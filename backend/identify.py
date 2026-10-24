# Copyright (c) 2026 Simon and Panache contributors.
"""Measure ruling band centres and return the exact deskewed writing background."""

import base64
import math
from dataclasses import dataclass

import cv2
import numpy as np
from numpy.typing import NDArray

PIXEL_WHITE = 255
MAX_DESKEW_ANGLE = 12.0
MIN_BANDS = 3
MIN_IMAGE_SIZE = 32
MIN_SPACING = 8
ANGLE_PIXEL_TOLERANCE = 1.5

type GrayImage = NDArray[np.uint8]


class ImageIdentificationError(ValueError):
    """The image does not provide measurable notebook ruling lines."""


@dataclass(frozen=True)
class PaperMeasurement:
    """Ruling geometry in the returned background's pixel coordinate system."""

    left: int
    right: int
    top: int
    bottom: int
    spacing: int
    first_baseline: int
    width: int
    height: int
    angle: float
    corrected: str | None

    def response(self) -> dict[str, int | float | str]:
        """Return JSON-safe measurements for both geometry and layout."""
        result: dict[str, int | float | str] = {
            "marginLeft": self.left,
            "marginRight": self.right,
            "marginTop": self.top,
            "marginBottom": self.bottom,
            "lineSpacing": self.spacing,
            "layoutTopMargin": self.first_baseline - self.spacing,
            "layoutBottomMargin": max(0, self.bottom - math.ceil(self.spacing * 0.25)),
            "firstBaseline": self.first_baseline,
            "imageWidth": self.width,
            "imageHeight": self.height,
            "deskewAngleDegrees": self.angle,
        }
        if self.corrected is not None:
            result["correctedBackground"] = self.corrected
        return result


def _no_rulings() -> ImageIdentificationError:
    return ImageIdentificationError(
        "Unable to measure regular ruling lines. Please set margins and spacing manually."
    )


