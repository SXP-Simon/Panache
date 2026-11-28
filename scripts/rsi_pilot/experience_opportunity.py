"""Trace validation offers during ordinary homework in independent MCP hosts."""

import argparse
import json
from pathlib import Path

from benchmark import Server, digest, read, write
from experience_audit import calls
from experience_bm25 import table
from experience_sessions import run_case
from experience_validation import invoke
from table_clearance import render_pdf

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("stage", choices=("seed", "positive", "boundary", "report"))
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--config", type=Path, required=True)
args = parser.parse_args()
ROOT = args.out.resolve()
HOME = ROOT / "home"
RUNTIME = read(args.config) | {"home": str(HOME)}
ROOT.mkdir(parents=True, exist_ok=True)


def lookup(s):
    return invoke(
        s, "search_homework_experience", tags=["table"], query="位移单位米表头"
    )["rules"]


def make(s, label, body):
    return invoke(
        s, "save_section", markdown=body, title=label, style={"homework": True}
    )


def review(s, key):
    r = invoke(s, "preview_handwriting", **key, view="review", section=1, page=1)
    return {"revision": r["revision"], "review_id": r["review_id"]}


def tab(rows, wrong=False):
    t = table(rows)
    return t.replace("位移 / m", "位移 / s") if wrong else t


def initialize():
    HOME.mkdir()
    with Server(RUNTIME, HOME, "seed", log_dir=ROOT) as s:
        rows = [(0, 0), (3, 8), (6, 17)]
        doc = make(s, "上次作业", tab(rows, True))
        base = {"draft_id": doc["draft_id"]}
        before = review(s, base | {"revision": 1})
        invoke(
            s,
            "save_section",
            **base,
            section=1,
            expected_revision=1,
            markdown=tab(rows),
        )
        key = base | {"revision": 2}
        after = review(s, key)
        end = invoke(s, "export_handwriting", **key, format="pdf")
        rule = invoke(
            s,
            "record_homework_experience",
            **key,
            export_id=end["export_id"],
            rules=[
                {
                    "tags": ["table"],
                    "scope": "两列表格记录时间和位移，位移已经说明用米，表头单位却误写成秒。",
                    "action": "只把位移表头的单位换成 m，保留原有每一行的时间及位移。若表头原本已是 m，保留原表。",
                    "reason": "成稿上位移的表头被误写成 s，第 2 版改成 m 后各行数据保持不变。",
                    "reviews": [before, after],
                }
            ],
        )["rules"][0]
        assert rule["status"] == "pending" and lookup(s) == []
        a = make(s, "斜面小车记录", tab([(0, 0), (2, 5), (4, 11)], True))
        b = make(s, "直道小车记录", tab([(0, 0), (1, 2), (5, 10)]))
        assert "experience_validation" not in a and "experience_validation" not in b
        # An export without already-filed review evidence must remain an ordinary export.
        assert "experience_validation" not in invoke(
            s, "export_handwriting", draft_id=b["draft_id"], format="pdf"
        )
        write(
            ROOT / "seed.json",
            {
                "rule_id": rule["rule_id"],
                "positive": a["draft_id"],
                "boundary": b["draft_id"],
            },
        )


def actor(name):
    keys = read(ROOT / "seed.json")
    title, data = (
        ("斜面小车记录", "0、2、4 秒的位移分别是 0、5、11 米")
        if name == "positive"
        else ("直道小车记录", "0、1、5 秒的位移分别是 0、2、10 米")
    )
    prompt = f"请用 Panache 核对我保存的《{title}》（草稿 {keys[name]}）。实验底单上，{data}。做成一页手写 PDF，核对表头及数据，能原样交就原样交，发现写错才改。"
    run_case(RUNTIME, name, ROOT / name, prompt)


def receipt():
    names = ["positive", "boundary"]
    keys = read(ROOT / "seed.json")
    results = {}
    for name in names:
        folder = ROOT / name
        trace = calls(folder)
        ex = next(
            c
            for c in reversed(trace)
            if c["tool"] == "export_handwriting" and not c["error"]
        )
        out = ex["response"]
        candidate = out["experience_validation"]
        assert candidate["read_candidate"]["arguments"]["rule_id"] == keys["rule_id"]
        assert all(
            "experience_validation" not in c["response"]
            for c in trace[: trace.index(ex)]
        )
        assert all(
            c["tool"]
            not in {
                "save_section",
                "replace_section_text",
                "tune_handwriting",
                "adjust_glyphs",
                "export_handwriting",
                "preview_handwriting",
            }
            for c in trace[trace.index(ex) + 1 :]
        )
        searches = [
            c
            for c in trace[: trace.index(ex)]
            if c["tool"] == "search_homework_experience" and not c["error"]
        ]
        assert all(
            keys["rule_id"] not in [r["rule_id"] for r in c["response"]["rules"]]
            for c in searches
        )
        wire = (
            json.loads(line)["payload"].get("result", {})
            for line in (folder / "wire.jsonl").read_text(encoding="utf8").splitlines()
        )
        export_result = next(
            r
            for r in wire
            if r.get("structuredContent", {}).get("export_id") == out["export_id"]
        )
        (attached,) = (
            block["resource"]["blob"]["sha256"]
            for block in export_result["content"]
            if block["type"] == "resource"
        )
        pdf = Path(out["path"])
        assert digest(pdf.read_bytes()) == attached
        files = render_pdf(pdf, folder)
        validation = [
            {
                "arguments": c["arguments"],
                "response": c["response"],
                "error": c["error"],
            }
            for c in trace
            if c["tool"] == "validate_homework_experience"
        ]
        results[name] = {
            "prompt": (folder / "prompt.txt").read_text(encoding="utf8"),
            "offers": candidate,
            "calls": [
                {
                    "tool": c["tool"],
                    "view": c["arguments"].get("view"),
                    "error": c["error"],
                }
                for c in trace
            ],
            "validation": validation,
            "searches_before_export": len(searches),
            "draft_id": out["draft_id"],
            "revision": out["revision"],
            "pages": files,
            "pdf_sha256": attached,
            "published_file_matches_export_attachment": True,
        }
    with Server(RUNTIME, HOME, "confirm", log_dir=ROOT) as s:
        active = {
            mode: [
                r["rule_id"]
                for r in invoke(s, "search_homework_experience", **query)["rules"]
            ]
            for mode, query in {
                "bm25": {"query": "位移单位米表头"},
                "tags": {"tags": ["table"]},
            }.items()
        }
        result = invoke(s, "read_homework_experience", rule_id=keys["rule_id"])
    write(
        ROOT / "result.json",
        {
            "model": read(ROOT / "positive" / "receipt.json")["model"],
            "rule_id": keys["rule_id"],
            "cases": results,
            "status": result["status"],
            "recorded_validation_order": [
                {"kind": c["kind"], "passed": c["passed"], "draft_id": c["draft_id"]}
                for c in result["cases"]
                if c["kind"] != "source"
            ],
            "active_search_ids": active,
        },
    )


if args.stage == "seed":
    initialize()
elif args.stage == "report":
    receipt()
else:
    actor(args.stage)
