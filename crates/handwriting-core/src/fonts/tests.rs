//! 2026-10-15：直接读取 Dart 符号语义表，确保其全部输出字符进入实际按需备用链而非缺字方框。
use super::*;
use crate::{Cancellation, Limits, Parameters, RenderRequest, render};
use std::{
    collections::{BTreeSet, HashMap},
    path::PathBuf,
    sync::OnceLock,
};

fn fonts() -> &'static HashMap<String, Arc<Font>> {
    static FONTS: OnceLock<HashMap<String, Arc<Font>>> = OnceLock::new();
    FONTS.get_or_init(|| {
        let directory = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets");
        ["云烟体.ttf"]
            .into_iter()
            .chain(FALLBACK_FONT_NAMES)
            .map(|name| {
                (
                    name.into(),
                    FontBook::load(&std::fs::read(directory.join(name)).unwrap()).unwrap(),
                )
            })
            .collect()
    })
}
fn symbols() -> BTreeSet<char> {
    let source = include_str!("../../../../app/test/latex_symbols_test.dart");
    let table = source
        .split_once("const symbols")
        .unwrap()
        .1
        .split_once("\n};")
        .unwrap()
        .0;
    table
        .lines()
        .filter_map(|line| {
            line.split_once(": '")
                .map(|(_, value)| value.split('\'').next().unwrap())
        })
        .flat_map(str::chars)
        .collect()
}
#[test]
fn every_dart_symbol_resolves_to_real_glyph_and_renders_visible_ink() {
    let symbols = symbols();
    assert!(
        symbols.len() >= 126,
        "the full Dart symbol table must be inspected"
    );
    let text: String = symbols.iter().collect();
    let book = FontBook::with_text_fallbacks(fonts()["云烟体.ttf"].clone(), &text, |name| {
        Ok(fonts().get(name).cloned())
    })
    .unwrap();
    for symbol in symbols {
        let font = book.for_char(symbol);
        assert_ne!(
            font.lookup_glyph_index(symbol),
            0,
            "missing glyph for {symbol}"
        );
        let (_, pixels) = font.rasterize(symbol, 36.);
        assert!(
            pixels.iter().any(|value| *value >= 128),
            "blank glyph for {symbol}"
        );
        let request = RenderRequest {
            text: symbol.to_string(),
            fonts: book.clone(),
            background: None,
            limits: Limits::default(),
            params: Parameters {
                width: Some(180),
                height: Some(150),
                font_size: 36.,
                line_spacing: 50.,
                left_margin: 15.,
                right_margin: 15.,
                top_margin: 15.,
                bottom_margin: 15.,
                font_size_sigma: 0.,
                word_spacing_sigma: 0.,
                line_spacing_sigma: 0.,
                perturb_x_sigma: 0.,
                perturb_y_sigma: 0.,
                perturb_theta_sigma: 0.,
                ink_depth_sigma: 0.,
                strikethrough_probability: 0.,
                preview: false,
                ..Parameters::default()
            },
        };
        let mut ink = false;
        render(&request, &Cancellation::default(), |_, image| {
            ink |= image.pixels().any(|pixel| pixel[0] < 128);
            Ok(())
        })
        .unwrap();
        assert!(ink, "renderer lost scientific symbol {symbol}");
    }
}
#[test]
fn fallback_loading_is_lazy_ordered_and_keeps_selected_primary() {
    let primary = fonts()["云烟体.ttf"].clone();
    let book = FontBook::with_text_fallbacks(
        primary.clone(),
        "abc123 √((a)/(b)) + xₙ² + (AB)⃗",
        |_| panic!("covered text must not load any fallback"),
    )
    .unwrap();
    assert!(Arc::ptr_eq(&book.fonts[0], &primary));
    assert_eq!(book.fonts.len(), 1);
    let rare = symbols()
        .into_iter()
        .find(|symbol| {
            primary.lookup_glyph_index(*symbol) == 0
                && FALLBACK_FONT_NAMES[..3]
                    .iter()
                    .all(|name| !visible_glyph(&fonts()[*name], *symbol))
        })
        .expect("fixture must exercise the final fallback");
    let mut loaded = vec![];
    let book = FontBook::with_text_fallbacks(primary.clone(), &rare.to_string(), |name| {
        loaded.push(name.to_owned());
        Ok(fonts().get(name).cloned())
    })
    .unwrap();
    assert_eq!(loaded, FALLBACK_FONT_NAMES);
    assert!(Arc::ptr_eq(&book.fonts[0], &primary));
    assert_ne!(book.for_char(rare).lookup_glyph_index(rare), 0);
}
