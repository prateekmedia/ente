import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:ente_rust/ente_rust.dart' as rust;
import 'package:ensu/auth/auth_crypto_adapter.dart';
import 'package:ensu/core/configuration.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

const _defaultAccountsUrl = 'https://accounts.ente.io';

/// Simplified authentication service for Ensu app.
/// Uses Rust core for all crypto operations.
class AuthService {
  static final AuthService instance = AuthService._();

  AuthService._() {
    _crypto = kReleaseMode
        ? RustOnlyAuthCryptoAdapter()
        : CrossCheckedAuthCryptoAdapter();
  }

  late AuthCryptoAdapter _crypto;

  @visibleForTesting
  void overrideCryptoAdapter(AuthCryptoAdapter crypto) {
    _crypto = crypto;
  }

  final _logger = Logger('AuthService');
  final _dio = Dio(BaseOptions(
    baseUrl: Configuration.instance.getHttpEndpoint(),
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(seconds: 30),
    headers: {
      'X-Client-Package': 'io.ente.ensu',
    },
  ));

  void updateEndpoint(String endpoint) {
    _dio.options.baseUrl = endpoint;
  }

  /// Get SRP attributes to determine auth flow.
  Future<ServerSrpAttributes> getSrpAttributes(String email) async {
    final response = await _dio.get(
      '/users/srp/attributes',
      queryParameters: {'email': email},
    );
    _logger.info('SRP attributes received');
    return ServerSrpAttributes.fromMap(response.data['attributes']);
  }

  /// Send OTP to email for login (only when email MFA is enabled).
  Future<void> sendOtp(String email) async {
    await _dio.post('/users/ott', data: {'email': email, 'purpose': 'login'});
  }

  /// Verify OTP and get user info (for email MFA flow).
  Future<OtpVerificationResult> verifyOtp(String email, String otp) async {
    final response = await _dio.post('/users/verify-email', data: {
      'email': email,
      'ott': otp,
    });

    final data = response.data;
    final passkeySessionId = data['passkeySessionID'] as String?;
    String? twoFactorSessionId = data['twoFactorSessionID'] as String?;
    if ((twoFactorSessionId == null || twoFactorSessionId.isEmpty) &&
        data['twoFactorSessionIDV2'] != null) {
      twoFactorSessionId = data['twoFactorSessionIDV2'] as String?;
    }

    final accountsUrl = data['accountsUrl'] as String?;

    return OtpVerificationResult(
      id: data['id'] as int,
      keyAttributes: data['keyAttributes'] != null
          ? ServerKeyAttributes.fromMap(data['keyAttributes'])
          : null,
      encryptedToken: data['encryptedToken'] as String?,
      plainToken: data['token'] as String?,
      twoFactorSessionId:
          (twoFactorSessionId?.isNotEmpty == true) ? twoFactorSessionId : null,
      passkeySessionId:
          (passkeySessionId?.isNotEmpty == true) ? passkeySessionId : null,
      accountsUrl: (accountsUrl?.isNotEmpty == true)
          ? accountsUrl!
          : _defaultAccountsUrl,
    );
  }

