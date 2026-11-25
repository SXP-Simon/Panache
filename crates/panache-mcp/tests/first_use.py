# /// script
# dependencies = ["mcp>=1.12,<2", "Pillow"]
# ///
"""Fixed first-use journeys over real stdio. Requires Poppler's pdfimages on PATH."""
import argparse
import asyncio
import base64
import hashlib
import io
import json
import os
import random
import sqlite3
import subprocess
from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
from zipfile import ZipFile

from PIL import Image, ImageChops, ImageDraw, ImageFont, ImageStat
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from mcp_client import call

HERE = Path(__file__).resolve().parent
TEXT = "观察记录：水滴沿着叶尖落下。"
LIMIT = 512 * 1024


def tables(home):
    with closing(sqlite3.connect((home / "drafts.sqlite3").as_uri() + "?mode=ro", uri=True)) as db:
        names = db.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        return {
            name: db.execute(f'SELECT * FROM "{name}" ORDER BY rowid').fetchall()
            for (name,) in names
        }


def digest(data):
    return hashlib.sha256(data).hexdigest()


def png_image(data):
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "PNG"
        return image.convert("RGBA")


def embedded(reply):
    return [item.resource for item in reply.content if item.type == "resource"]


async def run(args, home):
    out = args.out
    out.mkdir(parents=True, exist_ok=False)
    host = out / "client-files"
    host.mkdir()
    params = StdioServerParameters(command=str(args.binary.resolve()), cwd=home, env={
        **os.environ, "PANACHE_MCP_HOME": str(home), "PANACHE_USER_FONT_DIR": str(home / "fonts"),
        "PANACHE_FONT_DIR": str(HERE.parents[2] / "assets/font_assets"),
        "PANACHE_MARKDOWN_WORKER": str(args.worker.resolve()), "PANACHE_MCP_PRESERVE_REVIEWS": "0",
    })
    report = {"mode": "baseline" if args.baseline else "candidate", "exports": {}, "calls": []}
    async with stdio_client(params) as streams, ClientSession(*streams) as client:
        info = await client.initialize()
        assert info.serverInfo.name == "panache-mcp"
        tools = {tool.name: tool for tool in (await client.list_tools()).tools}
        export = tools["export_handwriting"]
        assert ("include_file" in export.inputSchema["properties"]) == (not args.baseline)
        (out / "initialize.txt").write_text(info.instructions, encoding="utf-8")
        (out / "export-tool.json").write_text(export.model_dump_json(indent=2), encoding="utf-8")

        async def invoke(name, **kw):
            report["calls"].append({"tool": name, "args": kw})
            return await call(client, name, **kw)

        async def sample(label, draft_id, revision):
            before = tables(home)
            res = await invoke("preview_handwriting", draft_id=draft_id, revision=revision,
                               view="image", section=1, page=1)
            assert res.structuredContent["revision"] == revision
            png = base64.b64decode(next(x.data for x in res.content if x.type == "image"), validate=True)
            assert tables(home) == before
            (out / (label + ".png")).write_bytes(png)
            return png_image(png)

        async def generate(label, draft_id, revision, fmt, request_bytes=True, oversize=False):
            opt = {"include_file": True} if request_bytes and not args.baseline else {}
            before = tables(home)
            res = await invoke("export_handwriting", draft_id=draft_id, revision=revision, format=fmt, **opt)
            sc = res.structuredContent
            assert (sc["draft_id"], sc["revision"], sc["pages"]) == (draft_id, revision, 1)
            assert sc["review"]["unreviewed_pages"] == [{"section": 1, "page": 1}]
            after = tables(home)
            assert {t for t in before if before[t] != after[t]} == {"export_files"}
            assert len(after["export_files"]) == len(before["export_files"]) + 1
            blobs = embedded(res)
            status = sc.get("file_transfer", {}).get("status")
            if opt and not oversize:
                assert status == "included" and len(blobs) == 1
                assert blobs[0].mimeType == {"pdf":"application/pdf", "zip":"application/zip"}[fmt]
                # The simulated client can use only the reply for this copy.
                data = base64.b64decode(blobs[0].blob, validate=True)
                target = host / f"{label}.{fmt}"
                target.write_bytes(data)
                assert target.read_bytes() == data
            else:
                assert not blobs and status == ("too_large" if opt and oversize else None)
            # Separate auditor, with access to the server, checks the generated artifact.
            server_bytes = Path(sc["path"]).read_bytes()
            if blobs:
                assert data == server_bytes
            if oversize:
                assert len(server_bytes) > LIMIT
            report["exports"][label] = dict(revision=revision, draft_id=draft_id, pages=sc["pages"],
                                            size=len(server_bytes), sha256=digest(server_bytes),
                                            status=status, client_copy=bool(blobs))
            return server_bytes

        # External scripted events: ambiguous request -> printable sheet and text -> change -> approve v2.
        start = tables(home)
        assert not start["drafts"]
        await invoke("list_fonts", source="bundled", query="霞鹜文楷.ttf", limit=1)
        assert tables(home) == start
        style = {"seed": 31}
        saved = await invoke("save_section", markdown=TEXT, style=style)
        key = saved.structuredContent["draft_id"]
        first = await sample("print-v1", key, 1)
        await invoke("tune_handwriting", draft_id=key, expected_revision=1, changes={"font_size": 48})
        chosen = await sample("print-v2", key, 2)
        assert chosen.tobytes() != first.tobytes()
        # A later version exists: export the chosen sample, even if it is no longer latest.
        await invoke("tune_handwriting", draft_id=key, expected_revision=2, changes={"font_size": 24})
        pdf = await generate("print-v2", key, 2, "pdf")
        pdf_path = host / "print-v2.pdf" if not args.baseline else out / "server-print-v2.pdf"
        if args.baseline:
            pdf_path.write_bytes(pdf)
        subprocess.run(["pdfimages", "-png", str(pdf_path), str(home / "page")], check=True)
        with Image.open(home / "page-000.png") as image:
            assert image.size == chosen.size
            errors = [sum(ImageStat.Stat(ImageChops.difference(image.convert("RGB"), ref.convert("RGB"))).mean) / 3
                      for ref in (chosen, first)]
        assert errors[0] == 0 and errors[1] > 0
        report["pdf_mean_absolute_channel_error_v2_v1"] = errors
        old_pdf = await generate("print-v1-control", key, 1, "pdf", request_bytes=False)
        assert digest(old_pdf) != digest(pdf)

        # Retry the same request after the client places the photo on the server.
        photo = home / "worksheet.png"
        before = tables(home)
        request = {"markdown": TEXT, "style": style, "paper_path": str(photo)}
        assert not photo.exists()
        missing = await client.call_tool("save_section", request)
        assert missing.isError and "paper_path" in missing.content[0].text
        assert tables(home) == before
        report["calls"].append({"tool": "save_section", "args": request, "error": missing.content[0].text})
        report["missing_photo_rejected_without_change"] = True
        with Image.open(HERE / "fixtures/ruled.png") as ruled:
            sheet = ruled.convert("RGB")
        font = ImageFont.truetype(str(HERE.parents[2] / "assets/font_assets/霞鹜文楷.ttf"), 23)
        name_box = (200, 0, 397, 40)
        blank_header = sheet.crop(name_box)
        ImageDraw.Draw(sheet).text((205, 6), "姓名：林禾", font=font, fill=(43, 52, 68))
        assert ImageChops.difference(sheet.crop(name_box), blank_header).getbbox()
        sheet.save(photo)
        saved = await invoke("save_section", **request)
        assert saved.structuredContent["revision"] == 1
        key = saved.structuredContent["draft_id"]
        paper = await sample("worksheet-v1", key, 1)
        assert paper.size == sheet.size
        delta = ImageChops.difference(paper.convert("RGB"), sheet)
        total = paper.width * paper.height
        unchanged = sum(n for n, rgb in delta.getcolors(total) if rgb == (0, 0, 0))
        assert total * 0.95 < unchanged < total
        name_delta = ImageChops.difference(paper.crop(name_box), sheet.crop(name_box).convert("RGBA"))
        name_changed = sum(n for n, rgba in name_delta.getcolors(total) if any(rgba))
        assert name_changed == 0
        report["worksheet_pixels"] = {"total": total, "unchanged": unchanged, "name_box": name_box,
                                      "name_changed": name_changed, "tables_checked": len(before)}
        archive = await generate("worksheet-v1", key, 1, "zip")
        with ZipFile(io.BytesIO(archive)) as z:
            assert z.namelist() == ["0.png"] and png_image(z.read("0.png")).tobytes() == paper.tobytes()

        # Explicit ink-only request. No paper import, font menu or review required.
        key = (await invoke("save_section", markdown=TEXT, style=style)).structuredContent["draft_id"]
        await invoke("tune_handwriting", draft_id=key, expected_revision=1, changes={"transparent_background": True})
        ink = await sample("ink-v2", key, 2)
        assert ink.getchannel("A").getextrema() == (0, 255)
        archive = await generate("ink-v2", key, 2, "zip")
        with ZipFile(io.BytesIO(archive)) as z:
            assert z.namelist() == ["0.png"] and png_image(z.read("0.png")).tobytes() == ink.tobytes()

        if not args.baseline:
            # Incompressible synthetic paper exercises the real oversized export path.
            noise = random.Random(31).randbytes(640 * 640 * 3)
            oversize_photo = home / "oversize.png"
            Image.frombytes("RGB", (640, 640), noise).save(oversize_photo)
            key = (await invoke("save_section", markdown=TEXT, style=style, paper_path=str(oversize_photo))).structuredContent["draft_id"]
            await generate("oversize", key, 1, "zip", oversize=True)
        assert not tables(home)["review_observations"]
    (out / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(report["exports"], ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("worker", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="new output directory for samples and receipts")
    parser.add_argument("--baseline", action="store_true", help="exercise a build without include_file")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="panache-first-use-") as tmp:
        asyncio.run(run(args, Path(tmp)))
