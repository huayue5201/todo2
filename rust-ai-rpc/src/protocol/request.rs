//! protocol/request.rs
//!
//! 定义从 Neovim / Lua 侧传入的请求结构。
//! 这是整个 RPC 的输入格式。

use serde::Deserialize;

#[derive(Deserialize, Debug)]
pub struct Message {
    pub role: String, // "user" / "assistant" / "system"
    pub content: String,
}

#[derive(Deserialize, Debug)]
pub struct Request {
    pub request_id: String, // 必填：用于路由 chunk/complete

    pub task_id: Option<String>,     // 可选：todo2 任务 ID
    pub action_type: Option<String>, // echo / feature / patch / ...

    pub model: serde_json::Value,           // 模型配置（动态 JSON）
    pub messages: Vec<Message>,             // 对话消息
    pub options: Option<serde_json::Value>, // 额外选项（stream / temperature / ...）
}
