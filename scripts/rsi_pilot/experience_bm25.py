"""Compare Chinese assignment text and legacy topics using native MCP in an isolated copy."""

import argparse
import shutil
import sqlite3
from pathlib import Path

import pymupdf
from benchmark import Server, digest, read, save_image, write
from content_matrix import CASES
from experience_audit import calls
from experience_output import native_content
from experience_sessions import run_case
from experience_validation import invoke
from PIL import Image

FORMULA_ID = "485fb830-e4ac-46b2-b2a1-b03f4cfbf424"
RULES = {
    "table": {
        "tags": ["table"],
        "scope": "两列表格有多个观测时刻，每一行都要对应正确的观测值。",
        "action": "沿表头逐行核对同一时刻和位移的对应关系，单独检查中间行。",
        "reason": "表格中即使首尾数值正确，中间行也可能错填。",
    },
    "flow": {
        "tags": ["flowchart"],
        "scope": "带箭头的流程图要求用是、否两条分支连接不同的终点。",
        "action": "从条件节点沿箭头读到两端，分别核对是、否标签和终点，保留正确分支。",
        "reason": "节点文字可以全对，但两条分支的标签仍可能对调。",
    },
}
# Expected relevancy is fixed by the assignment intent, independent of hits.
CASES_ZH = {
    "chemistry": (
        "用旧教材做一页化学作业：24 g 盐水中有 3 g 盐。模板输入的旧分数命令要留给组员照抄，同页计算行要排成上下分数并写出百分数。请给我一页手写 PDF。",
        ["homework", "formula", "chemistry"],
        ["formula"],
    ),
    "table": (
        CASES["table1"]["brief"] + " 请交一页手写 PDF。",
        ["homework", "table", "formula"],
        ["table"],
    ),
    "flow": (
        CASES["flow1"]["brief"] + " 请交一页手写 PDF。",
        ["homework", "flowchart"],
        ["flow"],
    ),
    "two_flows": (CASES["flow2"]["brief"], ["homework", "flowchart"], ["flow"]),
    "mixed": (
        CASES["combined"]["brief"],
        ["homework", "table", "flowchart", "formula"],
        ["table", "flow"],
    ),
    "text": (CASES["text"]["brief"], ["homework"], []),
}


def table(rows):
    return "| 时间 / s | 位移 / m |\n|---|---|\n" + "\n".join(
        f"| {t} | {d} |" for t, d in rows
    )


def flow(nodes, labels):
    left, right = labels
    a, b, c, d = nodes
    return rf"""\begin{{circuitikz}}[flowchart]
\draw (0,0) node[rectangle]{{{a}}};
\draw (0,-2) node[diamond]{{{b}}};
\draw (-3,-4) node[rectangle]{{{c}}};
\draw (3,-4) node[rectangle]{{{d}}};
\draw[->] (0,0) -- (0,-2);
\draw[->] (0,-2) -- (-3,-4) node[midway,above left]{{{left}}};
\draw[->] (0,-2) -- (3,-4) node[midway,above right]{{{right}}};
\end{{circuitikz}}"""


def case_pages(s, folder, title, original, corrected=None):
    receipts = []
    draft_id = None
    for version, source in enumerate(
        [original] + ([corrected] if corrected else []), 1
    ):
        args = (
            {"title": title, "style": {"homework": True}}
            if draft_id is None
            else {
                "draft_id": draft_id,
                "expected_revision": version - 1,
                "section": 1,
            }
        )
        saved = invoke(s, "save_section", markdown=source, **args)
        draft_id = saved["draft_id"]
        key = {
            "draft_id": saved["draft_id"],
            "revision": version,
            "section": 1,
            "page": 1,
        }
        review = invoke(s, "preview_handwriting", **key, view="review")
        save_image(
            s.call("preview_handwriting", **key, view="image"),
            folder / f"{title}-{version}.png",
        )
        receipts.append({"review_id": review["review_id"], "revision": version})
    export = invoke(
        s,
        "export_handwriting",
        draft_id=key["draft_id"],
        revision=version,
        format="pdf",
    )
    return {k: export[k] for k in ("draft_id", "revision", "export_id")} | {
        "reviews": receipts
    }


