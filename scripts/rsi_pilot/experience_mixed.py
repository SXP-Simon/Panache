"""Reproduce the ordinary two-calculation homework where the model proposed a rule."""

import argparse
from pathlib import Path

from benchmark import Server, read, write
from experience_sessions import run_case
from experience_validation import invoke

SOURCE = r"""小车测速记录

| 次数 | 路程 | 时间 |
| --- | --- | --- |
| 第一次 | 15 m | 5 s |
| 第二次 | 12 m | 6 s |

旧教材输入一：`\nicefrac{15}{5}`

速度一：
$$\nicefrac{15}{5}=3$$

旧教材输入二：`\nicefrac{12}{6}`

速度二：
$$\nicefrac{12}{6}=2$$
"""


def run(cfg, out, model):
    setup = out / "input"
    setup.mkdir(parents=True, exist_ok=False)
    with Server(cfg, Path(cfg["home"]), "worksheet_setup", log_dir=setup) as server:
        draft = invoke(
            server,
            "save_section",
            title="测速记录",
            style={"homework": True, "paper": "ruled"},
            markdown=SOURCE,
        )
    write(out / "source.json", {"draft": draft, "markdown": SOURCE})
    prompt = f"我们物理小组每周用这份旧教材模板做测速记录。这份 Panache 草稿 {draft['draft_id']} 明天要交。两行速度在纸上都没有显示成上下分数，还缺了速度单位。请看看原来的页面，把两个计算都改成老师能直接批的样子，保留数据表和两行供同学照抄的旧教材输入。请检查后给我一页 PDF。"
    run_case(cfg, "origin", out / "origin", prompt, model)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config", type=Path, required=True)
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--model", default="gpt-6.2-astra")
    args = p.parse_args()
    run(read(args.config), args.out.resolve(), args.model)
