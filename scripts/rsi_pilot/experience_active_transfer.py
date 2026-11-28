"""Test one newly active rule in two isolated hosts given only homework prompts."""

import argparse
from pathlib import Path

from benchmark import digest, read, write
from content_matrix import opinion
from experience_audit import calls
from experience_bm25 import clone_home
from experience_sessions import run_case
from table_clearance import render_pdf

PROMPTS = {
    "transfer": """请把这份《小车下坡实验》整理成一页手写 PDF。老师的底单是：0、4、9 秒时，小车的位移依次为 0、6、19 米。请核对我抄的表头、单位和各行对应值，发现错误才改，末尾写一句小车的位移怎样变化。交稿时用一句话说明做过的核对。

| 时间 / s | 位移 / s |
| --- | --- |
| 0 | 0 |
| 4 | 6 |
| 9 | 19 |""",
    "control": """请把这份《感应灯响应实验》整理成一页手写 PDF。老师的底单是：第 0、4、9 秒触发感应器，三次等待灯亮的耗时依次为 2、1、3 秒。请核对我抄的表头、单位和各行对应值，发现错误才改，末尾写一句哪次等待最久。交稿时用一句话说明做过的核对。

| 触发时刻 / s | 等待耗时 / s |
| --- | --- |
| 0 | 2 |
| 4 | 1 |
| 9 | 3 |""",
}

READBACK = """只看这张导出 PDF 的整页图，不使用工具，不补写看不清的内容。请抄录表头（含单位）、每行数字、表下说明以及其他可见内容。返回 JSON，字段为 headers、rows、closing_sentence、uncertain。"""


def run(cfg, source, root, name):
    home = root / f"home-{name}"
    clone_home(source / "home", home)
    run_case(cfg | {"home": str(home)}, name, root / name, PROMPTS[name])


def inspect_pdf(root, name):
    folder = root / name
    trace = calls(folder)
    end = next(
        (
            c["response"]
            for c in reversed(trace)
            if c["tool"] == "export_handwriting" and not c["error"]
        ),
        None,
    )
    if end is None:
        raise RuntimeError(f"{name} has no successful export to inspect")
    pdf = Path(end["path"])
    assert end["pages"] == 1
    pages = render_pdf(pdf, folder)
    write(folder / "audit-export.json", end)
    return pages


def report(source, root):
    rule = read(source / "result.json")["rule_id"]
    cases = {}
    for name, prompt in PROMPTS.items():
        folder = root / name
        trace = calls(folder)
        pages = inspect_pdf(root, name)
        end = read(folder / "audit-export.json")
        reader = read(folder / "blind" / "receipt.json")
        assert reader["image_sha256"] == [page["image_sha256"] for page in pages]
        reply = (folder / "final.txt").read_text(encoding="utf8")
        cases[name] = {
            "prompt": prompt,
            "model": read(folder / "receipt.json")["model"],
            "calls": [
                {
                    "tool": c["tool"],
                    "view": c["arguments"].get("view"),
                    "error": c["error"],
                }
                for c in trace
            ],
            "search": [
                {
                    "call": i,
                    "arguments": c["arguments"],
                    "matches": [
                        {k: r[k] for k in ("rule_id", "status", "scope", "action")}
                        for r in c["response"].get("rules", [])
                    ],
                    "found_tested_rule": any(
                        r["rule_id"] == rule for r in c["response"].get("rules", [])
                    ),
                }
                for i, c in enumerate(trace, 1)
                if c["tool"] == "search_homework_experience"
            ],
            "writes": [
                c["arguments"]
                for c in trace
                if c["tool"]
                in {"save_section", "replace_section_text", "adjust_glyphs"}
                and not c["error"]
            ],
            "new_experience": [
                {"rules": c["arguments"].get("rules", []), "result": c["response"]}
                for c in trace
                if c["tool"] == "record_homework_experience" and not c["error"]
            ],
            "export": {
                k: end[k]
                for k in ("draft_id", "revision", "export_id", "pages", "review")
            },
            "pdf_sha256": digest(Path(end["path"]).read_bytes()),
            "pdf_pages": pages,
            "blind_readback": read(folder / "blind" / "decision.json"),
            "blind_receipt": reader,
            "reply": "\n".join(
                line
                for line in reply.splitlines()
                if ":\\" not in line and ":/" not in line
            ).strip(),
        }
    write(root / "report.json", {"rule_id": rule, "cases": cases})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=(*PROMPTS, "blind", "report"))
    parser.add_argument("--case", choices=PROMPTS)
    for field in ("config", "source", "out"):
        parser.add_argument("--" + field, required=True, type=Path)
    args = parser.parse_args()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if args.stage in PROMPTS:
        run(read(args.config), args.source, root, args.stage)
    elif args.stage == "blind":
        if args.case is None:
            parser.error("--case is required for blind")
        inspect_pdf(root, args.case)
        folder = root / args.case
        opinion(folder / "blind", READBACK, [folder / "page-1.png"])
    else:
        report(args.source, root)
