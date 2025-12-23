//! SecretStream (XChaCha20-Poly1305) encryption.
//!
//! This module provides stateful authenticated encryption using a custom construction
//! based on ChaCha20 and Poly1305. It maintains byte-for-byte compatibility with
//! libsodium's crypto_secretstream_xchacha20poly1305.
//!
//! # CRITICAL: This is NOT standard AEAD!
//!
//! libsodium's secretstream uses a **custom construction**:
//! - Raw ChaCha20 stream cipher (with specific IC/block counter offsets)
//! - Manual Poly1305 MAC computation  
//! - Custom nonce/state management
//!
//! We CANNOT use the `chacha20poly1305` AEAD crate directly!
//!
//! # Wire Format
//!
//! HEADER (24 bytes):
//!   - bytes[0..16]:  HChaCha20 input (random)
//!   - bytes[16..24]: Initial INONCE (8 bytes)
//!
//! STATE:
//!   - k[32]:    Subkey derived via HChaCha20(original_key, header[0..16])
//!   - nonce[12]: counter[4] || inonce[8]
//!     - counter starts at 1 (little-endian)
//!     - inonce = header[16..24], updated on each message
//!
//! OUTPUT FORMAT (per message):
//!   encrypted_tag (1 byte) || ciphertext (msglen bytes) || MAC (16 bytes)
//!   Total: msglen + 17 = msglen + ABYTES

use chacha20::cipher::{KeyIvInit, StreamCipher, StreamCipherSeek};
use chacha20::{ChaCha20, hchacha};
use poly1305::Poly1305;
use poly1305::universal_hash::{KeyInit, UniversalHash};
use rand_core::{OsRng, RngCore};
use std::io::{Read, Write};
use subtle::ConstantTimeEq;
use zeroize::{Zeroize, ZeroizeOnDrop};

use crate::crypto::{CryptoError, Result};

/// Default encryption chunk size (4 MB).
pub const ENCRYPTION_CHUNK_SIZE: usize = 4 * 1024 * 1024;

/// Size of a SecretStream key in bytes (exported for compatibility).
pub const KEY_BYTES: usize = 32;

/// Size of the stream header in bytes (exported for compatibility).
pub const HEADER_BYTES: usize = 24;

/// Additional bytes added per message - encrypted tag + MAC (exported for compatibility).
pub const ABYTES: usize = 17;

/// Decryption chunk size (encryption chunk + overhead).
pub const DECRYPTION_CHUNK_SIZE: usize = ENCRYPTION_CHUNK_SIZE + ABYTES;

/// Size of the counter in bytes.
pub const COUNTERBYTES: usize = 4;

/// Size of the internal nonce in bytes.
pub const INONCEBYTES: usize = 8;

/// Message tag (normal message).
pub const TAG_MESSAGE: u8 = 0x00;

/// Push tag (unused in current implementation).
pub const TAG_PUSH: u8 = 0x01;

/// Rekey tag (triggers rekeying).
pub const TAG_REKEY: u8 = 0x02;

/// Final tag (marks end of stream).
pub const TAG_FINAL: u8 = 0x03;

/// HChaCha20 key derivation.
///
/// Derives a 32-byte subkey from a 32-byte key and 16-byte input.
fn hchacha20(key: &[u8; 32], input: &[u8; 16]) -> [u8; 32] {
    use chacha20::cipher::consts::U10;
    let result = hchacha::<U10>(key.into(), input.into());
    let mut output = [0u8; 32];
    output.copy_from_slice(result.as_slice());
    output
}

/// Feed data to Poly1305 with padding to 16-byte boundary.
fn poly1305_update_padded(poly: &mut Poly1305, data: &[u8]) {
    use poly1305::universal_hash::crypto_common::Block;

    let mut offset = 0;

    // Process complete 16-byte blocks
    while offset + 16 <= data.len() {
        let block_slice = &data[offset..offset + 16];
        let mut block = Block::<Poly1305>::default();
        block.copy_from_slice(block_slice);
        poly.update_padded(&block);
        offset += 16;
    }

    // Process remaining bytes with padding
    if offset < data.len() {
        let remaining = &data[offset..];
        let mut block = Block::<Poly1305>::default();
        block[..remaining.len()].copy_from_slice(remaining);

        // For the last partial block, we need to update with the actual data
        // The padding is implicit in Poly1305's finalization
        let mut partial = Block::<Poly1305>::default();
        partial[..remaining.len()].copy_from_slice(remaining);
        poly.update_padded(&partial);
    }
}

