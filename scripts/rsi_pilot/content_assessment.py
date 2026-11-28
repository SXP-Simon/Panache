"""Read anonymous rendered homework, without giving the assessor the authored source."""

import argparse
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from benchmark import read, write
from codex_judge import run

RUBRIC = """你是独立验收者，只依据用户题目与附图，不能打开工具或源文件。
先读成稿再判断是否完成题目。逐表抄下看到的表头、每行数据和单位；
逐图记下实际看清的节点、箭头起点/终点、是非标签。公式题核对算式、读数、单位和结果；
文字题检查每段是否真正解释现象。请把可见证据与推测分开，模糊时明确指出。
只返回 JSON，含 verdict（pass/rework/uncertain）、tables（数量）、flows（数量）、
observed（实际读到的行、连接、公式或文本要点）、reason（具体页和位置）。
"""


def assess(root, out, key, packet):
    target = out / key
    target.mkdir(parents=True, exist_ok=True)
    images = []
    for page in packet["pages"]:
        path = root / page["path"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != page["sha256"]:
            raise ValueError(f"Packet pixels changed for {key}.")
        images.append(path)
    prompt = target / "question.txt"
    prompt.write_text(RUBRIC + "\n用户题目：" + packet["brief"], encoding="utf-8")
    decision = target / "assessment"
    if not (decision / "receipt.json").exists():
        run(prompt, images, "gpt-6.1-terra", decision)
    vote = read(decision / "decision.json")
    if vote.get("verdict") not in {"pass", "rework", "uncertain"}:
        raise ValueError(f"Invalid assessment for {key}.")
    return key, {"vote": vote, "receipt": read(decision / "receipt.json")}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("packets", type=Path)
    cli.add_argument("out", type=Path)
    args = cli.parse_args()
    catalog = read(args.packets / "manifest.json")
    with ThreadPoolExecutor(max_workers=3) as pool:
        jobs = [
            pool.submit(assess, args.packets, args.out, key, entry)
            for key, entry in catalog.items()
        ]
        final = dict(job.result() for job in jobs)
    write(args.out / "ballots.json", final)
    print(json.dumps({key: item["vote"]["verdict"] for key, item in final.items()}))


if __name__ == "__main__":
    main()
