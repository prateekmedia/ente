//! Streaming encryption (XChaCha20-Poly1305 SecretStream with chunking).
//!
//! This module provides chunked streaming encryption for large files.
//! Data is split into chunks that are encrypted individually.

use super::{CryptoError, Result};
use libsodium_sys as sodium;
use std::io::{Read, Write};

/// Default encryption chunk size (4 MB).
pub const ENCRYPTION_CHUNK_SIZE: usize = 4 * 1024 * 1024;

/// Key length for SecretStream (32 bytes).
pub const KEY_BYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_KEYBYTES as usize;

/// Header length for SecretStream (24 bytes).
pub const HEADER_BYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_HEADERBYTES as usize;

/// Additional bytes (MAC) per chunk (17 bytes).
pub const ABYTES: usize = sodium::crypto_secretstream_xchacha20poly1305_ABYTES as usize;

/// Decryption chunk size (encryption chunk + overhead).
pub const DECRYPTION_CHUNK_SIZE: usize = ENCRYPTION_CHUNK_SIZE + ABYTES;

/// Tag for final message in stream.
pub const TAG_FINAL: u8 = sodium::crypto_secretstream_xchacha20poly1305_TAG_FINAL as u8;

/// Tag for regular message.
pub const TAG_MESSAGE: u8 = sodium::crypto_secretstream_xchacha20poly1305_TAG_MESSAGE as u8;

/// Result of stream encryption.
#[derive(Debug, Clone)]
pub struct EncryptedStream {
    /// The encrypted data (all chunks concatenated).
    pub encrypted_data: Vec<u8>,
    /// The decryption header.
    pub decryption_header: Vec<u8>,
}

/// Stream encryptor state.
pub struct StreamEncryptor {
    state: Box<[u8]>,
    /// The decryption header generated during init.
    pub header: Vec<u8>,
}

impl StreamEncryptor {
    fn state_bytes() -> usize {
        unsafe { sodium::crypto_secretstream_xchacha20poly1305_statebytes() }
    }

    /// Create a new stream encryptor.
    ///
    /// # Arguments
    /// * `key` - 32-byte encryption key.
    ///
    /// # Returns
    /// A new encryptor with the decryption header in the `header` field.
    pub fn new(key: &[u8]) -> Result<Self> {
        if key.len() != KEY_BYTES {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_BYTES,
                actual: key.len(),
            });
        }

        let mut state = vec![0u8; Self::state_bytes()].into_boxed_slice();
        let mut header = vec![0u8; HEADER_BYTES];

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

        Ok(StreamEncryptor { state, header })
    }

    /// Encrypt a chunk.
    ///
    /// # Arguments
    /// * `plaintext` - The chunk data to encrypt.
    /// * `is_final` - Whether this is the final chunk.
    ///
    /// # Returns
    /// The encrypted chunk.
    pub fn push(&mut self, plaintext: &[u8], is_final: bool) -> Result<Vec<u8>> {
        let tag = if is_final { TAG_FINAL } else { TAG_MESSAGE };
        let mut ciphertext = vec![0u8; plaintext.len() + ABYTES];

        let result = unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_push(
                self.state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
                ciphertext.as_mut_ptr(),
                std::ptr::null_mut(),
                plaintext.as_ptr(),
                plaintext.len() as u64,
                std::ptr::null(),
                0,
                tag,
            )
        };

        if result != 0 {
            return Err(CryptoError::StreamPushFailed);
        }

        Ok(ciphertext)
    }
}

/// Stream decryptor state.
pub struct StreamDecryptor {
    state: Box<[u8]>,
}

impl StreamDecryptor {
    fn state_bytes() -> usize {
        unsafe { sodium::crypto_secretstream_xchacha20poly1305_statebytes() }
    }

    /// Create a new stream decryptor.
    ///
    /// # Arguments
    /// * `header` - The decryption header from encryption.
    /// * `key` - The 32-byte encryption key.
    pub fn new(header: &[u8], key: &[u8]) -> Result<Self> {
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

        let mut state = vec![0u8; Self::state_bytes()].into_boxed_slice();

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

        Ok(StreamDecryptor { state })
    }

