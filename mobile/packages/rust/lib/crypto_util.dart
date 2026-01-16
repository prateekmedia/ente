/// CryptoUtil compatibility layer.
///
/// This provides a drop-in replacement for the CryptoUtil class from ente_crypto_dart,
/// backed by the Rust implementation via flutter_rust_bridge.
library;

import 'dart:typed_data';
import 'package:ente_rust/src/rust/api/crypto.dart' as crypto;

/// Result from encryption with separate nonce.
class EncryptResult {
  final Uint8List? encryptedData;
  final Uint8List? nonce;

  EncryptResult({this.encryptedData, this.nonce});
}

/// Result from key derivation with secure parameters.
class DerivedKeyResult {
  final Uint8List key;
  final int memLimit;
  final int opsLimit;

  DerivedKeyResult({
    required this.key,
    required this.memLimit,
    required this.opsLimit,
  });
}

/// Key pair for asymmetric encryption.
class KeyPair {
  final Uint8List publicKey;
  final SecretKey secretKey;

  KeyPair({required this.publicKey, required this.secretKey});
}

/// Secret key wrapper (compatible with existing API).
class SecretKey {
  final Uint8List _bytes;

  SecretKey(this._bytes);

  Uint8List extractBytes() => _bytes;
}

/// CryptoUtil compatible API backed by Rust crypto core.
class CryptoUtil {
  CryptoUtil._();

  /// Initialize the crypto backend.
  static Future<void> init() async {
    crypto.initCrypto();
  }

  // ============================================================================
  // Base64/Hex encoding utilities
  // ============================================================================

  /// Convert bytes to base64 string.
  static String bin2base64(Uint8List data, {bool urlSafe = false}) {
    return crypto.bin2Base64(data: data, urlSafe: urlSafe);
  }

  /// Convert base64 string to bytes.
  static Uint8List base642bin(String data) {
    return crypto.base642Bin(data: data);
  }

  /// Convert hex string to bytes.
  static Uint8List hex2bin(String data) {
    return crypto.hex2Bin(data: data);
  }

  /// Convert bytes to hex string.
  static String bin2hex(Uint8List data) {
    return crypto.bin2Hex(data: data);
  }

  // ============================================================================
  // Key generation
  // ============================================================================

  /// Generate a random 256-bit key.
  static Uint8List generateKey() {
    return crypto.generateKey();
  }

  /// Generate a key pair for asymmetric encryption.
  static KeyPair generateKeyPair() {
    final pair = crypto.generateKeyPair();
    return KeyPair(
      publicKey: pair.publicKey,
      secretKey: SecretKey(pair.secretKey),
    );
  }

  /// Generate a salt for key derivation.
  static Uint8List getSaltToDeriveKey() {
    return crypto.getSaltToDeriveKey();
  }

  // ============================================================================
  // SecretBox encryption
  // ============================================================================

  /// Encrypt with SecretBox returning encrypted data and nonce (synchronous).
  static EncryptResult encryptSync(Uint8List plaintext, Uint8List key) {
    final result = crypto.encryptSync(plaintext: plaintext, key: key);
    return EncryptResult(
      encryptedData: result.encryptedData,
      nonce: result.nonce,
    );
  }

  /// Decrypt with separate nonce (synchronous).
  static Uint8List decryptSync(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) {
    return crypto.decryptSync(
      cipher: cipher,
      key: key,
      nonce: nonce,
    );
  }

  /// Decrypt with separate nonce (async).
  static Future<Uint8List> decrypt(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) async {
    return await crypto.decrypt(
      cipher: cipher,
      key: key,
      nonce: nonce,
    );
  }

  // ============================================================================
  // Sealed box
  // ============================================================================

  /// Open a sealed box (synchronous).
  static Uint8List openSealSync(
    Uint8List cipher,
    Uint8List publicKey,
    Uint8List secretKey,
  ) {
    return crypto.openSealSync(
      cipher: cipher,
      publicKey: publicKey,
      secretKey: secretKey,
    );
  }

  // ============================================================================
  // Key derivation
  // ============================================================================

  /// Derive a key from password using Argon2id.
  static Future<Uint8List> deriveKey(
    String password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) async {
    return await crypto.deriveKey(
      password: password,
      salt: salt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );
  }

  /// Derive a key with sensitive (secure) parameters.
  static Future<DerivedKeyResult> deriveSensitiveKey(
    String password,
    Uint8List salt,
  ) async {
    final result =
        await crypto.deriveSensitiveKey(password: password, salt: salt);
    return DerivedKeyResult(
      key: result.key,
      memLimit: result.memLimit,
      opsLimit: result.opsLimit,
    );
  }

  /// Derive login key from KEK.
  static Future<Uint8List> deriveLoginKey(Uint8List key) async {
    return await crypto.deriveLoginKey(key: key);
  }
}
