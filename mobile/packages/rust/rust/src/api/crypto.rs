//! Cryptographic API exposed to Dart via Flutter Rust Bridge.
//!
//! This provides a Dart-compatible API for the Rust crypto core.
//! Functions are designed to match the CryptoUtil interface from ente_crypto_dart.

use flutter_rust_bridge::frb;

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

/// Base64 encode bytes (CryptoUtil.bin2base64 compatible).
#[frb(sync)]
pub fn bin2base64(data: Vec<u8>) -> String {
    ente_core::crypto::encode_b64(&data)
}

/// Base64 decode string to bytes (CryptoUtil.base642bin compatible).
#[frb(sync)]
pub fn base642bin(data: String) -> Result<Vec<u8>, String> {
    ente_core::crypto::decode_b64(&data).map_err(|e| e.to_string())
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
    bin2base64(data)
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
/// If salt is empty, generates a new random salt.
pub async fn derive_sensitive_key(
    password: String,
    salt: Vec<u8>,
) -> Result<DerivedKeyResult, String> {
    let salt_bytes = if salt.is_empty() {
        ente_core::crypto::keys::generate_salt().to_vec()
    } else {
        salt
    };

    let desired_strength = (ente_core::crypto::argon::MEMLIMIT_SENSITIVE as u64)
        * (ente_core::crypto::argon::OPSLIMIT_SENSITIVE as u64);
    let mut mem_limit = ente_core::crypto::argon::MEMLIMIT_MODERATE;
    let factor =
        ente_core::crypto::argon::MEMLIMIT_SENSITIVE / ente_core::crypto::argon::MEMLIMIT_MODERATE;
    let mut ops_limit = ente_core::crypto::argon::OPSLIMIT_SENSITIVE.saturating_mul(factor);

    if (mem_limit as u64) * (ops_limit as u64) != desired_strength {
        return Err("Unexpected argon parameters".to_string());
    }

    while mem_limit >= ente_core::crypto::argon::MEMLIMIT_MIN
        && ops_limit < ente_core::crypto::argon::OPSLIMIT_MAX
    {
        match ente_core::crypto::argon::derive_key(&password, &salt_bytes, mem_limit, ops_limit) {
            Ok(key) => {
                return Ok(DerivedKeyResult {
                    key,
                    mem_limit,
                    ops_limit,
                });
            }
            Err(_) => {
                mem_limit /= 2;
                ops_limit = ops_limit.saturating_mul(2);
            }
        }
    }

    Err("Cannot perform this operation on this device".to_string())
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