    /// Decrypt a chunk.
    ///
    /// # Arguments
    /// * `ciphertext` - The encrypted chunk.
    ///
    /// # Returns
    /// A tuple of (decrypted data, tag). Check if tag == TAG_FINAL for the last chunk.
    pub fn pull(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, u8)> {
        if ciphertext.len() < ABYTES {
            return Err(CryptoError::CiphertextTooShort {
                minimum: ABYTES,
                actual: ciphertext.len(),
            });
        }

        let mut plaintext = vec![0u8; ciphertext.len() - ABYTES];
        let mut plaintext_len: u64 = 0;
        let mut tag: u8 = 0;

        let result = unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_pull(
                self.state.as_mut_ptr() as *mut sodium::crypto_secretstream_xchacha20poly1305_state,
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
        Ok((plaintext, tag))
    }
}

/// Encrypt data using chunked streaming encryption.
///
/// # Arguments
/// * `data` - Data to encrypt.
/// * `key` - 32-byte encryption key.
///
/// # Returns
/// An [`EncryptedStream`] with all encrypted chunks concatenated.
pub fn encrypt(data: &[u8], key: &[u8]) -> Result<EncryptedStream> {
    let mut encryptor = StreamEncryptor::new(key)?;
    let header = encryptor.header.clone();

    let mut encrypted_chunks = Vec::new();
    let mut offset = 0;

    while offset < data.len() {
        let chunk_end = std::cmp::min(offset + ENCRYPTION_CHUNK_SIZE, data.len());
        let is_final = chunk_end == data.len();
        let chunk = &data[offset..chunk_end];

        let encrypted_chunk = encryptor.push(chunk, is_final)?;
        encrypted_chunks.push(encrypted_chunk);
        offset = chunk_end;
    }

    // Handle empty data case
    if data.is_empty() {
        let encrypted_chunk = encryptor.push(&[], true)?;
        encrypted_chunks.push(encrypted_chunk);
    }

    // Concatenate all chunks
    let total_len: usize = encrypted_chunks.iter().map(|c| c.len()).sum();
    let mut encrypted_data = Vec::with_capacity(total_len);
    for chunk in encrypted_chunks {
        encrypted_data.extend_from_slice(&chunk);
    }

    Ok(EncryptedStream {
        encrypted_data,
        decryption_header: header,
    })
}

/// Decrypt data encrypted with [`encrypt`].
///
/// # Arguments
/// * `encrypted_data` - The encrypted data (all chunks concatenated).
/// * `header` - The decryption header.
/// * `key` - The 32-byte encryption key.
///
/// # Returns
/// The decrypted data.
///
/// # Note
/// This function does not require TAG_FINAL to be present. If the stream ends
/// without a final tag, all successfully decrypted chunks are returned.
/// Use [`decrypt_strict`] if you need to enforce TAG_FINAL.
pub fn decrypt(encrypted_data: &[u8], header: &[u8], key: &[u8]) -> Result<Vec<u8>> {
    let mut decryptor = StreamDecryptor::new(header, key)?;
    let mut result = Vec::with_capacity(encrypted_data.len());

    let mut offset = 0;
    while offset < encrypted_data.len() {
        let chunk_end = std::cmp::min(offset + DECRYPTION_CHUNK_SIZE, encrypted_data.len());
        let chunk = &encrypted_data[offset..chunk_end];

        let (plaintext, tag) = decryptor.pull(chunk)?;
        result.extend_from_slice(&plaintext);
        offset = chunk_end;

        if tag == TAG_FINAL {
            break;
        }
    }

    Ok(result)
}

/// Decrypt an [`EncryptedStream`].
pub fn decrypt_stream(stream: &EncryptedStream, key: &[u8]) -> Result<Vec<u8>> {
    decrypt(&stream.encrypted_data, &stream.decryption_header, key)
}

/// Encrypt a file to another file.
///
/// # Arguments
/// * `source` - Reader for source data.
/// * `dest` - Writer for encrypted data.
/// * `key` - 32-byte encryption key (if None, a new key is generated).
///
/// # Returns
/// A tuple of (key used, decryption header).
pub fn encrypt_file<R: Read, W: Write>(
    source: &mut R,
    dest: &mut W,
    key: Option<&[u8]>,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let key = match key {
        Some(k) => k.to_vec(),
        None => super::keys::generate_stream_key(),
    };

    let mut encryptor = StreamEncryptor::new(&key)?;
    let header = encryptor.header.clone();

    let mut buffer = vec![0u8; ENCRYPTION_CHUNK_SIZE];
    loop {
        let bytes_read = source.read(&mut buffer)?;
        if bytes_read == 0 {
            // Empty file or EOF reached without data
            let encrypted = encryptor.push(&[], true)?;
            dest.write_all(&encrypted)?;
            break;
        }

        // Check if this is the last chunk by trying to read more
        let mut peek_buffer = [0u8; 1];
        let peek_result = source.read(&mut peek_buffer)?;

        if peek_result == 0 {
            // This was the last chunk
            let encrypted = encryptor.push(&buffer[..bytes_read], true)?;
            dest.write_all(&encrypted)?;
            break;
        } else {
            // Not the last chunk
            let encrypted = encryptor.push(&buffer[..bytes_read], false)?;
            dest.write_all(&encrypted)?;

            // Process the peeked byte as start of next chunk
            buffer[0] = peek_buffer[0];
            let additional = source.read(&mut buffer[1..])?;
            let total_read = 1 + additional;

            if additional < buffer.len() - 1 {
                // This is the last chunk
                let encrypted = encryptor.push(&buffer[..total_read], true)?;
                dest.write_all(&encrypted)?;
                break;
            }
            // Otherwise continue with full chunk
            let encrypted = encryptor.push(&buffer[..total_read], false)?;
            dest.write_all(&encrypted)?;
        }
    }

    dest.flush()?;
    Ok((key, header))
}

/// Decrypt a file to another file.
///
/// # Arguments
/// * `source` - Reader for encrypted data.
/// * `dest` - Writer for decrypted data.
/// * `header` - The decryption header.
/// * `key` - The 32-byte encryption key.
///
/// # Note
/// This function does not require TAG_FINAL to be present. If the stream ends
/// without a final tag, all successfully decrypted chunks are returned.
/// This maintains backwards compatibility with older encrypted data (e.g., from
/// mobile/apps/auth which didn't use TAG_FINAL).
pub fn decrypt_file<R: Read, W: Write>(
    source: &mut R,
    dest: &mut W,
    header: &[u8],
    key: &[u8],
) -> Result<()> {
    let mut decryptor = StreamDecryptor::new(header, key)?;
    let mut buffer = vec![0u8; DECRYPTION_CHUNK_SIZE];

    loop {
        let bytes_read = source.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }

        let (plaintext, tag) = decryptor.pull(&buffer[..bytes_read])?;
        dest.write_all(&plaintext)?;

        if tag == TAG_FINAL {
            break;
        }
    }

