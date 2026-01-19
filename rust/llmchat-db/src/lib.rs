mod backend;
mod crypto;
mod db;
mod error;
mod migrations;
mod models;
mod schema;
mod traits;

pub use crate::backend::sqlite::SqliteBackend;
pub use crate::db::ChatDb;
pub use crate::error::{Error, Result};
pub use crate::models::{Attachment, EntityType, Message, Sender, Session};
pub use crate::traits::{
    AttachmentStore, Clock, FileMetaStore, FsAttachmentStore, MetaStore, RandomUuidGen,
    SystemClock, UuidGen,
};
