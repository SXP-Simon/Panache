//! 按真实页面输出比较图内墨迹。纸面锁定方向，避免整图位移或旋转被误算为笔触变化。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, render, text};
use image::{GrayImage, Luma, RgbaImage};
use imageproc::region_labelling::{Connectivity, connected_components};
use std::{fs, path::PathBuf};

struct Case {
    name: String,
    source: String,
    fixed: bool,
}

impl Case {
    fn single_component(&self) -> bool {
        matches!(self.name.as_str(), "merge" | "diagonal")
    }
}

fn cases() -> Vec<Case> {
    let mut cases = Vec::new();
    let mut add = |name: &str, source: &str, fixed| {
        assert!(
            matches!(
                text::parse(source).as_slice(),
                [text::Node::Circuit(_) | text::Node::Table(_)]
            ),
            "{name}"
        );
        cases.push(Case {
            name: name.into(),
            source: source.into(),
            fixed,
        });
    };
    for (name, source, fixed) in [
        (
            "ledger",
            "⟦ 品名 | 数量 | 单价 ; 纸本 | 12 | 8 ; 铅笔 | 24 | 3 ⟧",
            false,
        ),
        (
            "wide",
            "⟦ 日 | 一 | 二 | 三 | 四 | 五 | 六 | 七 ; 甲 | 2 | 3 | 1 | 5 | 4 | 3 | 6 ; 乙 | 3 | 1 | 2 | 4 | 5 | 6 | 7 ⟧",
            false,
        ),
        (
            "tall",
            "⟦ 名次 | 记录 ; 1 | 甲 ; 2 | 乙 ; 3 | 丙 ; 4 | 丁 ; 5 | 戊 ; 6 | 己 ; 7 | 庚 ⟧",
            false,
        ),
        (
            "mixed",
            "⟦ ╌╌ ; 站点 ┆ 到达 | 离开 ; 甲站 ┆ 8 | 9 ; 乙站 ┆ 11 | 12 ; ── ⟧",
            false,
        ),
        ("dashed", "⟦ ╌╌ ; A | 1 ; B | 2 ; ╌╌ ⟧", true),
        ("matrix", "⟦ bmatrix: 1  2  3 ; 4  5  6 ⟧", true),
    ] {
        add(name, source, fixed);
    }
    for (name, paths) in [
        (
            "decision",
            r"\draw (0,1) -- (1.8,2) -- (3.6,1) -- (1.8,0) -- cycle;
\draw[->] (-2,1) -- (0,1); \draw[->] (3.6,1) -- (5.6,1);
\draw[->] (1.8,0) -- (1.8,-1.3); \draw (1.8,1) node{合格};
\draw (4.6,1) node[above]{是}; \draw (1.8,-0.8) node[right]{否};",
        ),
        (
            "merge",
            r"\draw[->] (-3,2) -| (0,0); \draw (3,2) |- (0,1); \draw[->] (0,0) -- (0,-1.5);",
        ),
        (
            "retry",
            r"\draw (0,0) -- (3,0) -- (3,1) -- (0,1) -- cycle;
\draw (1.5,0.5) node{重试}; \draw[->] (3,0.5) -- (4.5,0.5) -- (4.5,2) -- (-1.5,2) |- (0,0.5);",
        ),
        (
            "diagonal",
            r"\draw[->] (-2,-1) -- (2,1); \draw[->] (0,0) -- (0,2); \draw (0,0) node[circ]{};",
        ),
    ] {
        add(
            name,
            &format!("\\begin{{circuitikz}}\n{paths}\n\\end{{circuitikz}}"),
            false,
        );
    }
    for file in [
        include_str!("fixtures/circuitikz.json"),
        include_str!("fixtures/realistic-circuits.json"),
    ] {
        let fixtures: Vec<serde_json::Value> = serde_json::from_str(file).unwrap();
        for case in fixtures {
            if case["valid"] != false && case["id"] != "loaded-rc-ladder" {
                add(
                    case["id"].as_str().unwrap(),
                    case["source"].as_str().unwrap(),
                    false,
                );
            }
        }
    }
    cases
}

fn font(name: &str) -> FontBook {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../assets/font_assets")
        .join(format!("{name}.ttf"));
    FontBook::new(&fs::read(path).unwrap(), &[]).unwrap()
}

