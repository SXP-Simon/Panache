"""Independent known-answer cases, blinded checks, and native experience validation.

The operator owns these controlled cases and the two decoy rules. The origin/transfer tutors
are free-running MCP clients. This evaluator does not supply them with identifiers or prompts.
"""

import argparse
import json
from pathlib import Path

from benchmark import Server, digest, read, save_image, write
from content_matrix import opinion
from PIL import Image

VALIDATION_CASES = {
    "decoy-source": {
        "brief": "直接写出五分之一的分式。",
        "source": r"""分数辨认

$$\badfrac{1}{5}$$""",
        "expected": "repair",
    },
    "package-fault": {
        "brief": "旧模板的输入示例需要保留，同时要让下面的显示行真正排成十一分之六。",
        "source": r"""命令对照　十一分之六

模板输入：`\nicefrac{6}{11}`

最终显示：

$$\nicefrac{6}{11}$$""",
        "expected": "repair",
    },
    "package-boundary": {
        "brief": "请保留源模板中演示四分之一的命令，然后另起一行展示正确的分数。",
        "source": r"""模板说明　四分之一

可复制输入：`\nicefrac{1}{4}`

实际结果：

$$\frac{1}{4}$$""",
        "expected": "accept",
    },
    "candidate-fault": {
        "brief": "为新手写出三分之二的 LaTeX 输入命令，并另起一行展示排好的分式。",
        "source": r"""分式输入和显示

键盘输入：`\frac{2}{3}`

排版结果：

$$\badfrac{2}{3}$$""",
        "expected": "repair",
    },
    "candidate-boundary": {
        "brief": "写一个 LaTeX 输入例子：一行可照抄的源码，下一行展示排好的五分之二。",
        "source": r"""输入练习　五分之二

源码：`\frac{2}{5}`

排版结果：

$$\frac{2}{5}$$""",
        "expected": "accept",
    },
    "decoy-fault": {
        "brief": "直接写出五分之三的分式。仅交排好的算式。",
        "source": r"""分式计算

$$\badfrac{3}{5}$$""",
        "expected": "repair",
    },
    "decoy-simple": {
        "brief": "请以排好版的分式写出八分之三，不用显示键盘输入。",
        "source": r"""分式计算

$$\frac{3}{8}$$""",
        "expected": "accept",
    },
    "decoy-counterexample": {
        "brief": "给同桌演示如何用 LaTeX 写四分之七，保留一行可复制的原始命令，再另起一行排出对应分式。",
        "source": r"""排版练习　四分之七

可复制输入：`\frac{7}{4}`

排版输出：

$$\frac{7}{4}$$""",
        "expected": "accept",
    },
}


def invoke(server, name, **args):
    return server.call(name, **args)["structuredContent"]


def seed_fault(cfg, folder, numerator, denominator):
    """Prepare an actual student draft. The subsequent actor receives only its handle and ordinary request."""
    folder.mkdir(parents=True, exist_ok=False)
    correct = rf"\frac{{{numerator}}}{{{denominator}}}"
    wrong = rf"\fracc{{{numerator}}}{{{denominator}}}"
    source = f"手写排版练习\n\n照抄的输入：\n\n`{correct}`\n\n排版结果：\n\n$${wrong}$$\n\n分母是 {denominator}。"
    with Server(
        cfg, Path(cfg["home"]), "operator_prepares_student_draft", log_dir=folder
    ) as server:
        r = invoke(
            server,
            "save_section",
            markdown=source,
            title="分数排版练习",
            style={"homework": True, "seed": 4253},
        )
        d = r["draft_id"]
        save_image(
            server.call(
                "preview_handwriting",
                draft_id=d,
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
            "draft_id": d,
            "revision": 1,
            "source": source,
            "expected": [numerator, denominator],
            "initiator": "operator seeded a genuine rendered typo; actor decides the repair and any subsequent reflection",
        },
    )
    prompt = f"请帮我改已有的 Panache 手写作业，草稿编号 {d}。它要教同学输入并显示 {numerator}/{denominator}。老师说纸上的例子有一行印错了。我需要知道原来的纸面到底显示了什么，改好后又显示成什么，请先看旧稿的实际页面，再修好。交一页 PDF，保留可以照抄的 LaTeX 命令和下面排出来的分式。"
    (folder / "ordinary-prompt.txt").write_text(prompt, encoding="utf8")
    print(d, flush=True)


