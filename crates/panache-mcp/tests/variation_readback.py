# /// script
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Compare optional variation receipts with independent reads at the saved revisions."""

import argparse
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import call, isolated_session, open_db


async def run(binary, home):
    async with isolated_session(binary, home) as (client, _):
        saved = await call(client, "save_section", markdown="观察记录", style={"seed": 31})
        key = {"draft_id": saved.structuredContent["draft_id"]}

        async def values(revision):
            response = await call(
                client, "describe_controls", **key, revision=revision, group="variation"
            )
            return response.structuredContent["values"]

        tilt, shift = "perturb_theta_sigma", "perturb_x_sigma"
        before = await values(1)
        one = await call(
            client,
            "tune_handwriting",
            **key,
            expected_revision=1,
            changes={tilt: 0.09},
            readback_variation=[tilt],
        )
        after = await values(2)
        assert after[tilt] > before[tilt]
        assert one.structuredContent["effective_changes"] == {
            tilt: {"before": before[tilt], "after": after[tilt]}
        }

        two = await call(
            client,
            "tune_handwriting",
            **key,
            expected_revision=2,
            changes={tilt: None, shift: 1.5},
            readback_variation=[tilt, shift],
        )
        reset = await values(3)
        assert reset[tilt] == (await values(1))[tilt] and reset[shift] == 1.5
        assert two.structuredContent["effective_changes"] == {
            k: {"before": after[k], "after": reset[k]} for k in (tilt, shift)
        }

        proposed = {tilt: 0.11, shift: 2, "ink_depth_sigma": 9}
        with open_db(home) as db:
            unchanged = list(db.iterdump())
        for revision, keys, changes, error in (
            (2, [tilt], proposed, "Revision conflict"),
            (3, [shift], {tilt: 0.11}, "readback_variation"),
            (3, ["font_size"], {"font_size": 36}, "readback_variation"),
            (3, list(proposed), proposed, "readback_variation"),
        ):
            rejected = await client.call_tool(
                "tune_handwriting",
                {
                    **key,
                    "expected_revision": revision,
                    "changes": changes,
                    "readback_variation": keys,
                },
            )
            assert rejected.isError and error in rejected.content[0].text
            with open_db(home) as db:
                assert list(db.iterdump()) == unchanged

        noop = await call(
            client,
            "tune_handwriting",
            **key,
            expected_revision=3,
            changes={"variation": {shift: 1.5}},
            readback_variation=[shift],
        )
        assert (
            noop.structuredContent["changed"] is False and noop.structuredContent["revision"] == 3
        )
        assert noop.structuredContent["effective_changes"] == {}
        # Saving an explicit override at the inherited value does not change the effective value.
        equal = await call(
            client,
            "tune_handwriting",
            **key,
            expected_revision=3,
            changes={tilt: reset[tilt]},
            readback_variation=[tilt],
        )
        assert equal.structuredContent["effective_changes"] == {}
        default = await call(
            client,
            "tune_handwriting",
            **key,
            expected_revision=equal.structuredContent["revision"],
            changes={tilt: 0.12},
        )
        assert "effective_changes" not in default.structuredContent
        print(
            "Checked effective values, reset, grouped no-op, four rejections and default receipt."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    with TemporaryDirectory() as temp:
        asyncio.run(run(args.binary.resolve(), Path(temp)))
