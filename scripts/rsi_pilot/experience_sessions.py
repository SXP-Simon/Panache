"""Run a fresh signed-in Terra against an unmodified Panache stdio server in an empty directory.

The pass-through copies every wire byte and records compact tool receipts. It never issues a
request or changes a tool result. The only shared study surface is the Panache draft store.
Use 'run' for a case and 'proxy' only as the configured stdio command. Raw traces stay local.
"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from benchmark import read, write

CASES = {
    "connect": "请用 Panache 列出可选的手写中文字体，举两个例子就行。",
    "origin": "请用 Panache 做一页手写的 LaTeX 入门小作业并导出 PDF。题目是：怎样用分式写出四分之三？先原样写下键盘上要敲的 LaTeX 命令，另起一行展示排好的分式，再写一句话解释哪一项是分母。",
    "transfer": "想给同桌一张手写的物理速记页，用 Panache 生成 PDF。内容是平均速度：12 米走了 4 秒。请写出可以照抄进 LaTeX 的计算式源码，再给排好版的分式和带单位的速度结果。",
    "plain": "请用 Panache 做一张手写语文作业并导出 PDF。在一页上抄写“春天到了，河边的柳树发出了新芽。”，下一行写出句中的季节。",
}
MODEL = "gpt-6.1-terra"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def digest_tree(x):
    if isinstance(x, dict):
        if x.get("type") == "image" and isinstance(x.get("data"), str):
            decoded = base64.b64decode(x["data"])
            return {
                "type": "image",
                "sha256": sha(decoded),
                "byte_count": len(decoded),
                "mimeType": x.get("mimeType"),
            }
        return {
            k: (
                {
                    "sha256": sha(base64.b64decode(v)),
                    "byte_count": len(base64.b64decode(v)),
                }
                if k == "blob" and isinstance(v, str)
                else digest_tree(v)
            )
            for k, v in x.items()
        }
    if isinstance(x, list):
        return [digest_tree(v) for v in x]
    return x


def proxy(config_path, trace_dir):
    cfg = read(config_path)
    env = dict(
        os.environ,
        PANACHE_MCP_HOME=cfg["home"],
        PANACHE_FONT_DIR=cfg["fonts"],
        PANACHE_MARKDOWN_WORKER=cfg["worker"],
        PANACHE_USER_FONT_DIR=str(Path(cfg["home"]) / "fonts"),
    )
    trace_dir.mkdir(exist_ok=True, parents=True)
    Path(cfg["home"]).mkdir(exist_ok=True, parents=True)
    tasks = {}
    lock = threading.Lock()
    with (
        (trace_dir / "native-stderr.log").open("ab") as err,
        (trace_dir / "wire.jsonl").open("a", encoding="utf8", buffering=1) as log,
        subprocess.Popen(
            [cfg["binary"]],
            cwd=cfg["home"],
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=err,
        ) as proc,
    ):

        def forward(src, dst, inbound):
            try:
                for raw in iter(src.readline, b""):
                    obj = json.loads(raw)
                    with lock:
                        ref = obj.get("id")
                        method = obj.get("method")
                        if inbound and method:
                            tasks[ref] = obj.get("params", {}).get("name", method)
                        label = tasks.get(ref, method)
                        body = digest_tree(obj)
                        if label == "tools/list" and not inbound:
                            body = {
                                "tools": [v["name"] for v in obj["result"]["tools"]]
                            }
                        log.write(
                            json.dumps(
                                {
                                    "time_ns": time.time_ns(),
                                    "direction": "request" if inbound else "response",
                                    "label": label,
                                    "wire_bytes": len(raw),
                                    "payload": body,
                                },
                                ensure_ascii=False,
                            )
                            + "\n"
                        )
                    dst.write(raw)
                    dst.flush()
            except (BrokenPipeError, OSError):
                pass
            finally:
                if inbound:
                    dst.close()

        t = threading.Thread(
            target=forward, args=(sys.stdin.buffer, proc.stdin, True), daemon=True
        )
        t.start()
        forward(proc.stdout, sys.stdout.buffer, False)


def run_case(cfg, name, out, prompt, model=MODEL):
    if out.exists():
        raise ValueError("Create a new directory for each attempt.")
    out.mkdir(parents=True)
    write(out / "native-runtime.json", cfg)
    (out / "prompt.txt").write_text(prompt, encoding="utf8")
    tool_cfg = {
        "command": sys.executable,
        "args": [
            str(Path(__file__).resolve()),
            "proxy",
            "--config",
            str(out / "native-runtime.json"),
            "--out",
            str(out),
        ],
        "startup_timeout_sec": 90,
        "tool_timeout_sec": 240,
    }

    def toml(x):
        return json.dumps(x, ensure_ascii=False)

    settings = (
        "mcp_servers.panache={"
        + ",".join(k + "=" + toml(v) for k, v in tool_cfg.items())
        + "}"
    )
    cli = shutil.which("codex")
    if not cli:
        raise RuntimeError("Sign in to the Codex CLI first.")
    with tempfile.TemporaryDirectory() as empty:
        args = [
            cli,
            "exec",
            "--ephemeral",
            "--json",
            "--ignore-user-config",
            "--skip-git-repo-check",
            "-C",
            empty,
            "-s",
            "read-only",
            "-m",
            model,
            "-c",
            'model_reasoning_effort="high"',
            "--disable",
            "shell_tool",
            "-c",
            "project_doc_max_bytes=0",
            "-c",
            settings,
            *[
                arg
                for name in (
                    "save_section",
                    "preview_handwriting",
                    "export_handwriting",
                    "record_homework_experience",
                    "validate_homework_experience",
                    "replace_section_text",
                    "tune_handwriting",
                    "adjust_glyphs",
                    "annotate_review",
                )
                for arg in (
                    "-c",
                    f'mcp_servers.panache.tools.{name}.approval_mode="approve"',
                )
            ],
            "-o",
            str(out / "final.txt"),
            "-",
        ]
        with (
            (out / "cli-events.jsonl").open("wb") as stdout,
            (out / "cli-stderr.log").open("wb") as stderr,
        ):
            result = subprocess.run(
                args, input=prompt.encode(), stdout=stdout, stderr=stderr, check=False
            )
    events = [
        json.loads(row)
        for row in (out / "cli-events.jsonl")
        .read_text(encoding="utf-8-sig")
        .splitlines()
        if row.strip()
    ]
    unique = [i["thread_id"] for i in events if i.get("type") == "thread.started"]
    completed_tools = [
        i["item"]
        for i in events
        if i.get("type") == "item.completed"
        and i.get("item", {}).get("type") == "mcp_tool_call"
    ]
    receipt = {
        "completed_mcp_items": len(completed_tools),
        "client_rejections": [
            {"tool": t.get("tool"), "reason": t.get("error")}
            for t in completed_tools
            if t.get("error")
        ],
        "case": name,
        "model": model,
        "reasoning_effort": "high",
        "empty_cwd": True,
        "ephemeral": True,
        "ignore_user_config": True,
        "shell_tool_disabled": True,
        "no_project_instructions": True,
        "prompt_sha256": sha(prompt.encode()),
        "binary_sha256": sha(Path(cfg["binary"]).read_bytes()),
        "thread_ids": unique,
        "cli_exit_code": result.returncode,
        "usage": [i.get("usage") for i in events if i.get("type") == "turn.completed"],
        "other_tools": [
            [e["item"].get("type"), e["item"].get("server")]
            for e in events
            if e.get("item", {}).get("type")
            in {"command_execution", "web_search", "file_change", "collab_tool_call"}
            or e.get("item", {}).get("type") == "mcp_tool_call"
            and e["item"].get("server") != "panache"
        ],
    }
    write(out / "receipt.json", receipt)
    print(json.dumps(receipt), flush=True)
    if (
        result.returncode
        or not (out / "wire.jsonl").exists()
        or len(unique) != 1
        or len(receipt["usage"]) != 1
        or receipt["other_tools"]
    ):
        raise RuntimeError(
            "Inspect the recorded attempt. It did not meet the isolation or tool-completion criteria."
        )


if __name__ == "__main__":
    arg = argparse.ArgumentParser(description=__doc__)
    arg.add_argument("command", choices=["run", "proxy"])
    arg.add_argument("--config", required=True, type=Path)
    arg.add_argument("--out", required=True, type=Path)
    arg.add_argument("--case", choices=CASES)
    arg.add_argument("--prompt", type=Path)
    opt = arg.parse_args()
    if opt.command == "proxy":
        proxy(opt.config.resolve(), opt.out.resolve())
    else:
        run_case(
            read(opt.config),
            opt.case,
            opt.out.resolve(),
            opt.prompt.read_text(encoding="utf-8-sig")
            if opt.prompt
            else CASES[opt.case],
        )
