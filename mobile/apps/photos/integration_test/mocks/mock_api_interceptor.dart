import "dart:convert";
import "package:dio/dio.dart";
import "package:http_mock_adapter/http_mock_adapter.dart";
import "package:photos/core/configuration.dart";
import "test_crypto_keys.dart";

/// MockApiInterceptor provides a mock HTTP interceptor for Dio during integration tests.
/// It intercepts API calls and returns predefined mock responses without hitting real servers.
class MockApiInterceptor {
  late final DioAdapter dioAdapter;
  final Dio dio;
  final String baseUrl;
  final TestCryptoKeys testKeys;

  MockApiInterceptor(
    this.dio,
    this.testKeys, {
    String? baseUrl,
  }) : baseUrl = baseUrl ?? Configuration.instance.getHttpEndpoint() {
    dioAdapter = DioAdapter(dio: dio, matcher: const FullHttpRequestMatcher());
    _setupMockEndpoints();
  }

  void _setupMockEndpoints() {
    // Mock: GET /users/srp/attributes
    // Returns SRP attributes for the test user (using real crypto keys)
    dioAdapter.onGet(
      "$baseUrl/users/srp/attributes",
      (server) => server.reply(200, testKeys.getSrpAttributes()),
      queryParameters: {"email": "test@example.com"},
    );

    // Mock: POST /users/srp/create-session
    // Returns session ID and srpB for SRP handshake
    dioAdapter.onPost(
      "$baseUrl/users/srp/create-session",
      (server) => server.reply(
        200,
        {
          "sessionID": "mock-session-id-123",
          "srpB": base64Encode(
            List<int>.filled(512, 3),
          ), // Mock srpB (512 bytes)
        },
      ),
      data: Matchers.any,
    );

    // Mock: POST /users/srp/verify-session
    // Returns authentication token and user data with cryptographically valid encrypted token
    dioAdapter.onPost(
      "$baseUrl/users/srp/verify-session",
      (server) => server.reply(
        200,
        {
          "id": 12345,
          "encryptedToken": testKeys.getEncryptedTokenBase64(),
          "keyAttributes": testKeys.getKeyAttributesMap(),
          "twoFactorSessionID": "",
          "twoFactorSessionIDV2": "",
          "passkeySessionID": "",
          "accountsUrl": "https://accounts.ente.io",
        },
      ),
      data: Matchers.any,
    );

    // Mock: POST /users/ott
    // Sends OTT (One-Time Token) to email
    dioAdapter.onPost(
      "$baseUrl/users/ott",
      (server) => server.reply(200, {}),
      data: Matchers.any,
    );

    // Mock: POST /users/verify-email
    // Verifies OTT and returns user session
    dioAdapter.onPost(
      "$baseUrl/users/verify-email",
      (server) => server.reply(
        200,
        {
          "id": 12345,
          "token": "mock-jwt-token-from-ott",
          // Omitting encryptedToken to use plain token path
          "keyAttributes": {
            "kekSalt": base64Encode(
              List<int>.filled(16, 4),
            ), // 16 bytes for argon2
            "encryptedKey": base64Encode(
              List<int>.filled(48, 5),
            ), // 32 bytes key + 16 bytes auth tag
            "keyDecryptionNonce": base64Encode(
              List<int>.filled(24, 6),
            ), // 24 bytes for XChaCha20
            "publicKey": base64Encode(
              List<int>.filled(32, 7),
            ), // 32 bytes for X25519 public key
            "encryptedSecretKey": base64Encode(
              List<int>.filled(48, 8),
            ), // 32 bytes key + 16 bytes auth tag
            "secretKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 9),
            ), // 24 bytes for XChaCha20
            "memLimit": 67108864,
            "opsLimit": 2,
            "masterKeyEncryptedWithRecoveryKey": base64Encode(
              List<int>.filled(48, 10), // 32 bytes key + 16 bytes auth tag
            ),
            "masterKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 11),
            ), // 24 bytes for XChaCha20
            "recoveryKeyEncryptedWithMasterKey": base64Encode(
              List<int>.filled(48, 12), // 32 bytes key + 16 bytes auth tag
            ),
            "recoveryKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 13),
            ), // 24 bytes for XChaCha20
          },
          "twoFactorSessionID": "",
          "twoFactorSessionIDV2": "",
          "passkeySessionID": "",
          "accountsUrl": "https://accounts.ente.io",
        },
      ),
      data: Matchers.any,
    );

    // Mock: POST /users/two-factor/verify
    // Verifies 2FA code
    dioAdapter.onPost(
      "$baseUrl/users/two-factor/verify",
      (server) => server.reply(
        200,
        {
          "id": 12345,
          "token": "mock-jwt-token-after-2fa",
          // Omitting encryptedToken to use plain token path
          "keyAttributes": {
            "kekSalt": base64Encode(
              List<int>.filled(16, 4),
            ), // 16 bytes for argon2
            "encryptedKey": base64Encode(
              List<int>.filled(48, 5),
            ), // 32 bytes key + 16 bytes auth tag
            "keyDecryptionNonce": base64Encode(
              List<int>.filled(24, 6),
            ), // 24 bytes for XChaCha20
            "publicKey": base64Encode(
              List<int>.filled(32, 7),
            ), // 32 bytes for X25519 public key
            "encryptedSecretKey": base64Encode(
              List<int>.filled(48, 8),
            ), // 32 bytes key + 16 bytes auth tag
            "secretKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 9),
            ), // 24 bytes for XChaCha20
            "memLimit": 67108864,
            "opsLimit": 2,
            "masterKeyEncryptedWithRecoveryKey": base64Encode(
              List<int>.filled(48, 10), // 32 bytes key + 16 bytes auth tag
            ),
            "masterKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 11),
            ), // 24 bytes for XChaCha20
            "recoveryKeyEncryptedWithMasterKey": base64Encode(
              List<int>.filled(48, 12), // 32 bytes key + 16 bytes auth tag
            ),
            "recoveryKeyDecryptionNonce": base64Encode(
              List<int>.filled(24, 13),
            ), // 24 bytes for XChaCha20
          },
          "twoFactorSessionID": "",
          "passkeySessionID": "",
          "accountsUrl": "https://accounts.ente.io",
        },
      ),
      data: Matchers.any,
    );

    // Mock: GET /users/two-factor/status
    // Returns 2FA status (disabled for test user)
    dioAdapter.onGet(
      "$baseUrl/users/two-factor/status",
      (server) => server.reply(200, {"status": false}),
    );

    // Mock: POST /push/token
    // Accept push notification token registration
    dioAdapter.onPost(
      "$baseUrl/push/token",
      (server) => server.reply(200, {}),
      data: Matchers.any,
    );

    // Mock: GET /remote-store/feature-flags
    // Return feature flags (empty for test)
    dioAdapter.onGet(
      "$baseUrl/remote-store/feature-flags",
      (server) => server.reply(200, {}),
    );
  }

  /// Setup mock for successful login with 2FA enabled
  void setupMockWith2FA() {
    // Override verify-session to return 2FA session ID
    dioAdapter.onPost(
      "$baseUrl/users/srp/verify-session",
      (server) => server.reply(
        200,
        {
          "id": 12345,
          "twoFactorSessionID": "mock-2fa-session-id",
          "twoFactorSessionIDV2": "mock-2fa-session-id-v2",
          "passkeySessionID": null,
          "accountsUrl": "https://accounts.ente.io",
        },
      ),
      data: Matchers.any,
    );
  }

  /// Setup mock for login failure (incorrect password)
  void setupMockForInvalidCredentials() {
    dioAdapter.onPost(
      "$baseUrl/users/srp/verify-session",
      (server) => server.reply(
        401,
        {"message": "Incorrect password"},
      ),
      data: Matchers.any,
    );
  }

  /// Setup mock for network error
  void setupMockForNetworkError() {
    dioAdapter.onPost(
      "$baseUrl/users/srp/verify-session",
      (server) => server.throws(
        500,
        DioException(
          requestOptions:
              RequestOptions(path: "$baseUrl/users/srp/verify-session"),
          type: DioExceptionType.connectionTimeout,
          message: "Connection timeout",
        ),
      ),
      data: Matchers.any,
    );
  }

  /// Clear all mock responses
  void reset() {
    dioAdapter.reset();
    _setupMockEndpoints();
  }

  /// Dispose the adapter
  void dispose() {
    dioAdapter.close();
  }
}
