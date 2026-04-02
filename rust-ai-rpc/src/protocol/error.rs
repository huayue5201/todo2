// File: /Users/lijia/todo2/rust-ai-rpc/src/protocol/error.rs
use serde::Serialize;

// 统一的错误响应格式
#[derive(Serialize)]
pub struct ErrorResponse {
    pub request_id: String,
    pub status: String, // "error"
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}