  /// Complete SRP login flow using Rust core.
  Future<SrpLoginResult> loginWithSrp({
    required String email,
    required String password,
    required ServerSrpAttributes srpAttributes,
  }) async {
    _logger.info('Starting SRP login');

    try {
      // Step 1: Start SRP - derives keys and creates client
      final rustSrpAttrs = rust.SrpAttributes(
        srpUserId: srpAttributes.srpUserId,
        srpSalt: srpAttributes.srpSalt,
        kekSalt: srpAttributes.kekSalt,
        memLimit: srpAttributes.memLimit,
        opsLimit: srpAttributes.opsLimit,
        isEmailMfaEnabled: srpAttributes.isEmailMfaEnabled,
      );

      final startResult = await _crypto.srpStart(
        password: password,
        srpAttrs: rustSrpAttrs,
      );
      _logger.info('SRP started, got srpA');

      // Step 2: Create session with server
      final sessionResponse =
          await _dio.post('/users/srp/create-session', data: {
        'srpUserID': srpAttributes.srpUserId,
        'srpA': startResult.srpA,
      });

      final sessionId = sessionResponse.data['sessionID'] as String;
      final srpB = sessionResponse.data['srpB'] as String;
      _logger.info('SRP session created');

      // Step 3: Finish SRP - process server's B and compute M1
      final verifyResult = await _crypto.srpFinish(srpB: srpB);
      _logger.info('SRP finished, got srpM1');

      // Step 4: Verify session with server
      final authResponse = await _dio.post('/users/srp/verify-session', data: {
        'srpUserID': srpAttributes.srpUserId,
        'sessionID': sessionId,
        'srpM1': verifyResult.srpM1,
      });

      final responseData = authResponse.data;
      _logger.info('SRP verified by server');

      final passkeySessionId = responseData['passkeySessionID'] as String?;
      String? twoFactorSessionId =
          responseData['twoFactorSessionID'] as String?;
      if ((twoFactorSessionId == null || twoFactorSessionId.isEmpty) &&
          responseData['twoFactorSessionIDV2'] != null) {
        twoFactorSessionId = responseData['twoFactorSessionIDV2'] as String?;
      }
      final normalizedPasskeySessionId =
          (passkeySessionId?.isNotEmpty == true) ? passkeySessionId : null;
      final normalizedTwoFactorSessionId =
          (twoFactorSessionId?.isNotEmpty == true) ? twoFactorSessionId : null;
      if (normalizedPasskeySessionId != null ||
          normalizedTwoFactorSessionId != null) {
        Configuration.instance.setVolatilePassword(password);
        final accountsUrl = responseData['accountsUrl'] as String?;
        return SrpLoginResult(
          passkeySessionId: normalizedPasskeySessionId,
          twoFactorSessionId: normalizedTwoFactorSessionId,
          accountsUrl: accountsUrl?.isNotEmpty == true
              ? accountsUrl
              : _defaultAccountsUrl,
        );
      }

      // Step 5: Decrypt secrets using Rust core
      final keyAttrs = rust.KeyAttributes(
        kekSalt: responseData['keyAttributes']['kekSalt'],
        encryptedKey: responseData['keyAttributes']['encryptedKey'],
        keyDecryptionNonce: responseData['keyAttributes']['keyDecryptionNonce'],
        publicKey: responseData['keyAttributes']['publicKey'],
        encryptedSecretKey: responseData['keyAttributes']['encryptedSecretKey'],
        secretKeyDecryptionNonce: responseData['keyAttributes']
            ['secretKeyDecryptionNonce'],
        memLimit: responseData['keyAttributes']['memLimit'],
        opsLimit: responseData['keyAttributes']['opsLimit'],
      );

      // Server may return either encryptedToken (sealed box) or token (plain base64)
      final encryptedToken = responseData['encryptedToken'] as String?;
      final plainToken = responseData['token'] as String?;
      final secrets = await _crypto.srpDecryptSecrets(
        password: password,
        kekSalt: srpAttributes.kekSalt,
        memLimit: srpAttributes.memLimit,
        opsLimit: srpAttributes.opsLimit,
        keyAttrs: keyAttrs,
        encryptedToken: encryptedToken,
        plainToken: plainToken,
      );
      _logger.info('Secrets decrypted');

      // Step 6: Store credentials
      await _storeSecrets(
        email: email,
        userId: responseData['id'] as int,
        secrets: secrets,
      );

      _logger.info('SRP login successful');
      return const SrpLoginResult();
    } finally {
      await _crypto.srpClear();
    }
  }

  /// Login after email MFA verification (no SRP).
  Future<void> loginAfterEmailMfa({
    required String email,
    required String password,
    required ServerSrpAttributes srpAttributes,
    required ServerKeyAttributes keyAttributes,
    String? encryptedToken,
    String? plainToken,
    required int userId,
  }) async {
    _logger.info('Starting login after email MFA');

    final kek = await _crypto.deriveKekForLogin(
      password: password,
      kekSalt: srpAttributes.kekSalt,
      memLimit: srpAttributes.memLimit,
      opsLimit: srpAttributes.opsLimit,
    );

    // Decrypt secrets
    final rustKeyAttrs = rust.KeyAttributes(
      kekSalt: keyAttributes.kekSalt,
      encryptedKey: keyAttributes.encryptedKey,
      keyDecryptionNonce: keyAttributes.keyDecryptionNonce,
      publicKey: keyAttributes.publicKey,
      encryptedSecretKey: keyAttributes.encryptedSecretKey,
      secretKeyDecryptionNonce: keyAttributes.secretKeyDecryptionNonce,
      memLimit: keyAttributes.memLimit,
      opsLimit: keyAttributes.opsLimit,
    );

    final secrets = await _crypto.decryptSecretsWithKek(
      kek: kek,
      keyAttrs: rustKeyAttrs,
      encryptedToken: encryptedToken,
      plainToken: plainToken,
    );

    await _storeSecrets(
      email: email,
      userId: userId,
      secrets: secrets,
    );

    _logger.info('Login after email MFA successful');
  }

  Future<void> _storeSecrets({
    required String email,
    required int userId,
    required rust.AuthSecrets secrets,
  }) async {
    final config = Configuration.instance;

    // Convert to base64 for storage
    final masterKeyB64 = base64Encode(secrets.masterKey);
    final secretKeyB64 = base64Encode(secrets.secretKey);
    // Token is stored as URL-safe base64 (not UTF-8 decoded)
    final tokenB64 = base64Url.encode(secrets.token);

    await config.setEmail(email);
    await config.setUserId(userId);
    await config.setKey(masterKeyB64);
    await config.setSecretKey(secretKeyB64);
    await config.setToken(tokenB64);
    config.resetVolatilePassword();

    _logger.info('Credentials stored');
  }

