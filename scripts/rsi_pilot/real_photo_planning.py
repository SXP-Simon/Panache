"""Ask fresh agents how they would start the homework, before showing any finished page."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from tempfile import TemporaryDirectory

from benchmark import Server, read, write
from codex_judge import run


class StartupCapture(Server):
    def rpc(self, method, params):
        result = super().rpc(method, params)
        if method == "initialize":
            self.instructions = result["instructions"]
        return result


def compare(manifest_path, binary, out):
    manifest = read(manifest_path)
    cfg = dict(manifest["runtime"], binary=str(binary.resolve(strict=True)))
    out.mkdir(parents=True, exist_ok=False)
    with (
        TemporaryDirectory() as tmp,
        StartupCapture(cfg, Path(tmp), "capture-initialize") as server,
    ):
        instructions = server.instructions

    question = (
        manifest["brief"]
        + "\n附件是用户交给你的原始素材，尚未生成成稿。请据此决定你作为执行 Agent 的第一步，"
        "以及你会怎样完成和验收这次任务。用 JSON 返回 first_action、observations、acceptance。"
        "本次只记录决策，请不要调用工具。"
    )
    conditions = {
        "brief_only": question,
        "standard_mcp": question
        + "\n工作环境中 MCP 初始化时返回的常规使用说明如下。\n"
        + instructions,
    }

    def decide(condition):
        prompt = out / (condition + ".txt")
        prompt.write_text(conditions[condition], encoding="utf-8")
        destination = out / condition
        run(prompt, [Path(cfg["photo"])], "gpt-6.1-terra", destination)
        return {
            "condition": condition,
            "prompt": conditions[condition],
            "decision": read(destination / "decision.json"),
            "receipt": read(destination / "receipt.json"),
        }

    with ThreadPoolExecutor(max_workers=len(conditions)) as executor:
        votes = list(executor.map(decide, conditions))
    write(
        out / "report.json",
        {
            "scope": "Planning only, two independent fresh contexts, one run per condition; the original supplied photograph is the sole image. The second context received the actual server startup instructions. These actions were proposed, not executed.",
            "votes": votes,
        },
    )


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    for key in ("manifest", "binary", "out"):
        cli.add_argument("--" + key, type=Path, required=True)
    args = cli.parse_args()
    compare(args.manifest, args.binary, args.out)
