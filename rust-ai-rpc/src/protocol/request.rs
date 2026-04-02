use serde::Deserialize;

#[derive(Deserialize, Debug)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Deserialize, Debug)]
pub struct Request {
    pub request_id: String,

    pub task_id: Option<String>,
    pub action_type: Option<String>,

    pub model: serde_json::Value,

    // ⭐ 改成 Vec<Message>
    pub messages: Vec<Message>,

    pub options: Option<serde_json::Value>,
}
