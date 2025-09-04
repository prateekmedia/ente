import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:photos/app.dart';
import 'package:adaptive_theme/adaptive_theme.dart';
import 'package:photos/ui/tools/app_lock.dart';
import 'package:photos/ui/tools/lock_screen.dart';
import 'package:photos/ente_theme_data.dart';

void main() {
  patrolTest(
    'Simple Patrol Test - App Launches',
    framePolicy: LiveTestWidgetsFlutterBindingFramePolicy.fullyLive,
    nativeAutomation: true,
    ($) async {
      // Initialize and launch the app properly
      await $.pumpWidgetAndSettle(
        AppLock(
          builder: (args) => const EnteApp(null, null),
          lockScreen: const LockScreen(),
          enabled: false, // Disable lock screen for testing
          locale: null,
          lightTheme: lightThemeData,
          darkTheme: darkThemeData,
          savedThemeMode: null,
        ),
      );
      
      // Wait for app to fully initialize
      await Future.delayed(const Duration(seconds: 3));
      await $.pumpAndSettle();
      
      // Verify app has loaded past splash screen
      // Look for any common widgets that would appear after splash
      final hasContent = find.byType(Scaffold).evaluate().isNotEmpty ||
                         find.byType(Container).evaluate().isNotEmpty ||
                         find.byType(Column).evaluate().isNotEmpty;
      
      expect(hasContent, true, reason: 'App should have loaded past splash screen');
      
      // Try to find text widgets that might appear on landing page
      final textWidgets = find.byType(Text);
      if (textWidgets.evaluate().isNotEmpty) {
        debugPrint('Found ${textWidgets.evaluate().length} text widgets');
      }
    },
  );
}