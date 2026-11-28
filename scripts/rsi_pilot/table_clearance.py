"""Render archived homework revisions through a native MCP build and compare the exported PDF pages."""

import argparse
import json
from pathlib import Path

import pymupdf
from benchmark import Server, digest, read, write
from experience_audit import calls as host_calls
from experience_bm25 import clone_home
from experience_validation import invoke


def render_pdf(pdf, folder):
    pages = []
    with pymupdf.open(pdf) as doc:
        for number, page in enumerate(doc, 1):
            # Panache embeds each rendered page as a single image. Rasterize the
            # PDF page itself at that resolution, including its page transform.
            (image,) = page.get_images()
            width, height = image[2:4]
            matrix = pymupdf.Matrix(width / page.rect.width, height / page.rect.height)
            pix = page.get_pixmap(matrix=matrix, alpha=False)
            path = folder / f"page-{number}.png"
            pix.save(path)
            pages.append(
                {
                    "size": [pix.width, pix.height],
                    "pixels_sha256": digest(pix.samples),
                    "image_sha256": digest(path.read_bytes()),
                }
            )
    return pages


def compare_build(cfg, corpus, scope, root, arm):
    cases = {}
    for name in ("overlap", "clear_table", "text", "standalone_table"):
        if name == "clear_table":
            home = corpus / "home-table"
            receipt = next(
                c["response"]
                for c in reversed(host_calls(corpus / "session-table"))
                if c["tool"] == "export_handwriting" and not c["error"]
            )
        elif name == "standalone_table":
            home = Path(read(corpus / "config.json")["home"])
            receipt = read(corpus / "receipts.json")["table"]["boundary"]
        else:
            case = scope / ("mixed" if name == "overlap" else "text")
            home = case / "home"
            receipt = read(case / "audit.json")["export"]
        folder = root / arm / name
        folder.mkdir(parents=True, exist_ok=False)
        clone_home(home, folder / "home")
        key = {k: receipt[k] for k in ("draft_id", "revision")}
        with Server(cfg, folder / "home", arm, log_dir=folder) as server:
            response = server.call(
                "preview_handwriting", **key, view="review", section=1, page=1
            )
            review = response["structuredContent"]
            export = invoke(server, "export_handwriting", **key, format="pdf")
        pdf = Path(export["path"])
        calls = [
            json.loads(line)
            for line in (folder / "calls.jsonl").read_text(encoding="utf8").splitlines()
        ]
        cases[name] = {
            "draft": key,
            "calls": [c["name"] for c in calls if c["method"] == "tools/call"],
            "review_images": sum(
                block["type"] == "image" for block in response["content"]
            ),
            "next_step": review["next_step"],
            "table_clearance_check": review.get("table_clearance_check"),
            "unreviewed_pages": export["review"]["unreviewed_pages"],
            "pdf_sha256": digest(pdf.read_bytes()),
            "pages": render_pdf(pdf, folder),
        }
    write(
        root / (arm + ".json"),
        {"binary_sha256": digest(Path(cfg["binary"]).read_bytes()), "cases": cases},
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("arm", choices=["before", "after"])
    for key in ("config", "corpus", "scope", "out"):
        parser.add_argument("--" + key, type=Path, required=True)
    args = parser.parse_args()
    compare_build(read(args.config), args.corpus, args.scope, args.out, args.arm)
