"""Build the bilingual project site. Run with --out pointing to an output directory."""
import argparse
import datetime
import json
import posixpath
import re
import shutil
from pathlib import Path

import markdown
from jinja2 import Environment, FileSystemLoader, StrictUndefined, select_autoescape
from markupsafe import Markup
from PIL import Image
from markdown.extensions.toc import slugify_unicode

SITE = Path(__file__).resolve().parent
ROOT = SITE.parent
REPO = "https://github.com/SXP-Simon/Panache"
PRESETS = ("iris", "celadon", "coral")
GUIDES = ("guide/getting-started", "guide/parameters", "guide/layout-markers",
          "guide/chinese-letter", "guide/preview-export", "guide/faq", "desktop",
          "self-hosting/docker", "self-hosting/fonts-and-limits", "development",
          "architecture", "flutter-release", "changelog")


def prepare_gallery(assets):
    names = {}
    for mode in ("light", "dark"):
        board, = (ROOT / "docs/assets/images").glob(f"panache-themes-{mode}-*.webp")
        with Image.open(board) as image:
            if image.size != (1332, 2772):
                raise ValueError(f"Unexpected theme board layout: {board}")
            for index, preset in enumerate(PRESETS):
                top = 99 + index * 924
                shot = image.crop((26, top, 1306, top + 800))
                name = f"{board.stem}-{preset}.webp"
                shot.save(assets / name, quality=91, method=4)
                names[f"{preset}-{mode}"] = name
    return names


def build(out):
    assets = out / "assets"
    shutil.copytree(SITE / "static", assets, dirs_exist_ok=True)
    shutil.copyfile(ROOT / "app/assets/fonts/PlayfairDisplay.ttf", assets / "PlayfairDisplay.ttf")
    shutil.copyfile(ROOT / "assets/licenses/PlayfairDisplay-OFL.txt", assets / "PlayfairDisplay-OFL.txt")
    gallery = prepare_gallery(assets)
    for name in ("panache-showcase.webp", "panache-custom-background.webp"):
        shutil.copyfile(ROOT / "docs/assets/images" / name, assets / name)
    templates = Environment(loader=FileSystemLoader(SITE / "templates"),
                            undefined=StrictUndefined, autoescape=select_autoescape())
    for lang in ("zh", "en"):
        folder = SITE / "content" / lang
        articles = {p.relative_to(folder).with_suffix("").as_posix(): p.read_text(encoding="utf8")
                    for p in folder.rglob("*.md")}
        titles = {key: value.splitlines()[0].removeprefix("# ") for key, value in articles.items()}
        if set(titles) != {*GUIDES, "journal", "journal/iris-and-ink", "journal/paper-studies"}:
            raise ValueError(f"Incomplete navigation in {lang}")
        search_index = [{"route": key, "title": titles[key],
                         "text": " ".join(value.splitlines()[1:])}
                        for key, value in articles.items()]
        (assets / f"search-{lang}.json").write_text(
            json.dumps(search_index, ensure_ascii=False), encoding="utf8")
        titles["search"] = "Search" if lang == "en" else "搜索"
        for key in ("", "search", *articles):
            parts = ([lang] if lang == "en" else []) + ([key] if key else [])
            route = "/".join(parts)
            def link(target):
                return posixpath.relpath(target or ".", route or ".") + "/"
            def local(target):
                return link(("/".join((lang, target)).rstrip("/") if lang == "en" else target))
            def asset(filename):
                return posixpath.relpath("assets/" + filename, route or ".")
            content = ""
            if key in articles:
                source = "\n".join(articles[key].splitlines()[1:])
                source = re.sub(r"\]\(site:([\w/-]+)\)", lambda m: "](" + local(m[1]) + ")", source)
                content = markdown.markdown(source, extensions=["fenced_code", "tables", "toc"],
                                            extension_configs={"toc": {"slugify": slugify_unicode}})
            target = out / route / "index.html"
            target.parent.mkdir(parents=True, exist_ok=True)
            html = templates.get_template("page.html").render(
                key=key, lang=lang, en=lang == "en", titles=titles, guides=GUIDES,
                content=Markup(content), gallery=gallery, asset=asset, local=local,
                other=link(key if lang == "en" else "en/" + key), repo=REPO,
                year=datetime.date.today().year,
            )
            target.write_text(html, encoding="utf8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    build(parser.parse_args().out)
