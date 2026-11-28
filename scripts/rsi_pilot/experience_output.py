"""Audit final native PDFs and independently read the actual exported homework images."""

import argparse
import json
from pathlib import Path

import pymupdf
from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from experience_audit import calls
from experience_validation import invoke
from PIL import Image, ImageDraw


def native_content(img):
    gray = img.convert("L")
    bound = gray.point(lambda v: 255 if v < 125 else 0).getbbox()
    if not bound:
        raise ValueError("No rendered ink")
    x, y, r, b = bound
    return img.crop(
        (
            max(0, x - 24),
            max(0, y - 24),
            min(img.width, r + 24),
            min(img.height, b + 24),
        )
    ).convert("RGB")


def audit(folder):
    cfg = read(folder / "native-runtime.json")
    trajectory = calls(folder)
    exports = [
        v
        for v in trajectory
        if v["tool"] == "export_handwriting" and v.get("response", {}).get("export_id")
    ]
    if not exports:
        raise ValueError("No successful actor export")
    final = exports[-1]["response"]
    destination = folder / "auditor"
    destination.mkdir(exist_ok=True)
    images = []
    verified = []
    with (
        Server(
            cfg, Path(cfg["home"]), "auditor_after_delivery", log_dir=destination
        ) as s,
        pymupdf.open(final["path"]) as pdf,
    ):
        for page in pdf:
            idx = page.number + 1
            # These one-section study tasks must not silently use a section-local page for a multi-section PDF.
            sec = invoke(
                s,
                "read_section",
                draft_id=final["draft_id"],
                revision=final["revision"],
                section=1,
                view="source",
                limit=4000,
            )
            if len(pdf) != final["pages"] or final["pages"] != 1:
                raise ValueError("Expected one physical page")
            path = destination / f"page-{idx}.png"
            save_image(
                s.call(
                    "preview_handwriting",
                    draft_id=final["draft_id"],
                    revision=final["revision"],
                    section=1,
                    page=idx,
                    view="image",
                ),
                path,
            )
            imgs = page.get_images()
            if len(imgs) != 1:
                raise ValueError("Expected one embedded native RGB image")
            pix = pymupdf.Pixmap(pdf, imgs[0][0])
            with Image.open(path) as im:
                if pix.samples != im.convert("RGB").tobytes():
                    raise ValueError("Preview and PDF disagree")
                detail = destination / f"content-{idx}.png"
                native_content(im).save(detail)
            images.append(detail)
            verified.append(
                {
                    "page": idx,
                    "pixel_width": pix.width,
                    "pixel_height": pix.height,
                    "png_sha256": digest(path.read_bytes()),
                    "native_rgb_equal_pdf": True,
                }
            )
    user = (folder / "prompt.txt").read_text(encoding="utf8")
    prompt = (
        user
        + "\n这里是最终 PDF 实际嵌入图片的原尺寸内容。只按成稿本身转录键盘输入、排好的分子／分母和结果，按原题回答是否满足。仅返回 JSON {decision:accept或repair或uncertain,transcription,reason}。不要用工具。"
    )
    vote = opinion(destination / "readback", prompt, images)
    report = {
        "draft_id": final["draft_id"],
        "revision": final["revision"],
        "export_id": final["export_id"],
        "pdf_sha256": digest(Path(final["path"]).read_bytes()),
        "verified_pages": verified,
        "final_source": sec["markdown"],
        "independent_vote": vote,
        "receipt": read(destination / "readback/receipt.json"),
    }
    write(destination / "audit.json", report)
    print(json.dumps(report, ensure_ascii=False)[:550], flush=True)


def panel(out, folders):
    items = []
    for label, path in folders:
        with Image.open(path) as im:
            items.append((label, native_content(im)))
    w = max(i.width for _, i in items)
    sheet = Image.new("RGB", (w + 16, sum(i.height + 33 for _, i in items)), "white")
    draw = ImageDraw.Draw(sheet)
    y = 0
    for label, im in items:
        draw.text((8, y + 2), label, fill="#151515")
        sheet.paste(im, (8, y + 22))
        y += im.height + 33
    sheet.save(out)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--session", type=Path, required=True)
    p.add_argument("--assets-out", type=Path)
    a = p.parse_args()
    session = a.session.resolve()
    audit(session)
    if a.assets_out:
        dest = a.assets_out.resolve()
        dest.mkdir(exist_ok=True, parents=True)
        base = session.parent
        panel(
            dest / "experience-chemistry-transfer.png",
            [
                (
                    "Before | literal template command also printed in result",
                    base / "transfer-input/before.png",
                ),
                (
                    "Delivered PDF | template preserved, displayed fraction and percentage",
                    session / "auditor/page-1.png",
                ),
            ],
        )
        panel(
            dest / "experience-verified-examples.png",
            [
                (
                    "In scope | initial native display failed",
                    base / "validation/package-fault/page.png",
                ),
                (
                    "After the actual selective edit | independently accepted",
                    base / "validation/package-fault/corrected-page.png",
                ),
                (
                    "Boundary | correct template and output, no edit needed",
                    base / "validation/package-boundary/page.png",
                ),
                (
                    "Counterexample | always reject backslash would block this correct page",
                    base / "validation/decoy-counterexample/page.png",
                ),
            ],
        )
