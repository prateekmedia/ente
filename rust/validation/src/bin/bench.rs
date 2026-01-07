//! Simple crypto benchmarks for ente-core (pure Rust) vs libsodium-sys.
//!
//! Run with:
//!   cargo run -p ente-validation --bin bench

use std::collections::BTreeMap;
use std::hint::black_box;
use std::time::{Duration, Instant};

use ente_core::crypto;
use libsodium_sys as sodium;
use serde::Serialize;

const MB: usize = 1024 * 1024;
const STREAM_CHUNK: usize = 64 * 1024;

const ARGON_MEM: u32 = 67_108_864; // 64 MiB
const ARGON_OPS: u32 = 2;

const SECRETBOX_KEY_BYTES: usize = 32;
const SECRETBOX_NONCE_BYTES: usize = 24;

const STREAM_KEY_BYTES: usize = 32;
const STREAM_HEADER_BYTES: usize = 24;
const STREAM_ABYTES: usize = 17;
const STREAM_TAG_MESSAGE: u8 = 0;
const STREAM_TAG_FINAL: u8 = 3;

struct BenchResult {
    case: &'static str,
    implementation: &'static str,
    operation: &'static str,
    size_bytes: usize,
    iterations: usize,
    duration: Duration,
}

impl BenchResult {
    fn ms_per_op(&self) -> f64 {
        self.duration.as_secs_f64() * 1000.0 / self.iterations as f64
    }

    fn size_display(&self) -> String {
        if self.size_bytes == 0 {
            "n/a".to_string()
        } else {
            format!("{:.1}MiB", self.size_bytes as f64 / MB as f64)
        }
    }

    fn rate(&self) -> (&'static str, f64) {
        let seconds = self.duration.as_secs_f64();
        if self.size_bytes == 0 {
            ("ops/s", self.iterations as f64 / seconds)
        } else {
            let mib = self.size_bytes as f64 / MB as f64;
            ("MiB/s", mib * self.iterations as f64 / seconds)
        }
    }
}

#[derive(Serialize)]
struct BenchResultJson {
    case: &'static str,
    implementation: &'static str,
    operation: &'static str,
    size_bytes: usize,
    iterations: usize,
    duration_ms: f64,
}

fn write_json_if_requested(results: &[BenchResult]) {
    let path = match std::env::var("BENCH_JSON") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return,
    };

    let json_results: Vec<BenchResultJson> = results
        .iter()
        .map(|result| BenchResultJson {
            case: result.case,
            implementation: result.implementation,
            operation: result.operation,
            size_bytes: result.size_bytes,
            iterations: result.iterations,
            duration_ms: result.duration.as_secs_f64() * 1000.0,
        })
        .collect();

    let payload = serde_json::json!({ "results": json_results });
    let contents =
        serde_json::to_string_pretty(&payload).expect("Failed to serialize benchmark results");
    std::fs::write(&path, contents).expect("Failed to write benchmark JSON output");
}

fn main() {
    println!("╔══════════════════════════════════════════════════════════════╗");
    println!("║     ente-core vs libsodium Benchmark Suite                  ║");
    println!("╚══════════════════════════════════════════════════════════════╝\n");

    crypto::init().expect("Failed to init ente-core");
    unsafe {
        if sodium::sodium_init() < 0 {
            panic!("Failed to init libsodium");
        }
    }

    let mut results = Vec::new();

    // SecretBox (1 MiB)
    let secretbox_data = vec![0x2a; MB];
    let secretbox_key = vec![0x11; SECRETBOX_KEY_BYTES];
    let secretbox_nonce = vec![0x22; SECRETBOX_NONCE_BYTES];
    let secretbox_iters = 50;

    results.push(bench_secretbox_core_encrypt(
        &secretbox_data,
        &secretbox_key,
        &secretbox_nonce,
        secretbox_iters,
    ));
    results.push(bench_secretbox_core_decrypt(
        &secretbox_data,
        &secretbox_key,
        &secretbox_nonce,
        secretbox_iters,
    ));
    results.push(bench_secretbox_libsodium_encrypt(
        &secretbox_data,
        &secretbox_key,
        &secretbox_nonce,
        secretbox_iters,
    ));
    results.push(bench_secretbox_libsodium_decrypt(
        &secretbox_data,
        &secretbox_key,
        &secretbox_nonce,
        secretbox_iters,
    ));

    // Stream (1 MiB, 50 MiB)
    for &size in &[MB, 50 * MB] {
        let data = vec![0x5a; size];
        let key = vec![0x33; STREAM_KEY_BYTES];
        let iterations = if size >= 50 * MB { 3 } else { 10 };

        results.push(bench_stream_core_encrypt(&data, &key, iterations));
        results.push(bench_stream_core_decrypt(&data, &key, iterations));
        results.push(bench_stream_libsodium_encrypt(&data, &key, iterations));
        results.push(bench_stream_libsodium_decrypt(&data, &key, iterations));
    }

    // Argon2id (interactive params)
    let argon_iters = 3;
    results.push(bench_argon_core(argon_iters));
    results.push(bench_argon_libsodium(argon_iters));

    print_results(&results);
    print_summary(&results);
    write_json_if_requested(&results);
}

