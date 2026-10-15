# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""Measure notebook margins and line spacing from detected ruling lines."""

import logging
import math
from collections.abc import Sequence
from itertools import pairwise

import cv2
import numpy as np
from numpy.typing import NDArray
from sklearn.cluster import DBSCAN

logger = logging.getLogger(__name__)
PIXEL_WHITE = 255
MIN_RULING_DISTANCE = 5

type Coordinates = tuple[int, int, int, int]
type GrayImage = NDArray[np.uint8]


def _coordinates(values: NDArray[np.int32]) -> list[Coordinates]:
    rows = values.reshape(-1, 4)
    return [
        (int(rows[index, 0]), int(rows[index, 1]), int(rows[index, 2]), int(rows[index, 3]))
        for index in range(rows.shape[0])
    ]


def get_avg_distance(distances: Sequence[float]) -> float:
    """Average the most populous non-noise DBSCAN spacing cluster."""
    points = np.array(distances, dtype=np.float64).reshape(-1, 1)
    clustering = DBSCAN(eps=5, min_samples=3).fit(points)
    labels, counts = np.unique(clustering.labels_, return_counts=True)
    counts[labels == -1] = 0
    most_common = labels[np.argmax(counts)]
    return float(np.mean(points[clustering.labels_ == most_common]))


def _binary(image: GrayImage) -> GrayImage:
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    _, binary = cv2.threshold(gray, 150, PIXEL_WHITE, cv2.THRESH_BINARY_INV)
    return np.asarray(binary, dtype=np.uint8)


def _ruling_lines(binary: GrayImage) -> list[Coordinates]:
    edges = cv2.Canny(binary, 50, 150, apertureSize=3)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, 100, minLineLength=100, maxLineGap=10)
    if lines is None:
        return []
    return sorted(_coordinates(np.asarray(lines, dtype=np.int32)), key=lambda line: line[1])


def _deskew(image: GrayImage) -> GrayImage:
    kernel = np.ones((5, 5), np.uint8)
    connected = cv2.erode(cv2.dilate(_binary(image), kernel, iterations=1), kernel, iterations=1)
    lines = _ruling_lines(np.asarray(connected, dtype=np.uint8))
    angles = [math.degrees(math.atan2(y2 - y1, x2 - x1)) for x1, y1, x2, y2 in lines]
    angle = float(np.mean(angles)) if angles else 0.0
    height, width = image.shape[:2]
    rotation = cv2.getRotationMatrix2D((width // 2, height // 2), angle, 1.0)
    rotated = cv2.warpAffine(
        image, rotation, (width, height), flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE
    )
    return np.asarray(rotated, dtype=np.uint8)


def _horizontal_margins(binary: GrayImage, lines: list[Coordinates]) -> tuple[float, float]:
    left: list[float] = []
    right: list[float] = []
    width = binary.shape[1]
    for x1, _y1, x2, _y2 in lines:
        if x1 != 0 and x2 != width:
            left.append(x1)
            right.append(width - x2)
    return get_avg_distance(left), get_avg_distance(right)


def _vertical_margins(binary: GrayImage) -> tuple[float, float]:
    top: list[float] = []
    bottom: list[float] = []
    height, width = binary.shape[:2]
    for index in range(width):
        ink = np.flatnonzero(binary[:, index] == PIXEL_WHITE)
        first = int(ink[0]) if ink.size else 0
        last = int(ink[-1]) if ink.size else height
        if first != 0 and last != height:
            top.append(first)
            bottom.append(height - last)
    return get_avg_distance(top), get_avg_distance(bottom)


def identify_distance(filename: str) -> tuple[int, int, int, int, int]:
    """Return left, right, top, bottom margins and ruling distance in pixels."""
    image = cv2.imread(filename)
    if image is None:
        message = "Unable to decode notebook image"
        raise ValueError(message)
    binary = _binary(_deskew(np.asarray(image, dtype=np.uint8)))
    lines = _ruling_lines(binary)
    left, right = _horizontal_margins(binary, lines)
    top, bottom = _vertical_margins(binary)
    distances = [
        float(current[1] - previous[1])
        for previous, current in pairwise(lines)
        if current[1] - previous[1] > MIN_RULING_DISTANCE
    ]
    spacing = get_avg_distance(distances)
    logger.debug("Notebook margins=%s, ruling distance=%s", (left, right, top, bottom), spacing)
    return round(left), round(right), round(top), round(bottom), round(spacing)


if __name__ == "__main__":
    identify_distance("notebook.jpg")
