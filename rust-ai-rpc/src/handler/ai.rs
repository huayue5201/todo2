//! handler/ai.rs
//!
//! 调用 AIManager.chat，并把 AIError 转成 String。

use crate::ai::AIManager;
use crate::ai::provider::AIChunk;
use crate::protocol::request::Request;

pub async fn handle_ai(
    req: &Request,
    on_chunk: impl Fn(AIChunk) + Send + Sync + 'static,
) -> Result<String, String> {
    // 初始化 AIManager（解析模型配置 + 创建 Provider）
    let manager = AIManager::from_request(req).map_err(|e| format!("AI init failed: {}", e))?;

    // 调用 Provider.chat
    manager
        .chat(req, on_chunk)
        .await
        .map_err(|e| format!("AI call failed: {}", e))
}
