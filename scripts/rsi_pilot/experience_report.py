"""Build a path-free, hash-linked report of successful and unsuccessful ordinary agent sessions."""

import argparse
import json
import re
from pathlib import Path

from benchmark import digest, read, write
from experience_audit import learned, summarize


def event_audit(folder):
    events = [
        json.loads(raw)
        for raw in (folder / "cli-events.jsonl")
        .read_text(encoding="utf-8-sig")
        .splitlines()
    ]
    attempts = [
        x["item"]
        for x in events
        if x.get("type") == "item.completed"
        and x.get("item", {}).get("type") == "mcp_tool_call"
    ]
    return [
        {
            "tool": item["tool"],
            "status": item.get("status"),
            "client_error": item.get("error", {}).get("message")
            if item.get("error")
            else None,
        }
        for item in attempts
    ]


def redact(t):
    if isinstance(t, dict):
        return {
            k: redact(v) for k, v in t.items() if k not in {"path", "relative_path"}
        }
    if isinstance(t, list):
        return [redact(z) for z in t]
    if isinstance(t, str) and (
        re.search(r"(?:[A-Za-z]:[/\\]|/Users/|/home/)", t) or "base64," in t
    ):
        return "[local artifact path or transfer payload omitted]"
    return t


def folder_report(folder):
    receipt = read(folder / "receipt.json")
    ledger = summarize(folder)
    compact = []
    for row in ledger:
        arg = row["input"].copy()
        res = row["result"].copy()
        if "markdown" in arg:
            arg["markdown_sha256"] = digest(arg["markdown"].encode())
        if "experience_reflection" in res:
            reflection = res["experience_reflection"]
            res["experience_reflection"] = {
                k: reflection[k]
                for k in ("page_reviews", "reviewed_pages", "tool", "arguments")
                if k in reflection
            }
        if "rules" in res:
            res["rules"] = [
                {
                    k: r[k]
                    for k in ("rule_id", "status", "scope", "action", "tags")
                    if k in r
                }
                for r in res["rules"]
            ]
        compact.append(dict(row, input=arg, result=res))
    return {
        "attempt": folder.name,
        "prompt": (folder / "prompt.txt").read_text(encoding="utf8"),
        "model_receipt": receipt,
        "cli_items": event_audit(folder),
        "wire_sha256": digest((folder / "wire.jsonl").read_bytes()),
        "final_response_sha256": digest((folder / "final.txt").read_bytes()),
        "final_response_without_local_paths": "\n".join(
            line
            for line in (folder / "final.txt")
            .read_text(encoding="utf-8-sig")
            .splitlines()
            if not re.search(
                r"[A-Za-z]:[/\\]|/Users/|/home/|所在.*电脑|运行 Panache 的电脑", line
            )
        ),
        "native_calls": compact,
        "authored_rules": learned(folder),
        "final_artifact_audit": read(folder / "auditor/audit.json")
        if (folder / "auditor/audit.json").exists()
        else None,
    }


