"""Test whether ordinary homework agents choose which retrieved rules apply."""

import argparse
from pathlib import Path

import pymupdf
from benchmark import Server, digest, read, save_image, write
from content_matrix import CASES, opinion
from experience_audit import calls
from experience_bm25 import clone_home, table
from experience_sessions import run_case
from experience_validation import invoke
from PIL import Image, ImageChops

DELIVERY = "请交一页手写 PDF。交稿时在聊天里简述你实际采用或跳过了哪些检查，以及原因。"
BRIEFS = {
    "text": CASES["text"]["brief"] + DELIVERY,
    "mixed": "请帮我核对已有的《轨道小车观测记录》。实验底单上，0、3、6 秒三次观测的位移依次是 0、7、13 米。成稿要有一张带表头的两列表格，表下用一句话说明位移随时间怎样变化，不要画流程图。"
    + DELIVERY,
}
SEED = table([(0, 0), (3, 9), (6, 13)]) + "\n\n小车的位移随时间增大。"
READBACK = """请只根据这张成稿图片读卷，不使用工具。逐段转录能看清的文字。
如有表格，逐行抄出表头与每个单元格。如有流程图，记录节点和箭头。
数清表格、流程图和独立公式的数量。看不清的地方标注不确定，不补写。
返回 JSON，字段为 paragraphs、tables、flowcharts、formula_count、uncertain。"""


def run(cfg, root, name):
    folder = root / name
    folder.mkdir(parents=True, exist_ok=False)
    home = folder / "home"
    clone_home(Path(cfg["home"]), home)
    runtime = cfg | {"home": str(home)}
    if name == "mixed":
        with Server(runtime, home, "prepare-draft", log_dir=folder) as s:
            draft = invoke(
                s,
                "save_section",
                title="轨道小车观测记录",
                style={"homework": True},
                markdown=SEED,
            )
            save_image(
                s.call(
                    "preview_handwriting",
                    draft_id=draft["draft_id"],
                    section=1,
                    page=1,
                    revision=1,
                    view="image",
                ),
                folder / "before.png",
            )
            write(
                folder / "seed.json",
                {"draft_id": draft["draft_id"], "revision": 1, "markdown": SEED},
            )
    run_case(runtime, name, folder / "actor", BRIEFS[name])


def audit(root, name):
    folder = root / name
    actor = folder / "actor"
    receipt = read(actor / "receipt.json")
    trace = calls(actor)
    exports = [
        c["response"]
        for c in trace
        if c["tool"] == "export_handwriting" and not c["error"]
    ]
    if not exports:
        raise ValueError(
            f"No successful native export in {name}. Inspect the retained trace."
        )
    final = exports[-1]
    cfg = read(actor / "native-runtime.json")
    key = {k: final[k] for k in ("draft_id", "revision")}
    with Server(
        cfg, Path(cfg["home"]), "post-delivery-readback", log_dir=folder
    ) as server:
        source = invoke(
            server, "read_section", **key, section=1, view="source", limit=4000
        )["markdown"]
        save_image(
            server.call("preview_handwriting", **key, section=1, page=1, view="image"),
            folder / "native.png",
        )
    pdf_path = Path(final["path"])
    image_path = folder / "delivery.png"
    with pymupdf.open(pdf_path) as doc, Image.open(folder / "native.png") as native:
        if len(doc) != 1 or len(doc[0].get_images()) != 1:
            raise ValueError(
                "This study expects a single-page, single-raster homework PDF."
            )
        page = doc[0]
        pix = pymupdf.Pixmap(doc, page.get_images()[0][0])
        assert (
            native.size == (pix.width, pix.height)
            and native.convert("RGB").tobytes() == pix.samples
        )
        page.get_pixmap(
            matrix=pymupdf.Matrix(
                pix.width / page.rect.width, pix.height / page.rect.height
            ),
            alpha=False,
        ).save(image_path)
    blind = opinion(folder / "blind", READBACK, [image_path])
    searches = []
    actions = []
    for i, c in enumerate(trace, 1):
        args = c["arguments"]
        if c["tool"] == "search_homework_experience":
            searches.append(
                {
                    "call": i,
                    "arguments": args,
                    "hits": [
                        {k: r[k] for k in ("rule_id", "status", "scope", "action")}
                        for r in c["response"]["rules"]
                    ],
                }
            )
        actions.append(
            {
                "tool": c["tool"],
                "error": c.get("error"),
                "arguments": {
                    k: v
                    for k, v in args.items()
                    if k
                    in (
                        "view",
                        "revision",
                        "compare_revision",
                        "region",
                        "section",
                        "page",
                        "expected_revision",
                        "rule_id",
                        "markdown",
                        "rules",
                    )
                },
                "review_id": c.get("response", {}).get("review_id"),
            }
        )
    reply = (actor / "final.txt").read_text(encoding="utf-8")
    reply = "\n".join(
        "[本机取件路径已省略]" if ":\\" in line or ":/" in line else line
        for line in reply.splitlines()
    )
    result = {
        "case": name,
        "prompt": (actor / "prompt.txt").read_text(encoding="utf-8"),
        "actor": receipt,
        "searches": searches,
        "actions": actions,
        "delivery_reply_without_local_path": reply.strip(),
        "export": {
            **key,
            "export_id": final["export_id"],
            "pages": final["pages"],
            "pdf_sha256": digest(pdf_path.read_bytes()),
            "embedded_pixels_equal_native": True,
            "rendered_page_sha256": digest(image_path.read_bytes()),
        },
        "delivered_source": source,
        "blind_prompt": READBACK,
        "blind_readback": blind,
        "blind_receipt": read(folder / "blind/receipt.json"),
    }
    if name == "mixed":
        result["original"] = read(folder / "seed.json")
        result["original_image_sha256"] = digest((folder / "before.png").read_bytes())
        with (
            Image.open(folder / "before.png") as before,
            Image.open(folder / "native.png") as after,
        ):
            assert before.size == after.size
            delta = ImageChops.difference(before.convert("RGB"), after.convert("RGB"))
            result["changed_native_pixel_bounds_xyxy"] = delta.getbbox()
    write(folder / "audit.json", result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=BRIEFS)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--audit", action="store_true")
    args = parser.parse_args()
    if args.audit:
        audit(args.out.resolve(), args.case)
    else:
        run(read(args.config), args.out.resolve(), args.case)
