# Copyright (c) 2026 Simon and Handwriting Web contributors.
"""2026-10-22：二维矩阵与分段函数的等粗细伸缩括号路径."""

type Point = tuple[int, int]
type Stroke = tuple[tuple[Point, ...], int]


def _brace(width: int, height: int) -> tuple[Point, ...]:
    # 2026-10-22：四段三次曲线共用端点，避免大括号中腰尖刺和拼接断裂。
    w, h = float(width), float(height)
    curves = (
        ((w, 0.0), (w * 0.45, 0.0), (w * 0.45, h * 0.12), (w * 0.45, h * 0.25)),
        ((w * 0.45, h * 0.25), (w * 0.45, h * 0.4), (w * 0.45, h * 0.5), (0.0, h * 0.5)),
        ((0.0, h * 0.5), (w * 0.45, h * 0.5), (w * 0.45, h * 0.6), (w * 0.45, h * 0.75)),
        ((w * 0.45, h * 0.75), (w * 0.45, h * 0.88), (w * 0.45, h), (w, h)),
    )
    points: list[Point] = []
    for curve in curves:
        for step in range(13):
            t = step / 12
            factors = ((1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t**2, t**3)
            points.append(
                (
                    round(
                        sum(point[0] * weight for point, weight in zip(curve, factors, strict=True))
                    ),
                    round(
                        sum(point[1] * weight for point, weight in zip(curve, factors, strict=True))
                    ),
                )
            )
    return tuple(points)


def matrix_delimiters(kind: str, width: int, height: int, size: int) -> tuple[int, list[Stroke]]:
    """2026-10-22：返回左侧预留宽度及局部路径；cases 只有左大括号."""
    if kind == "matrix":
        return 0, []
    bracket = max(6, round(size * 0.25))
    gap = max(3, round(size * 0.12))
    inset = bracket + gap
    thin = max(1, round(size * 0.025))
    if kind in ("Bmatrix", "cases"):
        left = [_brace(bracket, height)]
    elif kind == "pmatrix":
        left = [
            tuple(
                (round(bracket * (1 - 4 * t * (1 - t))), round(height * t))
                for t in (i / 32 for i in range(33))
            )
        ]
    elif kind == "bmatrix":
        left = [((bracket, 0), (0, 0), (0, height), (bracket, height))]
    elif kind == "Vmatrix":
        left = [((0, 0), (0, height)), ((bracket // 2, 0), (bracket // 2, height))]
    else:
        left = [((bracket // 2, 0), (bracket // 2, height))]
    strokes = [(path, thin) for path in left]
    if kind != "cases":
        edge = width + inset * 2
        strokes.extend((tuple((edge - x, y) for x, y in path), thin) for path in left)
    return inset, strokes
