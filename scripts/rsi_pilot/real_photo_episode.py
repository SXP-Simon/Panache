"""Real-photo homework and strictly separated unprompted, guided, and blind visual reviews.

The original photograph and every page containing it stay under the provided working directory.
Run from the repository root with Python, Pillow and NumPy. The native AST probe consumes the
actual Markdown-worker output. No generated sheet is used as substitute stationery.

Using a private OUT directory, run real_photo_episode.py first with --out OUT --photo PHOTO
--binary BASELINE_EXE --worker WORKER_JS --fonts FONT_DIR --probe AST_PROBE. Then run
real_photo_episode.py guided --out OUT and real_photo_episode_controls.py --out OUT.
Run real_photo_episode_challenge.py --binary PHOTO_INK_EXE --out OUT, then
real_photo_episode_repair.py unsupported|repair --binary PHOTO_INK_EXE --out OUT
(once per action). Run real_photo_episode_local.py --binary FINAL_EXE --out OUT --results
RESULTS for feedback-directed refinement, and real_photo_episode_report.py --out OUT
--results RESULTS for the path-free report and deidentified native crop panels.
The CLI review helper requires an authenticated Codex CLI with access to the recorded model.
"""

import argparse
import base64
import io
import json
import math
import shutil
import subprocess
from pathlib import Path

import numpy as np
from appearance import edge_bands
from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion, take_snapshot
from paper_detector import detect_guides
from PIL import Image, ImageDraw

BRIEF = """写一份传感器波形的周期测量作业。一次试验从第一个上升过零点计到四个完整周期结束，两个时刻为 0.5 s 和 2.5 s。写清测量方法、数据表、带分母的周期计算和频率结论，画出操作流程，并附一张波形示意图。使用所给原纸。"""
FORMULA = r"$$T=\frac{2.5-0.5}{4}=0.5\,\mathrm{s}$$"
SOURCE = r"""周期测量　传感器波形实验

用相同方向的过零点标记周期，避免把半个周期当成整周期。

| 上升过零点 | 时刻 / s |
| --- | --- |
| 起点 | 0.5 |
| 四个周期后 | 2.5 |

总时差为 2.0 s，除以完整周期数，得到单周期时长。

FORMULA

频率为每秒 2 个周期，即 2 Hz。

测量流程：

\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{读波形};
\draw (0,-2) node[rectangle]{记时刻};
\draw (0,-4) node[rectangle]{求周期};
\draw[->] (0,0) -- (0,-2);
\draw[->] (0,-2) -- (0,-4);
\end{circuitikz}

参照下图，起点和终点均取波形向上穿过中线的位置。

EMBED

计时跨越多个周期后再求平均，可以减小时刻读数误差的影响。"""


def waveform():
    img = Image.new("RGB", (240, 70), "white")
    draw = ImageDraw.Draw(img)
    draw.line((5, 35, 235, 35), fill="black", width=1)
    points = [(8 + x, 35 - 22 * math.sin(2 * math.pi * x / 56)) for x in range(225)]
    draw.line(points, fill="black", width=3)
    draw.line((7, 7, 7, 63), fill="black", width=1)
    stream = io.BytesIO()
    img.save(stream, format="PNG")
    return stream.getvalue()


def source(formula):
    image = base64.b64encode(waveform()).decode()
    return SOURCE.replace("FORMULA", formula).replace(
        "EMBED", f"![实验波形](data:image/png;base64,{image})"
    )


def freeze(args):
    root = args.out.resolve()
    cfg = {
        key: str(getattr(args, key).resolve(strict=True))
        for key in ("binary", "worker", "fonts", "photo", "probe")
    }
    cfg.update(
        binary_sha256=digest(Path(cfg["binary"]).read_bytes()),
        worker_sha256=digest(Path(cfg["worker"]).read_bytes()),
        photo_sha256=digest(Path(cfg["photo"]).read_bytes()),
        waveform_sha256=digest(waveform()),
        probe_sha256=digest(Path(cfg["probe"]).read_bytes()),
        font_sha256=digest((Path(cfg["fonts"]) / "李国夫手写体.ttf").read_bytes()),
    )
    paper = read(Path(__file__).with_name("paper_labels.json"))["sources"]["image-1"]
    if cfg["photo_sha256"] != paper["sha256"]:
        raise ValueError(
            "The fixed native crop coordinates and provenance require the original image-1 photograph."
        )
    root.mkdir(parents=True, exist_ok=True)
    (root / "embedded-waveform.png").write_bytes(waveform())
    manifest = {
        "runtime": cfg,
        "brief": BRIEF,
        "source_sha256": digest(source(FORMULA).encode()),
        "independence": "The supplied photograph is byte-identical to the preceding pilot's image-1 development paper.",
    }
    if (root / "manifest.json").exists():
        old = read(root / "manifest.json")
        if any(old.get(k) != v for k, v in manifest.items()):
            raise ValueError(
                "Frozen source or runtime changed. Choose another working directory."
            )
    else:
        # The cargo examples directory is shared with subsequent builds.
        locked = root / ("frozen-content-probe" + Path(cfg["probe"]).suffix)
        shutil.copyfile(cfg["probe"], locked)
        if digest(locked.read_bytes()) != cfg["probe_sha256"]:
            raise ValueError("AST probe changed during the snapshot")
        write(root / "manifest.json", manifest)
    return cfg


