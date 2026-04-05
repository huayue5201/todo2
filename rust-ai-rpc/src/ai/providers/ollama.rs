//! providers/ollama.rs
//!
//! 实现 OllamaProvider：
//! - POST /api/chat
//! - 支持流式输出
//! - 按行解析 JSON
//! - 输出 AIChunk

use crate::ai::provider::{
    AIChunk, AIError, AIProvider, ChatRequest, ChatResponse, ProviderConfig,
};
use async_trait::async_trait;
use futures_util::StreamExt;
use reqwest::Client;
use serde_json::json;
use std::sync::Arc;
use tokio::time::Duration;

pub struct OllamaProvider {
    client: Client,
    base_url: String,
}

impl OllamaProvider {
    pub fn new(config: &ProviderConfig) -> Self {
        let host = config.host.as_deref().unwrap_or("http://127.0.0.1");
        let port = config.port.unwrap_or(11434);

        let base_url = if let Some(url) = &config.base_url {
            url.clone()
        } else {
            format!("{}:{}", host, port)
        };

        Self {
            client: Client::builder()
                .timeout(Duration::from_secs(config.timeout_seconds))
                .build()
                .expect("Failed to create HTTP client"),
            base_url,
        }
    }
}

#[async_trait]
impl AIProvider for OllamaProvider {
    async fn chat(
        &self,
        request: &ChatRequest,
        on_chunk: Option<Arc<dyn Fn(AIChunk) + Send + Sync>>,
    ) -> Result<ChatResponse, AIError> {
        let url = format!("{}/api/chat", self.base_url);
        let mut full_content = String::new();

        let messages: Vec<_> = request
            .messages
            .iter()
            .map(|m| json!({ "role": m.role, "content": m.content }))
            .collect();

        let body = json!({
            "model": request.model,
            "messages": messages,
            "stream": request.stream,
            "options": {
                "temperature": request.temperature.unwrap_or(0.2),
                "num_predict": request.max_tokens.unwrap_or(2048),
            }
        });

        let response = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await
            .map_err(|e| AIError::Network(e.to_string()))?;

        if request.stream {
            let mut stream = response.bytes_stream();

            while let Some(chunk_result) = stream.next().await {
                let chunk = chunk_result.map_err(|e| AIError::Network(e.to_string()))?;
                let text = String::from_utf8_lossy(&chunk);

                for line in text.split('\n') {
                    let line = line.trim();
                    if line.is_empty() {
                        continue;
                    }

                    let val: serde_json::Value =
                        serde_json::from_str(line).map_err(|e| AIError::Parse(e.to_string()))?;

                    if let Some(content) = val
                        .get("message")
                        .and_then(|m| m.get("content"))
                        .and_then(|c| c.as_str())
                    {
                        if !content.is_empty() {
                            full_content.push_str(content);
                            if let Some(cb) = &on_chunk {
                                cb(AIChunk::Text(content.to_string()));
                            }
                        }
                    }

                    if val.get("done").and_then(|v| v.as_bool()) == Some(true) {
                        if let Some(cb) = &on_chunk {
                            cb(AIChunk::Done);
                        }
                    }
                }
            }
        } else {
            let data: serde_json::Value = response
                .json()
                .await
                .map_err(|e| AIError::Parse(e.to_string()))?;
            if let Some(content) = data
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
            {
                full_content = content.to_string();
            }
        }

        Ok(ChatResponse {
            content: full_content,
        })
    }

    fn name(&self) -> &str {
        "ollama"
    }
}
