import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/src/crypto_cross_check_exception.dart';
import 'package:ente_crypto_cross_check_adapter/src/crypto_cross_check_utils.dart';
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_crypto_rust_adapter/ente_crypto_rust_adapter.dart';
import 'package:ente_rust/ente_rust.dart' as rust;

class EnteCryptoCrossCheckAdapter implements CryptoApi {
  EnteCryptoCrossCheckAdapter({
    CryptoApi? dartAdapter,
    CryptoApi? rustAdapter,
  })  : _dart = dartAdapter ?? const EnteCryptoDartAdapter(),
        _rustAdapter = rustAdapter ?? EnteCryptoRustAdapter();

  static bool _initialized = false;

  final CryptoApi _dart;
  final CryptoApi _rustAdapter;

  @override
  Future<void> init() async {
    // Rust initialization is owned by the app to avoid double-init.
    if (_initialized) {
      return;
    }
    await _dart.init();
    await _rustAdapter.init();
    _initialized = true;
  }

  @override
  Uint8List strToBin(String str) {
    final rustBin = rust.strToBin(input: str);
    _guard('strToBin', () {
      final dartBin = _dart.strToBin(str);
      assertEqualBytes(rustBin, dartBin, 'strToBin');
    });
    return rustBin;
  }

  @override
  Uint8List base642bin(String b64) {
    final dartBin = _dart.base642bin(b64);
    final rustBin = rust.base642Bin(data: b64);
    assertEqualBytes(rustBin, dartBin, 'base642bin');
    return rustBin;
  }

  @override
  String bin2base64(Uint8List bin, {bool urlSafe = false}) {
    final dartB64 = _dart.bin2base64(bin, urlSafe: urlSafe);
    final rustB64 = rust.bin2Base64(data: bin, urlSafe: urlSafe);
    assertEqualString(rustB64, dartB64, 'bin2base64');
    return rustB64;
  }

  @override
  String bin2hex(Uint8List bin) {
    final dartHex = _dart.bin2hex(bin);
    final rustHex = rust.bin2Hex(data: bin);
    assertEqualString(rustHex, dartHex, 'bin2hex');
    return rustHex;
  }

  @override
  Uint8List hex2bin(String hex) {
    final dartBin = _dart.hex2bin(hex);
    final rustBin = rust.hex2Bin(data: hex);
    assertEqualBytes(rustBin, dartBin, 'hex2bin');
    return rustBin;
  }

  @override
  EncryptionResult encryptSync(Uint8List source, Uint8List key) {
    final rustResult = rust.encryptSync(plaintext: source, key: key);
    final result = EncryptionResult(
      encryptedData: rustResult.encryptedData,
      nonce: rustResult.nonce,
    );
    _guard('encryptSync', () {
      final rustEncryptedData =
          _requireBytes(result.encryptedData, 'encryptSync:encryptedData');
      final rustNonce = _requireBytes(result.nonce, 'encryptSync:nonce');

      final dartPlain = _dart.decryptSync(
        rustEncryptedData,
        key,
        rustNonce,
      );
      assertEqualBytes(
        dartPlain,
        source,
        'encryptSync:dartDecryptFromRust',
        redact: true,
      );

      final dartEncrypted = _dart.encryptSync(source, key);
      final dartCipher =
          _requireBytes(dartEncrypted.encryptedData, 'encryptSync:dartCipher');
      final dartNonce =
          _requireBytes(dartEncrypted.nonce, 'encryptSync:dartNonce');
      final rustPlain = rust.decryptSync(
        cipher: dartCipher,
        key: key,
        nonce: dartNonce,
      );
      assertEqualBytes(
        rustPlain,
        source,
        'encryptSync:rustDecryptFromDart',
        redact: true,
      );
    });
    return result;
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) async {
    final rustPlain = await rust.decrypt(
      cipher: cipher,
      key: key,
      nonce: nonce,
    );
    await _guardAsync('decrypt', () async {
      final dartPlain = await _dart.decrypt(cipher, key, nonce);
      assertEqualBytes(
        rustPlain,
        dartPlain,
        'decrypt:parity',
        redact: true,
      );
    });
    return rustPlain;
  }

  @override
  Uint8List decryptSync(
    Uint8List cipher,
    Uint8List key,
    Uint8List nonce,
  ) {
    final rustPlain = rust.decryptSync(
      cipher: cipher,
      key: key,
      nonce: nonce,
    );
    _guard('decryptSync', () {
      final dartPlain = _dart.decryptSync(cipher, key, nonce);
      assertEqualBytes(
        rustPlain,
        dartPlain,
        'decryptSync:parity',
        redact: true,
      );
    });
    return rustPlain;
  }

