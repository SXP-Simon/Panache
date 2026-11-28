"""Summarize direct stdio tool calls and insert transparently operator-authored controls."""

import argparse
import json
from pathlib import Path

from benchmark import Server, read, write
from experience_validation import invoke, refs, verify


def calls(folder):
    named = {}
    for raw in (folder / "wire.jsonl").read_text(encoding="utf8").splitlines():
        row = json.loads(raw)
        p = row["payload"]
        i = p.get("id")
        if row["direction"] == "request" and p.get("method") == "tools/call":
            named[i] = {
                "tool": p["params"]["name"],
                "arguments": p["params"]["arguments"],
            }
        elif row["direction"] == "response" and i in named:
            res = p.get("result", {})
            named[i].update(
                response=res.get("structuredContent", {}),
                error=res.get("isError", False),
                blocks=[
                    {
                        k: v
                        for k, v in b.items()
                        if k in {"type", "sha256", "byte_count"}
                    }
                    for b in res.get("content", [])
                ],
                error_text=res.get("content", [{}])[0].get("text")
                if res.get("isError")
                else None,
            )
    return list(named.values())


def summarize(folder):
    rows = []
    for c in calls(folder):
        arg = c["arguments"]
        resp = c.get("response", {})
        item = {
            "tool": c["tool"],
            "input": {
                k: v
                for k, v in arg.items()
                if k
                in {
                    "draft_id",
                    "revision",
                    "section",
                    "page",
                    "view",
                    "tags",
                    "rule_id",
                    "format",
                    "include_file",
                    "region",
                    "export_id",
                    "drawing_kind",
                    "rules",
                }
            },
            "result": {
                k: v
                for k, v in resp.items()
                if k
                in {
                    "draft_id",
                    "revision",
                    "page",
                    "review_id",
                    "export_id",
                    "rules",
                    "available_tags",
                    "pages",
                    "experience_search",
                    "experience_reflection",
                }
            },
            "native_images": [b for b in c.get("blocks", []) if b["type"] == "image"],
            "error": c.get("error"),
        }
        if "markdown" in arg:
            item["input"]["markdown"] = arg["markdown"]
        if c.get("error_text"):
            item["error_text"] = c["error_text"]
        rows.append(item)
    return rows


def learned(folder):
    rules = []
    for c in calls(folder):
        if c["tool"] == "record_homework_experience" and not c.get("error"):
            for r, receipt in zip(
                c["arguments"]["rules"], c["response"]["rules"], strict=True
            ):
                rules.append(dict(**r, **receipt))
    return rules


def decoys(cfg, out, origin):
    auto = learned(origin)
    if not auto:
        raise ValueError(
            "No original model-authored rule; do not synthesize one for the origin"
        )
    # Reuse the first naturally proposed rule's exact tags, so a tag mismatch cannot explain the negatives' absence.
    tags = auto[0]["tags"]
    case = read(out / "validation/decoy-source/artifact.json")
    visual = verify(out, "decoy-source")
    if visual["decision"] != "repair":
        raise ValueError("Source does not establish the visible residue")
    source = refs(case)
    rules = [
        {
            "tags": tags,
            "scope": "手写页有分式时。",
            "action": "每次必须单独复查分母与页面右侧的边缘距离。",
            "reason": "对照作者提出的待验证检查。该页有分式，是否值得这样检查还未验证。",
            "reviews": source["reviews"],
        },
        {
            "tags": tags,
            "scope": "所有出现 LaTeX 或分式的手写页，包括教学页、源码及展示公式。",
            "action": "只要最终图片里出现任何反斜线命令，例如 \\frac 或 \\badfrac，即整页退回，不区分所在区域；没有字面命令时无需因此拦截。",
            "reason": "该次受控源稿要求直接显示分式，成图却裸露了命令。实验者故意把一次真实缺陷泛化到所有区域。",
            "reviews": source["reviews"],
        },
    ]
    with Server(
        cfg, Path(cfg["home"]), "operator_decoys", log_dir=out / "validation"
    ) as s:
        result = invoke(
            s,
            "record_homework_experience",
            **{k: v for k, v in source.items() if k != "reviews"},
            rules=rules,
        )
    record = {
        "initiator": "study operator",
        "purpose": "Matched-tag pending control and purposely overbroad control with later falsification. Neither was proposed by the homework agent.",
        "origin_rule_used_for_matching_tags": auto[0]["rule_id"],
        "decoys": [dict(**r, **e) for r, e in zip(rules, result["rules"], strict=True)],
    }
    write(out / "validation/decoys.json", record)
    print(json.dumps(record, ensure_ascii=False))


def visibility(cfg, out, origin):
    proposals = learned(origin)
    controls = read(out / "validation/decoys.json")["decoys"]
    sequential = calls(out / "transfer-01")
    original_query = next(
        x for x in sequential if x["tool"] == "search_homework_experience"
    )
    states = []
    with Server(
        cfg,
        Path(cfg["home"]),
        "end_of_transfer_read_only_independent_audit",
        log_dir=out / "validation",
    ) as server:
        for submitted in proposals + controls:
            row = invoke(
                server, "read_homework_experience", rule_id=submitted["rule_id"]
            )
            states.append(
                {
                    "rule_id": row["rule_id"],
                    "status": row["status"],
                    "condition": row["scope"],
                    "tags": row["tags"],
                    "case_roles": [(c["kind"], c["passed"]) for c in row["cases"]],
                }
            )
    retrieved = [r["rule_id"] for r in original_query["response"]["rules"]]
    first_edit = min(
        i
        for i, x in enumerate(sequential)
        if x["tool"] in ("replace_section_text", "save_section")
    )
    write(
        out / "validation/visibility.json",
        {
            "actual_unprompted_query": original_query["arguments"],
            "actually_returned": retrieved,
            "all_known_rules": states,
            "model_proposal_count_at_source": len(proposals),
            "transferred_only_one_from_source": len(retrieved) == 1
            and retrieved[0] in {r["rule_id"] for r in proposals},
            "search_preceded_any_edit": sequential.index(original_query) < first_edit,
        },
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", choices=["summary", "learned", "decoys", "visibility"])
    p.add_argument("--origin", type=Path, required=True)
    p.add_argument("--config", type=Path)
    p.add_argument("--out", type=Path)
    a = p.parse_args()
    if a.phase == "summary":
        rows = summarize(a.origin)
        write(a.origin / "tool-summary.json", rows)
        print([x["tool"] for x in rows])
    elif a.phase == "learned":
        print(json.dumps(learned(a.origin), ensure_ascii=False, indent=2))
    elif a.phase == "visibility":
        visibility(read(a.config), a.out.resolve(), a.origin.resolve())
    else:
        decoys(read(a.config), a.out.resolve(), a.origin.resolve())
