import 'package:dbus_secrets/dbus_secrets.dart';
import 'package:ente_configuration/secure_storage/secure_storage_service.dart';
import 'package:ente_logging/logging.dart';

/// Linux-specific implementation of [SecureStorageService] using D-Bus Secret Service.
/// This replaces libsecret with direct D-Bus communication for better compatibility
/// across different Linux distributions.
class DBusSecureStorage implements SecureStorageService {
  static final _logger = Logger('DBusSecureStorage');

  DBusSecrets? _secrets;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (_initialized) return;

    try {
      _secrets = DBusSecrets(appName: 'ente_auth');
      await _secrets!.initialize();
      await _secrets!.unlock();
      _initialized = true;
      _logger.info('DBus Secret Service initialized successfully');
    } catch (e, s) {
      _logger.severe('Failed to initialize DBus Secret Service', e, s);
      rethrow;
    }
  }

  @override
  Future<String?> read({required String key}) async {
    _ensureInitialized();
    try {
      final value = await _secrets!.get(key);
      return value;
    } catch (e) {
      _logger.warning('Failed to read key: $key', e);
      return null;
    }
  }

  @override
  Future<void> write({required String key, required String? value}) async {
    _ensureInitialized();
    try {
      if (value == null) {
        await delete(key: key);
        return;
      }
      await _secrets!.set(key, value);
    } catch (e, s) {
      _logger.severe('Failed to write key: $key', e, s);
      rethrow;
    }
  }

  @override
  Future<void> delete({required String key}) async {
    _ensureInitialized();
    try {
      await _secrets!.delete(key);
    } catch (e) {
      // Ignore errors when deleting non-existent keys
      _logger.warning('Failed to delete key: $key (may not exist)', e);
    }
  }

  @override
  Future<bool> containsKey({required String key}) async {
    _ensureInitialized();
    try {
      final value = await _secrets!.get(key);
      return value != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> close() async {
    if (_secrets != null) {
      try {
        await _secrets!.close();
      } catch (e) {
        _logger.warning('Error closing DBus connection', e);
      }
      _secrets = null;
      _initialized = false;
    }
  }

  void _ensureInitialized() {
    if (!_initialized || _secrets == null) {
      throw StateError(
        'DBusSecureStorage not initialized. Call init() first.',
      );
    }
  }
}
