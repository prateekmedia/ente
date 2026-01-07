import 'dart:async';
import 'dart:typed_data';

import 'package:ente_rust/ente_rust.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Configuration and secrets management for Ensu app.
class Configuration {
  Configuration._privateConstructor();
  static final Configuration instance = Configuration._privateConstructor();

  static const _keyKey = "key";
  static const _secretKeyKey = "secretKey";
  static const _chatSecretKeyKey = "chat_secret_key";
  static const _tokenKey = "token";
  static const _emailKey = "email";
  static const _userIdKey = "user_id";

  late SharedPreferences _preferences;
  late FlutterSecureStorage _secureStorage;

  String? _key;
  String? _secretKey;
  String? _chatSecretKey;
  String? _token;

  Future<void> init() async {
    _preferences = await SharedPreferences.getInstance();
    _secureStorage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    await _loadSecrets();
  }

  Future<void> _loadSecrets() async {
    _key = await _secureStorage.read(key: _keyKey);
    _secretKey = await _secureStorage.read(key: _secretKeyKey);
    _chatSecretKey = await _secureStorage.read(key: _chatSecretKeyKey);
    _token = await _secureStorage.read(key: _tokenKey);
  }

  bool hasConfiguredAccount() {
    return _token != null && _token!.isNotEmpty;
  }

  String? getEmail() => _preferences.getString(_emailKey);

  Future<void> setEmail(String email) async {
    await _preferences.setString(_emailKey, email);
  }

  int? getUserId() => _preferences.getInt(_userIdKey);

  Future<void> setUserId(int userId) async {
    await _preferences.setInt(_userIdKey, userId);
  }

  String? getToken() => _token;

  Future<void> setToken(String token) async {
    _token = token;
    await _secureStorage.write(key: _tokenKey, value: token);
  }

  Uint8List? getKey() {
    if (_key == null) return null;
    return decodeB64(data: _key!);
  }

  Future<void> setKey(String key) async {
    _key = key;
    await _secureStorage.write(key: _keyKey, value: key);
  }

  Uint8List? getSecretKey() {
    if (_secretKey == null) return null;
    return decodeB64(data: _secretKey!);
  }

  Future<void> setSecretKey(String secretKey) async {
    _secretKey = secretKey;
    await _secureStorage.write(key: _secretKeyKey, value: secretKey);
  }

  Uint8List? getChatSecretKey() {
    if (_chatSecretKey == null) return null;
    return decodeB64(data: _chatSecretKey!);
  }

  Future<void> setChatSecretKey(String chatSecretKey) async {
    _chatSecretKey = chatSecretKey;
    await _secureStorage.write(key: _chatSecretKeyKey, value: chatSecretKey);
  }

  Future<void> logout() async {
    _key = null;
    _secretKey = null;
    _chatSecretKey = null;
    _token = null;

    await _secureStorage.delete(key: _keyKey);
    await _secureStorage.delete(key: _secretKeyKey);
    await _secureStorage.delete(key: _chatSecretKeyKey);
    await _secureStorage.delete(key: _tokenKey);
    await _preferences.remove(_emailKey);
    await _preferences.remove(_userIdKey);
  }

  SharedPreferences get preferences => _preferences;
}
