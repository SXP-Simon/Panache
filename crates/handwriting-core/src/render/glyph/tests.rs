use super::*;
use crate::text;
use std::{collections::VecDeque, path::PathBuf, sync::OnceLock};

fn books() -> &'static [FontBook] {
    static BOOKS: OnceLock<Vec<FontBook>> = OnceLock::new();
    BOOKS.get_or_init(|| {
        ["云烟体", "李国夫手写体"]
            .iter()
            .map(|name| {
                let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join(format!("../../assets/font_assets/{name}.ttf"));
                FontBook::new(&std::fs::read(path).unwrap(), &[]).unwrap()
            })
            .collect()
    })
}
#[test]
fn logical_negation_is_a_continuous_bar_and_right_leg_in_handwritten_fonts() {
    for name in ["云烟体", "华阳手写体", "李国夫手写体", "霞鹜文楷"] {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join(format!("../../assets/font_assets/{name}.ttf"));
        let book = FontBook::new(&std::fs::read(path).unwrap(), &[]).unwrap();
        for size in [18., 36., 72., 124.] {
            let mut gs = Glyphs::new(&book);
            let glyph = gs.glyph('¬', size).unwrap();
            let mask = &glyph.mask;
            assert!(glyph.top < 0 && glyph.bottom() < 0);
            assert!((0..mask.height()).any(|y| {
                (0..mask.width()).filter(|x| mask[(*x, y)][0] > 0).count()
                    >= mask.width() as usize * 9 / 10
            }));
            assert!(
                (mask.width() / 2..mask.width())
                    .any(|x| (0..mask.height()).all(|y| mask[(x, y)][0] > 0))
            );
            let ink: Vec<_> = mask
                .enumerate_pixels()
                .filter(|(_, _, p)| p[0] > 0)
                .map(|(x, y, _)| (x, y))
                .collect();
            let mut seen = std::collections::HashSet::from([ink[0]]);
            let mut queue = VecDeque::from([ink[0]]);
            while let Some((x, y)) = queue.pop_front() {
                for (nx, ny) in [
                    (x as i32 - 1, y as i32),
                    (x as i32 + 1, y as i32),
                    (x as i32, y as i32 - 1),
                    (x as i32, y as i32 + 1),
                ] {
                    if nx >= 0
                        && ny >= 0
                        && nx < mask.width() as i32
                        && ny < mask.height() as i32
                        && mask[(nx as u32, ny as u32)][0] > 0
                        && seen.insert((nx as u32, ny as u32))
                    {
                        queue.push_back((nx as u32, ny as u32));
                    }
                }
            }
            assert_eq!(
                seen.len(),
                ink.len(),
                "negation must remain one connected stroke"
            );
            assert_eq!(gs.glyph('¬', size).unwrap().mask, *mask);
            assert!(glyph.advance >= glyph.right() as f32);
        }
    }
}
#[test]
fn distribution_table_has_two_dimensional_handwritten_ink_and_continuous_rules() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut gs = Glyphs::new(book);
            for source in [
                "⟦ X | 0  1  2  3 ; ── ; P | (8)/(15)  (4)/(15)  (2)/(15)  (1)/(15) ⟧",
                "⟦ Y | 1  2  3 ; ── ; P | ⅓  ⅓  ⅓ ⟧",
            ] {
                let parsed = text::parse(source);
                assert!(matches!(parsed.as_slice(), [Node::Table(_)]));
                let g = gs.sequence(&parsed, size).unwrap();
                assert!(
                    g.mask.height() as f32 > size * 2.,
                    "table must have two actual rows"
                );
                let fullest_row = (0..g.mask.height().saturating_sub(2))
                    .map(|y| {
                        (0..g.mask.width())
                            .filter(|&x| (y..y + 3).any(|yy| g.mask[(x, yy)][0] > 0))
                            .count()
                    })
                    .max()
                    .unwrap();
                assert!(
                    fullest_row as f32 > g.mask.width() as f32 * 0.90,
                    "horizontal rule spans all columns"
                );
                let fullest_col = (0..g.mask.width())
                    .map(|x| {
                        (0..g.mask.height())
                            .filter(|&y| g.mask[(x, y)][0] > 0)
                            .count()
                    })
                    .max()
                    .unwrap();
                assert!(
                    fullest_col as f32 > g.mask.height() as f32 * 0.85,
                    "vertical rule spans both rows"
                );
                // 2026-10-20：外框四边必须存在，不能只画分布律原有的一横一竖。
                for y in [0, g.mask.height() - 1] {
                    let coverage = (0..g.mask.width())
                        .filter(|&x| {
                            (y.saturating_sub(2)..=(y + 2).min(g.mask.height() - 1))
                                .any(|yy| g.mask[(x, yy)][0] > 0)
                        })
                        .count();
                    assert!(
                        coverage as f32 > g.mask.width() as f32 * 0.85,
                        "outer horizontal grid rule"
                    );
                }
                for x in [0, g.mask.width() - 1] {
                    let coverage = (0..g.mask.height())
                        .filter(|&y| {
                            (x.saturating_sub(2)..=(x + 2).min(g.mask.width() - 1))
                                .any(|xx| g.mask[(xx, y)][0] > 0)
                        })
                        .count();
                    assert!(
                        coverage as f32 > g.mask.height() as f32 * 0.85,
                        "outer vertical grid rule"
                    );
                }
                let fit = g.clone().fit(120., 100.);
                assert!(fit.mask.width() <= 120 && fit.mask.height() <= 100);
                assert!(fit.ink);
            }
        }
    }
}
#[test]
fn all_math_bounds_keep_actual_ink_and_native_baseline() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut glyphs = Glyphs::new(book);
            for input in [
                "(1)/(2)",
                "((a)/(b))/((c)/(d))",
                "√((x+1)/(x-1))",
                "√(1+√(1+√(x)))",
                "¹²√(x³)",
                "aₙ₊₁=x²",
                "xₙ²+y²ₘ",
                "(AB)⃗",
                "x̄",
                "(ab)̂",
                "x̲",
            ] {
                let g = glyphs.sequence(&text::parse(input), size).unwrap();
                assert!(g.ink, "{input}");
                assert!(
                    g.advance >= g.right() as f32,
                    "{input}: {} < {}",
                    g.advance,
                    g.right()
                );
                assert!(g.mask.rows().next().unwrap().any(|p| p[0] > 0));
                assert!(g.mask.rows().next_back().unwrap().any(|p| p[0] > 0));
            }
        }
    }
}
#[test]
fn paired_scripts_share_one_column_and_use_normal_handwritten_letters() {
    for book in books() {
        let mut gs = Glyphs::new(book);
        let a = gs.sequence(&text::parse("xₙ"), 40.).unwrap();
        let b = gs.sequence(&text::parse("x²"), 40.).unwrap();
        let both = gs.sequence(&text::parse("xₙ²"), 40.).unwrap();
        assert_eq!(both.advance, a.advance.max(b.advance));
        assert_eq!(both.top, b.top);
        assert_eq!(both.bottom(), a.bottom());
        let explicit = gs.sequence(&text::parse("x_(n)^(2)"), 40.).unwrap();
        assert_eq!(both.mask, explicit.mask);
    }
}

