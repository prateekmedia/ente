//! Cryptographic hashing.
//!
//! This module provides generic hashing using BLAKE2b.

use super::{CryptoError, Result};
use libsodium_sys as sodium;
use std::io::Read;

/// Maximum hash output length (64 bytes).
pub const HASH_BYTES_MAX: usize = sodium::crypto_generichash_BYTES_MAX as usize;

/// Minimum hash output length (16 bytes).
pub const HASH_BYTES_MIN: usize = sodium::crypto_generichash_BYTES_MIN as usize;

/// Default hash output length (32 bytes).
pub const HASH_BYTES: usize = sodium::crypto_generichash_BYTES as usize;

/// Hash state for streaming/chunked hashing.
pub struct HashState {
    state: Box<[u8]>,
    output_len: usize,
}

impl HashState {
    fn state_bytes() -> usize {
        unsafe { sodium::crypto_generichash_statebytes() }
    }

    /// Create a new hash state for streaming hashing.
    ///
    /// # Arguments
    /// * `output_len` - Desired hash output length (16-64 bytes, default 64).
    /// * `key` - Optional key for keyed hashing.
    pub fn new(output_len: Option<usize>, key: Option<&[u8]>) -> Result<Self> {
        let output_len = output_len.unwrap_or(HASH_BYTES_MAX);
        if !(HASH_BYTES_MIN..=HASH_BYTES_MAX).contains(&output_len) {
            return Err(CryptoError::InvalidKeyDerivationParams(format!(
                "Hash output length must be between {} and {}",
                HASH_BYTES_MIN, HASH_BYTES_MAX
            )));
        }

        let mut state = vec![0u8; Self::state_bytes()].into_boxed_slice();

        let (key_ptr, key_len) = match key {
            Some(k) => (k.as_ptr(), k.len()),
            None => (std::ptr::null(), 0),
        };

        let result = unsafe {
            sodium::crypto_generichash_init(
                state.as_mut_ptr() as *mut sodium::crypto_generichash_state,
                key_ptr,
                key_len,
                output_len,
            )
        };

        if result != 0 {
            return Err(CryptoError::HashFailed);
        }

        Ok(HashState { state, output_len })
    }

    /// Update the hash state with more data.
    pub fn update(&mut self, data: &[u8]) -> Result<()> {
        let result = unsafe {
            sodium::crypto_generichash_update(
                self.state.as_mut_ptr() as *mut sodium::crypto_generichash_state,
                data.as_ptr(),
                data.len() as u64,
            )
        };

        if result != 0 {
            return Err(CryptoError::HashFailed);
        }

        Ok(())
    }

    /// Finalize the hash and return the result.
    pub fn finalize(mut self) -> Result<Vec<u8>> {
        let mut hash = vec![0u8; self.output_len];

        let result = unsafe {
            sodium::crypto_generichash_final(
                self.state.as_mut_ptr() as *mut sodium::crypto_generichash_state,
                hash.as_mut_ptr(),
                self.output_len,
            )
        };

        if result != 0 {
            return Err(CryptoError::HashFailed);
        }

        Ok(hash)
    }
}

/// Compute a hash of the given data.
///
/// # Arguments
/// * `data` - Data to hash.
/// * `output_len` - Desired hash output length (16-64 bytes, default 64).
/// * `key` - Optional key for keyed hashing.
///
/// # Returns
/// The hash bytes.
pub fn hash(data: &[u8], output_len: Option<usize>, key: Option<&[u8]>) -> Result<Vec<u8>> {
    let output_len = output_len.unwrap_or(HASH_BYTES_MAX);
    if !(HASH_BYTES_MIN..=HASH_BYTES_MAX).contains(&output_len) {
        return Err(CryptoError::InvalidKeyDerivationParams(format!(
            "Hash output length must be between {} and {}",
            HASH_BYTES_MIN, HASH_BYTES_MAX
        )));
    }

    let mut hash = vec![0u8; output_len];

    let (key_ptr, key_len) = match key {
        Some(k) => (k.as_ptr(), k.len()),
        None => (std::ptr::null(), 0),
    };

    let result = unsafe {
        sodium::crypto_generichash(
            hash.as_mut_ptr(),
            output_len,
            data.as_ptr(),
            data.len() as u64,
            key_ptr,
            key_len,
        )
    };

    if result != 0 {
        return Err(CryptoError::HashFailed);
    }

    Ok(hash)
}

