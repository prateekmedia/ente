//! SecretBox encryption (XSalsa20-Poly1305).
//!
//! This module provides symmetric encryption using libsodium's secretbox APIs.
//! Use this for encrypting independent blobs of data with a shared key.

use super::{CryptoError, Result};
use libsodium_sys as sodium;

/// Key length for SecretBox (32 bytes).
pub const KEY_BYTES: usize = sodium::crypto_secretbox_KEYBYTES as usize;

/// Nonce length for SecretBox (24 bytes).
pub const NONCE_BYTES: usize = sodium::crypto_secretbox_NONCEBYTES as usize;

/// MAC (authentication tag) length (16 bytes).
pub const MAC_BYTES: usize = sodium::crypto_secretbox_MACBYTES as usize;

/// Result of SecretBox encryption.
#[derive(Debug, Clone)]
pub struct EncryptedBox {
    /// The encrypted data (ciphertext + MAC).
    pub encrypted_data: Vec<u8>,
    /// The nonce used for encryption.
    pub nonce: Vec<u8>,
}

/// Encrypt data using SecretBox (XSalsa20-Poly1305).
///
/// # Arguments
/// * `plaintext` - Data to encrypt.
/// * `key` - 32-byte encryption key.
///
/// # Returns
/// An [`EncryptedBox`] containing the ciphertext and randomly generated nonce.
pub fn encrypt(plaintext: &[u8], key: &[u8]) -> Result<EncryptedBox> {
    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    let nonce = super::keys::generate_secretbox_nonce();
    let encrypted_data = encrypt_with_nonce(plaintext, &nonce, key)?;

    Ok(EncryptedBox {
        encrypted_data,
        nonce,
    })
}

/// Encrypt data with a specific nonce.
///
/// # Arguments
/// * `plaintext` - Data to encrypt.
/// * `nonce` - 24-byte nonce (must be unique per key).
/// * `key` - 32-byte encryption key.
///
/// # Returns
/// The ciphertext (encrypted data + MAC).
pub fn encrypt_with_nonce(plaintext: &[u8], nonce: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    if nonce.len() != NONCE_BYTES {
        return Err(CryptoError::InvalidNonceLength {
            expected: NONCE_BYTES,
            actual: nonce.len(),
        });
    }

    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    let mut ciphertext = vec![0u8; plaintext.len() + MAC_BYTES];

    let result = unsafe {
        sodium::crypto_secretbox_easy(
            ciphertext.as_mut_ptr(),
            plaintext.as_ptr(),
            plaintext.len() as u64,
            nonce.as_ptr(),
            key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::EncryptionFailed);
    }

    Ok(ciphertext)
}

/// Decrypt data encrypted with SecretBox.
///
/// # Arguments
/// * `ciphertext` - The encrypted data (including MAC).
/// * `nonce` - The 24-byte nonce used during encryption.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The decrypted plaintext.
pub fn decrypt(ciphertext: &[u8], nonce: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    if nonce.len() != NONCE_BYTES {
        return Err(CryptoError::InvalidNonceLength {
            expected: NONCE_BYTES,
            actual: nonce.len(),
        });
    }

    if key.len() != KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: KEY_BYTES,
            actual: key.len(),
        });
    }

    if ciphertext.len() < MAC_BYTES {
        return Err(CryptoError::CiphertextTooShort {
            minimum: MAC_BYTES,
            actual: ciphertext.len(),
        });
    }

    let mut plaintext = vec![0u8; ciphertext.len() - MAC_BYTES];

    let result = unsafe {
        sodium::crypto_secretbox_open_easy(
            plaintext.as_mut_ptr(),
            ciphertext.as_ptr(),
            ciphertext.len() as u64,
            nonce.as_ptr(),
            key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::DecryptionFailed);
    }

    Ok(plaintext)
}

/// Decrypt an [`EncryptedBox`].
///
/// # Arguments
/// * `encrypted_box` - The encrypted box containing ciphertext and nonce.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The decrypted plaintext.
pub fn decrypt_box(encrypted_box: &EncryptedBox, key: &[u8]) -> Result<Vec<u8>> {
    decrypt(&encrypted_box.encrypted_data, &encrypted_box.nonce, key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let plaintext = b"Hello, World!";

        let encrypted = encrypt(plaintext, &key).unwrap();
        assert_eq!(encrypted.nonce.len(), NONCE_BYTES);
        assert_eq!(encrypted.encrypted_data.len(), plaintext.len() + MAC_BYTES);

        let decrypted = decrypt_box(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_encrypt_with_nonce() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let nonce = crate::crypto::keys::generate_secretbox_nonce();
        let plaintext = b"Test data";

        let ciphertext = encrypt_with_nonce(plaintext, &nonce, &key).unwrap();
        let decrypted = decrypt(&ciphertext, &nonce, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_wrong_key_fails() {
        crate::crypto::init().unwrap();
        let key1 = crate::crypto::keys::generate_key();
        let key2 = crate::crypto::keys::generate_key();
        let plaintext = b"Secret message";

        let encrypted = encrypt(plaintext, &key1).unwrap();
        let result = decrypt_box(&encrypted, &key2);
        assert!(matches!(result, Err(CryptoError::DecryptionFailed)));
    }

    #[test]
    fn test_wrong_nonce_fails() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let plaintext = b"Secret message";

        let encrypted = encrypt(plaintext, &key).unwrap();
        let wrong_nonce = crate::crypto::keys::generate_secretbox_nonce();
        let result = decrypt(&encrypted.encrypted_data, &wrong_nonce, &key);
        assert!(matches!(result, Err(CryptoError::DecryptionFailed)));
    }

    #[test]
    fn test_empty_plaintext() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let plaintext = b"";

        let encrypted = encrypt(plaintext, &key).unwrap();
        let decrypted = decrypt_box(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_invalid_key_length() {
        crate::crypto::init().unwrap();
        let short_key = vec![0u8; 16];
        let result = encrypt(b"test", &short_key);
        assert!(matches!(result, Err(CryptoError::InvalidKeyLength { .. })));
    }

    #[test]
    fn test_invalid_nonce_length() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let short_nonce = vec![0u8; 12];
        let result = encrypt_with_nonce(b"test", &short_nonce, &key);
        assert!(matches!(
            result,
            Err(CryptoError::InvalidNonceLength { .. })
        ));
    }

    #[test]
    fn test_ciphertext_too_short() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_key();
        let nonce = crate::crypto::keys::generate_secretbox_nonce();
        let short_ciphertext = vec![0u8; 8];
        let result = decrypt(&short_ciphertext, &nonce, &key);
        assert!(matches!(
            result,
            Err(CryptoError::CiphertextTooShort { .. })
        ));
    }
}