#[test]
fn matrix_delimiters_are_continuous_equal_weight_and_do_not_add_a_grid() {
    use crate::text::TableKind;
    for kind in [
        TableKind::Parentheses,
        TableKind::Brackets,
        TableKind::Braces,
        TableKind::Determinant,
        TableKind::Norm,
        TableKind::Cases,
    ] {
        let (_, paths) = table::matrix::delimiters(kind, 200, 220, 64.);
        assert!(!paths.is_empty());
        assert!(paths.iter().all(|(_, pen)| *pen == 2));
        for (points, _) in &paths {
            assert_eq!(points.first().unwrap().1, 0);
            assert_eq!(points.last().unwrap().1, 220);
            assert!(points.windows(2).all(|pair| pair[0].1 <= pair[1].1));
        }
        if kind == TableKind::Cases {
            assert_eq!(paths.len(), 1, "piecewise functions only have a left brace");
        }
    }
    for book in books() {
        for size in [24., 40., 70.] {
            let mut gs = Glyphs::new(book);
            let plain = gs
                .sequence(&text::parse("⟦ matrix: 1  0 ; 0  1 ⟧"), size)
                .unwrap();
            assert!(
                plain.mask.height() as f32 > size,
                "two physical rows required"
            );
            // 2026-10-22：裸矩阵不能自动画表格横线；至少有一整行留白分开两行数字。
            assert!((0..plain.mask.height()).any(|y| {
                plain
                    .mask
                    .rows()
                    .nth(y as usize)
                    .unwrap()
                    .all(|pixel| pixel[0] == 0)
            }));
            let bracket = gs
                .sequence(&text::parse("⟦ bmatrix: 1  0 ; 0  1 ⟧"), size)
                .unwrap();
            assert!(bracket.mask.width() > plain.mask.width());
            let column_coverage = (0..bracket.mask.width())
                .map(|x| {
                    (0..bracket.mask.height())
                        .filter(|&y| bracket.mask[(x, y)][0] > 0)
                        .count()
                })
                .max()
                .unwrap();
            assert!(
                column_coverage as f32 > bracket.mask.height() as f32 * 0.9,
                "bracket must span both rows"
            );
            let axis = gs.glyph('x', size).unwrap();
            assert!(
                (bracket.top + bracket.bottom() - axis.top - axis.bottom()).abs() <= 3,
                "matrix must be centered on mathematical axis"
            );
            let cases = gs
                .sequence(&text::parse("⟦ cases: (1)/(2)  x≥0 ; -x²  x<0 ⟧"), size)
                .unwrap();
            assert!(cases.ink);
            let fitted = cases.fit(100., 90.);
            assert!(fitted.mask.width() <= 100 && fitted.mask.height() <= 90);
        }
    }
}
#[test]
fn unicode_minus_preserves_the_same_handwritten_ink_as_ascii_minus() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut gs = Glyphs::new(book);
            let unicode = gs
                .sequence(
                    &text::parse(&text::normalize("−b ± √(b² − 4ac)", false)),
                    size,
                )
                .unwrap();
            let ascii = gs.sequence(&text::parse("-b ± √(b² - 4ac)"), size).unwrap();
            assert_eq!(unicode.mask, ascii.mask);
            assert_eq!(unicode.advance, ascii.advance);
            let minus = gs.glyph('-', size).unwrap();
            assert!(minus.ink);
            assert!(minus.mask.pixels().any(|p| p[0] >= 128));
        }
    }
}
#[test]
fn fraction_bar_uses_handwritten_axis_and_clear_ink_gaps() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut gs = Glyphs::new(book);
            let x = gs.glyph('x', size).unwrap();
            let axis = (x.top + x.bottom()) / 2;
            let g = gs
                .node(
                    &Node::Fraction(text::parse("123"), text::parse("456")),
                    size,
                )
                .unwrap();
            let row = (axis - g.top) as u32;
            let ink_count = |y| {
                g.mask
                    .rows()
                    .nth(y as usize)
                    .unwrap()
                    .filter(|p| p[0] > 0)
                    .count()
            };
            assert!(ink_count(row) > size as usize);
            // 2026-10-24：笔宽来自主字体，包含抗锯齿边缘后仍须与上下数字分离。
            let clear = (gs.pen.thickness(size) / 2.).ceil() as u32 + 2;
            assert_eq!(ink_count(row - clear), 0);
            assert_eq!(ink_count(row + clear), 0);
            assert!(g.top < axis - size as i32 / 3);
            assert!(g.bottom() > axis + size as i32 / 3);
        }
    }
}
#[test]
fn natural_math_paths_do_not_move_numerators_denominators_or_radicands() {
    let pixel = |g: &Glyph, x: i32, y: i32| {
        if x < g.left || y < g.top || x >= g.right() || y >= g.bottom() {
            0
        } else {
            g.mask[((x - g.left) as u32, (y - g.top) as u32)][0]
        }
    };
    for book in books() {
        for size in [24., 40., 72.] {
            let mut quiet = Glyphs::new(book);
            let mut natural = Glyphs::with_parameters(
                book,
                &Parameters {
                    perturb_x_sigma: 100.,
                    perturb_y_sigma: 100.,
                    perturb_theta_sigma: 100.,
                    ..Parameters::default()
                },
            );
            let x = quiet.glyph('x', size).unwrap();
            let axis = (x.top + x.bottom()) / 2;
            let fraction = Node::Fraction(text::parse("AB²"), text::parse("CDₙ"));
            let a = quiet.node(&fraction, size).unwrap();
            let b = natural.node(&fraction, size).unwrap();
            let pen_area = (quiet.pen.thickness(size) / 2.).ceil() as i32 + 3;
            for y in a.top.min(b.top)..a.bottom().max(b.bottom()) {
                if (y - axis).abs() <= pen_area {
                    continue;
                }
                for x in a.left.min(b.left)..a.right().max(b.right()) {
                    assert_eq!(
                        pixel(&a, x, y),
                        pixel(&b, x, y),
                        "numerator/denominator moved at {size}"
                    );
                }
            }
            let body = text::parse("a²+b²");
            let body_glyph = quiet.sequence(&body, size).unwrap();
            let radical = Node::Radical(body, vec![]);
            let a = quiet.node(&radical, size).unwrap();
            let b = natural.node(&radical, size).unwrap();
            let body_x =
                (size * 0.46).round().max(10.) as i32 + (size * 0.04).round().max(1.) as i32;
            for y in body_glyph.top..body_glyph.bottom() {
                for x in body_x..body_x + body_glyph.mask.width() as i32 {
                    assert_eq!(pixel(&a, x, y), pixel(&b, x, y), "radicand moved at {size}");
                }
            }
        }
    }
}
#[test]
fn native_root_hook_and_roof_stay_connected_at_all_sizes() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut gs = Glyphs::new(book);
            let g = gs.node(&text::parse("√(a+b+c+d)")[0], size).unwrap();
            let mut seen = vec![false; g.mask.len()];
            let mut largest = (0, 0);
            for (x, y, p) in g.mask.enumerate_pixels() {
                let index = (y * g.mask.width() + x) as usize;
                if p[0] < 32 || seen[index] {
                    continue;
                }
                let mut queue = VecDeque::from([(x, y)]);
                seen[index] = true;
                let (mut min_x, mut max_x, mut min_y, mut max_y) = (x, x, y, y);
                while let Some((xx, yy)) = queue.pop_front() {
                    min_x = min_x.min(xx);
                    max_x = max_x.max(xx);
                    min_y = min_y.min(yy);
                    max_y = max_y.max(yy);
                    for (nx, ny) in [
                        (xx as i32 - 1, yy as i32),
                        (xx as i32 + 1, yy as i32),
                        (xx as i32, yy as i32 - 1),
                        (xx as i32, yy as i32 + 1),
                        (xx as i32 - 1, yy as i32 - 1),
                        (xx as i32 - 1, yy as i32 + 1),
                        (xx as i32 + 1, yy as i32 - 1),
                        (xx as i32 + 1, yy as i32 + 1),
                    ] {
                        if nx < 0
                            || ny < 0
                            || nx >= g.mask.width() as i32
                            || ny >= g.mask.height() as i32
                        {
                            continue;
                        }
                        let index = ny as usize * g.mask.width() as usize + nx as usize;
                        if !seen[index] && g.mask[(nx as u32, ny as u32)][0] >= 32 {
                            seen[index] = true;
                            queue.push_back((nx as u32, ny as u32));
                        }
                    }
                }
                if max_x - min_x > largest.0 {
                    largest = (max_x - min_x, max_y - min_y);
                }
            }
            assert!(largest.0 > size as u32);
            assert!(largest.1 >= size as u32 / 2, "{size}: {largest:?}");
        }
    }
}
#[test]
fn unicode_and_explicit_root_indices_have_identical_single_scaling() {
    let mut gs = Glyphs::new(&books()[0]);
    for (a, b) in [
        ("³√(x)", "∛(x)"),
        ("⁴√(x)", "∜(x)"),
        ("¹²√(x)", "\\sqrt[12]{x}"),
    ] {
        let a = gs.sequence(&text::parse(a), 40.).unwrap();
        let b = gs.sequence(&text::parse(b), 40.).unwrap();
        assert_eq!(a.mask, b.mask);
        assert_eq!(a.top, b.top);
    }
}
#[test]
fn accents_span_whole_base_and_leave_clear_air() {
    for book in books() {
        let mut gs = Glyphs::new(book);
        let base = gs.sequence(&text::parse("AB"), 40.).unwrap();
        for mark in [
            '\u{0304}', '\u{0305}', '\u{0302}', '\u{20d7}', '\u{0307}', '\u{0308}', '\u{0303}',
            '\u{0332}',
        ] {
            let g = gs
                .node(&Node::Accent(text::parse("AB"), mark), 40.)
                .unwrap();
            assert!(g.advance >= base.advance);
            if mark == '\u{0332}' {
                assert!(g.bottom() > base.bottom() + 2);
            } else {
                assert!(g.top < base.top - 2);
            }
        }
    }
}

