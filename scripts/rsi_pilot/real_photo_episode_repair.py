"""Follow an actual negative image verdict through a native edit, re-read and verified export."""

import argparse
import json
import sqlite3
from pathlib import Path

from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from PIL import Image
from real_photo_episode import BRIEF, FORMULA, capture, source
from real_photo_episode_challenge import advance, export, invoke, task
from real_photo_episode_controls import BOX, CONTROLS

PROMPT = (
    BRIEF
    + "\n你独立检查本题的周期计算式。附件仅为同尺度、未加标记的原尺寸公式区域，而非完整作业。请转录你看到的运算式，然后判断该算式是否可交。看不清用 uncertain。只输出 JSON {transcription,decision:accept或repair或uncertain,reason}，不要调用工具。"
)
UNSUPPORTED = r"$$T=\badfrac{2.5-0.5}{4}=0.5\,\mathrm{s}$$"


def image_cut(full, output):
    with Image.open(full) as image:
        image.convert("RGB").crop(BOX).save(output)


def unsupported(out, cfg):
    folder = out / "equation-controls" / "U8A"
    folder.mkdir(exist_ok=True)
    result = {
        "condition": "unsupported_command_in_display_math",
        "opaque_id": "U8A",
        "equation_source": UNSUPPORTED,
        "source_sha256": digest(source(UNSUPPORTED).encode()),
        "native_crop": BOX,
    }
    with Server(cfg, folder / "home", "real_math_command", log_dir=folder) as s:
        state = folder / "state.json"
        if not state.exists():
            try:
                created = invoke(
                    s,
                    "save_section",
                    markdown=source(UNSUPPORTED),
                    paper_path=cfg["photo"],
                    title="传感器周期测量",
                    style={
                        "homework": True,
                        "seed": 64019,
                        "font_size": 34,
                        "font": "李国夫手写体.ttf",
                    },
                )
            except RuntimeError as err:
                result["save_error"] = str(err)
                write(folder / "outcome.json", result)
                return result
            write(state, {"draft_id": created["draft_id"]})
        draft = read(state)["draft_id"]
        with sqlite3.connect(
            (folder / "home/drafts.sqlite3").as_uri() + "?mode=ro", uri=True
        ) as db:
            prepared = db.execute(
                "SELECT prepared FROM sections WHERE draft=? AND number=1 AND revision=1",
                (draft,),
            ).fetchone()[0]
        (folder / "prepared.txt").write_text(prepared, encoding="utf8")
        result["prepared_sha256"] = digest(prepared.encode())
        token = prepared.find("badfrac")
        result["retained_command_in_prepared"] = token >= 0
        if token >= 0:
            result["worker_excerpt"] = prepared[max(0, token - 30) : token + 60]
        response = s.call(
            "preview_handwriting",
            draft_id=draft,
            revision=1,
            section=1,
            page=1,
            view="image",
        )
        save_image(response, folder / "private-page.png")
    image_cut(folder / "private-page.png", folder / "region.png")
    result["vote"] = opinion(folder / "vote", PROMPT, [folder / "region.png"])
    result["receipt"] = read(folder / "vote/receipt.json")
    result["image_sha256"] = digest((folder / "region.png").read_bytes())
    write(folder / "outcome.json", result)
    return result


def repair(out, cfg):
    folder = out / "equation-repair"
    folder.mkdir(exist_ok=True)
    bad = next(
        r
        for r in read(out / "equation-controls/report.json")["results"]
        if r["condition"] == "missing_denominator"
    )
    if bad["vote"]["decision"] != "repair":
        raise ValueError("No genuine rejection for missing denominator")
    control = out / "equation-controls" / bad["opaque_id"]
    home = folder / "home"
    home.mkdir(exist_ok=True)
    if not (home / "drafts.sqlite3").exists():
        with (
            sqlite3.connect(
                (control / "db/drafts.sqlite3").as_uri() + "?mode=ro", uri=True
            ) as src,
            sqlite3.connect(home / "drafts.sqlite3") as dest,
        ):
            src.backup(dest)
    with sqlite3.connect(
        (home / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True
    ) as db:
        rows = db.execute(
            "SELECT distinct draft FROM sections WHERE source=?",
            (source(CONTROLS["missing_denominator"]),),
        ).fetchall()
        if len(rows) != 1:
            raise ValueError("Could not unambiguously recover anonymous baseline")
        draft = rows[0][0]
    if not (folder / "r1/pages.json").exists():
        capture(cfg, folder, draft, 1)
    image_cut(folder / "r1/page-1.png", folder / "before.png")
    assert digest((folder / "before.png").read_bytes()) == bad["image_sha256"]
    with Server(cfg, home, "intercept_and_repair", log_dir=folder) as s:
        history = task(
            s,
            folder,
            "repair",
            draft,
            BRIEF,
            "Independent Codex CLI gpt-6.1-terra rejection and fresh post-edit acceptance; host implements the specified fraction.",
        )
        if not history["decisions"]:
            history = advance(
                s,
                history,
                folder,
                1,
                "revise",
                bad["vote"]["reason"],
                tool="save_section",
                instruction="Restore the divisor 4 in a native LaTeX fraction and inspect a fresh render before export.",
            )
        d = history["decisions"][0]
        if d["result_revision"] is None:
            saved = invoke(
                s,
                "save_section",
                draft_id=draft,
                expected_revision=1,
                section=1,
                markdown=source(FORMULA),
                rsi_decision_id=d["decision_id"],
            )
            assert saved["revision"] == 2
    if not (folder / "r2/pages.json").exists():
        capture(cfg, folder, draft, 2)
    image_cut(folder / "r2/page-1.png", folder / "after.png")
    vote = opinion(folder / "post-edit-vote", PROMPT, [folder / "after.png"])
    with Server(cfg, home, "post_edit_verification", log_dir=folder) as s:
        history = invoke(s, "read_rsi_task", task_id=history["task_id"])
        if history["status"] == "active":
            history = advance(
                s,
                history,
                folder,
                2,
                "select" if vote["decision"] == "accept" else "stop",
                vote["reason"],
            )
        final = (
            export(s, draft, 2, folder, "selected")
            if vote["decision"] == "accept"
            else None
        )
    result = {
        "scope": "Negative control draft forked by SQLite backup, exact pre-edit image hash verified. Only selected verified revision was exported in this repair task.",
        "draft_id": draft,
        "task_id": history["task_id"],
        "decisions": history["decisions"],
        "pre_edit_vote": bad["vote"],
        "pre_edit_sha256": bad["image_sha256"],
        "post_edit_vote": vote,
        "post_edit_receipt": read(folder / "post-edit-vote/receipt.json"),
        "post_edit_sha256": digest((folder / "after.png").read_bytes()),
        "selected_pdf": final,
    }
    write(folder / "outcome.json", result)
    return result


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", choices=["unsupported", "repair"])
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--binary", required=True, type=Path)
    a = p.parse_args()
    root = a.out.resolve()
    cfg = dict(
        read(root / "manifest.json")["runtime"],
        binary=str(a.binary.resolve(strict=True)),
    )
    result = (repair if a.phase == "repair" else unsupported)(root, cfg)
    print(json.dumps(result, ensure_ascii=False)[:1600])