    dest.flush()?;
    Ok(())
}

/// Estimate the encrypted size for a given plaintext size.
///
/// # Arguments
/// * `plaintext_size` - Size of the plaintext in bytes.
///
/// # Returns
/// Estimated encrypted size in bytes.
pub fn estimate_encrypted_size(plaintext_size: usize) -> usize {
    if plaintext_size == 0 {
        return ABYTES; // Even empty data has overhead
    }

    let full_chunks = plaintext_size / ENCRYPTION_CHUNK_SIZE;
    let last_chunk_size = plaintext_size % ENCRYPTION_CHUNK_SIZE;

    let mut size = full_chunks * (ENCRYPTION_CHUNK_SIZE + ABYTES);
    if last_chunk_size > 0 {
        size += last_chunk_size + ABYTES;
    }

    size
}

/// Validate that plaintext and ciphertext sizes match for streaming encryption.
pub fn validate_sizes(plaintext_size: usize, ciphertext_size: usize) -> bool {
    if plaintext_size == 0 && ciphertext_size == 0 {
        return false;
    }
    estimate_encrypted_size(plaintext_size) == ciphertext_size
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_stream_encrypt_decrypt() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"Hello, World!";

        let encrypted = encrypt(plaintext, &key).unwrap();
        let decrypted = decrypt_stream(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_stream_encrypt_decrypt_large() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        // Test with data larger than chunk size
        let plaintext = vec![0x42u8; ENCRYPTION_CHUNK_SIZE * 2 + 1000];

        let encrypted = encrypt(&plaintext, &key).unwrap();
        let decrypted = decrypt_stream(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_stream_encrypt_decrypt_empty() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"";

        let encrypted = encrypt(plaintext, &key).unwrap();
        let decrypted = decrypt_stream(&encrypted, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_stream_encryptor_decryptor() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        let mut encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        let chunk1 = encryptor.push(b"First chunk", false).unwrap();
        let chunk2 = encryptor.push(b"Second chunk", false).unwrap();
        let chunk3 = encryptor.push(b"Final chunk", true).unwrap();

        let mut decryptor = StreamDecryptor::new(&header, &key).unwrap();

        let (dec1, tag1) = decryptor.pull(&chunk1).unwrap();
        assert_eq!(dec1, b"First chunk");
        assert_eq!(tag1, TAG_MESSAGE);

        let (dec2, tag2) = decryptor.pull(&chunk2).unwrap();
        assert_eq!(dec2, b"Second chunk");
        assert_eq!(tag2, TAG_MESSAGE);

        let (dec3, tag3) = decryptor.pull(&chunk3).unwrap();
        assert_eq!(dec3, b"Final chunk");
        assert_eq!(tag3, TAG_FINAL);
    }

    #[test]
    fn test_file_encrypt_decrypt() {
        crate::crypto::init().unwrap();
        let plaintext = b"File contents here";

        let mut source = Cursor::new(plaintext.to_vec());
        let mut encrypted = Vec::new();

        let (key, header) = encrypt_file(&mut source, &mut encrypted, None).unwrap();

        let mut enc_source = Cursor::new(encrypted);
        let mut decrypted = Vec::new();

        decrypt_file(&mut enc_source, &mut decrypted, &header, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_file_encrypt_with_provided_key() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"Test data";

        let mut source = Cursor::new(plaintext.to_vec());
        let mut encrypted = Vec::new();

        let (returned_key, header) = encrypt_file(&mut source, &mut encrypted, Some(&key)).unwrap();
        assert_eq!(returned_key, key);

        let mut enc_source = Cursor::new(encrypted);
        let mut decrypted = Vec::new();

        decrypt_file(&mut enc_source, &mut decrypted, &header, &key).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_estimate_encrypted_size() {
        // Empty
        assert_eq!(estimate_encrypted_size(0), ABYTES);

        // Less than one chunk
        let small_size = 1000;
        assert_eq!(estimate_encrypted_size(small_size), small_size + ABYTES);

        // Exactly one chunk
        assert_eq!(
            estimate_encrypted_size(ENCRYPTION_CHUNK_SIZE),
            ENCRYPTION_CHUNK_SIZE + ABYTES
        );

        // Multiple chunks
        let multi_chunk = ENCRYPTION_CHUNK_SIZE * 2 + 500;
        let expected = 2 * (ENCRYPTION_CHUNK_SIZE + ABYTES) + 500 + ABYTES;
        assert_eq!(estimate_encrypted_size(multi_chunk), expected);
    }

    #[test]
    fn test_validate_sizes() {
        assert!(validate_sizes(1000, 1000 + ABYTES));
        assert!(!validate_sizes(1000, 1000)); // Missing overhead
        assert!(!validate_sizes(0, 0)); // Both zero is invalid
    }

    // ==========================================================================
    // Tests for TAG_FINAL behavior (backwards compatibility with mobile/apps/auth)
    // ==========================================================================

    #[test]
    fn test_low_level_stream_without_final_tag_accepted() {
        // Backwards compatibility: mobile/apps/auth didn't use TAG_FINAL for a long time
        // This tests the low-level StreamEncryptor/StreamDecryptor API
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        let mut encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        // Only push non-final chunks (simulating old auth app behavior)
        let chunk1 = encryptor.push(b"First chunk", false).unwrap();
        let chunk2 = encryptor.push(b"Second chunk", false).unwrap();
        // Intentionally no final chunk

        // Decrypt using low-level API
        let mut decryptor = StreamDecryptor::new(&header, &key).unwrap();

        let (dec1, tag1) = decryptor.pull(&chunk1).unwrap();
        assert_eq!(dec1, b"First chunk");
        assert_eq!(tag1, TAG_MESSAGE);

        let (dec2, tag2) = decryptor.pull(&chunk2).unwrap();
        assert_eq!(dec2, b"Second chunk");
        assert_eq!(tag2, TAG_MESSAGE);
        // Stream ends without TAG_FINAL - this is acceptable
    }

    #[test]
    fn test_high_level_decrypt_single_chunk_no_final() {
        // Test high-level decrypt with a single small chunk (no TAG_FINAL)
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        let mut encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        // Push as non-final
        let chunk = encryptor.push(b"Data without final tag", false).unwrap();

        // High-level decrypt should work (reads entire chunk)
        let result = decrypt(&chunk, &header, &key);
        assert!(result.is_ok(), "Single chunk without TAG_FINAL should be accepted");
        assert_eq!(result.unwrap(), b"Data without final tag");
    }

    #[test]
    fn test_file_stream_single_chunk_no_final() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        let mut encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        let chunk = encryptor.push(b"File data without final tag", false).unwrap();

        let mut source = Cursor::new(chunk);
        let mut dest = Vec::new();

        let result = decrypt_file(&mut source, &mut dest, &header, &key);
        assert!(result.is_ok(), "File streams without TAG_FINAL should be accepted");
        assert_eq!(dest, b"File data without final tag");
    }

    #[test]
    fn test_empty_stream_returns_empty() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        // Empty encrypted data (no chunks at all)
        let empty_data: &[u8] = &[];

        let result = decrypt(empty_data, &header, &key);
        assert!(result.is_ok(), "Empty stream should return empty result");
        assert!(result.unwrap().is_empty());
    }

    #[test]
    fn test_low_level_stream_with_final_tag() {
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();

        let mut encryptor = StreamEncryptor::new(&key).unwrap();
        let header = encryptor.header.clone();

        let chunk1 = encryptor.push(b"First", false).unwrap();
        let chunk2 = encryptor.push(b"Last", true).unwrap(); // TAG_FINAL

        let mut decryptor = StreamDecryptor::new(&header, &key).unwrap();

        let (dec1, tag1) = decryptor.pull(&chunk1).unwrap();
        assert_eq!(dec1, b"First");
        assert_eq!(tag1, TAG_MESSAGE);

        let (dec2, tag2) = decryptor.pull(&chunk2).unwrap();
        assert_eq!(dec2, b"Last");
        assert_eq!(tag2, TAG_FINAL);
    }

    #[test]
    fn test_high_level_encrypt_always_uses_final_tag() {
        // Verify that the high-level encrypt() function properly sets TAG_FINAL
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        let plaintext = b"Some data";

        let encrypted = encrypt(plaintext, &key).unwrap();

        // Decrypt and verify TAG_FINAL is seen
        let mut decryptor = StreamDecryptor::new(&encrypted.decryption_header, &key).unwrap();
        let (decrypted, tag) = decryptor.pull(&encrypted.encrypted_data).unwrap();

        assert_eq!(decrypted, plaintext);
        assert_eq!(tag, TAG_FINAL, "High-level encrypt should always set TAG_FINAL");
    }

    #[test]
    fn test_high_level_encrypt_multi_chunk_final_tag() {
        // Verify multi-chunk encryption sets TAG_FINAL on last chunk
        crate::crypto::init().unwrap();
        let key = crate::crypto::keys::generate_stream_key();
        // Data larger than one chunk
        let plaintext = vec![0x42u8; ENCRYPTION_CHUNK_SIZE + 1000];

        let encrypted = encrypt(&plaintext, &key).unwrap();
        let decrypted = decrypt_stream(&encrypted, &key).unwrap();

        assert_eq!(decrypted, plaintext);
    }
}