  @override
  Future<EncryptionResult> encryptData(Uint8List source, Uint8List key) async {
    final rustEncrypted = rust.encryptData(plaintext: source, key: key);
    final rustEncryptedData = _dart.base642bin(rustEncrypted.encryptedData);
    final rustHeader = _dart.base642bin(rustEncrypted.header);
    final result = EncryptionResult(
      encryptedData: rustEncryptedData,
      header: rustHeader,
    );
    await _guardAsync('encryptData', () async {
      final dartPlain = await _dart.decryptData(
        rustEncryptedData,
        key,
        rustHeader,
      );
      assertEqualBytes(
        dartPlain,
        source,
        'encryptData:dartDecryptFromRust',
        redact: true,
      );

      final dartResult = await _dart.encryptData(source, key);
      final dartEncryptedData =
          _requireBytes(dartResult.encryptedData, 'encryptData:encryptedData');
      final dartHeader = _requireBytes(dartResult.header, 'encryptData:header');

      final rustPlain = rust.decryptData(
        encryptedDataB64: _dart.bin2base64(dartEncryptedData),
        key: key,
        headerB64: _dart.bin2base64(dartHeader),
      );
      assertEqualBytes(
        rustPlain,
        source,
        'encryptData:rustDecryptFromDart',
        redact: true,
      );
    });
    return result;
  }

  @override
  Future<Uint8List> decryptData(
    Uint8List source,
    Uint8List key,
    Uint8List header,
  ) async {
    final rustPlain = rust.decryptData(
      encryptedDataB64: _dart.bin2base64(source),
      key: key,
      headerB64: _dart.bin2base64(header),
    );
    await _guardAsync('decryptData', () async {
      final dartPlain = await _dart.decryptData(source, key, header);
      assertEqualBytes(
        rustPlain,
        dartPlain,
        'decryptData:parity',
        redact: true,
      );
    });
    return rustPlain;
  }

  @override
  Future<EncryptionResult> encryptFile(
    String sourceFilePath,
    String destinationFilePath, {
    Uint8List? key,
  }) async {
    final rustResult = await _rustAdapter.encryptFile(
      sourceFilePath,
      destinationFilePath,
      key: key,
    );
    await _guardAsync('encryptFile', () async {
      final resolvedKey = rustResult.key ?? key;
      if (resolvedKey == null) {
        failCrossCheck('encryptFile:key', 'missing key');
      }
      final header = _requireBytes(rustResult.header, 'encryptFile:header');
      final decryptedFile = _tempFile('encrypt_file_decrypted');
      try {
        await _dart.decryptFile(
          destinationFilePath,
          decryptedFile.path,
          header,
          resolvedKey,
        );
        await _assertFileMatches(
          sourceFilePath,
          decryptedFile.path,
          'encryptFile:dartDecryptFromRust',
        );
      } finally {
        await _deleteTempFile(decryptedFile);
      }
    });
    return rustResult;
  }

  @override
  Future<FileEncryptResult> encryptFileWithMd5(
    String sourceFilePath,
    String destinationFilePath, {
    Uint8List? key,
    int? multiPartChunkSizeInBytes,
  }) async {
    final rustResult = await _rustAdapter.encryptFileWithMd5(
      sourceFilePath,
      destinationFilePath,
      key: key,
      multiPartChunkSizeInBytes: multiPartChunkSizeInBytes,
    );
    await _guardAsync('encryptFileWithMd5', () async {
      final resolvedKey = rustResult.key ?? key;
      if (resolvedKey == null) {
        failCrossCheck('encryptFileWithMd5:key', 'missing key');
      }
      final header =
          _requireBytes(rustResult.header, 'encryptFileWithMd5:header');
      final decryptedFile = _tempFile('encrypt_file_md5_decrypted');
      try {
        await _dart.decryptFile(
          destinationFilePath,
          decryptedFile.path,
          header,
          resolvedKey,
        );
        await _assertFileMatches(
          sourceFilePath,
          decryptedFile.path,
          'encryptFileWithMd5:dartDecryptFromRust',
        );
      } finally {
        await _deleteTempFile(decryptedFile);
      }
    });
    return rustResult;
  }

  @override
  Future<void> decryptFile(
    String sourceFilePath,
    String destinationFilePath,
    Uint8List header,
    Uint8List key,
  ) async {
    await _rustAdapter.decryptFile(
      sourceFilePath,
      destinationFilePath,
      header,
      key,
    );
    await _guardAsync('decryptFile', () async {
      final dartOutput = _tempFile('decrypt_file_dart');
      try {
        await _dart.decryptFile(
          sourceFilePath,
          dartOutput.path,
          header,
          key,
        );
        await _assertFileMatches(
          destinationFilePath,
          dartOutput.path,
          'decryptFile:dartDecryptFromRust',
        );
      } finally {
        await _deleteTempFile(dartOutput);
      }
    });
  }