fn ink(
    case: &Case,
    font: &FontBook,
    size: f32,
    width: u32,
    strength: f32,
    seed: u64,
    locked: bool,
) -> RgbaImage {
    let request = RenderRequest {
        text: case.source.clone(),
        fonts: font.clone(),
        limits: Limits::default(),
        background: None,
        params: Parameters {
            width: Some(width),
            height: Some(680),
            font_size: size,
            line_spacing: size * 1.4,
            left_margin: 16.,
            right_margin: 16.,
            top_margin: 16.,
            bottom_margin: 16.,
            font_size_sigma: 0.,
            word_spacing_sigma: 0.,
            ink_depth_sigma: 0.,
            strikethrough_probability: 0.,
            perturb_x_sigma: 0.,
            perturb_y_sigma: 0.,
            perturb_theta_sigma: 0.1 * strength,
            background_ruled: locked,
            preview: false,
            seed,
            ..Parameters::default()
        },
    };
    let mut result = None;
    render(&request, &Cancellation::default(), |index, image| {
        assert_eq!(index, 0, "{}", case.name);
        let (mut left, mut top, mut right, mut bottom) = (width, image.height(), 0, 0);
        for (x, y, _) in image.enumerate_pixels().filter(|(_, _, p)| p[0] < 128) {
            left = left.min(x);
            top = top.min(y);
            right = right.max(x);
            bottom = bottom.max(y);
        }
        assert!(
            left >= 16 && top >= 16 && right < width - 16 && bottom < image.height() - 16,
            "{}",
            case.name
        );
        assert!(right > left && bottom > top, "{}", case.name);
        result = Some(
            image::imageops::crop_imm(&image, left, top, right - left + 1, bottom - top + 1)
                .to_image(),
        );
        Ok(())
    })
    .unwrap();
    let crop = result.unwrap();
    if case.single_component() {
        // 这两个无文字图的所有分支都应属于同一片墨迹。
        let mask = GrayImage::from_fn(crop.width(), crop.height(), |x, y| {
            Luma([u8::from(crop[(x, y)][0] < 128)])
        });
        let labels = connected_components(&mask, Connectivity::Eight, Luma([0]));
        assert_eq!(
            labels.pixels().map(|p| p[0]).max(),
            Some(1),
            "{}/{size}/{width}/{strength}/{seed}",
            case.name
        );
    }
    crop
}

#[test]
fn native_diagrams_replay_their_strokes_and_respect_fixed_borders() {
    let book = font("云烟体");
    for case in cases() {
        if case.single_component() {
            ink(&case, &book, 20., 340, 1., 20261123, false);
        }
        let plain = ink(&case, &book, 40., 920, 0., 0, true);
        let first = ink(&case, &book, 40., 920, 1., 7, true);
        assert!(
            first == ink(&case, &book, 40., 920, 1., 7, true),
            "unstable: {}",
            case.name
        );
        assert_eq!(
            plain == first,
            case.fixed,
            "unexpected response: {}",
            case.name
        );
    }
}

fn check_profile(cases: &[Case], book: &FontBook, name: &str, size: f32, width: u32) {
    let mut changed = [0; 3];
    let mut eligible = 0;
    for case in cases {
        let plain = ink(case, book, size, width, 0., 0, true);
        let mut strong_differs = false;
        for (i, strength) in [0., 0.35, 1.].into_iter().enumerate() {
            for seed in [0, 7, 20261123] {
                let same = (strength == 0. && seed == 0)
                    || ink(case, book, size, width, strength, seed, true) == plain;
                if strength > 0. && case.single_component() {
                    ink(case, book, size, width, strength, seed, false);
                }
                if case.fixed || strength == 0. {
                    assert!(
                        same,
                        "{}/{name}/{size}/{width}/{strength}/{seed}",
                        case.name
                    );
                } else if !same {
                    changed[i] += 1;
                    strong_differs |= strength == 1.;
                }
            }
        }
        if !case.fixed {
            eligible += 3;
            if width == 920 && size >= 40. {
                assert!(
                    strong_differs,
                    "no visible variation: {}/{name}/{size}",
                    case.name
                );
            }
        }
    }
    eprintln!(
        "{name} {size}px width={width}: light={} full={} out of {eligible} eligible case/seed pairs",
        changed[1], changed[2]
    );
}

#[test]
#[ignore = "extended visual coverage across fonts, sizes, page widths, strengths and seeds"]
fn sweep_native_diagram_variation() {
    let cases = cases();
    for name in ["云烟体", "霞鹜文楷"] {
        let book = font(name);
        std::thread::scope(|scope| {
            for size in [20., 40., 64.] {
                for width in [340, 920] {
                    let (book, cases) = (&book, &cases);
                    scope.spawn(move || {
                        check_profile(cases, book, name, size, width);
                    });
                }
            }
        });
    }
}
