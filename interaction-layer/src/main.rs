// src/main.rs
use std::io::{self, BufRead, Write};
use std::time::{SystemTime, UNIX_EPOCH};

mod http_client;
mod models;
mod ollama_client;

use models::*;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    // COMMENT:ref:aa334b
    for line in stdin.lock().lines() {
        let line = line?;
        if line.is_empty() {
            continue;
        }

        // 解析请求
        let request: AIRequest = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(e) => {
                send_error(&mut stdout, "", 400, &format!("Invalid JSON: {}", e));
                continue;
            }
        };

        // 发送开始响应
        send_start(&mut stdout, &request.request_id);

        // 根据 api_type 选择客户端
        let result = match request.model.api_type.as_str() {
            "openai" => {
                let mut total_chars = 0;
                let mut duration_ms = 0;

                let send_result = http_client::OpenAIClient::send(&request, &mut |content| {
                    send_chunk(&mut stdout, &request.request_id, content);
                });

                match send_result {
                    Ok((chars, ms)) => {
                        total_chars = chars;
                        duration_ms = ms;
                        Ok((total_chars, duration_ms))
                    }
                    Err(e) => {
                        send_error(&mut stdout, &request.request_id, 500, &e.to_string());
                        Err(e)
                    }
                }
            }
            "ollama" => {
                let mut total_chars = 0;
                let mut duration_ms = 0;

                let send_result = ollama_client::OllamaClient::send(&request, &mut |content| {
                    send_chunk(&mut stdout, &request.request_id, content);
                });

                match send_result {
                    Ok((chars, ms)) => {
                        total_chars = chars;
                        duration_ms = ms;
                        Ok((total_chars, duration_ms))
                    }
                    Err(e) => {
                        send_error(&mut stdout, &request.request_id, 500, &e.to_string());
                        Err(e)
                    }
                }
            }
            _ => {
                send_error(
                    &mut stdout,
                    &request.request_id,
                    400,
                    &format!("Unsupported API type: {}", request.model.api_type),
                );
                Err(anyhow::anyhow!("Unsupported API type"))
            }
        };

        // 发送完成响应
        match result {
            Ok((total_chars, duration_ms)) => {
                send_complete(&mut stdout, &request.request_id, total_chars, duration_ms);
            }
            Err(_) => {
                // 错误已经在上面发送过了
            }
        }
    }

    Ok(())
}

fn send_start(stdout: &mut impl Write, request_id: &str) {
    let response = AIResponse::Start {
        request_id: request_id.to_string(),
        timestamp: SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs(),
    };
    writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).unwrap();
    stdout.flush().unwrap();
}

fn send_chunk(stdout: &mut impl Write, request_id: &str, content: &str) {
    let response = AIResponse::Chunk {
        request_id: request_id.to_string(),
        content: content.to_string(),
    };
    writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).unwrap();
    stdout.flush().unwrap();
}

fn send_complete(stdout: &mut impl Write, request_id: &str, total_chars: usize, duration_ms: u64) {
    let response = AIResponse::Complete {
        request_id: request_id.to_string(),
        total_chars,
        duration_ms,
    };
    writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).unwrap();
    stdout.flush().unwrap();
}

fn send_error(stdout: &mut impl Write, request_id: &str, code: u16, message: &str) {
    let response = AIResponse::Error {
        request_id: request_id.to_string(),
        code,
        message: message.to_string(),
    };
    writeln!(stdout, "{}", serde_json::to_string(&response).unwrap()).unwrap();
    stdout.flush().unwrap();
}