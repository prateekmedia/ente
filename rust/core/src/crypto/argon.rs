//! Argon2id key derivation.

use super::{CryptoError, Result};
use libsodium_sys as sodium;

/// Memory limit for interactive key derivation (64 MB).
pub const MEMLIMIT_INTERACTIVE: u32 = sodium::crypto_pwhash_MEMLIMIT_INTERACTIVE;

/// Operations limit for interactive key derivation.
pub const OPSLIMIT_INTERACTIVE: u32 = sodium::crypto_pwhash_OPSLIMIT_INTERACTIVE;

/// Memory limit for moderate key derivation (256 MB).
pub const MEMLIMIT_MODERATE: u32 = sodium::crypto_pwhash_MEMLIMIT_MODERATE;

/// Operations limit for moderate key derivation.
pub const OPSLIMIT_MODERATE: u32 = sodium::crypto_pwhash_OPSLIMIT_MODERATE;

/// Memory limit for sensitive key derivation (1 GB).
pub const MEMLIMIT_SENSITIVE: u32 = sodium::crypto_pwhash_MEMLIMIT_SENSITIVE;

/// Operations limit for sensitive key derivation.
pub const OPSLIMIT_SENSITIVE: u32 = sodium::crypto_pwhash_OPSLIMIT_SENSITIVE;

/// Minimum memory limit.
pub const MEMLIMIT_MIN: u32 = sodium::crypto_pwhash_MEMLIMIT_MIN;

/// Maximum operations limit.
pub const OPSLIMIT_MAX: u32 = sodium::crypto_pwhash_OPSLIMIT_MAX;

/// Salt bytes required for key derivation.
pub const SALT_BYTES: usize = sodium::crypto_pwhash_SALTBYTES as usize;

/// Result of key derivation including the parameters used.
#[derive(Debug, Clone)]
pub struct DerivedKey {
    /// The derived key bytes.
    pub key: Vec<u8>,
    /// The salt used (as bytes).
    pub salt: Vec<u8>,
    /// Operations limit used.
    pub ops_limit: u32,
    /// Memory limit used.
    pub mem_limit: u32,
}

/// Derive a key from a password using Argon2id.
///
/// # Arguments
/// * `password` - The password string.
/// * `salt` - 16-byte salt (can be base64 encoded or raw bytes).
/// * `mem_limit` - Memory limit in bytes.
/// * `ops_limit` - Operations limit.
///
/// # Returns
/// A 32-byte derived key.
pub fn derive_key(password: &str, salt: &[u8], mem_limit: u32, ops_limit: u32) -> Result<Vec<u8>> {
    if mem_limit < MEMLIMIT_MIN || ops_limit < 1 {
        return Err(CryptoError::InvalidKeyDerivationParams(
            "Invalid memory or operation limits".into(),
        ));
    }

    if salt.len() != SALT_BYTES {
        return Err(CryptoError::InvalidSaltLength {
            expected: SALT_BYTES,
            actual: salt.len(),
        });
    }

    let mut key = vec![0u8; sodium::crypto_secretbox_KEYBYTES as usize];
    let password_bytes = password.as_bytes();

    let result = unsafe {
        sodium::crypto_pwhash(
            key.as_mut_ptr(),
            key.len() as u64,
            password_bytes.as_ptr() as *const std::ffi::c_char,
            password_bytes.len() as u64,
            salt.as_ptr(),
            ops_limit as u64,
            mem_limit as usize,
            sodium::crypto_pwhash_ALG_ARGON2ID13 as i32,
        )
    };

    if result != 0 {
        return Err(CryptoError::KeyDerivationFailed);
    }

    Ok(key)
}

