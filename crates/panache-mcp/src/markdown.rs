use anyhow::{Context as _, Result};
use rquickjs::{CatchResultExt, Context, Runtime};
use std::time::{Duration, Instant};

/// 2026-11-22：在无文件和网络 API 的 JS 上下文执行与工作台相同的文本整理 Worker。
pub fn prepare(worker: &str, source: &str) -> Result<String> {
    let runtime = Runtime::new()?;
    runtime.set_memory_limit(128 * 1024 * 1024);
    runtime.set_max_stack_size(1024 * 1024);
    let deadline = Instant::now() + Duration::from_secs(30);
    runtime.set_interrupt_handler(Some(Box::new(move || Instant::now() >= deadline)));
    let context = Context::full(&runtime)?;
    context.with(|ctx| {
        let run = || -> rquickjs::Result<String> {
            ctx.eval::<(), _>("globalThis.self = globalThis; globalThis.postMessage = m => { globalThis.reply = m; };")?;
            ctx.eval::<(), _>(worker)?;
            ctx.globals().set("markdownSource", source)?;
            ctx.eval("onmessage({data: {text: markdownSource, tableMode: 'latex'}}); if (typeof reply?.result !== 'string') throw Error('Markdown conversion failed'); reply.result")
        };
        run().catch(&ctx).map_err(|e| anyhow::anyhow!("{e}"))
    }).context("Markdown worker failed")
}
