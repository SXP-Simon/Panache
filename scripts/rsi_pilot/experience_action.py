"""Verify an actual discovered display-math rule by implementing its precise action on a new draft."""

import argparse
from pathlib import Path

from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from experience_output import native_content
from experience_validation import VALIDATION_CASES, invoke, refs, verify
from PIL import Image


def positive(cfg, root, rule_id):
    d = root / "validation/package-fault"
    base = read(d / "artifact.json")
    outcome = d / ("positive-" + rule_id + ".json")
    if outcome.exists():
        raise ValueError(
            "Existing validation is immutable; choose a separate source cohort."
        )
    blind = verify(root, "package-fault")
    if blind["decision"] != "repair":
        raise ValueError("Independent observer could not identify the in-scope defect.")
    with Server(cfg, Path(cfg["home"]), "independent_action_test", log_dir=d) as s:
        rule = invoke(s, "read_homework_experience", rule_id=rule_id)
        if rule["status"] not in {"pending", "active"}:
            raise ValueError("Source is not eligible for validation")
        if (d / "corrected.json").exists():
            after = read(d / "corrected.json")
        else:
            src = VALIDATION_CASES["package-fault"]["source"]
            wrong = r"$$\nicefrac{6}{11}$$"
            replacement = r"$$\frac{6}{11}$$"
            assert src.count(wrong) == 1
            edited = invoke(
                s,
                "save_section",
                draft_id=base["draft_id"],
                expected_revision=1,
                section=1,
                markdown=src.replace(wrong, replacement),
            )
            k = {
                "draft_id": base["draft_id"],
                "revision": edited["revision"],
                "page": 1,
                "section": 1,
            }
            rev = invoke(s, "preview_handwriting", **k, view="review")
            save_image(
                s.call("preview_handwriting", **k, view="image"),
                d / "corrected-page.png",
            )
            with Image.open(d / "corrected-page.png") as im:
                native_content(im).save(d / "corrected-content.png")
            out = invoke(
                s,
                "export_handwriting",
                draft_id=base["draft_id"],
                revision=edited["revision"],
                format="pdf",
            )
            after = {
                "draft_id": base["draft_id"],
                "revision": edited["revision"],
                "review_id": rev["review_id"],
                "export_id": out["export_id"],
                "source_sha256": digest(src.replace(wrong, replacement).encode()),
                "pdf_sha256": digest(Path(out["path"]).read_bytes()),
                "page_sha256": digest((d / "corrected-page.png").read_bytes()),
            }
            write(d / "corrected.json", after)
        prompt = (
            base["brief"]
            + "\n请独立转录两处内容，判断照抄命令和最终排版是否满足题意，给出 JSON {decision:accept或repair或uncertain,transcription,reason}。不要使用工具。"
        )
        final = opinion(d / "after-blind", prompt, [d / "corrected-content.png"])
        # These are observations on *two different native revisions*. Only actual before/after
        # results score the executed action; a hypothetical assessment is not a pre-edit grade.
        if blind["decision"] not in {"repair", "accept"} or final["decision"] not in {
            "repair",
            "accept",
        }:
            raise ValueError(
                "Inconclusive actual pixel readback; no terminal native vote"
            )
        passed = blind["decision"] == "repair" and final["decision"] == "accept"
        outcome_preview = {
            "before_on_original": blind,
            "after_on_corrected": final,
            "score": passed,
        }
        write(d / "action-score-before-submission.json", outcome_preview)
        args = refs(after)
        args["reviews"].insert(0, {"review_id": base["review_id"], "revision": 1})
        r = invoke(
            s,
            "validate_homework_experience",
            rule_id=rule_id,
            kind="positive",
            passed=passed,
            reason="独立新稿：原图 "
            + blind["decision"]
            + "；按规则只替换显示公式，保留原模板行。独立重读："
            + final["reason"],
            **args,
        )
    write(
        d / ("positive-" + rule_id + ".json"),
        {
            "rule_id": rule_id,
            "kind": "positive",
            "passed": passed,
            "blind": blind,
            "ballot": {"before_on_original": blind, "after_on_corrected": final},
            "real_action": "Preserve literal inline code; replace just the display math nicefrac with frac.",
            "before": base,
            "after": after,
            "after_blind": final,
            "after_receipt": read(d / "after-blind/receipt.json"),
            "result": r,
        },
    )
    print(r, flush=True)


def transfer_seed(cfg, root):
    folder = root / "transfer-input"
    folder.mkdir(exist_ok=False)
    # New subject and numbers unrelated to the source physics speed table.
    literal = r"\nicefrac{3}{24}"
    src = f"化学实验　盐水质量分数\n\n盐水总质量 24 g，盐的质量 3 g。\n\n旧模板输入：`{literal}`\n\n质量分数：\n\n$$w={literal}=12.5\\%$$"
    with Server(
        cfg, Path(cfg["home"]), "ordinary_chemistry_draft", log_dir=folder
    ) as s:
        new = invoke(
            s,
            "save_section",
            title="盐水质量分数",
            markdown=src,
            style={"homework": True, "seed": 7882},
        )
        draft = new["draft_id"]
        save_image(
            s.call(
                "preview_handwriting",
                draft_id=draft,
                revision=1,
                section=1,
                page=1,
                view="image",
            ),
            folder / "before.png",
        )
    write(
        folder / "seed.json",
        {
            "draft_id": draft,
            "source": src,
            "revision": 1,
            "source_sha256": digest(src.encode()),
        },
    )
    prompt = "请帮我把 Panache 里已有的《盐水质量分数》改成可以交的手写化学实验作业。24 g 盐水里有 3 g 盐，算质量分数。旧教材那行模板输入要原样留给组员照抄，下面的计算要让老师直接看到上下分数和百分数。请看看现在的成稿，按题意修好，检查后交一页 PDF。"
    (folder / "prompt.txt").write_text(prompt, encoding="utf8")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("phase", choices=["positive", "transfer-seed"])
    p.add_argument("--config", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--rule")
    a = p.parse_args()
    cfg = read(a.config)
    root = a.out.resolve()
    if a.phase == "positive":
        positive(cfg, root, a.rule)
    else:
        transfer_seed(cfg, root)
