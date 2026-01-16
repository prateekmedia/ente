import 'dart:convert';
import 'dart:typed_data';

import 'package:ente_crypto_cross_check_adapter/src/crypto_cross_check_exception.dart';
import 'package:ente_crypto_cross_check_adapter/src/crypto_cross_check_utils.dart';
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_rust/ente_rust.dart' as rust;

class CryptoCrossCheckAuthVerifier {
  CryptoCrossCheckAuthVerifier({EnteCryptoDartAdapter? dartAdapter})
      : _dart = dartAdapter ?? const EnteCryptoDartAdapter();

  static final CryptoCrossCheckAuthVerifier instance =
      CryptoCrossCheckAuthVerifier();

  final EnteCryptoDartAdapter _dart;

  Future<void> verifyKekForLogin({
    required String password,
    required String kekSaltB64,
    required int memLimit,
    required int opsLimit,
    required Uint8List rustKek,
    required String label,
  }) async {
    try {
      final passwordBytes = Uint8List.fromList(utf8.encode(password));
      final salt = _dart.base642bin(kekSaltB64);
      final dartKek = await _dart.deriveKey(
        passwordBytes,
        salt,
        memLimit,
        opsLimit,
      );
      assertEqualBytes(dartKek, rustKek, '$label:kek', redact: true);
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      failCrossCheck(label, 'kek derivation failed (${e.runtimeType})');
    }
  }

  Future<void> verifyAuthSecretsWithKek({
    required Uint8List kek,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
    required rust.AuthSecrets rustSecrets,
    required String label,
  }) async {
    try {
      final masterKey = _decryptSecretBoxB64(
        cipherB64: keyAttrs.encryptedKey,
        nonceB64: keyAttrs.keyDecryptionNonce,
        key: kek,
      );
      assertEqualBytes(
        masterKey,
        rustSecrets.masterKey,
        '$label:masterKey',
        redact: true,
      );
      _verifyAuthSecretsWithMasterKey(
        masterKey: masterKey,
        keyAttrs: keyAttrs,
        encryptedToken: encryptedToken,
        plainToken: plainToken,
        rustSecrets: rustSecrets,
        label: label,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      failCrossCheck(label, 'auth decrypt failed (${e.runtimeType})');
    }
  }

  Future<void> verifyAuthSecretsWithMasterKey({
    required Uint8List masterKey,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
    required rust.AuthSecrets rustSecrets,
    required String label,
  }) async {
    try {
      _verifyAuthSecretsWithMasterKey(
        masterKey: masterKey,
        keyAttrs: keyAttrs,
        encryptedToken: encryptedToken,
        plainToken: plainToken,
        rustSecrets: rustSecrets,
        label: label,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      failCrossCheck(label, 'auth decrypt failed (${e.runtimeType})');
    }
  }

  void _verifyAuthSecretsWithMasterKey({
    required Uint8List masterKey,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
    required rust.AuthSecrets rustSecrets,
    required String label,
  }) {
    final secretKey = _decryptSecretBoxB64(
      cipherB64: keyAttrs.encryptedSecretKey,
      nonceB64: keyAttrs.secretKeyDecryptionNonce,
      key: masterKey,
    );
    assertEqualBytes(
      secretKey,
      rustSecrets.secretKey,
      '$label:secretKey',
      redact: true,
    );

    final token = _decryptToken(
      encryptedToken: encryptedToken,
      plainToken: plainToken,
      publicKeyB64: keyAttrs.publicKey,
      secretKey: secretKey,
    );
    assertEqualBytes(
      token,
      rustSecrets.token,
      '$label:token',
      redact: true,
    );
  }

  Uint8List _decryptSecretBoxB64({
    required String cipherB64,
    required String nonceB64,
    required Uint8List key,
  }) {
    final cipher = _dart.base642bin(cipherB64);
    final nonce = _dart.base642bin(nonceB64);
    return _dart.decryptSync(cipher, key, nonce);
  }

  Uint8List _decryptToken({
    required String? encryptedToken,
    required String? plainToken,
    required String publicKeyB64,
    required Uint8List secretKey,
  }) {
    if (encryptedToken != null) {
      final publicKey = _dart.base642bin(publicKeyB64);
      final sealed = _dart.base642bin(encryptedToken);
      return _dart.openSealSync(sealed, publicKey, secretKey);
    }
    if (plainToken != null) {
      return _decodeBase64Flexible(plainToken);
    }
    failCrossCheck('authToken', 'missing encrypted or plain token');
  }

  Uint8List _decodeBase64Flexible(String data) {
    try {
      return base64Url.decode(base64Url.normalize(data));
    } catch (_) {
      return base64.decode(base64.normalize(data));
    }
  }
}
