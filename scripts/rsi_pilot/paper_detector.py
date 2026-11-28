"""Candidate calibration based exclusively on the supplied blank image pixels."""

import itertools

import numpy as np
from PIL import Image


def _profile(ridge, x, half_width):
    w = ridge.shape[1]
    return ridge[:, max(0, x - half_width) : min(w, x + half_width + 1)].mean(axis=1)


def _periodic_rows(profile):
    h = len(profile)
    radius = max(3, round(h * 0.006))
    peaks = []
    for y in range(radius, h - radius):
        window = profile[y - radius : y + radius + 1]
        if profile[y] < 4.5 or profile[y] < window.max():
            continue
        if peaks and y - peaks[-1] < radius:
            continue
        peaks.append(y)
    best = []
    for first, second in itertools.combinations(peaks, 2):
        pitch = second - first
        if not 0.015 * h <= pitch <= 0.095 * h:
            continue
        chain = [first, second]
        for _ in range(64):
            predicted = chain[-1] + pitch
            possible = [p for p in peaks if abs(p - predicted) <= max(3, 0.11 * pitch)]
            if not possible:
                break
            y = min(possible, key=lambda p: abs(p - predicted))
            pitch = y - chain[-1]
            chain.append(y)
        if len(chain) > len(best):
            best = chain
    if len(best) < 4:
        raise ValueError("No reliable regularly spaced horizontal marks")
    return best


def _trace(ridge, center, y, direction, pitch):
    h, w = ridge.shape
    step = max(4, round(0.009 * w))
    radius = max(2, min(round(0.09 * pitch), round(step * 0.25)))
    pts = [(center, y)]
    lost = 0
    slope = 0.0
    for x in range(
        center + direction * step, w if direction > 0 else 0, direction * step
    ):
        prev_x, prev_y = pts[-1]
        estimate = round(prev_y + slope * (x - prev_x))
        lo, hi = max(0, estimate - radius), min(h, estimate + radius + 1)
        if lo >= hi:
            break
        scores = ridge[lo:hi, max(0, x - 3) : min(w, x + 4)].mean(axis=1)
        j = scores.argmax()
        if scores[j] < 3.5:
            lost += 1
            if lost >= 2:
                break
            continue
        lost = 0
        y1 = int(lo + j)
        slope = 0.65 * slope + 0.35 * (y1 - prev_y) / (x - prev_x)
        pts.append((x, y1))
    return pts


def detect_guides(path):
    """Estimate native MCP paper_guides or raise on insufficient evidence.

    A vertical dark-ridge filter removes slowly changing shadows. Find a long
    sequence with smoothly changing local pitch, remove abnormally heavy end
    borders, then trace each horizontal rule independently towards both edges.
    """
    with Image.open(path) as photo:
        gray = np.asarray(photo.convert("L"), dtype=np.float32)
    h, w = gray.shape
    shift = max(4, round(h * 0.004))
    padded = np.pad(gray, ((shift, shift), (0, 0)), mode="edge")
    ridge = np.maximum(0, (padded[:h] + padded[2 * shift :]) / 2 - gray)
    center = w // 2
    profile = _profile(ridge, center, max(4, round(w * 0.006)))
    rows = _periodic_rows(profile)
    # Integrated contrast distinguishes a dark thick border even at distant
    # soft focus, where peak depth or half-height width alone is ambiguous.
    masses = [float(profile[y - shift : y + shift + 1].sum()) for y in rows]
    for i in [0, -1]:
        neighbors = slice(1, 5) if i == 0 else slice(-5, -1)
        if masses[i] > 1.55 * np.median(masses[neighbors]):
            del rows[i]
            del masses[i]
    if len(rows) < 3:
        raise ValueError("Too few writable rulings after border removal")
    if rows[0] < (rows[-1] - rows[0]) / (len(rows) - 1):
        rows = rows[1:]
    guides = []
    for i, y in enumerate(rows):
        pitch = rows[i + 1] - y if i + 1 < len(rows) else y - rows[i - 1]
        left = _trace(ridge, center, y, -1, pitch)
        right = _trace(ridge, center, y, 1, pitch)
        if right[-1][0] - left[-1][0] < w * 0.32:
            raise ValueError("A ruling could not be followed far enough")
        # Fit through the central 80% to reduce the influence of shadows or
        # page boundaries. Use actual traced spread as the writable width.
        xs, ys = np.asarray(left[::-1] + right[1:]).T
        inside = (xs >= np.quantile(xs, 0.1)) & (xs <= np.quantile(xs, 0.9))
        slope, intercept = np.polyfit(xs[inside], ys[inside], 1)
        ends = [int(xs.min()), int(xs.max())]
        guide = [
            [x, int(np.clip(round(slope * x + intercept), 0, h - 1))] for x in ends
        ]
        guides.append({"row": i, "left": guide[0], "right": guide[1]})
    if len(guides) > 32:
        indices = np.linspace(0, len(guides) - 1, 32).round().astype(int)
        return [guides[index] for index in indices]
    return guides