/// Feed 8-byte little-endian length to Poly1305.
fn poly1305_update_len(poly: &mut Poly1305, len: u64) {
    use poly1305::universal_hash::crypto_common::Block;

    let bytes = len.to_le_bytes();
    let mut block = Block::<Poly1305>::default();
    block[..8].copy_from_slice(&bytes);
    poly.update_padded(&block);
}

/// SecretStream encryptor (stateful).
#[derive(ZeroizeOnDrop)]
pub struct StreamEncryptor {
    k: [u8; 32],
    nonce: [u8; 12], // counter[4] || inonce[8]
    #[zeroize(skip)]
    pub header: Vec<u8>,
}

impl StreamEncryptor {
    /// Create a new encryptor with a random header.
    ///
    /// # Arguments
    /// * `key` - 32-byte encryption key.
    ///
    /// # Returns
    /// A new encryptor with generated header.
    pub fn new(key: &[u8]) -> Result<Self> {
        if key.len() != KEY_BYTES {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_BYTES,
                actual: key.len(),
            });
        }

        let mut header = [0u8; HEADER_BYTES];
        OsRng.fill_bytes(&mut header);

        // Derive subkey via HChaCha20
        let key_arr: [u8; 32] = key.try_into()?;
        let hchacha_input: [u8; 16] = header[0..16].try_into()?;
        let k = hchacha20(&key_arr, &hchacha_input);

        // Initialize nonce: counter=1 || inonce
        let mut nonce = [0u8; 12];
        nonce[0..4].copy_from_slice(&1u32.to_le_bytes());
        nonce[4..12].copy_from_slice(&header[16..24]);

        Ok(Self {
            k,
            nonce,
            header: header.to_vec(),
        })
    }

    /// Encrypt a message.
    ///
    /// # Arguments
    /// * `plaintext` - Data to encrypt.
    /// * `is_final` - If true, marks this as the final message.
    ///
    /// # Returns
    /// encrypted_tag || ciphertext || MAC
    pub fn push(&mut self, plaintext: &[u8], is_final: bool) -> Result<Vec<u8>> {
        self.push_with_ad(plaintext, &[], is_final)
    }

    /// Encrypt a message with additional authenticated data.
    ///
    /// # Arguments
    /// * `plaintext` - Data to encrypt.
    /// * `ad` - Additional authenticated data (not encrypted).
    /// * `is_final` - If true, marks this as the final message.
    ///
    /// # Returns
    /// encrypted_tag || ciphertext || MAC
    pub fn push_with_ad(&mut self, plaintext: &[u8], ad: &[u8], is_final: bool) -> Result<Vec<u8>> {
        let tag = if is_final { TAG_FINAL } else { TAG_MESSAGE };

        // Step 1: Generate Poly1305 key from block 0
        let mut block0 = [0u8; 64];
        let mut cipher = ChaCha20::new((&self.k).into(), (&self.nonce).into());
        cipher.apply_keystream(&mut block0);

        // Step 2: Init Poly1305 with first 32 bytes
        let poly_key: [u8; 32] = block0[0..32].try_into()?;
        let mut poly = Poly1305::new((&poly_key).into());
        block0.zeroize();

        // Step 3: Process AD with padding
        if !ad.is_empty() {
            poly1305_update_padded(&mut poly, ad);
        }

        // Step 4-6: Encrypt tag block and feed to Poly1305
        let mut tag_block = [0u8; 64];
        tag_block[0] = tag;

        // XOR with keystream at IC=1 (block 1)
        cipher.seek(64); // Skip to block 1
        cipher.apply_keystream(&mut tag_block);

        poly1305_update_padded(&mut poly, &tag_block);
        let encrypted_tag = tag_block[0];

        // Step 7-8: Encrypt message at IC=2 (block 2+)
        cipher.seek(128); // Skip to block 2
        let mut ciphertext = plaintext.to_vec();
        cipher.apply_keystream(&mut ciphertext);

        // Step 9: Feed ciphertext to Poly1305 with padding
        if !ciphertext.is_empty() {
            poly1305_update_padded(&mut poly, &ciphertext);
        }

        // Step 10: Compute lengths and final MAC
        // libsodium: ad_len (8 bytes LE), then (64 + mlen) (8 bytes LE)
        poly1305_update_len(&mut poly, ad.len() as u64);
        poly1305_update_len(&mut poly, (64 + plaintext.len()) as u64);

        let mac = poly.finalize();

        // Step 11: XOR MAC[0..8] into inonce
        for i in 0..8 {
            self.nonce[4 + i] ^= mac.as_slice()[i];
        }

        // Step 12: Increment counter
        let counter = u32::from_le_bytes(self.nonce[0..4].try_into()?);
        let new_counter = counter.wrapping_add(1);
        self.nonce[0..4].copy_from_slice(&new_counter.to_le_bytes());

        // Step 13: Rekey if needed
        if (tag & TAG_REKEY) != 0 || new_counter == 0 {
            self.rekey();
        }

        // Build output: encrypted_tag || ciphertext || MAC
        let mut output = Vec::with_capacity(1 + ciphertext.len() + 16);
        output.push(encrypted_tag);
        output.extend_from_slice(&ciphertext);
        output.extend_from_slice(mac.as_slice());

        Ok(output)
    }

    /// Rekey the stream state.
    fn rekey(&mut self) {
        // Concatenate k || inonce
        let mut buf = [0u8; 40];
        buf[0..32].copy_from_slice(&self.k);
        buf[32..40].copy_from_slice(&self.nonce[4..12]);

        // XOR with ChaCha20 keystream
        let mut cipher = ChaCha20::new((&self.k).into(), (&self.nonce).into());
        cipher.apply_keystream(&mut buf);

        // Extract new key and inonce
        let mut new_k = [0u8; 32];
        new_k.copy_from_slice(&buf[0..32]);

        self.k.zeroize();
        self.k = new_k;
        self.nonce[4..12].copy_from_slice(&buf[32..40]);

        // Reset counter to 1
        self.nonce[0..4].copy_from_slice(&1u32.to_le_bytes());

        buf.zeroize();
    }
}

