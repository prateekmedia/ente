import 'dart:async';
import 'dart:io';

import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:ente_rust/ente_rust.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:ensu/services/llm/fllama_provider.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/store/chat_db.dart';
import 'package:ensu/ui/screens/home_page.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _logger = Logger("main");

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint(
        '${record.level.name}: ${record.time}: ${record.loggerName}: ${record.message}');
  });

  // Initialize FFI for desktop platforms
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
  }

  _logger.info("Starting Ensu");
  await _init();
  runApp(const EnsuApp());
}

Future<void> _init() async {
  // Initialize rust crypto
  await EnteRust.init();
  initCrypto();

  await Configuration.instance.init();

  // Initialize DB (needed before ChatService)
  await ChatDB.instance.database;

  await ChatService.instance.init();

  // Initialize LLM with FLlama provider
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
        debugShowCheckedModeBanner: false,
        home: const HomePage(),
      ),
    );
  }
}
