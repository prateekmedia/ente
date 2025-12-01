import 'package:ente_configuration/secure_storage/secure_storage_service.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Default implementation of [SecureStorageService] using flutter_secure_storage.
/// This is used on platforms other than Linux (iOS, Android, macOS, Windows).
class FlutterSecureStorageImpl implements SecureStorageService {
  late FlutterSecureStorage _storage;

  @override
  Future<void> init() async {
    _storage = const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  }

  @override
  Future<String?> read({required String key}) async {
    return _storage.read(key: key);
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    await _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) async {
    await _storage.delete(key: key);
  }

  @override
  Future<bool> containsKey({required String key}) async {
    return _storage.containsKey(key: key);
  }

  @override
  Future<void> close() async {
    // flutter_secure_storage doesn't require explicit close
  }
}
