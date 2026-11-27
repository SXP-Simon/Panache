"""Check the delivered PNGs against native preview pixels, including the paper itself."""

import base64
import io
from itertools import pairwise
from pathlib import Path
from zipfile import ZipFile

from mcp_client import call
from PIL import Image, ImageChops, ImageDraw


async def compare_preview(client, key, section, finish, content, box):
    expected = Image.open(io.BytesIO(content)).convert("RGBA")
    left, top, right, bottom = box
    region = [[left, top], [right, top], [right, bottom], [left, bottom]]
    for args, reference in [({}, expected), ({"region": region}, expected.crop(box))]:
        result = await call(client, "preview_handwriting", **key, section=section, view="image",
                            **finish, **args)
        for field, value in finish.items():
            assert result.structuredContent[field] == value
        data = next(p.data for p in result.content if p.type == "image")
        observed = Image.open(io.BytesIO(base64.b64decode(data))).convert("RGBA")
        assert observed.size == reference.size and observed.tobytes() == reference.tobytes()
        if args:
            assert result.structuredContent["crop_bounds"] == [left, top, right-left, bottom-top]


def gradient(low, high, start=(0.25, 0.25), end=(0.75, 0.75)):
    return {
        "export_blur_gradient": {
            "from": {"x": start[0], "y": start[1], "sigma_px": low},
            "to": {"x": end[0], "y": end[1], "sigma_px": high},
        }
    }


async def check_opaque_gradients(client, key, export, pages, raw, uniform):
    forward = gradient(0, 2)
    reverse = gradient(0, 2, start=(0.75, 0.75), end=(0.25, 0.25))
    _, strong = await export(export_blur_px=2)
    zero = gradient(0, 0)
    zero_receipt, unchanged = await export(**zero)
    assert unchanged == pages and zero_receipt["review"]["zip_pixels"] == raw["review"]["zip_pixels"]
    assert zero_receipt["export_blur_gradient"] == zero["export_blur_gradient"]
    await compare_preview(client, key, 1, zero, pages[0], (9, 13, 145, 120))
    fixed = gradient(1.2, 1.2, start=(0, 0), end=(1, 1))
    uniform_receipt, fixed_pages = await export(**fixed)
    assert fixed_pages == uniform
    assert uniform_receipt["review"]["zip_pixels"]["export_blur_gradient"] == fixed["export_blur_gradient"]

    # Marks along the two center axes isolate x and y variation. The corners lie past the endpoints.
    corners = [(5, 5, 29, 29), (505, 381, 531, 407)]
    for finish, direction in [(forward, 1), (reverse, -1)]:
        receipt, graded = await export(**finish)
        result = receipt["review"]["zip_pixels"]
        assert (
            receipt["export_blur_gradient"]
            == result["export_blur_gradient"]
            == finish["export_blur_gradient"]
        )
        assert (
            result["status"] == "not_compared_after_export_blur"
            and result["before_blur"] == raw["review"]["zip_pixels"]
        )
        for before, after, soft in zip(pages, graded, strong, strict=True):
            final = Image.open(io.BytesIO(after)).convert("RGB")
            references = [before, soft] if direction == 1 else [soft, before]
            for box, content in zip(corners, references, strict=True):
                expected = Image.open(io.BytesIO(content)).convert("RGB").crop(box)
                assert final.crop(box).tobytes() == expected.tobytes()
            for axis in [[(170, 210), (270, 210), (370, 210)], [(270, 120), (270, 210), (270, 300)]]:
                # Two pixels outside each identical black square, a wider Gaussian darkens the white paper more.
                drops = [255 - final.getpixel((x - 2, y + 8))[0] for x, y in axis]
                assert all(direction * (b - a) > 0 for a, b in pairwise(drops)), (finish, axis, drops)
        await compare_preview(client, key, 2, finish, graded[1], (270, 210, 401, 330))

    # Both forms are mutually exclusive even when the explicitly supplied scalar is zero.
    for invalid in [
        {**zero, "export_blur_px": 0},
        {**forward, "export_blur_px": 1},
        gradient(0, 2, end=(0.25, 0.25)),
        gradient(0, 2, start=(-0.01, 0.25)),
        gradient(0, 2.01),
        gradient(-0.1, 1),
    ]:
        for name, args in [
            ("export_handwriting", {"format": "zip"}),
            ("preview_handwriting", {"view": "image"}),
        ]:
            failure = await client.call_tool(name, {**key, **args, **invalid})
            assert failure.isError, (name, invalid)
    assert (await client.call_tool("export_handwriting", {**key, "format": "pdf", **forward})).isError
    await call(client, "export_handwriting", **key, format="pdf", **zero)
    assert (await client.call_tool("preview_handwriting", {**key, "view": "review", **forward})).isError
    assert (await export())[1] == pages


async def check_transparent_gradient(client, key, export, uniform):
    _, raw = await export()
    alpha = Image.open(io.BytesIO(raw[0])).convert("RGBA").getchannel("A")
    left, top, right, bottom = alpha.getbbox()
    # Put the outer glyphs on constant plateaus of a horizontal gradient through the text itself.
    x0 = left + (right - left) // 3
    x1 = left + 2 * (right - left) // 3
    finish = gradient(0, 2, (x0 / (alpha.width - 1), 0.5), (x1 / (alpha.width - 1), 0.5))
    _, graded = await export(**finish)
    after = Image.open(io.BytesIO(graded[0])).convert("RGBA")
    mask = after.getchannel("A")
    assert mask.getpixel((16, 16)) == 0  # The original paper mark stays out of the ink-only PNG.
    soft = Image.open(io.BytesIO(uniform[0])).convert("RGBA").getchannel("A")
    for box, expected, other in [
        ((0, 0, x0 - 7, alpha.height), alpha, soft),
        ((x1 + 7, 0, alpha.width, alpha.height), soft, alpha),
    ]:
        plateau = mask.crop(box)
        assert plateau.getbbox() and plateau.tobytes() == expected.crop(box).tobytes()
        assert plateau.tobytes() != other.crop(box).tobytes()
    # Feathered edge pixels retain the red pen color on transparency.
    halo = [px for px in after.getdata() if 1 <= px[3] <= 10]
    assert halo and all(r > g + 50 and r > b + 50 for r, g, b, _ in halo)
    await compare_preview(client, key, 1, finish, graded[0], (left + 3, top + 3, right, bottom))


async def verify(client, home):
    paper = Image.new("RGB", (540, 420), "white")
    draw = ImageDraw.Draw(paper)
    for x, y in [(9, 9), (170, 210), (270, 210), (370, 210), (270, 120), (270, 300), (510, 386)]:
        draw.rectangle((x, y, x + 15, y + 15), fill="black")
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
        assert ImageChops.difference(a, b).crop((30, 0, 540, 115)).getbbox()
    assert (await export())[1] == pages
    for sigma, content in [(0, pages[0]), (1.2, blurred[0])]:
        # The crop starts on the printed boundary: only filtering the full page first reproduces it.
        await compare_preview(client, key, 1, {"export_blur_px": sigma}, content, (9, 13, 145, 120))
    await check_opaque_gradients(client, key, export, pages, raw, blurred)
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
        await compare_preview(client, key, i+1, {"export_blur_px": 2}, content,
                              (bounds[0]+3, bounds[1]+3, bounds[2], bounds[3]))
    await check_transparent_gradient(client, key, export, transparent)
