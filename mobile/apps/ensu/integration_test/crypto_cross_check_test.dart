import 'dart:typed_data';

import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart';
import 'package:ente_rust/ente_rust.dart' hide CryptoUtil;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('crypto cross-check adapter', (tester) async {
    await EnteRust.init();
    initCrypto();

    registerCryptoApi(EnteCryptoCrossCheckAdapter());
    await CryptoUtil.init();

    final payload = Uint8List.fromList(const [1, 2, 3, 4, 5, 6]);
    final key = CryptoUtil.generateKey();
    final encrypted = CryptoUtil.encryptSync(payload, key);
    final decrypted = CryptoUtil.decryptSync(
      encrypted.encryptedData!,
      key,
      encrypted.nonce!,
    );

    expect(decrypted, equals(payload));
  });
}
