//! main.rs
//!
//! 负责：
//! - 从 stdin 读取 JSON 请求
//! - 调用 handler 分发 action_type
//! - 处理流式 chunk 输出（必须是纯字符串）
//! - 输出 complete / error 响应
//!
//! 注意：
//! - stdout 使用 tokio::sync::Mutex 保证并发安全
//! - AIChunk::Text → 转换成纯字符串再输出
//! - Lua 侧只接受字符串 chunk

use std::io::{self, BufRead};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use tokio::io::{AsyncWriteExt, stdout};
use tokio::sync::Mutex as AsyncMutex;

mod ai;
mod handler;
mod protocol;

use ai::provider::AIChunk;

lazy_static::lazy_static! {
    /// 全局 stdout，避免多线程写冲突
    static ref STDOUT: AsyncMutex<tokio::io::Stdout> = AsyncMutex::new(stdout());
}

#[tokio::main]
async fn main() {
    let stdin = io::stdin();
    let lines = stdin.lock().lines();

    for line in lines {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                eprintln!("Read error: {}", e);
                continue;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        eprintln!("🪚 Received: {}", line);

        // 解析 JSON → Request
        let req: protocol::request::Request = match serde_json::from_str(&line) {
            Ok(r) => r,
            Err(e) => {
                send_error("unknown", &format!("JSON parse error: {}", e)).await;
                continue;
            }
        };

        let req_id = req.request_id.clone();
        let start_time = Instant::now();

        // 用于统计总字符数
        let full_content = Arc::new(Mutex::new(String::new()));
        let full_content_for_len = full_content.clone();
        let req_id_for_chunk = req_id.clone();

        // ⭐ chunk 回调（必须输出纯字符串）
        let on_chunk = move |chunk: AIChunk| {
            match chunk {
                AIChunk::Text(text) => {
                    // 记录总内容
                    {
                        let mut guard = full_content.lock().unwrap();
                        guard.push_str(&text);
                    }

                    // 构造 chunk 响应（content 必须是纯字符串）
                    let chunk_resp = protocol::response::ChunkResponse {
                        request_id: req_id_for_chunk.clone(),
                        status: "chunk".to_string(),
                        content: text,
                    };

                    let json = serde_json::to_string(&chunk_resp).unwrap();

                    // 异步写 stdout
                    tokio::spawn(async move {
                        let mut out = STDOUT.lock().await;
                        let _ = out.write_all(json.as_bytes()).await;
                        let _ = out.write_all(b"\n").await;
                        let _ = out.flush().await;
                    });
                }

                // Done 不需要发给 Lua
                AIChunk::Done => {}
            }
        };

        // 调用 handler
        let result = handler::handle_request(&req, on_chunk).await;

        match result {
            Ok(content) => {
                let duration = start_time.elapsed();
                let total_chars = {
                    let guard = full_content_for_len.lock().unwrap();
                    guard.len()
                };

                let (start_line, end_line, signature_text) = extract_patch_info(&req);

                let complete = protocol::response::CompleteResponse {
                    request_id: req_id,
                    status: "complete".to_string(),
                    content,
                    total_chars,
                    duration_ms: duration.as_millis() as u64,
                    start_line,
                    end_line,
                    signature_text,
                };

                send_response(&complete).await;
            }

            Err(e) => {
                eprintln!("🪚 Error: {}", e);
                send_error(&req_id, &e).await;
            }
        }
    }
}

/// 提取 patch 信息（可选字段）
fn extract_patch_info(
    req: &protocol::request::Request,
) -> (Option<usize>, Option<usize>, Option<String>) {
    let mut start_line = None;
    let mut end_line = None;
    let mut signature_text = None;

    if let Some(options) = &req.options {
        if let Some(start) = options.get("start_line") {
            start_line = start.as_u64().map(|v| v as usize);
        }
        if let Some(end) = options.get("end_line") {
            end_line = end.as_u64().map(|v| v as usize);
        }
        if let Some(sig) = options.get("signature_text") {
            signature_text = sig.as_str().map(String::from);
        }
    }

    (start_line, end_line, signature_text)
}

/// 输出 JSON 响应
async fn send_response<T: serde::Serialize>(resp: &T) {
    let json = serde_json::to_string(resp).unwrap();
    let mut out = STDOUT.lock().await;
    let _ = out.write_all(json.as_bytes()).await;
    let _ = out.write_all(b"\n").await;
    let _ = out.flush().await;
}

/// 输出错误
async fn send_error(request_id: &str, message: &str) {
    let err = protocol::response::ErrorResponse {
        request_id: request_id.to_string(),
        status: "error".to_string(),
        message: message.to_string(),
        code: Some("AI_ERROR".to_string()),
    };
    send_response(&err).await;
}
