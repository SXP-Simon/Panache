# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.12,<2", "fonttools"]
# ///
"""Run against a built MCP binary and worker: preview_fresh.py BINARY WORKER [--baseline]."""
import argparse
import asyncio
import base64
import io
import os
import sqlite3
from pathlib import Path
from tempfile import TemporaryDirectory

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.shared.exceptions import McpError

from mcp_client import call


def font(alternate=False):
    """Two minimal valid TrueType faces with different A outlines."""
    names = [".notdef", "space", "letter"]
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(names)
    builder.setupCharacterMap({32: "space", ord("A"): "letter"})
    glyphs = {}
    for name in names:
        pen = TTGlyphPen(None)
        if name != "space":
            pen.moveTo((50, 20))
            pen.lineTo((700, 250) if alternate else (250, 700))
            pen.lineTo((700, 700))
            pen.closePath()
        glyphs[name] = pen.glyph()
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({name: (850, 0) for name in names})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({"familyName": "Synthetic", "styleName": "Regular"})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    data = io.BytesIO()
    builder.save(data)
    return data.getvalue()


async def preview(client, key, cached, **options):
    result = await call(client, "preview_handwriting", **key, **options)
    assert result.structuredContent == {**key, "page_in_section": 1, "cached": cached}
    return base64.b64decode(next(c.data for c in result.content if c.type == "image"))


async def reject(client, key, expected, **options):
    try:
        result = await client.call_tool("preview_handwriting", {**key, **options})
    except McpError as error:
        assert expected in str(error), error
        return
    assert result.isError and expected in result.content[0].text, result


def saved_rows(home):
    with sqlite3.connect((home / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True) as db:
        return tuple(db.iterdump())


async def regression(client, home, path, baseline):
    tools = await client.list_tools()
    props = next(tool.inputSchema for tool in tools.tools if tool.name == "preview_handwriting")
    if baseline:
        assert "fresh" not in props["properties"]
    else:
        assert "fresh" not in props["required"]
        assert props["properties"]["fresh"]["default"] is False
        assert props["properties"]["fresh"]["type"] == "boolean"

    saved = (await call(client, "save_section", markdown="AAAAAA",
                        style={"font": path.name, "seed": 31, "font_size": 33})).structuredContent
    draft_id = saved["draft_id"]
    for section in range(2, 6):
        await call(client, "save_section", markdown="AAAAAA", draft_id=draft_id,
                   section=section, expected_revision=section - 1)
    keys = [None, *[{"draft_id": draft_id, "revision": 5, "section": n} for n in range(1, 6)]]
    old = [None, *[await preview(client, key, False) for key in keys[1:5]]]
    unchanged_rows = saved_rows(home)

    changed = font(True)
    assert changed != path.read_bytes()
    path.write_bytes(changed)
    assert await preview(client, keys[1], True) == old[1]
    if baseline:
        await reject(client, keys[1], "fresh", fresh=True)
        await preview(client, keys[5], False)
        assert await preview(client, keys[1], False) != old[1]
        assert saved_rows(home) == unchanged_rows
        return

    assert await preview(client, keys[1], True, fresh=False) == old[1]
    for options in ({"view": "paper"}, {"view": "layout"}, {"view": "review"},
                    {"view": "review", "compare_revision": 1}):
        await reject(client, keys[1], "fresh=true requires view=image", fresh=True, **options)
    layout = await call(client, "preview_handwriting", **keys[1], view="layout", fresh=False, limit=1)
    assert layout.structuredContent["glyphs"]

    updated = await preview(client, keys[1], False, fresh=True)
    assert updated != old[1]
    assert await preview(client, keys[1], False, fresh=True, view="image") == updated
    assert await preview(client, keys[1], True, fresh=False) == updated
    for n in range(2, 5):
        assert await preview(client, keys[n], True) == old[n]

    # A cold fresh page uses ordinary FIFO. A refreshed hit must not promote its slot.
    inserted = await preview(client, keys[5], False, fresh=True)
    assert await preview(client, keys[5], True) == inserted
    for n in range(2, 5):
        assert await preview(client, keys[n], True) == old[n]
    assert await preview(client, keys[1], False) == updated

    # Failure removes only the explicitly refreshed entry; other warm pages remain untouched.
    path.unlink()
    assert await preview(client, keys[1], True, fresh=False) == updated
    await reject(client, keys[1], "invalid_font", fresh=True)
    await reject(client, keys[1], "invalid_font")
    assert await preview(client, keys[3], True) == old[3]
    path.write_bytes(changed)
    assert await preview(client, keys[1], False) == updated
    assert await preview(client, keys[1], True) == updated
    assert saved_rows(home) == unchanged_rows


async def main(binary, worker, baseline):
    with TemporaryDirectory(prefix="panache-preview-fresh-") as temp:
        root = Path(temp)
        fonts = root / "fonts"
        fonts.mkdir()
        path = fonts / "test.ttf"
        path.write_bytes(font())
        home = root / "drafts"
        params = StdioServerParameters(
            command=str(binary.resolve()), cwd=temp,
            env={**os.environ, "PANACHE_MCP_HOME": str(home),
                 "PANACHE_USER_FONT_DIR": str(root / "user-fonts"), "PANACHE_FONT_DIR": str(fonts),
                 "PANACHE_MARKDOWN_WORKER": str(worker.resolve()), "PANACHE_MCP_PRESERVE_REVIEWS": "0"},
        )
        async with stdio_client(params) as streams, ClientSession(*streams) as client:
            await client.initialize()
            await regression(client, home, path, baseline)
    print("baseline control passed" if baseline else "preview fresh regression passed")


if __name__ == "__main__":
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("binary", type=Path)
    cli.add_argument("worker", type=Path)
    cli.add_argument("--baseline", action="store_true")
    asyncio.run(main(**vars(cli.parse_args())))