def prepare(cfg, root, original):
    home = Path(cfg["home"])
    home.mkdir(parents=True, exist_ok=False)
    with (
        sqlite3.connect(
            (original / "drafts.sqlite3").resolve().as_uri() + "?mode=ro", uri=True
        ) as src,
        sqlite3.connect(home / "drafts.sqlite3") as dst,
    ):
        src.backup(dst)
    shutil.copytree(original / "exports", home / "exports")
    jobs = {
        "table": [
            (table([(0, 0), (2, 8), (4, 12)]), table([(0, 0), (2, 6), (4, 12)])),
            (table([(1, 5), (2, 15), (3, 15)]), table([(1, 5), (2, 10), (3, 15)])),
            (table([(0, 0), (2, 8), (4, 16)]),),
        ],
        "flow": [
            (
                flow(["验卷", "已署名", "收卷", "补签"], ["否", "是"]),
                flow(["验卷", "已署名", "收卷", "补签"], ["是", "否"]),
            ),
            (
                flow(["查书", "有库存", "借出", "预约"], ["否", "是"]),
                flow(["查书", "有库存", "借出", "预约"], ["是", "否"]),
            ),
            (flow(["测温", "超温", "报警", "保持"], ["是", "否"]),),
        ],
    }
    receipts = {}
    with Server(cfg, home, "prepare", log_dir=root) as s:
        for topic, work in jobs.items():
            receipts[topic] = {
                role: case_pages(s, root, topic + "-" + role, *pages)
                for role, pages in zip(
                    ["source", "positive", "boundary"], work, strict=True
                )
            }
    write(root / "receipts.json", receipts)


def validate(cfg, root):
    receipts = read(root / "receipts.json")
    ids = {"formula": FORMULA_ID}
    with Server(cfg, Path(cfg["home"]), "validate", log_dir=root) as s:
        for name, rule in RULES.items():
            samples = receipts[name]
            source = samples["source"].copy()
            rule_id = invoke(
                s,
                "record_homework_experience",
                **{k: v for k, v in source.items() if k != "reviews"},
                rules=[rule | {"reviews": source["reviews"]}],
            )["rules"][0]["rule_id"]
            for kind in ("positive", "boundary"):
                verdict = invoke(
                    s,
                    "validate_homework_experience",
                    **samples[kind],
                    rule_id=rule_id,
                    kind=kind,
                    passed=True,
                    reason=VERDICTS[name][kind],
                )
            assert verdict["status"] == "active"
            ids[name] = rule_id
    write(root / "ids.json", ids)


VERDICTS = {
    "table": {
        "positive": "核对同一行后第二个时刻由 15 修为 10，首末仍是 5 和 15。",
        "boundary": "另一张表位移依次为 0、8、16，中间行原本正确，可以保留。",
    },
    "flow": {
        "positive": "借书图沿箭头核对后，有库存的是分支到借出，否分支到预约。",
        "boundary": "测温图的是分支已经到报警，否分支到保持，两个终点都可保留。",
    },
}


def compare(cfg, root):
    ids = read(root / "ids.json")
    with sqlite3.connect(Path(cfg["home"]) / "drafts.sqlite3") as db:
        states = {
            r[0]: r[1] for r in db.execute("select id,status from experience_rules")
        }
        hidden = db.execute(
            "select id,status,scope,action from experience_rules where status!='active'"
        ).fetchall()

    def look(s, **args):
        rows = invoke(s, "search_homework_experience", **args)["rules"]
        assert all(states[r["rule_id"]] == "active" for r in rows)
        return [r["rule_id"] for r in rows]

    with Server(cfg, Path(cfg["home"]), "paired-queries", log_dir=root) as s:
        rows = [
            {
                "case": key,
                "prompt": prompt,
                "tags": tags,
                "expected": [ids[k] for k in target],
                "bm25": look(s, query=prompt),
                "tags_only": look(s, tags=tags),
                "combined": look(s, query=prompt, tags=tags),
            }
            for key, (prompt, tags, target) in CASES_ZH.items()
        ]
        probes = [
            {
                "id": i,
                "status": state,
                "query": scope + " " + action,
                "hits": look(s, query=scope + " " + action),
            }
            for i, state, scope, action in hidden
        ]
    assert all(r["id"] not in r["hits"] for r in probes)
    write(
        root / "comparison.json",
        {
            "ids": ids,
            "states": states,
            "queries": rows,
            "hidden_exact_text_probes": probes,
        },
    )


def session(cfg, root, name):
    # Each host sees the same starting library, including exactly the same hidden controls.
    session_home = root / ("home-" + name)
    session_home.mkdir(exist_ok=False)
    source = Path(cfg["home"])
    with (
        sqlite3.connect(
            (source / "drafts.sqlite3").resolve().as_uri() + "?mode=ro", uri=True
        ) as db,
        sqlite3.connect(session_home / "drafts.sqlite3") as clone,
    ):
        db.backup(clone)
    shutil.copytree(source / "exports", session_home / "exports")
    prompt = CASES_ZH["chemistry" if name == "chemistry_template" else name][0]
    if name == "chemistry_template":
        prompt += r" 这次要让同学照抄的原命令是 \nicefrac{3}{24}。"
    run_case(
        cfg | {"home": str(session_home)},
        name,
        root / ("session-" + name),
        prompt,
    )