/// Compute a hash of the given data with default output length (64 bytes).
pub fn hash_default(data: &[u8]) -> Result<Vec<u8>> {
    hash(data, None, None)
}

/// Hash a file or reader in chunks.
///
/// # Arguments
/// * `reader` - Reader to hash.
/// * `output_len` - Desired hash output length (16-64 bytes, default 64).
///
/// # Returns
/// The hash bytes.
pub fn hash_reader<R: Read>(reader: &mut R, output_len: Option<usize>) -> Result<Vec<u8>> {
    let mut state = HashState::new(output_len, None)?;
    let mut buffer = vec![0u8; 4 * 1024 * 1024]; // 4 MB chunks

    loop {
        let bytes_read = reader.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }
        state.update(&buffer[..bytes_read])?;
    }

    state.finalize()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_hash() {
        crate::crypto::init().unwrap();
        let data = b"Hello, World!";

        let hash1 = hash_default(data).unwrap();
        assert_eq!(hash1.len(), HASH_BYTES_MAX);

        // Same data should produce same hash
        let hash2 = hash_default(data).unwrap();
        assert_eq!(hash1, hash2);

        // Different data should produce different hash
        let hash3 = hash_default(b"Different data").unwrap();
        assert_ne!(hash1, hash3);
    }

    #[test]
    fn test_hash_custom_length() {
        crate::crypto::init().unwrap();
        let data = b"Test data";

        let hash32 = hash(data, Some(32), None).unwrap();
        assert_eq!(hash32.len(), 32);

        let hash16 = hash(data, Some(16), None).unwrap();
        assert_eq!(hash16.len(), 16);
    }

    #[test]
    fn test_keyed_hash() {
        crate::crypto::init().unwrap();
        let data = b"Test data";
        let key1 = crate::crypto::keys::generate_key();
        let key2 = crate::crypto::keys::generate_key();

        let hash1 = hash(data, None, Some(&key1)).unwrap();
        let hash2 = hash(data, None, Some(&key1)).unwrap();
        let hash3 = hash(data, None, Some(&key2)).unwrap();

        // Same key should produce same hash
        assert_eq!(hash1, hash2);

        // Different key should produce different hash
        assert_ne!(hash1, hash3);
    }

    #[test]
    fn test_hash_state() {
        crate::crypto::init().unwrap();
        let data = b"Hello, World!";

        // Hash all at once
        let hash_direct = hash_default(data).unwrap();

        // Hash in chunks
        let mut state = HashState::new(None, None).unwrap();
        state.update(b"Hello, ").unwrap();
        state.update(b"World!").unwrap();
        let hash_chunked = state.finalize().unwrap();

        assert_eq!(hash_direct, hash_chunked);
    }

    #[test]
    fn test_hash_reader() {
        crate::crypto::init().unwrap();
        let data = b"File contents here";

        let hash_direct = hash_default(data).unwrap();

        let mut cursor = Cursor::new(data.to_vec());
        let hash_reader = hash_reader(&mut cursor, None).unwrap();

        assert_eq!(hash_direct, hash_reader);
    }

    #[test]
    fn test_hash_empty() {
        crate::crypto::init().unwrap();
        let hash = hash_default(b"").unwrap();
        assert_eq!(hash.len(), HASH_BYTES_MAX);
    }

    #[test]
    fn test_hash_large() {
        crate::crypto::init().unwrap();
        let data = vec![0x42u8; 10 * 1024 * 1024]; // 10 MB
        let hash = hash_default(&data).unwrap();
        assert_eq!(hash.len(), HASH_BYTES_MAX);
    }

    #[test]
    fn test_invalid_output_length() {
        crate::crypto::init().unwrap();

        // Too short
        let result = hash(b"test", Some(8), None);
        assert!(matches!(
            result,
            Err(CryptoError::InvalidKeyDerivationParams(_))
        ));

        // Too long
        let result = hash(b"test", Some(128), None);
        assert!(matches!(
            result,
            Err(CryptoError::InvalidKeyDerivationParams(_))
        ));
    }
}
