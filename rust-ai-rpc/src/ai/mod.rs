//! ai/mod.rs
//!
//! AIManager：
//! - 从 Request 解析模型配置
//! - 创建 Provider
//! - 构造 ChatRequest
//! - 调用 Provider.chat

pub mod provider;
pub mod providers;

use crate::ai::provider::{AIChunk, AIError, AIProvider, ChatRequest, Message, ProviderConfig};
use crate::ai::providers::{ProviderFactory, ProviderType};
use crate::protocol::request::Request;
use std::sync::Arc;

pub struct AIManager {
    provider: Arc<dyn AIProvider>,
}

impl AIManager {
    /// 从 Request 创建 Provider
    pub fn from_request(req: &Request) -> Result<Self, AIError> {
        let model_config = &req.model;

        let provider_type_str = model_config
            .get("api_type")
            .and_then(|v| v.as_str())
            .ok_or_else(|| AIError::InvalidConfig("Missing api_type in model config".into()))?;

        let provider_type = ProviderType::from_str(provider_type_str).ok_or_else(|| {
            AIError::InvalidConfig(format!("Unsupported provider: {}", provider_type_str))
        })?;

        let config = ProviderConfig {
            provider_type: provider_type_str.to_string(),
            api_key: model_config
                .get("api_key")
                .and_then(|v| v.as_str())
                .map(String::from),
            base_url: model_config
                .get("url")
                .and_then(|v| v.as_str())
                .map(String::from),
            host: model_config
                .get("host")
                .and_then(|v| v.as_str())
                .map(String::from),
            port: model_config
                .get("port")
                .and_then(|v| v.as_u64())
                .map(|v| v as u16),
            timeout_seconds: req
                .options
                .as_ref()
                .and_then(|o| o.get("timeout_seconds"))
                .and_then(|v| v.as_u64())
                .unwrap_or(120),
        };

        let provider = ProviderFactory::create(provider_type, &config);
        Ok(Self { provider })
    }

    /// 调用 Provider.chat
    pub async fn chat(
        &self,
        req: &Request,
        on_chunk: impl Fn(AIChunk) + Send + Sync + 'static,
    ) -> Result<String, AIError> {
        let options = req.options.as_ref().and_then(|v| v.as_object());

        let messages: Vec<Message> = req
            .messages
            .iter()
            .map(|m| Message {
                role: m.role.clone(),
                content: m.content.clone(),
            })
            .collect();

        let chat_request = ChatRequest {
            model: req
                .model
                .get("model_name")
                .and_then(|v| v.as_str())
                .unwrap_or("codellama")
                .to_string(),
            messages,
            stream: options
                .and_then(|o| o.get("stream"))
                .and_then(|v| v.as_bool())
                .unwrap_or(true),
            temperature: options
                .and_then(|o| o.get("temperature"))
                .and_then(|v| v.as_f64())
                .map(|v| v as f32),
            max_tokens: options
                .and_then(|o| o.get("max_tokens"))
                .and_then(|v| v.as_u64())
                .map(|v| v as u32),
        };

        let on_chunk_arc = Arc::new(on_chunk);
        let response = self
            .provider
            .chat(&chat_request, Some(on_chunk_arc))
            .await?;
        Ok(response.content)
    }
}
