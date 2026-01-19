use crate::{error::Result, schema::CREATE_TABLES_SQL, Error};
use rusqlite::Connection;

pub const SCHEMA_VERSION: i32 = 1;

pub fn run_migrations(conn: &Connection) -> Result<()> {
    conn.execute_batch("PRAGMA foreign_keys = ON;")?;

    let user_version: i32 = conn.query_row("PRAGMA user_version;", [], |row| row.get(0))?;

    if user_version == 0 {
        conn.execute_batch(CREATE_TABLES_SQL)?;
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
    } else if user_version != SCHEMA_VERSION {
        return Err(Error::UnsupportedSchema(user_version));
    }

    Ok(())
}
