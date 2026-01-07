//! Authentication API exposed to Dart via Flutter Rust Bridge.
//!
//! Provides high-level authentication flows that handle all the crypto complexity.

use flutter_rust_bridge::frb;
use std::sync::Mutex;

// Store active SRP sessions
static SRP_SESSIONS: Mutex<Option<SrpSession>> = Mutex::new(None);

struct SrpSession {
    client: ente_core::auth::SrpAuthClient,
    kek: Vec<u8>,
}

/// SRP attributes from the server.
#[frb]
pub struct SrpAttributes {
    pub srp_user_id: String,
    pub srp_salt: String,
    pub kek_salt: String,
    pub mem_limit: u32,
    pub ops_limit: u32,
    pub is_email_mfa_enabled: bool,
}

/// Key attributes from the server.
#[frb]
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

/// Result of SRP session creation (step 1).
#[frb]
pub struct SrpSessionResult {
    /// Base64-encoded client public value A (send to server as srpA)
    pub srp_a: String,
}

/// Result of SRP verification (step 2).
#[frb]
pub struct SrpVerifyResult {
    /// Base64-encoded client proof M1 (send to server as srpM1)
    pub srp_m1: String,
}

/// Decrypted secrets after authentication.
#[frb]
pub struct AuthSecrets {
    pub master_key: Vec<u8>,
    pub secret_key: Vec<u8>,
    pub token: Vec<u8>,
}

/// Start SRP login flow - derives keys and creates SRP client.
///
/// Call this after getting SRP attributes from server.
/// Returns the client public value A to send to server.
///
/// # Flow
/// 1. Call `srp_start` with password and SRP attributes → get srpA
/// 2. Send srpA to server's `/users/srp/create-session` → get srpB
/// 3. Call `srp_finish` with srpB → get srpM1
/// 4. Send srpM1 to server's `/users/srp/verify-session` → get auth response
/// 5. Call `srp_decrypt_secrets` with key attributes → get decrypted secrets
pub async fn srp_start(
    password: String,
    srp_attrs: SrpAttributes,
) -> Result<SrpSessionResult, String> {
    let core_attrs = ente_core::auth::SrpAttributes {
        srp_user_id: srp_attrs.srp_user_id,
        srp_salt: srp_attrs.srp_salt,
        kek_salt: srp_attrs.kek_salt,
        mem_limit: srp_attrs.mem_limit,
        ops_limit: srp_attrs.ops_limit,
        is_email_mfa_enabled: srp_attrs.is_email_mfa_enabled,
    };

    let (client, kek) =
        ente_core::auth::create_srp_client(&password, &core_attrs).map_err(|e| e.to_string())?;

    let a_pub = client.compute_a();

    // Pad to 512 bytes as per ente protocol
    let padded_a = pad_bytes(&a_pub, 512);
    let srp_a = ente_core::crypto::encode_b64(&padded_a);

    // Store session for later
    let mut sessions = SRP_SESSIONS.lock().unwrap();
    *sessions = Some(SrpSession { client, kek });

    Ok(SrpSessionResult { srp_a })
}

/// Complete SRP handshake - process server's B and compute proof M1.
///
/// Call this after receiving srpB from server's create-session response.
/// Returns the client proof M1 to send to server.
pub fn srp_finish(srp_b: String) -> Result<SrpVerifyResult, String> {
    let server_b =
        ente_core::crypto::decode_b64(&srp_b).map_err(|e| format!("Invalid srpB: {}", e))?;

    let mut sessions = SRP_SESSIONS.lock().unwrap();
    let session = sessions.as_mut().ok_or("No active SRP session")?;

    session.client.set_b(&server_b).map_err(|e| e.to_string())?;

    let m1 = session.client.compute_m1();

    // Pad to 32 bytes as per ente protocol
    let padded_m1 = pad_bytes(&m1, 32);
    let srp_m1 = ente_core::crypto::encode_b64(&padded_m1);

    Ok(SrpVerifyResult { srp_m1 })
}

