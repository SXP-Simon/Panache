"""Drive one prepared native MCP task with a host-side Codex visual decision model.

python scripts/rsi_pilot/run_episode.py --out RUN --paper public-depth --arm B
Each turn is a fresh model context with only the task, pinned rules, actually
returned observations and selected image attachments. The private scorer stays
outside this process. Re-running resumes at the first undispatched decision.
"""

import argparse
import json
from pathlib import Path
from types import SimpleNamespace

import benchmark
from codex_judge import run

CONTRACT = """你是 Panache 的宿主决策模型。只看提供的任务、图像、工具回执与当前策略。
first attachment 是当前修订的整页拼图，第二张为细节。其后附图按证据目录解释。
在顶层给出 JSON 对象，含 action、reason、expected。每次只执行一个动作。
request_evidence 支持 tool=native_crop（arguments 指定 section:1或2、page_in_section 从1起、box:[x0,y0,x1,y1] 为该单页的0至1坐标），或 tool=detect_guides（arguments:{}，检测原图横线）。
revise 用 tool=tune_handwriting。arguments 可含 changes，例如 {"changes":{"font_size":32}}。
可以按需调节 font_size、line_spacing、ink_opacity 或 ink_softness；需要时使用 describe_controls 查询真实控件。
测得原纸坐标后可以使用 {"paper_guides":"$detected","changes":{}}。请保持原稿文字及底纸。
select 时用顶层 revision 指定要交付的已看修订号。stop 表示暂缓交付并说明原因。
共可采取四次非终止动作，最后一次只能 select 或 stop。报错也消耗一次。每次决定均给出可核查的依据。
本轮不使用任何文件或网络工具。在输出中只写 JSON。"""


def context(folder, state, compare_physical_fit=False):
    rev = state["revision"]
    directory = folder / f"r{rev}"
    images = [directory / "overview.jpg", directory / "detail.jpg"]
    previous = []
    for record in state["decisions"]:
        info = {
            k: record[k]
            for k in ("step", "revision", "raw", "result_revision", "error")
            if k in record
        }
        step_dir = folder / f"step-{record['step']}"
        for path in sorted(step_dir.glob("image-*.png")):
            images.append(path)
            info.setdefault("attachments", []).append(len(images))
        guides = step_dir / "guides.json"
        if guides.exists():
            info["detected_guides"] = benchmark.read(guides)
        meta = step_dir / "metadata.json"
        if meta.exists() and record["raw"].get("tool") == "describe_controls":
            info["controls"] = benchmark.read(meta)
        previous.append(info)
    other = []
    for version in state["snapshots"]:
        if int(version) != rev:
            for name in ("overview.jpg", "detail.jpg"):
                images.append(folder / f"r{version}" / name)
                other.append({"revision": int(version), "attachment": len(images)})
    # The first pass exposes only existing MCP measurements. If the actor
    # asks to detect guides, measure against those independently estimated
    # lines. The manually checked evaluation labels are never loaded.
    pages = state["snapshots"][str(rev)]
    measurements = []
    detected = next(
        (
            row["detected_guides"]
            for row in reversed(previous)
            if row.get("detected_guides")
        ),
        [],
    )
    refs = None
    if len(detected) >= 2:
        xs = [round(state["size"][0] * f) for f in (0.2, 0.5, 0.8)]
        rows = []
        for guide in detected:
            x1, y1 = guide["left"]
            x2, y2 = guide["right"]
            rows.append([y1 + (x - x1) * (y2 - y1) / (x2 - x1) for x in xs])
        refs = {"xs": xs, "rows": rows}
    for page in pages:
        prefix = f"s{page['section']}p{page['page']}"
        observed = benchmark.read(directory / f"{prefix}-review.json")["evidence"]
        m = {
            "section": page["section"],
            "page": page["page"],
            "printed_ridge_top_middle_bottom": observed[
                "nearby_dark_ridge_by_image_third"
            ],
        }
        if refs:
            from paper_geometry import score_layout

            score = score_layout(
                refs, benchmark.read(directory / f"{prefix}-glyphs.json")
            )
            m["vs_detected_lines_estimate"] = {
                k: score[k] for k in ("coverage", "p90_abs_rows", "within_quarter_row")
            }
            if compare_physical_fit:
                from prospective_papers import required_rows_for
                from ruling_fit import diagnose_page

                requirements = required_rows_for(
                    state["paper"], page["section"], page["page"]
                )
                measured = diagnose_page(
                    refs,
                    benchmark.read(directory / f"{prefix}-glyphs.json"),
                    required_rows=requirements,
                )
                m["vs_nearest_detected_ruling_p90_rows"] = measured[
                    "nearest_p90_abs_rows"
                ]
                m["unused_interior_rulings"] = measured["interior_unused_rows"]
                m["explicitly_requested_slots"] = measured["required_assignments"]
        measurements.append(m)
    task = state["task"]
    data = {
        "objective": task["objective"],
        "source": benchmark.sections_for(state["paper"]),
        "mcp_measurements": measurements,
        "rules": task["rules"],
        "current_revision": rev,
        "page_order": [[p["section"], p["page"]] for p in state["snapshots"][str(rev)]],
        "prior_decisions": previous,
        "other_candidates": other,
        "nonterminal_remaining": 4 - len(previous),
    }
    return CONTRACT + "\n" + json.dumps(data, ensure_ascii=False), images


def solve(out, paper, arm, model, compare_physical_fit=False):
    folder = out / paper / arm
    while True:
        state = benchmark.read(folder / "state.json")
        if state.get("disposition"):
            return
        if not state.get("task"):
            raise ValueError("Initialize the native task first.")
        number = len(state["decisions"]) + 1
        if number > 5:
            raise ValueError("Decision budget has been exhausted.")
        base = folder / f"turn-{number}"
        prompt, images = context(folder, state, compare_physical_fit)
        path = base / "decision.json"
        if not (base / "receipt.json").exists():
            prompt_file = folder / f"input-{number}.txt"
            prompt_file.write_text(prompt, encoding="utf-8")
            run(prompt_file, images, model, base)
        benchmark.advance(SimpleNamespace(out=out, paper=paper, arm=arm, decision=path))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--paper", required=True)
    parser.add_argument("--arm", required=True)
    parser.add_argument(
        "--model", default="gpt-6.1-terra", choices=["gpt-6.1-terra", "gpt-6-luna"]
    )
    parser.add_argument(
        "--compare-physical-fit",
        action="store_true",
        help="Include both contiguous and nearest-line estimates plus explicit targets on transfer tasks.",
    )
    args = parser.parse_args()
    solve(
        args.out.resolve(), args.paper, args.arm, args.model, args.compare_physical_fit
    )
