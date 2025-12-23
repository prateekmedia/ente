//! Blob encryption (XChaCha20-Poly1305 SecretStream without chunking).
//!
//! This module provides encryption using libsodium's secretstream APIs
//! for small-ish data that doesn't need to be chunked.
//! Use this for encrypting metadata associated with Ente objects.

use super::{CryptoError, Result};
use libsodium_sys as sodium;

/// Key length for SecretStream (32 bytes).
pub const KEY_BYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_KEYBYTES as usize;

/// Header length for SecretStream (24 bytes).
pub const HEADER_BYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_HEADERBYTES as usize;

/// Additional bytes (MAC) per message (17 bytes).
pub const ABYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_ABYTES as usize;

/// Tag for final message in stream.
pub const TAG_FINAL: u8 = sodium::crypto_secretstream_xchacha20poly1305_TAG_FINAL as u8;

/// Tag for regular message.
pub const TAG_MESSAGE: u8 = sodium::crypto_secretstream_xchacha20poly1305_TAG_MESSAGE as u8;

/// Result of blob encryption.
#[derive(Debug, Clone)]
pub struct EncryptedBlob {
    /// The encrypted data.
    pub encrypted_data: Vec<u8>,
    /// The decryption header.
    pub decryption_header: Vec<u8>,
}

/// Encrypt data using SecretStream (XChaCha20-Poly1305) without chunking.
///
/// This is suitable for encrypting metadata and small files.
///
/// # Arguments
/// * `plaintext` - Data to encrypt.
/// * `key` - 32-byte encryption key.
///
/// # Returns
/// An [`EncryptedBlob`] containing the ciphertext and decryption header.
pub fn encrypt(plaintext: &[u8], key: &[u8]) -> Result<EncryptedBlob> {
    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    let state_bytes = unsafe { sodium::crypto_secretstream_xchacha20poly1305_statebytes() };
    let mut state = vec![0u8; state_bytes];
    let mut header = vec![0u8; HEADER_BYTES];

    // Initialize push state
    let result = unsafe {
        sodium::crypto_secretstream_xchacha20poly1305_init_push(
            state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
            header.as_mut_ptr(),
            key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::StreamInitFailed);
    }

    // Encrypt with final tag (single message)
    let mut ciphertext = vec![0u8; plaintext.len() + ABYTES];

    let result = unsafe {
        sodium::crypto_secretstream_xchacha20poly1305_push(
            state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
            ciphertext.as_mut_ptr(),
            std::ptr::null_mut(), // ciphertext_len not needed
            plaintext.as_ptr(),
            plaintext.len() as u64,
            std::ptr::null(),
            0,
            TAG_FINAL,
        )
    };

    if result != 0 {
        return Err(CryptoError::StreamPushFailed);
    }

    Ok(EncryptedBlob {
        encrypted_data: ciphertext,
        decryption_header: header,
    })
}

/// Decrypt data encrypted with [`encrypt`].
///
/// # Arguments
/// * `ciphertext` - The encrypted data.
/// * `header` - The decryption header.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The decrypted plaintext.
pub fn decrypt(ciphertext: &[u8], header: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    if header.len() != HEADER_BYTES {
        return Err(CryptoError::InvalidHeaderLength {
            expected: HEADER_BYTES,
            actual: header.len(),
        });
    }

    if ciphertext.len() < ABYTES {
        return Err(CryptoError::CiphertextTooShort {
            minimum: ABYTES,
            actual: ciphertext.len(),
        });
    }

    let state_bytes = unsafe { sodium::crypto_secretstream_xchacha20poly1305_statebytes() };
    let mut state = vec![0u8; state_bytes];

    // Initialize pull state
    let result = unsafe {
        sodium::crypto_secretstream_xchacha20poly1305_init_pull(
            state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
            header.as_ptr(),
            key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::StreamInitFailed);
    }

    // Decrypt
    let mut plaintext = vec![0u8; ciphertext.len() - ABYTES];
    let mut plaintext_len: u64 = 0;
    let mut tag: u8 = 0;

    let result = unsafe {
        sodium::crypto_secretstream_xchacha20poly1305_pull(
            state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
            plaintext.as_mut_ptr(),
            &mut plaintext_len,
            &mut tag,
            ciphertext.as_ptr(),
            ciphertext.len() as u64,
            std::ptr::null(),
            0,
        )
    };

    if result != 0 {
        return Err(CryptoError::StreamPullFailed);
    }

    plaintext.truncate(plaintext_len as usize);
    Ok(plaintext)
}

