//! providers/mod.rs
//!
//! Provider 工厂：根据 api_type 创建 Provider

pub mod ollama;

use crate::ai::provider::{AIProvider, ProviderConfig};
use ollama::OllamaProvider;
use std::sync::Arc;

pub enum ProviderType {
    Ollama,
}

impl ProviderType {
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "ollama" => Some(Self::Ollama),
            _ => None,
        }
    }
}

pub struct ProviderFactory;

impl ProviderFactory {
    pub fn create(provider_type: ProviderType, config: &ProviderConfig) -> Arc<dyn AIProvider> {
        match provider_type {
            ProviderType::Ollama => Arc::new(OllamaProvider::new(config)),
        }
    }
}
