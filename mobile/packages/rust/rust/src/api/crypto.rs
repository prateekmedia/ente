//! Cryptographic API exposed to Dart via Flutter Rust Bridge.
//!
//! This provides a Dart-compatible API for the Rust crypto core.
//! Functions are designed to match the CryptoUtil interface from ente_crypto_dart.

use flutter_rust_bridge::frb;

use std::fs::File;
use std::io::{self, BufReader, BufWriter, Write};

/// Initialize the crypto backend. Must be called once before using any crypto functions.
#[frb(sync)]
pub fn init_crypto() -> Result<(), String> {
    ente_core::crypto::init().map_err(|e| e.to_string())
}

/// Generate a random 256-bit key for SecretBox encryption.
#[frb(sync)]
pub fn generate_key() -> Vec<u8> {
    ente_core::crypto::keys::generate_key().to_vec()
}

/// Generate a random key for SecretStream encryption.
#[frb(sync)]
pub fn generate_stream_key() -> Vec<u8> {
    ente_core::crypto::keys::generate_stream_key().to_vec()
}

// ============================================================================
// Base64/Hex encoding utilities (CryptoUtil compatible)
// ============================================================================

/// Convert a UTF-8 string to bytes.
#[frb(sync)]
pub fn str_to_bin(input: String) -> Vec<u8> {
    ente_core::crypto::str_to_bin(&input)
}

/// Base64 encode bytes (CryptoUtil.bin2base64 compatible).
///
/// Set `url_safe` to true to use the URL-safe alphabet.
#[frb(sync)]
pub fn bin2base64(data: Vec<u8>, url_safe: bool) -> String {
    ente_core::crypto::bin2base64(&data, url_safe)
}

/// Base64 decode string to bytes (CryptoUtil.base642bin compatible).
///
/// Accepts standard (`+`/`/`) or URL-safe (`-`/`_`) alphabets with or without
/// padding.
#[frb(sync)]
pub fn base642bin(data: String) -> Result<Vec<u8>, String> {
    let mut normalized = data.replace('-', "+").replace('_', "/");
    while normalized.len() % 4 != 0 {
        normalized.push('=');
    }
    ente_core::crypto::base642bin(&normalized).map_err(|e| e.to_string())
}

/// Hex decode string to bytes (CryptoUtil.hex2bin compatible).
#[frb(sync)]
pub fn hex2bin(data: String) -> Result<Vec<u8>, String> {
    ente_core::crypto::decode_hex(&data).map_err(|e| e.to_string())
}

/// Hex encode bytes (CryptoUtil.bin2hex compatible).
#[frb(sync)]
pub fn bin2hex(data: Vec<u8>) -> String {
    ente_core::crypto::encode_hex(&data)
}

// Aliases for the new naming convention
#[frb(sync)]
pub fn encode_b64(data: Vec<u8>) -> String {
    ente_core::crypto::encode_b64(&data)
}

#[frb(sync)]
pub fn decode_b64(data: String) -> Result<Vec<u8>, String> {
    base642bin(data)
}

// ============================================================================
// SecretBox encryption (XSalsa20-Poly1305)
// ============================================================================

/// Encrypt data using SecretBox (XSalsa20-Poly1305).
/// Returns the encrypted data with nonce prepended.
#[frb(sync)]
pub fn secretbox_encrypt(plaintext: Vec<u8>, key: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    let result =
        ente_core::crypto::secretbox::encrypt(&plaintext, &key).map_err(|e| e.to_string())?;
    // encrypted_data already contains nonce || MAC || ciphertext
    Ok(result.encrypted_data)
}

/// Decrypt data encrypted with SecretBox.
/// Input should have nonce prepended.
#[frb(sync)]
pub fn secretbox_decrypt(ciphertext: Vec<u8>, key: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    ente_core::crypto::secretbox::decrypt_box(&ciphertext, &key).map_err(|e| e.to_string())
}

/// Decrypt with separate nonce (CryptoUtil.decryptSync compatible).
#[frb(sync)]
pub fn decrypt_sync(cipher: Vec<u8>, key: Vec<u8>, nonce: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    let nonce: [u8; 24] = nonce
        .try_into()
        .map_err(|_| "Nonce must be 24 bytes".to_string())?;
    ente_core::crypto::secretbox::decrypt(&cipher, &nonce, &key).map_err(|e| e.to_string())
}