def cohort(out):
    origins = sorted(d for d in out.glob("origin*") if (d / "receipt.json").exists())
    transfer = sorted(
        d
        for d in out.glob("transfer-*")
        if d.is_dir() and (d / "receipt.json").exists()
    )
    known = {}
    for d in sorted((out / "validation").iterdir()):
        if not d.is_dir() or not (d / "artifact.json").exists():
            continue
        known[d.name] = {
            "artifact": read(d / "artifact.json"),
            "image_only": read(d / "blind/decision.json")
            if (d / "blind/decision.json").exists()
            else None,
            "image_only_receipt": read(d / "blind/receipt.json")
            if (d / "blind/receipt.json").exists()
            else None,
            "rule_validations": [
                read(v)
                for v in sorted(
                    [*d.glob("positive-*.json"), *d.glob("boundary-*.json")]
                )
            ],
        }
    logs = [folder_report(d) for d in [*origins, *transfer]]
    ids = [t for l in logs for t in l["model_receipt"]["thread_ids"]]
    if len(ids) != len(set(ids)):
        raise ValueError("Reused model conversation ID")
    info = {
        "scope": "Actual ephemeral Codex CLI model-directed native stdio calls. The proxy copies protocol bytes unchanged. Actor prompts name no experience tool or rule ID; a draft ID is provided only for edits requested on existing drafts. The matched negative controls are investigator-authored, never represented as automatic reflection.",
        "isolation": {
            "shared_surface": "One native draft/experience store",
            "processes": "New native stdio process and new temporary empty model working directory on every model invocation. Codex user configuration ignored, project instructions and shell disabled. Interactive history/resume never supplied.",
            "distinct_observed_thread_ids": len(ids),
        },
        "sessions": logs,
        "known_answer_observations": known,
        "decoy_registration": read(out / "validation/decoys.json")
        if (out / "validation/decoys.json").exists()
        else None,
        "limitations": "An independent matching readback validates the controlled cases. It is not a population estimate or a causal accuracy improvement over the unaided model. Model authorship, host-initiated fixtures and independent observers have separate receipts.",
    }
    info["corpus"] = out.name
    return redact(info)


def report(out, results, earlier):
    result = {"primary": cohort(out), "earlier_cohorts": [cohort(d) for d in earlier]}
    status = out / "validation/pretransfer-states.json"
    if status.exists():
        result["primary"]["pretransfer_native_status"] = read(status)
    snapshot = out / "snapshot-after-origin.sqlite3"
    if snapshot.exists():
        result["primary"]["prevalidation_database_backup_sha256"] = digest(
            snapshot.read_bytes()
        )
    state_file = out / "validation/visibility.json"
    if state_file.exists():
        result["primary"]["verified_visibility"] = read(state_file)
    for earlier_dir, part in zip(earlier, result["earlier_cohorts"], strict=True):
        if (earlier_dir / "validation/decoys.json").exists() and not (
            earlier_dir / "snapshot-after-origin.sqlite3"
        ).exists():
            part["caution"] = (
                "Historical validation error: the post-action hypothetical accept was incorrectly evaluated as a pre-edit grade. This cohort's rejection is genuine native state but not a valid assessment of that original helpful rule. The cohort was retained."
            )
    assets = out / "public-assets"
    result["public_assets_sha256"] = {
        f.name: digest(f.read_bytes()) for f in sorted(assets.glob("*.png"))
    }
    result["scope_and_selection"] = {
        "origin": "The positive source is an autonomous Astra homework agent; multiple initial Terra origin agents exported correctly and recorded zero or no proposals. The chemistry transfer agent is a fresh Terra using only the native library.",
        "transfer": "The transfer request supplied a unique ordinary homework title and no UUID, rule wording, validation history or previous transcript. Its first knowledge search happened before preview and before edit. It used the normal list_drafts title lookup.",
        "validation": "A blinded independent review called the held-out faulty draft repair; an operator implemented the exact candidate action; an independent readback of the actual revised output accepted it. A separate already-correct page including literal template code remained acceptable. An overbroad same-tag rule initially reached active, but later wrongly rejected a correct page and was permanently rejected.",
        "historical_evaluator_error": "In the preceding physics cohort, a scoring bug treated a hypothetical post-repair acceptance as an initial-page acceptance, submitting a mistaken failing native validation. The original rejected rule and raw evidence remain untouched. The final cohort is a different, fresh natural agent proposal, with a complete prevalidation database backup and physically separate original-vs-revised image scoring.",
    }
    results.mkdir(exist_ok=True, parents=True)
    write(results / "experience-cross-session.json", redact(result))
    print(
        "ordinary sessions",
        [len(c["sessions"]) for c in [result["primary"], *result["earlier_cohorts"]]],
        flush=True,
    )


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--results", type=Path, required=True)
    p.add_argument("--earlier", type=Path, action="append", default=[])
    a = p.parse_args()
    report(a.out.resolve(), a.results.resolve(), [v.resolve() for v in a.earlier])