#[test]
fn scripts_follow_actual_base_height_and_natural_ink_width() {
    for book in books() {
        for size in [24., 40., 70.] {
            let mut glyphs = Glyphs::new(book);
            for letter in ['x', 'H', 'g'] {
                let base = glyphs.unit(&[Node::Char(letter)], size).unwrap();
                let upper = glyphs
                    .scripts(&[Node::Char('2')], &[], size, &base, 0)
                    .unwrap();
                let lower = glyphs
                    .scripts(&[], &[Node::Char('n')], size, &base, 0)
                    .unwrap();
                assert!(
                    upper.bottom() > base.top && upper.bottom() < base.bottom(),
                    "{letter}/{size}: floating superscript"
                );
                assert!(
                    (lower.top - base.bottom()).abs() <= (size * 0.25) as i32,
                    "{letter}/{size}: floating subscript"
                );
                let combined = glyphs
                    .sequence(&text::parse(&format!("{letter}ₙ²")), size)
                    .unwrap();
                assert!(
                    combined.advance < base.mask.width() as f32 + size,
                    "{letter}/{size}: excessive trailing bearing"
                );
                let chinese = glyphs.unit(&[Node::Char('中')], size).unwrap();
                assert_eq!(chinese.advance, glyphs.glyph('中', size).unwrap().advance);
            }
        }
    }
}

