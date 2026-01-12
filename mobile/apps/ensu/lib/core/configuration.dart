import 'dart:async';
import 'dart:typed_data';

import 'package:ente_base/models/database.dart';
import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
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
  static const _useCustomModelKey = "use_custom_model";
  static const _defaultHttpEndpoint = "https://api.ente.io";

  late SharedPreferences _preferences;
  late FlutterSecureStorage _secureStorage;

  String? _key;
  String? _secretKey;
  String? _chatSecretKey;
  String? _offlineChatSecretKey;
  String? _token;
  String? _httpEndpoint;
  String? _customModelUrl;
  bool _useCustomModel = false;

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
    await super.init(dbs);
    await _loadSecrets();
    _httpEndpoint = _preferences.getString(_httpEndpointKey);
    _customModelUrl = _preferences.getString(_customModelUrlKey);
    _useCustomModel = _preferences.getBool(_useCustomModelKey) ?? false;
  }

  Future<void> _loadSecrets() async {
    _key = await _secureStorage.read(key: _keyKey);
    _secretKey = await _secureStorage.read(key: _secretKeyKey);
    _chatSecretKey = await _secureStorage.read(key: _chatSecretKeyKey);
    _offlineChatSecretKey =
        await _secureStorage.read(key: _offlineChatSecretKeyKey);
    _token = await _secureStorage.read(key: _tokenKey);
  }

  @override
  bool hasConfiguredAccount() {
    return _token != null && _token!.isNotEmpty;
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
  String? getToken() => _token;

  @override
  Future<void> setToken(String token) async {
    _token = token;
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  @override
  String getHttpEndpoint() => _httpEndpoint ?? _defaultHttpEndpoint;

  @override
  Future<void> setHttpEndpoint(String endpoint) async {
    _httpEndpoint = endpoint;
    await _preferences.setString(_httpEndpointKey, endpoint);
  }

  String? getCustomModelUrl() => _customModelUrl;

  Future<void> setCustomModelUrl(String? url) async {
    final normalized = url?.trim();
    if (normalized == null || normalized.isEmpty) {
      _customModelUrl = null;
      await _preferences.remove(_customModelUrlKey);
      if (_useCustomModel) {
        _useCustomModel = false;
        await _preferences.setBool(_useCustomModelKey, false);
      }
      return;
    }
    _customModelUrl = normalized;
    await _preferences.setString(_customModelUrlKey, normalized);
  }

  bool getUseCustomModel() => _useCustomModel;

  Future<void> setUseCustomModel(bool useCustomModel) async {
    _useCustomModel = useCustomModel;
    await _preferences.setBool(_useCustomModelKey, useCustomModel);
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

  Future<void> _clearSecureStorageKeys() async {
    for (final key in secureStorageKeys.toSet()) {
      await _secureStorage.delete(key: key);
    }
  }

  @override
  Future<void> logout({bool autoLogout = false}) async {
    _key = null;
    _secretKey = null;
    _chatSecretKey = null;
    _token = null;

    await _clearSecureStorageKeys();
    await _preferences.remove(_emailKey);
    await _preferences.remove(_userIdKey);
  }

  SharedPreferences get preferences => _preferences;
}
