//! 2026-10-15：跨学科可复查 PNG、PDF、ZIP 图集；输入是转换后的结构文本，不宣称支持完整 TeX。
#[path = "support/curriculum.rs"]
mod curriculum;
use handwriting_core::{Cancellation, export, render};
use std::{env, fs, io::Cursor, path::PathBuf};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: curriculum_gallery FONT_DIR OUTPUT_DIR".into());
    }
    let fonts = curriculum::fonts(&PathBuf::from(&args[1]));
    let output = PathBuf::from(&args[2]);
    fs::create_dir_all(&output)?;
    let mut pdf = export::PdfExport::new();
    let mut zip = export::ZipExport::new(Cursor::new(Vec::new()));
    let mut records =
        String::from("subject\tcase\tsize\twidth\tgrid\tpage\tfile\tink\twithin_margins\n");
    let mut index = 0;
    for (subject, name, text) in curriculum::CASES {
        for (size, width, grid) in [(20., 480, false), (36., 220, false), (48., 220, true)] {
            render(
                &curriculum::request(text, &fonts, size, width, grid),
                &Cancellation::default(),
                |page, image| {
                    let file = format!(
                        "{subject}-{name}-{}-{}-{}.png",
                        size as u32,
                        if grid { "grid" } else { "plain" },
                        page + 1
                    );
                    let mut ink = 0;
                    for (x, y, p) in image.enumerate_pixels() {
                        if p[0] < 128 {
                            ink += 1;
                            assert!(
                                x >= 18 && y >= 18 && x < width - 18 && y < 342,
                                "{file}: clipped ink"
                            );
                        }
                    }
                    assert!(ink > 20, "{file}: empty formula");
                    fs::write(output.join(&file), export::png(&image)?).unwrap();
                    pdf.add(&image)?;
                    zip.add(index, &image)?;
                    index += 1;
                    records.push_str(&format!(
                        "{subject}\t{name}\t{size}\t{width}\t{grid}\t{}\t{file}\t{ink}\ttrue\n",
                        page + 1
                    ));
                    Ok(())
                },
            )?;
        }
    }
    fs::write(output.join("curriculum.pdf"), pdf.finish())?;
    fs::write(output.join("curriculum.zip"), zip.finish()?.into_inner())?;
    fs::write(output.join("metrics.tsv"), records)?;
    println!("Generated {index} curriculum pages");
    Ok(())
}