  /// Get auth response for a verified passkey session.
  ///
  /// Server behavior (observed):
  /// - `400` when passkey not yet verified
  /// - `404/410` when session expired
  /// - `200` returns the same payload shape as other auth responses:
  ///   `id`, `keyAttributes`, `encryptedToken` (or `token`).
  Future<Map<String, dynamic>> getTokenForPasskeySession(
    String sessionId,
  ) async {
    try {
      final response = await _dio.get(
        '/users/two-factor/passkeys/get-token',
        queryParameters: {'sessionID': sessionId},
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        return data;
      }
      if (data is Map) {
        return Map<String, dynamic>.from(data);
      }
      throw Exception('Invalid passkey response type: ${data.runtimeType}');
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 400) {
        throw PasskeySessionNotVerifiedException();
      }
      if (status == 404 || status == 410) {
        throw PasskeySessionExpiredException();
      }
      rethrow;
    }
  }

  /// Verify 2FA TOTP code.
  Future<TwoFactorResult> verifyTwoFactor({
    required String sessionId,
    required String code,
  }) async {
    final response = await _dio.post('/users/two-factor/verify', data: {
      'sessionID': sessionId,
      'code': code,
    });

    return TwoFactorResult(
      id: response.data['id'],
      keyAttributes:
          ServerKeyAttributes.fromMap(response.data['keyAttributes']),
      encryptedToken: response.data['encryptedToken'] as String?,
      plainToken: response.data['token'] as String?,
    );
  }
}

/// Result of SRP login.
class SrpLoginResult {
  final String? twoFactorSessionId;
  final String? passkeySessionId;
  final String? accountsUrl;

  const SrpLoginResult({
    this.twoFactorSessionId,
    this.passkeySessionId,
    this.accountsUrl,
  });

  bool get requiresTwoFactor => twoFactorSessionId != null;
  bool get requiresPasskey => passkeySessionId != null;
}

/// Result of OTP verification (for email MFA flow).
class OtpVerificationResult {
  final int id;
  final ServerKeyAttributes? keyAttributes;
  final String? encryptedToken;
  final String? plainToken;
  final String? twoFactorSessionId;
  final String? passkeySessionId;
  final String accountsUrl;

  OtpVerificationResult({
    required this.id,
    this.keyAttributes,
    this.encryptedToken,
    this.plainToken,
    this.twoFactorSessionId,
    this.passkeySessionId,
    this.accountsUrl = _defaultAccountsUrl,
  });

  bool get isNewUser => keyAttributes == null;
  bool get requiresTwoFactor => twoFactorSessionId != null;
  bool get requiresPasskey => passkeySessionId != null;
}

/// Result of 2FA verification.
class TwoFactorResult {
  final int id;
  final ServerKeyAttributes keyAttributes;
  final String? encryptedToken;
  final String? plainToken;

  TwoFactorResult({
    required this.id,
    required this.keyAttributes,
    this.encryptedToken,
    this.plainToken,
  });
}

/// Key attributes from server.
class ServerKeyAttributes {
  final String kekSalt;
  final String encryptedKey;
  final String keyDecryptionNonce;
  final String publicKey;
  final String encryptedSecretKey;
  final String secretKeyDecryptionNonce;
  final int? memLimit;
  final int? opsLimit;

  ServerKeyAttributes({
    required this.kekSalt,
    required this.encryptedKey,
    required this.keyDecryptionNonce,
    required this.publicKey,
    required this.encryptedSecretKey,
    required this.secretKeyDecryptionNonce,
    this.memLimit,
    this.opsLimit,
  });

  factory ServerKeyAttributes.fromMap(Map<String, dynamic> map) {
    return ServerKeyAttributes(
      kekSalt: map['kekSalt'] as String,
      encryptedKey: map['encryptedKey'] as String,
      keyDecryptionNonce: map['keyDecryptionNonce'] as String,
      publicKey: map['publicKey'] as String,
      encryptedSecretKey: map['encryptedSecretKey'] as String,
      secretKeyDecryptionNonce: map['secretKeyDecryptionNonce'] as String,
      memLimit: map['memLimit'] as int?,
      opsLimit: map['opsLimit'] as int?,
    );
  }
}

/// SRP attributes from server.
class ServerSrpAttributes {
  final String srpUserId;
  final String srpSalt;
  final String kekSalt;
  final int memLimit;
  final int opsLimit;
  final bool isEmailMfaEnabled;

  ServerSrpAttributes({
    required this.srpUserId,
    required this.srpSalt,
    required this.kekSalt,
    required this.memLimit,
    required this.opsLimit,
    this.isEmailMfaEnabled = false,
  });

  factory ServerSrpAttributes.fromMap(Map<String, dynamic> map) {
    return ServerSrpAttributes(
      srpUserId: map['srpUserID'] as String,
      srpSalt: map['srpSalt'] as String,
      kekSalt: map['kekSalt'] as String,
      memLimit: map['memLimit'] as int,
      opsLimit: map['opsLimit'] as int,
      isEmailMfaEnabled: map['isEmailMFAEnabled'] as bool? ?? false,
    );
  }
}

class PasskeySessionNotVerifiedException implements Exception {}

class PasskeySessionExpiredException implements Exception {}
