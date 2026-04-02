// File: /Users/lijia/todo2/rust-ai-rpc/src/main.rs
use std::io::{self, BufRead, Write};
use std::time::{Duration, Instant};

mod handler;
mod protocol;

use handler::echo::handle_echo;
use protocol::action_type::ActionType;
use protocol::error::ErrorResponse;
use protocol::request::Request;
use protocol::response::{ChunkResponse, CompleteResponse};

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::stdout();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => continue,
        };

        eprintln!("{} {}: {:?}", "🪚", "line", line);

        if line.trim().is_empty() {
            continue;
        }

        // 先尝试解析 JSON 获取 request_id（用于错误响应）
        let temp_req: Result<Request, _> = serde_json::from_str(&line);

        // 解析 JSON → Request
        let req: Request = match temp_req {
            Ok(r) => r,
            Err(e) => {
                // 尝试提取 request_id（如果 JSON 部分有效）
                let request_id =
                    if let Ok(json_value) = serde_json::from_str::<serde_json::Value>(&line) {
                        json_value
                            .get("request_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("unknown")
                            .to_string()
                    } else {
                        "unknown".to_string()
                    };

                let err = ErrorResponse {
                    request_id,
                    status: "error".into(),
                    message: format!("JSON parse error: {}", e),
                    code: Some("PARSE_ERROR".into()),
                };
                let json = serde_json::to_string(&err).unwrap();
                eprintln!("{} Sending error: {}", "🪚", json);
                let _ = writeln!(stdout, "{}", json);
                let _ = stdout.flush();
                continue;
            }
        };

        eprintln!("{} {}: {:?}", "🪚", "req", req);
        let req_id = req.request_id.clone();
        let start_time = Instant::now();

        // 根据 action_type 分发 handler
        let action = ActionType::from(req.action_type.clone());

        let reply = match action {
            ActionType::Feature => handle_echo(&req),
            ActionType::BugFix => handle_echo(&req),
            ActionType::Refactor => handle_echo(&req),
            ActionType::Signature => handle_echo(&req),
            ActionType::Diagnostic => handle_echo(&req),
            ActionType::Summarize => handle_echo(&req),
            ActionType::Verify => handle_echo(&req),
            ActionType::Patch => handle_echo(&req),
            ActionType::Comment => handle_echo(&req),
            ActionType::Test => handle_echo(&req),
            ActionType::Completion => handle_echo(&req),
            ActionType::Unknown => "未知 action_type".into(),
        };

        eprintln!("{} Generated reply: {}", "🪚", reply);

        // 模拟流式输出（分块发送）
        let chunk_size = 10; // 每10个字符发送一次
        let chars: Vec<char> = reply.chars().collect();
        let mut accumulated = String::new();

        for (i, chunk) in chars.chunks(chunk_size).enumerate() {
            let chunk_str: String = chunk.iter().collect();
            accumulated.push_str(&chunk_str);

            // 发送 chunk
            let chunk_resp = ChunkResponse {
                request_id: req_id.clone(),
                status: "chunk".into(),
                content: chunk_str,
            };
            let json = serde_json::to_string(&chunk_resp).unwrap();
            eprintln!("{} Sending chunk {}: {}", "🪚", i, json);
            let _ = writeln!(stdout, "{}", json);
            let _ = stdout.flush(); // 强制立即刷新

            // 模拟生成延迟（实际 AI 调用时会有自然延迟）
            std::thread::sleep(Duration::from_millis(50));
        }

        // 计算耗时
        let duration = start_time.elapsed();

        // 从请求中提取可能的 patch 信息
        let (start_line, end_line, signature_text) = extract_patch_info(&req);

        // 发送 complete
        let complete = CompleteResponse {
            request_id: req_id.clone(),
            status: "complete".into(),
            content: reply,
            total_chars: accumulated.len(),
            duration_ms: duration.as_millis() as u64,
            start_line,
            end_line,
            signature_text,
        };
        let json = serde_json::to_string(&complete).unwrap();
        eprintln!("{} Sending complete: {}", "🪚", json);
        let _ = writeln!(stdout, "{}", json);
        let _ = stdout.flush(); // 强制立即刷新

        eprintln!("{} Done processing request", "🪚");
    }
}

// 辅助函数：从请求中提取 patch 信息
fn extract_patch_info(req: &Request) -> (Option<usize>, Option<usize>, Option<String>) {
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
