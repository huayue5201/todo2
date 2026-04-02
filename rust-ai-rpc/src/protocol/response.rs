// File: /Users/lijia/todo2/rust-ai-rpc/src/protocol/response.rs
use serde::Serialize;

#[derive(Serialize)]
pub struct ChunkResponse {
    pub request_id: String,
    pub status: String, // "chunk"
    pub content: String,
}

#[derive(Serialize)]
pub struct CompleteResponse {
    pub request_id: String,
    pub status: String, // "complete"
    pub content: String,
    pub total_chars: usize,
    pub duration_ms: u64,
    // 可选字段，用于 patch 操作
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start_line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end_line: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature_text: Option<String>,
}

#[derive(Serialize)]
pub struct ErrorResponse {
    pub request_id: String,
    pub status: String, // "error"
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
}
