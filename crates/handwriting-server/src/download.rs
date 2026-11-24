//! 已完成任务的 HTTP 下载与响应体流。
use crate::{ApiResult, Server, storage_error, tasks::DownloadLease};
use axum::{
    body::Body,
    extract::{Path, State},
    http::HeaderValue,
    response::{IntoResponse, Response},
};
use futures_util::Stream;
use handwriting_core::Error;
use std::{
    pin::Pin,
    task::{Context, Poll},
};
use tokio::io::AsyncRead;
use tokio_util::io::ReaderStream;

struct Download<R> {
    reader: ReaderStream<R>,
    _lease: DownloadLease,
}
impl<R: AsyncRead + Unpin> Stream for Download<R> {
    type Item = std::result::Result<axum::body::Bytes, std::io::Error>;
    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        Pin::new(&mut self.get_mut().reader).poll_next(cx)
    }
}
pub(super) async fn result(State(s): State<Server>, Path(id): Path<String>) -> ApiResult<Response> {
    let (task, lease) = s.0.store.lock().unwrap().lease_result(&id)?;
    let file = tokio::fs::File::open(
        task.result_file
            .ok_or_else(|| Error::new("storage_failed", "结果文件缺失"))?,
    )
    .await
    .map_err(storage_error)?;
    let mut response = Body::from_stream(Download {
        reader: ReaderStream::new(file),
        _lease: lease,
    })
    .into_response();
    response.headers_mut().insert(
        "content-type",
        HeaderValue::from_str(
            task.content_type
                .as_deref()
                .unwrap_or("application/octet-stream"),
        )
        .unwrap(),
    );
    if let Some(name) = task.filename {
        response.headers_mut().insert(
            "content-disposition",
            HeaderValue::from_str(&format!("attachment; filename={name}")).unwrap(),
        );
    }
    Ok(response)
}