def seed_package_example(cfg, folder):
    """A preserved legacy template example and an independently broken rendered output."""
    folder.mkdir(parents=True, exist_ok=False)
    literal = r"\nicefrac{7}{9}"
    source = f"旧模板分数练习\n\n原模板输入：\n\n`{literal}`\n\n排版结果：\n\n$${literal}$$\n\n分子是 7，分母是 9。"
    with Server(
        cfg, Path(cfg["home"]), "operator_prepares_legacy_template", log_dir=folder
    ) as server:
        r = invoke(
            server,
            "save_section",
            markdown=source,
            title="旧模板分数练习",
            style={"homework": True, "seed": 7229},
        )
        d = r["draft_id"]
        save_image(
            server.call(
                "preview_handwriting",
                draft_id=d,
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
            "draft_id": d,
            "revision": 1,
            "source": source,
            "initiator": "Operator seed after discovering the old template command survives in the worker output.",
        },
    )
    prompt = f"我把旧 LaTeX 模板的例题做成了 Panache 手写讲义，草稿是 {d}。请先看看现在纸上两处各印出了什么，然后把它修成一页可发给同学的 PDF。标着“原模板输入”的那一行要照原稿保持，下面的结果要变成七在上、九在下的分数，不要混成同一种表示。最后告诉我你改了哪一处。"
    (folder / "ordinary-prompt.txt").write_text(prompt, encoding="utf8")
    print(d, flush=True)


def seed_repeated_template(cfg, folder):
    folder.mkdir(parents=True, exist_ok=False)
    nines = [("甲", r"\nicefrac{2}{3}"), ("乙", r"\sfrac{5}{6}")]
    sections = ["分数录入对照　旧版讲义"]
    for name, command in nines:
        sections.extend(
            [
                f"例{name}，模板输入：`{command}`",
                f"例{name}，实际显示：",
                f"$${command}$$",
            ]
        )
    src = "\n\n".join(sections)
    with Server(
        cfg, Path(cfg["home"]), "operator_prepares_two_legacy_examples", log_dir=folder
    ) as s:
        draft = invoke(
            s,
            "save_section",
            title="分数录入对照",
            markdown=src,
            style={"homework": True, "seed": 9387},
        )["draft_id"]
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
            "revision": 1,
            "source": src,
            "initiator": "operator prepared two actual legacy-template incompatibilities",
        },
    )
    prompt = f"请帮我批改这张已有的 Panache 分数录入讲义，草稿 {draft}。我下周还要用这两种旧模板，例甲、例乙的模板输入都要照原样留给同学。两处实际显示应分别是三分之二、六分之五，按上下分数写。请看原来的手写页，修好不合要求的地方，逐项确认两例都能读，交一页 PDF 并告诉我改前与改后各是什么样。"
    (folder / "ordinary-prompt.txt").write_text(prompt, encoding="utf8")
    print(draft, flush=True)


def fixtures(cfg, out):
    fixtures = out / "validation"
    fixtures.mkdir(exist_ok=True)
    for code, case in VALIDATION_CASES.items():
        d = fixtures / code
        d.mkdir(exist_ok=True)
        if (d / "artifact.json").exists():
            continue
        with Server(cfg, Path(cfg["home"]), "operator_known_answer", log_dir=d) as s:
            created = invoke(
                s,
                "save_section",
                markdown=case["source"],
                title="课堂练习",
                style={"homework": True, "seed": 9245},
            )
            draft = created["draft_id"]
            rev = created["revision"]
            key = {"draft_id": draft, "revision": rev, "section": 1, "page": 1}
            inspect = invoke(s, "preview_handwriting", **key, view="review")
            save_image(
                s.call("preview_handwriting", **key, view="image"), d / "page.png"
            )
            export = invoke(
                s, "export_handwriting", draft_id=draft, revision=rev, format="pdf"
            )
            assert export["pages"] == 1
        # This monochrome page has no original photograph. Give the judge the entire native content at 1:1.
        with Image.open(d / "page.png") as img:
            lum = img.convert("L")
            box = lum.point(lambda p: 255 if p < 125 else 0).getbbox()
            if not box:
                raise ValueError("No ink")
            x1, y1, x2, y2 = box
            img.crop(
                (
                    max(0, x1 - 30),
                    max(0, y1 - 30),
                    min(img.width, x2 + 30),
                    min(img.height, y2 + 30),
                )
            ).convert("RGB").save(d / "content.png")
        write(
            d / "artifact.json",
            {
                "brief": case["brief"],
                "expected": case["expected"],
                "draft_id": draft,
                "revision": rev,
                "review_id": inspect["review_id"],
                "export_id": export["export_id"],
                "source_sha256": digest(case["source"].encode()),
                "page_sha256": digest((d / "page.png").read_bytes()),
                "content_sha256": digest((d / "content.png").read_bytes()),
            },
        )
    print("Native evaluation fixtures ready", flush=True)


