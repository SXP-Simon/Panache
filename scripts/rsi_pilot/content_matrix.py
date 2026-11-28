"""Prospective homework-content matrix through the local MCP and a fresh Terra author/reviewer.

Run freeze before author or episode. Inspect manifest.json for the frozen briefs/expectations.
Raw MCP calls, model receipts and native evidence stay in --out. Packets contain generated paper.
"""

import argparse
import json
import re
import secrets
import sqlite3
import unicodedata
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from benchmark import Server, digest, read, save_image, write
from codex_judge import run as judge
from PIL import Image, ImageChops, ImageDraw, ImageStat

MODEL = "gpt-6.1-terra"
CASES = {
    "text": {
        "brief": "写一页纯文字的野外观测记录，按上午、午后、傍晚三段分别解释露珠、云影、晚霞的形成。三段包含相应时段和现象名称。每段一至两句，勿加公式、图或表。",
        "tokens": ["上午", "露珠", "午后", "云影", "傍晚", "晚霞"],
        "concepts": [
            "condensation near cooled surfaces",
            "clouds blocking sunlight",
            "long optical path / scattering",
        ],
    },
    "formula": {
        "brief": "推导并求解并联电阻。电阻 R₁=6 Ω、R₂=3 Ω，电压 U=12 V。至少分三行展现等效电阻、总电流与功率的计算。等效电阻一步必须写成上下堆叠的分式；给出每个结果及单位。不要画图或表格。",
        "tokens": ["6", "3", "12", "2", "6", "72"],
        "concepts": [
            "R_eq = 2 Ω",
            "I = 6 A",
            "P = 72 W",
            "at least one stacked fraction",
            "at least three calculation lines",
        ],
        "fractions": 1,
    },
    "table1": {
        "brief": "完成匀速小车记录：时间 t/s 依次是 0、2、4，位移 x/m 依次是 0、6、12。做一张带表头的两列表格，三行一一对应；表后另写平均速度公式，代数值算出速度和单位。不要附图。",
        "tokens": ["0", "2", "4", "6", "12", "3"],
        "tables": [[["0", "0"], ["2", "6"], ["4", "12"]]],
        "concepts": [
            "two column headings identify time and distance",
            "average speed = Δx/Δt = 3 m/s",
        ],
    },
    "table2": {
        "brief": "比较两种储能方案。第一张表列项目和数值：方案甲输入能量 50 J、输出能量 40 J。第二张独立的表列项目和数值：方案乙输入 80 J、输出 60 J。两表各要有表头和输入、输出两行。表外写效率公式，并分别计算两方案效率和相差的百分点。不要画图。",
        "tokens": ["甲", "乙", "50", "40", "80", "60", "75", "5"],
        "tables": [[["输入", "50"], ["输出", "40"]], [["输入", "80"], ["输出", "60"]]],
        "concepts": [
            "η = output/input",
            "甲 80%, 乙 75%, difference 5 percentage points",
        ],
    },
    "flow1": {
        "brief": "为温室控制作业画一张带箭头的流程图。用四个节点“读温度”“超温”“开风扇”“保持”，从读温度到条件节点超温，两条边分别以“是”“否”到开风扇和保持。图外一句话解释 30 ℃ 阈值。不使用表格。",
        "tokens": ["30"],
        "graphs": [
            {
                "nodes": ["读温度", "超温", "开风扇", "保持"],
                "edges": [
                    ["读温度", "超温", ""],
                    ["超温", "开风扇", "是"],
                    ["超温", "保持", "否"],
                ],
            }
        ],
        "concepts": ["阈值 30 ℃ and correct conditional actions"],
    },
    "flow2": {
        "brief": "画两张分开的带箭头流程图。图一用于借书：节点“查书”“有库存”“借出”“预约”，查书后判断库存，“是”通往借出，“否”通往预约。图二用于交卷：节点“验卷”“已署名”“收卷”“补签”，验卷后判断署名，“是”通往收卷，“否”通往补签。保留这些节点、每条有向连接和分支文字，另写一句话说明两流程用途。",
        "tokens": [],
        "graphs": [
            {
                "nodes": ["查书", "有库存", "借出", "预约"],
                "edges": [
                    ["查书", "有库存", ""],
                    ["有库存", "借出", "是"],
                    ["有库存", "预约", "否"],
                ],
            },
            {
                "nodes": ["验卷", "已署名", "收卷", "补签"],
                "edges": [
                    ["验卷", "已署名", ""],
                    ["已署名", "收卷", "是"],
                    ["已署名", "补签", "否"],
                ],
            },
        ],
        "concepts": ["two visually separate workflows and correct branch labels"],
    },
    "combined": {
        "brief": "完成酸碱判别练习：用带表头的两列表格列出“样品甲 / 3”“样品乙 / 9”作为各自 pH。表外写公式 pH = −log₁₀[H⁺]。再画一张有箭头的流程图，节点用“读数”“小于7”“酸性”“非酸性”，从读数到小于7，分支“是”到酸性、“否”到非酸性。最后说明两个样品分别被分到哪一类。",
        "tokens": ["甲", "乙", "3", "9", "pH", "log", "H"],
        "tables": [[["甲", "3"], ["乙", "9"]]],
        "graphs": [
            {
                "nodes": ["读数", "小于7", "酸性", "非酸性"],
                "edges": [
                    ["读数", "小于7", ""],
                    ["小于7", "酸性", "是"],
                    ["小于7", "非酸性", "否"],
                ],
            }
        ],
        "concepts": [
            "log base 10, negative sign, H superscript plus",
            "甲 acidic; 乙 non-acidic",
        ],
    },
}