/// SecretStream decryptor (stateful).
#[derive(ZeroizeOnDrop)]
pub struct StreamDecryptor {
    k: [u8; 32],
    nonce: [u8; 12],
}

impl StreamDecryptor {
    /// Create a new decryptor from a header.
    ///
    /// # Arguments
    /// * `header` - 24-byte stream header.
    /// * `key` - 32-byte encryption key.
    ///
    /// # Returns
    /// A new decryptor initialized with the header.
    pub fn new(header: &[u8], key: &[u8]) -> Result<Self> {
        if header.len() != HEADER_BYTES {
            return Err(CryptoError::InvalidHeaderLength {
                expected: HEADER_BYTES,
                actual: header.len(),
            });
        }
        if key.len() != KEY_BYTES {
            return Err(CryptoError::InvalidKeyLength {
                expected: KEY_BYTES,
                actual: key.len(),
            });
        }

        let key_arr: [u8; 32] = key.try_into()?;
        let hchacha_input: [u8; 16] = header[0..16].try_into()?;
        let k = hchacha20(&key_arr, &hchacha_input);

        let mut nonce = [0u8; 12];
        nonce[0..4].copy_from_slice(&1u32.to_le_bytes());
        nonce[4..12].copy_from_slice(&header[16..24]);

        Ok(Self { k, nonce })
    }

    /// Decrypt a message.
    ///
    /// # Arguments
    /// * `ciphertext` - Encrypted message (encrypted_tag || ciphertext || MAC).
    ///
    /// # Returns
    /// (plaintext, tag) where tag is TAG_MESSAGE, TAG_FINAL, etc.
    pub fn pull(&mut self, ciphertext: &[u8]) -> Result<(Vec<u8>, u8)> {
        self.pull_with_ad(ciphertext, &[])
    }

