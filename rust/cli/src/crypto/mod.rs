//! Crypto module - wraps ente-core crypto functionality
//!
//! This module provides a thin wrapper around ente-core's pure Rust
//! cryptography implementation. All crypto operations are performed
//! by ente-core.

use crate::{Error, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};

// Re-export stream types from ente-core
pub use ente_core::crypto::stream::{StreamDecryptor, StreamEncryptor, TAG_FINAL, TAG_MESSAGE};

/// Initialize crypto subsystem. Must be called before any crypto operations.
pub fn init() -> Result<()> {
    ente_core::crypto::init().map_err(|e| Error::Crypto(e.to_string()))
}

/// Decode base64 string to bytes
pub fn decode_base64(input: &str) -> Result<Vec<u8>> {
    Ok(BASE64.decode(input)?)
}

/// Encode bytes to base64 string
pub fn encode_base64(input: &[u8]) -> String {
    BASE64.encode(input)
}

// =============================================================================
// Argon2id Key Derivation
// =============================================================================

/// Derive a key using Argon2id algorithm
///
/// # Arguments
/// * `password` - The password string
/// * `salt` - Base64-encoded salt (16 bytes when decoded)
/// * `mem_limit` - Memory limit in bytes
/// * `ops_limit` - Number of iterations
pub fn derive_argon_key(
    password: &str,
    salt: &str,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>> {
    let salt_bytes = decode_base64(salt)?;

    if salt_bytes.len() != 16 {
        return Err(Error::Crypto(format!(
            "Invalid salt length: expected 16, got {}",
            salt_bytes.len()
        )));
    }

    ente_core::crypto::argon::derive_key(password, &salt_bytes, mem_limit, ops_limit)
        .map_err(|e| Error::Crypto(e.to_string()))
}

// =============================================================================
// KDF - Login Key Derivation
// =============================================================================

/// Derive login key from key encryption key
///
/// Returns first 16 bytes of derived key (matching web implementation)
pub fn derive_login_key(key_enc_key: &[u8]) -> Result<Vec<u8>> {
    ente_core::crypto::kdf::derive_login_key(key_enc_key).map_err(|e| Error::Crypto(e.to_string()))
}

// =============================================================================
// SecretBox (XSalsa20-Poly1305)
// =============================================================================

/// Open a secret box (decrypt with XSalsa20-Poly1305)
pub fn secret_box_open(ciphertext: &[u8], nonce: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    ente_core::crypto::secretbox::decrypt(ciphertext, nonce, key)
        .map_err(|e| Error::Crypto(e.to_string()))
}

/// Seal a secret box (encrypt with XSalsa20-Poly1305)
pub fn secret_box_seal(plaintext: &[u8], nonce: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    ente_core::crypto::secretbox::encrypt_with_nonce(plaintext, nonce, key)
        .map_err(|e| Error::Crypto(e.to_string()))
}

// =============================================================================
// Sealed Box (X25519 + XSalsa20-Poly1305)
// =============================================================================

/// Open a sealed box (decrypt with public key crypto)
pub fn sealed_box_open(ciphertext: &[u8], public_key: &[u8], secret_key: &[u8]) -> Result<Vec<u8>> {
    ente_core::crypto::sealed::open(ciphertext, public_key, secret_key)
        .map_err(|e| Error::Crypto(e.to_string()))
}

// =============================================================================
// Stream Encryption (XChaCha20-Poly1305 secretstream)
// =============================================================================

/// Decrypt data using streaming XChaCha20-Poly1305
/// This is for single-chunk decryption (most common case for files)
pub fn decrypt_stream(ciphertext: &[u8], header: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    ente_core::crypto::stream::decrypt(header, ciphertext, key)
        .map_err(|e| Error::Crypto(e.to_string()))
}

/// Decrypt file data from memory using streaming cipher with chunking for large files
///
/// Handles multi-chunk encrypted data where each chunk is 4MB + 17 bytes overhead
pub fn decrypt_file_data(encrypted_data: &[u8], header: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    // Buffer size matching Go implementation: 4MB + 17 bytes overhead
    const CHUNK_SIZE: usize = 4 * 1024 * 1024 + ente_core::crypto::stream::ABYTES;

    let mut decryptor = ente_core::crypto::stream::StreamDecryptor::new(header, key)
        .map_err(|e| Error::Crypto(e.to_string()))?;

    let mut result = Vec::with_capacity(encrypted_data.len());

    let mut offset = 0;
    while offset < encrypted_data.len() {
        let chunk_end = std::cmp::min(offset + CHUNK_SIZE, encrypted_data.len());
        let chunk = &encrypted_data[offset..chunk_end];

        let (plaintext, tag) = decryptor.pull(chunk).map_err(|e| Error::Crypto(e.to_string()))?;
        result.extend_from_slice(&plaintext);

        offset = chunk_end;

        // Check if this was the final chunk
        if tag == TAG_FINAL {
            break;
        }
    }

    Ok(result)
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_argon_key_derivation() {
        init().unwrap();

        let password = "test_password";
        let salt_bytes = [0x42u8; 16];
        let salt_b64 = encode_base64(&salt_bytes);

        let key = derive_argon_key(password, &salt_b64, 67108864, 2).unwrap();
        assert_eq!(key.len(), 32);

        // Verify deterministic
        let key2 = derive_argon_key(password, &salt_b64, 67108864, 2).unwrap();
        assert_eq!(key, key2);
    }

    #[test]
    fn test_login_key_derivation() {
        init().unwrap();

        let master_key = hex::decode(
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        )
        .unwrap();

        let login_key = derive_login_key(&master_key).unwrap();
        assert_eq!(login_key.len(), 16);

        // Known value from libsodium
        let expected = hex::decode("6970b5d34442fd11788a83b4b57e1e72").unwrap();
        assert_eq!(login_key, expected);
    }

    #[test]
    fn test_secretbox_roundtrip() {
        init().unwrap();

        let key = [0x42u8; 32];
        let nonce = [0x24u8; 24];
        let plaintext = b"Hello, World!";

        let ciphertext = secret_box_seal(plaintext, &nonce, &key).unwrap();
        let decrypted = secret_box_open(&ciphertext, &nonce, &key).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_sealed_box_roundtrip() {
        init().unwrap();

        let (public_key, secret_key) = ente_core::crypto::keys::generate_keypair().unwrap();
        let plaintext = b"Sealed message";

        let ciphertext = ente_core::crypto::sealed::seal(plaintext, &public_key).unwrap();
        let decrypted = sealed_box_open(&ciphertext, &public_key, &secret_key).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_stream_roundtrip() {
        init().unwrap();

        let key = [0x42u8; 32];
        let plaintext = b"Stream test data";

        // Encrypt
        let (header, ciphertext) = ente_core::crypto::stream::encrypt(plaintext, &key).unwrap();

        // Decrypt
        let decrypted = decrypt_stream(&ciphertext, &header, &key).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_base64_roundtrip() {
        let data = b"Hello, World!";
        let encoded = encode_base64(data);
        let decoded = decode_base64(&encoded).unwrap();
        assert_eq!(decoded, data);
    }
}