HINTS = r"""Panache save_section takes one complete Markdown section. Use plain paragraphs, standard Markdown pipe tables, and LaTeX math when appropriate. For new flowcharts Panache documents this native syntax (raw markup, outside code fences):
\begin{circuitikz}[flowchart]
\draw (0,0) node[rectangle]{B1};
\draw (0,-2) node[diamond]{B2};
\draw[->] (0,0) -- (0,-2) node[midway,right]{i≤10};
\end{circuitikz}
Use a separate circuitikz block per requested diagram. Nodes and paths share coordinates; provide space for labels."""
AUTHOR = "你是手写作业作者。只根据题面和 Panache 写稿工具提示解答，用中文写可直接保存的 Markdown。只输出单个 JSON 对象，字段 markdown 为完整字符串。不得调用任何工具或访问文件。"
REVIEW = """你是 Panache 宿主的视觉复查模型。检查所有随附的真实页面、题面和当前 Markdown。判断逐项是否完成，包括数值、表格单元、图中节点、箭头方向和分支标注。仅据可见图像判断呈现，源代码不能证明标签、分式或表格已经写出来；在图像证据不足时指出不确定性。你可选择一轮修正机会。只输出 JSON，action=select、stop、replace 或 tune，reason 描述具体问题或验收依据；replace 附 markdown 整节完整替换，tune 附 changes 对象。若必须改题意内容，用 replace。不要访问文件或工具。"""


def paper_image(path):
    image = Image.new("RGB", (1200, 1650), "#fffdf5")
    draw = ImageDraw.Draw(image)
    for y in range(120, 1570, 50):
        draw.line((78, y, 1122, y), fill="#ccd8da", width=1)
    image.save(path)


def freeze(args):
    out = args.out
    out.mkdir(parents=True, exist_ok=True)
    cfg = {
        k: str(getattr(args, k).resolve(strict=True))
        for k in ("binary", "worker", "fonts")
    }
    cfg["binary_sha256"] = digest(Path(cfg["binary"]).read_bytes())
    cfg["worker_sha256"] = digest(Path(cfg["worker"]).read_bytes())
    cfg["font_sha256"] = digest((Path(cfg["fonts"]) / "李国夫手写体.ttf").read_bytes())
    if not (out / "paper.png").exists():
        paper_image(out / "paper.png")
    manifest = {
        "protocol": 1,
        "cases": CASES,
        "runtime": cfg,
        "paper_sha256": digest((out / "paper.png").read_bytes()),
        "provider": MODEL,
        "author_instructions": AUTHOR,
        "review_instructions": REVIEW,
        "tool_hints": HINTS,
        "schedule": "One fresh author, one evidence-aware review with at most one source or control edit, one selection after a successful edit. Final blind grading is separate.",
        "render": {
            "size": [1200, 1650],
            "seed": 60017,
            "font_size": 33,
            "font": "李国夫手写体.ttf",
            "manual_guides_y": [120, 1520],
            "line_pitch": 50,
        },
    }
    if (out / "manifest.json").exists() and read(out / "manifest.json") != manifest:
        raise ValueError("Frozen manifest differs; choose a new run directory.")
    write(out / "manifest.json", manifest)
    print("manifest_sha256", digest((out / "manifest.json").read_bytes()), flush=True)


def opinion(folder, prompt, images):
    receipt = folder / "receipt.json"
    if receipt.exists():
        existing = read(receipt)
        if existing["prompt_sha256"] != digest(prompt.encode()) or existing[
            "image_sha256"
        ] != [digest(p.read_bytes()) for p in images]:
            raise ValueError(
                "Cannot reuse a receipt for different evidence or instructions."
            )
    elif folder.exists():
        folder.rename(
            folder.with_name(folder.name + "-incomplete-" + secrets.token_hex(4))
        )
    if not receipt.exists():
        prompt_file = folder.parent / (folder.name + "-prompt.txt")
        prompt_file.write_text(prompt, encoding="utf-8")
        judge(prompt_file, images, MODEL, folder)
    return read(folder / "decision.json")