def report(root, output):
    comparison = read(root / "comparison.json")
    actors = []
    assets = root / "public-assets"
    assets.mkdir(exist_ok=True)
    for name in ["chemistry", "table", "flow", "chemistry_template"]:
        folder = root / ("session-" + name)
        prompt = (folder / "prompt.txt").read_text(encoding="utf-8")
        trace = calls(folder)
        receipt = read(folder / "receipt.json")
        searches = []
        exports = []
        for index, call in enumerate(trace):
            if call["tool"] == "search_homework_experience":
                found = [r["rule_id"] for r in call["response"]["rules"]]
                assert all(comparison["states"][i] == "active" for i in found)
                query = call["arguments"].get("query", "")
                searches.append(
                    {
                        "call": index + 1,
                        "arguments": call["arguments"],
                        "returned": found,
                        "verbatim_prompt": query == prompt,
                        "same_wording_ignoring_whitespace": "".join(query.split())
                        == "".join(prompt.split()),
                        "verbatim_excerpt": bool(query) and query in prompt,
                    }
                )
            if call["tool"] == "export_handwriting" and not call.get("error"):
                r = call["response"]
                pdf_path = Path(r["path"])
                with pymupdf.open(pdf_path) as doc:
                    assert len(doc) == 1 and len(doc[0].get_images()) == 1
                    pix = pymupdf.Pixmap(doc, doc[0].get_images()[0][0])
                    img = Image.frombytes("RGB", (pix.width, pix.height), pix.samples)
                    target = assets / (name + "-pdf.png")
                    native_content(img).save(target)
                exports.append(
                    {
                        "revision": r["revision"],
                        "export_id": r["export_id"],
                        "pdf_sha256": digest(pdf_path.read_bytes()),
                        "page_pixels": [pix.width, pix.height],
                        "image": target.name,
                        "image_sha256": digest(target.read_bytes()),
                    }
                )
        actors.append(
            {
                "case": name,
                "prompt": prompt,
                "model": receipt["model"],
                "thread_ids": receipt["thread_ids"],
                "binary_sha256": receipt["binary_sha256"],
                "other_tools": receipt["other_tools"],
                "tool_order": [c["tool"] for c in trace],
                "searches": searches,
                "exports": exports,
                "delivery_summary": (folder / "final.txt")
                .read_text(encoding="utf-8")
                .split("\n\n")[0],
            }
        )
    assert len({a["thread_ids"][0] for a in actors}) == len(actors)
    write(
        output,
        {
            "corpus": "Isolated copy of the preceding physics library, plus two operator-authored controls whose native source, positive edit and clean boundary pages were visually checked.",
            "controls": RULES,
            "control_cases": read(root / "receipts.json"),
            **comparison,
            "live_sessions": actors,
            "scope_review": {
                "mixed": "The predeclared topic labels included both table and flow. The table rule is specific to observation times and displacement, so it is a lexical candidate only for a pH sample table. The flow rule directly applies.",
                "text": "The plain observation brief says to omit formula, figures and tables. BM25 returned two active but out-of-scope rules; adding the homework-only tags returned none.",
                "chemistry": "The first host found the legacy fraction example and requested the missing literal command. A fresh host with the command supplied exported a PDF. Four sessions span three assignments.",
            },
            "method": "Six fixed paired queries and three ordinary assignment prompts. The additional chemistry session supplied the literal command missing in the first request. The tag baseline uses operator-selected labels. Relevance labels describe intended scope, independent of tool output.",
        },
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "phase", choices=["prepare", "validate", "compare", "session", "report"]
    )
    p.add_argument("--config", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--original", type=Path)
    p.add_argument("--result", type=Path)
    p.add_argument("--case", choices=[*CASES_ZH, "chemistry_template"])
    a = p.parse_args()
    cfg = read(a.config)
    root = a.out.resolve()
    if a.phase == "prepare":
        prepare(cfg, root, a.original)
    elif a.phase == "validate":
        validate(cfg, root)
    elif a.phase == "compare":
        compare(cfg, root)
    elif a.phase == "session":
        session(cfg, root, a.case)
    else:
        report(root, a.result)
