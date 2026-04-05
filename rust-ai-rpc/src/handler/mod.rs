//! handler/mod.rs
//!
//! 根据 action_type 分发请求。
//! 所有 handler 都统一使用 Fn(AIChunk) 回调。

pub mod ai;
pub mod echo;

use crate::ai::provider::AIChunk;
use crate::protocol::request::Request;

pub async fn handle_request(
    req: &Request,
    on_chunk: impl Fn(AIChunk) + Send + Sync + 'static,
) -> Result<String, String> {
    match req.action_type.as_deref() {
        Some("echo") => Ok(echo::handle_echo(req)),
        _ => ai::handle_ai(req, on_chunk).await,
    }
}
