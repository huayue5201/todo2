// src/ollama_client.rs
use crate::models::AIRequest;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub struct OllamaClient;

impl OllamaClient {
    pub fn send(request: &AIRequest, on_chunk: &mut dyn FnMut(&str)) -> Result<(usize, u64)> {
        let start_time = std::time::Instant::now();
        let mut total_chars = 0;

        // 构建 Ollama 请求体
        let messages: Vec<Value> = request
            .messages
            .iter()
            .map(|msg| {
                json!({
                    "role": msg.role,
                    "content": msg.content
                })
            })
            .collect();

        let body = json!({
            "model": request.model.model_name,
            "messages": messages,
            "stream": request.options.stream,
        });

        let client = reqwest::blocking::Client::new();
        let response = client.post(&request.model.url).json(&body).send()?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text()?;
            return Err(anyhow!("HTTP {}: {}", status, text));
        }

        if request.options.stream {
            let text = response.text()?;
            for line in text.lines() {
                if line.is_empty() {
                    continue;
                }

                if let Ok(value) = serde_json::from_str::<Value>(line) {
                    if let Some(content) = value["message"]["content"].as_str() {
                        total_chars += content.len();
                        on_chunk(content);
                    }
                }
            }
        } else {
            let json: Value = response.json()?;
            if let Some(content) = json["message"]["content"].as_str() {
                total_chars += content.len();
                on_chunk(content);
            }
        }

        let duration_ms = start_time.elapsed().as_millis() as u64;
        Ok((total_chars, duration_ms))
    }
}