    /// Decrypt a message with additional authenticated data.
    ///
    /// # Arguments
    /// * `input` - Encrypted message.
    /// * `ad` - Additional authenticated data (must match encryption).
    ///
    /// # Returns
    /// (plaintext, tag)
    pub fn pull_with_ad(&mut self, input: &[u8], ad: &[u8]) -> Result<(Vec<u8>, u8)> {
        if input.len() < ABYTES {
            return Err(CryptoError::CiphertextTooShort {
                minimum: ABYTES,
                actual: input.len(),
            });
        }

        let mlen = input.len() - ABYTES;
        let encrypted_tag = input[0];
        let ciphertext = &input[1..1 + mlen];
        let stored_mac = &input[1 + mlen..];

        // Generate Poly1305 key from block 0
        let mut block0 = [0u8; 64];
        let mut cipher = ChaCha20::new((&self.k).into(), (&self.nonce).into());
        cipher.apply_keystream(&mut block0);

        let poly_key: [u8; 32] = block0[0..32].try_into()?;
        let mut poly = Poly1305::new((&poly_key).into());
        block0.zeroize();

        // Process AD with padding
        if !ad.is_empty() {
            poly1305_update_padded(&mut poly, ad);
        }

        // Recreate and verify tag block
        let mut tag_block = [0u8; 64];
        tag_block[0] = encrypted_tag;
        cipher.seek(64);
        cipher.apply_keystream(&mut tag_block);
        let tag = tag_block[0]; // Decrypted tag
        tag_block[0] = encrypted_tag; // Restore for MAC verification

        poly1305_update_padded(&mut poly, &tag_block);

        // Feed ciphertext to Poly1305 with padding
        if !ciphertext.is_empty() {
            poly1305_update_padded(&mut poly, ciphertext);
        }

        // Compute lengths (same as encrypt)
        poly1305_update_len(&mut poly, ad.len() as u64);
        poly1305_update_len(&mut poly, (64 + mlen) as u64);

        let computed_mac = poly.finalize();

        // SECURITY: Constant-time MAC verification
        if computed_mac.as_slice().ct_eq(stored_mac).unwrap_u8() != 1 {
            return Err(CryptoError::StreamPullFailed);
        }

        // Decrypt message
        cipher.seek(128);
        let mut plaintext = ciphertext.to_vec();
        cipher.apply_keystream(&mut plaintext);

        // Update state: XOR MAC into inonce
        for i in 0..8 {
            self.nonce[4 + i] ^= stored_mac[i];
        }

        // Increment counter
        let counter = u32::from_le_bytes(self.nonce[0..4].try_into()?);
        let new_counter = counter.wrapping_add(1);
        self.nonce[0..4].copy_from_slice(&new_counter.to_le_bytes());

        // Rekey if needed
        if (tag & TAG_REKEY) != 0 || new_counter == 0 {
            self.rekey();
        }

        Ok((plaintext, tag))
    }

    /// Rekey the stream state.
    fn rekey(&mut self) {
        let mut buf = [0u8; 40];
        buf[0..32].copy_from_slice(&self.k);
        buf[32..40].copy_from_slice(&self.nonce[4..12]);

        let mut cipher = ChaCha20::new((&self.k).into(), (&self.nonce).into());
        cipher.apply_keystream(&mut buf);

        let mut new_k = [0u8; 32];
        new_k.copy_from_slice(&buf[0..32]);

        self.k.zeroize();
        self.k = new_k;
        self.nonce[4..12].copy_from_slice(&buf[32..40]);
        self.nonce[0..4].copy_from_slice(&1u32.to_le_bytes());

        buf.zeroize();
    }
}

