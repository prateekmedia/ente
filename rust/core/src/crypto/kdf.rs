//! Key derivation functions for subkey generation.

use super::{CryptoError, Result};
use libsodium_sys as sodium;

/// Context bytes required for KDF.
pub const CONTEXT_BYTES: usize = sodium::crypto_kdf_CONTEXTBYTES as usize;

/// Minimum subkey length.
pub const SUBKEY_BYTES_MIN: usize = sodium::crypto_kdf_BYTES_MIN as usize;

/// Maximum subkey length.
pub const SUBKEY_BYTES_MAX: usize = sodium::crypto_kdf_BYTES_MAX as usize;

/// Master key length for KDF.
pub const KEY_BYTES: usize = sodium::crypto_kdf_KEYBYTES as usize;

// Login key derivation constants
const LOGIN_SUB_KEY_LEN: usize = 32;
const LOGIN_SUB_KEY_ID: u64 = 1;
const LOGIN_SUB_KEY_CONTEXT: &[u8] = b"loginctx";

/// Derive a subkey from a master key using KDF.
///
/// Multiple secret subkeys can be deterministically derived from a single
/// high-entropy key. Knowledge of a derived key does not impact the security
/// of the master key or other sibling subkeys.
///
/// # Arguments
/// * `key` - The master key (32 bytes).
/// * `subkey_len` - Length of the subkey to derive (16-64 bytes).
/// * `subkey_id` - Unique identifier for this subkey.
/// * `context` - 8-byte context string to separate domains.
///
/// # Returns
/// The derived subkey bytes.
pub fn derive_subkey(
    key: &[u8],
    subkey_len: usize,
    subkey_id: u64,
    context: &[u8],
) -> Result<Vec<u8>> {
    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    if !(SUBKEY_BYTES_MIN..=SUBKEY_BYTES_MAX).contains(&subkey_len) {
        return Err(CryptoError::InvalidKeyDerivationParams(format!(
            "Subkey length must be between {} and {}",
            SUBKEY_BYTES_MIN, SUBKEY_BYTES_MAX
        )));
    }

    // Ensure context is exactly 8 bytes
    let mut ctx = [0u8; CONTEXT_BYTES];
    let ctx_len = context.len().min(CONTEXT_BYTES);
    ctx[..ctx_len].copy_from_slice(&context[..ctx_len]);

    let mut subkey = vec![0u8; subkey_len];

    let result = unsafe {
        sodium::crypto_kdf_derive_from_key(
            subkey.as_mut_ptr(),
            subkey_len,
            subkey_id,
            ctx.as_ptr() as *const std::ffi::c_char,
            key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::KeyDerivationFailed);
    }

    Ok(subkey)
}

/// Derive a login key from the key encryption key (KEK).
///
/// This matches the web implementation's `deriveSRPLoginSubKey` function.
/// The login key is used for SRP authentication.
///
/// # Arguments
/// * `key_enc_key` - The key encryption key (32 bytes).
///
/// # Returns
/// A 16-byte login key.
pub fn derive_login_key(key_enc_key: &[u8]) -> Result<Vec<u8>> {
    let subkey = derive_subkey(
        key_enc_key,
        LOGIN_SUB_KEY_LEN,
        LOGIN_SUB_KEY_ID,
        LOGIN_SUB_KEY_CONTEXT,
    )?;

    // Return only the first 16 bytes (matching web implementation)
    Ok(subkey[..16].to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_derive_subkey() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();

        let subkey1 = derive_subkey(&key, 32, 1, b"context1").unwrap();
        assert_eq!(subkey1.len(), 32);

        // Same parameters should produce same subkey
        let subkey1_again = derive_subkey(&key, 32, 1, b"context1").unwrap();
        assert_eq!(subkey1, subkey1_again);

        // Different subkey_id should produce different subkey
        let subkey2 = derive_subkey(&key, 32, 2, b"context1").unwrap();
        assert_ne!(subkey1, subkey2);

        // Different context should produce different subkey
        let subkey3 = derive_subkey(&key, 32, 1, b"context2").unwrap();
        assert_ne!(subkey1, subkey3);
    }

    #[test]
    fn test_derive_subkey_different_lengths() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();

        let subkey16 = derive_subkey(&key, 16, 1, b"test").unwrap();
        assert_eq!(subkey16.len(), 16);

        let subkey64 = derive_subkey(&key, 64, 1, b"test").unwrap();
        assert_eq!(subkey64.len(), 64);
    }

    #[test]
    fn test_derive_login_key() {
        crate::crypto::init().unwrap();
        let kek = crate::crypto::keys::generate_key();

        let login_key = derive_login_key(&kek).unwrap();
        assert_eq!(login_key.len(), 16);

        // Should be deterministic
        let login_key2 = derive_login_key(&kek).unwrap();
        assert_eq!(login_key, login_key2);
    }

    #[test]
    fn test_invalid_key_length() {
        crate::crypto::init().unwrap();
        let short_key = vec![0u8; 16];
        let result = derive_subkey(&short_key, 32, 1, b"test");
        assert!(matches!(result, Err(CryptoError::InvalidKeyLength { .. })));
    }

    #[test]
    fn test_invalid_subkey_length() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();

        // Too short
        let result = derive_subkey(&key, 8, 1, b"test");
        assert!(matches!(
            result,
            Err(CryptoError::InvalidKeyDerivationParams(_))
        ));

        // Too long
        let result = derive_subkey(&key, 128, 1, b"test");
        assert!(matches!(
            result,
            Err(CryptoError::InvalidKeyDerivationParams(_))
        ));
    }
}
