//! Comprehensive cryptographic tests including large files.
//!
//! These tests verify the pure Rust implementation with edge cases
//! and large data scenarios.

use ente_core::crypto;
use std::io::Cursor;

#[test]
fn test_stream_encrypt_decrypt_empty() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = b"";

    let encrypted = crypto::stream::encrypt(plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_encrypt_decrypt_small() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = b"Hello, World!";

    let encrypted = crypto::stream::encrypt(plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_encrypt_decrypt_exact_chunk_size() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = vec![0x42u8; crypto::stream::ENCRYPTION_CHUNK_SIZE];

    let encrypted = crypto::stream::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_encrypt_decrypt_multiple_chunks() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    // 2.5 chunks
    let plaintext = vec![
        0x42u8;
        crypto::stream::ENCRYPTION_CHUNK_SIZE * 2
            + crypto::stream::ENCRYPTION_CHUNK_SIZE / 2
    ];

    let encrypted = crypto::stream::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_encrypt_decrypt_10mb() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = vec![0x42u8; 10 * 1024 * 1024]; // 10 MB

    let encrypted = crypto::stream::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted.len(), plaintext.len());
    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_encrypt_decrypt_50mb() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let size = 50 * 1024 * 1024; // 50 MB

    // Use repeating pattern to verify data integrity
    let mut plaintext = Vec::with_capacity(size);
    for i in 0..size {
        plaintext.push((i % 256) as u8);
    }

    let encrypted = crypto::stream::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::stream::decrypt_stream(&encrypted, &key).unwrap();

    assert_eq!(decrypted.len(), plaintext.len());
    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_stream_file_encrypt_decrypt_small() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = b"Test file content";

    let mut source = Cursor::new(plaintext.to_vec());
    let mut encrypted_data = Vec::new();

    let (returned_key, header) =
        crypto::stream::encrypt_file(&mut source, &mut encrypted_data, Some(&key)).unwrap();

    assert_eq!(returned_key, key);

    let mut source = Cursor::new(encrypted_data);
    let mut decrypted_data = Vec::new();

    crypto::stream::decrypt_file(&mut source, &mut decrypted_data, &header, &key).unwrap();

    assert_eq!(decrypted_data, plaintext);
}

#[test]
fn test_stream_file_encrypt_decrypt_5mb() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = vec![0x42u8; 5 * 1024 * 1024];

    let mut source = Cursor::new(plaintext.clone());
    let mut encrypted_data = Vec::new();

    let (_, header) =
        crypto::stream::encrypt_file(&mut source, &mut encrypted_data, Some(&key)).unwrap();

    let mut source = Cursor::new(encrypted_data);
    let mut decrypted_data = Vec::new();

    crypto::stream::decrypt_file(&mut source, &mut decrypted_data, &header, &key).unwrap();

    assert_eq!(decrypted_data, plaintext);
}

#[test]
fn test_stream_file_encrypt_decrypt_50mb() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();

    // Use pattern to verify integrity
    let size = 50 * 1024 * 1024;
    let mut plaintext = Vec::with_capacity(size);
    for i in 0..size {
        plaintext.push((i % 256) as u8);
    }

    let mut source = Cursor::new(plaintext.clone());
    let mut encrypted_data = Vec::new();

    let (_, header) =
        crypto::stream::encrypt_file(&mut source, &mut encrypted_data, Some(&key)).unwrap();

    let mut source = Cursor::new(encrypted_data);
    let mut decrypted_data = Vec::new();

    crypto::stream::decrypt_file(&mut source, &mut decrypted_data, &header, &key).unwrap();

    assert_eq!(decrypted_data.len(), plaintext.len());
    assert_eq!(decrypted_data, plaintext);
}

#[test]
fn test_estimate_encrypted_size() {
    crypto::init().unwrap();

    // Empty
    assert_eq!(
        crypto::stream::estimate_encrypted_size(0),
        crypto::stream::ABYTES
    );

    // Small file
    assert_eq!(
        crypto::stream::estimate_encrypted_size(100),
        100 + crypto::stream::ABYTES
    );

    // Exact chunk size
    assert_eq!(
        crypto::stream::estimate_encrypted_size(crypto::stream::ENCRYPTION_CHUNK_SIZE),
        crypto::stream::ENCRYPTION_CHUNK_SIZE + crypto::stream::ABYTES
    );

    // Multiple chunks
    let size = crypto::stream::ENCRYPTION_CHUNK_SIZE * 3 + 1000;
    let expected = crypto::stream::ENCRYPTION_CHUNK_SIZE * 3
        + crypto::stream::ABYTES * 3
        + 1000
        + crypto::stream::ABYTES;
    assert_eq!(crypto::stream::estimate_encrypted_size(size), expected);
}

#[test]
fn test_validate_sizes() {
    crypto::init().unwrap();

    // Valid sizes
    let plaintext_size = 1000;
    let ciphertext_size = crypto::stream::estimate_encrypted_size(plaintext_size);
    assert!(crypto::stream::validate_sizes(
        plaintext_size,
        ciphertext_size
    ));

    // Invalid - ciphertext too small
    assert!(!crypto::stream::validate_sizes(1000, 100));

    // Invalid - zero sizes
    assert!(!crypto::stream::validate_sizes(0, 0));

    // Large file validation
    let plaintext_size = 50 * 1024 * 1024;
    let ciphertext_size = crypto::stream::estimate_encrypted_size(plaintext_size);
    assert!(crypto::stream::validate_sizes(
        plaintext_size,
        ciphertext_size
    ));
}

