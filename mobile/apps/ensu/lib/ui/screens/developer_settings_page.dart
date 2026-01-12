import 'package:ente_configuration/base_configuration.dart';
import 'package:ente_ui/pages/developer_settings_page.dart' as ente_ui;
import 'package:ensu/auth/auth_service.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DeveloperSettingsPage extends StatelessWidget {
  const DeveloperSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseStyle =
        theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge;
    final serifStyle = GoogleFonts.cormorantGaramond(textStyle: baseStyle);

    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          titleTextStyle: serifStyle,
        ),
      ),
      child: ente_ui.DeveloperSettingsPage(_EnsuConfigurationAdapter()),
    );
  }
}

class _EnsuConfigurationAdapter extends BaseConfiguration {
  final Configuration _config = Configuration.instance;

  @override
  String getHttpEndpoint() => _config.getHttpEndpoint();

  @override
  Future<void> setHttpEndpoint(String endpoint) async {
    await _config.setHttpEndpoint(endpoint);
    AuthService.instance.updateEndpoint(endpoint);
    ChatService.instance.updateEndpoint(endpoint);
  }
}