fn print_results(results: &[BenchResult]) {
    println!("Impl        | Case        | Op      | Size     | Iters | ms/op     | Rate");
    println!("------------+-------------+---------+----------+-------+-----------+------------");

    for result in results {
        let size = result.size_display();
        let (label, rate) = result.rate();
        println!(
            "{:<11} | {:<11} | {:<7} | {:>8} | {:>5} | {:>9.3} ms/op | {} {:>8.2}",
            result.implementation,
            result.case,
            result.operation,
            size,
            result.iterations,
            result.ms_per_op(),
            label,
            rate
        );
    }
}

fn print_summary(results: &[BenchResult]) {
    let mut groups: BTreeMap<(String, String, usize), Vec<&BenchResult>> = BTreeMap::new();

    for result in results {
        groups
            .entry((
                result.case.to_string(),
                result.operation.to_string(),
                result.size_bytes,
            ))
            .or_default()
            .push(result);
    }

    println!("\nWinner Summary (lower ms/op wins)");

    for ((case, operation, size_bytes), mut entries) in groups {
        entries.sort_by(|a, b| {
            a.ms_per_op()
                .partial_cmp(&b.ms_per_op())
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        let size_label = size_label(size_bytes);

        if entries.len() == 1 {
            println!(
                "- {} {} {}: {} only",
                case, operation, size_label, entries[0].implementation
            );
            continue;
        }

        let best = entries[0];
        let runner_up = entries[1];
        let best_ms = best.ms_per_op();
        let runner_ms = runner_up.ms_per_op();
        let percent = if runner_ms > 0.0 {
            (runner_ms - best_ms) / runner_ms * 100.0
        } else {
            0.0
        };

        println!(
            "- {} {} {}: {} by {:.1}%",
            case, operation, size_label, best.implementation, percent
        );
    }
}

fn size_label(size_bytes: usize) -> String {
    if size_bytes == 0 {
        "n/a".to_string()
    } else {
        format!("{:.1}MiB", size_bytes as f64 / MB as f64)
    }
}

fn bench_secretbox_core_encrypt(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    iterations: usize,
) -> BenchResult {
    let mut sink = 0u64;
    let start = Instant::now();
    for _ in 0..iterations {
        let ciphertext = crypto::secretbox::encrypt_with_nonce(plaintext, nonce, key).unwrap();
        sink ^= ciphertext[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "secretbox",
        implementation: "rust-core",
        operation: "encrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_secretbox_core_decrypt(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    iterations: usize,
) -> BenchResult {
    let ciphertext = crypto::secretbox::encrypt_with_nonce(plaintext, nonce, key).unwrap();
    let mut sink = 0u64;
    let start = Instant::now();
    for _ in 0..iterations {
        let decrypted = crypto::secretbox::decrypt(&ciphertext, nonce, key).unwrap();
        sink ^= decrypted[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "secretbox",
        implementation: "rust-core",
        operation: "decrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_secretbox_libsodium_encrypt(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    iterations: usize,
) -> BenchResult {
    let mut sink = 0u64;
    let start = Instant::now();
    for _ in 0..iterations {
        let ciphertext = libsodium_secretbox_encrypt(plaintext, nonce, key);
        sink ^= ciphertext[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "secretbox",
        implementation: "libsodium",
        operation: "encrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_secretbox_libsodium_decrypt(
    plaintext: &[u8],
    key: &[u8],
    nonce: &[u8],
    iterations: usize,
) -> BenchResult {
    let ciphertext = libsodium_secretbox_encrypt(plaintext, nonce, key);
    let mut sink = 0u64;
    let start = Instant::now();
    for _ in 0..iterations {
        let decrypted = libsodium_secretbox_decrypt(&ciphertext, nonce, key);
        sink ^= decrypted[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "secretbox",
        implementation: "libsodium",
        operation: "decrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_stream_core_encrypt(plaintext: &[u8], key: &[u8], iterations: usize) -> BenchResult {
    let chunks = chunk_count(plaintext.len());
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let mut encryptor = crypto::stream::StreamEncryptor::new(key).unwrap();
        for (index, chunk) in plaintext.chunks(STREAM_CHUNK).enumerate() {
            let is_final = index + 1 == chunks;
            let ciphertext = encryptor.push(chunk, is_final).unwrap();
            sink ^= ciphertext[0] as u64;
        }
        sink ^= encryptor.header[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "stream",
        implementation: "rust-core",
        operation: "encrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_stream_core_decrypt(plaintext: &[u8], key: &[u8], iterations: usize) -> BenchResult {
    let (cipher_chunks, header) = build_core_stream_ciphertext(plaintext, key);
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let mut decryptor = crypto::stream::StreamDecryptor::new(&header, key).unwrap();
        for chunk in &cipher_chunks {
            let (decrypted, _tag) = decryptor.pull(chunk).unwrap();
            sink ^= decrypted[0] as u64;
        }
    }
    black_box(sink);

    BenchResult {
        case: "stream",
        implementation: "rust-core",
        operation: "decrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_stream_libsodium_encrypt(plaintext: &[u8], key: &[u8], iterations: usize) -> BenchResult {
    let chunks = chunk_count(plaintext.len());
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let mut encryptor = LibsodiumStreamEncryptor::new(key);
        for (index, chunk) in plaintext.chunks(STREAM_CHUNK).enumerate() {
            let is_final = index + 1 == chunks;
            let ciphertext = encryptor.push(chunk, is_final);
            sink ^= ciphertext[0] as u64;
        }
        sink ^= encryptor.header[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "stream",
        implementation: "libsodium",
        operation: "encrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_stream_libsodium_decrypt(plaintext: &[u8], key: &[u8], iterations: usize) -> BenchResult {
    let (cipher_chunks, header) = build_libsodium_stream_ciphertext(plaintext, key);
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let mut decryptor = LibsodiumStreamDecryptor::new(key, &header).unwrap();
        for chunk in &cipher_chunks {
            let (decrypted, _tag) = decryptor.pull(chunk).unwrap();
            sink ^= decrypted[0] as u64;
        }
    }
    black_box(sink);

    BenchResult {
        case: "stream",
        implementation: "libsodium",
        operation: "decrypt",
        size_bytes: plaintext.len(),
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_argon_core(iterations: usize) -> BenchResult {
    let password = "benchmark-password";
    let salt = [0x7b; 16];
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let key = crypto::argon::derive_key(password, &salt, ARGON_MEM, ARGON_OPS).unwrap();
        sink ^= key[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "argon2id",
        implementation: "rust-core",
        operation: "derive",
        size_bytes: 0,
        iterations,
        duration: start.elapsed(),
    }
}

fn bench_argon_libsodium(iterations: usize) -> BenchResult {
    let password = "benchmark-password";
    let salt = [0x7b; 16];
    let mut sink = 0u64;

    let start = Instant::now();
    for _ in 0..iterations {
        let key = libsodium_argon2(password, &salt, ARGON_MEM, ARGON_OPS);
        sink ^= key[0] as u64;
    }
    black_box(sink);

    BenchResult {
        case: "argon2id",
        implementation: "libsodium",
        operation: "derive",
        size_bytes: 0,
        iterations,
        duration: start.elapsed(),
    }
}

fn libsodium_argon2(password: &str, salt: &[u8], mem_limit: u32, ops_limit: u32) -> Vec<u8> {
    let mut key = vec![0u8; 32];
    let result = unsafe {
        sodium::crypto_pwhash(
            key.as_mut_ptr(),
            key.len() as u64,
            password.as_ptr() as *const i8,
            password.len() as u64,
            salt.as_ptr(),
            ops_limit as u64,
            mem_limit as usize,
            sodium::crypto_pwhash_ALG_ARGON2ID13 as i32,
        )
    };
    assert_eq!(result, 0, "libsodium argon2 failed");
    key
}

fn libsodium_secretbox_encrypt(plaintext: &[u8], nonce: &[u8], key: &[u8]) -> Vec<u8> {
    let mac_bytes = sodium::crypto_secretbox_MACBYTES as usize;
    let mut ciphertext = vec![0u8; plaintext.len() + mac_bytes];
    unsafe {
        sodium::crypto_secretbox_easy(
            ciphertext.as_mut_ptr(),
            plaintext.as_ptr(),
            plaintext.len() as u64,
            nonce.as_ptr(),
            key.as_ptr(),
        );
    }
    ciphertext
}

fn libsodium_secretbox_decrypt(ciphertext: &[u8], nonce: &[u8], key: &[u8]) -> Vec<u8> {
    let mac_bytes = sodium::crypto_secretbox_MACBYTES as usize;
    let mut plaintext = vec![0u8; ciphertext.len() - mac_bytes];
    let result = unsafe {
        sodium::crypto_secretbox_open_easy(
            plaintext.as_mut_ptr(),
            ciphertext.as_ptr(),
            ciphertext.len() as u64,
            nonce.as_ptr(),
            key.as_ptr(),
        )
    };
    assert_eq!(result, 0, "libsodium secretbox decrypt failed");
    plaintext
}

fn build_core_stream_ciphertext(plaintext: &[u8], key: &[u8]) -> (Vec<Vec<u8>>, Vec<u8>) {
    let chunks = chunk_count(plaintext.len());
    let mut encryptor = crypto::stream::StreamEncryptor::new(key).unwrap();
    let mut ciphertext = Vec::with_capacity(chunks);

    for (index, chunk) in plaintext.chunks(STREAM_CHUNK).enumerate() {
        let is_final = index + 1 == chunks;
        ciphertext.push(encryptor.push(chunk, is_final).unwrap());
    }

    (ciphertext, encryptor.header)
}

fn build_libsodium_stream_ciphertext(
    plaintext: &[u8],
    key: &[u8],
) -> (Vec<Vec<u8>>, [u8; STREAM_HEADER_BYTES]) {
    let chunks = chunk_count(plaintext.len());
    let mut encryptor = LibsodiumStreamEncryptor::new(key);
    let mut ciphertext = Vec::with_capacity(chunks);

    for (index, chunk) in plaintext.chunks(STREAM_CHUNK).enumerate() {
        let is_final = index + 1 == chunks;
        ciphertext.push(encryptor.push(chunk, is_final));
    }

    (ciphertext, encryptor.header)
}

fn chunk_count(len: usize) -> usize {
    len.div_ceil(STREAM_CHUNK)
}

struct LibsodiumStreamEncryptor {
    state: sodium::crypto_secretstream_xchacha20poly1305_state,
    header: [u8; STREAM_HEADER_BYTES],
}

impl LibsodiumStreamEncryptor {
    fn new(key: &[u8]) -> Self {
        let mut state = sodium::crypto_secretstream_xchacha20poly1305_state {
            k: [0u8; 32],
            nonce: [0u8; 12],
            _pad: [0u8; 8],
        };
        let mut header = [0u8; STREAM_HEADER_BYTES];
        unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_init_push(
                &mut state,
                header.as_mut_ptr(),
                key.as_ptr(),
            );
        }
        Self { state, header }
    }

    fn push(&mut self, plaintext: &[u8], is_final: bool) -> Vec<u8> {
        let tag = if is_final {
            STREAM_TAG_FINAL
        } else {
            STREAM_TAG_MESSAGE
        };
        let mut ciphertext = vec![0u8; plaintext.len() + STREAM_ABYTES];
        unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_push(
                &mut self.state,
                ciphertext.as_mut_ptr(),
                std::ptr::null_mut(),
                plaintext.as_ptr(),
                plaintext.len() as u64,
                std::ptr::null(),
                0,
                tag,
            );
        }
        ciphertext
    }
}

struct LibsodiumStreamDecryptor {
    state: sodium::crypto_secretstream_xchacha20poly1305_state,
}

impl LibsodiumStreamDecryptor {
    fn new(key: &[u8], header: &[u8; STREAM_HEADER_BYTES]) -> Option<Self> {
        let mut state = sodium::crypto_secretstream_xchacha20poly1305_state {
            k: [0u8; 32],
            nonce: [0u8; 12],
            _pad: [0u8; 8],
        };
        let result = unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_init_pull(
                &mut state,
                header.as_ptr(),
                key.as_ptr(),
            )
        };
        if result == 0 {
            Some(Self { state })
        } else {
            None
        }
    }

    fn pull(&mut self, ciphertext: &[u8]) -> Option<(Vec<u8>, u8)> {
        if ciphertext.len() < STREAM_ABYTES {
            return None;
        }

        let mut plaintext = vec![0u8; ciphertext.len() - STREAM_ABYTES];
        let mut tag: u8 = 0;
        let result = unsafe {
            sodium::crypto_secretstream_xchacha20poly1305_pull(
                &mut self.state,
                plaintext.as_mut_ptr(),
                std::ptr::null_mut(),
                &mut tag,
                ciphertext.as_ptr(),
                ciphertext.len() as u64,
                std::ptr::null(),
                0,
            )
        };

        if result == 0 {
            Some((plaintext, tag))
        } else {
            None
        }
    }
}