#[test]
fn test_hash_streaming_large_file() {
    crypto::init().unwrap();

    // Create 10MB of data
    let data = vec![0x42u8; 10 * 1024 * 1024];

    // Hash all at once
    let hash_direct = crypto::hash::hash_default(&data).unwrap();

    // Hash incrementally in 1MB chunks
    let mut state = crypto::hash::hash_state_new().unwrap();
    for chunk in data.chunks(1024 * 1024) {
        state.update(chunk).unwrap();
    }
    let hash_incremental = state.finalize().unwrap();

    assert_eq!(hash_direct, hash_incremental);
}

#[test]
fn test_hash_streaming_50mb() {
    crypto::init().unwrap();

    // Create 50MB of patterned data
    let size = 50 * 1024 * 1024;
    let mut data = Vec::with_capacity(size);
    for i in 0..size {
        data.push((i % 256) as u8);
    }

    // Hash incrementally in 4MB chunks
    let mut state = crypto::hash::hash_state_new().unwrap();
    for chunk in data.chunks(4 * 1024 * 1024) {
        state.update(chunk).unwrap();
    }
    let hash_result = state.finalize().unwrap();

    assert_eq!(hash_result.len(), 64);
}

#[test]
fn test_sealed_box_large_data() {
    crypto::init().unwrap();
    let (pk, sk) = crypto::keys::generate_keypair().unwrap();

    // 1MB of data
    let plaintext = vec![0x42u8; 1024 * 1024];

    let sealed = crypto::sealed::seal(&plaintext, &pk).unwrap();
    let opened = crypto::sealed::open(&sealed, &pk, &sk).unwrap();

    assert_eq!(opened, plaintext);
}

#[test]
fn test_secretbox_large_data() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_key();

    // 1MB of data
    let plaintext = vec![0x42u8; 1024 * 1024];

    let encrypted = crypto::secretbox::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::secretbox::decrypt_box(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_blob_large_data() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();

    // 1MB of data
    let plaintext = vec![0x42u8; 1024 * 1024];

    let encrypted = crypto::blob::encrypt(&plaintext, &key).unwrap();
    let decrypted = crypto::blob::decrypt_blob(&encrypted, &key).unwrap();

    assert_eq!(decrypted, plaintext);
}

#[test]
fn test_argon2_various_sizes() {
    crypto::init().unwrap();

    let long_password = "very_long_password_".repeat(100);
    let passwords = vec!["short", "medium_length_password", &long_password];

    for password in passwords {
        let salt = crypto::keys::generate_salt();
        let key = crypto::argon::derive_interactive_key_with_salt(password, &salt).unwrap();
        assert_eq!(key.len(), 32);
    }
}

#[test]
fn test_kdf_multiple_subkeys() {
    crypto::init().unwrap();

    let master_key = crypto::keys::generate_key();

    // Derive multiple subkeys with different IDs
    let subkey1 = crypto::kdf::derive_subkey(&master_key, 32, 1, b"context1").unwrap();
    let subkey2 = crypto::kdf::derive_subkey(&master_key, 32, 2, b"context1").unwrap();
    let subkey3 = crypto::kdf::derive_subkey(&master_key, 32, 1, b"context2").unwrap();

    // All should be different
    assert_ne!(subkey1, subkey2);
    assert_ne!(subkey1, subkey3);
    assert_ne!(subkey2, subkey3);

    // But deterministic
    let subkey1_again = crypto::kdf::derive_subkey(&master_key, 32, 1, b"context1").unwrap();
    assert_eq!(subkey1, subkey1_again);
}

#[test]
fn test_stream_wrong_key_fails() {
    crypto::init().unwrap();
    let key1 = crypto::keys::generate_stream_key();
    let key2 = crypto::keys::generate_stream_key();
    let plaintext = b"Secret data";

    let encrypted = crypto::stream::encrypt(plaintext, &key1).unwrap();
    let result = crypto::stream::decrypt_stream(&encrypted, &key2);

    assert!(result.is_err());
}

#[test]
fn test_stream_corrupted_data_fails() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = b"Important data that needs to be protected";

    let mut encrypted = crypto::stream::encrypt(plaintext, &key).unwrap();

    // Corrupt a byte in the encrypted data (skip header area)
    let corruption_pos = encrypted.encrypted_data.len() / 2;
    encrypted.encrypted_data[corruption_pos] ^= 0xFF;

    let result = crypto::stream::decrypt_stream(&encrypted, &key);
    assert!(result.is_err());
}

#[test]
fn test_stream_corrupted_header_fails() {
    crypto::init().unwrap();
    let key = crypto::keys::generate_stream_key();
    let plaintext = b"Important data";

    let encrypted = crypto::stream::encrypt(plaintext, &key).unwrap();

    // Corrupt the header
    let mut corrupted_header = encrypted.decryption_header.clone();
    corrupted_header[5] ^= 0xFF;

    let result = crypto::stream::decrypt(&encrypted.encrypted_data, &corrupted_header, &key);
    assert!(result.is_err());
}

#[test]
fn test_encoding_roundtrips() {
    crypto::init().unwrap();

    let data = b"Test data for encoding";

    // Base64 roundtrip
    let b64 = crypto::encode_b64(data);
    let decoded = crypto::decode_b64(&b64).unwrap();
    assert_eq!(decoded, data);

    // Hex roundtrip
    let hex = crypto::encode_hex(data);
    let decoded = crypto::decode_hex(&hex).unwrap();
    assert_eq!(decoded, data);

    // Base64 to hex
    let hex_from_b64 = crypto::b64_to_hex(&b64).unwrap();
    assert_eq!(hex_from_b64, hex);

    // Hex to base64
    let b64_from_hex = crypto::hex_to_b64(&hex).unwrap();
    assert_eq!(b64_from_hex, b64);
}