/// Async decrypt wrapper (CryptoUtil.decrypt compatible).
pub async fn decrypt(cipher: Vec<u8>, key: Vec<u8>, nonce: Vec<u8>) -> Result<Vec<u8>, String> {
    decrypt_sync(cipher, key, nonce)
}

// ============================================================================
// Blob encryption (SecretStream without chunking)
// ============================================================================

/// Encrypt data using blob encryption (SecretStream without chunking).
/// Returns encrypted data with header prepended.
#[frb(sync)]
pub fn blob_encrypt(plaintext: Vec<u8>, key: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    let result = ente_core::crypto::blob::encrypt(&plaintext, &key).map_err(|e| e.to_string())?;
    // Combine header + encrypted_data
    let mut combined = result.decryption_header;
    combined.extend(result.encrypted_data);
    Ok(combined)
}

/// Decrypt blob-encrypted data.
/// Input should have header prepended.
#[frb(sync)]
pub fn blob_decrypt(ciphertext: Vec<u8>, key: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    // Header is 24 bytes
    if ciphertext.len() < 24 {
        return Err("Ciphertext too short".to_string());
    }
    let header = &ciphertext[..24];
    let encrypted = &ciphertext[24..];
    ente_core::crypto::blob::decrypt(encrypted, header, &key).map_err(|e| e.to_string())
}

/// Encrypt data with separate header output (for Auth-style entity encryption).
/// Returns (encrypted_data, header) as base64 strings.
#[frb(sync)]
pub fn encrypt_data(plaintext: Vec<u8>, key: Vec<u8>) -> Result<EncryptedData, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    let result = ente_core::crypto::blob::encrypt(&plaintext, &key).map_err(|e| e.to_string())?;

    let header = ente_core::crypto::encode_b64(&result.decryption_header);
    let data = ente_core::crypto::encode_b64(&result.encrypted_data);

    Ok(EncryptedData {
        encrypted_data: data,
        header,
    })
}

/// Decrypt data with separate header input (for Auth-style entity decryption).
#[frb(sync)]
pub fn decrypt_data(
    encrypted_data_b64: String,
    key: Vec<u8>,
    header_b64: String,
) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;

    let header = ente_core::crypto::decode_b64(&header_b64).map_err(|e| e.to_string())?;
    let encrypted =
        ente_core::crypto::decode_b64(&encrypted_data_b64).map_err(|e| e.to_string())?;

    ente_core::crypto::blob::decrypt(&encrypted, &header, &key).map_err(|e| e.to_string())
}

// ============================================================================
// Sealed box (anonymous public-key encryption)
// ============================================================================

/// Seal data for a recipient (CryptoUtil.sealSync compatible).
#[frb(sync)]
pub fn seal_sync(data: Vec<u8>, public_key: Vec<u8>) -> Result<Vec<u8>, String> {
    ente_core::crypto::sealed::seal(&data, &public_key).map_err(|e| e.to_string())
}

/// Open a sealed box (CryptoUtil.openSealSync compatible).
#[frb(sync)]
pub fn open_seal_sync(
    cipher: Vec<u8>,
    public_key: Vec<u8>,
    secret_key: Vec<u8>,
) -> Result<Vec<u8>, String> {
    ente_core::crypto::sealed::open(&cipher, &public_key, &secret_key).map_err(|e| e.to_string())
}

// ============================================================================
// File encryption (SecretStream)
// ============================================================================

pub async fn encrypt_file(
    source_file_path: String,
    destination_file_path: String,
    key: Option<Vec<u8>>,
) -> Result<FileEncryptResult, String> {
    let src = File::open(&source_file_path)
        .map_err(|e| format!("open source file {source_file_path}: {e}"))?;
    let dst = File::create(&destination_file_path)
        .map_err(|e| format!("create destination file {destination_file_path}: {e}"))?;

    let mut reader = BufReader::new(src);
    let mut writer = BufWriter::new(dst);

    let (key, header) =
        ente_core::crypto::stream::encrypt_file(&mut reader, &mut writer, key.as_deref())
            .map_err(|e| e.to_string())?;

    writer
        .flush()
        .map_err(|e| format!("flush destination file {destination_file_path}: {e}"))?;

    Ok(FileEncryptResult {
        key,
        header,
        file_md5: None,
        part_md5s: None,
        part_size: None,
    })
}

