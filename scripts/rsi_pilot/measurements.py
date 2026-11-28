"""Summarize a local run without publishing its photos, image bytes, paths or model prompts.

Use after all requested native episodes have finished. Dependencies include Pillow, NumPy, SciPy and PyMuPDF. PyMuPDF checks each PDF's
embedded full-size image against the PNG reviewed by the actor.
"""

import argparse
import io
import json
import platform
from collections import Counter
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import PIL
import pymupdf
import scipy
from appearance import appearance
from benchmark import Server, digest, read, score, write
from paper_geometry import load_labels
from PIL import Image
from ruling_fit import diagnose_page


def verify_source(folder, state, revision):
    target = folder / f"r{revision}" / "source-fingerprints.json"
    if not target.exists():
        with Server(
            state["runtime"], Path(state["home"]), "evaluator", log_dir=folder
        ) as server:
            hashes = []
            for section in (1, 2):
                response = server.call(
                    "read_section",
                    draft_id=state["draft_id"],
                    section=section,
                    revision=revision,
                    view="source",
                    limit=4000,
                )["structuredContent"]
                if response["next_offset"] is not None:
                    raise ValueError("Section exceeds the benchmark source limit")
                hashes.append(digest(response["markdown"].encode()))
        write(target, hashes)
    return read(target) == state["section_sha256"]


def verify_pdf(folder, state):
    path = folder / "export.json"
    if not path.exists():
        if state["selected_revision"] is not None:
            raise ValueError(
                f"Missing selected PDF for {state['paper']}/{state['arm']}; run export-selected"
            )
        return None
    export = read(path)
    with pymupdf.open(export["path"]) as document:
        revision = export["revision"]
        assert revision == state["selected_revision"]
        assert export["draft_id"] == state["draft_id"]
        refs = state["snapshots"][str(revision)]
        assert document.page_count == export["pages"] == len(refs)
        errors = []
        for page, ref in zip(document, refs, strict=True):
            images = page.get_images(full=True)
            if len(images) != 1:
                raise ValueError("Expected one embedded page image")
            raw = document.extract_image(images[0][0])["image"]
            with (
                Image.open(io.BytesIO(raw)) as embedded,
                Image.open(folder / f"r{revision}" / ref["image"]) as png,
            ):
                assert embedded.size == png.size
                difference = np.asarray(
                    embedded.convert("RGB"), dtype=np.int16
                ) - np.asarray(png.convert("RGB"))
                errors.append(int(np.abs(difference).max()))
        return {
            "sha256": digest(Path(export["path"]).read_bytes()),
            "pages": len(refs),
            "revision": revision,
            "max_channel_error_vs_reviewed_png_by_page": errors,
        }


def costs(log):
    phases = {}
    for line in log.read_text(encoding="utf-8").splitlines():
        entry = json.loads(line)
        name = entry.get("name", entry["method"])
        phase = phases.setdefault(
            entry["phase"],
            {
                "requests": 0,
                "tools": Counter(),
                "failures": 0,
                "request_bytes": 0,
                "response_bytes": 0,
                "server_roundtrip_seconds": 0.0,
            },
        )
        phase["requests"] += 1
        phase["tools"][name] += 1
        phase["failures"] += bool(entry["error"])
        phase["request_bytes"] += entry["request_bytes"]
        phase["response_bytes"] += entry["response_bytes"]
        phase["server_roundtrip_seconds"] += entry["seconds"]
    for phase in phases.values():
        phase["server_roundtrip_seconds"] = round(phase["server_roundtrip_seconds"], 3)
    return phases


