import 'package:ente_configuration/secure_storage/secure_storage_service.dart';

/// Stub implementation that throws if used.
/// This should never be called - it exists only to satisfy the type system
/// on platforms where dbus_secrets isn't available.
class DBusSecureStorage implements SecureStorageService {
  @override
  Future<void> init() async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }

  @override
  Future<String?> read({required String key}) async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }

  @override
  Future<void> delete({required String key}) async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }

  @override
  Future<bool> containsKey({required String key}) async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }

  @override
  Future<void> close() async {
    throw UnsupportedError('DBusSecureStorage is only available on Linux');
  }
}
