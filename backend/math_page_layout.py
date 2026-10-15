"""含复合数学字形的 handright 页布局。"""

import functools
import math

from PIL import Image, ImageDraw


def install_math_page_layout(core, is_math_glyph, measure_bbox):
    """2026-10-15：安装按真实墨迹范围换行、调行距与分页的布局适配器。"""
    original = core._draw_page
    if getattr(original, "_math_page_layout", False):
        return

    def raster(char, font):
        # 2026-10-15：测量只用于预留画布，前进量始终取实际绘制的返回值。
        left, top, right, bottom = measure_bbox(char, font, getattr(font, "path", None))
        left, top = math.floor(left), math.floor(top)
        right, bottom = math.ceil(right), math.ceil(bottom)
        image = Image.new("1", (max(1, right - left + 4), max(1, bottom - top + 4)), 0)
        origin = (2 - left, 2 - top)
        advance = core._draw_char(ImageDraw.Draw(image), char, origin, font)
        ink = image.getbbox()
        if ink is None:
            return image.crop((0, 0, 1, 1)), (0, 0, 0, 0), max(1, advance)
        bbox = (ink[0] - origin[0], ink[1] - origin[1], ink[2] - origin[0], ink[3] - origin[1])
        return image.crop(ink), bbox, max(1, advance)

    def fit(char, font, available_width, available_height):
        # 2026-10-15：先以字体原生尺寸重绘；极窄纸张再整体等比缩小，分式不拆开。
        bbox = measure_bbox(char, font, getattr(font, "path", None))
        while font.size > 8 and (bbox[2] - min(0, bbox[0]) > available_width
                                 or bbox[3] - bbox[1] > available_height):
            ratio = min(available_width / max(1, bbox[2] - min(0, bbox[0])),
                        available_height / max(1, bbox[3] - bbox[1]))
            font = font.font_variant(size=max(8, min(font.size - 1, int(font.size * ratio))))
            bbox = measure_bbox(char, font, getattr(font, "path", None))
        image, bbox, advance = raster(char, font)
        width = max(advance, bbox[2]) - min(0, bbox[0])
        height = bbox[3] - bbox[1]
        ratio = min(1, available_width / max(1, width), available_height / max(1, height))
        if ratio < 1:
            image = image.resize((max(1, int(image.width * ratio)), max(1, int(image.height * ratio))),
                                 Image.Resampling.NEAREST)
            left, top = math.floor(bbox[0] * ratio), math.floor(bbox[1] * ratio)
            bbox = (left, top, left + image.width, top + image.height)
            advance = max(1, math.floor(advance * ratio))
        return image, bbox, advance

    def corrected_pair(image, bbox, advance, wrong, font, tpl, rand, width, height):
        # 2026-10-15：先划掉错字，再在其右侧写正确字，不能把两者叠成一个字。
        wrong_image, wrong_bbox, wrong_advance = fit(wrong, font, width, height)
        strokes = []

        class StrokeCapture:
            def line(self, points, fill, width):
                strokes.append((tuple(points), fill, max(1, width)))

        core._draw_strikethrough(StrokeCapture(), 0, 0, tpl, rand)
        bounds = [wrong_bbox]
        for points, _, thickness in strokes:
            pad = (thickness + 1) // 2 + 1
            bounds.append((math.floor(min(points[::2]) - pad), math.floor(min(points[1::2]) - pad),
                           math.ceil(max(points[::2]) + pad + 1), math.ceil(max(points[1::2]) + pad + 1)))
        wrong_right = max(bound[2] for bound in bounds)
        offset = max(wrong_advance + max(0, tpl.get_word_spacing()), wrong_right + max(2, round(font.size * 0.08)))
        bounds.append((bbox[0] + offset, bbox[1], bbox[2] + offset, bbox[3]))
        left_edge, top_edge = min(bound[0] for bound in bounds), min(bound[1] for bound in bounds)
        right_edge, bottom_edge = max(bound[2] for bound in bounds), max(bound[3] for bound in bounds)
        advance += offset
        # 2026-10-15：先缩放坐标再分配蒙版，极端删除线参数不能产生超大中间画布。
        ratio = min(1, width / max(1, max(advance, right_edge) - min(0, left_edge)),
                    height / max(1, bottom_edge - top_edge))
        pair_width = max(1, min(width, int((right_edge - left_edge) * ratio)))
        pair_height = max(1, min(height, int((bottom_edge - top_edge) * ratio)))
        pair = Image.new("1", (pair_width, pair_height), 0)

        def paste_scaled(glyph, x, y):
            if ratio < 1:
                glyph = glyph.resize((max(1, int(glyph.width * ratio)), max(1, int(glyph.height * ratio))),
                                     Image.Resampling.NEAREST)
            position = (max(0, min(pair_width - glyph.width, round((x - left_edge) * ratio))),
                        max(0, min(pair_height - glyph.height, round((y - top_edge) * ratio))))
            pair.paste(glyph, position, glyph)

        paste_scaled(wrong_image, wrong_bbox[0], wrong_bbox[1])
        pair_draw = ImageDraw.Draw(pair)
        for points, fill, thickness in strokes:
            pair_draw.line(tuple(round((value - (left_edge if index % 2 == 0 else top_edge)) * ratio)
                                 for index, value in enumerate(points)), fill=fill,
                           width=max(1, round(thickness * ratio)))
        paste_scaled(image, bbox[0] + offset, bbox[1])
        left_edge, top_edge = math.floor(left_edge * ratio), math.floor(top_edge * ratio)
        advance = max(1, math.floor(advance * ratio))
        right_edge, bottom_edge = left_edge + pair.width, top_edge + pair.height
        return pair, (left_edge, top_edge, right_edge, bottom_edge), advance

    @functools.wraps(original)
    def draw_page(page, text, start, tpl, rand):
        if not any(is_math_glyph(char) for char in text[start:]):
            return original(page, text, start, tpl, rand)
        core._check_template(page, tpl)
        left, top = tpl.get_left_margin(), tpl.get_top_margin()
        right = page.width() - tpl.get_right_margin()
        bottom = page.height() - tpl.get_bottom_margin()
        usable_width, usable_height = right - left, bottom - top
        if usable_width <= 0 or usable_height <= 0:
            raise core.LayoutError("No writable area for mathematical glyphs")
        draw = page.draw()
        spacing = tpl.get_line_spacing()
        font_size = tpl.get_font().size
        grid = core.Feature.GRID_LAYOUT in tpl.get_features()
        cell_width = max(1, tpl.get_word_spacing() + font_size)
        gap = max(2, round(font_size * 0.12))
        previous_y = None
        previous_bottom = top - gap
        candidates = tuple(char for char in text if char not in tpl.get_end_chars() + " \n\t\r")

        while start < len(text):
            line_start, line_state = start, rand.getstate()
            units = []
            cursor = left
            while start < len(text) and text[start] != "\n":
                char = text[start]
                char_state = rand.getstate()
                font = core._get_font(tpl, rand)
                image, bbox, advance = fit(char, font, usable_width, usable_height)
                jitter_x = core.gauss(rand, 0, tpl.get_word_spacing_sigma()) if grid else 0
                jitter_y = round(core.gauss(rand, 0, tpl.get_line_spacing_sigma()))
                x = round(cursor + jitter_x)
                # 2026-10-15：保留位置扰动，但不能让负边承或网格抖动越过纸张左边距。
                x = max(left - bbox[0], x)
                ink_right = x + bbox[2]
                footprint = max(advance, bbox[2]) - min(0, bbox[0])
                if units and ink_right > right:
                    rand.setstate(char_state)
                    break
                if not units and ink_right > right:
                    x = right - bbox[2]
                # 2026-10-15：开括号等禁行尾字符，在尚有空间时尽量与下一个字形一起换行。
                if units and char in tpl.get_start_chars() and start + 1 < len(text):
                    next_bbox = measure_bbox(text[start + 1], font, getattr(font, "path", None))
                    if x + footprint + max(0, next_bbox[2]) > right:
                        rand.setstate(char_state)
                        break
                strike = bool(candidates and rand.random() < tpl.get_strikethrough_probability())
                if strike:
                    # 2026-10-15：涂改仍使用手写引擎的笔画与参数，固定使用传入的局部随机源。
                    wrong = rand.choice(candidates)
                    image, bbox, advance = corrected_pair(image, bbox, advance, wrong, font, tpl, rand,
                                                          usable_width, usable_height)
                    x = max(left - bbox[0], round(cursor + jitter_x))
                    if units and x + bbox[2] > right:
                        rand.setstate(char_state)
                        break
                    x = min(x, right - bbox[2])
                units.append((image, bbox, x, jitter_y))
                if grid:
                    # 2026-10-15：普通文字保留用户的固定网格字距，复合单元才额外占格。
                    cells = math.ceil(max(advance, bbox[2]) / cell_width) if is_math_glyph(char) or strike else 1
                    cursor = x + cells * cell_width
                else:
                    step = core.gauss(rand, advance + tpl.get_word_spacing(), tpl.get_word_spacing_sigma())
                    # 2026-10-15：负字距是普通文字的显式参数，不能被数学行的防碰撞规则覆盖。
                    cursor = x + max(1, step, bbox[2] if is_math_glyph(char) or strike else 1)
                start += 1
            if start < len(text) and text[start] == "\n":
                start += 1
            if not units:
                # 2026-10-15：空行正常消耗输入和基础行距，避免循环卡在换行符。
                previous_y = (previous_y if previous_y is not None else top - font_size) + spacing
                previous_bottom = max(previous_bottom, previous_y + font_size)
                continue
            min_y = min(bbox[1] + dy for _, bbox, _, dy in units)
            max_y = max(bbox[3] + dy for _, bbox, _, dy in units)
            # 2026-10-15：极端纵向抖动同样不能使单行高于整页，整体缩放行字形而非裁切。
            if max_y - min_y > usable_height:
                factor = usable_height / (max_y - min_y)
                adjusted = []
                for image, bbox, x, dy in units:
                    image = image.resize((max(1, int(image.width * factor)), max(1, int(image.height * factor))), Image.Resampling.NEAREST)
                    y1 = math.floor((bbox[1] + dy - min_y) * factor)
                    adjusted.append((image, (bbox[0], y1, bbox[0] + image.width, y1 + image.height), x, 0))
                units, min_y = adjusted, 0
                max_y = max(bbox[3] for _, bbox, _, _ in units)
            baseline = max(top - min_y, top + spacing - font_size) if previous_y is None else max(
                previous_y + spacing, previous_bottom + gap - min_y)
            if baseline + max_y > bottom:
                if line_start == 0 or previous_y is None:
                    baseline = bottom - max_y
                else:
                    rand.setstate(line_state)
                    return line_start
            for image, bbox, x, dy in units:
                draw.bitmap((x + bbox[0], baseline + dy + bbox[1]), image, fill=core._WHITE)
            previous_y, previous_bottom = baseline, baseline + max_y
        return start

    draw_page._math_page_layout = True
    core._draw_page = draw_page
