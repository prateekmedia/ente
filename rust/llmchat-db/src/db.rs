use crate::{
    backend::Backend,
    crypto,
    error::{Error, Result},
    migrations,
    models::{Attachment, AttachmentJson, EntityType, Message, Sender, Session},
    traits::{AttachmentStore, Clock, UuidGen},
};
use ente_core::crypto::SecretVec;
use rusqlite::{params, OptionalExtension, Row};
use std::{collections::BTreeSet, sync::Arc};
use uuid::Uuid;

pub struct ChatDb<B: Backend> {
    backend: B,
    key: SecretVec,
    clock: Arc<dyn Clock>,
    uuid_gen: Arc<dyn UuidGen>,
}

impl<B: Backend> ChatDb<B> {
    pub fn new(
        backend: B,
        key: &[u8],
        clock: Arc<dyn Clock>,
        uuid_gen: Arc<dyn UuidGen>,
    ) -> Result<Self> {
        ente_core::crypto::init()?;
        if key.len() != crypto::KEY_BYTES {
            return Err(Error::InvalidKeyLength {
                expected: crypto::KEY_BYTES,
                actual: key.len(),
            });
        }
        backend.with_conn(migrations::run_migrations)?;
        Ok(Self {
            backend,
            key: SecretVec::new(key.to_vec()),
            clock,
            uuid_gen,
        })
    }

    pub fn create_session(&self, title: &str) -> Result<Session> {
        let uuid = self.uuid_gen.new_uuid();
        let now = self.clock.now_us();
        let title_blob = crypto::encrypt_blob_field(title.as_bytes(), &self.key)?;

        self.backend.with_conn(|conn| {
            conn.execute(
                "INSERT INTO sessions (session_uuid, title, created_at, updated_at, needs_sync) VALUES (?, ?, ?, ?, 1)",
                params![uuid.to_string(), title_blob, now, now],
            )?;
            Ok(())
        })?;

        Ok(Session {
            uuid,
            title: title.to_string(),
            created_at: now,
            updated_at: now,
            remote_id: None,
            needs_sync: true,
            deleted_at: None,
        })
    }