/// Decrypt an [`EncryptedBlob`].
///
/// # Arguments
/// * `blob` - The encrypted blob.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The decrypted plaintext.
pub fn decrypt_blob(blob: &EncryptedBlob, key: &[u8]) -> Result<Vec<u8>> {
    decrypt(&blob.encrypted_data, &blob.decryption_header, key)
}

/// Encrypt a JSON value.
///
/// # Arguments
/// * `value` - The value to serialize and encrypt.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// An [`EncryptedBlob`] containing the encrypted JSON.
pub fn encrypt_json<T: serde::Serialize>(value: &T, key: &[u8]) -> Result<EncryptedBlob> {
    let json = serde_json::to_vec(value).map_err(|e| {
        CryptoError::InvalidKeyDerivationParams(format!("JSON serialization failed: {}", e))
    })?;
    encrypt(&json, key)
}

/// Decrypt to a JSON value.
///
/// # Arguments
/// * `blob` - The encrypted blob.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The deserialized JSON value.
pub fn decrypt_json<T: serde::de::DeserializeOwned>(blob: &EncryptedBlob, key: &[u8]) -> Result<T> {
    let plaintext = decrypt_blob(blob, key)?;
    serde_json::from_slice(&plaintext).map_err(|e| {
        CryptoError::InvalidKeyDerivationParams(format!("JSON deserialization failed: {}", e))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"Hello, World!";

        let encrypted = encrypt(plaintext, &key).unwrap();
        assert_eq!(encrypted.decryption_header.len(), HEADER_BYTES);
        assert_eq!(encrypted.encrypted_data.len(), plaintext.len() + ABYTES);

        let decrypted = decrypt_blob(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_decrypt_large() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = vec![0x42u8; 1024 * 1024]; // 1 MB

        let encrypted = encrypt(&plaintext, &key).unwrap();
        let decrypted = decrypt_blob(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_wrong_key_fails() {
        crate::crypto::init().unwrap();
        let key1 = crate::crypto::keys::generate_stream_key();
        let key2 = crate::crypto::keys::generate_stream_key();
        let plaintext = b"Secret message";

        let encrypted = encrypt(plaintext, &key1).unwrap();
        let result = decrypt_blob(&encrypted, &key2);
        assert!(matches!(result, Err(CryptoError::StreamPullFailed)));
    }

    #[test]
    fn test_empty_plaintext() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"";

        let encrypted = encrypt(plaintext, &key).unwrap();
        let decrypted = decrypt_blob(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_decrypt_json() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        #[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq)]
        struct TestData {
            name: String,
            value: i32,
        }

        let data = TestData {
            name: "test".to_string(),
            value: 42,
        };

        let encrypted = encrypt_json(&data, &key).unwrap();
        let decrypted: TestData = decrypt_json(&encrypted, &key).unwrap();
        assert_eq!(decrypted, data);
    }

    #[test]
    fn test_invalid_key_length() {
        crate::crypto::init().unwrap();
        let short_key = vec![0u8; 16];
        let result = encrypt(b"test", &short_key);
        assert!(matches!(result, Err(CryptoError::InvalidKeyLength { .. })));
    }

    #[test]
    fn test_invalid_header_length() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let short_header = vec![0u8; 12];
        let result = decrypt(b"test_ciphertext_here", &short_header, &key);
        assert!(matches!(
            result,
            Err(CryptoError::InvalidHeaderLength { .. })
        ));
    }
}
