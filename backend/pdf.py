# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Export handwritten pages with bounded JPEG quality into a temporary PDF."""

import logging
import shutil
import tempfile
from collections.abc import Iterable
from pathlib import Path

import fitz
from PIL import Image

logger = logging.getLogger(__name__)
PDF_JPEG_QUALITY = 75


def generate_pdf(images: Iterable[Image.Image]) -> str | None:
    """Write page images and return the exported PDF path, or report export failure."""
    base = Path("temp")
    base.mkdir(exist_ok=True)
    temp_dir = Path(tempfile.mkdtemp(dir=base))
    document = fitz.open()
    try:
        for index, image in enumerate(images):
            width, height = image.size
            path = temp_dir / f"image{index}.jpg"
            image.save(path, format="JPEG", quality=PDF_JPEG_QUALITY)
            page = document.new_page(width=width, height=height)
            page.insert_image(fitz.Rect(0, 0, width, height), filename=str(path))
        # 2026-10-15：原子创建输出文件，避免 mktemp 的检查与使用竞态。
        with tempfile.NamedTemporaryFile(suffix=".pdf", dir=base, delete=False) as target:
            output = target.name
        document.save(output)
    except Exception:
        logger.exception("PDF export failed")
        return None
    else:
        return output
    finally:
        document.close()
        shutil.rmtree(temp_dir)
