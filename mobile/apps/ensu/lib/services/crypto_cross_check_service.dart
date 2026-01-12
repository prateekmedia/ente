import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:ente_crypto_dart/ente_crypto_dart.dart' as dart_crypto;
import 'package:ente_rust/ente_rust.dart' as rust;
import 'package:logging/logging.dart';

class CryptoCrossCheckException implements Exception {
  final String label;

  CryptoCrossCheckException(this.label);

  @override
  String toString() => 'CryptoCrossCheckException: $label';
}

class CryptoCrossCheckService {
  CryptoCrossCheckService._();

  static final CryptoCrossCheckService instance = CryptoCrossCheckService._();

  final Logger _logger = Logger('CryptoCrossCheck');
  static const ListEquality<int> _bytesEqual = ListEquality<int>();

  Future<void>? _deterministicChecksFuture;

  Future<void> run() async {
    _logger.fine('Starting crypto cross-checks');
    try {
      await _ensureDeterministicChecks();
      await _runNonDeterministicChecks();
      _logger.fine('Crypto cross-checks passed');
    } catch (e, s) {
      _logger.severe('Crypto cross-checks failed', e, s);
      rethrow;
    }
  }

  Uint8List decodeB64CrossChecked({
    required String data,
    required String label,
  }) {
    final rustDecoded = rust.decodeB64(data: data);
    final dartDecoded = dart_crypto.CryptoUtil.base642bin(data);

    _assertEqualBytes(
      rustDecoded,
      dartDecoded,
      '$label:decodeB64',
      redact: true,
    );

    return rustDecoded;
  }

  String encodeB64CrossChecked({
    required Uint8List data,
    required String label,
  }) {
    final rustEncoded = rust.encodeB64(data: data);
    final dartEncoded = dart_crypto.CryptoUtil.bin2base64(data);

    _assertEqualString(
      rustEncoded,
      dartEncoded,
      '$label:encodeB64',
    );

    return rustEncoded;
  }

