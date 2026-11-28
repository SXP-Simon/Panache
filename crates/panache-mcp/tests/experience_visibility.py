# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2"]
# ///
"""Exercise ordinary lesson discovery across two real server processes sharing one home."""

import argparse
import asyncio
from pathlib import Path
from tempfile import TemporaryDirectory

from mcp_client import call, isolated_session


async def result(client, tool, **arguments):
    return (await call(client, tool, **arguments)).structuredContent


async def delivered(client, title, markdown):
    saved = await result(
        client, "save_section", title=title, markdown=markdown, style={"homework": True}
    )
    draft = {"draft_id": saved["draft_id"], "revision": saved["revision"]}
    page = await result(
        client, "preview_handwriting", **draft, section=1, page=1, view="review"
    )
    export = await result(client, "export_handwriting", **draft, format="pdf")
    return {
        **draft,
        "export_id": export["export_id"],
        "reviews": [{"revision": draft["revision"], "review_id": page["review_id"]}],
    }


async def exercise(binary, home):
    async with (
        isolated_session(binary, home) as (author, _),
        isolated_session(binary, home) as (reader, _),
    ):
        source = await delivered(
            author,
            "Three equal groups",
            "Three equal groups share 12 seeds. Each group gets 4 seeds.",
        )
        witness = source["reviews"]
        form = {k: source[k] for k in ("draft_id", "revision", "export_id")}
        tags = ["division", "homework"]
        action = "Read back the divisor and unit from the final calculation."
        source_rule = {
            "tags": tags,
            "scope": "The problem asks for an average per group.",
            "action": action,
            "reason": "A correct result alone does not show which divisor was used.",
            "reviews": witness,
        }
        other_rule = {
            **source_rule,
            "tags": ["control-only"],
            "action": "This unverified control must stay hidden from normal lookup.",
        }
        await result(
            author,
            "record_homework_experience",
            **form,
            rules=[source_rule, other_rule],
        )

        async def search(terms):
            return await result(reader, "search_homework_experience", tags=terms)

        assert not (await search(tags))["rules"]
        assert not (await search(["control-only"]))["rules"]
        assert "control-only" not in (await search([])).get("available_tags", [])

        # Replaying the same reflection must let the caller recover the original rule identifier.
        retry = await result(
            author,
            "record_homework_experience",
            **form,
            rules=[source_rule, other_rule],
        )
        rule_id = retry["rules"][0]["rule_id"]

        async def validate(evidence, kind, passed):
            return await result(
                author,
                "validate_homework_experience",
                rule_id=rule_id,
                **evidence,
                kind=kind,
                passed=passed,
                reason="Independent native review of the indicated homework.",
            )

        positive = await delivered(
            author,
            "Average group size",
            "Eight plants in two rows. Check the divisor 2.",
        )
        boundary = await delivered(
            author,
            "Equivalent notation",
            "Six plants for three trays. Six divided by three is two.",
        )
        negative = await delivered(
            author,
            "Counterexample",
            "The instructions explicitly ask for a diagram only.",
        )
        for invalid in (
            source,
            {**positive, "reviews": source["reviews"]},
            {**positive, "export_id": boundary["export_id"]},
        ):
            attempt = await author.call_tool(
                "validate_homework_experience",
                {
                    "rule_id": rule_id,
                    **invalid,
                    "kind": "positive",
                    "passed": True,
                    "reason": "Invalid evidence.",
                },
            )
            assert attempt.isError
        await validate(positive, "positive", True)
        assert not (await search(tags))["rules"]
        reused = await author.call_tool(
            "validate_homework_experience",
            {
                "rule_id": rule_id,
                **positive,
                "kind": "boundary",
                "passed": True,
                "reason": "A second label on the same draft must not promote this rule.",
            },
        )
        assert reused.isError
        await validate(boundary, "boundary", True)
        match = (await search(tags))["rules"]
        assert [r["rule_id"] for r in match] == [rule_id]
        assert match[0]["action"] == action
        assert not (await search(["homework"]))["rules"]
        assert not (await search(["control-only"]))["rules"]

        # Resolve an evidence receipt through the regular historical observation tool.
        audit = await result(reader, "read_homework_experience", rule_id=rule_id)
        source_case = next(case for case in audit["cases"] if case["kind"] == "source")
        cite = source_case["reviews"][0]
        assert cite["review_id"] == witness[0]["review_id"]
        assert (cite["draft_id"], cite["revision"], cite["section"], cite["page"]) == (
            source["draft_id"],
            source["revision"],
            1,
            1,
        )
        historical = await result(
            reader, "read_section", **cite["read_section_arguments"]
        )
        assert historical["review_id"] == cite["review_id"]
        assert historical["pixel_sha256"] == cite["pixel_sha256"]
        await validate(negative, "positive", False)
        assert not (await search(tags))["rules"]
        assert "division" not in (await search([])).get("available_tags", [])

    async with isolated_session(binary, home) as (next_agent, _):
        hidden = await result(next_agent, "search_homework_experience", tags=tags)
        assert hidden["rules"] == []
        audit = await result(next_agent, "read_homework_experience", rule_id=rule_id)
        assert audit["status"] == "rejected"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    opts = parser.parse_args()
    with TemporaryDirectory() as directory:
        asyncio.run(exercise(opts.binary.resolve(strict=True), Path(directory)))
    print(
        "Two live servers and a fresh connection agreed on the rule, its evidence and its withdrawal."
    )
