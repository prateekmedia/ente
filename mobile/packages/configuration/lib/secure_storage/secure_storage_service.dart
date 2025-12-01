import 'package:ente_configuration/secure_storage/secure_storage_factory.dart'
    if (dart.library.io) 'package:ente_configuration/secure_storage/secure_storage_factory_io.dart';

/// Abstract interface for secure storage operations.
/// This allows platform-specific implementations (dbus_secrets on Linux,
/// flutter_secure_storage on other platforms).
abstract class SecureStorageService {
  /// Factory constructor that returns the appropriate implementation
  /// based on the current platform.
  factory SecureStorageService() => createSecureStorageService();

  /// Initialize the secure storage service.
  /// Must be called before any other operations.
  Future<void> init();

  /// Read a value from secure storage.
  Future<String?> read({required String key});

  /// Write a value to secure storage.
  Future<void> write({required String key, required String? value});

  /// Delete a value from secure storage.
  Future<void> delete({required String key});

  /// Check if a key exists in secure storage.
  Future<bool> containsKey({required String key});

  /// Close the secure storage connection.
  /// Should be called when the app is shutting down.
  Future<void> close();
}
