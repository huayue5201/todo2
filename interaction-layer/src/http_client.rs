// src/http_client.rs
use crate::models::AIRequest;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

pub struct OpenAIClient;

impl OpenAIClient {
    pub fn send(request: &AIRequest, on_chunk: &mut dyn FnMut(&str)) -> Result<(usize, u64)> {
        let start_time = std::time::Instant::now();
        let mut total_chars = 0;

        // 构建 OpenAI 请求体
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
            "temperature": request.options.temperature.unwrap_or(0.7),
            "max_tokens": request.options.max_tokens.unwrap_or(2000),
        });

        let client = reqwest::blocking::Client::new();
        let response = client
            .post(&request.model.url)
            .header("Authorization", format!("Bearer {}", request.model.api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()?;

        if !response.status().is_success() {
            let status = response.status();
            let text = response.text()?;
            return Err(anyhow!("HTTP {}: {}", status, text));
        }

        if request.options.stream {
            // 流式处理
            let text = response.text()?;
            for line in text.lines() {
                if line.is_empty() {
                    continue;
                }

                if line.starts_with("data: ") {
                    let data = &line[6..];
                    if data == "[DONE]" {
                        break;
                    }

                    if let Ok(value) = serde_json::from_str::<Value>(data) {
                        if let Some(content) = value["choices"][0]["delta"]["content"].as_str() {
                            if !content.is_empty() {
                                total_chars += content.len();
                                on_chunk(content);
                            }
                        }
                    }
                }
            }
        } else {
            // 非流式处理
            let json: Value = response.json()?;
            if let Some(content) = json["choices"][0]["message"]["content"].as_str() {
                total_chars += content.len();
                on_chunk(content);
            }
        }

        let duration_ms = start_time.elapsed().as_millis() as u64;
        Ok((total_chars, duration_ms))
    }
}
