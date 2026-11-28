"""Feedback-driven, single-line native refinement. Earlier PDF and three-way choice stay independent."""

import argparse
import json
from pathlib import Path

import numpy as np
from benchmark import Server, digest, read, write
from content_matrix import opinion
from PIL import Image, ImageDraw
from real_photo_audit_trial import CATEGORIES
from real_photo_episode import BRIEF, FORMULA, capture, source
from real_photo_episode_challenge import advance, export, invoke, task

BODY = (273, 337, 752, 402)
IDS = tuple(range(14, 28))
BLIND_ORDER = {"Q4": 2, "F7": 1}


def tile(root, out_path, rev):
    labels = {
        "First body line": BODY,
        **{kind: v[0] for kind, v in CATEGORIES.items() if kind != "text"},
    }
    with Image.open(root / f"r{rev}/page-1.png") as page:
        width = max(b[2] - b[0] for b in labels.values())
        height = sum(b[3] - b[1] + 21 for b in labels.values())
        strip = Image.new("RGB", (width, height), "white")
        draw = ImageDraw.Draw(strip)
        y = 0
        for label, box in labels.items():
            draw.text((2, y + 3), label, fill="black")
            strip.paste(page.crop(box), (0, y + 21))
            y += box[3] - box[1] + 21
        strip.save(out_path)


def propose(out, binary):
    f = out / "local-refinement"
    f.mkdir(exist_ok=True)
    cfg = dict(read(out / "manifest.json")["runtime"], binary=str(binary))
    primary = out / "homework"
    if not (f / "state.json").exists():
        with Server(cfg, f / "home", "fresh_local_task", log_dir=f) as s:
            new = invoke(
                s,
                "save_section",
                markdown=source(FORMULA),
                paper_path=cfg["photo"],
                title="传感器周期测量",
                style={
                    "seed": 64019,
                    "homework": True,
                    "font_size": 34,
                    "font": "李国夫手写体.ttf",
                },
            )
            write(
                f / "state.json",
                {
                    "draft_id": new["draft_id"],
                    "revision": new["revision"],
                    "binary_sha256": digest(binary.read_bytes()),
                },
            )
    draft = read(f / "state.json")["draft_id"]
    if not (f / "r1" / "pages.json").exists():
        capture(cfg, f, draft, 1)
    left = read(f / "r1/pages.json")
    right = read(primary / "r1/pages.json")
    assert [x["sha256"] for x in left] == [x["sha256"] for x in right]
    tile(primary, f / "original.png", 1)
    tile(primary, f / "challenger.png", 2)
    allglyph = {g["id"]: g for g in read(f / "r1/glyphs-1.json")}
    xs = [int(x) for g in IDS for x, _ in allglyph[g]["photo_quad"]]
    ys = [int(y) for g in IDS for _, y in allglyph[g]["photo_quad"]]
    assert (
        min(xs) >= BODY[0]
        and max(xs) <= BODY[2]
        and min(ys) >= BODY[1]
        and max(ys) <= BODY[3]
    )
    prompt = (
        BRIEF
        + "\n新任务，从原稿重新开始。之前三选一整稿裁判选过温和的整片处理；另两次互换匿名位置的局部评审均指出那一版的表格比原稿模糊、原稿正文和表边更清晰。当前附图1原稿、图2为该温和版，包含同坐标原生像素。可以选 keep，或在原稿上只试第一行正文的 14 个字（用相同方向的过零点标记周期，）0.1至0.4 像素轻柔化，保护标题、其他文字、表格线和所有图形。观察局部可见证据，别假定必须修改。如果要试请自行决定 softness 取0.1、0.2、0.3或0.4。输出 JSON {action:keep或try_local,softness,reason,expected,protected}。不要执行工具。"
    )
    return (
        cfg,
        f,
        draft,
        opinion(
            f / "feedback-proposal", prompt, [f / "original.png", f / "challenger.png"]
        ),
    )


def category_changes(f):
    glyphs = {g["id"]: g for g in read(f / "r1/glyphs-1.json")}
    with Image.open(f / "r1/page-1.png") as p1, Image.open(f / "r2/page-1.png") as p2:
        a = np.asarray(p1.convert("RGB"), dtype=np.int16)
        b = np.asarray(p2.convert("RGB"), dtype=np.int16)
        delta = np.max(np.abs(b - a), axis=2)
    by = {
        "body": IDS,
        "table": [42],
        "formula": [72, 73, 75, 76, 77, 78, 80],
        "flow": [108],
        "raster": [135],
    }
    ans = {}
    for kind, ids in by.items():
        mask = Image.new("1", (delta.shape[1], delta.shape[0]), 0)
        draw = ImageDraw.Draw(mask)
        for i in ids:
            draw.polygon([tuple(p) for p in glyphs[i]["photo_quad"]], fill=1)
        vals = delta[np.asarray(mask)]
        ans[kind] = {
            "glyph_ids": list(ids),
            "quad_pixels": len(vals),
            "changed_any_channel": int(np.count_nonzero(vals)),
            "max_delta": int(vals.max()),
        }
    box = BODY
    x1, y1, x2, y2 = box
    ans["outside_body_crop_changed"] = int(
        np.count_nonzero(delta) - np.count_nonzero(delta[y1:y2, x1:x2])
    )
    ans["entire_page_two_byte_equal"] = digest(
        (f / "r1/page-2.png").read_bytes()
    ) == digest((f / "r2/page-2.png").read_bytes())
    return ans