def arm_summary(out, paper, arm):
    folder = out / paper / arm
    state = read(folder / "state.json")
    if not state.get("disposition"):
        raise ValueError(f"Open task {paper}/{arm}")
    score(SimpleNamespace(out=out, paper=paper, arm=arm))
    candidates = []
    labels = load_labels(paper)
    for version, pages in state["snapshots"].items():
        item = {
            "revision": int(version),
            "source_sections_unchanged": verify_source(folder, state, int(version)),
            "physical_pages": len(pages),
            "pages": [],
        }
        for ref in pages:
            tag = f"s{ref['section']}p{ref['page']}"
            directory = folder / f"r{version}"
            measurements = read(directory / f"{tag}-score.json")
            glyphs = read(directory / f"{tag}-glyphs.json")
            measurements["appearance"] = appearance(
                directory, ref, read(directory / f"{tag}-review.json"), glyphs
            )
            measurements["posthoc_physical_ruling_fit"] = diagnose_page(
                labels,
                glyphs,
                background=directory / "paper.png",
                rendered=directory / ref["image"],
            )
            item["pages"].append(
                {
                    k: ref[k]
                    for k in ("section", "page", "sha256", "review_id", "glyphs")
                }
                | measurements
            )
        candidates.append(item)
    task = state.get("task", {})
    return {
        "draft_id": state["draft_id"],
        "policy_id": task.get("policy_id"),
        "task_id": task.get("task_id"),
        "status": state["disposition"],
        "selected_revision": state["selected_revision"],
        "model_decisions": len(state["decisions"]),
        "failed_dispatches": sum("error" in r for r in state["decisions"]),
        "decision_ids": [
            r["decision_id"] for r in state["decisions"] if "decision_id" in r
        ],
        "candidates": candidates,
        "delivered_pdf": verify_pdf(folder, state),
        "cost_by_phase": costs(folder / "calls.jsonl"),
    }


def collect(out):
    cases = []
    binary = None
    for path in sorted(out.glob("*/seed.json")):
        state = read(path)
        folder, paper = path.parent, state["paper"]
        arms = {}
        for arm in ("A", "D") if state["split"] == "development" else ("A", "B", "C"):
            arms[arm] = arm_summary(out, paper, arm)
            runtime = read(folder / arm / "state.json")["runtime"]
            if binary and binary != runtime["binary_sha256"]:
                raise ValueError("Native binary changed between arms")
            binary = runtime["binary_sha256"]
        baseline = [r["sha256"] for r in arms["A"]["candidates"][0]["pages"]]
        for arm in arms.values():
            if baseline != [p["sha256"] for p in arm["candidates"][0]["pages"]]:
                raise ValueError(f"Unmatched starting revision: {paper}")
        cases.append(
            {
                k: state[k]
                for k in ("paper", "sha256", "size", "section_sha256", "split")
            }
            | {"arms": arms}
        )
    return {
        "schema": 3,
        "python": platform.python_version(),
        "pillow": PIL.__version__,
        "numpy": np.__version__,
        "scipy": scipy.__version__,
        "pymupdf": pymupdf.VersionBind,
        "native_binary_sha256": binary,
        "worker_sha256": runtime["worker_sha256"],
        "font": "李国夫手写体.ttf",
        "font_sha256": runtime["font_hashes"]["李国夫手写体.ttf"],
        "seed": 24719,
        "creation_style": {"font_size": 36, "paper_mode": "photo", "homework": False},
        "notes": [
            "Appearance includes original MCP paper focus and local contrast. The post-hoc native-pixel proxy samples vertical profiles every 8px in each image third. It compares the 20–80% transition of isolated paper-minus-render writing strokes in glyph quads with nearby print in half-glyph-height expanded bounds. Minimum prominence 12/255, maximum width 22px, maximum flat plateau 20px, 45px prominence window, minimum 6 peaks. Stroke angle, material, thickness and shot noise can alter this proxy. Absent writing support stays null; it is not an authenticity score.",
            "posthoc_physical_ruling_fit was added after observing that legitimate blank rows can inflate the preregistered consecutive-row metric. Its nearest-ruling fit cannot alone detect placement on a wrong row.",
            "Per-page data are repeated measures. Source identity and template define independent groups.",
            "A exports the immutable starting revision shared with its paired native task; A does not pay twice for preparation. See shared_fixture for the paired task's preparation.",
            "Rendering, evaluator instrumentation and host decision dispatch have separate costs. JSON-RPC initialize is counted; the one-way initialized notification is excluded.",
            "A stopped actor withholds delivery and has no selected PDF. For audit its last known draft is available locally.",
            "Measurements check content equality and native endpoint geometry. Missing geometry and unoccupied depth bands remain null.",
        ],
        "cases": cases,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("report", type=Path)
    args = parser.parse_args()
    write(args.report, collect(args.out.resolve()))
