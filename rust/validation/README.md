# ente-validation

Validation and benchmarks for `ente-core` against libsodium.

## Validation suite

```bash
cargo run -p ente-validation --bin ente-validation
```

Covers cross-implementation checks for secretbox, stream, sealed box, KDF,
Argon2id, and full auth flow.

## Benchmarks

```bash
cargo run -p ente-validation --bin bench
cargo run -p ente-validation --bin bench --release
```

Bench cases include secretbox (1 MiB), stream (1 MiB / 50 MiB), Argon2id,
and auth signup/login (interactive parameters).

To write JSON output:

```bash
BENCH_JSON=bench-rust.json cargo run -p ente-validation --bin bench --release
```

## Requirements

The validation suite uses `libsodium-sys-stable`. Ensure libsodium builds
successfully in your environment (CI toolchain or local install).
