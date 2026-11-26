"""Audit two export_file.py runs. Only files in the simulated client's inbox count as handed off."""
import argparse
import hashlib
import json
from pathlib import Path


def matches(inbox_file, reference):
    return inbox_file.is_file() and hashlib.sha256(inbox_file.read_bytes()).hexdigest() == reference


def compare(baseline, candidate):
    reports = [json.loads((directory / "report.json").read_text(encoding="utf-8"))
               for directory in (baseline, candidate)]
    assert [r["mode"] for r in reports] == ["baseline", "candidate"]
    old, new = [r["exports"] for r in reports]
    assert all(old[key]["sha256"] == new[key]["sha256"] for key in old)
    samples = {"print-v2": "pdf", "worksheet-v1": "zip", "ink-v2": "zip"}
    delivered = []
    for directory in (baseline, candidate):
        inbox = directory / "client-files"
        delivered.append(sum(matches(inbox / f"{name}.{ext}", old[name]["sha256"])
                             for name, ext in samples.items()))
    assert delivered == [0, 3]
    assert not matches(candidate / "client-files/print-v2.pdf", old["print-v1-control"]["sha256"])
    assert not matches(candidate / "client-files/worksheet-v1.zip", old["ink-v2"]["sha256"])
    assert new["oversize"]["status"] == "too_large" and not (candidate / "client-files/oversize.zip").exists()

    print(json.dumps({"matching_client_files": delivered, "required_files": len(samples),
                      "same_export_bytes": len(old)}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    args = parser.parse_args()
    compare(args.baseline, args.candidate)
