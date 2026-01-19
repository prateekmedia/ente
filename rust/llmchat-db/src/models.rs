use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub uuid: Uuid,
    pub title: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub remote_id: Option<String>,
    pub needs_sync: bool,
    pub deleted_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub uuid: Uuid,
    pub session_uuid: Uuid,
    pub parent_message_uuid: Option<Uuid>,
    pub sender: Sender,
    pub text: String,
    pub attachments: Vec<Attachment>,
    pub created_at: i64,
    pub deleted_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attachment {
    pub id: String,
    pub kind: String,
    pub size: u64,
    pub name: String,
    pub uploaded_at: Option<i64>,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum Sender {
    SelfUser,
    Other,
}

impl Sender {
    pub fn as_str(&self) -> &'static str {
        match self {
            Sender::SelfUser => "self",
            Sender::Other => "other",
        }
    }
}

impl TryFrom<&str> for Sender {
    type Error = String;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "self" => Ok(Sender::SelfUser),
            "other" => Ok(Sender::Other),
            other => Err(other.to_string()),
        }
    }
}

#[derive(Debug, Copy, Clone, PartialEq, Eq)]
pub enum EntityType {
    Session,
    Message,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct AttachmentJson {
    pub id: String,
    pub kind: String,
    pub size: u64,
    pub encrypted_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(default)]
    pub uploaded_at: Option<i64>,
}
