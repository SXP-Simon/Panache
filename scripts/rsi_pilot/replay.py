"""Replay saved benchmark actions on generated paper, then compare every PNG hash.

This checks tool behavior with fixed decisions, independent of a model account.
The full native task-policy registry and model behavior are tested separately.
"""

import argparse
from pathlib import Path
from types import SimpleNamespace

import benchmark


def replay(args):
    results = Path(__file__).resolve().parent / "results"
    actions = benchmark.read(results / "decisions.json")["episodes"]
    measured = benchmark.read(results / "measurements.json")["cases"]
    papers = [case for case in measured if case["paper"] in args.paper]
    out = args.out.resolve()
    if out.exists():
        raise ValueError("Choose a new output directory for an independent replay.")
    benchmark.setup(
        SimpleNamespace(
            out=out,
            binary=args.binary,
            fonts=args.fonts,
            worker=args.worker,
            photos=None,
            papers=args.paper,
        )
    )
    matches = []
    for case in papers:
        paper = case["paper"]
        for arm in ("A", "B", "C"):
            folder = out / paper / arm
            ctx = SimpleNamespace(out=out, paper=paper, arm=arm)
            benchmark.clone(ctx)
            state = benchmark.read(folder / "state.json")
            benchmark.snapshot(benchmark.read(out / "runtime.json"), folder, state)
            if arm != "A":
                entry = next(
                    e for e in actions if e["paper"] == paper and e["arm"] == arm
                )
                for row in entry["turns"]:
                    file = folder / f"replay-{row['step']}.json"
                    benchmark.write(file, row["raw"])
                    benchmark.advance(SimpleNamespace(**vars(ctx), decision=file))
            state = benchmark.read(folder / "state.json")
            expected = case["arms"][arm]
            generated = {
                rev: [p["sha256"] for p in pages]
                for rev, pages in state["snapshots"].items()
            }
            frozen = {
                str(v["revision"]): [p["sha256"] for p in v["pages"]]
                for v in expected["candidates"]
            }
            disposition_ok = arm == "A" or (
                state.get("disposition") == expected["status"]
                and state.get("selected_revision") == expected["selected_revision"]
            )
            matches.append(
                {
                    "paper": paper,
                    "arm": arm,
                    "same_pixels": generated == frozen,
                    "same_decision": disposition_ok,
                }
            )
    benchmark.write(out / "replay.json", matches)
    if not all(m["same_pixels"] and m["same_decision"] for m in matches):
        raise SystemExit(
            "Replay differs. See replay.json and the retained revision PNGs."
        )
    print(f"Matched candidate pixels and disposition for {len(matches)} arms.")


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    for name in ("out", "binary", "worker", "fonts"):
        cli.add_argument("--" + name, type=Path, required=True)
    cli.add_argument(
        "--paper",
        nargs="+",
        choices=["public-grid", "public-depth"],
        default=["public-grid", "public-depth"],
    )
    replay(cli.parse_args())
