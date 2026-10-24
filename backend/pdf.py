# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Export handwritten pages with bounded JPEG quality into a temporary PDF."""

import shutil
import tempfile
from collections.abc import Iterable
from pathlib import Path

import fitz
from PIL import Image

if __package__:
    from .generation_cancellation import GenerationCancelledError, check_cancelled, checked_items
    from .logging_setup import get_logger
else:
    from generation_cancellation import GenerationCancelledError, check_cancelled, checked_items
    from logging_setup import get_logger

logger = get_logger(__name__)
PDF_JPEG_QUALITY = 75


def generate_pdf(images: Iterable[Image.Image]) -> str | None:
    """Write page images and return the exported PDF path, or report export failure."""
    base = Path("temp")
    base.mkdir(exist_ok=True)
    temp_dir = Path(tempfile.mkdtemp(dir=base))
    document = fitz.open()
    output: str | None = None
    try:
        for index, image in enumerate(checked_items(images)):
            width, height = image.size
            path = temp_dir / f"image{index}.jpg"
            image.save(path, format="JPEG", quality=PDF_JPEG_QUALITY)
            check_cancelled()
            page = document.new_page(width=width, height=height)
            page.insert_image(fitz.Rect(0, 0, width, height), filename=str(path))
            check_cancelled()
        # 2026-10-15：原子创建输出文件，避免 mktemp 的检查与使用竞态。
        with tempfile.NamedTemporaryFile(suffix=".pdf", dir=base, delete=False) as target:
            output = target.name
        document.save(output)
        check_cancelled(force=True)
    except GenerationCancelledError:
        if output is not None:
            Path(output).unlink(missing_ok=True)
        raise
    except Exception:
        if output is not None:
            Path(output).unlink(missing_ok=True)
        logger.exception("PDF export failed")
        return None
    else:
        return output
    finally:
        document.close()
        shutil.rmtree(temp_dir)
