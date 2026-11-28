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


async def delivered(client, title, markdown, before=None):
    saved = await result(
        client,
        "save_section",
        title=title,
        markdown=before if before is not None else markdown,
        style={"homework": True},
    )
    draft = {"draft_id": saved["draft_id"], "revision": saved["revision"]}
    earlier = None
    if before is not None:
        page = await result(
            client, "preview_handwriting", **draft, section=1, page=1, view="review"
        )
        earlier = {"revision": draft["revision"], "review_id": page["review_id"]}
        saved = await result(
            client,
            "save_section",
            draft_id=draft["draft_id"],
            section=1,
            expected_revision=draft["revision"],
            markdown=markdown,
        )
        draft["revision"] = saved["revision"]
    assert saved["experience_search"]["tool"] == "search_homework_experience"
    page = await result(
        client, "preview_handwriting", **draft, section=1, page=1, view="review"
    )
    export = await result(client, "export_handwriting", **draft, format="pdf")
    review = {"revision": draft["revision"], "review_id": page["review_id"]}
    assert export["experience_reflection"]["page_reviews"] == [
        {"section": 1, "page": 1, "reference": review, "earlier_reference": earlier}
    ]
    return {
        **draft,
        "export_id": export["export_id"],
        "reviews": [review],
    }, export.get("experience_validation"), earlier


async def exercise(binary, home):
    async with (
        isolated_session(binary, home) as (author, _),
        isolated_session(binary, home) as (reader, _),
    ):
        source, offer, _ = await delivered(
            author,
            "Three equal groups",
            "Three equal groups share 12 seeds. 12 / 3 = 4 seeds per group.",
        )
        assert offer is None
        witness = source["reviews"]
        form = {k: source[k] for k in ("draft_id", "revision", "export_id")}
        tags = ["formula", "homework"]
        action = "Read back the divisor and unit from the final calculation."
        source_rule = {
            "tags": tags,
            "scope": "The problem asks for an average per group. 求每组平均数。",
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

        positive, offer, earlier = await delivered(
            author,
            "Average group size",
            "Eight plants in two rows. 8 / 2 = 4 plants per row.",
            before="Eight plants in two rows. 8 / 4 = 2 plants per row.",
        )
        assert offer["read_candidate"]["arguments"]["rule_id"] == rule_id
        assert offer["optional"] and "positive" in offer["validation"]["possible_kinds"]
        assert offer.get("action") is None
        assert offer["validation"]["evidence"] == {
            **positive,
            "section": 1,
            "page": 1,
            "reviews": positive["reviews"] + [earlier],
        }
        candidate = await result(reader, "read_homework_experience", rule_id=rule_id)
        assert candidate["status"] == "pending"
        negative, unrelated, _ = await delivered(
            author,
            "Counterexample",
            "The instructions explicitly ask for a diagram only.",
        )
        assert unrelated is None
        for invalid in (
            source,
            {**positive, "reviews": source["reviews"]},
            {**positive, "export_id": negative["export_id"]},
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
        await validate(
            {**positive, "reviews": positive["reviews"] + [earlier]}, "positive", True
        )
        assert not (await search(tags))["rules"]
        boundary, offer, _ = await delivered(
            author,
            "Equivalent notation",
            "Six plants for three trays. 6 / 3 = 2 plants per tray.",
        )
        assert offer["read_candidate"]["arguments"]["rule_id"] == rule_id
        assert offer["validation"]["possible_kinds"] == ["boundary"]
        assert offer["validation"]["evidence"] == {**boundary, "section": 1, "page": 1}
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
        by_text = await result(
            reader, "search_homework_experience", query="check the divisor"
        )
        assert [r["rule_id"] for r in by_text["rules"]] == [rule_id]
        by_chinese = await result(
            reader, "search_homework_experience", query="求每组平均数，检查计算式"
        )
        assert [r["rule_id"] for r in by_chinese["rules"]] == [rule_id]
        pending = await result(
            reader, "search_homework_experience", query="unverified control"
        )
        assert not pending["rules"]
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
        assert not (
            await result(reader, "search_homework_experience", query="divisor")
        )["rules"]
        assert not (await search(tags))["rules"]
        assert "formula" not in (await search([])).get("available_tags", [])

    async with isolated_session(binary, home) as (next_agent, _):
        hidden = await result(next_agent, "search_homework_experience", tags=tags)
        assert hidden["rules"] == []
        assert not (
            await result(next_agent, "search_homework_experience", query=action)
        )["rules"]
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
