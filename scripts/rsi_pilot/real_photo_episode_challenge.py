"""Native optical challengers after the guided assessor chose to keep the original."""

import argparse
import json
import shutil
from pathlib import Path

import pymupdf
from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from PIL import Image, ImageDraw
from real_photo_episode import BRIEF, WINDOWS, capture, packet

# Frozen before rendering. These are operator challenge settings, never actor-proposed controls.
CHALLENGES = [
    {
        "photo_ink_light": 30,
        "photo_ink_focus": {
            "from": {"x": 0.5, "y": 0.15, "sigma_px": 0.65},
            "to": {"x": 0.5, "y": 0.78, "sigma_px": 0.0},
        },
    },
    {
        "photo_ink_light": 95,
        "photo_ink_focus": {
            "from": {"x": 0.5, "y": 0.15, "sigma_px": 1.9},
            "to": {"x": 0.5, "y": 0.78, "sigma_px": 1.0},
        },
    },
]
CODES = ["S7Q", "D5K", "W2L"]
MAPPING = {"S7Q": 3, "D5K": 1, "W2L": 2}


def invoke(s, name, **args):
    return s.call(name, **args)["structuredContent"]


def task(s, folder, key, draft, objective, provider):
    target = folder / (key + "-task.json")
    if not target.exists():
        val = invoke(
            s,
            "start_rsi_task",
            draft_id=draft,
            revision=1,
            objective=objective,
            policy_id="pilot-v1",
            decision_provider=provider,
        )
        write(target, val)
    return invoke(s, "read_rsi_task", task_id=read(target)["task_id"])


def advance(s, t, folder, revision, action, reason, **kwargs):
    pages = read(folder / f"r{revision}" / "pages.json")
    return invoke(
        s,
        "advance_rsi_task",
        task_id=t["task_id"],
        expected_step=t["step"],
        revision=revision,
        action=action,
        reason=reason,
        review_ids=[p["review_id"] for p in pages],
        **kwargs,
    )


def export(s, draft, revision, folder, name):
    dest = folder / (name + ".pdf")
    report = folder / (name + ".json")
    if not report.exists():
        receipt = invoke(
            s, "export_handwriting", draft_id=draft, revision=revision, format="pdf"
        )
        shutil.copyfile(receipt["path"], dest)
        with pymupdf.open(dest) as pdf:
            checks = []
            for page in pdf:
                images = page.get_images()
                assert len(images) == 1, images
                pix = pymupdf.Pixmap(pdf, images[0][0])
                if pix.alpha:
                    pix = pymupdf.Pixmap(pix, 0)
                with Image.open(
                    folder / f"r{revision}" / f"page-{page.number + 1}.png"
                ) as png:
                    expected = png.convert("RGB")
                    checks.append(
                        {
                            "width": pix.width,
                            "height": pix.height,
                            "rgb_equal": pix.samples == expected.tobytes(),
                        }
                    )
        assert len(checks) == receipt["pages"] and all(
            p["rgb_equal"] for p in checks
        ), checks
        write(
            report,
            {
                "sha256": digest(dest.read_bytes()),
                "pages": receipt["pages"],
                "revision": revision,
                "native_review": receipt["review"],
                "embedded_rgb_vs_preview": checks,
            },
        )
    return read(report)


def triple_panel(folder, name, code_order):
    page, box = WINDOWS[name]
    pics = []
    for code in code_order:
        with Image.open(folder / f"r{MAPPING[code]}" / f"page-{page}.png") as im:
            pics.append(im.convert("RGB").crop(box))
    canvas = Image.new(
        "RGB", (pics[0].width, len(pics) * (pics[0].height + 25)), "white"
    )
    draw = ImageDraw.Draw(canvas)
    for i, (code, pic) in enumerate(zip(code_order, pics, strict=True)):
        y = i * (pic.height + 25)
        draw.text((2, y + 3), code, fill="black")
        canvas.paste(pic, (0, y + 25))
    return canvas


