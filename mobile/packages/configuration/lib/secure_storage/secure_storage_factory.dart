import 'package:ente_configuration/secure_storage/secure_storage_service.dart';
import 'package:ente_configuration/secure_storage/flutter_secure_storage_impl.dart';

/// Default factory for non-IO platforms (web).
/// Falls back to flutter_secure_storage implementation.
SecureStorageService createSecureStorageService() {
  return FlutterSecureStorageImpl();
}