    pub fn get_session(&self, uuid: Uuid) -> Result<Option<Session>> {
        self.backend.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT session_uuid, title, created_at, updated_at, remote_id, needs_sync, deleted_at
                 FROM sessions WHERE session_uuid = ? AND deleted_at IS NULL",
            )?;
            let mut rows = stmt.query(params![uuid.to_string()])?;
            if let Some(row) = rows.next()? {
                Ok(Some(self.session_from_row(row)?))
            } else {
                Ok(None)
            }
        })
    }

    pub fn list_sessions(&self) -> Result<Vec<Session>> {
        self.backend.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT session_uuid, title, created_at, updated_at, remote_id, needs_sync, deleted_at
                 FROM sessions WHERE deleted_at IS NULL ORDER BY updated_at DESC",
            )?;
            let mut rows = stmt.query([])?;
            let mut sessions = Vec::new();
            while let Some(row) = rows.next()? {
                sessions.push(self.session_from_row(row)?);
            }
            Ok(sessions)
        })
    }

    pub fn update_session_title(&self, uuid: Uuid, title: &str) -> Result<()> {
        let now = self.clock.now_us();
        let title_blob = crypto::encrypt_blob_field(title.as_bytes(), &self.key)?;
        let rows = self.backend.with_conn(|conn| {
            conn.execute(
                "UPDATE sessions SET title = ?, updated_at = ?, needs_sync = 1
                 WHERE session_uuid = ? AND deleted_at IS NULL",
                params![title_blob, now, uuid.to_string()],
            )
            .map_err(Error::from)
        })?;
        if rows == 0 {
            return Err(Error::NotFound("session".to_string()));
        }
        Ok(())
    }

    pub fn delete_session(&self, uuid: Uuid) -> Result<()> {
        let now = self.clock.now_us();
        self.backend.with_txn(|txn| {
            txn.execute(
                "UPDATE messages SET deleted_at = ? WHERE session_uuid = ? AND deleted_at IS NULL",
                params![now, uuid.to_string()],
            )?;
            let rows = txn.execute(
                "UPDATE sessions SET deleted_at = ?, updated_at = ?, needs_sync = 1
                 WHERE session_uuid = ? AND deleted_at IS NULL",
                params![now, now, uuid.to_string()],
            )?;
            if rows == 0 {
                return Err(Error::NotFound("session".to_string()));
            }
            Ok(())
        })
    }

    pub fn get_sessions_needing_sync(&self) -> Result<Vec<Session>> {
        self.backend.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT session_uuid, title, created_at, updated_at, remote_id, needs_sync, deleted_at
                 FROM sessions WHERE needs_sync = 1 AND deleted_at IS NULL ORDER BY updated_at DESC",
            )?;
            let mut rows = stmt.query([])?;
            let mut sessions = Vec::new();
            while let Some(row) = rows.next()? {
                sessions.push(self.session_from_row(row)?);
            }
            Ok(sessions)
        })
    }

    pub fn insert_message(
        &self,
        session_uuid: Uuid,
        sender: &str,
        text: &str,
        parent: Option<Uuid>,
        attachments: Vec<Attachment>,
    ) -> Result<Message> {
        let sender = Sender::try_from(sender).map_err(Error::InvalidSender)?;
        let uuid = self.uuid_gen.new_uuid();
        let now = self.clock.now_us();
        let text_blob = crypto::encrypt_blob_field(text.as_bytes(), &self.key)?;
        let attachments_json = self.attachments_to_json(&attachments)?;

        self.backend.with_txn(|txn| {
            txn.execute(
                "INSERT INTO messages (message_uuid, session_uuid, parent_message_uuid, sender, text, attachments, created_at)
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
                params![
                    uuid.to_string(),
                    session_uuid.to_string(),
                    parent.map(|value| value.to_string()),
                    sender.as_str(),
                    text_blob,
                    attachments_json,
                    now
                ],
            )?;
            txn.execute(
                "UPDATE sessions SET updated_at = ?, needs_sync = 1
                 WHERE session_uuid = ? AND deleted_at IS NULL",
                params![now, session_uuid.to_string()],
            )?;
            Ok(())
        })?;

        Ok(Message {
            uuid,
            session_uuid,
            parent_message_uuid: parent,
            sender,
            text: text.to_string(),
            attachments,
            created_at: now,
            deleted_at: None,
        })
    }

    pub fn get_messages(&self, session_uuid: Uuid) -> Result<Vec<Message>> {
        self.backend.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT message_uuid, session_uuid, parent_message_uuid, sender, text, attachments, created_at, deleted_at
                 FROM messages WHERE session_uuid = ? AND deleted_at IS NULL
                 ORDER BY created_at ASC, message_uuid ASC",
            )?;
            let mut rows = stmt.query(params![session_uuid.to_string()])?;
            let mut messages = Vec::new();
            while let Some(row) = rows.next()? {
                messages.push(self.message_from_row(row)?);
            }
            Ok(messages)
        })
    }

    pub fn update_message_text(&self, uuid: Uuid, text: &str) -> Result<()> {
        let now = self.clock.now_us();
        let text_blob = crypto::encrypt_blob_field(text.as_bytes(), &self.key)?;
        self.backend.with_txn(|txn| {
            let rows = txn.execute(
                "UPDATE messages SET text = ? WHERE message_uuid = ? AND deleted_at IS NULL",
                params![text_blob, uuid.to_string()],
            )?;
            if rows == 0 {
                return Err(Error::NotFound("message".to_string()));
            }
            txn.execute(
                "UPDATE sessions SET updated_at = ?, needs_sync = 1
                 WHERE session_uuid = (SELECT session_uuid FROM messages WHERE message_uuid = ?)",
                params![now, uuid.to_string()],
            )?;
            Ok(())
        })
    }

    pub fn delete_message(&self, uuid: Uuid) -> Result<()> {
        let now = self.clock.now_us();
        self.backend.with_txn(|txn| {
            let rows = txn.execute(
                "UPDATE messages SET deleted_at = ? WHERE message_uuid = ? AND deleted_at IS NULL",
                params![now, uuid.to_string()],
            )?;
            if rows == 0 {
                return Err(Error::NotFound("message".to_string()));
            }
            txn.execute(
                "UPDATE sessions SET updated_at = ?, needs_sync = 1
                 WHERE session_uuid = (SELECT session_uuid FROM messages WHERE message_uuid = ?)",
                params![now, uuid.to_string()],
            )?;
            Ok(())
        })
    }

    pub fn mark_attachment_uploaded(&self, message_uuid: Uuid, attachment_id: &str) -> Result<()> {
        let now = self.clock.now_us();
        self.backend.with_txn(|txn| {
            let attachments_json: Option<Option<String>> = txn
                .query_row(
                    "SELECT attachments FROM messages WHERE message_uuid = ? AND deleted_at IS NULL",
                    params![message_uuid.to_string()],
                    |row| row.get(0),
                )
                .optional()?;

            let attachments_json = match attachments_json {
                None => return Err(Error::NotFound("message".to_string())),
                Some(None) => return Err(Error::AttachmentNotFound(attachment_id.to_string())),
                Some(Some(json)) => json,
            };

            let mut attachments: Vec<AttachmentJson> = serde_json::from_str(&attachments_json)?;
            let mut found = false;
            for attachment in &mut attachments {
                if attachment.id == attachment_id {
                    attachment.uploaded_at = Some(now);
                    found = true;
                    break;
                }
            }
            if !found {
                return Err(Error::AttachmentNotFound(attachment_id.to_string()));
            }

            let updated_json = if attachments.is_empty() {
                None
            } else {
                Some(serde_json::to_string(&attachments)?)
            };
            txn.execute(
                "UPDATE messages SET attachments = ? WHERE message_uuid = ?",
                params![updated_json, message_uuid.to_string()],
            )?;
            Ok(())
        })
    }

    pub fn get_pending_uploads(&self, session_uuid: Uuid) -> Result<Vec<Attachment>> {
        self.backend.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT attachments FROM messages
                 WHERE session_uuid = ? AND deleted_at IS NULL AND attachments IS NOT NULL",
            )?;
            let mut rows = stmt.query(params![session_uuid.to_string()])?;
            let mut pending = Vec::new();
            while let Some(row) = rows.next()? {
                let json: String = row.get(0)?;
                let attachments: Vec<AttachmentJson> = serde_json::from_str(&json)?;
                for attachment in attachments {
                    if attachment.uploaded_at.is_none() {
                        pending.push(self.attachment_from_json(attachment)?);
                    }
                }
            }
            Ok(pending)
        })
    }

    pub fn list_attachment_ids(&self, include_deleted: bool) -> Result<Vec<String>> {
        self.backend.with_conn(|conn| {
            let mut ids = BTreeSet::new();
            let sql = if include_deleted {
                "SELECT attachments FROM messages WHERE attachments IS NOT NULL"
            } else {
                "SELECT attachments FROM messages WHERE deleted_at IS NULL AND attachments IS NOT NULL"
            };
            let mut stmt = conn.prepare(sql)?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let json: String = row.get(0)?;
                let attachments: Vec<AttachmentJson> = serde_json::from_str(&json)?;
                for attachment in attachments {
                    ids.insert(attachment.id);
                }
            }
            Ok(ids.into_iter().collect())
        })
    }

    pub fn cleanup_orphaned_attachments<S: AttachmentStore>(
        &self,
        store: &S,
        include_deleted: bool,
    ) -> Result<Vec<String>> {
        let referenced: BTreeSet<String> = self
            .list_attachment_ids(include_deleted)?
            .into_iter()
            .collect();
        let mut removed = Vec::new();
        for id in store.list_ids()? {
            if !referenced.contains(&id) {
                store.delete(&id)?;
                removed.push(id);
            }
        }
        Ok(removed)
    }

    pub fn mark_session_synced(&self, uuid: Uuid, remote_id: &str) -> Result<()> {
        let rows = self.backend.with_conn(|conn| {
            conn.execute(
                "UPDATE sessions SET remote_id = ?, needs_sync = 0 WHERE session_uuid = ? AND deleted_at IS NULL",
                params![remote_id, uuid.to_string()],
            )
            .map_err(Error::from)
        })?;
        if rows == 0 {
            return Err(Error::NotFound("session".to_string()));
        }
        Ok(())
    }

    pub fn get_pending_deletions(&self) -> Result<Vec<(EntityType, Uuid)>> {
        self.backend.with_conn(|conn| {
            let mut pending = Vec::new();
            let mut stmt = conn.prepare(
                "SELECT session_uuid FROM sessions
                 WHERE remote_id IS NOT NULL AND deleted_at IS NOT NULL",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let uuid: String = row.get(0)?;
                pending.push((EntityType::Session, Uuid::parse_str(&uuid)?));
            }

            let mut stmt = conn.prepare(
                "SELECT message_uuid FROM messages
                 WHERE deleted_at IS NOT NULL
                   AND session_uuid IN (SELECT session_uuid FROM sessions WHERE remote_id IS NOT NULL)",
            )?;
            let mut rows = stmt.query([])?;
            while let Some(row) = rows.next()? {
                let uuid: String = row.get(0)?;
                pending.push((EntityType::Message, Uuid::parse_str(&uuid)?));
            }

            Ok(pending)
        })
    }

    pub fn hard_delete(&self, entity_type: EntityType, uuid: Uuid) -> Result<()> {
        let rows = self.backend.with_conn(|conn| {
            let uuid = uuid.to_string();
            match entity_type {
                EntityType::Session => {
                    conn.execute("DELETE FROM sessions WHERE session_uuid = ?", params![uuid])
                }
                EntityType::Message => {
                    conn.execute("DELETE FROM messages WHERE message_uuid = ?", params![uuid])
                }
            }
            .map_err(Error::from)
        })?;
        if rows == 0 {
            return Err(Error::NotFound(format!("{:?}", entity_type)));
        }
        Ok(())
    }

    fn session_from_row(&self, row: &Row<'_>) -> Result<Session> {
        let uuid: String = row.get(0)?;
        let title_blob: Vec<u8> = row.get(1)?;
        let created_at: i64 = row.get(2)?;
        let updated_at: i64 = row.get(3)?;
        let remote_id: Option<String> = row.get(4)?;
        let needs_sync: i64 = row.get(5)?;
        let deleted_at: Option<i64> = row.get(6)?;

        let title = String::from_utf8(crypto::decrypt_blob_field(&title_blob, &self.key)?)?;

        Ok(Session {
            uuid: Uuid::parse_str(&uuid)?,
            title,
            created_at,
            updated_at,
            remote_id,
            needs_sync: needs_sync != 0,
            deleted_at,
        })
    }

    fn message_from_row(&self, row: &Row<'_>) -> Result<Message> {
        let uuid: String = row.get(0)?;
        let session_uuid: String = row.get(1)?;
        let parent: Option<String> = row.get(2)?;
        let sender: String = row.get(3)?;
        let text_blob: Vec<u8> = row.get(4)?;
        let attachments_json: Option<String> = row.get(5)?;
        let created_at: i64 = row.get(6)?;
        let deleted_at: Option<i64> = row.get(7)?;

        let sender = Sender::try_from(sender.as_str()).map_err(Error::InvalidSender)?;
        let text = String::from_utf8(crypto::decrypt_blob_field(&text_blob, &self.key)?)?;
        let attachments = self.attachments_from_json(attachments_json)?;

        Ok(Message {
            uuid: Uuid::parse_str(&uuid)?,
            session_uuid: Uuid::parse_str(&session_uuid)?,
            parent_message_uuid: match parent {
                Some(value) => Some(Uuid::parse_str(&value)?),
                None => None,
            },
            sender,
            text,
            attachments,
            created_at,
            deleted_at,
        })
    }

    fn attachments_from_json(&self, json: Option<String>) -> Result<Vec<Attachment>> {
        let Some(json) = json else {
            return Ok(Vec::new());
        };
        let attachments: Vec<AttachmentJson> = serde_json::from_str(&json)?;
        attachments
            .into_iter()
            .map(|attachment| self.attachment_from_json(attachment))
            .collect()
    }

    fn attachment_from_json(&self, attachment: AttachmentJson) -> Result<Attachment> {
        Ok(Attachment {
            id: attachment.id,
            kind: attachment.kind,
            size: attachment.size,
            name: crypto::decrypt_name(&attachment.encrypted_name, &self.key)?,
            uploaded_at: attachment.uploaded_at,
        })
    }

    fn attachments_to_json(&self, attachments: &[Attachment]) -> Result<Option<String>> {
        if attachments.is_empty() {
            return Ok(None);
        }
        let mut items = Vec::with_capacity(attachments.len());
        for attachment in attachments {
            items.push(AttachmentJson {
                id: attachment.id.clone(),
                kind: attachment.kind.clone(),
                size: attachment.size,
                encrypted_name: crypto::encrypt_name(&attachment.name, &self.key)?,
                uploaded_at: attachment.uploaded_at,
            });
        }
        Ok(Some(serde_json::to_string(&items)?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend::sqlite::SqliteBackend;
    use crate::traits::{Clock, FsAttachmentStore, UuidGen};
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};
    use tempfile::tempdir;

    const TEST_KEY: [u8; crypto::KEY_BYTES] = [7u8; crypto::KEY_BYTES];

    #[derive(Debug)]
    struct TestClock {
        now: Mutex<i64>,
    }

    impl TestClock {
        fn new(now: i64) -> Self {
            Self {
                now: Mutex::new(now),
            }
        }

        fn set(&self, value: i64) {
            *self.now.lock().unwrap() = value;
        }
    }

    impl Clock for TestClock {
        fn now_us(&self) -> i64 {
            *self.now.lock().unwrap()
        }
    }

    #[derive(Debug)]
    struct TestUuidGen {
        values: Mutex<VecDeque<Uuid>>,
    }

    impl TestUuidGen {
        fn new(values: Vec<Uuid>) -> Self {
            Self {
                values: Mutex::new(values.into()),
            }
        }
    }

    impl UuidGen for TestUuidGen {
        fn new_uuid(&self) -> Uuid {
            self.values
                .lock()
                .unwrap()
                .pop_front()
                .expect("uuid queue exhausted")
        }
    }

    fn build_db(clock: Arc<TestClock>, uuid_gen: Arc<TestUuidGen>) -> ChatDb<SqliteBackend> {
        let backend = SqliteBackend::in_memory().unwrap();
        ChatDb::new(backend, &TEST_KEY, clock, uuid_gen).unwrap()
    }

    #[test]
    fn test_schema_indexes_exist() {
        let clock = Arc::new(TestClock::new(10));
        let uuid_gen = Arc::new(TestUuidGen::new(vec![Uuid::new_v4()]));
        let db = build_db(clock, uuid_gen);
        db.backend
            .with_conn(|conn| {
                let mut stmt = conn.prepare(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'messages'",
                )?;
                let indexes: Vec<String> = stmt
                    .query_map([], |row| row.get(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                assert!(indexes.contains(&"idx_messages_order".to_string()));

                let mut stmt = conn.prepare(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'sessions'",
                )?;
                let indexes: Vec<String> = stmt
                    .query_map([], |row| row.get(0))?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
                assert!(indexes.contains(&"idx_sessions_updated".to_string()));
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn test_session_crud() {
        let clock = Arc::new(TestClock::new(100));
        let session_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid]));
        let db = build_db(clock.clone(), uuid_gen);

        let session = db.create_session("Hello").unwrap();
        assert_eq!(session.uuid, session_uuid);
        assert_eq!(session.title, "Hello");
        assert!(session.needs_sync);

        let loaded = db.get_session(session_uuid).unwrap().unwrap();
        assert_eq!(loaded.title, "Hello");

        clock.set(200);
        db.update_session_title(session_uuid, "Updated").unwrap();
        let updated = db.get_session(session_uuid).unwrap().unwrap();
        assert_eq!(updated.title, "Updated");
        assert_eq!(updated.updated_at, 200);

        db.delete_session(session_uuid).unwrap();
        assert!(db.get_session(session_uuid).unwrap().is_none());
        assert!(db.list_sessions().unwrap().is_empty());
    }

    #[test]
    fn test_message_and_attachments() {
        let clock = Arc::new(TestClock::new(1000));
        let session_uuid = Uuid::new_v4();
        let message_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid, message_uuid]));
        let db = build_db(clock.clone(), uuid_gen);
        db.create_session("Chat").unwrap();

        let attachment = Attachment {
            id: "att-1".to_string(),
            kind: "image".to_string(),
            size: 55,
            name: "secret.png".to_string(),
            uploaded_at: None,
        };

        let message = db
            .insert_message(
                session_uuid,
                "self",
                "hello",
                None,
                vec![attachment.clone()],
            )
            .unwrap();
        assert_eq!(message.uuid, message_uuid);
        assert_eq!(message.attachments.len(), 1);

        let messages = db.get_messages(session_uuid).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].attachments[0].name, "secret.png");

        let pending = db.get_pending_uploads(session_uuid).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].id, "att-1");

        clock.set(2000);
        db.mark_attachment_uploaded(message_uuid, "att-1").unwrap();
        let pending = db.get_pending_uploads(session_uuid).unwrap();
        assert!(pending.is_empty());
        let session = db.get_session(session_uuid).unwrap().unwrap();
        assert_eq!(session.updated_at, 1000);
    }

    #[test]
    fn test_sender_validation() {
        let clock = Arc::new(TestClock::new(500));
        let session_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid]));
        let db = build_db(clock, uuid_gen);
        db.create_session("Chat").unwrap();

        let err = db
            .insert_message(session_uuid, "invalid", "oops", None, vec![])
            .unwrap_err();
        match err {
            Error::InvalidSender(value) => assert_eq!(value, "invalid"),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn test_pending_deletions() {
        let clock = Arc::new(TestClock::new(100));
        let session_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid]));
        let db = build_db(clock, uuid_gen);
        db.create_session("Chat").unwrap();
        db.mark_session_synced(session_uuid, "remote-1").unwrap();
        db.delete_session(session_uuid).unwrap();

        let pending = db.get_pending_deletions().unwrap();
        assert!(pending
            .iter()
            .any(|(kind, uuid)| { matches!(kind, EntityType::Session) && *uuid == session_uuid }));
    }

    #[test]
    fn test_hard_delete_session_cascades_messages() {
        let clock = Arc::new(TestClock::new(1));
        let session_uuid = Uuid::new_v4();
        let message_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid, message_uuid]));
        let db = build_db(clock, uuid_gen);
        db.create_session("Chat").unwrap();
        db.insert_message(session_uuid, "self", "hi", None, vec![])
            .unwrap();

        db.hard_delete(EntityType::Session, session_uuid).unwrap();

        db.backend
            .with_conn(|conn| {
                let session_count: i64 =
                    conn.query_row("SELECT COUNT(*) FROM sessions", [], |row| row.get(0))?;
                let message_count: i64 =
                    conn.query_row("SELECT COUNT(*) FROM messages", [], |row| row.get(0))?;
                assert_eq!(session_count, 0);
                assert_eq!(message_count, 0);
                Ok(())
            })
            .unwrap();
    }

    #[test]
    fn test_hard_delete_missing_returns_error() {
        let clock = Arc::new(TestClock::new(1));
        let uuid_gen = Arc::new(TestUuidGen::new(vec![]));
        let db = build_db(clock, uuid_gen);

        let err = db
            .hard_delete(EntityType::Message, Uuid::new_v4())
            .unwrap_err();
        match err {
            Error::NotFound(value) => assert_eq!(value, "Message"),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn test_mark_session_synced_deleted_session() {
        let clock = Arc::new(TestClock::new(50));
        let session_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid]));
        let db = build_db(clock, uuid_gen);
        db.create_session("Chat").unwrap();
        db.delete_session(session_uuid).unwrap();

        let err = db.mark_session_synced(session_uuid, "remote").unwrap_err();
        match err {
            Error::NotFound(value) => assert_eq!(value, "session"),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn test_cleanup_orphaned_attachments() {
        let clock = Arc::new(TestClock::new(10));
        let session_uuid = Uuid::new_v4();
        let message_uuid = Uuid::new_v4();
        let uuid_gen = Arc::new(TestUuidGen::new(vec![session_uuid, message_uuid]));
        let db = build_db(clock, uuid_gen);
        db.create_session("Chat").unwrap();
        db.insert_message(
            session_uuid,
            "self",
            "hello",
            None,
            vec![Attachment {
                id: "att-keep".to_string(),
                kind: "image".to_string(),
                size: 10,
                name: "keep.png".to_string(),
                uploaded_at: None,
            }],
        )
        .unwrap();

        let dir = tempdir().unwrap();
        let store = FsAttachmentStore::new(dir.path());
        store.write("att-keep", b"data").unwrap();
        store.write("att-orphan", b"data").unwrap();

        let removed = db.cleanup_orphaned_attachments(&store, true).unwrap();
        assert!(removed.contains(&"att-orphan".to_string()));
        assert!(!removed.contains(&"att-keep".to_string()));
        assert!(store.exists("att-keep").unwrap());
        assert!(!store.exists("att-orphan").unwrap());
    }
}