def author(out, name, case):
    folder = out / name
    folder.mkdir(parents=True, exist_ok=True)
    result = opinion(
        folder / "author", AUTHOR + "\n\n" + HINTS + "\n\n题面：" + case["brief"], []
    )
    source = result.get("markdown")
    if not isinstance(source, str) or not source.strip():
        raise ValueError(f"Invalid Markdown response for {name}")
    (folder / "first.md").write_text(source, encoding="utf-8")
    return source


def take_snapshot(server, folder, state, revision):
    key = {"draft_id": state["draft_id"], "revision": revision, "section": 1}
    output = folder / f"r{revision}"
    output.mkdir(exist_ok=True)
    last = server.call("read_section", **key, view="review", page="last")[
        "structuredContent"
    ]["page"]
    pages = []
    for page in range(1, last + 1):
        page_key = dict(**key, page=page)
        pic = output / f"page-{page}.png"
        save_image(server.call("preview_handwriting", **page_key, view="image"), pic)
        review = server.call("preview_handwriting", **page_key, view="review")[
            "structuredContent"
        ]
        write(output / f"review-{page}.json", review)
        glyphs, offset = [], 0
        while offset is not None:
            layout = server.call(
                "preview_handwriting",
                **page_key,
                view="layout",
                offset=offset,
                limit=32,
            )["structuredContent"]
            glyphs.extend(layout["glyphs"])
            offset = layout.get("next_offset")
        write(output / f"glyphs-{page}.json", glyphs)
        pages.append(
            {
                "page": page,
                "glyphs": len(glyphs),
                "review_id": review["review_id"],
                "sha256": digest(pic.read_bytes()),
            }
        )
    with sqlite3.connect(
        (folder / "home" / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True
    ) as db:
        source, prepared = db.execute(
            "SELECT source,prepared FROM sections WHERE draft=? AND number=1 AND revision<=? ORDER BY revision DESC LIMIT 1",
            (state["draft_id"], revision),
        ).fetchone()
    (output / "source.md").write_text(source, encoding="utf-8")
    (output / "prepared.txt").write_text(prepared, encoding="utf-8")
    write(output / "pages.json", pages)
    return pages


def render_first(out, name, case):
    folder = out / name
    cfg = read(out / "manifest.json")["runtime"]
    with Server(cfg, folder / "home", "content_first", log_dir=folder) as server:
        if not (folder / "state.json").exists():
            first = server.call(
                "save_section",
                markdown=(folder / "first.md").read_text(encoding="utf-8"),
                paper_path=str(out / "paper.png"),
                paper_guides=[
                    {"row": 0, "left": [78, 120], "right": [1122, 120]},
                    {"row": 28, "left": [78, 1520], "right": [1122, 1520]},
                ],
                style={"font": "李国夫手写体.ttf", "seed": 60017, "font_size": 33},
            )["structuredContent"]
            state = {"draft_id": first["draft_id"], "first_revision": first["revision"]}
            write(folder / "state.json", state)
        state = read(folder / "state.json")
        revision = state["first_revision"]
        if not (folder / f"r{revision}" / "pages.json").exists():
            take_snapshot(server, folder, state, revision)
        if "task_id" not in state:
            task = server.call(
                "start_rsi_task",
                draft_id=state["draft_id"],
                revision=revision,
                objective=case["brief"],
                policy_id="pilot-v1",
                decision_provider=MODEL,
            )["structuredContent"]
            state["task_id"] = task["task_id"]
            write(folder / "state.json", state)
    print("rendered first", name, flush=True)


def review_prompt(case, source, terminal, review_instructions):
    policy = (
        review_instructions
        if not terminal
        else "你是手写稿的宿主视觉复查模型。只根据题面及附件从 r1、r2 选择实际更好的版本，若皆未达到交付要求则用 stop。只输出单个 JSON，action=select 或 stop，revision=所选版本，reason 说明具体的页上证据。不要使用文件或工具。"
    )
    return (
        policy
        + "\n"
        + HINTS
        + "\n题面："
        + case["brief"]
        + "\n当前写稿 Markdown：\n"
        + source
    )


def pages(folder, revision):
    stage = folder / f"r{revision}"
    return [stage / f"page-{p['page']}.png" for p in read(stage / "pages.json")]


def episode(out, name, case):
    folder = out / name
    initial = read(folder / "state.json")
    if (folder / "outcome.json").exists():
        return
    state = initial.copy()
    protocol = read(out / "manifest.json")
    cfg = protocol["runtime"]
    with Server(cfg, folder / "home", "content_review", log_dir=folder) as server:
        history = server.call("read_rsi_task", task_id=state["task_id"])[
            "structuredContent"
        ]

        def advance(revision, action, reason, **extra):
            nonlocal history
            refs = read(folder / f"r{revision}" / "pages.json")
            history = server.call(
                "advance_rsi_task",
                task_id=state["task_id"],
                expected_step=history["step"],
                revision=revision,
                action=action,
                reason=reason,
                review_ids=[p["review_id"] for p in refs],
                **extra,
            )["structuredContent"]
            return history

        rev = state["first_revision"]
        actor = opinion(
            folder / "review",
            review_prompt(
                case,
                (folder / f"r{rev}" / "source.md").read_text(encoding="utf-8"),
                False,
                protocol["review_instructions"],
            ),
            pages(folder, rev),
        )
        op = actor["action"]
        if op in {"replace", "tune"}:
            tool = "save_section" if op == "replace" else "tune_handwriting"
            if not history["decisions"]:
                advance(
                    rev,
                    "revise",
                    actor["reason"],
                    tool=tool,
                    instruction=actor["reason"],
                )
            change = history["decisions"][0]
            next_rev = change["result_revision"]
            if next_rev is None and history["status"] == "active":
                args = {
                    "draft_id": state["draft_id"],
                    "expected_revision": rev,
                    "rsi_decision_id": change["decision_id"],
                }
                if op == "replace":
                    args.update(section=1, markdown=actor["markdown"])
                else:
                    args["changes"] = actor["changes"]
                try:
                    next_rev = server.call(tool, **args)["structuredContent"][
                        "revision"
                    ]
                except RuntimeError as exc:
                    state["execution_error"] = str(exc)
            if next_rev is not None and next_rev != rev:
                if not (folder / f"r{next_rev}" / "pages.json").exists():
                    take_snapshot(server, folder, state, next_rev)
                prompt = review_prompt(
                    case,
                    (folder / f"r{next_rev}" / "source.md").read_text(encoding="utf-8"),
                    True,
                    protocol["review_instructions"],
                )
                nums = [rev, next_rev]
                prompt += "\n按以下顺序逐页附图：" + str(
                    [r for r in nums for _ in pages(folder, r)]
                )
                final = opinion(
                    folder / "select",
                    prompt,
                    [p for r in nums for p in pages(folder, r)],
                )
                if final["action"] not in {"select", "stop"}:
                    raise ValueError("Terminal verdict required")
                choice = int(final.get("revision") or next_rev)
                if choice not in nums:
                    raise ValueError("Unknown selected revision")
                if history["status"] == "active":
                    advance(choice, final["action"], final["reason"])
            elif history["status"] == "active":
                advance(
                    rev,
                    "stop",
                    "Author repair produced no candidate. "
                    + state.get("execution_error", "Tool reported no new revision."),
                )
        elif op in {"select", "stop"}:
            if history["status"] == "active":
                advance(rev, op, actor["reason"])
        else:
            raise ValueError("Unknown author review action")
        write(
            folder / "outcome.json",
            {"history": history, "execution_error": state.get("execution_error")},
        )
        print(
            "closed", name, history["status"], history["selected_revision"], flush=True
        )


def packets(out):
    import shutil

    directory = out / "packets"
    directory.mkdir(exist_ok=True)
    map_path = out / "packet-key.json"
    key = read(map_path) if map_path.exists() else {}
    manifest = {}
    cases = read(out / "manifest.json")["cases"]
    observed = {}
    for arm, base in [("v1", out), ("v2", out / "v2")]:
        for name, case in cases.items():
            folder = base / name
            if not (folder / "state.json").exists():
                continue
            for item in sorted(folder.glob("r*/pages.json")):
                stage = item.parent
                revision = int(stage.name[1:])
                hashes = tuple(p["sha256"] for p in read(item))
                address = (
                    f"{name}/{revision}" if arm == "v1" else f"{arm}/{name}/{revision}"
                )
                token = (
                    key.get(address)
                    or observed.get((name, hashes))
                    or secrets.token_hex(6)
                )
                key[address] = token
                observed[(name, hashes)] = token
                if token in manifest:
                    continue
                target = directory / token
                target.mkdir(exist_ok=True)
                page_files = []
                for p in pages(folder, revision):
                    dst = target / p.name
                    shutil.copyfile(p, dst)
                    page_files.append(
                        {
                            "path": dst.relative_to(directory).as_posix(),
                            "sha256": digest(dst.read_bytes()),
                        }
                    )
                manifest[token] = {
                    "brief": case["brief"],
                    "criteria": {k: v for k, v in case.items() if k != "brief"},
                    "pages": page_files,
                }
    write(map_path, key)
    write(directory / "manifest.json", {k: manifest[k] for k in sorted(manifest)})
    print(
        "packets",
        len(manifest),
        digest((directory / "manifest.json").read_bytes()),
        flush=True,
    )


TERMINAL_CONTRACT = """MCP 动作定义：select 表示验收该版本并交付；stop 表示仍有无法解决的问题，结束任务且不交付任何稿件。replace 或 tune 表示先产生另一个候选再复查；如果选择修改，具体写出当前稿上需要改动的证据。由你依据页面判断该采取哪一项。"""


def terminal_arm(out):
    import shutil

    folder = out / "v2"
    folder.mkdir(exist_ok=True)
    protocol = read(out / "manifest.json")
    protocol["protocol"] = 2
    protocol["review_instructions"] = REVIEW + "\n" + TERMINAL_CONTRACT
    protocol["first_page_hashes"] = {
        n: [p["sha256"] for p in read(out / n / "r1" / "pages.json")]
        for n in protocol["cases"]
    }
    frozen = folder / "manifest.json"
    if frozen.exists() and read(frozen) != protocol:
        raise ValueError("V2 protocol changed.")
    write(frozen, protocol)
    print("terminal_protocol_sha256", digest(frozen.read_bytes()), flush=True)
    for name, case in protocol["cases"].items():
        original = out / name
        target = folder / name
        target.mkdir(exist_ok=True)
        if (target / "state.json").exists():
            continue
        source = read(original / "state.json")
        shutil.copytree(original / "r1", target / "r1", dirs_exist_ok=True)
        home = target / "home"
        home.mkdir(exist_ok=True)
        with (
            sqlite3.connect(
                (original / "home" / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True
            ) as seed,
            sqlite3.connect(home / "drafts.sqlite3") as db,
        ):
            seed.backup(db)
        with Server(
            protocol["runtime"], home, "terminal_binding", log_dir=target
        ) as server:
            task = server.call(
                "start_rsi_task",
                draft_id=source["draft_id"],
                revision=1,
                objective=case["brief"],
                policy_id="pilot-v1",
                decision_provider=MODEL,
            )["structuredContent"]
        write(
            target / "state.json",
            {
                "draft_id": source["draft_id"],
                "first_revision": 1,
                "task_id": task["task_id"],
            },
        )
    return folder


def normalized(value):
    return (
        re.sub(r"\s+", "", unicodedata.normalize("NFKC", value))
        .replace("−", "-")
        .lower()
    )


def has_value(cell, target):
    value = normalized(cell)
    token = normalized(target)
    if target.isdigit():
        return (
            re.search(r"(?<![\d.])" + re.escape(token) + r"(?![\d.])", value)
            is not None
        )
    return token in value


def table_check(rows, expected):
    data = rows[1:]
    return {
        "observed": rows,
        "expected_data": expected,
        "header_present": bool(rows) and len(rows[0]) == 2 and all(rows[0]),
        "row_matches": [
            len(cells) == len(wanted)
            and all(has_value(cell, value) for cell, value in zip(cells, wanted))
            for cells, wanted in zip(data, expected)
        ],
        "data_row_count": len(data) == len(expected),
    }


def graph_checks(graph, expected):
    nodes = {
        tuple(m["position"]): m
        for m in graph["marks"]
        if m["kind"] in {"rectangle", "diamond", "circle"}
    }
    labels = {
        tuple(m["position"]): m["text"]
        for m in graph["marks"]
        if m["kind"] not in {"rectangle", "diamond", "circle"}
    }
    edges = []
    for seg in graph["segments"]:
        a, b = tuple(seg["from"]), tuple(seg["to"])
        middle = tuple((x + y) / 2 for x, y in zip(a, b))
        if a in nodes and b in nodes and seg["arrow"]:
            edges.append([nodes[a]["text"], nodes[b]["text"], labels.get(middle, "")])
    observed = [m["text"] for m in nodes.values()]
    return {
        "observed_nodes": observed,
        "observed_directed_edges": edges,
        "expected_nodes_present": sorted(observed) == sorted(expected["nodes"]),
        "conditional_diamond": any(
            m["kind"] == "diamond" and m["text"] == expected["nodes"][1]
            for m in nodes.values()
        ),
        "expected_edges_match": sorted(edges) == sorted(expected["edges"]),
    }


def content_checks(name, prepared):
    compact = normalized(prepared)
    if name == "text":
        lines = [s for s in prepared.splitlines() if s.strip()]
        groups = [
            ("上午", "露珠", r"凝结|凝聚|液化"),
            ("午后", "云影", r"遮|阻挡"),
            ("傍晚", "晚霞", r"散射"),
        ]
        return {
            "three_observations_in_order": len(lines) == 3
            and all(
                time in line and event in line and re.search(concept, line)
                for (time, event, concept), line in zip(groups, lines)
            ),
            "one_or_two_sentences_per_observation": len(lines) == 3
            and all(1 <= len(re.findall(r"[。！？]", line)) <= 2 for line in lines),
        }
    if name == "formula":
        return {
            "resistance_2_ohms": "=2ω" in compact,
            "current_6_amperes": "=6a" in compact,
            "power_72_watts": "=72w" in compact,
            "three_calculation_lines": sum(
                "=" in line for line in prepared.splitlines()
            )
            >= 3,
        }
    if name == "table1":
        return {
            "speed_3_m_per_s": "=3m/s" in compact,
            "distance_over_time": "δx" in compact and "δt" in compact,
        }
    if name == "table2":
        lines = prepared.splitlines()
        calculation_lines = [
            normalized((lines[i - 1] if i else "") + " " + line)
            for i, line in enumerate(lines)
            if "=" in line
        ]
        return {
            "separate_efficiencies": all(
                any(
                    label in line and line.endswith(answer)
                    for line in calculation_lines
                )
                for label, answer in [("甲", "80%"), ("乙", "75%")]
            ),
            "input_output_efficiency": "输出能量" in compact
            and "输入能量" in compact
            and "/" in compact,
            "efficiencies_and_difference": "80%" in compact
            and "75%" in compact
            and "5个百分点" in compact,
        }
    if name == "flow1":
        return {
            "threshold_30_celsius": "30°c" in compact
            and ("高于" in compact or "超过" in compact)
        }
    if name == "flow2":
        return {
            "library_and_exam_purpose_in_prose": any(
                "借书" in line and "交卷" in line for line in prepared.splitlines()
            )
        }
    return {
        "chemical_formula": "ph=-log10[h+]" in compact
        and "H⁺" in prepared
        and "log₁₀" in prepared,
        "both_classifications": re.search(r"甲[^。；;]*酸性", prepared) is not None
        and re.search(r"乙[^。；;]*非酸性", prepared) is not None,
    }


def inspect_render(root, stage, name, case, probe):
    import subprocess

    raw = (stage / "prepared.txt").read_bytes()
    native = json.loads(subprocess.check_output([str(probe)], input=raw))
    with Image.open(root / "paper.png") as f:
        paper = f.convert("L")
    raster = {}
    for page in read(stage / "pages.json"):
        n = page["page"]
        with Image.open(stage / f"page-{n}.png") as img:
            delta = ImageChops.subtract(paper, img.convert("L"))
        for g in read(stage / f"glyphs-{n}.json"):
            x, y, w, h = g["bounds"]
            box = (
                max(0, x),
                max(0, y),
                min(delta.width, x + w),
                min(delta.height, y + h),
            )
            ink = (
                sum(delta.crop(box).histogram()[32:])
                if box[0] < box[2] and box[1] < box[3]
                else 0
            )
            raster[g["id"]] = {
                "page": n,
                "bounds": g["bounds"],
                "ink_pixels": ink,
                "layout_kind": g.get("kind"),
                "text": g.get("text"),
            }
    checks = content_checks(name, raw.decode())
    by_kind = {k: [] for k in ("table", "graph", "fraction")}
    for c in native["components"]:
        g = raster.get(c["id"], {})
        c["raster"] = {k: v for k, v in g.items() if k != "text"}
        by_kind[c["kind"]].append(c)
    tables = by_kind["table"]
    wanted = case.get("tables", [])
    checks["table_count"] = len(tables) == len(wanted)
    cell_reports = [
        table_check(t["rows"], expected) for t, expected in zip(tables, wanted)
    ]
    header_vocab = {
        "table1": [("时间", "t/s"), ("位移", "x/m")],
        "table2": [("项目", "能量", "名目"), ("数值", "能量", "值")],
        "combined": [("样品", "样本"), ("ph",)],
    }
    if name in header_vocab:
        checks["table_header_meaning"] = all(
            len(t["rows"][0]) == 2
            and all(
                any(normalized(term) in normalized(cell) for term in choices)
                for cell, choices in zip(t["rows"][0], header_vocab[name])
            )
            for t in tables
        )
    checks["table_cells"] = all(
        t["header_present"] and all(t["row_matches"]) and t["data_row_count"]
        for t in cell_reports
    )
    graphs = by_kind["graph"]
    checks["graph_count"] = len(graphs) == len(case.get("graphs", []))
    graph_reports = [graph_checks(g, e) for g, e in zip(graphs, case.get("graphs", []))]
    checks["graph_semantics"] = all(
        g["expected_nodes_present"]
        and g["conditional_diamond"]
        and g["expected_edges_match"]
        for g in graph_reports
    )
    checks["graph_native_editable"] = all(
        g["raster"].get("layout_kind") == "native_diagram" for g in graphs
    )
    checks["min_stacked_fractions"] = len(by_kind["fraction"]) >= case.get(
        "fractions", 0
    )
    checks["components_visible_ink"] = all(
        c["raster"].get("ink_pixels", 0) > 0 for c in native["components"]
    )
    checks["expected_terms"] = all(has_value(raw.decode(), s) for s in case["tokens"])
    plain = [raster.get(c["id"], {"ink_pixels": 0}) for c in native["text_nodes"]]
    checks["visible_prose_glyphs"] = bool(plain) and all(
        g["ink_pixels"] > 0 for g in plain
    )
    return {
        "checks": checks,
        "mechanical_pass": all(checks.values()),
        "counts": {k: len(v) for k, v in by_kind.items()},
        "table_checks": cell_reports,
        "graph_checks": graph_reports,
        "components": native["components"],
        "layout_glyph_count": len(raster),
        "prose_glyphs_checked": len(plain),
        "nonblank_prose_glyphs": sum(g["ink_pixels"] > 0 for g in plain),
        "pages": read(stage / "pages.json"),
        "prepared_sha256": digest(raw),
    }


def deliver(out):
    """Export only native selections and independently render the resulting on-disk PDFs."""
    import shutil
    import subprocess

    protocol = read(out / "manifest.json")
    for arm, base in [("v1", out), ("v2", out / "v2")]:
        for name in protocol["cases"]:
            folder = base / name
            history = read(folder / "outcome.json")["history"]
            rev = history["selected_revision"]
            if rev is None:
                continue
            pdf = folder / "selected.pdf"
            receipt = folder / "delivery.json"
            if (
                receipt.exists()
                and pdf.is_file()
                and read(receipt)["sha256"] == digest(pdf.read_bytes())
            ):
                continue
            with Server(
                protocol["runtime"],
                folder / "home",
                "post_selection_export",
                log_dir=folder,
            ) as server:
                result = server.call(
                    "export_handwriting",
                    draft_id=history["draft_id"],
                    revision=rev,
                    format="pdf",
                )["structuredContent"]
            if result["draft_id"] != history["draft_id"] or result["revision"] != rev:
                raise ValueError("Export returned a different candidate.")
            shutil.copyfile(result["path"], pdf)
            info = subprocess.check_output(["pdfinfo", str(pdf)]).decode(
                errors="replace"
            )
            count = int(re.search(r"(?m)^Pages:\s+(\d+)", info).group(1))
            previews = pages(folder, rev)
            if len(previews) != count or count != result["pages"]:
                raise ValueError(
                    "Independent PDF page count does not match the selected candidate."
                )
            rasters = []
            for index, preview in enumerate(previews, 1):
                basename = folder / f"selected-page-{index}"
                with Image.open(preview) as original:
                    subprocess.run(
                        [
                            "pdftoppm",
                            "-f",
                            str(index),
                            "-l",
                            str(index),
                            "-singlefile",
                            "-png",
                            "-scale-to-x",
                            str(original.width),
                            "-scale-to-y",
                            str(original.height),
                            str(pdf),
                            str(basename),
                        ],
                        check=True,
                    )
                    actual = basename.with_suffix(".png")
                    with Image.open(actual) as page:
                        error = ImageStat.Stat(
                            ImageChops.difference(
                                page.convert("RGB"), original.convert("RGB")
                            )
                        ).mean
                        rasters.append(
                            {
                                "index": index,
                                "size": page.size,
                                "png_sha256": digest(actual.read_bytes()),
                                "preview_sha256": digest(preview.read_bytes()),
                                "mean_absolute_rgb_error": round(sum(error) / 3, 4),
                            }
                        )
            write(
                receipt,
                {
                    "arm": arm,
                    "revision": rev,
                    "source": "post_selection_export_handwriting",
                    "pdfinfo_pages": count,
                    "bytes": pdf.stat().st_size,
                    "sha256": digest(pdf.read_bytes()),
                    "poppler_rasters": rasters,
                },
            )


def publish_report(out, probe, target):
    protocol = read(out / "manifest.json")
    report = {
        "protocol_sha256": digest((out / "manifest.json").read_bytes()),
        "terminal_protocol_sha256": digest((out / "v2" / "manifest.json").read_bytes()),
        "model": MODEL,
        "binary_sha256": protocol["runtime"]["binary_sha256"],
        "worker_sha256": protocol["runtime"]["worker_sha256"],
        "font_sha256": protocol["runtime"]["font_sha256"],
        "paper_sha256": protocol["paper_sha256"],
        "measurement": "Native parser run on saved prepared sections, joined to MCP page layout by node ID and checked for at least 32 levels of grayscale darkening against the known public paper. Whole-object ink verifies location and paint, not individual character legibility. Content rules are literal witnesses; the blinded visual assessment is separate.",
        "arms": {
            "v1": protocol["review_instructions"],
            "v2": read(out / "v2" / "manifest.json")["review_instructions"],
        },
        "cases": {},
    }
    for name, case in protocol["cases"].items():
        base = out / name
        result = {
            "brief": case["brief"],
            "expected": {k: v for k, v in case.items() if k != "brief"},
            "author_receipt": read(base / "author" / "receipt.json"),
            "authored_markdown": (base / "first.md").read_text(encoding="utf-8"),
            "author_decision_sha256": digest(
                (base / "author" / "decision.json").read_bytes()
            ),
            "first": inspect_render(out, base / "r1", name, case, probe),
        }
        for arm, folder in [("v1", base), ("v2", out / "v2" / name)]:
            outcome = read(folder / "outcome.json")
            history = outcome["history"]
            decisions = []
            for stage in ("review", "select"):
                if (folder / stage / "receipt.json").exists():
                    decisions.append(
                        {
                            "actor": read(folder / stage / "decision.json"),
                            "receipt": read(folder / stage / "receipt.json"),
                        }
                    )
            changes = {}
            for rev in history["candidate_revisions"][1:]:
                stage = folder / f"r{rev}"
                changes[str(rev)] = {
                    "markdown": (stage / "source.md").read_text(encoding="utf-8"),
                    "render": inspect_render(out, stage, name, case, probe),
                }
            result[arm] = {
                "actor_decisions": decisions,
                "task_id": history["task_id"],
                "status": history["status"],
                "selected_revision": history["selected_revision"],
                "decision_steps": history["decisions"],
                "changes": changes,
                "exported_pdf": read(folder / "delivery.json")
                if (folder / "delivery.json").exists()
                else None,
            }
        report["cases"][name] = result
    cases = list(report["cases"].values())
    report["summary"] = {
        "cases": len(cases),
        "first_render_mechanical_pass": sum(
            c["first"]["mechanical_pass"] for c in cases
        ),
        "native_component_count": {
            kind: sum(c["first"]["counts"][kind] for c in cases)
            for kind in ("table", "graph", "fraction")
        },
        "rendered_text_nodes": sum(c["first"]["nonblank_prose_glyphs"] for c in cases),
        "arms": {
            arm: {
                "selected": sum(c[arm]["status"] == "selected" for c in cases),
                "stopped": sum(c[arm]["status"] == "stopped" for c in cases),
                "new_candidate_revisions": sum(len(c[arm]["changes"]) for c in cases),
            }
            for arm in ("v1", "v2")
        },
    }
    write(target, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser(
        "freeze",
        help="Write the immutable briefs, instructions, media and runtime identities.",
    )
    for key in ("binary", "worker", "fonts"):
        init.add_argument("--" + key, type=Path, required=True)
    for action in ("first", "review-v1", "review-v2"):
        run = sub.add_parser(action)
        run.add_argument("--case", choices=CASES, action="append")
        run.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    sub.add_parser(
        "packets", help="Export opaque PNG packets for separately blinded grading."
    )
    sub.add_parser(
        "deliver", help="Export selected PDFs and verify pages with Poppler."
    )
    summary = sub.add_parser(
        "results",
        help="Join the Rust parser output to saved MCP page glyphs and pixel evidence.",
    )
    summary.add_argument(
        "--probe",
        type=Path,
        required=True,
        help="Built handwriting-core rsi_content_probe example",
    )
    summary.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    args.out = args.out.resolve()
    if args.command == "freeze":
        return freeze(args)
    if args.command == "packets":
        return packets(args.out)
    if args.command == "deliver":
        return deliver(args.out)
    if args.command == "results":
        return publish_report(args.out, args.probe.resolve(strict=True), args.report)
    protocol = read(args.out / "manifest.json")
    if (
        protocol["cases"] != CASES
        or protocol["author_instructions"] != AUTHOR
        or protocol["tool_hints"] != HINTS
    ):
        raise ValueError("Use the script version that froze these briefs.")
    base = terminal_arm(args.out) if args.command == "review-v2" else args.out

    def work(name):
        case = protocol["cases"][name]
        if args.command == "first":
            author(base, name, case)
            return render_first(base, name, case)
        return episode(base, name, case)

    with ThreadPoolExecutor(args.jobs) as pool:
        list(pool.map(work, args.case or CASES))


if __name__ == "__main__":
    main()