  @override
  Uint8List generateKey() {
    final rustKey = rust.generateKey();
    _guard('generateKey', () {
      final dartKey = _dart.generateKey();
      assertEqualInt(rustKey.length, dartKey.length, 'generateKeyLength');
      if (rustKey.isEmpty) {
        failCrossCheck('generateKeyEmpty', 'Generated key is empty');
      }

      final probe = Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]);
      final rustEncrypted = rust.encryptSync(plaintext: probe, key: rustKey);
      final dartPlain = _dart.decryptSync(
        rustEncrypted.encryptedData,
        rustKey,
        rustEncrypted.nonce,
      );
      assertEqualBytes(
        dartPlain,
        probe,
        'generateKey:rustEncrypt->dartDecrypt',
        redact: true,
      );

      final dartEncrypted = _dart.encryptSync(probe, rustKey);
      final dartCipher =
          _requireBytes(dartEncrypted.encryptedData, 'generateKey:dartCipher');
      final dartNonce =
          _requireBytes(dartEncrypted.nonce, 'generateKey:dartNonce');
      final rustPlain = rust.decryptSync(
        cipher: dartCipher,
        key: rustKey,
        nonce: dartNonce,
      );
      assertEqualBytes(
        rustPlain,
        probe,
        'generateKey:dartEncrypt->rustDecrypt',
        redact: true,
      );
    });
    return rustKey;
  }

  @override
  CryptoKeyPair generateKeyPair() {
    final rustPair = rust.generateKeyPair();
    _guard('generateKeyPair', () {
      final dartPair = _dart.generateKeyPair();
      assertEqualInt(
        rustPair.publicKey.length,
        dartPair.publicKey.length,
        'generateKeyPairPublicLen',
      );
      assertEqualInt(
        rustPair.secretKey.length,
        dartPair.secretKey.length,
        'generateKeyPairSecretLen',
      );
    });
    return CryptoKeyPair(
      publicKey: rustPair.publicKey,
      secretKey: rustPair.secretKey,
    );
  }

  @override
  Uint8List openSealSync(
    Uint8List input,
    Uint8List publicKey,
    Uint8List secretKey,
  ) {
    final rustPlain = rust.openSealSync(
      cipher: input,
      publicKey: publicKey,
      secretKey: secretKey,
    );
    _guard('openSealSync', () {
      final dartPlain = _dart.openSealSync(input, publicKey, secretKey);
      assertEqualBytes(
        rustPlain,
        dartPlain,
        'openSealSync:parity',
        redact: true,
      );
    });
    return rustPlain;
  }

  @override
  Uint8List sealSync(Uint8List input, Uint8List publicKey) {
    final rustCipher = rust.sealSync(data: input, publicKey: publicKey);
    _guard('sealSync', () {
      final dartCipher = _dart.sealSync(input, publicKey);
      assertEqualInt(rustCipher.length, dartCipher.length, 'sealSync:length');
    });
    return rustCipher;
  }

  @override
  Future<DerivedKeyResult> deriveSensitiveKey(
    Uint8List password,
    Uint8List salt,
  ) async {
    final rustResult = await rust.deriveSensitiveKey(
      password: _passwordToString(password),
      salt: salt,
    );
    await _guardAsync('deriveSensitiveKey', () async {
      final dartResult = await _dart.deriveSensitiveKey(password, salt);
      assertEqualBytes(rustResult.key, dartResult.key, 'deriveSensitiveKey');
      assertEqualInt(
        rustResult.memLimit,
        dartResult.memLimit,
        'deriveSensitiveKeyMem',
      );
      assertEqualInt(
        rustResult.opsLimit,
        dartResult.opsLimit,
        'deriveSensitiveKeyOps',
      );
    });
    return DerivedKeyResult(
      rustResult.key,
      rustResult.memLimit,
      rustResult.opsLimit,
    );
  }

  @override
  Future<DerivedKeyResult> deriveInteractiveKey(
    Uint8List password,
    Uint8List salt,
  ) async {
    final rustKey = await rust.deriveKey(
      password: _passwordToString(password),
      salt: salt,
      memLimit: pwhashMemLimitInteractive,
      opsLimit: pwhashOpsLimitInteractive,
    );
    final dartResult = await _dart.deriveInteractiveKey(password, salt);
    await _guardAsync('deriveInteractiveKey', () async {
      assertEqualBytes(rustKey, dartResult.key, 'deriveInteractiveKey');
    });
    return DerivedKeyResult(
      rustKey,
      dartResult.memLimit,
      dartResult.opsLimit,
    );
  }

  @override
  Future<Uint8List> deriveKey(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) async {
    final rustKey = await rust.deriveKey(
      password: _passwordToString(password),
      salt: salt,
      memLimit: memLimit,
      opsLimit: opsLimit,
    );
    await _guardAsync('deriveKey', () async {
      final dartKey = await _dart.deriveKey(password, salt, memLimit, opsLimit);
      assertEqualBytes(rustKey, dartKey, 'deriveKey');
    });
    return rustKey;
  }

  @override
  Future<Uint8List> deriveLoginKey(Uint8List key) async {
    final rustKey = await rust.deriveLoginKey(key: key);
    await _guardAsync('deriveLoginKey', () async {
      final dartKey = await _dart.deriveLoginKey(key);
      assertEqualBytes(rustKey, dartKey, 'deriveLoginKey');
    });
    return rustKey;
  }

  @override
  Uint8List getSaltToDeriveKey() {
    final rustSalt = rust.getSaltToDeriveKey();
    _guard('getSaltToDeriveKey', () {
      final dartSalt = _dart.getSaltToDeriveKey();
      assertEqualInt(
        rustSalt.length,
        dartSalt.length,
        'getSaltToDeriveKeyLength',
      );
      if (rustSalt.isEmpty) {
        failCrossCheck('getSaltToDeriveKeyEmpty', 'Generated salt is empty');
      }
    });
    return rustSalt;
  }

  @override
  Uint8List cryptoPwHash(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) {
    final rustHash = _rustAdapter.cryptoPwHash(
      password,
      salt,
      memLimit,
      opsLimit,
    );
    _guard('cryptoPwHash', () {
      final dartHash = _dart.cryptoPwHash(password, salt, memLimit, opsLimit);
      assertEqualBytes(rustHash, dartHash, 'cryptoPwHash');
    });
    return rustHash;
  }

  @override
  int get pwhashMemLimitInteractive {
    final rustValue = _rustAdapter.pwhashMemLimitInteractive;
    _guard('pwhashMemLimitInteractive', () {
      final dartValue = _dart.pwhashMemLimitInteractive;
      assertEqualInt(
        rustValue,
        dartValue,
        'pwhashMemLimitInteractive',
      );
    });
    return rustValue;
  }

  @override
  int get pwhashMemLimitSensitive {
    final rustValue = _rustAdapter.pwhashMemLimitSensitive;
    _guard('pwhashMemLimitSensitive', () {
      final dartValue = _dart.pwhashMemLimitSensitive;
      assertEqualInt(
        rustValue,
        dartValue,
        'pwhashMemLimitSensitive',
      );
    });
    return rustValue;
  }

  @override
  int get pwhashOpsLimitInteractive {
    final rustValue = _rustAdapter.pwhashOpsLimitInteractive;
    _guard('pwhashOpsLimitInteractive', () {
      final dartValue = _dart.pwhashOpsLimitInteractive;
      assertEqualInt(
        rustValue,
        dartValue,
        'pwhashOpsLimitInteractive',
      );
    });
    return rustValue;
  }

  @override
  int get pwhashOpsLimitSensitive {
    final rustValue = _rustAdapter.pwhashOpsLimitSensitive;
    _guard('pwhashOpsLimitSensitive', () {
      final dartValue = _dart.pwhashOpsLimitSensitive;
      assertEqualInt(
        rustValue,
        dartValue,
        'pwhashOpsLimitSensitive',
      );
    });
    return rustValue;
  }

  @override
  Future<Uint8List> getHash(File source) async {
    final rustHash = await _rustAdapter.getHash(source);
    await _guardAsync('getHash', () async {
      final dartHash = await _dart.getHash(source);
      assertEqualBytes(rustHash, dartHash, 'getHash');
    });
    return rustHash;
  }

  Uint8List _requireBytes(Uint8List? value, String label) {
    if (value == null) {
      failCrossCheck(label, 'missing value');
    }
    return value;
  }

  void _guard(String label, void Function() body) {
    try {
      body();
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      failCrossCheck(label, 'cross-check failed (${e.runtimeType})');
    }
  }

  Future<void> _guardAsync(String label, Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      if (e is CryptoCrossCheckException) rethrow;
      failCrossCheck(label, 'cross-check failed (${e.runtimeType})');
    }
  }

  Future<void> _assertFileMatches(
    String expectedPath,
    String actualPath,
    String label,
  ) async {
    final expectedHash = await rust.getHash(sourceFilePath: expectedPath);
    final actualHash = await rust.getHash(sourceFilePath: actualPath);
    assertEqualBytes(
      actualHash,
      expectedHash,
      label,
      redact: true,
    );
  }

  File _tempFile(String label) {
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    return File(
      '${Directory.systemTemp.path}/crypto_cross_check_${label}_$timestamp',
    );
  }

  Future<void> _deleteTempFile(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  String _passwordToString(Uint8List password) {
    return utf8.decode(password, allowMalformed: true);
  }
}