def capture(cfg, folder, draft, rev):
    d = folder / f"r{rev}"
    with Server(cfg, folder / "home", "native_measure", log_dir=folder) as s:
        take_snapshot(s, folder, {"draft_id": draft}, rev)
        save_image(
            s.call("preview_handwriting", draft_id=draft, revision=rev, view="paper"),
            d / "paper.png",
        )
    prepared = (d / "prepared.txt").read_text(encoding="utf8")
    locked = folder.parent / ("frozen-content-probe" + Path(cfg["probe"]).suffix)
    executable = locked if locked.is_file() else Path(cfg["probe"])
    probe_hash = digest(executable.read_bytes())
    if locked.is_file() and probe_hash != cfg["probe_sha256"]:
        raise ValueError("Archived AST probe hash does not match the manifest")
    probe = subprocess.run(
        [str(executable)], input=prepared.encode(), capture_output=True, check=True
    )
    write(d / "nodes.json", json.loads(probe.stdout))
    write(
        d / "probe-receipt.json",
        {
            "binary_sha256": probe_hash,
            "prepared_utf8_sha256": digest(prepared.encode()),
        },
    )
    return d


def first(args):
    cfg = freeze(args)
    out = args.out.resolve()
    folder = out / "homework"
    folder.mkdir(exist_ok=True)
    if not (folder / "state.json").exists():
        with Server(cfg, folder / "home", "initial_homework", log_dir=folder) as s:
            r = s.call(
                "save_section",
                markdown=source(FORMULA),
                paper_path=cfg["photo"],
                title="传感器周期测量",
                style={
                    "homework": True,
                    "seed": 64019,
                    "font_size": 34,
                    "font": "李国夫手写体.ttf",
                },
            )["structuredContent"]
            write(
                folder / "state.json",
                {"draft_id": r["draft_id"], "revision": r["revision"]},
            )
    state = read(folder / "state.json")
    d = folder / "r1"
    if not (d / "pages.json").exists():
        capture(cfg, folder, state["draft_id"], 1)
    paths = [d / f"page-{p['page']}.png" for p in read(d / "pages.json")]
    print("Initial native", paths, flush=True)
    prompt = (
        BRIEF
        + "\n请独立查看随附成稿。你会交付吗？请按实际看见的内容，用 JSON 给出 decision（deliver、revise 或 uncertain）和 observations。不要使用工具。"
    )
    verdict = opinion(folder / "unprompted", prompt, paths)
    print(verdict)


# Native rectangles fixed against the first page before guided review. Original photo and ink
# crops use exactly the same bounds. Page two contains the concluding sentence near the top.
WINDOWS = {
    "upper_text": (1, (195, 258, 930, 387)),
    "printed_table": (1, (200, 402, 750, 622)),
    "equation": (1, (140, 616, 810, 744)),
    "flowchart": (1, (130, 776, 460, 1195)),
    "embedded_wave": (1, (450, 1290, 1030, 1510)),
    "conclusion": (2, (202, 250, 1240, 379)),
}


def pair_window(a, b):
    output = Image.new("RGB", (a.width * 2 + 8, a.height), "white")
    output.paste(a, (0, 0))
    output.paste(b, (a.width + 8, 0))
    return output


