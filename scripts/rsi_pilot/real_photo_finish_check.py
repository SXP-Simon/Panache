"""Measure where a native ink finish acts on the specified photo, independently of visual preference."""

import argparse
from pathlib import Path

import numpy as np
from benchmark import Server, digest, read, save_image, write
from PIL import Image


def measure(manifest, binary, out):
    cfg = dict(read(manifest)["runtime"], binary=str(binary.resolve(strict=True)))
    out.mkdir(parents=True, exist_ok=False)
    text = "\n\n".join(f"第{i + 1}行　光照与焦点对照　R = 36 Ω。" for i in range(17))
    gradient = {
        "from": {"x": 0.5, "y": 0.12, "sigma_px": 0.9},
        "to": {"x": 0.5, "y": 0.55, "sigma_px": 0},
    }
    style = {"font": "李国夫手写体.ttf", "font_size": 35, "seed": 803, "ink": "#6a4754"}
    with Server(cfg, out / "home", "ink-finish", log_dir=out) as server:
        saved = server.call(
            "save_section", paper_path=cfg["photo"], markdown=text, style=style
        )["structuredContent"]
        draft = saved["draft_id"]

        def snap(label, revision, view="image"):
            response = server.call(
                "preview_handwriting", draft_id=draft, revision=revision, view=view
            )
            dest = out / f"{label}.png"
            save_image(response, dest)
            with Image.open(dest) as im:
                return np.array(im.convert("RGB"), dtype=np.int16)

        def tune(previous, changes):
            result = server.call(
                "tune_handwriting",
                draft_id=draft,
                expected_revision=previous,
                changes=changes,
            )
            return result["structuredContent"]["revision"]

        blank = snap("paper", saved["revision"], "paper")
        before = snap("before", saved["revision"])
        r2 = tune(saved["revision"], {"photo_ink_focus": gradient})
        focus = snap("focus", r2)
        r3 = tune(r2, {"photo_ink_focus": None, "photo_ink_light": 75})
        light = snap("light", r3)
        r4 = tune(r3, {"photo_ink_light": None})
        reset = snap("reset", r4)

    rows = np.arange(before.shape[0])[:, None] / before.shape[0]
    far, near = rows < 0.30, rows >= 0.55
    visible_ink = np.max(abs(before - blank), axis=2) > 8
    changed = np.any(focus != before, axis=2)
    result = {
        "photo_sha256": digest(Path(cfg["photo"]).read_bytes()),
        "binary_sha256": digest(binary.read_bytes()),
        "style": style,
        "focus_gradient": gradient,
        "alignment": saved.get("paper", {}).get("alignment"),
        "scope": "Technical action footprint on separately generated writing. Counts are photo pixels, not grades of realism. Far = y < 30%, near = y >= 55%. Ink visibility requires a maximum RGB difference >8 vs native blank; focus change is any RGB difference vs initial.",
        "visible_ink_far": int((visible_ink & far).sum()),
        "visible_ink_near": int((visible_ink & near).sum()),
        "changed_far": int((changed & far).sum()),
        "changed_near": int((changed & near).sum()),
        "changed_top_200_rows": int(changed[:200].sum()),
        "light_75_changed_gt1": int((np.max(abs(light - before), axis=2) > 1).sum()),
        "reset_rgb_exact": bool(np.array_equal(reset, before)),
    }
    write(out / "findings.json", result)


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    for arg in ("manifest", "binary", "out"):
        cli.add_argument("--" + arg, type=Path, required=True)
    args = cli.parse_args()
    measure(args.manifest, args.binary, args.out)