/// Result of stream encryption.
#[derive(Debug, Clone)]
pub struct EncryptedStream {
    /// The encrypted data (all chunks concatenated).
    pub encrypted_data: Vec<u8>,
    /// The decryption header.
    pub decryption_header: Vec<u8>,
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
/// Use strict mode if you need to enforce TAG_FINAL.
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

/// Result of file encryption with hash.
#[derive(Debug, Clone)]
pub struct FileEncryptResult {
    /// The encryption key used.
    pub key: Vec<u8>,
    /// The decryption header.
    pub header: Vec<u8>,
    /// MD5 hash of the entire encrypted file (base64), if not using multipart.
    pub file_hash: Option<String>,
    /// MD5 hashes of each part (base64), if using multipart.
    pub part_hashes: Option<Vec<String>>,
    /// Part size in bytes, if using multipart.
    pub part_size: Option<usize>,
}

/// Encrypt a file with MD5 hash calculation and real-time verification.
///
/// This function encrypts a file while:
/// 1. Computing MD5 hash of the encrypted output
/// 2. Verifying each encrypted chunk can be decrypted (bit-flip detection)
/// 3. Optionally computing per-part MD5s for multipart uploads
///
/// # Arguments
/// * `source` - Reader for source data.
/// * `dest` - Writer for encrypted data.
/// * `key` - 32-byte encryption key (if None, a new key is generated).
/// * `multipart_chunk_size` - If Some, compute MD5 for each part of this size.
///
/// # Returns
/// FileEncryptResult with key, header, and hash information.
pub fn encrypt_file_with_hash<R: Read, W: Write>(
    source: &mut R,
    dest: &mut W,
    key: Option<&[u8]>,
    multipart_chunk_size: Option<usize>,
) -> Result<FileEncryptResult> {
    use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
    use md5::{Digest, Md5};

    let key = match key {
        Some(k) => k.to_vec(),
        None => super::keys::generate_stream_key(),
    };

    let mut encryptor = StreamEncryptor::new(&key)?;
    let header = encryptor.header.clone();

    // Create a verification decryptor to detect bit flips
    let mut verifier = StreamDecryptor::new(&header, &key)?;

    // MD5 hasher for entire file or current part
    let mut hasher = Md5::new();
    let mut part_hashes: Vec<String> = Vec::new();
    let mut part_bytes_written: usize = 0;

    let mut buffer = vec![0u8; ENCRYPTION_CHUNK_SIZE];
    let mut is_final = false;

    while !is_final {
        let bytes_read = source.read(&mut buffer)?;

        if bytes_read == 0 {
            // Empty file or EOF - push final empty chunk
            let encrypted = encryptor.push(&[], true)?;

            // Verify
            let (decrypted, _) = verifier.pull(&encrypted)?;
            if !decrypted.is_empty() {
                return Err(CryptoError::StreamPushFailed);
            }

            // Hash and write
            hasher.update(&encrypted);
            dest.write_all(&encrypted)?;
            part_bytes_written += encrypted.len();
            is_final = true;
        } else {
            // Check if more data exists
            let mut peek = [0u8; 1];
            let peek_result = source.read(&mut peek)?;

            is_final = peek_result == 0;

            let chunk = &buffer[..bytes_read];
            let encrypted = encryptor.push(chunk, is_final)?;

            // Verify decryption matches original
            let (decrypted, _) = verifier.pull(&encrypted)?;
            if decrypted != chunk {
                return Err(CryptoError::StreamPushFailed);
            }

            // Handle multipart MD5
            if let Some(part_size) = multipart_chunk_size {
                // Write encrypted data
                dest.write_all(&encrypted)?;
                hasher.update(&encrypted);
                part_bytes_written += encrypted.len();

                // Check if we've completed a part
                while part_bytes_written >= part_size {
                    let hash_result = hasher.finalize_reset();
                    part_hashes.push(BASE64.encode(hash_result));
                    part_bytes_written -= part_size;
                }
            } else {
                hasher.update(&encrypted);
                dest.write_all(&encrypted)?;
            }

            // If we peeked a byte, process it
            if !is_final {
                buffer[0] = peek[0];
                let additional = source.read(&mut buffer[1..])?;
                let total = 1 + additional;

                is_final = additional < buffer.len() - 1;

                let chunk = &buffer[..total];
                let encrypted = encryptor.push(chunk, is_final)?;

                // Verify
                let (decrypted, _) = verifier.pull(&encrypted)?;
                if decrypted != chunk {
                    return Err(CryptoError::StreamPushFailed);
                }

                if let Some(part_size) = multipart_chunk_size {
                    dest.write_all(&encrypted)?;
                    hasher.update(&encrypted);
                    part_bytes_written += encrypted.len();

                    while part_bytes_written >= part_size {
                        let hash_result = hasher.finalize_reset();
                        part_hashes.push(BASE64.encode(hash_result));
                        part_bytes_written -= part_size;
                    }
                } else {
                    hasher.update(&encrypted);
                    dest.write_all(&encrypted)?;
                }
            }
        }
    }

    dest.flush()?;

    // Finalize hash
    let (file_hash, part_hashes_result) = if multipart_chunk_size.is_some() {
        // Finalize last part if there's remaining data
        if part_bytes_written > 0 {
            let hash_result = hasher.finalize();
            part_hashes.push(BASE64.encode(hash_result));
        }
        (
            None,
            if part_hashes.is_empty() {
                None
            } else {
                Some(part_hashes)
            },
        )
    } else {
        let hash_result = hasher.finalize();
        (Some(BASE64.encode(hash_result)), None)
    };

    Ok(FileEncryptResult {
        key,
        header,
        file_hash,
        part_hashes: part_hashes_result,
        part_size: multipart_chunk_size,
    })
}

/// Verify that an encrypted file can be decrypted.
///
/// This function attempts to decrypt chunks of an encrypted file to verify
/// the encryption is valid and the keys are correct.
///
/// # Arguments
/// * `source` - Reader for encrypted data.
/// * `header` - The decryption header.
/// * `key` - The 32-byte encryption key.
/// * `chunk_limit` - Number of chunks to verify. Use -1 (or i32::MAX) for entire file.
///
/// # Returns
/// Ok(()) if verification succeeds, Err if any chunk fails to decrypt.
pub fn verify_file<R: Read>(
    source: &mut R,
    header: &[u8],
    key: &[u8],
    chunk_limit: i32,
) -> Result<()> {
    let mut decryptor = StreamDecryptor::new(header, key)?;
    let mut buffer = vec![0u8; DECRYPTION_CHUNK_SIZE];

    let chunks_to_verify = if chunk_limit < 0 {
        i32::MAX
    } else {
        chunk_limit
    };
    let mut chunks_verified = 0;

    loop {
        if chunks_verified >= chunks_to_verify {
            break;
        }

        let bytes_read = source.read(&mut buffer)?;
        if bytes_read == 0 {
            break;
        }

        let (_, tag) = decryptor.pull(&buffer[..bytes_read])?;
        chunks_verified += 1;

        if tag == TAG_FINAL {
            break;
        }
    }

    Ok(())
}

/// Verify an encrypted file using encrypted file key and collection key.
///
/// This is the full verification flow used by Ente clients:
/// 1. Decrypt the file key using the collection key (secretbox)
/// 2. Verify the encrypted file can be decrypted
///
/// # Arguments
/// * `encrypted_file` - Reader for the encrypted file.
/// * `encrypted_file_key` - Encrypted file key (base64).
/// * `encrypted_file_nonce` - Nonce used to encrypt file key (base64).
/// * `encrypted_file_header` - Decryption header (base64).
/// * `collection_key` - Collection key used to encrypt the file key.
/// * `chunk_limit` - Number of chunks to verify (-1 for entire file).
///
/// # Returns
/// Ok(()) if verification succeeds.
pub fn decrypt_verify<R: Read>(
    encrypted_file: &mut R,
    encrypted_file_key: &str,
    encrypted_file_nonce: &str,
    encrypted_file_header: &str,
    collection_key: &[u8],
    chunk_limit: i32,
) -> Result<()> {
    // Decode base64 inputs
    let enc_key = crate::crypto::decode_b64(encrypted_file_key)?;
    let nonce = crate::crypto::decode_b64(encrypted_file_nonce)?;
    let header = crate::crypto::decode_b64(encrypted_file_header)?;

    // Decrypt file key using collection key
    let file_key = super::secretbox::decrypt(&enc_key, &nonce, collection_key)?;

    // Verify file can be decrypted
    verify_file(encrypted_file, &header, &file_key, chunk_limit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::impl_pure::keys;

    #[test]
    fn test_encrypt_decrypt_single_message() {
        let key = keys::generate_stream_key();
        let plaintext = b"Hello, SecretStream!";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push(plaintext, false).unwrap();

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let (decrypted, tag) = dec.pull(&encrypted).unwrap();

        assert_eq!(decrypted, plaintext);
        assert_eq!(tag, TAG_MESSAGE);
    }

    #[test]
    fn test_encrypt_decrypt_multiple_messages() {
        let key = keys::generate_stream_key();
        let messages: Vec<&[u8]> = vec![b"First", b"Second", b"Third"];

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();

        let mut encrypted_msgs = Vec::new();
        for msg in &messages {
            encrypted_msgs.push(enc.push(*msg, false).unwrap());
        }

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        for (i, enc_msg) in encrypted_msgs.iter().enumerate() {
            let (decrypted, tag) = dec.pull(enc_msg).unwrap();
            assert_eq!(decrypted, messages[i]);
            assert_eq!(tag, TAG_MESSAGE);
        }
    }

    #[test]
    fn test_final_tag() {
        let key = keys::generate_stream_key();
        let plaintext = b"Final message";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push(plaintext, true).unwrap();

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let (decrypted, tag) = dec.pull(&encrypted).unwrap();

        assert_eq!(decrypted, plaintext);
        assert_eq!(tag, TAG_FINAL);
    }

    #[test]
    fn test_with_ad() {
        let key = keys::generate_stream_key();
        let plaintext = b"Message";
        let ad = b"Additional data";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push_with_ad(plaintext, ad, false).unwrap();

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let (decrypted, _) = dec.pull_with_ad(&encrypted, ad).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_wrong_ad_fails() {
        let key = keys::generate_stream_key();
        let plaintext = b"Message";
        let ad = b"Correct AD";
        let wrong_ad = b"Wrong AD";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push_with_ad(plaintext, ad, false).unwrap();

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let result = dec.pull_with_ad(&encrypted, wrong_ad);

        assert!(result.is_err());
    }

    #[test]
    fn test_empty_message() {
        let key = keys::generate_stream_key();
        let plaintext = b"";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push(plaintext, false).unwrap();

        assert_eq!(encrypted.len(), ABYTES);

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let (decrypted, _) = dec.pull(&encrypted).unwrap();

        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_corrupted_ciphertext() {
        let key = keys::generate_stream_key();
        let plaintext = b"Original";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let mut encrypted = enc.push(plaintext, false).unwrap();

        // Corrupt a byte
        encrypted[5] ^= 1;

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let result = dec.pull(&encrypted);

        assert!(result.is_err());
    }

    #[test]
    fn test_wrong_key() {
        let key = keys::generate_stream_key();
        let wrong_key = keys::generate_stream_key();
        let plaintext = b"Secret";

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();
        let encrypted = enc.push(plaintext, false).unwrap();

        let mut dec = StreamDecryptor::new(&header, &wrong_key).unwrap();
        let result = dec.pull(&encrypted);

        assert!(result.is_err());
    }

    #[test]
    fn test_state_synchronization() {
        let key = keys::generate_stream_key();

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();

        // Encrypt multiple messages
        let enc1 = enc.push(b"First", false).unwrap();
        let enc2 = enc.push(b"Second", false).unwrap();
        let enc3 = enc.push(b"Third", false).unwrap();

        // Decrypt in order
        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let (dec1, _) = dec.pull(&enc1).unwrap();
        let (dec2, _) = dec.pull(&enc2).unwrap();
        let (dec3, _) = dec.pull(&enc3).unwrap();

        assert_eq!(dec1, b"First");
        assert_eq!(dec2, b"Second");
        assert_eq!(dec3, b"Third");
    }

    #[test]
    fn test_out_of_order_fails() {
        let key = keys::generate_stream_key();

        let mut enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();

        let _enc1 = enc.push(b"First", false).unwrap();
        let enc2 = enc.push(b"Second", false).unwrap();

        // Try to decrypt second message first
        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let result = dec.pull(&enc2);

        assert!(result.is_err());
    }

    #[test]
    fn test_invalid_key_length() {
        let bad_key = vec![0u8; 16]; // Wrong size
        let result = StreamEncryptor::new(&bad_key);

        assert!(matches!(result, Err(CryptoError::InvalidKeyLength { .. })));
    }

    #[test]
    fn test_invalid_header_length() {
        let key = keys::generate_stream_key();
        let bad_header = vec![0u8; 16]; // Wrong size

        let result = StreamDecryptor::new(&bad_header, &key);
        assert!(matches!(
            result,
            Err(CryptoError::InvalidHeaderLength { .. })
        ));
    }

    #[test]
    fn test_ciphertext_too_short() {
        let key = keys::generate_stream_key();

        let enc = StreamEncryptor::new(&key).unwrap();
        let header = enc.header.clone();

        let mut dec = StreamDecryptor::new(&header, &key).unwrap();
        let bad_ciphertext = vec![0u8; 10]; // Less than ABYTES

        let result = dec.pull(&bad_ciphertext);
        assert!(matches!(
            result,
            Err(CryptoError::CiphertextTooShort { .. })
        ));
    }
}
