# ente-core

Common Rust code for Ente apps.

## Modules

| Module | Description |
|--------|-------------|
| `crypto` | Cryptographic utilities (pure Rust) |
| `http` | HTTP client for Ente API |
| `urls` | URL construction utilities |

## Crypto

Pure Rust cryptography, byte-compatible with JS/Dart clients.

| Submodule | Algorithm | Use Case |
|-----------|-----------|----------|
| `secretbox` | XSalsa20-Poly1305 | Encrypt keys, small data |
| `blob` | XChaCha20-Poly1305 | Encrypt metadata |
| `stream` | XChaCha20-Poly1305 | Encrypt large files (4MB chunks) |
| `sealed` | X25519 + XSalsa20-Poly1305 | Anonymous public-key encryption |
| `argon` | Argon2id | Password-based key derivation |
| `kdf` | BLAKE2b | Subkey derivation |
| `hash` | BLAKE2b | Cryptographic hashing |
| `keys` | - | Key generation |

### Quick Start

```rust
use ente_core::crypto;

crypto::init().unwrap();

let key = crypto::keys::generate_key();
let encrypted = crypto::secretbox::encrypt(b"Hello", &key).unwrap();
let decrypted = crypto::secretbox::decrypt_box(&encrypted, &key).unwrap();
```

📖 **[Full API Docs](docs/crypto.md)**

## Development

```bash
cargo fmt      # format
cargo clippy   # lint  
cargo build    # build
cargo test     # test
```

## Tests

```
tests/
├── crypto_interop.rs        # 91 integration tests (JS/Dart compatibility)
└── comprehensive_crypto_tests.rs  # 22 stress tests (up to 50MB files)

src/crypto/impl_pure/
└── *.rs                     # 109 unit tests (per-module)
```

**Total: 223 tests**

| Test Suite | Count | What it tests |
|------------|-------|---------------|
| Unit tests | 109 | Individual crypto operations |
| Integration | 91 | Cross-platform compatibility, real workflows |
| Comprehensive | 22 | Large files (50MB), edge cases, stress tests |

### Running Tests

```bash
# All tests
cargo test

# Specific suite
cargo test --test crypto_interop
cargo test --test comprehensive_crypto_tests

# With output
cargo test -- --nocapture
```

### JS Interop Verification

```bash
cd tests
npm install libsodium-wrappers-sumo
node js_interop_test.mjs
```