  Uint8List generateKeyCrossChecked({
    required String label,
  }) {
    final rustKey = rust.generateKey();
    final dartKey = dart_crypto.CryptoUtil.generateKey();

    _assertEqualInt(
      rustKey.length,
      dartKey.length,
      '$label:generateKeyLength',
    );
    if (rustKey.isEmpty || dartKey.isEmpty) {
      _fail('$label:generateKeyEmpty', 'Generated key is empty');
    }

    final probe = Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]);
    final rustEncrypted = rust.encryptSync(plaintext: probe, key: rustKey);
    final dartPlain = dart_crypto.CryptoUtil.decryptSync(
      rustEncrypted.encryptedData,
      rustKey,
      rustEncrypted.nonce,
    );
    _assertEqualBytes(
      dartPlain,
      probe,
      '$label:rustKeyEncrypt->dartDecrypt',
      redact: true,
    );

    final dartEncrypted = dart_crypto.CryptoUtil.encryptSync(probe, dartKey);
    final rustPlain = rust.decryptSync(
      cipher: dartEncrypted.encryptedData!,
      key: dartKey,
      nonce: dartEncrypted.nonce!,
    );
    _assertEqualBytes(
      rustPlain,
      probe,
      '$label:dartKeyEncrypt->rustDecrypt',
      redact: true,
    );

    return Uint8List.fromList(rustKey);
  }

  /// Encrypt using rust (ente_rust), but validate both directions:
  /// - rust encrypt -> dart decrypt
  /// - dart encrypt -> rust decrypt
  Future<rust.EncryptedData> encryptDataCrossChecked({
    required Uint8List plaintext,
    required Uint8List key,
    required String label,
  }) async {
    final encrypted = rust.encryptData(
      plaintext: plaintext,
      key: key,
    );
    await verifyEncryptedData(
      plaintext: plaintext,
      encryptedDataB64: encrypted.encryptedData,
      headerB64: encrypted.header,
      key: key,
      label: label,
    );
    return encrypted;
  }

  /// Decrypt using both implementations and assert they match.
  /// Returns the rust plaintext.
  Future<Uint8List> decryptDataCrossChecked({
    required String encryptedDataB64,
    required String headerB64,
    required Uint8List key,
    required String label,
  }) async {
    await _ensureDeterministicChecks();

    final rustPlain = rust.decryptData(
      encryptedDataB64: encryptedDataB64,
      key: key,
      headerB64: headerB64,
    );

    final dartPlain = await dart_crypto.CryptoUtil.decryptData(
      dart_crypto.CryptoUtil.base642bin(encryptedDataB64),
      key,
      dart_crypto.CryptoUtil.base642bin(headerB64),
    );

    _assertEqualBytes(
      rustPlain,
      dartPlain,
      '$label:decryptParity',
      redact: true,
    );

    return rustPlain;
  }

  /// Encrypt using rust secretbox, but validate both directions:
  /// - rust encrypt -> dart decrypt
  /// - dart encrypt -> rust decrypt
  rust.EncryptedResult encryptSecretboxCrossChecked({
    required Uint8List plaintext,
    required Uint8List key,
    required String label,
  }) {
    final encrypted = rust.encryptSync(
      plaintext: plaintext,
      key: key,
    );

    verifySecretboxEncryption(
      plaintext: plaintext,
      cipher: encrypted.encryptedData,
      nonce: encrypted.nonce,
      key: key,
      label: label,
    );

    return encrypted;
  }

  /// Decrypt using both implementations and assert they match.
  /// Returns the rust plaintext.
  Uint8List decryptSecretboxCrossChecked({
    required Uint8List cipher,
    required Uint8List nonce,
    required Uint8List key,
    required String label,
  }) {
    final rustPlain = rust.decryptSync(
      cipher: cipher,
      key: key,
      nonce: nonce,
    );
    final dartPlain = dart_crypto.CryptoUtil.decryptSync(
      cipher,
      key,
      nonce,
    );

    _assertEqualBytes(
      rustPlain,
      dartPlain,
      '$label:secretboxDecryptParity',
      redact: true,
    );

    return rustPlain;
  }

  Future<void> verifyEncryptedData({
    required Uint8List plaintext,
    required String encryptedDataB64,
    required String headerB64,
    required Uint8List key,
    required String label,
  }) async {
    await _ensureDeterministicChecks();

    try {
      final rustPlain = rust.decryptData(
        encryptedDataB64: encryptedDataB64,
        key: key,
        headerB64: headerB64,
      );
      _assertEqualBytes(
        rustPlain,
        plaintext,
        '$label:rustDecryptData',
        redact: true,
      );

      final dartPlain = await dart_crypto.CryptoUtil.decryptData(
        dart_crypto.CryptoUtil.base642bin(encryptedDataB64),
        key,
        dart_crypto.CryptoUtil.base642bin(headerB64),
      );
      _assertEqualBytes(
        dartPlain,
        plaintext,
        '$label:dartDecryptData',
        redact: true,
      );

      // Dart encrypt -> rust decrypt (encryption is non-deterministic, so only
      // validate round-trip correctness).
      final dartEncrypted = await dart_crypto.CryptoUtil.encryptData(
        plaintext,
        key,
      );
      final dartEncryptedDataB64 =
          dart_crypto.CryptoUtil.bin2base64(dartEncrypted.encryptedData!);
      final dartHeaderB64 =
          dart_crypto.CryptoUtil.bin2base64(dartEncrypted.header!);

      final rustPlainFromDartEncrypted = rust.decryptData(
        encryptedDataB64: dartEncryptedDataB64,
        key: key,
        headerB64: dartHeaderB64,
      );
      _assertEqualBytes(
        rustPlainFromDartEncrypted,
        plaintext,
        '$label:dartEncryptData->rustDecryptData',
        redact: true,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      _fail(label, 'encrypt/decrypt check failed (${e.runtimeType})');
    }
  }

  Future<void> verifyDecryptedData({
    required Uint8List plaintext,
    required String encryptedDataB64,
    required String headerB64,
    required Uint8List key,
    required String label,
  }) async {
    await _ensureDeterministicChecks();

    try {
      final rustPlain = rust.decryptData(
        encryptedDataB64: encryptedDataB64,
        key: key,
        headerB64: headerB64,
      );
      _assertEqualBytes(
        rustPlain,
        plaintext,
        '$label:rustDecryptData',
        redact: true,
      );

      final dartPlain = await dart_crypto.CryptoUtil.decryptData(
        dart_crypto.CryptoUtil.base642bin(encryptedDataB64),
        key,
        dart_crypto.CryptoUtil.base642bin(headerB64),
      );
      _assertEqualBytes(
        dartPlain,
        plaintext,
        '$label:dartDecryptData',
        redact: true,
      );

      _assertEqualBytes(
        rustPlain,
        dartPlain,
        '$label:decryptParity',
        redact: true,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      _fail(label, 'decrypt check failed (${e.runtimeType})');
    }
  }

  void verifySecretboxEncryption({
    required Uint8List plaintext,
    required Uint8List cipher,
    required Uint8List nonce,
    required Uint8List key,
    required String label,
  }) {
    try {
      final rustPlain = rust.decryptSync(
        cipher: cipher,
        key: key,
        nonce: nonce,
      );
      _assertEqualBytes(
        rustPlain,
        plaintext,
        '$label:rustDecryptSync',
        redact: true,
      );

      final dartPlain = dart_crypto.CryptoUtil.decryptSync(
        cipher,
        key,
        nonce,
      );
      _assertEqualBytes(
        dartPlain,
        plaintext,
        '$label:dartDecryptSync',
        redact: true,
      );

      // Dart encrypt -> rust decrypt (encryption is non-deterministic).
      final dartSecretbox = dart_crypto.CryptoUtil.encryptSync(
        plaintext,
        key,
      );
      final rustFromDartSecretbox = rust.decryptSync(
        cipher: dartSecretbox.encryptedData!,
        key: key,
        nonce: dartSecretbox.nonce!,
      );
      _assertEqualBytes(
        rustFromDartSecretbox,
        plaintext,
        '$label:dartEncryptSync->rustDecryptSync',
        redact: true,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      _fail(label, 'secretbox encrypt/decrypt check failed (${e.runtimeType})');
    }
  }

  void verifySecretboxDecryption({
    required Uint8List plaintext,
    required Uint8List cipher,
    required Uint8List nonce,
    required Uint8List key,
    required String label,
  }) {
    try {
      final rustPlain = rust.decryptSync(
        cipher: cipher,
        key: key,
        nonce: nonce,
      );
      _assertEqualBytes(
        rustPlain,
        plaintext,
        '$label:rustDecryptSync',
        redact: true,
      );

      final dartPlain = dart_crypto.CryptoUtil.decryptSync(
        cipher,
        key,
        nonce,
      );
      _assertEqualBytes(
        dartPlain,
        plaintext,
        '$label:dartDecryptSync',
        redact: true,
      );

      _assertEqualBytes(
        rustPlain,
        dartPlain,
        '$label:decryptParity',
        redact: true,
      );
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      _fail(label, 'secretbox decrypt check failed (${e.runtimeType})');
    }
  }

  Future<void> verifyKekForLogin({
    required String password,
    required String kekSaltB64,
    required int memLimit,
    required int opsLimit,
    required Uint8List rustKek,
    required String label,
  }) async {
    await _ensureDeterministicChecks();

    try {
      final passwordBytes = Uint8List.fromList(utf8.encode(password));
      final salt = dart_crypto.CryptoUtil.base642bin(kekSaltB64);
      final dartKek = await dart_crypto.CryptoUtil.deriveKey(
        passwordBytes,
        salt,
        memLimit,
        opsLimit,
      );
      _assertEqualBytes(dartKek, rustKek, '$label:kek', redact: true);
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      _fail(label, 'kek derivation failed (${e.runtimeType})');
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
    await _ensureDeterministicChecks();

    try {
      final masterKey = _decryptSecretBoxB64(
        cipherB64: keyAttrs.encryptedKey,
        nonceB64: keyAttrs.keyDecryptionNonce,
        key: kek,
      );
      _assertEqualBytes(
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
      _fail(label, 'auth decrypt failed (${e.runtimeType})');
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
    await _ensureDeterministicChecks();

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
      _fail(label, 'auth decrypt failed (${e.runtimeType})');
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
    _assertEqualBytes(
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
    _assertEqualBytes(
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
    final cipher = dart_crypto.CryptoUtil.base642bin(cipherB64);
    final nonce = dart_crypto.CryptoUtil.base642bin(nonceB64);
    return dart_crypto.CryptoUtil.decryptSync(cipher, key, nonce);
  }

  Uint8List _decryptToken({
    required String? encryptedToken,
    required String? plainToken,
    required String publicKeyB64,
    required Uint8List secretKey,
  }) {
    if (encryptedToken != null) {
      final publicKey = dart_crypto.CryptoUtil.base642bin(publicKeyB64);
      final sealed = dart_crypto.CryptoUtil.base642bin(encryptedToken);
      return dart_crypto.CryptoUtil.openSealSync(
        sealed,
        publicKey,
        secretKey,
      );
    }
    if (plainToken != null) {
      return _decodeBase64Flexible(plainToken);
    }
    _fail('authToken', 'missing encrypted or plain token');
  }

  Uint8List _decodeBase64Flexible(String data) {
    try {
      return base64Url.decode(base64Url.normalize(data));
    } catch (_) {
      return base64.decode(base64.normalize(data));
    }
  }

  Future<void> _ensureDeterministicChecks() {
    _deterministicChecksFuture ??= _runDeterministicChecks();
    return _deterministicChecksFuture!;
  }

  Future<void> _runDeterministicChecks() async {
    final sampleBytes = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 7 + 3) & 0xff),
    );

    final rustB64 = rust.bin2Base64(data: sampleBytes);
    final dartB64 = dart_crypto.CryptoUtil.bin2base64(sampleBytes);
    _assertEqualString(rustB64, dartB64, 'bin2Base64');

    final rustEncode = rust.encodeB64(data: sampleBytes);
    _assertEqualString(rustEncode, dartB64, 'encodeB64');

    final rustDecode = rust.base642Bin(data: dartB64);
    final dartDecode = dart_crypto.CryptoUtil.base642bin(dartB64);
    _assertEqualBytes(rustDecode, dartDecode, 'base642Bin');

    final rustDecodeB64 = rust.decodeB64(data: dartB64);
    _assertEqualBytes(rustDecodeB64, dartDecode, 'decodeB64');

    final rustHex = rust.bin2Hex(data: sampleBytes);
    final dartHex = dart_crypto.CryptoUtil.bin2hex(sampleBytes);
    _assertEqualString(rustHex, dartHex, 'bin2Hex');

    final rustHexDecoded = rust.hex2Bin(data: dartHex);
    final dartHexDecoded = dart_crypto.CryptoUtil.hex2bin(dartHex);
    _assertEqualBytes(rustHexDecoded, dartHexDecoded, 'hex2Bin');

    final password = 'ensu-cross-check';
    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    final salt = Uint8List.fromList(
      List<int>.generate(16, (i) => (i * 11 + 5) & 0xff),
    );
    final memLimit = dart_crypto.sodium.crypto.pwhash.memLimitInteractive;
    final opsLimit = dart_crypto.sodium.crypto.pwhash.opsLimitInteractive;

    final rustDerivedKey = await rust.deriveKey(
      password: password,
      salt: salt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );
    final dartDerivedKey = await dart_crypto.CryptoUtil.deriveKey(
      passwordBytes,
      salt,
      memLimit,
      opsLimit,
    );
    _assertEqualBytes(rustDerivedKey, dartDerivedKey, 'deriveKey');

    final rustSensitive = await rust.deriveSensitiveKey(
      password: password,
      salt: salt,
    );
    final dartSensitive = await dart_crypto.CryptoUtil.deriveSensitiveKey(
      passwordBytes,
      salt,
    );
    _assertEqualBytes(
        rustSensitive.key, dartSensitive.key, 'deriveSensitiveKey');
    _assertEqualInt(
      rustSensitive.memLimit,
      dartSensitive.memLimit,
      'deriveSensitiveKeyMem',
    );
    _assertEqualInt(
      rustSensitive.opsLimit,
      dartSensitive.opsLimit,
      'deriveSensitiveKeyOps',
    );

    final loginKeySeed = Uint8List.fromList(
      List<int>.generate(32, (i) => (i * 5 + 1) & 0xff),
    );
    final rustLoginKey = await rust.deriveLoginKey(key: loginKeySeed);
    final dartLoginKey = await dart_crypto.CryptoUtil.deriveLoginKey(
      loginKeySeed,
    );
    _assertEqualBytes(rustLoginKey, dartLoginKey, 'deriveLoginKey');

    final rustKey = rust.generateKey();
    final dartKey = dart_crypto.CryptoUtil.generateKey();
    _assertEqualInt(rustKey.length, dartKey.length, 'generateKeyLength');
    if (rustKey.isEmpty || dartKey.isEmpty) {
      _fail('generateKeyEmpty', 'Generated key is empty');
    }

    final rustSalt = rust.getSaltToDeriveKey();
    final dartSalt = dart_crypto.CryptoUtil.getSaltToDeriveKey();
    _assertEqualInt(
      rustSalt.length,
      dartSalt.length,
      'getSaltToDeriveKeyLength',
    );
    if (rustSalt.isEmpty || dartSalt.isEmpty) {
      _fail('getSaltToDeriveKeyEmpty', 'Generated salt is empty');
    }
  }

  Future<void> _runNonDeterministicChecks() async {
    final plaintext = Uint8List.fromList(
      List<int>.generate(96, (i) => (i * 13 + 17) & 0xff),
    );
    final key = rust.generateKey();

    final rustSecretbox = rust.encryptSync(plaintext: plaintext, key: key);
    final dartSecretboxPlain = dart_crypto.CryptoUtil.decryptSync(
      rustSecretbox.encryptedData,
      key,
      rustSecretbox.nonce,
    );
    _assertEqualBytes(
      dartSecretboxPlain,
      plaintext,
      'encryptSync->dartDecryptSync',
    );

    final rustSecretboxPlain = rust.decryptSync(
      cipher: rustSecretbox.encryptedData,
      key: key,
      nonce: rustSecretbox.nonce,
    );
    _assertEqualBytes(
      rustSecretboxPlain,
      plaintext,
      'encryptSync->rustDecryptSync',
    );

    final rustSecretboxPlainAsync = await rust.decrypt(
      cipher: rustSecretbox.encryptedData,
      key: key,
      nonce: rustSecretbox.nonce,
    );
    _assertEqualBytes(
      rustSecretboxPlainAsync,
      plaintext,
      'encryptSync->rustDecrypt',
    );

    final dartSecretboxPlainAsync = await dart_crypto.CryptoUtil.decrypt(
      rustSecretbox.encryptedData,
      key,
      rustSecretbox.nonce,
    );
    _assertEqualBytes(
      dartSecretboxPlainAsync,
      plaintext,
      'encryptSync->dartDecrypt',
    );

    final dartSecretbox = dart_crypto.CryptoUtil.encryptSync(plaintext, key);
    final rustFromDartSecretbox = rust.decryptSync(
      cipher: dartSecretbox.encryptedData!,
      key: key,
      nonce: dartSecretbox.nonce!,
    );
    _assertEqualBytes(
      rustFromDartSecretbox,
      plaintext,
      'dartEncryptSync->rustDecryptSync',
    );

    final rustEncrypted = rust.encryptData(
      plaintext: plaintext,
      key: key,
    );

    final dartEncryptedPlain = await dart_crypto.CryptoUtil.decryptData(
      dart_crypto.CryptoUtil.base642bin(rustEncrypted.encryptedData),
      key,
      dart_crypto.CryptoUtil.base642bin(rustEncrypted.header),
    );
    _assertEqualBytes(
      dartEncryptedPlain,
      plaintext,
      'encryptData->dartDecryptData',
    );

    final rustEncryptedPlain = rust.decryptData(
      encryptedDataB64: rustEncrypted.encryptedData,
      key: key,
      headerB64: rustEncrypted.header,
    );
    _assertEqualBytes(
      rustEncryptedPlain,
      plaintext,
      'encryptData->rustDecryptData',
    );

    final dartEncrypted = await dart_crypto.CryptoUtil.encryptData(
      plaintext,
      key,
    );
    final rustFromDartEncrypted = rust.decryptData(
      encryptedDataB64: dart_crypto.CryptoUtil.bin2base64(
        dartEncrypted.encryptedData!,
      ),
      key: key,
      headerB64: dart_crypto.CryptoUtil.bin2base64(
        dartEncrypted.header!,
      ),
    );
    _assertEqualBytes(
      rustFromDartEncrypted,
      plaintext,
      'dartEncryptData->rustDecryptData',
    );

    final rustKeyPair = rust.generateKeyPair();
    final dartKeyPair = dart_crypto.CryptoUtil.generateKeyPair();
    _assertEqualInt(
      rustKeyPair.publicKey.length,
      dartKeyPair.publicKey.length,
      'generateKeyPairPublicLen',
    );
    _assertEqualInt(
      rustKeyPair.secretKey.length,
      dartKeyPair.secretKey.extractBytes().length,
      'generateKeyPairSecretLen',
    );

    final sealed = dart_crypto.CryptoUtil.sealSync(
      plaintext,
      rustKeyPair.publicKey,
    );
    final rustOpened = rust.openSealSync(
      cipher: sealed,
      publicKey: rustKeyPair.publicKey,
      secretKey: rustKeyPair.secretKey,
    );
    _assertEqualBytes(rustOpened, plaintext, 'sealSync->rustOpenSealSync');

    final dartOpened = dart_crypto.CryptoUtil.openSealSync(
      sealed,
      rustKeyPair.publicKey,
      rustKeyPair.secretKey,
    );
    _assertEqualBytes(dartOpened, plaintext, 'sealSync->dartOpenSealSync');
  }

  void _assertEqualBytes(
    Uint8List actual,
    Uint8List expected,
    String label, {
    bool redact = false,
  }) {
    if (!_bytesEqual.equals(actual, expected)) {
      _fail(
        label,
        'byte mismatch len=${actual.length} vs ${expected.length} '
        'actual=${_shortB64(actual)} expected=${_shortB64(expected)}',
      );
    }
  }

  void _assertEqualString(String actual, String expected, String label) {
    if (actual != expected) {
      _fail(
        label,
        'string mismatch actual="$actual" expected="$expected"',
      );
    }
  }

  void _assertEqualInt(int actual, int expected, String label) {
    if (actual != expected) {
      _fail(label, 'int mismatch actual=$actual expected=$expected');
    }
  }

  String _shortB64(Uint8List data) {
    final encoded = base64Encode(data);
    if (encoded.length <= 64) {
      return encoded;
    }
    return '${encoded.substring(0, 64)}...';
  }

  Never _fail(String label, String details) {
    _logger.severe('Crypto cross-check failed [$label] $details');
    throw CryptoCrossCheckException(label);
  }
}
