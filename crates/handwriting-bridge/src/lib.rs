//! 2026-10-12：移动端 C ABI。JSON 仅传参数、状态和路径，图片不经过 FFI 字符串。
pub mod api;
use std::ffi::{CStr, CString, c_char};

/// # Safety
/// `input` 必须是有效、以 NUL 结尾的 UTF-8 字符串；返回指针由 free 释放一次。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn handwriting_bridge_call(input: *const c_char) -> *mut c_char {
    let outcome = std::panic::catch_unwind(|| {
        if input.is_null() {
            return Err(handwriting_core::Error::new("invalid_request", "空请求"));
        }
        let text = unsafe { CStr::from_ptr(input) }
            .to_str()
            .map_err(|e| handwriting_core::Error::new("invalid_request", e.to_string()))?;
        let request = serde_json::from_str(text)
            .map_err(|e| handwriting_core::Error::new("invalid_request", e.to_string()))?;
        api::execute(request)
    });
    let response = match outcome {
        Ok(Ok(value)) => serde_json::json!({"ok":true,"data":value}),
        Ok(Err(error)) => serde_json::json!({"ok":false,"code":error.code,"message":error.message}),
        Err(_) => serde_json::json!({"ok":false,"code":"engine_failed","message":"引擎异常"}),
    };
    CString::new(response.to_string())
        .expect("JSON 不含 NUL")
        .into_raw()
}
/// # Safety
/// `value` 必须是 call 返回的指针，且只能释放一次；NULL 可忽略。
#[unsafe(no_mangle)]
pub unsafe extern "C" fn handwriting_bridge_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests;
