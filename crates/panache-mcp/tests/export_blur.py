"""Check the delivered PNGs against native preview pixels, including the paper itself."""

import base64
import io
from pathlib import Path
from zipfile import ZipFile

from PIL import Image, ImageChops, ImageDraw

from mcp_client import call


async def compare_preview(client, key, section, sigma, content, box):
    expected = Image.open(io.BytesIO(content)).convert("RGBA")
    left, top, right, bottom = box
    region = [[left, top], [right, top], [right, bottom], [left, bottom]]
    for args, reference in [({}, expected), ({"region": region}, expected.crop(box))]:
        result = await call(client, "preview_handwriting", **key, section=section, view="image",
                            export_blur_px=sigma, **args)
        data = next(p.data for p in result.content if p.type == "image")
        observed = Image.open(io.BytesIO(base64.b64decode(data))).convert("RGBA")
        assert observed.size == reference.size and observed.tobytes() == reference.tobytes()
        if args:
            assert result.structuredContent["crop_bounds"] == [left, top, right-left, bottom-top]


async def verify(client, home):
    paper = Image.new("RGB", (540, 420), "white")
    ImageDraw.Draw(paper).rectangle((9, 9, 24, 24), fill="black")
    path = home / "export-focus-paper.png"
    paper.save(path)
    saved = await call(client, "save_section", markdown="第一页", paper_path=str(path),
                       style={"seed": 31, "ink": "#ba243b"})
    draft = saved.structuredContent["draft_id"]
    await call(client, "save_section", draft_id=draft, expected_revision=1, markdown="第二页")
    key = {"draft_id": draft, "revision": 2}
    await call(client, "preview_handwriting", **key, section=1, view="review")

    async def export(**args):
        result = (await call(client, "export_handwriting", **key, format="zip", **args)).structuredContent
        with ZipFile(Path(result["path"])) as archive:
            return result, [archive.read(name) for name in archive.namelist()]

    raw, pages = await export()
    _, zero = await export(export_blur_px=0)
    assert zero == pages and len(pages) == 2
    for i, page in enumerate(pages):
        preview = await call(client, "preview_handwriting", **key, section=i+1)
        assert page == base64.b64decode(next(item.data for item in preview.content if item.type == "image"))
    soft, blurred = await export(export_blur_px=1.2)
    evidence = soft["review"]["zip_pixels"]
    assert evidence == {"status": "not_compared_after_export_blur", "export_blur_px": 1.2,
                        "before_blur": raw["review"]["zip_pixels"]}
    assert evidence["before_blur"]["pages_matching_latest_review"] == 1
    assert soft["review"]["unreviewed_pages"] == [{"section": 2, "page": 1}]
    for before, after in zip(pages, blurred, strict=True):
        a = Image.open(io.BytesIO(before)).convert("RGB")
        b = Image.open(io.BytesIO(after)).convert("RGB")
        assert a.size == b.size == paper.size
        assert a.getpixel((8, 16)) == (255, 255, 255) and 1 < b.getpixel((8, 16))[0] < 255
        # The printed mark at the top left and the handwriting elsewhere both soften.
        assert ImageChops.difference(a, b).crop((30, 0, 540, 420)).getbbox()
    assert (await export())[1] == pages
    for sigma, content in [(0, pages[0]), (1.2, blurred[0])]:
        # The crop starts on the printed boundary: only filtering the full page first reproduces it.
        await compare_preview(client, key, 1, sigma, content, (9, 13, 145, 120))
    for args, reason in [
        ({"format": "zip", "export_blur_px": -0.1}, "0 to 2"),
        ({"format": "zip", "export_blur_px": 2.1}, "0 to 2"),
        ({"export_blur_px": 1}, "format=zip"),
    ]:
        invalid = await client.call_tool("export_handwriting", {**key, **args})
        assert invalid.isError and reason in invalid.content[0].text
    for args in [{"view": "review", "export_blur_px": 0}, {"view": "layout", "export_blur_px": 1},
                 {"view": "image", "export_blur_px": 2.1}]:
        invalid = await client.call_tool("preview_handwriting", {**key, **args})
        assert invalid.isError and "export_blur_px" in invalid.content[0].text

    await call(client, "tune_handwriting", draft_id=draft, expected_revision=2,
               changes={"transparent_background": True, "ink_depth_sigma": 0})
    key["revision"] = 3
    _, transparent = await export(export_blur_px=2)
    for i, content in enumerate(transparent):
        image = Image.open(io.BytesIO(content)).convert("RGBA")
        assert image.getpixel((8, 16))[3] == 0
        edge = [p for p in image.getdata() if 1 <= p[3] <= 10]
        assert edge and all(r > g + 50 and r > b + 50 for r, g, b, _ in edge)
        bounds = image.getchannel("A").getbbox()
        await compare_preview(client, key, i+1, 2, content,
                              (bounds[0]+3, bounds[1]+3, bounds[2], bounds[3]))
