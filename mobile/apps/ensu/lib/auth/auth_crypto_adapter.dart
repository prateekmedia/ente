import 'dart:convert';
import 'dart:typed_data';

import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart'
    show CryptoCrossCheckAuthVerifier;
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_rust/ente_rust.dart' as rust;

abstract class AuthCryptoAdapter {
  Future<rust.SrpSessionResult> srpStart({
    required String password,
    required rust.SrpAttributes srpAttrs,
  });

  Future<rust.SrpVerifyResult> srpFinish({
    required String srpB,
  });

  Future<rust.AuthSecrets> srpDecryptSecrets({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  });

  Future<void> srpClear();

  Future<Uint8List> deriveKekForLogin({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
  });

  Future<rust.AuthSecrets> decryptSecretsWithKek({
    required Uint8List kek,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  });
}

class CrossCheckedAuthCryptoAdapter implements AuthCryptoAdapter {
  CrossCheckedAuthCryptoAdapter({
    CryptoCrossCheckAuthVerifier? verifier,
    EnteCryptoDartAdapter? dartAdapter,
  })  : _verifier = verifier ?? CryptoCrossCheckAuthVerifier.instance,
        _dart = dartAdapter ?? const EnteCryptoDartAdapter();

  final CryptoCrossCheckAuthVerifier _verifier;
  final EnteCryptoDartAdapter _dart;

  @override
  Future<rust.SrpSessionResult> srpStart({
    required String password,
    required rust.SrpAttributes srpAttrs,
  }) {
    // SRP start contains randomness (ephemeral A), so there’s no deterministic
    // Dart parity check for the whole output.
    return rust.srpStart(password: password, srpAttrs: srpAttrs);
  }

  @override
  Future<rust.SrpVerifyResult> srpFinish({
    required String srpB,
  }) {
    // SRP finish depends on the random SRP session state created in srpStart.
    return rust.srpFinish(srpB: srpB);
  }

  @override
  Future<rust.AuthSecrets> srpDecryptSecrets({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  }) async {
    final secrets = await rust.srpDecryptSecrets(
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
    );

    // Cross-check by re-deriving KEK in Dart from the password + SRP attributes,
    // then decrypting and comparing secrets deterministically.
    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    final salt = _dart.base642bin(kekSalt);
    final dartKek = await _dart.deriveKey(
      passwordBytes,
      salt,
      memLimit,
      opsLimit,
    );

    await _verifier.verifyAuthSecretsWithKek(
      kek: dartKek,
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
      rustSecrets: secrets,
      label: 'srpDecryptSecrets',
    );

    return secrets;
  }

  @override
  Future<void> srpClear() async {
    await rust.srpClear();
  }

  @override
  Future<Uint8List> deriveKekForLogin({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
  }) async {
    final kek = await rust.deriveKekForLogin(
      password: password,
      kekSalt: kekSalt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );

    await _verifier.verifyKekForLogin(
      password: password,
      kekSaltB64: kekSalt,
      memLimit: memLimit,
      opsLimit: opsLimit,
      rustKek: kek,
      label: 'deriveKekForLogin',
    );

    return kek;
  }

  @override
  Future<rust.AuthSecrets> decryptSecretsWithKek({
    required Uint8List kek,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  }) async {
    final secrets = await rust.decryptSecretsWithKek(
      kek: kek,
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
    );

    await _verifier.verifyAuthSecretsWithKek(
      kek: kek,
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
      rustSecrets: secrets,
      label: 'decryptSecretsWithKek',
    );

    return secrets;
  }
}

class RustOnlyAuthCryptoAdapter implements AuthCryptoAdapter {
  @override
  Future<rust.SrpSessionResult> srpStart({
    required String password,
    required rust.SrpAttributes srpAttrs,
  }) {
    return rust.srpStart(password: password, srpAttrs: srpAttrs);
  }

  @override
  Future<rust.SrpVerifyResult> srpFinish({
    required String srpB,
  }) {
    return rust.srpFinish(srpB: srpB);
  }

  @override
  Future<rust.AuthSecrets> srpDecryptSecrets({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  }) {
    return rust.srpDecryptSecrets(
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
    );
  }

  @override
  Future<void> srpClear() async {
    await rust.srpClear();
  }

  @override
  Future<Uint8List> deriveKekForLogin({
    required String password,
    required String kekSalt,
    required int memLimit,
    required int opsLimit,
  }) {
    return rust.deriveKekForLogin(
      password: password,
      kekSalt: kekSalt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );
  }

  @override
  Future<rust.AuthSecrets> decryptSecretsWithKek({
    required Uint8List kek,
    required rust.KeyAttributes keyAttrs,
    required String? encryptedToken,
    required String? plainToken,
  }) {
    return rust.decryptSecretsWithKek(
      kek: kek,
      keyAttrs: keyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
    );
  }
}
