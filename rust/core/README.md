# ente-core

Common Rust code for Ente apps.

## Modules

### Crypto (`crypto`)

Full-featured cryptographic utilities built on libsodium, designed to be
interoperable with the JavaScript (`web/packages/base/crypto`) and Dart
(`mobile/apps/photos/plugins/ente_crypto`) implementations.

#### Features

| Module | Description | Algorithm |
|--------|-------------|-----------|
| `crypto::secretbox` | Symmetric encryption for independent data | XSalsa20-Poly1305 |
| `crypto::blob` | Metadata encryption (no chunking) | XChaCha20-Poly1305 |
| `crypto::stream` | Large file encryption with chunking | XChaCha20-Poly1305 |
| `crypto::sealed` | Anonymous public-key encryption | X25519 + XSalsa20-Poly1305 |
| `crypto::argon` | Password-based key derivation | Argon2id |
| `crypto::kdf` | Subkey derivation | BLAKE2b |
| `crypto::hash` | Cryptographic hashing | BLAKE2b |
| `crypto::keys` | Key generation utilities | - |

#### Usage

```rust
use ente_core::crypto;

// Initialize (required once before any crypto operations)
crypto::init().unwrap();

// Generate keys
let key = crypto::keys::generate_key();
let stream_key = crypto::keys::generate_stream_key();

// SecretBox encryption (for independent data)
let encrypted = crypto::secretbox::encrypt(b"Hello", &key).unwrap();
let decrypted = crypto::secretbox::decrypt_box(&encrypted, &key).unwrap();

// Blob encryption (for metadata)
let blob = crypto::blob::encrypt(b"Metadata", &stream_key).unwrap();
let data = crypto::blob::decrypt_blob(&blob, &stream_key).unwrap();

// Stream encryption (for large files)
use std::io::Cursor;
let mut source = Cursor::new(b"File contents".to_vec());
let mut encrypted = Vec::new();
let (key, header) = crypto::stream::encrypt_file(&mut source, &mut encrypted, None).unwrap();

// Key derivation from password
let derived = crypto::argon::derive_interactive_key("password").unwrap();
let login_key = crypto::kdf::derive_login_key(&derived.key).unwrap();

// Public key encryption
let (public_key, secret_key) = crypto::keys::generate_keypair().unwrap();
let sealed = crypto::sealed::seal(b"Secret", &public_key).unwrap();
let opened = crypto::sealed::open(&sealed, &public_key, &secret_key).unwrap();

// Hashing
let hash = crypto::hash::hash_default(b"Data to hash").unwrap();
```

#### Interoperability

The crypto module is designed to produce identical output to the JS library.
Test vectors and a JS verification script are provided in `tests/`:

- `tests/crypto_interop.rs` - Rust integration tests with cross-platform vectors
- `tests/js_interop_test.mjs` - JavaScript test script for verification

To verify JS interoperability:
```bash
cd tests
npm install libsodium-wrappers-sumo
node js_interop_test.mjs
```

### HTTP (`http`)

HTTP client for communicating with the Ente API.

### URLs (`urls`)

URL construction utilities.

## Development

```bash
cargo fmt        # format
cargo clippy     # lint
cargo build      # build
cargo test       # test
```

## Architecture

The crypto module follows the same layered approach as the JS implementation:

1. **Low-level**: Direct libsodium bindings (`libsodium-sys-stable`)
2. **Mid-level**: Individual crypto modules (`secretbox`, `blob`, `stream`, etc.)
3. **High-level**: Re-exports in `crypto` module for easy access

### Encryption Types (Box vs Blob vs Stream)

| Type | Use Case | API |
|------|----------|-----|
| **Box** | Independent data (encrypted keys, etc.) | `secretbox::encrypt/decrypt` |
| **Blob** | Small metadata (<few MB) | `blob::encrypt/decrypt` |
| **Stream** | Large files (chunked at 4MB) | `stream::encrypt/decrypt` |

All three use authenticated encryption, but:
- Box uses a 24-byte nonce
- Blob/Stream use a 24-byte header
- Stream processes data in 4MB chunks with 17 bytes overhead each