def packet(d):
    raw = Image.open(d / "paper.png").convert("RGB")
    summary = {}
    images = []
    for name, (page, box) in WINDOWS.items():
        original = raw.crop(box)
        with Image.open(d / f"page-{page}.png") as full:
            ink = full.convert("RGB").crop(box)
        level = np.asarray(original.convert("L"), dtype=np.int16)
        dark = level - np.asarray(ink.convert("L"), dtype=np.int16)
        added = dark[dark >= 12]
        summary[name] = {
            "page": page,
            "native_xyxy": box,
            "paper_luma_p25_p50_p75": np.percentile(level, [25, 50, 75])
            .round(1)
            .tolist(),
            "ink_luma_drop_p90": float(np.percentile(added, 90))
            if len(added)
            else None,
            "ink_pixel_count": len(added),
        }
        target = d / f"{name}.png"
        pair_window(original, ink).save(target)
        images.append(target)
    reviewed = read(d / "review-1.json")
    focus = reviewed["paper_focus_check"]
    focus = {
        k: [
            {
                v: t.get(v)
                for v in (
                    "sample_point",
                    "role",
                    "median_edge_width_px",
                    "sampled_strokes",
                )
            }
            for t in vals
        ]
        if k == "regions"
        else vals
        for k, vals in focus.items()
        if k in {"status", "regions"}
    }
    edges = edge_bands(d, "page-1.png", read(d / "glyphs-1.json"))
    byid = {g["id"]: g for g in read(d / "glyphs-1.json")}
    geometry = {}
    for label, ids in {
        "first_text": [0, 1, 2],
        "table": [42],
        "equation_line": [72, 73, 75, 76, 77, 78, 80],
        "flowchart": [108],
        "embedded_wave": [135],
    }.items():
        geometry[label] = [
            {
                "id": i,
                "kind": byid[i].get("kind"),
                "photo_quad": byid[i].get(
                    "current_photo_quad", byid[i].get("photo_quad")
                ),
            }
            for i in ids
            if i in byid
        ]
    predicted = detect_guides(d / "paper.png")
    checks = {
        "native_windows": summary,
        "printed_edge_focus": focus,
        "print_and_writing_vertical_edge_width_proxies_px": edges,
        "photo_space_geometry": geometry,
        "independently_detected_guides": predicted,
        "caveats": "Edge-width proxy is affected by stroke shape, angle and contrast. Large paper folds and designed arrows are not necessarily misplaced.",
    }
    write(d / "optical-evidence.json", checks)
    return images, checks


def guided(args):
    out = args.out.resolve()
    folder = out / "homework"
    d = folder / "r1"
    cfg = read(out / "manifest.json")["runtime"]
    pages = read(d / "pages.json")
    state = read(folder / "state.json")
    if not (d / "export.json").exists():
        with Server(cfg, folder / "home", "initial_export", log_dir=folder) as s:
            receipt = s.call(
                "export_handwriting",
                draft_id=state["draft_id"],
                revision=1,
                format="pdf",
            )["structuredContent"]
            receipt["sha256"] = digest(Path(receipt["path"]).read_bytes())
            write(d / "export.json", receipt)
    detail, checks = packet(d)
    guide_path = (
        Path(__file__).resolve().parents[2]
        / "crates/panache-mcp/evidence-guide-v2.json"
    )
    guide = read(guide_path)
    prompt = (
        BRIEF
        + "\n请独立复查同一稿件并决定下一动作。前两张是真实两页整稿，其后六张按 upper_text、printed_table、equation、flowchart、embedded_wave、conclusion 顺序，每张左侧为同处原纸、右侧为写入笔迹，均原尺寸。请复述公式分子、分母和结果，逐项区分成图中实际看见的现象和测量提示，记录仍无法确认的方面。你可选择只试一次可逆的新渲染再与原稿对比，也可保留或暂缓。新工具 tune_handwriting 的 photo_ink_light 取 0..100，表示让新增墨响应纸面局部亮度的混合量；photo_ink_focus 为 {from:{x,y,sigma_px},to:{x,y,sigma_px}}，坐标 0..1，σ0..2照片像素，仅影响新墨层。两项可独立设置或共同使用。不必强行让墨色与纸印一致。输出 JSON {action:try或keep或stop,changes:{},reason,observations,expected}；选择 try 要自行确定方向、数值和要保护的区域。不要执行工具。"
    )
    relevant = {
        k: guide["checks"][k]
        for k in ("formula_rendering", "mixed_content_projection", "focus_and_contrast")
    }
    prompt += (
        "\n验收依据："
        + json.dumps(relevant, ensure_ascii=False)
        + "\n本稿原纸与成图测量："
        + json.dumps(checks, ensure_ascii=False)
    )
    r = opinion(
        folder / "guided", prompt, [d / f"page-{p['page']}.png" for p in pages] + detail
    )
    write(
        folder / "guidance.json",
        {
            "version": guide["version"],
            "guide_sha256": digest(guide_path.read_bytes()),
            "response": r,
        },
    )
    print(r, flush=True)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("stage", choices=["first", "guided"])
    cli.add_argument("--out", required=True, type=Path)
    for name in ("binary", "worker", "fonts", "photo", "probe"):
        cli.add_argument("--" + name, type=Path)
    args = cli.parse_args()
    if args.stage == "first":
        first(args)
    else:
        guided(args)
