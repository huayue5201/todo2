//! provider.rs
//!
//! 定义：
//! - ChatRequest / ChatResponse
//! - AIChunk（流式块）
//! - AIError（统一错误类型）
//! - AIProvider trait（所有模型的统一接口）

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct ChatRequest {
    pub model: String,
    pub messages: Vec<Message>,
    pub stream: bool,
    pub temperature: Option<f32>,
    pub max_tokens: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct ChatResponse {
    pub content: String,
}

/// 流式输出块
#[derive(Debug, Clone)]
pub enum AIChunk {
    Text(String),
    Done,
}

/// 统一错误类型
#[derive(Debug)]
pub enum AIError {
    Network(String),
    Provider(String),
    Parse(String),
    Timeout,
    InvalidConfig(String),
}

impl fmt::Display for AIError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            AIError::Network(e) => write!(f, "Network error: {}", e),
            AIError::Provider(e) => write!(f, "Provider error: {}", e),
            AIError::Parse(e) => write!(f, "Parse error: {}", e),
            AIError::Timeout => write!(f, "Timeout"),
            AIError::InvalidConfig(e) => write!(f, "Invalid config: {}", e),
        }
    }
}

impl std::error::Error for AIError {}

/// 所有模型 Provider 必须实现的接口
#[async_trait]
pub trait AIProvider: Send + Sync {
    async fn chat(
        &self,
        request: &ChatRequest,
        on_chunk: Option<Arc<dyn Fn(AIChunk) + Send + Sync>>,
    ) -> Result<ChatResponse, AIError>;

    fn name(&self) -> &str;
}

/// Provider 配置
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    pub provider_type: String,
    pub api_key: Option<String>,
    pub base_url: Option<String>,
    pub host: Option<String>,
    pub port: Option<u16>,
    pub timeout_seconds: u64,
}
