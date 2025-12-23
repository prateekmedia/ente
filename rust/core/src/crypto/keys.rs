//! Key generation utilities.

use super::Result;
use libsodium_sys as sodium;

/// Generate a new random 256-bit key suitable for SecretBox encryption.
///
/// This key can be used with [`super::secretbox::encrypt`] and [`super::secretbox::decrypt`].
///
/// # Returns
/// A 32-byte (256-bit) random key.
pub fn generate_key() -> Vec<u8> {
    let mut key = vec![0u8; sodium::crypto_secretbox_KEYBYTES as usize];
    unsafe {
        sodium::crypto_secretbox_keygen(key.as_mut_ptr());
    }
    key
}

/// Generate a new random 256-bit key suitable for SecretStream encryption.
///
/// This key can be used with blob and stream encryption functions.
///
/// # Returns
/// A 32-byte (256-bit) random key.
pub fn generate_stream_key() -> Vec<u8> {
    let mut key = vec![0u8; sodium::crypto_secretstream_xchacha20poly1305_KEYBYTES as usize];
    unsafe {
        sodium::crypto_secretstream_xchacha20poly1305_keygen(key.as_mut_ptr());
    }
    key
}

/// Generate a random salt suitable for key derivation.
///
/// # Returns
/// A 16-byte random salt.
pub fn generate_salt() -> Vec<u8> {
    let mut salt = vec![0u8; sodium::crypto_pwhash_SALTBYTES as usize];
    unsafe {
        sodium::randombytes_buf(salt.as_mut_ptr() as *mut _, salt.len());
    }
    salt
}

/// Generate a random nonce suitable for SecretBox encryption.
///
/// # Returns
/// A 24-byte random nonce.
pub fn generate_secretbox_nonce() -> Vec<u8> {
    let mut nonce = vec![0u8; sodium::crypto_secretbox_NONCEBYTES as usize];
    unsafe {
        sodium::randombytes_buf(nonce.as_mut_ptr() as *mut _, nonce.len());
    }
    nonce
}

/// Generate a new public/private key pair for asymmetric encryption.
///
/// # Returns
/// A tuple of (public_key, secret_key), both as byte vectors.
pub fn generate_keypair() -> Result<(Vec<u8>, Vec<u8>)> {
    let mut public_key = vec![0u8; sodium::crypto_box_PUBLICKEYBYTES as usize];
    let mut secret_key = vec![0u8; sodium::crypto_box_SECRETKEYBYTES as usize];

    let result =
        unsafe { sodium::crypto_box_keypair(public_key.as_mut_ptr(), secret_key.as_mut_ptr()) };

    if result != 0 {
        return Err(super::CryptoError::EncryptionFailed);
    }

    Ok((public_key, secret_key))
}

/// Fill a buffer with random bytes.
///
/// # Arguments
/// * `len` - Number of random bytes to generate.
///
/// # Returns
/// A vector of `len` random bytes.
pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut buf = vec![0u8; len];
    unsafe {
        sodium::randombytes_buf(buf.as_mut_ptr() as *mut _, len);
    }
    buf
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_key() {
        crate::crypto::init().unwrap();
        let key = generate_key();
        assert_eq!(key.len(), 32);

        // Keys should be unique
        let key2 = generate_key();
        assert_ne!(key, key2);
    }

    #[test]
    fn test_generate_stream_key() {
        crate::crypto::init().unwrap();
        let key = generate_stream_key();
        assert_eq!(key.len(), 32);
    }

    #[test]
    fn test_generate_salt() {
        crate::crypto::init().unwrap();
        let salt = generate_salt();
        assert_eq!(salt.len(), 16);
    }

    #[test]
    fn test_generate_secretbox_nonce() {
        crate::crypto::init().unwrap();
        let nonce = generate_secretbox_nonce();
        assert_eq!(nonce.len(), 24);
    }

    #[test]
    fn test_generate_keypair() {
        crate::crypto::init().unwrap();
        let (public_key, secret_key) = generate_keypair().unwrap();
        assert_eq!(public_key.len(), 32);
        assert_eq!(secret_key.len(), 32);
    }

    #[test]
    fn test_random_bytes() {
        crate::crypto::init().unwrap();
        let bytes = random_bytes(64);
        assert_eq!(bytes.len(), 64);

        // Should be unique
        let bytes2 = random_bytes(64);
        assert_ne!(bytes, bytes2);
    }
}