def _binary(image: GrayImage) -> GrayImage:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    # 2026-10-24：局部闭运算消除纸张阴影，再用 Otsu 保留浅灰线，避免渐变变成大片黑区。
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (1, max(15, image.shape[0] // 25)))
    contrast = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, kernel)
    _, binary = cv2.threshold(contrast, 0, PIXEL_WHITE, cv2.THRESH_BINARY | cv2.THRESH_OTSU)
    return np.asarray(binary, dtype=np.uint8)


def _angle(binary: GrayImage) -> float:
    width = binary.shape[1]
    lines = cv2.HoughLinesP(
        binary,
        1,
        np.pi / 1800,
        max(20, width // 5),
        minLineLength=max(20, width // 3),
        maxLineGap=max(3, width // 100),
    )
    if lines is None:
        raise _no_rulings()
    angles: list[float] = []
    for row in np.asarray(lines, dtype=np.int32).reshape(-1, 4):
        dx, dy = int(row[2]) - int(row[0]), int(row[3]) - int(row[1])
        angle = math.degrees(math.atan2(dy, dx)) if dx else 90.0
        if abs(angle) <= MAX_DESKEW_ANGLE:
            angles.append(angle)
    if not angles:
        raise _no_rulings()
    angle = float(np.median(angles))
    return angle if abs(math.tan(math.radians(angle))) * width > ANGLE_PIXEL_TOLERANCE else 0.0


def _rotate(image: GrayImage, angle: float) -> GrayImage:
    height, width = image.shape[:2]
    radians = math.radians(angle)
    new_width = math.ceil(width * abs(math.cos(radians)) + height * abs(math.sin(radians)))
    new_height = math.ceil(height * abs(math.cos(radians)) + width * abs(math.sin(radians)))
    rotation = cv2.getRotationMatrix2D((width / 2, height / 2), angle, 1.0)
    rotation[0, 2] += (new_width - width) / 2
    rotation[1, 2] += (new_height - height) / 2
    # 2026-10-24：扩展实际画布而不是只旋转分析副本，保留四角并与返回坐标使用同一张图。
    rotated = cv2.warpAffine(
        image,
        rotation,
        (new_width, new_height),
        flags=cv2.INTER_CUBIC,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(255, 255, 255),
    )
    return np.asarray(rotated, dtype=np.uint8)


def _bands(binary: GrayImage) -> list[tuple[float, int, int]]:
    height, width = binary.shape
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, (max(12, width // 5), 1))
    horizontal = np.asarray(cv2.morphologyEx(binary, cv2.MORPH_OPEN, kernel), dtype=np.uint8)
    counts = np.count_nonzero(horizontal, axis=1)
    active = np.flatnonzero(counts >= width * 0.35)
    if not active.size:
        raise _no_rulings()
    groups = np.split(active, np.flatnonzero(np.diff(active) > 1) + 1)
    bands: list[tuple[float, int, int]] = []
    for group in groups:
        if len(group) > height * 0.06:
            continue
        centre = float(np.average(group, weights=counts[group]))
        columns = np.flatnonzero(np.count_nonzero(horizontal[group], axis=0) >= len(group) / 2)
        if columns.size:
            bands.append((centre, int(columns[0]), int(columns[-1])))
    if len(bands) < MIN_BANDS:
        raise _no_rulings()
    return bands


def _spacing(centres: NDArray[np.float64]) -> int:
    gaps = np.diff(centres)
    spacing = float(np.median(gaps))
    if spacing < MIN_SPACING:
        raise _no_rulings()
    tolerance = max(2.0, spacing * 0.06)
    # 2026-10-24：以整条线带中心计距；不规则表格不能伪装成等行距作业纸。
    if bool(np.any(np.abs(gaps - spacing) > tolerance)):
        raise _no_rulings()
    fitted = float((centres[-1] - centres[0]) / (len(centres) - 1))
    rounded = round(fitted)
    expected = centres[0] + np.arange(len(centres)) * rounded
    if bool(np.any(np.abs(expected - centres) > tolerance)):
        raise _no_rulings()
    return rounded


def identify_paper(filename: str) -> PaperMeasurement:
    """Measure line centres and optionally return a physically corrected PNG."""
    # 2026-10-24：OpenCV 在 Windows 上无法直接打开中文路径，先读取字节再解码。
    try:
        encoded = np.fromfile(filename, dtype=np.uint8)
    except OSError as error:
        raise _no_rulings() from error
    image = cv2.imdecode(encoded, cv2.IMREAD_COLOR) if encoded.size else None
    if image is None or min(image.shape[:2]) < MIN_IMAGE_SIZE:
        raise _no_rulings()
    pixels = np.asarray(image, dtype=np.uint8)
    angle = _angle(_binary(pixels))
    if angle:
        pixels = _rotate(pixels, angle)
    bands = _bands(_binary(pixels))
    centres = np.array([band[0] for band in bands], dtype=np.float64)
    spacing = _spacing(centres)
    top = round(float(centres[0]))
    first = top + max(0, math.ceil((spacing - top) / spacing)) * spacing
    if first > round(float(centres[-1])):
        raise _no_rulings()
    height, width = pixels.shape[:2]
    corrected = None
    if angle:
        success, encoded = cv2.imencode(".png", pixels)
        if not success:
            raise _no_rulings()
        corrected = base64.b64encode(encoded.tobytes()).decode("ascii")
    return PaperMeasurement(
        round(float(np.median([band[1] for band in bands]))),
        width - round(float(np.median([band[2] for band in bands]))),
        top,
        height - round(float(centres[-1])),
        spacing,
        first,
        width,
        height,
        round(angle, 4),
        corrected,
    )


def identify_distance(filename: str) -> tuple[int, int, int, int, int]:
    """Return legacy margins and centre-to-centre ruling distance in pixels."""
    measurement = identify_paper(filename)
    return (
        measurement.left,
        measurement.right,
        measurement.top,
        measurement.bottom,
        measurement.spacing,
    )