def verify(out, code, rule=None):
    d = out / "validation" / code
    meta = read(d / "artifact.json")
    prompt = (
        meta["brief"]
        + "\n你收到的是这一份成稿的可见内容。各行实际显示了什么？按题意决定可交 accept、返工 repair 或 uncertain，指出具体证据。请只输出 JSON {decision,transcription,reason}。不要使用工具。"
    )
    if rule:
        prompt += (
            "\n接下来只给当前这张尚未改过的原图打分，不预测修改以后的效果：若严格照下述规则，当前图是否要返工？即使你不同意规则，也分别返回 pre_edit_rule_disposition（accept 表示现在即可交、repair 表示现在须返工、uncertain 表示无法判断）及 pre_edit_reason。经验适用范围及动作："
            + json.dumps(
                {k: rule[k] for k in ["scope", "action", "reason"]}, ensure_ascii=False
            )
        )
    ballot = opinion(
        d / ("current-page-ballot-" + rule["rule_id"] if rule else "blind"),
        prompt,
        [d / "content.png"],
    )
    return ballot


def refs(a):
    return {
        "draft_id": a["draft_id"],
        "revision": a["revision"],
        "export_id": a["export_id"],
        "reviews": [{"revision": a["revision"], "review_id": a["review_id"]}],
    }


def validate(cfg, out, rule_id, kind, code):
    d = out / "validation" / code
    meta = read(d / "artifact.json")
    outcome = d / (kind + "-" + rule_id + ".json")
    if outcome.exists():
        raise ValueError("An existing validation record must not be overwritten")
    blind = verify(out, code)
    with Server(cfg, Path(cfg["home"]), "operator_validation", log_dir=d) as s:
        lookup = invoke(s, "read_homework_experience", rule_id=rule_id)
        rule = lookup.get("rule", lookup)
        ballot = verify(out, code, rule)
        if blind["decision"] not in {"accept", "repair"} or ballot.get(
            "pre_edit_rule_disposition"
        ) not in {"accept", "repair"}:
            raise ValueError(
                "Inconclusive pre-edit disposition. No validation submitted."
            )
        passed = (
            blind["decision"] == meta["expected"]
            and ballot["pre_edit_rule_disposition"] == meta["expected"]
        )
        if kind == "positive" and meta["expected"] != "repair":
            raise ValueError("Positive is the held-out concrete defect")
        record = invoke(
            s,
            "validate_homework_experience",
            rule_id=rule_id,
            kind=kind,
            passed=passed,
            reason=f"Known target {meta['expected']}. Independent image-only: {blind['decision']}; rule application: {ballot['pre_edit_rule_disposition']}. "
            + ballot["pre_edit_reason"],
            **refs(meta),
        )
    write(
        d / (kind + "-" + rule_id + ".json"),
        {
            "rule_id": rule_id,
            "kind": kind,
            "passed": passed,
            "blind": blind,
            "ballot": ballot,
            "result": record,
        },
    )
    print(record, flush=True)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "phase",
        choices=[
            "fixtures",
            "blind",
            "validate",
            "seed-fault",
            "seed-package",
            "seed-repeated",
        ],
    )
    p.add_argument("--config", required=True, type=Path)
    p.add_argument("--out", required=True, type=Path)
    p.add_argument("--case", choices=VALIDATION_CASES)
    p.add_argument("--rule")
    p.add_argument("--kind", choices=["positive", "boundary"])
    a = p.parse_args()
    cfg = read(a.config)
    root = a.out.resolve()
    if a.phase == "seed-repeated":
        seed_repeated_template(cfg, root)
    elif a.phase == "seed-package":
        seed_package_example(cfg, root)
    elif a.phase == "seed-fault":
        seed_fault(cfg, root, 5, 8)
    elif a.phase == "fixtures":
        fixtures(cfg, root)
    elif a.phase == "blind":
        print(verify(root, a.case))
    else:
        validate(cfg, root, a.rule, a.kind, a.case)