pub async fn encrypt_file_with_md5(
    source_file_path: String,
    destination_file_path: String,
    key: Option<Vec<u8>>,
    multi_part_chunk_size_in_bytes: Option<u32>,
) -> Result<FileEncryptResult, String> {
    let src = File::open(&source_file_path)
        .map_err(|e| format!("open source file {source_file_path}: {e}"))?;
    let dst = File::create(&destination_file_path)
        .map_err(|e| format!("create destination file {destination_file_path}: {e}"))?;

    let mut reader = BufReader::new(src);

    if let Some(part_size) = multi_part_chunk_size_in_bytes {
        if part_size == 0 {
            return Err("multi_part_chunk_size_in_bytes must be > 0".to_string());
        }

        use md5::{Digest, Md5};

        struct PartMd5Writer<W: Write> {
            inner: W,
            part_size: usize,
            part_filled: usize,
            part_state: Md5,
            part_md5s: Vec<String>,
        }

        impl<W: Write> PartMd5Writer<W> {
            fn new(inner: W, part_size: usize) -> Self {
                Self {
                    inner,
                    part_size,
                    part_filled: 0,
                    part_state: Md5::new(),
                    part_md5s: Vec::new(),
                }
            }

            fn update_hashes(&mut self, mut data: &[u8]) {
                while !data.is_empty() {
                    let remaining = self.part_size - self.part_filled;
                    let to_take = remaining.min(data.len());
                    self.part_state.update(&data[..to_take]);
                    self.part_filled += to_take;
                    data = &data[to_take..];

                    if self.part_filled == self.part_size {
                        let state = std::mem::replace(&mut self.part_state, Md5::new());
                        let digest = state.finalize();
                        self.part_md5s
                            .push(ente_core::crypto::encode_b64(digest.as_ref()));
                        self.part_filled = 0;
                    }
                }
            }

            fn finish(mut self) -> Vec<String> {
                if self.part_filled > 0 {
                    let digest = self.part_state.finalize();
                    self.part_md5s
                        .push(ente_core::crypto::encode_b64(digest.as_ref()));
                }
                self.part_md5s
            }
        }

        impl<W: Write> Write for PartMd5Writer<W> {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                let n = self.inner.write(buf)?;
                self.update_hashes(&buf[..n]);
                Ok(n)
            }

            fn flush(&mut self) -> io::Result<()> {
                self.inner.flush()
            }
        }

        let mut writer = PartMd5Writer::new(BufWriter::new(dst), part_size as usize);

        let (key, header) =
            ente_core::crypto::stream::encrypt_file(&mut reader, &mut writer, key.as_deref())
                .map_err(|e| e.to_string())?;

        writer
            .flush()
            .map_err(|e| format!("flush destination file {destination_file_path}: {e}"))?;

        let part_md5s = writer.finish();

        Ok(FileEncryptResult {
            key,
            header,
            file_md5: None,
            part_md5s: Some(part_md5s),
            part_size: Some(part_size),
        })
    } else {
        let mut writer = BufWriter::new(dst);

        let (key, header, md5) =
            ente_core::crypto::stream::encrypt_file_with_md5(&mut reader, &mut writer, key.as_deref())
                .map_err(|e| e.to_string())?;

        writer
            .flush()
            .map_err(|e| format!("flush destination file {destination_file_path}: {e}"))?;

        Ok(FileEncryptResult {
            key,
            header,
            file_md5: Some(ente_core::crypto::encode_b64(&md5)),
            part_md5s: None,
            part_size: None,
        })
    }
}