def run(out, binary):
    folder = out / "homework"
    cfg = dict(read(out / "manifest.json")["runtime"], binary=str(binary))
    draft = read(folder / "state.json")["draft_id"]
    manifest = {
        "binary_sha256": digest(binary.read_bytes()),
        "binary": str(binary),
        "initiator": "operator challenges after guided keep",
        "mapping": MAPPING,
        "settings": CHALLENGES,
    }
    spec = folder / "challenges.json"
    if spec.exists() and read(spec) != manifest:
        raise ValueError("Challenge plan changed")
    write(spec, manifest)
    with Server(cfg, folder / "home", "new_native", log_dir=folder) as s:
        write(
            folder / "native-controls.json",
            invoke(s, "describe_controls", draft_id=draft, group="ink"),
        )
        write(
            folder / "native-guide.json",
            invoke(s, "read_rsi_policy", evidence_guide_version="paper-homework/2"),
        )
        refs = read(folder / "r1/pages.json")
        for p in refs:
            dest = folder / f"same-page-{p['page']}.png"
            save_image(
                s.call(
                    "preview_handwriting",
                    draft_id=draft,
                    revision=1,
                    section=1,
                    page=p["page"],
                    view="image",
                ),
                dest,
            )
            assert digest(dest.read_bytes()) == p["sha256"], (
                "baseline changed with new binary"
            )
        guided = read(folder / "guided/decision.json")
        if guided["action"] != "keep":
            raise ValueError(
                "This prospective challenge specifically follows a keep decision"
            )
        kept = task(
            s,
            folder,
            "guided",
            draft,
            BRIEF,
            "Codex CLI gpt-6.1-terra high guided visual review",
        )
        if kept["status"] == "active":
            kept = advance(s, kept, folder, 1, "select", guided["reason"])
        write(folder / "guided-native-outcome.json", kept)
        export(s, draft, 1, folder, "initial")
        actor = task(
            s,
            folder,
            "challenge",
            draft,
            BRIEF + " 人工提出2个光学参数作对照，独立裁判可选任意稿或拒交。",
            "Operator proposes labelled controls. Independent Codex CLI gpt-6.1-terra high selects blind.",
        )
        for i, changes in enumerate(CHALLENGES, 1):
            actor = invoke(s, "read_rsi_task", task_id=actor["task_id"])
            if len(actor["decisions"]) < i:
                actor = advance(
                    s,
                    actor,
                    folder,
                    i,
                    "revise",
                    "实验方预先指定可逆挑战条件，用于解决证据不足；guided 模型选择保留原稿。",
                    tool="tune_handwriting",
                    instruction=json.dumps(changes),
                )
            decision = actor["decisions"][i - 1]
            if decision["result_revision"] is None:
                candidate = invoke(
                    s,
                    "tune_handwriting",
                    draft_id=draft,
                    expected_revision=i,
                    changes=changes,
                    rsi_decision_id=decision["decision_id"],
                )
                assert candidate["revision"] == i + 1
            if not (folder / f"r{i + 1}" / "optical-evidence.json").exists():
                packet(capture(cfg, folder, draft, i + 1))
            export(s, draft, i + 1, folder, f"candidate-{i + 1}")
    blind = out / "optical-selection"
    blind.mkdir(exist_ok=True)
    paths = []
    for code in CODES:
        for page in (1, 2):
            dest = blind / f"{code}-page-{page}.png"
            shutil.copyfile(folder / f"r{MAPPING[code]}" / f"page-{page}.png", dest)
            paths.append(dest)
    for name in WINDOWS:
        path = blind / (name + ".png")
        triple_panel(folder, name, CODES).save(path)
        paths.append(path)
    prompt = (
        BRIEF
        + "\n比较三份匿名成稿 S7Q、D5K、W2L，可选任意一份或拒交。前六幅依次为各份两页全稿。接着每幅是同一部位三组原尺寸像素，顺序为图上编号，从上至下读取。优先关注公式、表格、流程和波形是否可读，以及笔迹曝光、软硬和局部透视是否符合周围真实纸面。若候选水平相当请选择 tied 并列出等同编号，不要猜测版本；若不能交请选择 reject。仅输出 JSON {choice, equivalent_codes:[], reason, observed_limitations}。不要使用工具。"
    )
    verdict = opinion(blind / "vote", prompt, paths)
    code = verdict["choice"]
    if code == "tied":
        ties = verdict["equivalent_codes"]
        if not ties or not set(ties) <= set(CODES):
            raise ValueError(verdict)
        # Frozen tie-break: keep the least-changed admissible version.
        code = min(ties, key=MAPPING.get)
    selected = MAPPING.get(code)
    if selected is None and code != "reject":
        raise ValueError(verdict)
    with Server(cfg, folder / "home", "final_selection", log_dir=folder) as s:
        actor = invoke(s, "read_rsi_task", task_id=actor["task_id"])
        if actor["status"] == "active":
            actor = advance(
                s,
                actor,
                folder,
                selected or 3,
                "select" if selected else "stop",
                verdict["reason"],
            )
        write(folder / "challenge-native-outcome.json", actor)
        selected_pdf = (
            export(s, draft, selected, folder, "selected") if selected else None
        )
    write(
        out / "selection-summary.json",
        {
            "guided_revision": 1,
            "blind_verdict": verdict,
            "selected_revision": selected,
            "selected_pdf": selected_pdf,
            "model_receipt": read(blind / "vote/receipt.json"),
            "task_id": actor["task_id"],
            "binary_sha256": manifest["binary_sha256"],
        },
    )
    print(selected, verdict, flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    a = parser.parse_args()
    run(a.out.resolve(), a.binary.resolve(strict=True))
