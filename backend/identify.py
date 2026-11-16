# Copyright (c) 2026 Simon and Panache contributors.
"""Measure ruling band centres and return the exact deskewed writing background."""

import base64
import math
from dataclasses import dataclass
from itertools import pairwise
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
MIN_LOCAL_CONTRAST = 3
HEADER_CONTRAST = 24
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


def _local_ruling_mask(image: GrayImage) -> GrayImage:
    """Keep faint lines even when darker objects occupy part of the photo."""
    # 2026-11-16：与 Rust 一样用局部纵向亮度差提取浅线。
    gray = np.asarray(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), dtype=np.float32)
    radius = min(64, max(12, image.shape[0] // 30))
    mean = cv2.blur(gray, (1, radius * 2 + 1))
    return np.asarray((mean - gray > MIN_LOCAL_CONTRAST) * PIXEL_WHITE, dtype=np.uint8)


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


def _has_printed_header(image: GrayImage, top: int, spacing: int) -> bool:
    """Recognize groups of printed strokes before the first physical ruling."""
    # 2026-11-16：在校正后的背景检查页眉，排除紧贴首条横线的墨迹和通栏边框。
    radius = max(2, spacing // 6)
    # 2026-11-16：标题只有侵入首个书写格时才占用首线。
    start = max(radius, top - spacing)
    end = top - max(radius * 2, 3)
    if end <= start:
        return False
    width = image.shape[1]
    gray = cv2.cvtColor(image[:, width * 15 // 100 : width * 85 // 100], cv2.COLOR_BGR2GRAY)
    rows = np.asarray(gray[start:end], dtype=np.int16)
    surroundings = np.asarray(gray[start - radius : end - radius], dtype=np.int16) + np.asarray(
        gray[start + radius : end + radius], dtype=np.int16
    )
    ink = surroundings - 2 * rows > HEADER_CONTRAST
    counts = np.count_nonzero(ink, axis=1)
    text_rows = (counts >= rows.shape[1] * 0.025) & (counts <= rows.shape[1] * 0.70)
    return bool(
        np.count_nonzero(text_rows) >= max(3, spacing // 5)
        and np.count_nonzero(np.any(ink[text_rows], axis=0)) >= rows.shape[1] * 0.12
    )


def _first_writable_baseline(image: GrayImage, top: int, spacing: int) -> int:
    if top < spacing or _has_printed_header(image, top, spacing):
        return top + spacing
    return top


def _strip_centres(binary: GrayImage) -> NDArray[np.float64]:
    """Find local line candidates, merging nearby fragments of the same stroke."""
    counts = np.count_nonzero(binary, axis=1)
    active = np.flatnonzero(counts >= binary.shape[1] * 0.40)
    gap = max(2, binary.shape[0] // 220)
    groups = np.split(active, np.flatnonzero(np.diff(active) > gap) + 1)
    return np.asarray(
        [
            np.average(group, weights=counts[group])
            for group in groups
            if group.size and group[-1] - group[0] <= gap * 2
        ],
        dtype=np.float64,
    )


def _match_strip(
    strip: NDArray[np.float64], previous: NDArray[np.float64], tolerance: NDArray[np.float64]
) -> NDArray[np.float64]:
    """Match adjacent strips using the local distance between rulings."""
    if not strip.size:
        return np.full_like(previous, np.nan)
    after = np.minimum(np.searchsorted(strip, previous), len(strip) - 1)
    before = np.maximum(after - 1, 0)
    left, right = strip[before], strip[after]
    matched = np.where(np.abs(previous - left) < np.abs(right - previous), left, right)
    return np.asarray(
        np.where(np.abs(matched - previous) <= tolerance, matched, np.nan), dtype=np.float64
    )


def _track_strips(
    strips: list[NDArray[np.float64]],
    sequence: NDArray[np.float64],
    tolerance: NDArray[np.float64],
) -> NDArray[np.float64]:
    """Match neighboring strips and bridge isolated gaps with measured support."""
    mid = len(strips) // 2
    tracks = [sequence[:0]] * len(strips)
    tracks[mid] = sequence
    for walk in (range(mid - 1, -1, -1), range(mid + 1, len(strips))):
        previous = sequence
        for index in walk:
            matched = _match_strip(strips[index], previous, tolerance)
            tracks[index] = matched
            previous = np.asarray(
                np.where(np.isfinite(matched), matched, previous), dtype=np.float64
            )
    track = np.asarray(tracks, dtype=np.float64)
    # 2026-11-16：仅补齐两侧都有实测支撑的单个采样缺口，不外推缺失的线。
    left, middle_track, right = track[:-2], track[1:-1], track[2:]
    bridge = (
        ~np.isfinite(middle_track)
        & np.isfinite(left)
        & np.isfinite(right)
        & (np.abs(left - right) <= tolerance)
    )
    track[1:-1] = np.where(bridge, (left + right) / 2, middle_track)
    return track


def _tracked_rulings(
    binary: GrayImage,
) -> tuple[GrayImage, NDArray[np.float32], NDArray[np.float64], int]:
    """Measure and flatten ruling tracks through narrow vertical strips."""
    # 2026-11-16：在窄条内追踪同一组横线，校正照片的弯曲和透视。
    height, width = binary.shape
    columns = np.asarray([width * (0.22 + i * 0.07) for i in range(9)], dtype=np.float64)
    radius = max(4, width // 120)
    strips = [_strip_centres(binary[:, int(x) - radius : int(x) + radius]) for x in columns]
    mid = len(strips) // 2
    middle = strips[mid]
    if len(middle) < MIN_TRACKED_BANDS:
        raise _no_rulings()
    gaps = np.diff(middle)
    # 2026-11-16：透视会逐步改变间距，只比较相邻间隔并寻找最长连续序列。
    stop = np.flatnonzero((gaps[1:] < gaps[:-1] * 0.75) | (gaps[1:] > gaps[:-1] * 1.33)) + 1
    boundaries = [0, *stop.tolist(), len(gaps)]
    start, end = max(pairwise(boundaries), key=lambda pair: pair[1] - pair[0])
    sequence = middle[start : end + 1]
    local = np.diff(sequence)
    if len(sequence) < MIN_TRACKED_BANDS or np.any(local < MIN_SPACING):
        raise _no_rulings()
    tolerance = np.minimum(np.r_[local[0], local], np.r_[local, local[-1]]) * 0.42
    track = _track_strips(strips, sequence, tolerance)
    verified = np.flatnonzero(np.all(np.isfinite(track), axis=0))
    runs = np.split(verified, np.flatnonzero(np.diff(verified) != 1) + 1)
    run = max(runs, key=len)
    if len(run) < MIN_TRACKED_BANDS or len(run) < len(sequence) * 0.75:
        raise _no_rulings()
    track = track[:, run]
    sequence = sequence[run]
    spacing = round(float((sequence[-1] - sequence[0]) / (len(sequence) - 1)))
    target = np.rint(sequence[0]) + np.arange(len(sequence)) * spacing
    if target[-1] >= height - 1:
        raise _no_rulings()
    # 2026-11-16：外侧沿最近两个采样条外推，固定图像上下边缘。
    x = np.arange(width, dtype=np.float64)
    index = np.asarray(np.clip(np.searchsorted(columns, x) - 1, 0, len(columns) - 2), dtype=np.intp)
    weight = (x - columns[index]) / (columns[index + 1] - columns[index])
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


def _segmented_bands(
    binary: GrayImage, centres: NDArray[np.float64]
) -> list[tuple[float, int, int]]:
    """Measure repeated rows with short gaps, including dotted ruling."""
    # 2026-11-16：在已验证的每条轨迹附近统计横向支持，忽略远离正文的独立墨迹。
    height, width = binary.shape
    max_gap = max(3, width // 30)
    min_span = width * 0.40
    min_density = 0.30
    bands: list[tuple[float, int, int]] = []
    for centre in centres:
        row = round(float(centre))
        columns = np.flatnonzero(np.any(binary[max(0, row - 2) : min(height, row + 3)], axis=0))
        groups = np.split(columns, np.flatnonzero(np.diff(columns) > max_gap) + 1)
        support = max(groups, key=len)
        if not support.size:
            raise _no_rulings()
        span = int(support[-1] - support[0] + 1)
        if span < min_span or support.size < span * min_density:
            raise _no_rulings()
        trim = support.size // 40
        bands.append((float(centre), int(support[trim]), int(support[-1 - trim])))
    return bands


def _measure_tracks(
    rectified: GrayImage, target: NDArray[np.float64], spacing: int
) -> list[tuple[float, int, int]]:
    # 2026-11-16：保留实线的精确中心；对点线或虚线按同一轨迹的跨度和密度校验。
    try:
        bands = [
            band
            for band in _bands(rectified)
            if np.min(np.abs(target - band[0])) <= max(2.0, spacing * 0.06)
        ]
        if len(bands) == len(target):
            centres = np.array([band[0] for band in bands], dtype=np.float64)
            if _spacing(centres) == spacing:
                return bands
    except ImageIdentificationError:
        pass
    return _segmented_bands(rectified, target)


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
        rectified, map_y, target, spacing = _tracked_rulings(_local_ruling_mask(pixels))
        bands = _measure_tracks(rectified, target, spacing)
        centres = np.array([band[0] for band in bands], dtype=np.float64)
        map_x = np.broadcast_to(np.arange(pixels.shape[1], dtype=np.float32), map_y.shape).copy()
        pixels = np.asarray(cv2.remap(pixels, map_x, map_y, cv2.INTER_LINEAR), dtype=np.uint8)
        angle = 0.0
        warped = True
    top = round(float(centres[0]))
    first = _first_writable_baseline(pixels, top, spacing)
    if first > round(float(centres[-1])):
        raise _no_rulings()
    height, width = pixels.shape[:2]
    corrected = None
    if angle or warped:
        success, encoded = cv2.imencode(".png", pixels)
        if not success:
            raise _no_rulings()
        corrected = base64.b64encode(encoded.tobytes()).decode("ascii")
    # 2026-11-16：透视使下半页更宽，取多数横线共用的内侧书写区。
    left = round(float(np.quantile([band[1] for band in bands], 0.9 if warped else 0.5)))
    right = round(float(np.quantile([band[2] for band in bands], 0.1 if warped else 0.5)))
    if warped and right - left < width * 0.35:
        raise _no_rulings()
    return PaperMeasurement(
        left,
        width - right,
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
