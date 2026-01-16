import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_rust/ente_rust.dart' as rust;

class EnteCryptoRustAdapter implements CryptoApi {
  EnteCryptoRustAdapter();

  static bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) {
      return;
    }
    rust.initCrypto();
    _initialized = true;
  }

  @override
  Uint8List strToBin(String str) => rust.strToBin(input: str);

  @override
  Uint8List base642bin(String b64) => rust.base642Bin(data: b64);

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
      encryptedData: rust.base642Bin(data: result.encryptedData),
      header: rust.base642Bin(data: result.header),
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
  }) async {
    final result = await rust.encryptFile(
      sourceFilePath: sourceFilePath,
      destinationFilePath: destinationFilePath,
      key: key,
    );
    return EncryptionResult(
      key: result.key,
      header: result.header,
    );
  }

  @override
  Future<FileEncryptResult> encryptFileWithMd5(
    String sourceFilePath,
    String destinationFilePath, {
    Uint8List? key,
    int? multiPartChunkSizeInBytes,
  }) async {
    final result = await rust.encryptFileWithMd5(
      sourceFilePath: sourceFilePath,
      destinationFilePath: destinationFilePath,
      key: key,
      multiPartChunkSizeInBytes: multiPartChunkSizeInBytes,
    );

    return FileEncryptResult(
      key: result.key,
      header: result.header,
      fileMd5: result.fileMd5,
      partMd5s: result.partMd5S,
      partSize: result.partSize,
    );
  }

  @override
  Future<void> decryptFile(
    String sourceFilePath,
    String destinationFilePath,
    Uint8List header,
    Uint8List key,
  ) {
    return rust.decryptFile(
      sourceFilePath: sourceFilePath,
      destinationFilePath: destinationFilePath,
      header: header,
      key: key,
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
    return rust.sealSync(data: input, publicKey: publicKey);
  }

  @override
  Future<DerivedKeyResult> deriveSensitiveKey(
    Uint8List password,
    Uint8List salt,
  ) async {
    return _mapKeyDerivationError(() async {
      final result = await rust.deriveSensitiveKey(
        password: _passwordToString(password),
        salt: salt,
      );
      return DerivedKeyResult(result.key, result.memLimit, result.opsLimit);
    });
  }

  @override
  Future<DerivedKeyResult> deriveInteractiveKey(
    Uint8List password,
    Uint8List salt,
  ) async {
    return _mapKeyDerivationError(() async {
      final result = await rust.deriveInteractiveKey(
        password: _passwordToString(password),
        salt: salt,
      );
      return DerivedKeyResult(result.key, result.memLimit, result.opsLimit);
    });
  }

  @override
  Future<Uint8List> deriveKey(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) {
    return _mapKeyDerivationError(() async {
      return rust.deriveKey(
        password: _passwordToString(password),
        salt: salt,
        memLimit: memLimit,
        opsLimit: opsLimit,
      );
    });
  }

  @override
  Future<Uint8List> deriveLoginKey(Uint8List key) {
    return _mapLoginKeyDerivationError(() async {
      return rust.deriveLoginKey(key: key);
    });
  }

  @override
  Uint8List getSaltToDeriveKey() => rust.getSaltToDeriveKey();

  @override
  Uint8List cryptoPwHash(
    Uint8List password,
    Uint8List salt,
    int memLimit,
    int opsLimit,
  ) {
    return _mapKeyDerivationErrorSync(() {
      return rust.cryptoPwHash(
        password: _passwordToString(password),
        salt: salt,
        memLimit: memLimit,
        opsLimit: opsLimit,
      );
    });
  }

  @override
  int get pwhashMemLimitInteractive => rust.pwhashMemLimitInteractive();

  @override
  int get pwhashMemLimitSensitive => rust.pwhashMemLimitSensitive();

  @override
  int get pwhashOpsLimitInteractive => rust.pwhashOpsLimitInteractive();

  @override
  int get pwhashOpsLimitSensitive => rust.pwhashOpsLimitSensitive();

  @override
  Future<Uint8List> getHash(File source) {
    return rust.getHash(sourceFilePath: source.path);
  }

  Future<T> _mapKeyDerivationError<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (_, s) {
      Error.throwWithStackTrace(KeyDerivationError(), s);
    }
  }

  Future<T> _mapLoginKeyDerivationError<T>(Future<T> Function() body) async {
    try {
      return await body();
    } catch (_, s) {
      Error.throwWithStackTrace(LoginKeyDerivationError(), s);
    }
  }

  T _mapKeyDerivationErrorSync<T>(T Function() body) {
    try {
      return body();
    } catch (_, s) {
      Error.throwWithStackTrace(KeyDerivationError(), s);
    }
  }

  String _passwordToString(Uint8List password) {
    return utf8.decode(password, allowMalformed: true);
  }

}
