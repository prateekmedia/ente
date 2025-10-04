import "dart:async";
import "dart:io";

import "package:device_info_plus/device_info_plus.dart";
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";
import "package:logging/logging.dart";
import "package:permission_handler/permission_handler.dart";
import "package:photos/db/upload_locks_db.dart";
import "package:photos/extensions/stop_watch.dart";
import "package:photos/main.dart";
import "package:photos/services/sync/sync_run_guard.dart";
import "package:photos/utils/file_uploader.dart";
import "package:sentry_flutter/sentry_flutter.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:workmanager/workmanager.dart" as workmanager;

@pragma('vm:entry-point')
void callbackDispatcher() {
  workmanager.Workmanager().executeTask((taskName, inputData) async {
    final TimeLogger tlog = TimeLogger();
    Future<bool> result = Future.error("Task didn't run");
    final prefs = await SharedPreferences.getInstance();

    // Set up Sentry context for background task
    await Sentry.configureScope((scope) {
      scope.setTag('execution_mode', 'background');
      scope.setContexts('background_task', {
        'task_name': taskName,
        'task_id': taskName,
        'timestamp': DateTime.now().toIso8601String(),
        'platform': Platform.operatingSystem,
      });
    });
    BgTaskUtils.addSentryBreadcrumb(
      Breadcrumb(message: 'Background WorkManager task started'),
    );

    try {
      await runWithLogs(
        () async {
          try {
            BgTaskUtils.$.info('BG Task: Started $tlog');
            BgTaskUtils.addSentryBreadcrumb(
              Breadcrumb(message: 'Background task execution started'),
            );

            await runBackgroundTask(taskName, tlog).timeout(
              Platform.isIOS ? kBGTaskTimeout : const Duration(hours: 1),
              onTimeout: () async {
                BgTaskUtils.$.warning(
                  "TLE, committing seppuku for taskID: $taskName",
                );
                final timeoutError =
                    TimeoutException('Background task exceeded timeout');
                BgTaskUtils.captureSentryException(
                  timeoutError,
                  stackTrace: StackTrace.current,
                  level: SentryLevel.fatal,
                );
                BgTaskUtils.addSentryBreadcrumb(
                  Breadcrumb(message: 'Background task timed out'),
                );
                await BgTaskUtils.releaseResourcesForKill(taskName, prefs);
              },
            );

            BgTaskUtils.$.info('BG Task: Completed successfully $tlog');
            BgTaskUtils.addSentryBreadcrumb(
              Breadcrumb(message: 'Background task completed successfully'),
            );
            result = Future.value(true);
          } catch (e, s) {
            BgTaskUtils.$.warning('BG Task: Failed with error: $e');
            BgTaskUtils.captureSentryException(
              e,
              stackTrace: s,
              level: SentryLevel.error,
            );
            BgTaskUtils.addSentryBreadcrumb(
              Breadcrumb(
                message: 'Background task failed',
                data: {'error': e.toString()},
              ),
            );
            await BgTaskUtils.releaseResourcesForKill(taskName, prefs);
            result = Future.error(e.toString());
          }
        },
        prefix: "[bg]",
      ).onError((e, s) {
        BgTaskUtils.$.severe("BG Task: Didn't finish correctly!");
        BgTaskUtils.captureSentryException(
          e,
          stackTrace: s,
          level: SentryLevel.fatal,
        );
        result = Future.error("Didn't finished correctly!");
        return;
      });
    } finally {
      final isSuccess = await result.then((_) => true).catchError((_) => false);
      BgTaskUtils.$.info(
        'BG WorkManager: Task returning with result: ${isSuccess ? "success" : "failure"}',
      );
    }

    return result;
  });
}

class BgTaskUtils {
  static final $ = Logger("BgTaskUtils");
  static const _fgCh = MethodChannel('io.ente.photos/fgservice');

