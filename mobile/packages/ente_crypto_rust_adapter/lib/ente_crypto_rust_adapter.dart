import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_rust/ente_rust.dart' as rust;

class EnteCryptoRustAdapter implements CryptoApi {
  EnteCryptoRustAdapter({CryptoApi? fallback})
      : _fallback = fallback ?? const EnteCryptoDartAdapter();

  final CryptoApi _fallback;

  static bool _initialized = false;

  @override
  Future<void> init() async {
    // Rust initialization is owned by the app to avoid double-init.
    if (_initialized) {
      return;
    }
    await _fallback.init();
    _initialized = true;
  }

  @override
  Uint8List strToBin(String str) => _fallback.strToBin(str);

  @override
  Uint8List base642bin(String b64) {
    final normalized = _normalizeBase64(b64);
    return rust.base642Bin(data: normalized);
  }

  @override
  String bin2base64(Uint8List bin, {bool urlSafe = false}) {
    return rust.bin2Base64(data: bin, urlSafe: urlSafe);
  }

  @override
  String bin2hex(Uint8List bin) => rust.bin2Hex(data: bin);

  @override
  Uint8List hex2bin(String hex) => rust.hex2Bin(data: hex);

  @override
  EncryptionResult encryptSync(Uint8List source, Uint8List key) {
    final result = rust.encryptSync(plaintext: source, key: key);
    return EncryptionResult(
      encryptedData: result.encryptedData,
      nonce: result.nonce,
    );
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) =>
      rust.decrypt(cipher: cipher, key: key, nonce: nonce);

  @override
  Uint8List decryptSync(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) =>
      rust.decryptSync(cipher: cipher, key: key, nonce: nonce);

  @override
  Future<EncryptionResult> encryptData(Uint8List source, Uint8List key) async {
    final result = rust.encryptData(plaintext: source, key: key);
    return EncryptionResult(
      encryptedData: _decodeBase64(result.encryptedData),
      header: _decodeBase64(result.header),
    );
  }

  @override
  Future<Uint8List> decryptData(
    Uint8List source,
    Uint8List key,
    Uint8List header,
  ) async {
    final encryptedDataB64 = bin2base64(source);
    final headerB64 = bin2base64(header);
    return rust.decryptData(
      encryptedDataB64: encryptedDataB64,
      key: key,
      headerB64: headerB64,
    );
  }

  @override
  Future<EncryptionResult> encryptFile(
    String sourceFilePath,
    String destinationFilePath, {
    Uint8List? key,
  }) {
    return _fallback.encryptFile(
      sourceFilePath,
      destinationFilePath,
      key: key,
    );
  }

  @override
  Future<FileEncryptResult> encryptFileWithMd5(
    String sourceFilePath,
    String destinationFilePath, {
    Uint8List? key,
    int? multiPartChunkSizeInBytes,
  }) {
    return _fallback.encryptFileWithMd5(
      sourceFilePath,
      destinationFilePath,
      key: key,
      multiPartChunkSizeInBytes: multiPartChunkSizeInBytes,
    );
  }

  @override
  Future<void> decryptFile(
    String sourceFilePath,
    String destinationFilePath,
    Uint8List header,
    Uint8List key,
  ) {
    return _fallback.decryptFile(
      sourceFilePath,
      destinationFilePath,
      header,
      key,
    );
  }

  @override
  Uint8List generateKey() => rust.generateKey();

  @override
  CryptoKeyPair generateKeyPair() {
    final pair = rust.generateKeyPair();
    return CryptoKeyPair(
      publicKey: pair.publicKey,
      secretKey: pair.secretKey,
    );
  }

  @override
  Uint8List openSealSync(
    Uint8List input,
    Uint8List publicKey,
    Uint8List secretKey,
  ) =>
      rust.openSealSync(
        cipher: input,
        publicKey: publicKey,
        secretKey: secretKey,
      );

  @override
  Uint8List sealSync(Uint8List input, Uint8List publicKey) {
    return _fallback.sealSync(input, publicKey);
  }

  @override
  Future<DerivedKeyResult> deriveSensitiveKey(
    Uint8List password,
    Uint8List salt,
  ) async {
    final result = await rust.deriveSensitiveKey(
      password: _passwordToString(password),
      salt: salt,
    );
    return DerivedKeyResult(result.key, result.memLimit, result.opsLimit);
  }

  @override
  Future<DerivedKeyResult> deriveInteractiveKey(
    Uint8List password,
    Uint8List salt,
  ) {
    return _fallback.deriveInteractiveKey(password, salt);
  }

  @override
  Future<Uint8List> deriveKey(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) {
    return rust.deriveKey(
      password: _passwordToString(password),
      salt: salt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );
  }

  @override
  Future<Uint8List> deriveLoginKey(Uint8List key) =>
      rust.deriveLoginKey(key: key);

  @override
  Uint8List getSaltToDeriveKey() => rust.getSaltToDeriveKey();

  @override
  Uint8List cryptoPwHash(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) {
    return _fallback.cryptoPwHash(password, salt, memLimit, opsLimit);
  }

  @override
  int get pwhashMemLimitInteractive => _fallback.pwhashMemLimitInteractive;

  @override
  int get pwhashMemLimitSensitive => _fallback.pwhashMemLimitSensitive;

  @override
  int get pwhashOpsLimitInteractive => _fallback.pwhashOpsLimitInteractive;

  @override
  int get pwhashOpsLimitSensitive => _fallback.pwhashOpsLimitSensitive;

  @override
  Future<Uint8List> getHash(File source) => _fallback.getHash(source);

  String _passwordToString(Uint8List password) => utf8.decode(password);

  Uint8List _decodeBase64(String data) => base64.decode(data);

  String _normalizeBase64(String data) {
    var normalized = data.replaceAll('-', '+').replaceAll('_', '/');
    while (normalized.length % 4 != 0) {
      normalized += '=';
    }
    return normalized;
  }
}
