// Helper test to generate cryptographically valid test keys
// Run: flutter test integration_test/mocks/generate_test_keys.dart
// Then copy the output into test_crypto_keys.dart

import "dart:convert";
import "package:ente_crypto/ente_crypto.dart";
import "package:flutter_test/flutter_test.dart";

const String testPassword = "test123";

void main() {
  test("Generate cryptographically valid test keys", () async {
    print("\n\nGenerating cryptographically valid test keys...\n");

    // 1. Generate master key (32 bytes random)
    final masterKey = CryptoUtil.generateKey();
    print("Master Key: ${CryptoUtil.bin2base64(masterKey)}");

    // 2. Generate recovery key (32 bytes random)
    final recoveryKey = CryptoUtil.generateKey();
    print("Recovery Key: ${CryptoUtil.bin2base64(recoveryKey)}");

    // 3. Encrypt master key and recovery key with each other
    final encryptedMasterKey = CryptoUtil.encryptSync(masterKey, recoveryKey);
    final encryptedRecoveryKey = CryptoUtil.encryptSync(recoveryKey, masterKey);
    print(
      "Encrypted Master Key Nonce: ${CryptoUtil.bin2base64(encryptedMasterKey.nonce!)}",
    );
    print(
      "Encrypted Master Key Data: ${CryptoUtil.bin2base64(encryptedMasterKey.encryptedData!)}",
    );
    print(
      "Encrypted Recovery Key Nonce: ${CryptoUtil.bin2base64(encryptedRecoveryKey.nonce!)}",
    );
    print(
      "Encrypted Recovery Key Data: ${CryptoUtil.bin2base64(encryptedRecoveryKey.encryptedData!)}",
    );

    // 4. Derive key-encryption-key from test password
    final kekSalt = CryptoUtil.getSaltToDeriveKey(); // 16 bytes
    print("KEK Salt: ${CryptoUtil.bin2base64(kekSalt)}");

    final derivedKeyResult = await CryptoUtil.deriveSensitiveKey(
      utf8.encode(testPassword),
      kekSalt,
    );
    final keyEncryptionKey = derivedKeyResult.key;
    print("KEK (for reference): ${CryptoUtil.bin2base64(keyEncryptionKey)}");
    print("memLimit: ${derivedKeyResult.memLimit}");
    print("opsLimit: ${derivedKeyResult.opsLimit}");

    // 5. Encrypt master key with key-encryption-key
    final encryptedKeyData = CryptoUtil.encryptSync(
      masterKey,
      keyEncryptionKey,
    );
    print(
      "Encrypted Key Nonce: ${CryptoUtil.bin2base64(encryptedKeyData.nonce!)}",
    );
    print(
      "Encrypted Key Data: ${CryptoUtil.bin2base64(encryptedKeyData.encryptedData!)}",
    );

    // 6. Generate X25519 keypair
    final keyPair = await CryptoUtil.generateKeyPair();
    print("Public Key: ${CryptoUtil.bin2base64(keyPair.pk)}");
    print("Secret Key: ${CryptoUtil.bin2base64(keyPair.sk)}");

    // 7. Encrypt secret key with master key
    final encryptedSecretKeyData = CryptoUtil.encryptSync(
      keyPair.sk,
      masterKey,
    );
    print(
      "Encrypted Secret Key Nonce: ${CryptoUtil.bin2base64(encryptedSecretKeyData.nonce!)}",
    );
    print(
      "Encrypted Secret Key Data: ${CryptoUtil.bin2base64(encryptedSecretKeyData.encryptedData!)}",
    );

    // 8. Create a test JWT token and seal it
    const testToken = "test-jwt-token-1234567890";
    final encryptedToken = await CryptoUtil.sealSync(
      utf8.encode(testToken),
      keyPair.pk,
    );
    print("Test Token: $testToken");
    print(
      "Encrypted Token (sealed box): ${CryptoUtil.bin2base64(encryptedToken)}",
    );

    print("\n✅ All keys generated successfully!");
    print("Copy these values into test_crypto_keys.dart\n\n");
  });
}
