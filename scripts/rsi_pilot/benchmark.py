"""Freeze a two-section homework draft and dispatch one external policy decision at a time.

Call from the repository root. Dependencies: Python 3.11+, Pillow and NumPy (geometry).
Example from the repository root, after building panache-mcp and the Markdown worker:

  python scripts/rsi_pilot/benchmark.py --out RUN setup --binary target/release/panache-mcp --worker app/web/prepare-text-worker.js --fonts assets/font_assets public-grid public-depth
  python scripts/rsi_pilot/benchmark.py --out RUN native-start public-grid B --binary target/release/panache-mcp --provider gpt-6.1-terra-high
  python scripts/rsi_pilot/benchmark.py --out RUN baseline public-grid B
  python scripts/rsi_pilot/run_episode.py --out RUN --paper public-grid --arm B
  python scripts/rsi_pilot/benchmark.py --out RUN score public-grid B

Use the .exe suffix on Windows. To stage the three optional photographs, pass
--photos DIR and the names image-1 image-2 image-3 to setup. For manual dispatch,
advance takes PAPER ARM DECISION.json, performs one action and returns control.
All source photographs, rendered pages, exported PDFs and raw tool logs stay in RUN.

"""

import argparse
import base64
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import time
from contextlib import closing
from pathlib import Path

from PIL import Image

SECTIONS = [
    """电路分析作业　RC 放电

已知电阻 R = 10 kΩ，电容 C = 100 μF，初始电压为 5 V。

断开电源后，电荷经电阻释放。取电容上端对地电压为 u(t)。

由基尔霍夫电流定律得 C du/dt + u/R = 0。

分离变量并积分：ln(u/5) = −t/(RC)。

时间常数 τ = RC = 1.0 s，故 u(t) = 5 exp(−t/τ) V。

代入 t = 2.0 s，计算得 u(2) = 0.677 V。

此时电阻上的电流为 0.0677 mA，方向从上端流向地。""",
    """数值计算作业　显式欧拉法

沿用前页电路，用步长 h = 0.5 s 求解初值问题。

递推式 u[n+1] = u[n] + h (−u[n]/τ)。

因为 h/τ = 0.5，每一步的电压都是上一步的一半。

从 u[0] = 5 V 开始，依次得到 2.5、1.25、0.625 V。

第 4 步对应 t = 2 s，近似值为 0.3125 V。

与解析值 0.6767 V 比较，绝对误差约为 0.3642 V。

步长减半后可降低截断误差。这里的数值衰减快于真实电路。""",
]
# Each concise paragraph forms one ruled line on the 13-row depth-stress sheet.
DEPTH_SECTIONS = [
    """RC 放电实验

R = 10 kΩ，C = 100 μF。

电源初始为 5 V。

开关断开后开始计时。

电流经电阻释放电荷。

设上端电压为 u(t)。

有 C du/dt = −u/R。

整理为 du/u = −dt/(RC)。

积分得 ln(u/5) = −t/(RC)。

时间常数 τ = RC = 1 s。

代入 t = 2 s。

u(2) = 5 exp(−2) V。

末读数约为 0.677 V。""",
    """欧拉法数值检验

初值 u[0] = 5 V。

步长 h = 0.5 s。

模型为 du/dt = −u/τ。

递推得 u[n+1] = 0.5u[n]。

第一步为 2.5 V。

第二步为 1.25 V。

第三步为 0.625 V。

第四步为 0.3125 V。

解析值约为 0.6767 V。

绝对误差约为 0.3642 V。

减小步长可改善精度。

结果低估了真实电压。""",
]


def sections_for(paper):
    import prospective_papers

    if paper in prospective_papers.PAPERS:
        return prospective_papers.SECTIONS[paper]
    return DEPTH_SECTIONS if paper == "public-depth" else SECTIONS


OBJECTIVE = "将两页理工科作业自然、清楚地写在原纸可写横线上，保留公式、题目与正文，避免遮挡印刷标题或栏框。"


def objective_for(paper):
    import prospective_papers

    if paper in prospective_papers.PAPERS:
        return prospective_papers.OBJECTIVES[paper]
    if paper == "public-depth":
        return OBJECTIVE + "每节须在一张纸上完成；交付恰好两张，保留末行答案。"
    return OBJECTIVE


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    tmp.replace(path)


