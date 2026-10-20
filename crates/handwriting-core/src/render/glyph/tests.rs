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
            assert_eq!(ink_count(row - 2), 0);
            assert_eq!(ink_count(row + 2), 0);
            assert!(g.top < axis - size as i32 / 3);
            assert!(g.bottom() > axis + size as i32 / 3);
        }
    }
}
#[test]
fn root_hook_and_roof_stay_four_connected_at_all_sizes() {
    for book in books() {
        for size in [24., 40., 64.] {
            let mut gs = Glyphs::new(book);
            let g = gs.node(&text::parse("√(a+b+c+d)")[0], size).unwrap();
            let mut seen = vec![false; g.mask.len()];
            let mut largest = (0, 0);
            for (x, y, p) in g.mask.enumerate_pixels() {
                let index = (y * g.mask.width() + x) as usize;
                if p[0] < 128 || seen[index] {
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
                    ] {
                        if nx < 0
                            || ny < 0
                            || nx >= g.mask.width() as i32
                            || ny >= g.mask.height() as i32
                        {
                            continue;
                        }
                        let index = ny as usize * g.mask.width() as usize + nx as usize;
                        if !seen[index] && g.mask[(nx as u32, ny as u32)][0] >= 128 {
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
