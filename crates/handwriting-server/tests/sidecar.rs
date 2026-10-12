use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::{Duration, Instant},
};

struct OwnedChild(Child);
impl Drop for OwnedChild {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn desktop_handshake_and_parent_pipe_eof_shutdown() {
    let data = tempfile::tempdir().unwrap();
    let fonts = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
    let mut child = OwnedChild(
        Command::new(env!("CARGO_BIN_EXE_handwriting-server"))
            .env("HANDWRITING_DESKTOP_SIDECAR", "1")
            .env("HANDWRITING_LISTEN_ADDR", "127.0.0.1:0")
            .env("HANDWRITING_ACCESS_TOKEN", "a".repeat(32))
            .env("HANDWRITING_DATA_DIR", data.path())
            .env("HANDWRITING_FONT_DIR", fonts)
            .env("HANDWRITING_WEB_DIR", "")
            .env_remove("HANDWRITING_ALLOWED_ORIGINS")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let stdout = child.0.stdout.take().unwrap();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some(json) = line.strip_prefix("HANDWRITING_READY ") {
                let _ = sender.send(json.to_owned());
                break;
            }
        }
    });
    let json = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    let value: serde_json::Value = serde_json::from_str(&json).unwrap();
    let base = url::Url::parse(value["base"].as_str().unwrap()).unwrap();
    assert_eq!(base.host_str(), Some("127.0.0.1"));
    assert_ne!(base.port().unwrap(), 0);
    assert!(child.0.try_wait().unwrap().is_none());
    // 2026-10-12：父进程崩溃时 OS 也会关闭管道，服务必须自行退出。
    drop(child.0.stdin.take());
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = child.0.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline, "sidecar 没有随父管道关闭退出");
        std::thread::sleep(Duration::from_millis(20));
    }
}
