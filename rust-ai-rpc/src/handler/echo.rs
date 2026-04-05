//! handler/echo.rs
//!
//! 简单的 echo handler，用于测试 RPC 通路是否正常。

use crate::protocol::request::Request;

pub fn handle_echo(req: &Request) -> String {
    let mut last_user = None;

    for msg in &req.messages {
        if msg.role == "user" {
            last_user = Some(msg.content.clone());
        }
    }

    match last_user {
        Some(text) => format!("你刚才说了：{}", text),
        None => "没有找到用户输入".into(),
    }
}
