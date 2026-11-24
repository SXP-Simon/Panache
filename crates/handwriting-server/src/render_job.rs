use crate::{Server, Upload, storage_error};
use base64::{Engine, engine::general_purpose::STANDARD};
use handwriting_core::{
    Cancellation, Error, FontBook, Parameters, RenderRequest, Result,
    generation::{self, Event, Output},
};
use std::{collections::HashMap, fs::File, io::Write, sync::Arc};

impl Server {
    pub(super) fn run(
        &self,
        id: &str,
        fields: HashMap<String, String>,
        files: HashMap<String, Upload>,
        token: Cancellation,
    ) -> Result<()> {
        token.check()?;
        let request = self.render_request(fields, files)?;
        self.update(id, |t| {
            if t.task_status != "processing" {
                return;
            }
            t.task_status = "processing".into();
            t.task_stage = "rendering".into();
            t.task_message = "正在生成手写图像".into();
            t.task_progress = 5;
        })?;
        let format = ResultFormat::for_params(&request.params);
        let (extension, content_type) = format.file_type();
        let path = self
            .0
            .config
            .data_dir
            .join("results")
            .join(format!("{id}.{extension}"));
        let partial = path.with_extension("partial");
        let outcome = (|| {
            let mut output = File::create(&partial).map_err(storage_error)?;
            format.write(&mut output, &request, &token, |event| {
                self.generation_progress(id, event)
            })?;
            token.check()?;
            output.sync_all().map_err(storage_error)?;
            drop(output);
            // 取消与完成提交使用同一锁，避免结果被取消状态覆盖或孤立。
            let mut store = self.0.store.lock().unwrap();
            token.check()?;
            std::fs::rename(&partial, &path).map_err(storage_error)?;
            store.update(id, |t| {
                t.task_status = "completed".into();
                t.task_stage = "completed".into();
                t.task_message = "生成完成".into();
                t.task_progress = 100;
                t.result_file = Some(path.clone());
                t.content_type = Some(content_type.into());
                t.filename = format.attachment().map(str::to_owned);
            })?;
            Ok(())
        })();
        if outcome.is_err() {
            let _ = std::fs::remove_file(&partial);
            let _ = std::fs::remove_file(&path);
        }
        outcome
    }

    fn render_request(
        &self,
        mut fields: HashMap<String, String>,
        mut files: HashMap<String, Upload>,
    ) -> Result<RenderRequest> {
        let mut p = Parameters::from_form(&fields)?;
        if !fields.contains_key("seed") && !p.fine_edit {
            p.seed = u64::from_le_bytes(uuid::Uuid::new_v4().as_bytes()[..8].try_into().unwrap());
        }
        let primary = if let Some(file) = files.get("font_file") {
            FontBook::load(&file.bytes)?
        } else {
            self.font(
                fields
                    .get("font_option")
                    .map(String::as_str)
                    .unwrap_or(&self.0.fonts[0]),
            )?
        };
        let text = fields
            .remove("text")
            .ok_or_else(|| Error::new("invalid_parameter", "缺少 text"))?;
        let fonts = FontBook::with_text_fallbacks(primary, &text, |name| {
            if self.0.fonts.iter().any(|available| available == name) {
                self.font(name).map(Some)
            } else {
                Ok(None)
            }
        })?;
        Ok(RenderRequest {
            text,
            params: p,
            background: files.remove("background_image").map(|f| f.bytes),
            fonts,
            limits: self.0.config.limits.clone(),
        })
    }

    fn font(&self, name: &str) -> Result<Arc<fontdue::Font>> {
        if !self.0.fonts.iter().any(|s| s == name) {
            return Err(Error::new("invalid_font", "字体不存在"));
        }
        let mut cache = self.0.font_cache.lock().unwrap();
        if let Some(font) = cache.get(name) {
            return Ok(font.clone());
        }
        let bytes = std::fs::read(self.0.config.font_dir.join(name)).map_err(storage_error)?;
        let font = FontBook::load(&bytes)?;
        if cache.len() >= 3 {
            cache.clear();
        }
        cache.insert(name.into(), font.clone());
        Ok(font)
    }

    fn generation_progress(&self, id: &str, event: Event) -> Result<()> {
        self.update(id, |t| {
            if t.task_status != "processing" {
                return;
            }
            match event {
                Event::Rendering => {
                    t.task_stage = "rendering".into();
                }
                Event::PageReady(pages) => {
                    t.pages_completed = pages;
                    t.task_progress = (10 + (pages - 1) * 3).min(90) as u8;
                    t.task_message = format!("已生成 {pages} 页");
                }
                Event::Exporting => {
                    t.task_stage = "exporting".into();
                    t.task_message = "正在导出".into();
                }
            }
        })
    }
}

#[derive(Clone, Copy)]
enum ResultFormat {
    Pdf,
    Zip,
    Png,
    Images,
    InkLayers,
}

impl ResultFormat {
    fn for_params(params: &Parameters) -> Self {
        if params.pdf_save {
            Self::Pdf
        } else if !params.preview {
            Self::Zip
        } else if params.ink_layers {
            Self::InkLayers
        } else if params.full_preview {
            Self::Images
        } else {
            Self::Png
        }
    }

    fn file_type(self) -> (&'static str, &'static str) {
        match self {
            Self::Pdf => ("pdf", "application/pdf"),
            Self::Zip => ("zip", "application/zip"),
            Self::Png => ("png", "image/png"),
            Self::Images | Self::InkLayers => ("json", "application/json"),
        }
    }

    fn attachment(self) -> Option<&'static str> {
        match self {
            Self::Pdf => Some("images.pdf"),
            Self::Zip => Some("images.zip"),
            _ => None,
        }
    }

    fn write(
        self,
        output: &mut File,
        request: &RenderRequest,
        token: &Cancellation,
        progress: impl FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        match self {
            Self::Pdf => generation::generate(request, token, Output::Pdf(output), progress),
            Self::Zip => generation::generate(request, token, Output::Zip(output), progress),
            Self::Png => generation::generate(
                request,
                token,
                Output::Preview(&mut |_, bytes| output.write_all(&bytes).map_err(storage_error)),
                progress,
            ),
            Self::Images => {
                output
                    .write_all(b"{\"status\":\"success\",\"images\":[")
                    .map_err(storage_error)?;
                generation::generate(
                    request,
                    token,
                    Output::Preview(&mut |index, bytes| {
                        if index > 0 {
                            output.write_all(b",").map_err(storage_error)?;
                        }
                        output.write_all(b"\"").map_err(storage_error)?;
                        output
                            .write_all(STANDARD.encode(bytes).as_bytes())
                            .map_err(storage_error)?;
                        output.write_all(b"\"").map_err(storage_error)
                    }),
                    progress,
                )?;
                output.write_all(b"]}").map_err(storage_error)
            }
            Self::InkLayers => {
                output
                    .write_all(b"{\"status\":\"success\",\"layers\":[")
                    .map_err(storage_error)?;
                generation::generate(
                    request,
                    token,
                    Output::InkLayers(&mut |index, page| {
                        if index > 0 {
                            output.write_all(b",").map_err(storage_error)?;
                        }
                        serde_json::to_writer(&mut *output, &page).map_err(storage_error)
                    }),
                    progress,
                )?;
                output.write_all(b"]}").map_err(storage_error)
            }
        }
    }
}
