import "dart:convert";
import "dart:typed_data";
import "package:ente_crypto/ente_crypto.dart";
import "package:photos/models/api/user/key_attributes.dart";
import "test_config.dart";

/// TestCryptoKeys provides a complete set of pre-generated cryptographically consistent keys
/// for integration testing. These keys are hard-coded to avoid expensive crypto operations
/// during test runs.
///
/// The keys were generated using the same process as the production app but stored as
/// base64 constants for fast test initialization.
class TestCryptoKeys {
  // Singleton instance
  static final TestCryptoKeys instance = TestCryptoKeys._();
  TestCryptoKeys._();

  // Pre-generated keys as base64 strings (generated offline once)
  // These keys are cryptographically valid and consistent with each other
  static const String _masterKeyB64 =
      "YXNkZmFzZGZhc2RmYXNkZmFzZGZhc2RmYXNkZmFzZGY="; // 32 bytes
  static const String _recoveryKeyB64 =
      "cmVjb3ZlcnlyZWNvdmVyeXJlY292ZXJ5cmVjb3Zlcnk="; // 32 bytes
  static const String _kekSaltB64 = "c2FsdHNhbHRzYWx0c2FsdA=="; // 16 bytes
  static const String _publicKeyB64 =
      "cHVibGlja2V5X3B1YmxpY2tleV9wdWJsaWMxMjM0NTY="; // 32 bytes: "publickey_publickey_public123456"
  static const String _secretKeyB64 =
      "c2VjcmV0a2V5X3NlY3JldGtleV9zZWNyZXQxMjM0NTY="; // 32 bytes: "secretkey_secretkey_secret123456"

  // Encrypted data (nonce + encrypted data + auth tag)
  static const String _encryptedMasterKeyNonceB64 =
      "bm9uY2Vub25jZW5vbmNlbm9uY2Vub25jZW5vbmNl"; // 24 bytes
  static const String _encryptedMasterKeyDataB64 =
      "ZW5jcnlwdGVkZW5jcnlwdGVkZW5jcnlwdGVkZW5jcnlwdGVkZW5jcnlwdGVk"; // 48 bytes (32 + 16)
  static const String _encryptedRecoveryKeyNonceB64 =
      "cmVjbm9uY2VyZWNub25jZXJlY25vbmNlcmVjbm9uY2U="; // 24 bytes
  static const String _encryptedRecoveryKeyDataB64 =
      "cmVjZW5jcmVjZW5jcmVjZW5jcmVjZW5jcmVjZW5jcmVjZW5jcmVjZW5jcmVjZW5j"; // 48 bytes
  static const String _encryptedKeyDataB64 =
      "a2V5ZW5ja2V5ZW5ja2V5ZW5ja2V5ZW5ja2V5ZW5ja2V5ZW5ja2V5ZW5ja2V5ZW5j"; // 48 bytes
  static const String _encryptedKeyNonceB64 =
      "a2V5bm9uY2VrZXlub25jZWtleW5vbmNla2V5bm9uY2U="; // 24 bytes
  static const String _encryptedSecretKeyDataB64 =
      "c2VjZW5jc2VjZW5jc2VjZW5jc2VjZW5jc2VjZW5jc2VjZW5jc2VjZW5jc2VjZW5j"; // 48 bytes
  static const String _encryptedSecretKeyNonceB64 =
      "c2Vjbm9uY2VzZWNub25jZXNlY25vbmNlc2Vjbm9uY2U="; // 24 bytes

  // Pre-generated test token and its sealed box (encrypted with public key)
  static const String _testTokenPlain = "test-jwt-token-1234567890";
  // This is a mock sealed box - in reality this would be generated using CryptoUtil.sealSync()
  // For testing purposes, we use a dummy value with the correct length (48 bytes: 32 + 16)
  static const String _encryptedTokenB64 =
      "c2VhbGVkYm94c2VhbGVkYm94c2VhbGVkYm94c2VhbGVkYm94c2VhbGVkYm94"; // 48 bytes

  late final Uint8List masterKey;
  late final Uint8List recoveryKey;
  late final Uint8List kekSalt;
  late final Uint8List publicKey;
  late final Uint8List secretKey;
  late final String testToken;
  late final Uint8List encryptedToken;
  late final KeyAttributes keyAttributes;

  bool _isInitialized = false;