pub async fn decrypt_file(
    source_file_path: String,
    destination_file_path: String,
    header: Vec<u8>,
    key: Vec<u8>,
) -> Result<(), String> {
    let src = File::open(&source_file_path)
        .map_err(|e| format!("open source file {source_file_path}: {e}"))?;
    let dst = File::create(&destination_file_path)
        .map_err(|e| format!("create destination file {destination_file_path}: {e}"))?;

    let mut reader = BufReader::new(src);
    let mut writer = BufWriter::new(dst);

    ente_core::crypto::stream::decrypt_file(&mut reader, &mut writer, &header, &key)
        .map_err(|e| e.to_string())?;

    writer
        .flush()
        .map_err(|e| format!("flush destination file {destination_file_path}: {e}"))?;

    Ok(())
}

// ============================================================================
// Key derivation
// ============================================================================

/// Derive a key from password using Argon2id (CryptoUtil.deriveKey compatible).
pub async fn derive_key(
    password: String,
    salt: Vec<u8>,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>, String> {
    ente_core::crypto::argon::derive_key(&password, &salt, mem_limit, ops_limit)
        .map_err(|e| e.to_string())
}

/// Derive login key from KEK (CryptoUtil.deriveLoginKey compatible).
pub async fn derive_login_key(key: Vec<u8>) -> Result<Vec<u8>, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    ente_core::crypto::kdf::derive_login_key(&key).map_err(|e| e.to_string())
}

/// Derive sensitive key with secure parameters (CryptoUtil.deriveSensitiveKey compatible).
pub async fn derive_sensitive_key(
    password: String,
    salt: Vec<u8>,
) -> Result<DerivedKeyResult, String> {
    let result = ente_core::crypto::argon::derive_sensitive_key_with_salt_adaptive(
        password.as_bytes(),
        &salt,
    )
    .map_err(|e| e.to_string())?;

    Ok(DerivedKeyResult {
        key: result.key,
        mem_limit: result.mem_limit,
        ops_limit: result.ops_limit,
    })
}

/// Derive an interactive key using fixed interactive parameters.
pub async fn derive_interactive_key(
    password: String,
    salt: Vec<u8>,
) -> Result<DerivedKeyResult, String> {
    let key = ente_core::crypto::argon::derive_interactive_key_with_salt(&password, &salt)
        .map_err(|e| e.to_string())?;

    Ok(DerivedKeyResult {
        key,
        mem_limit: ente_core::crypto::argon::MEMLIMIT_INTERACTIVE,
        ops_limit: ente_core::crypto::argon::OPSLIMIT_INTERACTIVE,
    })
}