class Server:
    """Line-oriented MCP stdio. Count on-wire JSON bytes, including base64; never log image data."""

    def __init__(self, cfg, home, phase, *, log_dir=None):
        home.mkdir(parents=True, exist_ok=True)
        self.phase, self.log = phase, (log_dir or home) / "calls.jsonl"
        self.env = dict(
            os.environ,
            PANACHE_MCP_HOME=str(home),
            PANACHE_FONT_DIR=cfg["fonts"],
            PANACHE_MARKDOWN_WORKER=cfg["worker"],
            PANACHE_USER_FONT_DIR=str(home / "fonts"),
        )
        self.binary, self.home, self.seq = cfg["binary"], home, 0

    def __enter__(self):
        self.stderr = (self.home / "server.stderr").open("ab")
        self.p = subprocess.Popen(
            [self.binary],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.stderr,
            cwd=self.home,
            env=self.env,
        )
        self.rpc(
            "initialize",
            {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "panache-rsi-pilot", "version": "1"},
            },
        )
        self.p.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.p.stdin.flush()
        return self

    def __exit__(self, *_):
        self.p.stdin.close()
        try:
            self.p.wait(timeout=12)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        self.p.stdout.close()
        self.stderr.close()

    def rpc(self, method, params):
        self.seq += 1
        body = (
            json.dumps(
                {"jsonrpc": "2.0", "id": self.seq, "method": method, "params": params},
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
            + b"\n"
        )
        start = time.monotonic()
        self.p.stdin.write(body)
        self.p.stdin.flush()
        while row := self.p.stdout.readline():
            obj = json.loads(row)
            if obj.get("id") == self.seq:
                break
        else:
            raise RuntimeError("MCP closed stdout; inspect server.stderr")
        result = obj.get("result", {})
        error = obj.get("error") or (
            result.get("content", [{}])[0].get("text")
            if result.get("isError")
            else None
        )
        with self.log.open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {
                        "phase": self.phase,
                        "method": method,
                        **params,
                        "request_bytes": len(body),
                        "response_bytes": len(row),
                        "seconds": round(time.monotonic() - start, 4),
                        "error": error,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
        if error:
            raise RuntimeError(f"{method}/{params.get('name')}: {error}")
        return result

    def call(self, name, **args):
        deadline = time.monotonic() + 60
        delay = 0.5
        while True:
            try:
                return self.rpc("tools/call", {"name": name, "arguments": args})
            except RuntimeError as error:
                # The server rejected before import/export acquired its storage lock.
                if (
                    "Storage busy: retry" not in str(error)
                    or time.monotonic() >= deadline
                ):
                    raise
                time.sleep(delay)
                delay = min(4, delay * 2)


def create_draft(server, path, sections):
    import prospective_papers

    saved = server.call(
        "save_section",
        markdown=sections[0],
        title=prospective_papers.TITLES.get(Path(path).stem, "电路分析与数值计算"),
        paper_path=str(path),
        style={"seed": 24719, "font": "李国夫手写体.ttf", "font_size": 36},
    )["structuredContent"]
    return server.call(
        "save_section",
        draft_id=saved["draft_id"],
        expected_revision=saved["revision"],
        markdown=sections[1],
    )["structuredContent"]


def setup(args):
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    paths = {
        "binary": args.binary.resolve(strict=True),
        "worker": args.worker.resolve(strict=True),
        "fonts": args.fonts.resolve(strict=True),
    }
    cfg = {k: str(v) for k, v in paths.items()}
    cfg["binary_sha256"] = digest(paths["binary"].read_bytes())
    cfg["worker_sha256"] = digest(paths["worker"].read_bytes())
    cfg["font_hashes"] = {
        p.name: digest(p.read_bytes()) for p in sorted(paths["fonts"].glob("*.ttf"))
    }
    runtime_path = out / "runtime.json"
    if runtime_path.exists() and read(runtime_path) != cfg:
        raise ValueError(
            "Use a separate run directory when changing the fixture runtime"
        )
    write(runtime_path, cfg)
    for paper in args.papers:
        sections = sections_for(paper)
        import prospective_papers

        if paper in prospective_papers.PAPERS:
            path = out / f"{paper}.png"
            prospective_papers.generate(paper, path)
        elif paper in {"public-grid", "public-depth"}:
            from paper_geometry import generate_depth_paper, generate_public_paper

            path = out / f"{paper}.png"
            generate = (
                generate_depth_paper
                if paper == "public-depth"
                else generate_public_paper
            )
            generate(path)
        else:
            if args.photos is None:
                raise ValueError("--photos is required for supplied photographs")
            path = args.photos / f"{paper}.jpg"
        path = path.resolve(strict=True)
        group = out / paper
        if (group / "seed.json").exists():
            raise ValueError(f"Already initialized {paper}")
        with Server(cfg, group / "seed", "shared_fixture") as s:
            added = create_draft(s, path, sections)
        info = {
            "paper": paper,
            "path": str(path),
            "sha256": digest(path.read_bytes()),
            "size": Image.open(path).size,
            "draft_id": added["draft_id"],
            "revision": added["revision"],
            "split": "development" if paper in ("image-1", "image-3") else "heldout",
            "section_sha256": [digest(t.encode()) for t in sections],
        }
        write(group / "seed.json", info)
        print(paper, info["revision"], flush=True)


def clone(args):
    group = args.out / args.paper
    arm = group / args.arm
    arm.mkdir(parents=True, exist_ok=False)
    with (
        closing(
            sqlite3.connect(
                (group / "seed" / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True
            )
        ) as src,
        closing(sqlite3.connect(arm / "drafts.sqlite3")) as dst,
    ):
        src.backup(dst)
    state = read(group / "seed.json")
    state.update(arm=args.arm, decisions=[], snapshots={})
    write(arm / "state.json", state)


def save_image(result, target):
    (block,) = [b for b in result["content"] if b["type"] == "image"]
    target.write_bytes(base64.b64decode(block["data"]))


def packet(directory, pages):
    images = [Image.open(directory / p["image"]).convert("RGB") for p in pages]
    w, h = images[0].size

    def tile(image, width):
        return image.resize(
            (width, round(image.height * width / image.width)), Image.Resampling.LANCZOS
        )

    whole = [tile(img, 420) for img in images]
    sheet = Image.new(
        "RGB", (sum(i.width for i in whole), max(i.height for i in whole)), "white"
    )
    for n, image in enumerate(whole):
        sheet.paste(image, (420 * n, 0))
    sheet.save(directory / "overview.jpg", quality=88)
    # Identical normalized windows for all arms, frozen before any solver decisions.
    boxes = [
        (0.10, 0.19, 0.58, 0.32),
        (0.12, 0.37, 0.60, 0.50),
        (0.15, 0.60, 0.63, 0.73),
    ]
    roi = Image.new(
        "RGB", (550 * len(images), 3 * round(550 * h * 0.13 / (w * 0.48))), "white"
    )
    for n, img in enumerate(images):
        for k, box in enumerate(boxes):
            crop = tile(
                img.crop(
                    tuple(
                        round(v * (w if j % 2 == 0 else h)) for j, v in enumerate(box)
                    )
                ),
                550,
            )
            roi.paste(crop, (550 * n, k * roi.height // 3))
    roi.save(directory / "detail.jpg", quality=94)


def snapshot(cfg, arm, state):
    rev = state["revision"]
    directory = arm / f"r{rev}"
    directory.mkdir(exist_ok=True)
    pages = []
    with Server(
        cfg, Path(state.get("home", arm)), "render_and_measure", log_dir=arm
    ) as s:
        save_image(
            s.call(
                "preview_handwriting",
                draft_id=state["draft_id"],
                revision=rev,
                view="paper",
            ),
            directory / "paper.png",
        )
        for section in (1, 2):
            key = {"draft_id": state["draft_id"], "revision": rev, "section": section}
            # Query last physical page so overflow is never truncated.
            last = s.call("read_section", **key, view="review", page="last")[
                "structuredContent"
            ]
            write(directory / f"section-{section}.json", last)
            for page in range(1, int(last["page"]) + 1):
                key["page"] = page
                prefix = f"s{section}p{page}"
                save_image(
                    s.call("preview_handwriting", **key, view="image"),
                    directory / f"{prefix}.png",
                )
                review = s.call("preview_handwriting", **key, view="review")[
                    "structuredContent"
                ]
                write(directory / f"{prefix}-review.json", review)
                glyphs, offset = [], 0
                while offset is not None:
                    layout = s.call(
                        "preview_handwriting",
                        **key,
                        view="layout",
                        limit=32,
                        offset=offset,
                    )["structuredContent"]
                    glyphs.extend(layout["glyphs"])
                    offset = layout.get("next_offset")
                write(directory / f"{prefix}-glyphs.json", glyphs)
                pages.append(
                    {
                        "section": section,
                        "page": page,
                        "image": f"{prefix}.png",
                        "sha256": digest((directory / f"{prefix}.png").read_bytes()),
                        "review_id": review["review_id"],
                        "glyphs": len(glyphs),
                    }
                )
    state["snapshots"][str(rev)] = pages
    write(arm / "state.json", state)
    packet(directory, pages)
    print(directory, len(pages), flush=True)


def native_start(args):
    """Create a fresh native draft in the shared task database and compare to the frozen seed."""
    cfg = read(args.out / "runtime.json")
    cfg["binary"] = str(args.binary.resolve(strict=True))
    cfg["binary_sha256"] = digest(Path(cfg["binary"]).read_bytes())
    group = args.out / args.paper
    sections = sections_for(args.paper)
    arm = group / args.arm
    home = args.out / "native-home"
    arm.mkdir(parents=True, exist_ok=False)
    state = read(group / "seed.json")
    with Server(cfg, home, "shared_fixture", log_dir=arm) as s:
        result = create_draft(s, state["path"], sections)
        state.update(
            draft_id=result["draft_id"],
            revision=result["revision"],
            home=str(home),
            arm=args.arm,
            snapshots={},
            decisions=[],
            policy_id=args.policy,
            runtime=cfg,
        )
    write(arm / "state.json", state)
    snapshot(cfg, arm, state)
    warm = group / "trajectory" / "state.json"
    if warm.exists():
        expected = [p["sha256"] for p in read(warm)["snapshots"]["2"]]
        actual = [p["sha256"] for p in state["snapshots"]["2"]]
        state["warmup_pages_match"] = expected == actual
        write(arm / "state.json", state)
        if expected != actual:
            print(
                "Warmup and native pages differ; present new pages to the actor before using decisions."
            )
    with Server(cfg, home, "policy_binding", log_dir=arm) as s:
        task = s.call(
            "start_rsi_task",
            draft_id=state["draft_id"],
            revision=state["revision"],
            objective=objective_for(args.paper),
            policy_id=args.policy,
            decision_provider=args.provider,
        )["structuredContent"]
    state["task"] = task
    write(arm / "state.json", state)
    print(task["task_id"])


def evidence(s, state, action, folder):
    name = action.get("tool")
    params = action.get("arguments") or {}
    folder.mkdir(parents=True, exist_ok=True)
    if name == "detect_guides":
        from paper_detector import detect_guides

        start = time.monotonic()
        guides = detect_guides(Path(state["path"]))
        elapsed = time.monotonic() - start
        write(folder / "guides.json", guides)
        return {
            "guides": guides,
            "host_seconds": round(elapsed, 4),
            "source_sha256": state["sha256"],
        }
    if name == "native_crop":
        section = params["section"]
        if section not in (1, 2):
            if "左" in str(section) or "第一" in str(section):
                section = 1
            elif "右" in str(section) or "第二" in str(section):
                section = 2
            else:
                raise ValueError("Specify section 1 or 2")
        vals = params["box"]
        if (
            len(vals) != 4
            or not all(0 <= n <= 1 for n in vals)
            or vals[0] >= vals[2]
            or vals[1] >= vals[3]
        ):
            raise ValueError("Expected a normalized [x0,y0,x1,y1] box")
        x0, y0, x1, y1 = [round(v * d) for v, d in zip(vals, state["size"] * 2)]
        params = {
            "section": section,
            "page": params.get("page_in_section", 1),
            "view": "image",
            "export_blur_px": 0,
            "region": [[x0, y0], [x1, y0], [x1, y1], [x0, y1]],
        }
        name = "preview_handwriting"
    if name not in {"preview_handwriting", "read_section", "describe_controls"}:
        raise ValueError("Unknown evidence tool")
    key = {"draft_id": state["draft_id"], "revision": state["revision"]}
    if name == "describe_controls" and not params.get("group"):
        key = {}
    if name == "preview_handwriting" and state.get("task"):
        key["rsi_task_id"] = state["task"]["task_id"]
    result = s.call(name, **params, **key)
    meta = result["structuredContent"]
    write(folder / "metadata.json", meta)
    for i, block in enumerate(b for b in result["content"] if b["type"] == "image"):
        (folder / f"image-{i + 1}.png").write_bytes(base64.b64decode(block["data"]))
    return {k: meta[k] for k in ("evidence_id", "review_id", "image_size") if k in meta}


def deliver(server, state, arm):
    """Export the exact selected revision; file delivery can be retried after a closed task."""
    rev = state["selected_revision"]
    if rev is None:
        raise ValueError("No revision selected for delivery")
    exported = server.call(
        "export_handwriting", draft_id=state["draft_id"], revision=rev, format="pdf"
    )["structuredContent"]
    if exported["pages"] != len(state["snapshots"][str(rev)]):
        raise ValueError("PDF page count differs from the frozen candidate")
    exported["file_sha256"] = digest(Path(exported["path"]).read_bytes())
    write(arm / "export.json", exported)


def advance(args):
    """Dispatch a single genuine external decision; an error counts as an attempt."""
    arm = args.out / args.paper / args.arm
    state = read(arm / "state.json")
    cfg = state.get("runtime", read(args.out / "runtime.json"))
    action = read(args.decision)
    op = action["action"]
    if state.get("disposition"):
        raise ValueError("Task already closed")
    if op not in {"revise", "request_evidence", "select", "stop"}:
        raise ValueError("Unknown action")
    step = len(state["decisions"]) + 1
    if step >= 5 and op not in {"select", "stop"}:
        raise ValueError(
            "Budget reached (four nonterminal decisions); explicit terminal decision required"
        )
    rev = action.get(
        "revision", (action.get("arguments") or {}).get("revision", state["revision"])
    )
    if str(rev) not in state["snapshots"]:
        raise ValueError("Unreviewed revision")
    folder = arm / f"step-{step}"
    folder.mkdir(exist_ok=True)
    applied = {
        "step": step,
        "revision": rev,
        "raw": action,
        "source_sha256": digest(args.decision.read_bytes()),
    }
    write(folder / "decision.json", applied)
    with Server(
        cfg, Path(state.get("home", arm)), "decision_dispatch", log_dir=arm
    ) as s:
        task = state.get("task")
        if task:
            ids = [page["review_id"] for page in state["snapshots"][str(rev)]]
            for earlier in state["decisions"]:
                if earlier["revision"] == rev:
                    extra = earlier.get("evidence", {}).get("evidence_id")
                    if extra:
                        ids.append(extra)
            req = {
                "task_id": task["task_id"],
                "expected_step": task["step"],
                "revision": rev,
                "action": op,
                "reason": action["reason"],
                "review_ids": ids,
            }
            if op in {"revise", "request_evidence"}:
                req["instruction"] = (
                    action.get("instruction")
                    or action.get("expected")
                    or action["reason"]
                )
            if op == "revise":
                req["tool"] = action["tool"]
            task = s.call("advance_rsi_task", **req)["structuredContent"]
            state["task"] = task
            applied["decision_id"] = task["decisions"][-1]["decision_id"]
        state["decisions"].append(applied)
        write(arm / "state.json", state)
        try:
            if op == "request_evidence":
                applied["evidence"] = evidence(s, state, action, folder)
            elif op == "revise":
                params = dict(action["arguments"])
                if params.get("paper_guides") == "$detected":
                    from paper_detector import detect_guides

                    params["paper_guides"] = detect_guides(Path(state["path"]))
                if task:
                    params["rsi_decision_id"] = applied["decision_id"]
                result = s.call(
                    action["tool"],
                    draft_id=state["draft_id"],
                    expected_revision=rev,
                    **params,
                )
                state["revision"] = result["structuredContent"]["revision"]
                applied["result_revision"] = state["revision"]
            elif op == "select":
                state.update(disposition=op, selected_revision=rev)
                deliver(s, state, arm)
            elif op == "stop":
                state.update(disposition=op, selected_revision=None)
        except (ValueError, RuntimeError, KeyError, TypeError) as exc:
            applied["error"] = str(exc)
            print("Decision failed:", exc)
        write(folder / "decision.json", applied)
        write(arm / "state.json", state)
    if op == "revise" and "result_revision" in applied:
        snapshot(cfg, arm, state)
    print(folder)


def score(args):
    """The scoring command is evaluator-only. It never sends labels or scores to the actor."""
    from paper_geometry import load_labels, score_ink, score_layout

    arm = args.out / args.paper / args.arm
    state = read(arm / "state.json")
    labels = load_labels(state["paper"])
    for rev, pages in state["snapshots"].items():
        directory = arm / f"r{rev}"
        if not (directory / "paper.png").exists():
            cfg = state.get("runtime", read(args.out / "runtime.json"))
            with Server(
                cfg, Path(state.get("home", arm)), "evaluator", log_dir=arm
            ) as s:
                save_image(
                    s.call(
                        "preview_handwriting",
                        draft_id=state["draft_id"],
                        revision=int(rev),
                        view="paper",
                    ),
                    directory / "paper.png",
                )
        for p in pages:
            prefix = f"s{p['section']}p{p['page']}"
            glyphs = read(directory / f"{prefix}-glyphs.json")
            metrics = {
                "layout": score_layout(labels, glyphs),
                "raster": score_ink(
                    labels, directory / "paper.png", directory / p["image"], glyphs
                ),
            }
            write(directory / f"{prefix}-score.json", metrics)


def baseline(args):
    # The immutable starting revision IS the A arm. A receives no actor decisions.
    original = args.out / args.paper / args.source
    src = read(original / "state.json")
    arm = args.out / args.paper / "A"
    arm.mkdir(exist_ok=True)
    if (arm / "export.json").exists():
        raise ValueError("Baseline export already exists")
    previous = arm / "state.json"
    if previous.exists() and read(previous)["draft_id"] != src["draft_id"]:
        raise ValueError("Baseline belongs to a different draft")
    pages = src["snapshots"]["2"]
    state = {
        k: src[k]
        for k in (
            "paper",
            "path",
            "sha256",
            "size",
            "draft_id",
            "split",
            "section_sha256",
            "home",
            "runtime",
        )
    }
    state.update(
        revision=2,
        snapshots={"2": pages},
        decisions=[],
        arm="A",
        disposition="fixed_baseline",
        selected_revision=2,
    )
    write(arm / "state.json", state)
    shutil.copytree(original / "r2", arm / "r2", dirs_exist_ok=True)
    with Server(
        src["runtime"], Path(src["home"]), "fixed_delivery", log_dir=arm
    ) as server:
        deliver(server, state, arm)
    print(arm)


def policy(args):
    group = args.out / args.paper / args.arm
    state = read(group / "state.json")
    request = read(args.request)
    with Server(
        state["runtime"], Path(state["home"]), "policy_registry", log_dir=group
    ) as server:
        document = server.call(args.tool, **request)["structuredContent"]
    write(args.response, document)
    print(args.response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    cmd = parser.add_subparsers(dest="op", required=True)
    c = cmd.add_parser("setup")
    for k in ("binary", "worker", "fonts"):
        c.add_argument("--" + k, required=True, type=Path)
    c.add_argument("--photos", type=Path)
    c.add_argument("papers", nargs="+")
    c = cmd.add_parser("baseline")
    c.add_argument("paper")
    c.add_argument(
        "source", help="Native arm that contains the immutable starting revision"
    )
    c = cmd.add_parser("policy")
    c.add_argument("paper")
    c.add_argument("arm")
    c.add_argument(
        "tool", choices=("read_rsi_policy", "publish_rsi_policy", "validate_rsi_policy")
    )
    c.add_argument("request", type=Path)
    c.add_argument("response", type=Path)
    for name in (
        "clone",
        "freeze",
        "native-start",
        "advance",
        "score",
        "export-selected",
    ):
        c = cmd.add_parser(name)
        c.add_argument("paper")
        c.add_argument("arm")
        if name == "native-start":
            c.add_argument("--binary", required=True, type=Path)
            c.add_argument("--policy", default="pilot-v1")
            c.add_argument("--provider", required=True)
        if name == "advance":
            c.add_argument("decision", type=Path)
    args = parser.parse_args()
    args.out = args.out.resolve()
    if args.op == "baseline":
        return baseline(args)
    if args.op == "policy":
        return policy(args)
    if args.op == "setup":
        return setup(args)
    if args.op == "clone":
        return clone(args)
    if args.op == "native-start":
        return native_start(args)
    if args.op == "advance":
        return advance(args)
    if args.op == "score":
        return score(args)
    arm = args.out / args.paper / args.arm
    state = read(arm / "state.json")
    cfg = state.get("runtime", read(args.out / "runtime.json"))
    if args.op == "export-selected":
        with Server(
            cfg, Path(state.get("home", arm)), "delivery_retry", log_dir=arm
        ) as server:
            deliver(server, state, arm)
        return
    snapshot(cfg, arm, state)


if __name__ == "__main__":
    main()
