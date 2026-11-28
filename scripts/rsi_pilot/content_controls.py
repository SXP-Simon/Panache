"""Blinded, intentionally defective controls for native homework review.

Run separately from the natural content matrix. Inputs are its frozen manifest,
public paper and two Terra-authored Markdown files. Each first visual judge sees
only the public brief and a newly named copy of the actual MCP full-page PNG.
"""

import argparse
import re
import shutil
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory

import numpy as np
from benchmark import Server, digest, read, write
from content_matrix import MODEL, opinion, pages, render_first, take_snapshot
from PIL import Image

NAMES = ("table1", "flow1")
VISUAL = """你是独立手写作业验收者。只依据题面和随附的实际整页成稿，检查各项事实与可读性。不得调用工具、搜索或打开文件。只返回 JSON 对象，action 为 accept 或 repair；看不清且不能确认交付时用 repair。reason 引述页上看到的具体内容，无法辨认时如实说明。"""
REPAIR = """你负责修订手写作业。依据题面、当前完整 Markdown 和上轮对成稿的具体观察，作必要的最小修订，保持现有可用的排版与语法。只输出 JSON 对象，markdown 为修订后的完整原文，reason 解释具体改动。请勿调用任何工具。"""


def mutate(name, source):
    if name == "table1":
        old, new = "| 2 | 6 |", "| 2 | 8 |"
        if source.count(old) != 1:
            raise ValueError("Unexpected archived table source")
        return source.replace(old, new)
    labels = re.compile(r"(node\[midway,[^\]]+\]\{)(是|否)(\};)")
    changed, n = labels.subn(
        lambda m: m[1] + {"是": "否", "否": "是"}[m[2]] + m[3], source
    )
    if n != 2:
        raise ValueError("Expected two distinct conditional labels")
    return changed


def facts(name, source):
    """Extract table pairs or map circuitikz coordinates back to named endpoints."""
    if name == "table1":
        pairs = re.findall(r"\|\s*(\d+)\s*\|\s*(\d+)\s*\|", source)
        return {
            "table_rows": [list(pair) for pair in pairs],
            "target_value_at_t_2": next((x for t, x in pairs if t == "2"), None),
        }
    ids = {
        tuple(re.sub(r"\s+", "", point).split(",")): value
        for point, value in re.findall(
            r"\\draw\s*\(([^)]+)\)\s*node\[[^\]]+\]\s*\{([^}]+)\}", source
        )
    }
    edges = []
    for a, b, label in re.findall(
        r"\\draw\s*\[->\]\s*\(([^)]+)\)\s*--\s*\(([^)]+)\)(?:\s*node\[[^\]]*\]\s*\{([^}]+)\})?\s*;",
        source,
    ):
        a, b = [tuple(re.sub(r"\s+", "", s).split(",")) for s in (a, b)]
        edges.append([ids.get(a, "?"), ids.get(b, "?"), label])
    return {"nodes": sorted(ids.values()), "edges": sorted(edges)}


def check_specific(name, measured, case):
    if name == "table1":
        return measured["table_rows"] == case["tables"][0]
    graph = case["graphs"][0]
    return measured["nodes"] == sorted(graph["nodes"]) and measured["edges"] == sorted(
        graph["edges"]
    )


def visual(folder, brief, page_paths):
    with TemporaryDirectory() as temp:
        copies = []
        for n, page in enumerate(page_paths, 1):
            path = Path(temp) / f"page-{n}.png"
            shutil.copyfile(page, path)
            copies.append(path)
        result = opinion(folder, VISUAL + "\n\n题面：" + brief, copies)
    if result.get("action") not in ("accept", "repair"):
        raise ValueError("Invalid visual decision")
    return result


def raster_pair(before, after):
    with Image.open(before) as im:
        a = np.asarray(im.convert("RGB"), dtype=np.int16)
    with Image.open(after) as im:
        b = np.asarray(im.convert("RGB"), dtype=np.int16)
    if a.shape != b.shape:
        raise ValueError("Native raster size changed")
    y, x = np.nonzero(np.max(np.abs(a - b), axis=2) >= 12)
    return {
        "threshold_8bit": 12,
        "changed_pixels": len(x),
        "bbox_xyxy_inclusive": [int(x.min()), int(y.min()), int(x.max()), int(y.max())]
        if len(x)
        else None,
    }


