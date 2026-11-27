import json, math, hashlib
from pathlib import Path
import numpy as np, cv2
from PIL import Image, ImageDraw

p = Path(__file__).parent
source = Image.open(p / "paper.jpg").convert("RGB")


def rgb(im):
    return np.array(im).astype(np.int16)


def rr(x):
    return round(float(x), 3)


def slope(xs, ys):
    return np.polyfit(xs, ys, 1)[0]


def angle(s):
    return rr(math.degrees(math.atan(s)))


def analyze(image, stem):
    target = Image.open(image).convert("RGB")
    mask = (rgb(source) - rgb(target)).mean(axis=2) > 32
    gray = cv2.cvtColor(np.array(source), cv2.COLOR_RGB2GRAY)
    dark = (cv2.GaussianBlur(gray, (0, 0), 6).astype(float) - gray > 16).astype("uint8")
    _, labels, stats, _ = cv2.connectedComponentsWithStats(dark)
    rules = []
    for i, (x, y, w, h, _) in enumerate(stats):
        if w < 1100 or not 795 <= y <= 1155:
            continue
        iy, ix = np.where(labels[y : y + h, x : x + w] == i)
        centers = {int(k + x): float(np.median(iy[ix == k] + y)) for k in np.unique(ix)}
        rules.append((int(x), int(x + w - 1), centers))

    def ref_horizontal(x0, x1, y):
        matched = sorted(rules, key=lambda r: abs(r[2][round((x0 + x1) / 2)] - y))[:2]
        return [
            angle(slope(range(x0, x1 + 1), [line[2][x] for x in range(x0, x1 + 1)]))
            for line in matched
        ]

    def ref_vertical(x, y):
        mid = min(rules, key=lambda r: abs(r[2][round(x)] - y))
        frac = (x - mid[0]) / (mid[1] - mid[0])
        xs = [round(a + frac * (b - a)) for a, b, _ in rules]
        ys = [r[2][xp] for r, xp in zip(rules, xs)]
        return angle(slope(ys, xs))

    def sample(x0, x1, y0, y1, axis):
        roi = mask[y0 : y1 + 1, x0 : x1 + 1]
        if axis == "v":
            roi = roi.T
        ys = []
        xs = []
        for i, cs in enumerate(roi.T):
            active = np.flatnonzero(cs)
            if len(active):
                xs.append(i + (x0 if axis == "h" else y0))
                ys.append(np.median(active) + (y0 if axis == "h" else x0))
        return xs, ys

    def edge(x0, x1, y0, y1, axis):
        coord, dep = sample(x0, x1, y0, y1, axis)
        return [rr(np.median(coord)), rr(np.median(dep)), angle(slope(coord, dep))]

    upper = [edge(214, 239, 941, 948, "h"), edge(799, 825, 909, 915, "h")]
    lower = [edge(397, 430, 1082, 1088, "h"), edge(598, 634, 1071, 1077, "h")]
    hs = {}
    for key, arr in [("upper B1-B4 top", upper), ("lower B6-B5 bottom", lower)]:
        (x0, y0, _), (x1, y1, _) = arr
        hs[key] = {
            "centres": [arr[0][:2], arr[1][:2]],
            "angle": angle((y1 - y0) / (x1 - x0)),
            "angles_of_two_nearest_printed_rules": ref_horizontal(
                round(x0), round(x1), (y0 + y1) / 2
            ),
        }
    vs = {}
    for k, box in [
        ("upper left B1 left", (201, 210, 951, 974)),
        ("upper right B4 right", (834, 842, 917, 941)),
        ("lower left B6 left", (389, 395, 1055, 1081)),
        ("lower right B5 right", (638, 645, 1044, 1068)),
    ]:
        y, x, theta = edge(*box, "v")
        vs[k] = {
            "angle_from_vertical_positive_right": theta,
            "printed_rule_endpoint_interpolation": ref_vertical(x, y),
            "middle": [x, y],
            "span_px": box[3] - box[2],
        }
    # The B character repeats six times in the same text row. Each fixed window
    # isolates its actual ink; no reported glyph baseline is used for measurement.
    letters = []
    for xlo, xhi, ylo, yhi in [
        (173, 205, 1114, 1144),
        (370, 400, 1102, 1131),
        (548, 576, 1093, 1122),
        (673, 698, 1087, 1115),
        (850, 878, 1077, 1105),
        (1027, 1053, 1069, 1096),
    ]:
        yy, xx = np.where(mask[ylo : yhi + 1, xlo : xhi + 1])
        # The six windows cover the handwritten B in each node label.
        ix = xx + xlo
        iy = yy + ylo
        letters.append([rr(np.median(ix)), rr(np.median(iy))])
    body = {
        "B_centres": letters,
        "angle": angle(slope(*zip(*letters))),
        "printed_rule_angles": ref_horizontal(190, 1042, 1110),
    }

    # The row-centre abscissa of a diamond is halfway between its two tips.
    # Sampling original-size ink gives subpixel statistics without consulting the saved map.
    def ink_centre(y, xlo, xhi):
        xs = np.flatnonzero(mask[y, xlo : xhi + 1]) + xlo
        return (xs[0] + xs[-1]) / 2

    ps = []
    for top, bottom, xlo, xhi in [(919, 986, 408, 439), (908, 974, 605, 630)]:
        ps.append(
            [
                rr((ink_centre(top, xlo, xhi) + ink_centre(bottom, xlo, xhi)) / 2),
                (top + bottom) / 2,
            ]
        )
    for y, xlo, xhi in [(1068, 389, 438), (1057, 589, 644)]:
        ps.append([rr(ink_centre(y, xlo, xhi)), y])
    obs = (ps[3][0] - ps[2][0]) / (ps[1][0] - ps[0][0])
    xx = round(np.mean([q[0] for q in ps]))
    depths = [r[2][xx] for r in rules]
    widths = [r[1] - r[0] for r in rules]
    y1 = np.mean([q[1] for q in ps[:2]])
    y2 = np.mean([q[1] for q in ps[2:]])
    exp = np.interp(y2, depths, widths) / np.interp(y1, depths, widths)
    metrics = {
        "input": Path(image).name,
        "rgb_sha256": hashlib.sha256(target.tobytes()).hexdigest(),
        "native_size": target.size,
        "horizontal": hs,
        "vertical": vs,
        "body": body,
        "spread": {
            "node_positions": ps,
            "diagram_ratio": rr(obs),
            "printed_rule_span_ratio_at_same_depths": rr(exp),
        },
    }
    (p / (stem + ".json")).write_text(
        json.dumps(metrics, ensure_ascii=False, indent=2), encoding="utf8"
    )
    crop = (158, 884, 1064, 1155)
    target.crop(crop).save(p / (stem + "-native-crop.png"))
    canvas = Image.new("RGB", (crop[2] - crop[0], (crop[3] - crop[1]) * 2))
    canvas.paste(source.crop(crop), (0, 0))
    canvas.paste(target.crop(crop), (0, crop[3] - crop[1]))
    canvas.save(p / (stem + "-paper-and-output-native.png"))
    print(json.dumps(metrics, ensure_ascii=False))


if __name__ == "__main__":
    import sys

    analyze(
        p / (sys.argv[1] if len(sys.argv) > 1 else "original-v15.png"),
        sys.argv[2] if len(sys.argv) > 2 else "baseline-geometry",
    )