def run(out, binary, results):
    cfg, f, draft, decision = propose(out, binary)
    op = decision["action"]
    if op not in {"keep", "try_local"}:
        raise ValueError(decision)
    sigma = decision.get("softness") if op == "try_local" else 0.3
    if sigma not in {0.1, 0.2, 0.3, 0.4}:
        raise ValueError(decision)
    with Server(cfg, f / "home", "feedback_guided_refinement", log_dir=f) as s:
        primary = task(
            s,
            f,
            "feedback",
            draft,
            BRIEF + " 从原稿根据局部评审意见决定是否微调第一行正文。",
            "Codex CLI Terra proposal and independent local selection",
        )
        if op == "keep":
            if primary["status"] == "active":
                primary = advance(s, primary, f, 1, "select", decision["reason"])
            active = task(
                s,
                f,
                "operator",
                draft,
                BRIEF + " 实验者另测限定单行设置，盲评可保留原稿。",
                "Operator control after model keep, independent Codex CLI Terra judges",
            )
        else:
            active = primary
        if not active["decisions"]:
            reason = (
                decision["reason"]
                if op == "try_local"
                else "模型保留原稿；实验者另测预设的第一行正文0.3像素，不改表格与图片。"
            )
            active = advance(
                s,
                active,
                f,
                1,
                "revise",
                reason,
                tool="adjust_glyphs",
                instruction=f"Page 1 first body line IDs {IDS}, softness={sigma}.",
            )
        edit = active["decisions"][0]
        if edit["result_revision"] is None:
            new = invoke(
                s,
                "adjust_glyphs",
                draft_id=draft,
                expected_revision=1,
                section=1,
                page=1,
                ids=list(IDS),
                softness=sigma,
                rsi_decision_id=edit["decision_id"],
            )
            assert new["revision"] == 2
    if not (f / "r2/pages.json").exists():
        capture(cfg, f, draft, 2)
    stats = category_changes(f)
    for code, rev in BLIND_ORDER.items():
        tile(f, f / f"{code}.png", rev)
    prompt = "在 Q4 和 F7 两张同纸、同坐标、原尺寸手写作业局部中，比较最上面第一行正文是否清楚、与周围纸面光照和清晰度是否协调；对表格、公式、流程、波形只报告确实可见的差异。可以并列或拒交，避免猜哪个经过处理。只输出 JSON {choice:Q4或F7或tie或reject,reason,regions}。不要使用工具。"
    verdict = opinion(
        f / "blind-vote", prompt, [f / f"{code}.png" for code in BLIND_ORDER]
    )
    choice = verdict["choice"]
    if choice not in {*BLIND_ORDER, "tie", "reject"}:
        raise ValueError(verdict)
    selected = BLIND_ORDER.get(choice, 1 if choice == "tie" else None)
    with Server(cfg, f / "home", "local_terminal_selection", log_dir=f) as s:
        active = invoke(s, "read_rsi_task", task_id=active["task_id"])
        if active["status"] == "active":
            active = advance(
                s,
                active,
                f,
                selected or 2,
                "select" if selected else "stop",
                verdict["reason"],
            )
        pdf = export(s, draft, selected, f, "selected") if selected else None
    result = {
        "scope": "One feedback-driven single-line refinement on an exact re-render of the same development paper. Ties keep r1. This task does not overwrite the prior overall selection.",
        "binary_sha256": digest(binary.read_bytes()),
        "model_proposal": decision,
        "proposal_receipt": read(f / "feedback-proposal/receipt.json"),
        "candidate_initiator": "model"
        if op == "try_local"
        else "operator after model keep",
        "softness": sigma,
        "candidate_task_id": active["task_id"],
        "proposal_task_id": primary["task_id"],
        "original_source_sha256": digest(source(FORMULA).encode()),
        "decisions": active["decisions"],
        "native_body_box": BODY,
        "pixel_changes": stats,
        "blinded_mapping": BLIND_ORDER,
        "ballot": verdict,
        "ballot_receipt": read(f / "blind-vote/receipt.json"),
        "selected_revision": selected,
        "pdf": pdf,
    }
    write(f / "outcome.json", result)
    write(results / "real-photo-local-refinement.json", result)
    print(json.dumps(result, ensure_ascii=False)[:1200])


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--binary", required=True, type=Path)
    p.add_argument("--results", required=True, type=Path)
    args = p.parse_args()
    run(args.out.resolve(), args.binary.resolve(strict=True), args.results.resolve())