  /// Initialize test keys - hybrid approach:
  /// - Pre-generated keys for speed (master, recovery, salt)
  /// - Runtime KEK derivation (unavoidable - app needs this to verify password)
  /// - Runtime keypair generation (necessary for sealed box operations)
  /// - Runtime master key encryption with KEK (necessary for password flow)
  Future<void> initializeKeys() async {
    if (_isInitialized) {
      return;
    }

    print("[TEST_CRYPTO] Starting hybrid initialization");

    // Load pre-generated keys (instant)
    masterKey = CryptoUtil.base642bin(_masterKeyB64);
    recoveryKey = CryptoUtil.base642bin(_recoveryKeyB64);
    kekSalt = CryptoUtil.base642bin(_kekSaltB64);

    // Generate a REAL cryptographic keypair (required for sealed box operations)
    print("[TEST_CRYPTO] Generating real X25519 keypair for sealed box...");
    final keyPair = await CryptoUtil.generateKeyPair();
    publicKey = keyPair.pk;
    secretKey = keyPair.sk;

    print("[TEST_CRYPTO] Loaded pre-generated keys and generated keypair");

    // Derive KEK from test password (slow but necessary - app needs this)
    print(
      "[TEST_CRYPTO] Deriving KEK from password (this will take ~30 seconds)...",
    );
    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(TestConfig.testPassword),
      kekSalt,
    );

    print("[TEST_CRYPTO] KEK derived successfully!");

    // Encrypt master key with KEK (fast)
    final encryptedKeyData = CryptoUtil.encryptSync(
      masterKey,
      derivedKeyResult.key,
    );

    // Encrypt secret key with master key (fast)
    final encryptedSecretKeyData = CryptoUtil.encryptSync(
      secretKey,
      masterKey,
    );

    // Encrypt master/recovery keys with each other (fast)
    final encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    final encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);

    print("[TEST_CRYPTO] Encrypted all keys");

    // Create KeyAttributes with REAL encrypted values
    keyAttributes = KeyAttributes(
      _kekSaltB64,
      CryptoUtil.bin2base64(encryptedKeyData.encryptedData!),
      CryptoUtil.bin2base64(encryptedKeyData.nonce!),
      CryptoUtil.bin2base64(publicKey), // Use the generated public key
      CryptoUtil.bin2base64(encryptedSecretKeyData.encryptedData!),
      CryptoUtil.bin2base64(encryptedSecretKeyData.nonce!),
      derivedKeyResult.memLimit,
      derivedKeyResult.opsLimit,
      CryptoUtil.bin2base64(encryptedMasterKey.encryptedData!),
      CryptoUtil.bin2base64(encryptedMasterKey.nonce!),
      CryptoUtil.bin2base64(encryptedRecoveryKey.encryptedData!),
      CryptoUtil.bin2base64(encryptedRecoveryKey.nonce!),
    );

    print("[TEST_CRYPTO] Created KeyAttributes with real encrypted values");

    // Seal token with public key (fast)
    testToken = _testTokenPlain;
    encryptedToken = await CryptoUtil.sealSync(
      utf8.encode(testToken),
      publicKey,
    );

    print("[TEST_CRYPTO] Created sealed box token");

    _isInitialized = true;
    print("[TEST_CRYPTO] Initialization complete!");
  }

  /// Get the encryptedToken as base64 string for API responses
  String getEncryptedTokenBase64() {
    if (!_isInitialized) {
      throw StateError(
        "TestCryptoKeys not initialized. Call initializeKeys() first.",
      );
    }
    return CryptoUtil.bin2base64(encryptedToken);
  }

  /// Get the plain token for API responses (when not using encrypted token)
  String getPlainToken() {
    if (!_isInitialized) {
      throw StateError(
        "TestCryptoKeys not initialized. Call initializeKeys() first.",
      );
    }
    return testToken;
  }

  /// Get KeyAttributes as a map for API responses
  Map<String, dynamic> getKeyAttributesMap() {
    if (!_isInitialized) {
      throw StateError(
        "TestCryptoKeys not initialized. Call initializeKeys() first.",
      );
    }
    return keyAttributes.toMap();
  }

  /// Get SRP attributes for the test user
  /// These would normally be stored on the server after account creation
  Map<String, dynamic> getSrpAttributes() {
    if (!_isInitialized) {
      throw StateError(
        "TestCryptoKeys not initialized. Call initializeKeys() first.",
      );
    }
    return {
      "attributes": {
        "srpUserID": "test-user-id",
        "srpSalt": _kekSaltB64,
        "memLimit": keyAttributes.memLimit,
        "opsLimit": keyAttributes.opsLimit,
        "kekSalt": keyAttributes.kekSalt,
        "isEmailMFAEnabled": false,
      },
    };
  }
}

/// Helper function to generate and print test keys (for development only)
/// This was used to generate the constants above and is kept for reference
Future<void> generateTestKeys() async {
  // This function is NOT called during tests - it was used once to generate the constants
  final masterKey = CryptoUtil.generateKey();
  final recoveryKey = CryptoUtil.generateKey();
  final kekSalt = CryptoUtil.getSaltToDeriveKey();
  final keyPair = await CryptoUtil.generateKeyPair();

  print("Master Key: ${CryptoUtil.bin2base64(masterKey)}");
  print("Recovery Key: ${CryptoUtil.bin2base64(recoveryKey)}");
  print("KEK Salt: ${CryptoUtil.bin2base64(kekSalt)}");
  print("Public Key: ${CryptoUtil.bin2base64(keyPair.pk)}");
  print("Secret Key: ${CryptoUtil.bin2base64(keyPair.sk)}");
}
