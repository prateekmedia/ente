import 'dart:async';
import 'dart:typed_data';

import 'package:ente_base/models/database.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_events/event_bus.dart';
import 'package:ente_events/models/endpoint_updated_event.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Configuration and secrets management for Ensu app.
class Configuration extends BaseConfiguration {
  Configuration._privateConstructor();
  static final Configuration instance = Configuration._privateConstructor();

  @override
  List<String> get secureStorageKeys => [
        // Offline chat key is intentionally excluded to persist local encryption.
        _keyKey,
        _secretKeyKey,
        _chatSecretKeyKey,
        _tokenKey,
      ];

  static const _keyKey = "key";
  static const _secretKeyKey = "secretKey";
  static const _chatSecretKeyKey = "chat_secret_key";
  static const _offlineChatSecretKeyKey = "offline_chat_secret_key";
  static const _tokenKey = "token";
  static const _emailKey = "email";
  static const _userIdKey = "user_id";
  static const _httpEndpointKey = "http_endpoint";
  static const _customModelUrlKey = "custom_model_url";
  static const _customMmprojUrlKey = "custom_mmproj_url";
  static const _useCustomModelKey = "use_custom_model";
  static const _customModelContextLengthKey = "custom_model_context_length";
  static const _customModelMaxTokensKey = "custom_model_max_tokens";
  static const _defaultHttpEndpoint = String.fromEnvironment(
    'endpoint',
    defaultValue: 'https://api.ente.io',
  );

  late SharedPreferences _preferences;
  late FlutterSecureStorage _secureStorage;

  String? _key;
  String? _secretKey;
  String? _chatSecretKey;
  String? _offlineChatSecretKey;
  String? _token;
  String? _httpEndpoint;
  String? _customModelUrl;
  String? _customMmprojUrl;
  bool _useCustomModel = false;
  int? _customModelContextLength;
  int? _customModelMaxTokens;

  @override
  Future<void> init(List<EnteBaseDatabase> dbs) async {
    if (dbs.isNotEmpty) {
      // Ensu does not use BaseConfiguration databases; kept for API parity.
    }
    _preferences = await SharedPreferences.getInstance();
    _secureStorage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    final storedToken = await _secureStorage.read(key: _tokenKey);
    final cachedToken = _preferences.getString(BaseConfiguration.tokenKey);
    if ((cachedToken == null || cachedToken.isEmpty) &&
        storedToken != null &&
        storedToken.isNotEmpty) {
      await _preferences.setString(BaseConfiguration.tokenKey, storedToken);
    }
    await super.init(dbs);
    await _loadSecrets();
    if (_token == null || _token!.isEmpty) {
      await _preferences.remove(BaseConfiguration.tokenKey);
    }
    final storedHttpEndpoint = _preferences.getString(_httpEndpointKey);
    if (storedHttpEndpoint != null) {
      final normalized = _normalizeHttpEndpoint(storedHttpEndpoint);
      if (normalized.isEmpty) {
        _httpEndpoint = null;
        await _preferences.remove(_httpEndpointKey);
      } else {
        _httpEndpoint = normalized;
        if (normalized != storedHttpEndpoint) {
          await _preferences.setString(_httpEndpointKey, normalized);
        }
      }
    } else {
      _httpEndpoint = null;
    }

    _customModelUrl = _preferences.getString(_customModelUrlKey);
    _customMmprojUrl = _preferences.getString(_customMmprojUrlKey);
    _useCustomModel = _preferences.getBool(_useCustomModelKey) ?? false;
    _customModelContextLength =
        _preferences.getInt(_customModelContextLengthKey);
    _customModelMaxTokens = _preferences.getInt(_customModelMaxTokensKey);
  }

  Future<void> _loadSecrets() async {
    _key = await _secureStorage.read(key: _keyKey);
    _secretKey = await _secureStorage.read(key: _secretKeyKey);
    _chatSecretKey = await _secureStorage.read(key: _chatSecretKeyKey);
    _offlineChatSecretKey =
        await _secureStorage.read(key: _offlineChatSecretKeyKey);
    final storedToken = await _secureStorage.read(key: _tokenKey);
    final cachedToken = _preferences.getString(BaseConfiguration.tokenKey);
    if (cachedToken != null && cachedToken.isNotEmpty) {
      _token = cachedToken;
      if (storedToken != cachedToken) {
        await _secureStorage.write(key: _tokenKey, value: cachedToken);
      }
    } else if (storedToken != null && storedToken.isNotEmpty) {
      _token = storedToken;
      await _preferences.setString(BaseConfiguration.tokenKey, storedToken);
    } else {
      _token = null;
    }
  }

  @override
  bool hasConfiguredAccount() {
    final token = getToken();
    return token != null && token.isNotEmpty;
  }

  @override
  String? getEmail() => _preferences.getString(_emailKey);

  @override
  Future<void> setEmail(String email) async {
    await _preferences.setString(_emailKey, email);
  }

  @override
  int? getUserID() => _preferences.getInt(_userIdKey);

  int? getUserId() => getUserID();

  @override
  Future<void> setUserID(int userID) async {
    await _preferences.setInt(_userIdKey, userID);
  }

  Future<void> setUserId(int userId) async => setUserID(userId);

  @override
  String? getToken() {
    _token ??= super.getToken();
    return _token;
  }

  @override
  Future<void> setToken(String token) async {
    _token = token;
    await _secureStorage.write(key: _tokenKey, value: token);
    await super.setToken(token);
  }

