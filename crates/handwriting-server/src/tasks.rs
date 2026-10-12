//! 2026-10-12：SQLite 仅保存元数据；Rust 与 Python 使用独立数据库。
use handwriting_core::{Cancellation, Error, Result};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::sync::watch;
pub fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
#[derive(Clone, Serialize, Deserialize, Debug)]
pub struct Task {
    pub task_id: String,
    pub task_status: String,
    pub task_stage: String,
    pub task_message: String,
    pub task_progress: u8,
    pub created_at: f64,
    pub updated_at: f64,
    pub error_message: Option<String>,
    pub error_code: Option<String>,
    pub result_file: Option<PathBuf>,
    pub content_type: Option<String>,
    pub filename: Option<String>,
}
impl Task {
    pub fn active(&self) -> bool {
        matches!(self.task_status.as_str(), "pending" | "processing")
    }
}
pub struct Runtime {
    pub task: Task,
    pub cancellation: Cancellation,
    pub sender: watch::Sender<Task>,
    pub downloads: Arc<AtomicUsize>,
}
pub struct Store {
    db: Connection,
    pub tasks: BTreeMap<String, Runtime>,
    pub ttl: f64,
}
fn db_error(e: impl std::fmt::Display) -> Error {
    Error::new("storage_failed", e.to_string())
}
impl Store {
    pub fn open(directory: &Path, ttl: f64) -> Result<Self> {
        std::fs::create_dir_all(directory.join("results")).map_err(db_error)?;
        let db = Connection::open(directory.join("rust-tasks.db")).map_err(db_error)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS tasks(id TEXT PRIMARY KEY, metadata TEXT NOT NULL);").map_err(db_error)?;
        let records = {
            let mut statement = db.prepare("SELECT metadata FROM tasks").map_err(db_error)?;
            statement
                .query_map([], |r| r.get::<_, String>(0))
                .map_err(db_error)?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(db_error)?
        };
        let mut store = Self {
            db,
            tasks: BTreeMap::new(),
            ttl,
        };
        for json in records {
            let mut task: Task = serde_json::from_str(&json).map_err(db_error)?;
            if task.active() {
                task.task_status = "failed".into();
                task.task_stage = "interrupted".into();
                task.error_code = Some("interrupted".into());
                task.error_message = Some("服务重启，任务已中断，请重新生成".into());
                task.updated_at = now();
            }
            let (sender, _) = watch::channel(task.clone());
            store.tasks.insert(
                task.task_id.clone(),
                Runtime {
                    task,
                    cancellation: Cancellation::default(),
                    sender,
                    downloads: Arc::new(AtomicUsize::new(0)),
                },
            );
        }
        for runtime in store.tasks.values() {
            store.persist(&runtime.task)?;
        }
        store.cleanup()?;
        // 中断任务及崩溃遗留的未提交结果不再占用磁盘。
        for entry in std::fs::read_dir(directory.join("results")).map_err(db_error)? {
            let path = entry.map_err(db_error)?.path();
            if path.is_file()
                && !store
                    .tasks
                    .values()
                    .any(|r| r.task.result_file.as_ref() == Some(&path))
            {
                std::fs::remove_file(path).map_err(db_error)?;
            }
        }
        Ok(store)
    }
    fn persist(&self, task: &Task) -> Result<()> {
        self.db.execute("INSERT INTO tasks(id,metadata) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata",params![task.task_id,serde_json::to_string(task).map_err(db_error)?]).map_err(db_error)?;
        Ok(())
    }
    pub fn insert(&mut self, id: String, max_active: usize) -> Result<Cancellation> {
        self.cleanup()?;
        if self.tasks.values().filter(|r| r.task.active()).count() >= max_active {
            return Err(Error::new("queue_full", "当前服务器队列已满，请稍后再试"));
        }
        let time = now();
        let task = Task {
            task_id: id.clone(),
            task_status: "pending".into(),
            task_stage: "queued".into(),
            task_message: "任务排队中".into(),
            task_progress: 0,
            created_at: time,
            updated_at: time,
            error_message: None,
            error_code: None,
            result_file: None,
            content_type: None,
            filename: None,
        };
        self.persist(&task)?;
        let (sender, _) = watch::channel(task.clone());
        let cancellation = Cancellation::default();
        self.tasks.insert(
            id,
            Runtime {
                task,
                cancellation: cancellation.clone(),
                sender,
                downloads: Arc::new(AtomicUsize::new(0)),
            },
        );
        Ok(cancellation)
    }
    pub fn update(&mut self, id: &str, change: impl FnOnce(&mut Task)) -> Result<()> {
        let Some(runtime) = self.tasks.get_mut(id) else {
            return Err(Error::new("task_not_found", "任务不存在"));
        };
        let mut task = runtime.task.clone();
        change(&mut task);
        task.updated_at = now();
        self.persist(&task)?;
        let runtime = self.tasks.get_mut(id).unwrap();
        runtime.task = task.clone();
        runtime.sender.send_replace(task);
        Ok(())
    }
    pub fn payload(&self, id: &str) -> Option<serde_json::Value> {
        let target = &self.tasks.get(id)?.task;
        let pending = self
            .tasks
            .values()
            .filter(|r| r.task.task_status == "pending")
            .count();
        let processing = self
            .tasks
            .values()
            .filter(|r| r.task.task_status == "processing")
            .count();
        let ahead = if target.task_status == "pending" {
            self.tasks
                .values()
                .filter(|r| {
                    r.task.task_status == "pending"
                        && (r.task.created_at, &r.task.task_id)
                            < (target.created_at, &target.task_id)
                })
                .count()
        } else {
            0
        };
        Some(
            serde_json::json!({"status":"success","task_id":id,"task_status":target.task_status,"task_stage":target.task_stage,"task_message":target.task_message,"task_progress":target.task_progress,"created_at":target.created_at,"updated_at":target.updated_at,"error_message":target.error_message,"error_code":target.error_code,"queue_pending_count":pending,"queue_ahead_count":ahead,"processing_count":processing,"active_task_count":pending+processing}),
        )
    }
    pub fn cleanup(&mut self) -> Result<()> {
        let cutoff = now() - self.ttl;
        let expired: Vec<_> = self
            .tasks
            .iter()
            .filter(|(_, r)| {
                !r.task.active()
                    && r.task.updated_at < cutoff
                    && r.downloads.load(Ordering::Acquire) == 0
            })
            .map(|(id, _)| id.clone())
            .collect();
        for id in expired {
            if let Some(path) = &self.tasks[&id].task.result_file {
                match std::fs::remove_file(path) {
                    Ok(()) => (),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                    Err(e) => return Err(db_error(e)),
                }
            }
            self.db
                .execute("DELETE FROM tasks WHERE id=?1", [&id])
                .map_err(db_error)?;
            self.tasks.remove(&id);
        }
        Ok(())
    }
}
