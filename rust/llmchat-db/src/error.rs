use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("sqlite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("crypto error: {0}")]
    Crypto(#[from] ente_core::crypto::CryptoError),
    #[error("serde json error: {0}")]
    SerdeJson(#[from] serde_json::Error),
    #[error("uuid error: {0}")]
    Uuid(#[from] uuid::Error),
    #[error("utf8 error: {0}")]
    Utf8(#[from] std::string::FromUtf8Error),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid encrypted blob length: {len}")]
    InvalidBlobLength { len: usize },
    #[error("invalid encrypted name format")]
    InvalidEncryptedName,
    #[error("invalid sender: {0}")]
    InvalidSender(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("attachment not found: {0}")]
    AttachmentNotFound(String),
    #[error("unsupported schema version: {0}")]
    UnsupportedSchema(i32),
    #[error("invalid key length: expected {expected}, got {actual}")]
    InvalidKeyLength { expected: usize, actual: usize },
    #[error("database lock poisoned")]
    LockPoisoned,
}

pub type Result<T> = std::result::Result<T, Error>;