/// Derive a key from a password with base64-encoded salt.
///
/// # Arguments
/// * `password` - The password string.
/// * `salt_b64` - Base64-encoded 16-byte salt.
/// * `mem_limit` - Memory limit in bytes.
/// * `ops_limit` - Operations limit.
///
/// # Returns
/// A 32-byte derived key.
pub fn derive_key_from_b64_salt(
    password: &str,
    salt_b64: &str,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>> {
    let salt = super::decode_b64(salt_b64)?;
    derive_key(password, &salt, mem_limit, ops_limit)
}

/// Derive a sensitive key with adaptive parameters.
///
/// This function attempts to derive a key with secure parameters,
/// falling back to lower memory usage if the device cannot handle it.
///
/// # Arguments
/// * `password` - The password string.
///
/// # Returns
/// A [`DerivedKey`] containing the key and the parameters used.
pub fn derive_sensitive_key(password: &str) -> Result<DerivedKey> {
    let salt = super::keys::generate_salt();

    // Target strength: MEMLIMIT_SENSITIVE * OPSLIMIT_SENSITIVE
    // Start with moderate memory but higher ops to maintain security
    let factor = MEMLIMIT_SENSITIVE / MEMLIMIT_MODERATE; // = 4
    let mut mem_limit = MEMLIMIT_MODERATE; // 256 MB
    let mut ops_limit = OPSLIMIT_SENSITIVE * factor; // 16

    while mem_limit >= MEMLIMIT_MIN {
        match derive_key(password, &salt, mem_limit, ops_limit) {
            Ok(key) => {
                return Ok(DerivedKey {
                    key,
                    salt,
                    ops_limit,
                    mem_limit,
                });
            }
            Err(_) => {
                // Halve memory, double ops to maintain work factor
                ops_limit *= 2;
                mem_limit /= 2;
            }
        }
    }

    Err(CryptoError::InvalidKeyDerivationParams(
        "Cannot perform key derivation on this device".into(),
    ))
}

/// Derive an interactive key (faster, less secure parameters).
///
/// # Arguments
/// * `password` - The password string.
///
/// # Returns
/// A [`DerivedKey`] containing the key and the parameters used.
pub fn derive_interactive_key(password: &str) -> Result<DerivedKey> {
    let salt = super::keys::generate_salt();
    let key = derive_key(password, &salt, MEMLIMIT_INTERACTIVE, OPSLIMIT_INTERACTIVE)?;

    Ok(DerivedKey {
        key,
        salt,
        ops_limit: OPSLIMIT_INTERACTIVE,
        mem_limit: MEMLIMIT_INTERACTIVE,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_key() {
        crate::crypto::init().unwrap();
        let salt = crate::crypto::keys::generate_salt();
        let key = derive_key(
            "password123",
            &salt,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        )
        .unwrap();
        assert_eq!(key.len(), 32);

        // Same password and salt should produce same key
        let key2 = derive_key(
            "password123",
            &salt,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        )
        .unwrap();
        assert_eq!(key, key2);

        // Different password should produce different key
        let key3 = derive_key(
            "different",
            &salt,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        )
        .unwrap();
        assert_ne!(key, key3);
    }

    #[test]
    fn test_derive_key_from_b64_salt() {
        crate::crypto::init().unwrap();
        let salt = crate::crypto::keys::generate_salt();
        let salt_b64 = crate::crypto::encode_b64(&salt);

        let key1 = derive_key(
            "password",
            &salt,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        )
        .unwrap();
        let key2 = derive_key_from_b64_salt(
            "password",
            &salt_b64,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        )
        .unwrap();

        assert_eq!(key1, key2);
    }

    #[test]
    fn test_derive_interactive_key() {
        crate::crypto::init().unwrap();
        let derived = derive_interactive_key("password").unwrap();
        assert_eq!(derived.key.len(), 32);
        assert_eq!(derived.salt.len(), 16);
        assert_eq!(derived.mem_limit, MEMLIMIT_INTERACTIVE);
        assert_eq!(derived.ops_limit, OPSLIMIT_INTERACTIVE);
    }

    #[test]
    fn test_invalid_salt_length() {
        crate::crypto::init().unwrap();
        let bad_salt = vec![0u8; 8]; // Too short
        let result = derive_key(
            "password",
            &bad_salt,
            MEMLIMIT_INTERACTIVE,
            OPSLIMIT_INTERACTIVE,
        );
        assert!(matches!(result, Err(CryptoError::InvalidSaltLength { .. })));
    }
}