  static String _normalizeHttpEndpoint(String endpoint) {
    var normalized = endpoint.trim();
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  @override
  String getHttpEndpoint() {
    final stored = _httpEndpoint;
    if (stored != null) {
      final normalized = _normalizeHttpEndpoint(stored);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return _normalizeHttpEndpoint(_defaultHttpEndpoint);
  }

  @override
  Future<void> setHttpEndpoint(String endpoint) async {
    final normalized = _normalizeHttpEndpoint(endpoint);
    if (normalized.isEmpty) {
      _httpEndpoint = null;
      await _preferences.remove(_httpEndpointKey);
    } else {
      _httpEndpoint = normalized;
      await _preferences.setString(_httpEndpointKey, normalized);
    }
    Bus.instance.fire(EndpointUpdatedEvent());
  }

  String? getCustomModelUrl() => _customModelUrl;

  Future<void> setCustomModelUrl(String? url) async {
    final normalized = url?.trim();
    if (normalized == null || normalized.isEmpty) {
      _customModelUrl = null;
      await _preferences.remove(_customModelUrlKey);
      _customMmprojUrl = null;
      await _preferences.remove(_customMmprojUrlKey);
      if (_useCustomModel) {
        _useCustomModel = false;
        await _preferences.setBool(_useCustomModelKey, false);
      }
      return;
    }
    _customModelUrl = normalized;
    await _preferences.setString(_customModelUrlKey, normalized);
  }

  String? getCustomMmprojUrl() => _customMmprojUrl;

  Future<void> setCustomMmprojUrl(String? url) async {
    final normalized = url?.trim();
    if (normalized == null || normalized.isEmpty) {
      _customMmprojUrl = null;
      await _preferences.remove(_customMmprojUrlKey);
      return;
    }
    _customMmprojUrl = normalized;
    await _preferences.setString(_customMmprojUrlKey, normalized);
  }

  bool getUseCustomModel() => _useCustomModel;

  Future<void> setUseCustomModel(bool useCustomModel) async {
    _useCustomModel = useCustomModel;
    await _preferences.setBool(_useCustomModelKey, useCustomModel);
  }

  int? getCustomModelContextLength() => _customModelContextLength;

  Future<void> setCustomModelContextLength(int? value) async {
    if (value == null || value <= 0) {
      _customModelContextLength = null;
      await _preferences.remove(_customModelContextLengthKey);
      return;
    }
    _customModelContextLength = value;
    await _preferences.setInt(_customModelContextLengthKey, value);
  }

  int? getCustomModelMaxOutputTokens() => _customModelMaxTokens;

  Future<void> setCustomModelMaxOutputTokens(int? value) async {
    if (value == null || value <= 0) {
      _customModelMaxTokens = null;
      await _preferences.remove(_customModelMaxTokensKey);
      return;
    }
    _customModelMaxTokens = value;
    await _preferences.setInt(_customModelMaxTokensKey, value);
  }

  @override
  Uint8List? getKey() {
    if (_key == null) return null;
    return CryptoUtil.base642bin(_key!);
  }

  @override
  Future<void> setKey(String key) async {
    _key = key;
    await _secureStorage.write(key: _keyKey, value: key);
  }

  @override
  Uint8List? getSecretKey() {
    if (_secretKey == null) return null;
    return CryptoUtil.base642bin(_secretKey!);
  }

  @override
  Future<void> setSecretKey(String? secretKey) async {
    _secretKey = secretKey;
    if (secretKey == null) {
      await _secureStorage.delete(key: _secretKeyKey);
      return;
    }
    await _secureStorage.write(key: _secretKeyKey, value: secretKey);
  }

  Uint8List? getChatSecretKey() {
    if (_chatSecretKey == null) return null;
    return CryptoUtil.base642bin(_chatSecretKey!);
  }

  Future<void> setChatSecretKey(String chatSecretKey) async {
    _chatSecretKey = chatSecretKey;
    await _secureStorage.write(key: _chatSecretKeyKey, value: chatSecretKey);
  }

  Uint8List? getOfflineChatSecretKey() {
    if (_offlineChatSecretKey == null) return null;
    return CryptoUtil.base642bin(_offlineChatSecretKey!);
  }

  Future<Uint8List> getOrCreateOfflineChatSecretKey() async {
    if (_offlineChatSecretKey != null) {
      return CryptoUtil.base642bin(_offlineChatSecretKey!);
    }
    final stored = await _secureStorage.read(key: _offlineChatSecretKeyKey);
    if (stored != null && stored.isNotEmpty) {
      _offlineChatSecretKey = stored;
      return CryptoUtil.base642bin(stored);
    }
    final key = CryptoUtil.generateKey();
    final encoded = CryptoUtil.bin2base64(key);
    _offlineChatSecretKey = encoded;
    await _secureStorage.write(key: _offlineChatSecretKeyKey, value: encoded);
    return key;
  }

  @override
  Future<void> logout({bool autoLogout = false}) async {
    _key = null;
    _secretKey = null;
    _chatSecretKey = null;
    _offlineChatSecretKey = null;
    _token = null;
    _httpEndpoint = null;
    _customModelUrl = null;
    _customMmprojUrl = null;
    _useCustomModel = false;
    _customModelContextLength = null;
    _customModelMaxTokens = null;

    await super.logout(autoLogout: autoLogout);
  }

  SharedPreferences get preferences => _preferences;
}
