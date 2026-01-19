use crate::Result;
use ente_core::crypto;
use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

pub trait MetaStore: Send + Sync {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>>;
    fn set(&self, key: &str, value: &[u8]) -> Result<()>;
    fn delete(&self, key: &str) -> Result<()>;
}

pub trait AttachmentStore: Send + Sync {
    fn write(&self, id: &str, data: &[u8]) -> Result<()>;
    fn read(&self, id: &str) -> Result<Vec<u8>>;
    fn delete(&self, id: &str) -> Result<()>;
    fn exists(&self, id: &str) -> Result<bool>;
    fn list_ids(&self) -> Result<Vec<String>>;
}

pub trait Clock: Send + Sync {
    fn now_us(&self) -> i64;
}

pub trait UuidGen: Send + Sync {
    fn new_uuid(&self) -> Uuid;
}

#[derive(Debug, Default, Clone)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_us(&self) -> i64 {
        let duration = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("system clock should be after unix epoch");
        duration.as_micros() as i64
    }
}

#[derive(Debug, Default, Clone)]
pub struct RandomUuidGen;

impl UuidGen for RandomUuidGen {
    fn new_uuid(&self) -> Uuid {
        Uuid::new_v4()
    }
}

#[derive(Debug, Clone)]
pub struct FileMetaStore {
    root: Arc<PathBuf>,
}

impl FileMetaStore {
    pub fn new(path: impl AsRef<Path>) -> Self {
        Self {
            root: Arc::new(path.as_ref().to_path_buf()),
        }
    }

    fn path_for(&self, key: &str) -> PathBuf {
        let encoded = crypto::encode_hex(key.as_bytes());
        self.root.join(encoded)
    }
}

impl MetaStore for FileMetaStore {
    fn get(&self, key: &str) -> Result<Option<Vec<u8>>> {
        let path = self.path_for(key);
        if !path.exists() {
            return Ok(None);
        }
        Ok(Some(fs::read(path)?))
    }

    fn set(&self, key: &str, value: &[u8]) -> Result<()> {
        fs::create_dir_all(&*self.root)?;
        let path = self.path_for(key);
        fs::write(path, value)?;
        Ok(())
    }

    fn delete(&self, key: &str) -> Result<()> {
        let path = self.path_for(key);
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }
}

#[derive(Debug, Clone)]
pub struct FsAttachmentStore {
    root: Arc<PathBuf>,
}

impl FsAttachmentStore {
    pub fn new(base_dir: impl AsRef<Path>) -> Self {
        Self {
            root: Arc::new(base_dir.as_ref().join("chat_attachments")),
        }
    }

    fn path_for(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }
}

impl AttachmentStore for FsAttachmentStore {
    fn write(&self, id: &str, data: &[u8]) -> Result<()> {
        fs::create_dir_all(&*self.root)?;
        let path = self.path_for(id);
        fs::write(path, data)?;
        Ok(())
    }

    fn read(&self, id: &str) -> Result<Vec<u8>> {
        let path = self.path_for(id);
        Ok(fs::read(path)?)
    }

    fn delete(&self, id: &str) -> Result<()> {
        let path = self.path_for(id);
        if path.exists() {
            fs::remove_file(path)?;
        }
        Ok(())
    }

    fn exists(&self, id: &str) -> Result<bool> {
        Ok(self.path_for(id).exists())
    }

    fn list_ids(&self) -> Result<Vec<String>> {
        if !self.root.exists() {
            return Ok(Vec::new());
        }
        let mut ids = Vec::new();
        for entry in fs::read_dir(&*self.root)? {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                ids.push(entry.file_name().to_string_lossy().to_string());
            }
        }
        Ok(ids)
    }
}
