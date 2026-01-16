import 'dart:io';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart';
import 'package:ente_logging/logging.dart';
import 'package:ente_network/network.dart';
import 'package:ente_rust/ente_rust.dart' hide CryptoUtil;
import 'package:ente_strings/ente_strings.dart';
import 'package:ente_accounts/ente_accounts.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/core/feature_flags.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:ensu/services/llm/fllama_provider.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/store/chat_db.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _logger = Logger("main");

Future<void> main() async {
  await _runWithLogs(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Initialize FFI for desktop platforms
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
    }

    _logger.fine("Starting Ensu");
    await _init();
    runApp(const EnsuApp());
  });
}

Future<void> _runWithLogs(Future<void> Function() body) async {
  WidgetsFlutterBinding.ensureInitialized();

  await SuperLogging.main(
    LogConfig(
      body: body,
      logDirPath: "${(await getApplicationSupportDirectory()).path}/logs",
      maxLogFiles: 5,
      enableInDebugMode: true,
    ),
  );
}

Future<void> _init() async {
  await EnteRust.init();
  initCrypto();

  registerCryptoApi(EnteCryptoCrossCheckAdapter());
  await CryptoUtil.init();

  await Configuration.instance.init([]);

  await Network.instance.init(Configuration.instance);
  await UserService.instance.init(
    Configuration.instance,
    const HomePage(),
    clientPackageName: 'io.ente.auth',
    passkeyRedirectUrl: 'enteauth://passkey',
  );

  // Initialize DB (needed before ChatService)
  await ChatDB.instance.database;

  await ChatService.instance.init();

  // Initialize LLM with fllama provider
  if (FeatureFlags.useRustLlama) {
    _logger.warning(
      'Rust LLM flag enabled but provider is disabled; using fllama.',
    );
  }

  LLMService.instance.setProvider(FllamaProvider());
  await LLMService.instance.init();
}

class EnsuApp extends StatelessWidget {
  const EnsuApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AdaptiveTheme(
      light: EnsuTheme.light(),
      dark: EnsuTheme.dark(),
      initial: AdaptiveThemeMode.system,
      builder: (theme, darkTheme) => MaterialApp(
        title: 'Ensu',
        theme: theme,
        darkTheme: darkTheme,
        localizationsDelegates: StringsLocalizations.localizationsDelegates,
        supportedLocales: StringsLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        home: const HomePage(),
      ),
    );
  }
}
