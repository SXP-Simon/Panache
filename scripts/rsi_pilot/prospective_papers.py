"""Frozen prospective transfer fixtures. Geometry targets are evaluator-only.

Section text and the objective are the only task specifications shown to the
actor. Each fixture gets the same native Panache preparation and handwriting
style as the original pilot. Both pages share their task's independently drawn
stationery; two pages from one design are a single paper source.
"""

from PIL import Image, ImageDraw, ImageFont

NOTES = "public-notes-v3"
SLOTS = "public-slots-v3"
PAPERS = {NOTES, SLOTS}

SECTIONS = {
    NOTES: [
        """量热实验记录

热水质量为 80 g，初温为 65 °C。

冷水质量为 120 g，初温为 20 °C。

忽略容器的吸热，设平衡温度为 T。

热水放热量为 Q = mc(65 − T)。

冷水的吸热量为 Q = mc(T − 20)。

令两式相等，得到 T = 38 °C。

混合后搅拌，使温度在各处趋于一致。""",
        """浮力实验记录

物块在空气中的重量为 1.20 N。

物块浸没后，弹簧秤示数为 0.80 N。

两次读数之差给出浮力 0.40 N。

取重力加速度为 10 m/s²。

由排水质量 m = F/g，得 m = 0.040 kg。

排开水的体积为 40 cm³。

读数时应等到液面和弹簧秤稳定。""",
    ],
    SLOTS: [
        "实测电流 2.0 mA。\n\n\n平均电流 $I=\\frac{2+4}{2}=3$ mA。",
        "实测长度 12 mm。\n\n\n平均长度 $L=\\frac{12+14}{2}=13$ mm。",
    ],
}

OBJECTIVES = {
    NOTES: "把量热和浮力实验记录分别手写在两张原纸上，每份记录限一页。正文须沿纸上横线书写；段落和算式之间允许空一行。保留全部读数、单位、公式及结论。",
    SLOTS: "这两页分别是电流、长度登记单，每节各交一页。每页第一项实测值须写在第一条可写横线上，第二项平均值和计算式须写在第二条可写横线上。这两条横线之间不能空行。保留两个数值、单位及完整算式。",
}

TITLES = {NOTES: "量热与浮力实验记录", SLOTS: "电流与长度登记单"}


def required_rows_for(paper, section, page):
    """Map source-entry indices to zero-based physical rows when explicitly specified."""
    if paper == SLOTS and section in (1, 2) and page == 1:
        return {0: 0, 1: 1}
    return {}


def _geometry(paper):
    if paper == NOTES:
        width, height = 796, 1010
        xs = [120, 398, 665]
        endpoints = [
            ((69 - i, 148 + i * 47 + i * i // 9), (727 + i, 127 + i * 47 + i * i // 9))
            for i in range(16)
        ]
    elif paper == SLOTS:
        width, height = 806, 998
        xs = [145, 403, 680]
        endpoints = [((95, 172 + i * 69), (734, 180 + i * 69)) for i in range(11)]
    else:
        raise KeyError(paper)
    rows = []
    for (xl, yl), (xr, yr) in endpoints:
        rows.append([round(yl + (yr - yl) * (x - xl) / (xr - xl)) for x in xs])
    return {
        "size": [width, height],
        "xs": xs,
        "rows": rows,
        "split": "prospective_holdout",
        "template": paper,
        "kind": "ruled",
    }, endpoints


def labels_for(paper):
    return _geometry(paper)[0]


def generate(paper, path):
    labels, endpoints = _geometry(paper)
    image = Image.new("RGB", labels["size"], "#f5f1e6" if paper == NOTES else "#f0f4f3")
    draw = ImageDraw.Draw(image)
    large, small = ImageFont.load_default(size=25), ImageFont.load_default(size=15)
    if paper == NOTES:
        draw.rectangle((35, 33, 48, 98), fill="#5c806e")
        draw.text((68, 32), "MEASUREMENT NOTEBOOK", font=large, fill="#3a5147")
        draw.text(
            (69, 71),
            "Experimental physics    /    laboratory observations",
            font=small,
            fill="#50645c",
        )
        for x in range(78, 710, 10):
            draw.line((x, 932, x + 3, 932), fill="#b1aa98")
    else:
        draw.rounded_rectangle((55, 32, 249, 71), radius=6, outline="#71908d", width=2)
        draw.text((68, 44), "INSTRUMENT LAB", font=small, fill="#435c59")
        draw.text((62, 88), "Two-entry measurement record", font=large, fill="#344e4c")
        for index, letter in enumerate(["1", "2"]):
            draw.text((62, 152 + 69 * index), letter, font=small, fill="#597974")
        draw.text(
            (62, 936),
            "Measurement register  /  readings and calculation",
            font=small,
            fill="#5d7471",
        )
    for left, right in endpoints:
        draw.line(
            (left, right), fill="#84998a" if paper == NOTES else "#78948f", width=2
        )
    image.save(path, format="PNG")
    return labels