#[test]
fn table_grid_has_uniform_strokes_and_visually_centered_cells() {
    for book in books() {
        let mut gs = Glyphs::new(book);
        let g = gs
            .sequence(
                &text::parse("⟦ X | 0  1 ; ── ; P | (8)/(15)  (1)/(3) ⟧"),
                64.,
            )
            .unwrap();
        let cluster = |values: Vec<u32>| {
            let mut groups: Vec<Vec<u32>> = Vec::new();
            for v in values {
                if groups
                    .last()
                    .is_none_or(|group| v > group.last().unwrap() + 1)
                {
                    groups.push(vec![]);
                }
                groups.last_mut().unwrap().push(v);
            }
            groups
        };
        let horizontal = cluster(
            (0..g.mask.height())
                .filter(|&y| {
                    (0..g.mask.width())
                        .filter(|&x| g.mask[(x, y)][0] > 0)
                        .count() as f32
                        > g.mask.width() as f32 * 0.90
                })
                .collect(),
        );
        let vertical = cluster(
            (0..g.mask.width())
                .filter(|&x| {
                    (0..g.mask.height())
                        .filter(|&y| g.mask[(x, y)][0] > 0)
                        .count() as f32
                        > g.mask.height() as f32 * 0.90
                })
                .collect(),
        );
        assert_eq!(horizontal.len(), 3);
        assert_eq!(vertical.len(), 4);
        assert!(
            horizontal
                .iter()
                .chain(&vertical)
                .all(|line| line.len() == horizontal[0].len())
        );
        for row in horizontal.windows(2) {
            for col in vertical.windows(2) {
                let (x0, x1) = (*col[0].last().unwrap() + 3, col[1][0] - 2);
                let (y0, y1) = (*row[0].last().unwrap() + 3, row[1][0] - 2);
                let mut ink = Vec::new();
                for y in y0..y1 {
                    for x in x0..x1 {
                        if g.mask[(x, y)][0] > 0 {
                            ink.push((x, y));
                        }
                    }
                }
                assert!(!ink.is_empty());
                let left = ink.iter().map(|p| p.0).min().unwrap();
                let right = ink.iter().map(|p| p.0).max().unwrap();
                let top = ink.iter().map(|p| p.1).min().unwrap();
                let bottom = ink.iter().map(|p| p.1).max().unwrap();
                assert!((left as i32 + right as i32 - (col[0][0] + col[1][0]) as i32).abs() <= 3);
                assert!((top as i32 + bottom as i32 - (row[0][0] + row[1][0]) as i32).abs() <= 3);
            }
        }
    }
}
