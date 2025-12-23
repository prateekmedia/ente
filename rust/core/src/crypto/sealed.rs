//! Sealed box (anonymous public-key encryption).
//!
//! This module provides asymmetric encryption where the sender can encrypt
//! a message for a recipient given only the recipient's public key.

use super::{CryptoError, Result};
use libsodium_sys as sodium;

/// Public key length (32 bytes).
pub const PUBLIC_KEY_BYTES: usize = sodium::crypto_box_PUBLICKEYBYTES as usize;

/// Secret key length (32 bytes).
pub const SECRET_KEY_BYTES: usize = sodium::crypto_box_SECRETKEYBYTES as usize;

/// Sealed box overhead (48 bytes).
pub const SEAL_BYTES: usize = sodium::crypto_box_SEALBYTES as usize;

/// Encrypt data for a recipient using their public key (sealed box).
///
/// The sender remains anonymous - only the recipient can decrypt.
///
/// # Arguments
/// * `plaintext` - Data to encrypt.
/// * `public_key` - Recipient's 32-byte public key.
///
/// # Returns
/// The encrypted data (ciphertext + overhead).
pub fn seal(plaintext: &[u8], public_key: &[u8]) -> Result<Vec<u8>> {
    if public_key.len() != PUBLIC_KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: PUBLIC_KEY_BYTES,
            actual: public_key.len(),
        });
    }

    let mut ciphertext = vec![0u8; plaintext.len() + SEAL_BYTES];

    let result = unsafe {
        sodium::crypto_box_seal(
            ciphertext.as_mut_ptr(),
            plaintext.as_ptr(),
            plaintext.len() as u64,
            public_key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::EncryptionFailed);
    }

    Ok(ciphertext)
}

/// Decrypt a sealed box using the recipient's key pair.
///
/// # Arguments
/// * `ciphertext` - The encrypted data (including overhead).
/// * `public_key` - Recipient's 32-byte public key.
/// * `secret_key` - Recipient's 32-byte secret key.
///
/// # Returns
/// The decrypted plaintext.
pub fn open(ciphertext: &[u8], public_key: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    if public_key.len() != PUBLIC_KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: PUBLIC_KEY_BYTES,
            actual: public_key.len(),
        });
    }

    if secret_key.len() != SECRET_KEY_BYTES {
        return Err(CryptoError::InvalidKeyLength {
            expected: SECRET_KEY_BYTES,
            actual: secret_key.len(),
        });
    }

    if ciphertext.len() < SEAL_BYTES {
        return Err(CryptoError::CiphertextTooShort {
            minimum: SEAL_BYTES,
            actual: ciphertext.len(),
        });
    }

    let mut plaintext = vec![0u8; ciphertext.len() - SEAL_BYTES];

    let result = unsafe {
        sodium::crypto_box_seal_open(
            plaintext.as_mut_ptr(),
            ciphertext.as_ptr(),
            ciphertext.len() as u64,
            public_key.as_ptr(),
            secret_key.as_ptr(),
        )
    };

    if result != 0 {
        return Err(CryptoError::SealedBoxOpenFailed);
    }

    Ok(plaintext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_seal_open() {
        crate::crypto::init().unwrap();
        let (public_key, secret_key) = crate::crypto::keys::generate_keypair().unwrap();
        let plaintext = b"Hello, World!";

        let ciphertext = seal(plaintext, &public_key).unwrap();
        assert_eq!(ciphertext.len(), plaintext.len() + SEAL_BYTES);

        let decrypted = open(&ciphertext, &public_key, &secret_key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_seal_open_large() {
        crate::crypto::init().unwrap();
        let (public_key, secret_key) = crate::crypto::keys::generate_keypair().unwrap();
        let plaintext = vec![0x42u8; 10000];

        let ciphertext = seal(&plaintext, &public_key).unwrap();
        let decrypted = open(&ciphertext, &public_key, &secret_key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_seal_open_empty() {
        crate::crypto::init().unwrap();
        let (public_key, secret_key) = crate::crypto::keys::generate_keypair().unwrap();
        let plaintext = b"";

        let ciphertext = seal(plaintext, &public_key).unwrap();
        let decrypted = open(&ciphertext, &public_key, &secret_key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_wrong_keys_fail() {
        crate::crypto::init().unwrap();
        let (public_key1, _) = crate::crypto::keys::generate_keypair().unwrap();
        let (public_key2, secret_key2) = crate::crypto::keys::generate_keypair().unwrap();
        let plaintext = b"Secret message";

        // Encrypt with key1's public key
        let ciphertext = seal(plaintext, &public_key1).unwrap();

        // Try to decrypt with key2's keys
        let result = open(&ciphertext, &public_key2, &secret_key2);
        assert!(matches!(result, Err(CryptoError::SealedBoxOpenFailed)));
    }

    #[test]
    fn test_invalid_public_key_length() {
        crate::crypto::init().unwrap();
        let short_key = vec![0u8; 16];
        let result = seal(b"test", &short_key);
        assert!(matches!(result, Err(CryptoError::InvalidKeyLength { .. })));
    }

    #[test]
    fn test_ciphertext_too_short() {
        crate::crypto::init().unwrap();
        let (public_key, secret_key) = crate::crypto::keys::generate_keypair().unwrap();
        let short_ciphertext = vec![0u8; 10];
        let result = open(&short_ciphertext, &public_key, &secret_key);
        assert!(matches!(
            result,
            Err(CryptoError::CiphertextTooShort { .. })
        ));
    }

    #[test]
    fn test_different_ciphertexts_for_same_plaintext() {
        crate::crypto::init().unwrap();
        let (public_key, _) = crate::crypto::keys::generate_keypair().unwrap();
        let plaintext = b"Same message";

        // Each encryption should produce different ciphertext (due to ephemeral key)
        let ciphertext1 = seal(plaintext, &public_key).unwrap();
        let ciphertext2 = seal(plaintext, &public_key).unwrap();
        assert_ne!(ciphertext1, ciphertext2);
    }
}
