//! Authentication and account management module.
//!
//! Provides cryptographic key management for:
//! - Key generation (signup)
//! - Key decryption (login)
//! - Account recovery
//! - SRP credentials (password-based authentication)
//!
//! ## Quick Start
//!
//! For SRP login flow:
//! ```ignore
//! // 1. Derive SRP credentials from password
//! let creds = auth::derive_srp_credentials(password, &srp_attrs)?;
//!
//! // 2. Use creds.login_key with your SRP client to complete the SRP exchange
//! //    (create session with srpA, then verify with srpM1)
//!
//! // 3. Decrypt secrets
//! let secrets = auth::decrypt_secrets(&creds.kek, &key_attrs, &encrypted_token)?;
//! ```
//!
//! For email MFA flow (no SRP):
//! ```ignore
//! // 1. Derive KEK from password
//! let kek = auth::derive_kek(password, &kek_salt, mem_limit, ops_limit)?;
//!
//! // 2. Do email OTP + TOTP verification via API
//!
//! // 3. Decrypt secrets
//! let secrets = auth::decrypt_secrets(&kek, &key_attrs, &encrypted_token)?;
//! ```

mod api;
mod key_gen;
mod login;
mod recovery;
#[cfg(any(test, feature = "srp"))]
mod srp;
mod types;

// High-level API (recommended for applications)
pub use api::{DecryptedSecrets, SrpCredentials};
pub use api::{decrypt_secrets, derive_kek, derive_srp_credentials};

// Key generation (for signup)
pub use key_gen::{
    KeyDerivationStrength, create_new_recovery_key, generate_key_attributes_for_new_password,
    generate_key_attributes_for_new_password_with_strength, generate_keys,
    generate_keys_with_strength,
};

// Lower-level login utilities (prefer api module for new code)
pub use login::{
    decrypt_secrets as decrypt_secrets_legacy, decrypt_secrets_with_kek, derive_keys_for_login,
    derive_login_key_for_srp,
};

// Recovery
pub use recovery::{get_recovery_key, recover_with_key};

// Types
pub use types::{
    AuthError, KeyAttributes, KeyGenResult, LoginResult, PrivateKeyAttributes, Result,
    SrpAttributes,
};
