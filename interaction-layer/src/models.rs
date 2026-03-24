// src/models.rs
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AIRequest {
    pub request_id: String,
    pub model: ModelConfig,
    pub messages: Vec<Message>,
    pub options: RequestOptions,
    pub context: Option<RequestContext>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    pub name: String,
    pub api_type: String, // "openai", "anthropic", "ollama"
    pub api_key: String,
    pub url: String,
    pub model_name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestOptions {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<u32>,
    pub stream: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestContext {
    pub task_id: String,
    pub file_path: String,
    pub start_line: u32,
    pub end_line: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "status")]
pub enum AIResponse {
    #[serde(rename = "start")]
    Start { request_id: String, timestamp: u64 },
    #[serde(rename = "chunk")]
    Chunk { request_id: String, content: String },
    #[serde(rename = "complete")]
    Complete {
        request_id: String,
        total_chars: usize,
        duration_ms: u64,
    },
    #[serde(rename = "error")]
    Error {
        request_id: String,
        code: u16,
        message: String,
    },
}
