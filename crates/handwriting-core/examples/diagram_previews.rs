//! 通过生产渲染入口生成 README 的流程图和电路图近景。
use handwriting_core::{Cancellation, FontBook, Limits, Parameters, RenderRequest, render};
use std::{env, fs, path::PathBuf};

const FLOW: &str = r"\begin{circuitikz}
\draw (0,0) -- (3.2,0) -- (3.2,1) -- (0,1) -- cycle;
\draw (13.4,0) -- (16.6,0) -- (16.6,1) -- (13.4,1) -- cycle;
\draw (6.7,-2.6) -- (9.9,-2.6) -- (9.9,-1.6) -- (6.7,-1.6) -- cycle;
\draw[->] (3.2,0.78) -- (13.4,0.78);
\draw[->] (13.4,0.25) -- (3.2,0.25);
\draw[->] (15,0) |- (9.9,-2.1);
\draw[->] (6.7,-2.1) -| (1.6,0);
\draw (1.6,0.5) node{就绪态};
\draw (15,0.5) node{执行态};
\draw (8.3,-2.1) node{阻塞态};
\draw (8.3,1.12) node{进程调度};
\draw (8.3,-0.10) node{时间片到或被抢占};
\draw (12.45,-1.75) node{等待事件};
\draw (4.15,-1.75) node{事件完成};
\end{circuitikz}";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out = PathBuf::from(
        env::args_os()
            .nth(1)
            .ok_or("usage: diagram_previews OUTPUT_DIR")?,
    );
    fs::create_dir_all(&out)?;
    let fixtures: Vec<serde_json::Value> =
        serde_json::from_str(include_str!("../tests/fixtures/realistic-circuits.json"))?;
    let rc = fixtures
        .iter()
        .find(|case| case["id"] == "loaded-rc-ladder")
        .and_then(|case| case["source"].as_str())
        .ok_or("missing RC fixture")?;
    let font =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../assets/font_assets/云烟体.ttf");
    let fonts = FontBook::new(&fs::read(font)?, &[])?;
    for (name, source) in [("process-states", FLOW), ("rc-ladder", rc)] {
        assert!(handwriting_core::text::circuit::parse(source).is_some());
        let request = RenderRequest {
            text: source.into(),
            fonts: fonts.clone(),
            background: None,
            limits: Limits::default(),
            params: Parameters {
                width: Some(1650),
                height: Some(640),
                font_size: 52.,
                line_spacing: 66.,
                left_margin: 20.,
                right_margin: 20.,
                top_margin: 16.,
                bottom_margin: 16.,
                font_size_sigma: 0.,
                ink_depth_sigma: 0.,
                strikethrough_probability: 0.,
                background_ruled: true,
                preview: false,
                seed: 20261123,
                ..Parameters::default()
            },
        };
        render(&request, &Cancellation::default(), |_, image| {
            let mut bounds = (image.width(), image.height(), 0, 0);
            for (x, y, _) in image.enumerate_pixels().filter(|(_, _, p)| p[0] < 245) {
                bounds = (
                    bounds.0.min(x),
                    bounds.1.min(y),
                    bounds.2.max(x),
                    bounds.3.max(y),
                );
            }
            let (x, y, right, bottom) = bounds;
            if right < x || bottom < y {
                return Err(handwriting_core::Error::new("empty_preview", name));
            }
            let left = x.saturating_sub(12);
            let top = y.saturating_sub(12);
            let width = (right + 13).min(image.width()) - left;
            let height = (bottom + 13).min(image.height()) - top;
            let crop = image::imageops::crop_imm(&image, left, top, width, height);
            crop.to_image()
                .save(out.join(format!("{name}.webp")))
                .map_err(|e| handwriting_core::Error::new("write_preview", e.to_string()))?;
            Ok(())
        })?;
    }
    Ok(())
}