/// cryptoPwHash compatible wrapper.
#[frb(sync)]
pub fn crypto_pw_hash(
    password: String,
    salt: Vec<u8>,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>, String> {
    ente_core::crypto::argon::derive_key(&password, &salt, mem_limit, ops_limit)
        .map_err(|e| e.to_string())
}

#[frb(sync)]
pub fn pwhash_mem_limit_interactive() -> u32 {
    ente_core::crypto::argon::MEMLIMIT_INTERACTIVE
}

#[frb(sync)]
pub fn pwhash_mem_limit_sensitive() -> u32 {
    ente_core::crypto::argon::MEMLIMIT_SENSITIVE
}

#[frb(sync)]
pub fn pwhash_ops_limit_interactive() -> u32 {
    ente_core::crypto::argon::OPSLIMIT_INTERACTIVE
}

#[frb(sync)]
pub fn pwhash_ops_limit_sensitive() -> u32 {
    ente_core::crypto::argon::OPSLIMIT_SENSITIVE
}

// ============================================================================
// Hashing
// ============================================================================

pub async fn get_hash(source_file_path: String) -> Result<Vec<u8>, String> {
    let src = File::open(&source_file_path)
        .map_err(|e| format!("open source file {source_file_path}: {e}"))?;

    let mut reader = BufReader::new(src);
    ente_core::crypto::hash::hash_reader(&mut reader, None).map_err(|e| e.to_string())
}

// ============================================================================
// SecretBox with nonce (for encryption)
// ============================================================================

/// Encrypt with SecretBox returning encrypted data and nonce (CryptoUtil.encryptSync compatible).
#[frb(sync)]
pub fn encrypt_sync(plaintext: Vec<u8>, key: Vec<u8>) -> Result<EncryptedResult, String> {
    let key: [u8; 32] = key
        .try_into()
        .map_err(|_| "Key must be 32 bytes".to_string())?;
    let result =
        ente_core::crypto::secretbox::encrypt(&plaintext, &key).map_err(|e| e.to_string())?;
    // encrypted_data contains: nonce (24 bytes) || MAC || ciphertext
    // We need to return just the MAC || ciphertext part, and the nonce separately
    let encrypted_data = &result.encrypted_data;
    if encrypted_data.len() < 24 {
        return Err("Encrypted data too short".to_string());
    }
    Ok(EncryptedResult {
        encrypted_data: encrypted_data[24..].to_vec(),
        nonce: result.nonce,
    })
}

// ============================================================================
// Key pair generation
// ============================================================================

/// Generate a key pair for asymmetric encryption (CryptoUtil.generateKeyPair compatible).
#[frb(sync)]
pub fn generate_key_pair() -> Result<KeyPair, String> {
    let (public_key, secret_key) =
        ente_core::crypto::keys::generate_keypair().map_err(|e| e.to_string())?;
    Ok(KeyPair {
        public_key,
        secret_key,
    })
}

/// Generate a salt for key derivation (CryptoUtil.getSaltToDeriveKey compatible).
#[frb(sync)]
pub fn get_salt_to_derive_key() -> Vec<u8> {
    ente_core::crypto::keys::generate_salt().to_vec()
}

// ============================================================================
// Types
// ============================================================================

/// Result of encryption with separate header.
#[frb]
pub struct EncryptedData {
    pub encrypted_data: String,
    pub header: String,
}

/// Result of encryption with nonce.
#[frb]
pub struct EncryptedResult {
    pub encrypted_data: Vec<u8>,
    pub nonce: Vec<u8>,
}

/// Key derivation result.
#[frb]
pub struct DerivedKeyResult {
    pub key: Vec<u8>,
    pub mem_limit: u32,
    pub ops_limit: u32,
}

/// Key pair for asymmetric encryption.
#[frb]
pub struct KeyPair {
    pub public_key: Vec<u8>,
    pub secret_key: Vec<u8>,
}

/// Result of file encryption.
#[frb]
pub struct FileEncryptResult {
    pub key: Vec<u8>,
    pub header: Vec<u8>,
    pub file_md5: Option<String>,
    pub part_md5s: Option<Vec<String>>,
    pub part_size: Option<u32>,
}

// ============================================================================
// High-level Auth API (for login flows)
// ============================================================================

/// Derive KEK (Key Encryption Key) from password for authentication.
/// This is used in the email MFA flow where SRP is not used.
pub async fn derive_kek(
    password: String,
    kek_salt: String,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>, String> {
    ente_core::auth::derive_kek(&password, &kek_salt, mem_limit, ops_limit)
        .map_err(|e| e.to_string())
}

/// Decrypted secrets from authentication.
#[frb]
pub struct DecryptedSecrets {
    pub master_key: Vec<u8>,
    pub secret_key: Vec<u8>,
    pub token: Vec<u8>,
}

/// Decrypt secrets after successful authentication.
///
/// This decrypts:
/// 1. Master key using KEK
/// 2. Secret key using master key
/// 3. Token using sealed box (public key crypto)
pub fn decrypt_auth_secrets(
    kek: Vec<u8>,
    encrypted_key: String,
    key_decryption_nonce: String,
    public_key: String,
    encrypted_secret_key: String,
    secret_key_decryption_nonce: String,
    encrypted_token: String,
) -> Result<DecryptedSecrets, String> {
    let key_attrs = ente_core::auth::KeyAttributes {
        kek_salt: String::new(), // Not needed for decryption
        encrypted_key,
        key_decryption_nonce,
        public_key,
        encrypted_secret_key,
        secret_key_decryption_nonce,
        mem_limit: None,
        ops_limit: None,
        master_key_encrypted_with_recovery_key: None,
        master_key_decryption_nonce: None,
        recovery_key_encrypted_with_master_key: None,
        recovery_key_decryption_nonce: None,
    };

    let secrets = ente_core::auth::decrypt_secrets(&kek, &key_attrs, &encrypted_token)
        .map_err(|e| e.to_string())?;

    Ok(DecryptedSecrets {
        master_key: secrets.master_key,
        secret_key: secrets.secret_key,
        token: secrets.token,
    })
}
