use crate::Result;
use rusqlite::{Connection, Transaction};

pub mod sqlite;

pub trait Backend: Send + Sync {
    fn with_conn<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Connection) -> Result<T>;

    fn with_txn<T, F>(&self, f: F) -> Result<T>
    where
        F: FnOnce(&Transaction) -> Result<T>;
}
