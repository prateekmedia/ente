//! UniFFI bindings for the Ensu Swift frontend.
//!
//! The Swift UI is responsible for networking + UX, while all auth-crypto
//! (Argon2id, libsodium-compatible SecretBox/SealedBox, SRP helpers)
//! is implemented in pure Rust via `ente-core`.

use std::sync::Mutex;

use base64::Engine;
use thiserror::Error;

// Include UniFFI-generated scaffolding from `src/ensu_uniffi.udl`.
//
// This generates the FFI export layer that Swift calls into, and also derives
// the required UniFFI traits for the types below (via placeholder items).
uniffi::include_scaffolding!("ensu_uniffi");

// =====================================================================================
// Types (must match the UDL definitions)
// =====================================================================================

#[derive(Debug, Error)]
pub enum EnsuError {
    #[error("{message}")]
    Message { message: String },
}

impl EnsuError {
    fn msg(message: impl ToString) -> Self {
        EnsuError::Message {
            message: message.to_string(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SrpAttributes {
    pub srp_user_id: String,
    pub srp_salt: String,
    pub kek_salt: String,
    pub mem_limit: u32,
    pub ops_limit: u32,
    pub is_email_mfa_enabled: bool,
}

#[derive(Debug, Clone)]
pub struct KeyAttributes {
    pub kek_salt: String,
    pub encrypted_key: String,
    pub key_decryption_nonce: String,
    pub public_key: String,
    pub encrypted_secret_key: String,
    pub secret_key_decryption_nonce: String,
    pub mem_limit: Option<u32>,
    pub ops_limit: Option<u32>,
}

#[derive(Debug, Clone)]
pub struct SrpSessionResult {
    pub srp_a: String,
}

#[derive(Debug, Clone)]
pub struct SrpVerifyResult {
    pub srp_m1: String,
}

#[derive(Debug, Clone)]
pub struct AuthSecrets {
    pub master_key: Vec<u8>,
    pub secret_key: Vec<u8>,
    pub token: Vec<u8>,
}

// =====================================================================================
// SRP session state (single in-flight session)
// =====================================================================================

struct SrpSessionState {
    session: ente_core::auth::SrpSession,
    kek: Vec<u8>,
}

static SRP_SESSION: Mutex<Option<SrpSessionState>> = Mutex::new(None);

// =====================================================================================
// Functions referenced by the UDL (called by UniFFI-generated wrappers)
// =====================================================================================

pub fn init_crypto() -> Result<(), EnsuError> {
    ente_core::crypto::init().map_err(|e| EnsuError::msg(e.to_string()))
}

pub fn srp_start(password: String, srp_attrs: SrpAttributes) -> Result<SrpSessionResult, EnsuError> {
    let core_attrs = ente_core::auth::SrpAttributes {
        srp_user_id: srp_attrs.srp_user_id,
        srp_salt: srp_attrs.srp_salt,
        kek_salt: srp_attrs.kek_salt,
        mem_limit: srp_attrs.mem_limit,
        ops_limit: srp_attrs.ops_limit,
        is_email_mfa_enabled: srp_attrs.is_email_mfa_enabled,
    };

    let creds = ente_core::auth::derive_srp_credentials(&password, &core_attrs)
        .map_err(|e| EnsuError::msg(e.to_string()))?;

    let srp_salt = ente_core::crypto::decode_b64(&core_attrs.srp_salt)
        .map_err(|e| EnsuError::msg(format!("srp_salt: {e}")))?;

    let session = ente_core::auth::SrpSession::new(&core_attrs.srp_user_id, &srp_salt, &creds.login_key)
        .map_err(|e| EnsuError::msg(e.to_string()))?;

    let a_pub = session.public_a();

    // Protocol expects srpA padded to 512 bytes (4096-bit group).
    let padded_a = pad_bytes(&a_pub, 512);
    let srp_a = ente_core::crypto::encode_b64(&padded_a);

    *SRP_SESSION.lock().unwrap() = Some(SrpSessionState {
        session,
        kek: creds.kek,
    });

    Ok(SrpSessionResult { srp_a })
}

pub fn srp_finish(srp_b: String) -> Result<SrpVerifyResult, EnsuError> {
    let server_b = ente_core::crypto::decode_b64(&srp_b)
        .map_err(|e| EnsuError::msg(format!("Invalid srpB: {e}")))?;

    let mut lock = SRP_SESSION.lock().unwrap();
    let state = lock.as_mut().ok_or_else(|| EnsuError::msg("No active SRP session"))?;

    let m1 = state
        .session
        .compute_m1(&server_b)
        .map_err(|e| EnsuError::msg(e.to_string()))?;

    // Protocol expects srpM1 padded to 32 bytes.
    let padded_m1 = pad_bytes(&m1, 32);
    let srp_m1 = ente_core::crypto::encode_b64(&padded_m1);

    Ok(SrpVerifyResult { srp_m1 })
}

pub fn srp_decrypt_secrets(
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, EnsuError> {
    let kek = {
        let lock = SRP_SESSION.lock().unwrap();
        let state = lock.as_ref().ok_or_else(|| EnsuError::msg("No active SRP session"))?;
        state.kek.clone()
    };

    let result = decrypt_secrets_internal(&kek, key_attrs, encrypted_token, plain_token);

    // Always clear SRP state after attempting decryption.
    *SRP_SESSION.lock().unwrap() = None;

    result
}

pub fn srp_clear() {
    *SRP_SESSION.lock().unwrap() = None;
}

pub fn derive_kek_for_login(
    password: String,
    kek_salt: String,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>, EnsuError> {
    ente_core::auth::derive_kek(&password, &kek_salt, mem_limit, ops_limit)
        .map_err(|e| EnsuError::msg(e.to_string()))
}

pub fn decrypt_secrets_with_kek(
    kek: Vec<u8>,
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, EnsuError> {
    decrypt_secrets_internal(&kek, key_attrs, encrypted_token, plain_token)
}

// =====================================================================================
// Internal helpers
// =====================================================================================

fn decrypt_secrets_internal(
    kek: &[u8],
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, EnsuError> {
    let core_attrs = ente_core::auth::KeyAttributes {
        kek_salt: key_attrs.kek_salt,
        encrypted_key: key_attrs.encrypted_key,
        key_decryption_nonce: key_attrs.key_decryption_nonce,
        public_key: key_attrs.public_key.clone(),
        encrypted_secret_key: key_attrs.encrypted_secret_key,
        secret_key_decryption_nonce: key_attrs.secret_key_decryption_nonce,
        mem_limit: key_attrs.mem_limit,
        ops_limit: key_attrs.ops_limit,
        master_key_encrypted_with_recovery_key: None,
        master_key_decryption_nonce: None,
        recovery_key_encrypted_with_master_key: None,
        recovery_key_decryption_nonce: None,
    };

    // 1) Decrypt master key with KEK
    let encrypted_key = ente_core::crypto::decode_b64(&core_attrs.encrypted_key)
        .map_err(|e| EnsuError::msg(format!("encrypted_key: {e}")))?;
    let key_nonce = ente_core::crypto::decode_b64(&core_attrs.key_decryption_nonce)
        .map_err(|e| EnsuError::msg(format!("key_decryption_nonce: {e}")))?;

    let master_key = ente_core::crypto::secretbox::decrypt(&encrypted_key, &key_nonce, kek)
        .map_err(|_| EnsuError::msg("Incorrect password"))?;

    // 2) Decrypt secret key with master key
    let encrypted_secret_key = ente_core::crypto::decode_b64(&core_attrs.encrypted_secret_key)
        .map_err(|e| EnsuError::msg(format!("encrypted_secret_key: {e}")))?;
    let secret_key_nonce = ente_core::crypto::decode_b64(&core_attrs.secret_key_decryption_nonce)
        .map_err(|e| EnsuError::msg(format!("secret_key_decryption_nonce: {e}")))?;

    let secret_key = ente_core::crypto::secretbox::decrypt(
        &encrypted_secret_key,
        &secret_key_nonce,
        &master_key,
    )
    .map_err(|_| EnsuError::msg("Failed to decrypt secret key"))?;

    // 3) Token: either sealed-box encrypted or plain base64(url)
    let token = if let Some(enc_token) = encrypted_token {
        let public_key = ente_core::crypto::decode_b64(&key_attrs.public_key)
            .map_err(|e| EnsuError::msg(format!("public_key: {e}")))?;
        let sealed_token = ente_core::crypto::decode_b64(&enc_token)
            .map_err(|e| EnsuError::msg(format!("encrypted_token: {e}")))?;

        ente_core::crypto::sealed::open(&sealed_token, &public_key, &secret_key)
            .map_err(|_| EnsuError::msg("Failed to decrypt token"))?
    } else if let Some(plain) = plain_token {
        // Server sometimes returns URL-safe base64; accept both.
        base64::engine::general_purpose::URL_SAFE
            .decode(&plain)
            .or_else(|_| base64::engine::general_purpose::STANDARD.decode(&plain))
            .map_err(|e| EnsuError::msg(format!("token decode: {e}")))?
    } else {
        return Err(EnsuError::msg("No token provided"));
    };

    Ok(AuthSecrets {
        master_key,
        secret_key,
        token,
    })
}

/// Pad bytes to a fixed length by prefixing zeros (Ente SRP wire format).
fn pad_bytes(data: &[u8], len: usize) -> Vec<u8> {
    if data.len() >= len {
        return data.to_vec();
    }
    let mut padded = vec![0u8; len - data.len()];
    padded.extend_from_slice(data);
    padded
}
