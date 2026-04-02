// File: /Users/lijia/todo2/rust-ai-rpc/src/protocol/action_type.rs
use serde::Deserialize;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActionType {
    Feature,
    BugFix,
    Refactor,
    Signature,
    Diagnostic,
    Summarize,
    Verify,
    // 新增类型
    Patch,
    Comment,
    Test,
    Completion,
    Unknown,
}

impl From<Option<String>> for ActionType {
    fn from(s: Option<String>) -> Self {
        match s.as_deref() {
            Some("feature") => ActionType::Feature,
            Some("bug_fix") => ActionType::BugFix,
            Some("refactor") => ActionType::Refactor,
            Some("signature") => ActionType::Signature,
            Some("diagnostic") => ActionType::Diagnostic,
            Some("summarize") => ActionType::Summarize,
            Some("verify") => ActionType::Verify,
            Some("patch") => ActionType::Patch,
            Some("comment") => ActionType::Comment,
            Some("test") => ActionType::Test,
            Some("completion") => ActionType::Completion,
            _ => ActionType::Unknown,
        }
    }
}
