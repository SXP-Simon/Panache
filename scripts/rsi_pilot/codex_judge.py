"""Run a fresh image decision using the signed-in Codex CLI and save its evidence.

Example: python codex_judge.py --prompt decision.txt --out run/turn-1 page.jpg crop.png
A policy, previous decisions and the task belong in the prompt. Only explicit
image attachments are shown. The host applies any action after validation.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory


def run(prompt_file, images, model, out):
    executable = shutil.which("codex")
    if executable is None:
        raise SystemExit("Codex CLI must be installed and signed in.")
    prompt = prompt_file.read_text(encoding="utf-8-sig")
    images = [path.resolve(strict=True) for path in images]
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    last = out / "decision.json"
    with TemporaryDirectory() as isolated:
        args = [
            executable,
            "exec",
            "--json",
            "--ephemeral",
            "--skip-git-repo-check",
            "-C",
            isolated,
            "-s",
            "read-only",
            "-m",
            model,
            "-c",
            'model_reasoning_effort="high"',
            "--output-last-message",
            str(last),
        ]
        for image in images:
            args.extend(["--image", str(image)])
        with (
            (out / "events.jsonl").open("wb") as events,
            (out / "stderr.log").open("wb") as errors,
        ):
            result = subprocess.run(
                [*args, "-"],
                input=prompt.encode("utf-8"),
                stdout=events,
                stderr=errors,
                check=False,
            )
    if result.returncode:
        raise SystemExit(
            f"Codex returned {result.returncode}; see {out / 'stderr.log'}"
        )
    events = [
        json.loads(row)
        for row in (out / "events.jsonl").read_text(encoding="utf-8-sig").splitlines()
        if row
    ]
    completed = [event for event in events if event["type"] == "turn.completed"]
    forbidden = [
        event
        for event in events
        if event.get("item", {}).get("type")
        in {
            "command_execution",
            "mcp_tool_call",
            "web_search",
            "file_change",
            "collab_tool_call",
        }
    ]
    if forbidden or len(completed) != 1:
        raise RuntimeError(
            "Use a fresh evidence-only decision; see recorded event stream."
        )
    decision = json.loads(last.read_text(encoding="utf-8-sig"))
    if not isinstance(decision, dict):
        raise TypeError("The host expects a JSON object.")
    evidence = {
        "provider": "Codex CLI",
        "decision_sha256": hashlib.sha256(last.read_bytes()).hexdigest(),
        "model": model,
        "reasoning_effort": "high",
        "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
        "image_sha256": [
            hashlib.sha256(path.read_bytes()).hexdigest() for path in images
        ],
        "usage": completed[0].get("usage", {}),
    }
    (out / "prompt.txt").write_text(prompt, encoding="utf-8")
    receipt_tmp = out / "receipt.json.tmp"
    receipt_tmp.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    receipt_tmp.replace(out / "receipt.json")
    print(json.dumps(decision, ensure_ascii=False))


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--prompt", type=Path, required=True)
    cli.add_argument("--out", type=Path, required=True)
    cli.add_argument(
        "--model", choices=["gpt-6.1-terra", "gpt-6-luna"], default="gpt-6.1-terra"
    )
    cli.add_argument("images", type=Path, nargs="+")
    options = cli.parse_args()
    run(options.prompt, options.images, options.model, options.out)
