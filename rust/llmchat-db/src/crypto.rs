use crate::{Error, Result};
use ente_core::crypto::{self, blob};

pub const HEADER_BYTES: usize = blob::HEADER_BYTES;
pub const KEY_BYTES: usize = blob::KEY_BYTES;

const ENCRYPTED_NAME_PREFIX: &str = "enc:v1:";

pub fn encrypt_blob_field(plaintext: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    let encrypted = blob::encrypt(plaintext, key)?;
    let mut out =
        Vec::with_capacity(encrypted.decryption_header.len() + encrypted.encrypted_data.len());
    out.extend_from_slice(&encrypted.decryption_header);
    out.extend_from_slice(&encrypted.encrypted_data);
    Ok(out)
}

pub fn decrypt_blob_field(blob_data: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    if blob_data.len() < HEADER_BYTES {
        return Err(Error::InvalidBlobLength {
            len: blob_data.len(),
        });
    }
    let (header, ciphertext) = blob_data.split_at(HEADER_BYTES);
    Ok(blob::decrypt(ciphertext, header, key)?)
}

pub fn encrypt_name(plaintext: &str, key: &[u8]) -> Result<String> {
    let encrypted = blob::encrypt(plaintext.as_bytes(), key)?;
    let ciphertext_b64 = crypto::encode_b64(&encrypted.encrypted_data);
    let header_b64 = crypto::encode_b64(&encrypted.decryption_header);
    Ok(format!(
        "{}{}:{}",
        ENCRYPTED_NAME_PREFIX, ciphertext_b64, header_b64
    ))
}

pub fn decrypt_name(encrypted_name: &str, key: &[u8]) -> Result<String> {
    let remainder = encrypted_name
        .strip_prefix(ENCRYPTED_NAME_PREFIX)
        .ok_or(Error::InvalidEncryptedName)?;
    let mut parts = remainder.split(':');
    let ciphertext_b64 = parts.next().ok_or(Error::InvalidEncryptedName)?;
    let header_b64 = parts.next().ok_or(Error::InvalidEncryptedName)?;
    if parts.next().is_some() {
        return Err(Error::InvalidEncryptedName);
    }
    let ciphertext = crypto::decode_b64(ciphertext_b64)?;
    let header = crypto::decode_b64(header_b64)?;
    let plaintext = blob::decrypt(&ciphertext, &header, key)?;
    Ok(String::from_utf8(plaintext)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_blob_roundtrip() {
        let key = vec![7u8; KEY_BYTES];
        let plaintext = b"hello";
        let encrypted = encrypt_blob_field(plaintext, &key).unwrap();
        assert!(encrypted.len() > HEADER_BYTES);
        let decrypted = decrypt_blob_field(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_name_roundtrip() {
        let key = vec![9u8; KEY_BYTES];
        let encrypted = encrypt_name("file.txt", &key).unwrap();
        assert!(encrypted.starts_with(ENCRYPTED_NAME_PREFIX));
        let decrypted = decrypt_name(&encrypted, &key).unwrap();
        assert_eq!(decrypted, "file.txt");
    }
}