/// Decrypt secrets after successful SRP authentication.
///
/// Call this after server validates srpM1 and returns key attributes.
/// Uses the KEK from the SRP session to decrypt.
///
/// # Arguments
/// * `key_attrs` - Key attributes from auth response
/// * `encrypted_token` - Sealed box encrypted token (if present)
/// * `plain_token` - Plain base64 token (if encrypted_token is not present)
pub fn srp_decrypt_secrets(
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, String> {
    let kek = {
        let sessions = SRP_SESSIONS.lock().unwrap();
        let session = sessions.as_ref().ok_or("No active SRP session")?;
        session.kek.clone()
    };

    let result = decrypt_secrets_internal(&kek, key_attrs, encrypted_token, plain_token);
    *SRP_SESSIONS.lock().unwrap() = None;
    result
}

/// Internal function to decrypt secrets with provided KEK.
fn decrypt_secrets_internal(
    kek: &[u8],
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, String> {
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

    // Decrypt master key
    let encrypted_key = ente_core::crypto::decode_b64(&core_attrs.encrypted_key)
        .map_err(|e| format!("encrypted_key: {}", e))?;
    let key_nonce = ente_core::crypto::decode_b64(&core_attrs.key_decryption_nonce)
        .map_err(|e| format!("key_decryption_nonce: {}", e))?;
    let master_key = ente_core::crypto::secretbox::decrypt(&encrypted_key, &key_nonce, kek)
        .map_err(|_| "Incorrect password".to_string())?;

    // Decrypt secret key
    let encrypted_secret_key = ente_core::crypto::decode_b64(&core_attrs.encrypted_secret_key)
        .map_err(|e| format!("encrypted_secret_key: {}", e))?;
    let secret_key_nonce = ente_core::crypto::decode_b64(&core_attrs.secret_key_decryption_nonce)
        .map_err(|e| format!("secret_key_decryption_nonce: {}", e))?;
    let secret_key = ente_core::crypto::secretbox::decrypt(
        &encrypted_secret_key,
        &secret_key_nonce,
        &master_key,
    )
    .map_err(|_| "Failed to decrypt secret key".to_string())?;

    // Decrypt token - handle both encrypted and plain token
    let token = if let Some(enc_token) = encrypted_token {
        // Sealed box encrypted token
        let public_key = ente_core::crypto::decode_b64(&key_attrs.public_key)
            .map_err(|e| format!("public_key: {}", e))?;
        let sealed_token = ente_core::crypto::decode_b64(&enc_token)
            .map_err(|e| format!("encrypted_token: {}", e))?;
        ente_core::crypto::sealed::open(&sealed_token, &public_key, &secret_key)
            .map_err(|_| "Failed to decrypt token".to_string())?
    } else if let Some(plain) = plain_token {
        // Plain base64 token (just decode)
        use base64::Engine;
        base64::engine::general_purpose::URL_SAFE
            .decode(&plain)
            .or_else(|_| base64::engine::general_purpose::STANDARD.decode(&plain))
            .map_err(|e| format!("token decode: {}", e))?
    } else {
        return Err("No token provided".to_string());
    };

    Ok(AuthSecrets {
        master_key,
        secret_key,
        token,
    })
}

/// Clear the active SRP session.
pub fn srp_clear() {
    let mut sessions = SRP_SESSIONS.lock().unwrap();
    *sessions = None;
}

/// Derive KEK for email MFA flow (no SRP).
///
/// Use this when email MFA is enabled and SRP is skipped.
pub async fn derive_kek_for_login(
    password: String,
    kek_salt: String,
    mem_limit: u32,
    ops_limit: u32,
) -> Result<Vec<u8>, String> {
    ente_core::auth::derive_kek(&password, &kek_salt, mem_limit, ops_limit)
        .map_err(|e| e.to_string())
}

/// Decrypt secrets with provided KEK (for email MFA flow).
pub fn decrypt_secrets_with_kek(
    kek: Vec<u8>,
    key_attrs: KeyAttributes,
    encrypted_token: Option<String>,
    plain_token: Option<String>,
) -> Result<AuthSecrets, String> {
    decrypt_secrets_internal(&kek, key_attrs, encrypted_token, plain_token)
}

/// Pad bytes to specified length (prepend zeros).
fn pad_bytes(data: &[u8], len: usize) -> Vec<u8> {
    if data.len() >= len {
        return data.to_vec();
    }
    let mut padded = vec![0u8; len - data.len()];
    padded.extend_from_slice(data);
    padded
}