def run_case(source_root, out, name, manifest):
    folder = out / name
    folder.mkdir(exist_ok=True)
    case = manifest["cases"][name]
    original = (source_root / name / "r1" / "source.md").read_text(encoding="utf-8")
    bad = mutate(name, original)
    if not check_specific(name, facts(name, original), case) or check_specific(
        name, facts(name, bad), case
    ):
        raise ValueError("Mutation did not yield the predefined defect")
    (folder / "author-original.md").write_text(original, encoding="utf-8")
    (folder / "first.md").write_text(bad, encoding="utf-8")
    (folder / "brief.txt").write_text(case["brief"], encoding="utf-8")
    render_first(out, name, case)
    state = read(folder / "state.json")
    rev = state["first_revision"]
    initial_pages = pages(folder, rev)
    first = visual(folder / "visual-1", case["brief"], initial_pages)
    results = {
        "case": name,
        "author_source_sha256": digest(original.encode()),
        "bad_source_sha256": digest(bad.encode()),
        "paper_sha256": manifest["paper_sha256"],
        "base_png_sha256": digest(
            (source_root / name / "r1" / "page-1.png").read_bytes()
        ),
        "initial_png_sha256": digest(initial_pages[0].read_bytes()),
        "initial_facts": facts(name, bad),
        "initial_prepared_facts": facts(
            name, (folder / f"r{rev}" / "prepared.txt").read_text(encoding="utf-8")
        ),
        "initial_vs_correct_author_raster": raster_pair(
            source_root / name / "r1" / "page-1.png", initial_pages[0]
        ),
        "blind_initial": first,
        "repairs_attempted": 0,
    }
    if first["action"] == "repair":
        draft = opinion(
            folder / "repair",
            REPAIR
            + "\n题面："
            + case["brief"]
            + "\n观察："
            + first["reason"]
            + "\n当前原文：\n"
            + bad,
            initial_pages,
        )
        corrected = draft["markdown"]
        next_rev = rev + 1
        if not (folder / f"r{next_rev}" / "pages.json").exists():
            with Server(
                manifest["runtime"], folder / "home", "control_repair", log_dir=folder
            ) as s:
                history = s.call("read_rsi_task", task_id=state["task_id"])[
                    "structuredContent"
                ]
                if not history["decisions"]:
                    history = s.call(
                        "advance_rsi_task",
                        task_id=state["task_id"],
                        expected_step=history["step"],
                        revision=rev,
                        action="revise",
                        tool="save_section",
                        reason=first["reason"],
                        instruction=draft["reason"],
                        review_ids=[
                            p["review_id"]
                            for p in read(folder / f"r{rev}" / "pages.json")
                        ],
                    )["structuredContent"]
                decision = history["decisions"][0]
                saved = decision["result_revision"]
                if saved is None:
                    saved = s.call(
                        "save_section",
                        draft_id=state["draft_id"],
                        expected_revision=rev,
                        section=1,
                        markdown=corrected,
                        rsi_decision_id=decision["decision_id"],
                    )["structuredContent"]["revision"]
                next_rev = saved
                take_snapshot(s, folder, state, next_rev)
        final_pages = pages(folder, next_rev)
        final_visual = visual(folder / "visual-2", case["brief"], final_pages)
        canonical = (folder / f"r{next_rev}" / "source.md").read_text(encoding="utf-8")
        prepared = (folder / f"r{next_rev}" / "prepared.txt").read_text(
            encoding="utf-8"
        )
        observed = facts(name, prepared)
        results.update(
            repairs_attempted=1,
            repair_reason=draft["reason"],
            final_revision=next_rev,
            final_sha256=digest(canonical.encode()),
            final_png_sha256=digest(final_pages[0].read_bytes()),
            final_facts=facts(name, canonical),
            final_prepared_facts=observed,
            final_specific_fact_correct=check_specific(name, observed, case),
            initial_vs_final_raster=raster_pair(initial_pages[0], final_pages[0]),
            final_vs_correct_author_raster=raster_pair(
                source_root / name / "r1" / "page-1.png", final_pages[0]
            ),
            blind_final=final_visual,
        )
    else:
        results.update(final_revision=rev, final_specific_fact_correct=False)
    verdict = results.get("blind_final", first)
    final_revision = results["final_revision"]
    with Server(
        manifest["runtime"], folder / "home", "control_disposition", log_dir=folder
    ) as server:
        history = server.call("read_rsi_task", task_id=state["task_id"])[
            "structuredContent"
        ]
        if history["status"] == "active":
            final_refs = read(folder / f"r{final_revision}" / "pages.json")
            history = server.call(
                "advance_rsi_task",
                task_id=state["task_id"],
                expected_step=history["step"],
                revision=final_revision,
                action="select" if verdict["action"] == "accept" else "stop",
                reason=verdict["reason"],
                review_ids=[p["review_id"] for p in final_refs],
            )["structuredContent"]
        results["native_disposition"] = {
            "status": history["status"],
            "selected_revision": history["selected_revision"],
        }
    for turn in ("visual-1", "repair", "visual-2"):
        receipt = folder / turn / "receipt.json"
        if receipt.exists():
            info = read(receipt)
            results.setdefault("model_receipts", {})[turn] = {
                k: info[k] for k in ("model", "prompt_sha256", "image_sha256", "usage")
            }
    write(folder / "control-outcome.json", results)
    print(name, first["action"], results["final_specific_fact_correct"], flush=True)
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--result", type=Path, required=True)
    args = parser.parse_args()
    root = args.source_root.resolve()
    out = args.out.resolve()
    if out == root or out.is_relative_to(root):
        parser.error("Use a separate output directory")
    out.mkdir(parents=True, exist_ok=True)
    manifest = read(root / "manifest.json")
    for filename in ("manifest.json", "paper.png"):
        src, dst = root / filename, out / filename
        if dst.exists() and digest(src.read_bytes()) != digest(dst.read_bytes()):
            raise ValueError(
                "Frozen archived input changed; use a fresh output directory"
            )
        shutil.copyfile(src, dst)
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(
            pool.map(lambda name: run_case(root, out, name, manifest), NAMES)
        )
    write(
        args.result,
        {
            "scope": "Deliberately injected negative controls, separate from naturally authored pilot cases.",
            "blind_inputs": "User brief and full native PNG only.",
            "runtime_sha256": manifest["runtime"]["binary_sha256"],
            "model": MODEL,
            "cases": results,
        },
    )


if __name__ == "__main__":
    main()