  /// Start foreground service on Android for internal users
  /// Returns true if service was started successfully, false otherwise
  static Future<bool> startForegroundService() async {
    if (!Platform.isAndroid) return false;

    // Check notification permission on Android 13+ (API 33+)
    // Foreground service requires notification permission to display notification
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 33) {
      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted) {
        $.warning(
          'BG Service: Skipping foreground service - notification permission not granted (Android 13+)',
        );
        addSentryBreadcrumb(
          Breadcrumb(
            message: 'Foreground service skipped - no notification permission',
          ),
        );
        return false;
      }
    }

    try {
      $.info('BG Service: Starting foreground service (internal user)');
      await _fgCh.invokeMethod('start', {
        'title': 'Ente - Uploading photos',
        'text': 'Preparing for upload…',
      });
      $.info('BG Service: Foreground service started successfully');
      addSentryBreadcrumb(
        Breadcrumb(message: 'Foreground service started'),
      );
      return true;
    } catch (e, s) {
      $.warning('BG Service: Failed to start foreground service: $e');
      captureSentryException(e, stackTrace: s, level: SentryLevel.warning);
      return false;
    }
  }

  /// Stop foreground service on Android
  static Future<void> stopForegroundService() async {
    if (!Platform.isAndroid) return;

    try {
      $.info('BG Service: Stopping foreground service');
      await _fgCh.invokeMethod('stop');
      $.info('BG Service: Foreground service stopped');
      addSentryBreadcrumb(
        Breadcrumb(message: 'Foreground service stopped'),
      );
    } catch (e, s) {
      $.warning('BG Service: Failed to stop foreground service: $e');
      captureSentryException(e, stackTrace: s, level: SentryLevel.warning);
    }
  }

  /// Safely capture exception to Sentry with network error handling
  static void captureSentryException(
    dynamic exception, {
    dynamic stackTrace,
    SentryLevel? level,
  }) {
    try {
      unawaited(
        Sentry.captureException(
          exception,
          stackTrace: stackTrace,
          withScope: (scope) {
            if (level != null) {
              scope.level = level;
            }
          },
        ),
      );
    } catch (e) {
      // Sentry failed (likely network issue) - log it but don't crash
      $.warning(
        'Failed to capture exception in Sentry (likely network issue): $e',
      );
    }
  }

  /// Safely add Sentry breadcrumb with network error handling
  static void addSentryBreadcrumb(Breadcrumb breadcrumb) {
    try {
      unawaited(Sentry.addBreadcrumb(breadcrumb));
    } catch (e) {
      $.warning('Failed to add Sentry breadcrumb (likely network issue): $e');
    }
  }

  static Future<void> releaseResourcesForKill(
    String taskId,
    SharedPreferences prefs,
  ) async {
    await UploadLocksDB.instance.releaseLocksAcquiredByOwnerBefore(
      ProcessType.background.toString(),
      DateTime.now().microsecondsSinceEpoch,
    );
    await SyncRunGuard.clearIfStale();
    await prefs.remove(kLastBGTaskHeartBeatTime);
  }

  static Future configureWorkmanager() async {
    if (Platform.isIOS) {
      final status = await Permission.backgroundRefresh.status;
      if (status != PermissionStatus.granted) {
        $.warning(
          "Background refresh permission is not granted. Please grant it to start the background service.",
        );
        return;
      }
    }
    $.warning("Configuring Work Manager for background tasks");
    const iOSBackgroundAppRefresh = "io.ente.frame.iOSBackgroundAppRefresh";
    const androidPeriodicTask = "io.ente.photos.androidPeriodicTask";
    final backgroundTaskIdentifier =
        Platform.isIOS ? iOSBackgroundAppRefresh : androidPeriodicTask;
    try {
      await workmanager.Workmanager().initialize(
        callbackDispatcher,
        isInDebugMode: false,
      );
      await workmanager.Workmanager().registerPeriodicTask(
        backgroundTaskIdentifier,
        backgroundTaskIdentifier,
        frequency: Platform.isIOS
            ? const Duration(minutes: 30)
            : const Duration(minutes: 15),
        initialDelay: kDebugMode ? Duration.zero : const Duration(minutes: 10),
        constraints: workmanager.Constraints(
          networkType: workmanager.NetworkType.connected,
          requiresCharging: false,
          requiresStorageNotLow: false,
          requiresDeviceIdle: false,
        ),
        existingWorkPolicy: workmanager.ExistingWorkPolicy.append,
        backoffPolicy: workmanager.BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 15),
      );
      $.info("WorkManager configured");
    } catch (e) {
      $.warning("Failed to configure WorkManager: $e");
    }
  }
}
