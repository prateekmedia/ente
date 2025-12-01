import 'dart:io';

import 'package:ente_configuration/secure_storage/secure_storage_service.dart';
import 'package:ente_configuration/secure_storage/flutter_secure_storage_impl.dart';
import 'package:ente_configuration/secure_storage/dbus_secure_storage.dart';

/// Factory for IO-based platforms (mobile/desktop).
/// Returns DBusSecureStorage on Linux, FlutterSecureStorageImpl elsewhere.
SecureStorageService createSecureStorageService() {
  if (Platform.isLinux) {
    return DBusSecureStorage();
  }
  return FlutterSecureStorageImpl();
}
