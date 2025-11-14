// ignore_for_file: deprecated_member_use

import "dart:async";
import "dart:developer" as developer;

import "package:flutter/widgets.dart";
import "package:logging/logging.dart";
import "package:sentry_flutter/sentry_flutter.dart";

final _logger = Logger("bootstrap");

Future<void> bootstrap(FutureOr<Widget> Function() builder) async {
  // Enhanced error handler that logs every render failure
  FlutterError.onError = (details) {
    // Log to dart:developer for immediate console output
    developer.log(
      details.exceptionAsString(),
      stackTrace: details.stack,
      name: 'FlutterError',
    );

    // Log via Logger for file logging and Sentry integration
    _logger.severe(
      'Widget render failed: ${details.exceptionAsString()}',
      details.exception,
      details.stack,
    );

    // Add breadcrumb to Sentry for better error tracking
    try {
      Sentry.addBreadcrumb(
        Breadcrumb(
          message: 'Widget render failure',
          category: 'ui.render',
          level: SentryLevel.error,
          data: {
            'exception': details.exceptionAsString(),
            'library': details.library ?? 'unknown',
            'context': details.context?.toString() ?? 'no context',
          },
        ),
      );
    } catch (e) {
      // Silently fail if Sentry is not initialized
      developer.log('Failed to add Sentry breadcrumb: $e');
    }

    // Let Flutter show the error widget
    FlutterError.presentError(details);
  };

  await runZonedGuarded(
    () async {
      runApp(await builder());
    },
    (error, stackTrace) {
      developer.log(error.toString(), stackTrace: stackTrace);
      _logger.severe('Uncaught error in app zone', error, stackTrace);
    },
  );
}
