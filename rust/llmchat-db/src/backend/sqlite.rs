use crate::{backend::Backend, Error, Result};
use rusqlite::{Connection, Transaction};
use std::{path::Path, sync::Mutex};

pub struct SqliteBackend {
    conn: Mutex<Connection>,
}

impl SqliteBackend {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }

    pub fn in_memory() -> Result<Self> {
        let conn = Connection::open_in_memory()?;
        Ok(Self {
            conn: Mutex::new(conn),
        })
    }
}

impl Backend for SqliteBackend {
    fn with_conn<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T>,
    {
        let conn = self.conn.lock().map_err(|_| Error::LockPoisoned)?;
        f(&conn)
    }

    fn with_txn<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>,
    {
        let mut conn = self.conn.lock().map_err(|_| Error::LockPoisoned)?;
        let txn = conn.transaction()?;
        let result = f(&txn);
        match result {
            Ok(value) => {
                txn.commit()?;
                Ok(value)
            }
            Err(err) => Err(err),
        }
    }
}
