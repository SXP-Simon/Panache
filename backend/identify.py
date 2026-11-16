# Copyright (c) 2026 Simon and Panache contributors.
"""Measure ruling band centres and return the exact deskewed writing background."""

import base64
import math
from dataclasses import dataclass
from typing import cast

import cv2
import numpy as np
from numpy.typing import NDArray

PIXEL_WHITE = 255
MAX_DESKEW_ANGLE = 12.0
MIN_BANDS = 3
MIN_TRACKED_BANDS = 6
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


def _tracked_rulings(
    binary: GrayImage,
) -> tuple[GrayImage, NDArray[np.float32], NDArray[np.float64], int]:
    """Measure and flatten ruling tracks through narrow vertical strips."""
    # 2026-11-16：在窄条内追踪同一组横线，校正照片的弯曲和透视。
    height, width = binary.shape
    columns = np.asarray([width * (0.15 + i * 0.175) for i in range(5)], dtype=np.float64)
    radius = max(8, width // 30)
    strips = [
        np.array([y for y, _, _ in _bands(binary[:, int(x) - radius : int(x) + radius])])
        for x in columns
    ]
    middle = strips[2]
    gaps = np.diff(middle)
    spacing = round(float(np.median(gaps)))
    if spacing < MIN_SPACING:
        raise _no_rulings()
    breaks = np.flatnonzero(np.abs(gaps - spacing) > spacing * 0.18) + 1
    sequence = max(np.split(middle, breaks), key=len)
    if len(sequence) < MIN_TRACKED_BANDS:
        raise _no_rulings()
    spacing = round(float((sequence[-1] - sequence[0]) / (len(sequence) - 1)))
    target = np.rint(sequence[0]) + np.arange(len(sequence)) * spacing
    if target[-1] >= height - 1:
        raise _no_rulings()
    tracks: list[NDArray[np.float64]] = []
    for strip in strips:
        after = np.minimum(np.searchsorted(strip, sequence), len(strip) - 1)
        before = np.maximum(after - 1, 0)
        matched = np.asarray(
            np.where(
                np.abs(sequence - strip[before]) < np.abs(strip[after] - sequence),
                strip[before],
                strip[after],
            ),
            dtype=np.float64,
        )
        if np.any(np.abs(matched - sequence) > spacing * 0.42):
            raise _no_rulings()
        if np.any(np.abs(np.diff(matched) - spacing) > spacing * 0.22):
            raise _no_rulings()
        tracks.append(matched)
    # 2026-11-16：外侧沿最近两个采样条外推，固定图像上下边缘。
    x = np.arange(width, dtype=np.float64)
    index = np.asarray(np.clip(np.searchsorted(columns, x) - 1, 0, len(columns) - 2), dtype=np.intp)
    weight = (x - columns[index]) / (columns[index + 1] - columns[index])
    track = np.asarray(tracks)
    source = track[index] + weight[:, None] * (track[index + 1] - track[index])
    if (
        np.any(source[:, 0] <= 0)
        or np.any(source[:, -1] >= height - 1)
        or np.any(np.diff(source, axis=1) <= 0)
    ):
        raise _no_rulings()
    anchors = np.column_stack((np.zeros(width), source, np.full(width, height - 1)))
    rows = np.arange(height, dtype=np.float64)
    destination = np.concatenate(([0.0], target, [float(height - 1)]))
    map_y = np.asarray(
        [cast("NDArray[np.float64]", np.interp(rows, destination, column)) for column in anchors],
        dtype=np.float32,
    ).T.copy()
    map_x = np.broadcast_to(np.arange(width, dtype=np.float32), map_y.shape).copy()
    rectified = cv2.remap(binary, map_x, map_y, cv2.INTER_NEAREST)
    return np.asarray(rectified, dtype=np.uint8), map_y, target, spacing


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
    binary = _binary(pixels)
    warped = False
    try:
        angle = _angle(binary)
        rotated = _rotate(pixels, angle) if angle else pixels
        bands = _bands(_binary(rotated) if angle else binary)
        centres = np.array([band[0] for band in bands], dtype=np.float64)
        spacing = _spacing(centres)
        pixels = rotated
    except ImageIdentificationError:
        rectified, map_y, target, spacing = _tracked_rulings(binary)
        # 2026-11-16：排除校正后仍能投影成长横线的页眉装饰。
        bands = [
            band
            for band in _bands(rectified)
            if np.min(np.abs(target - band[0])) <= max(2.0, spacing * 0.06)
        ]
        if len(bands) != len(target):
            raise _no_rulings() from None
        centres = np.array([band[0] for band in bands], dtype=np.float64)
        if _spacing(centres) != spacing:
            raise _no_rulings() from None
        map_x = np.broadcast_to(np.arange(pixels.shape[1], dtype=np.float32), map_y.shape).copy()
        pixels = cv2.remap(pixels, map_x, map_y, cv2.INTER_LINEAR)
        angle = 0.0
        warped = True
    top = round(float(centres[0]))
    first = top + max(0, math.ceil((spacing - top) / spacing)) * spacing
    if first > round(float(centres[-1])):
        raise _no_rulings()
    height, width = pixels.shape[:2]
    corrected = None
    if angle or warped:
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
