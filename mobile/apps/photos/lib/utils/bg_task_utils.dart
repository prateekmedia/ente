import "dart:async";
import "dart:io";

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

const _fgCh = MethodChannel('io.ente.photos/fgservice');

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
    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(message: 'Background WorkManager task started'),
      ),
    );

    // Start foreground service on Android to prevent task from being killed
    // Only for internal users
    if (Platform.isAndroid) {
      BgTaskUtils.$.info(
        'BG Service: Checking feature flag for foreground service',
      );

      // Check if user is internal (feature flag check happens in service locator after init)
      const shouldUseForegroundService =
          kDebugMode; // Will be checked again after flagService is initialized

      if (shouldUseForegroundService) {
        try {
          BgTaskUtils.$.info(
            'BG Service: Starting foreground service (internal user)',
          );
          await _fgCh.invokeMethod('start', {
            'title': 'Ente - Uploading photos',
            'text': 'Preparing for upload…',
          });
          BgTaskUtils.$.info(
            'BG Service: Foreground service started successfully',
          );
          unawaited(
            Sentry.addBreadcrumb(
              Breadcrumb(message: 'Foreground service started'),
            ),
          );
        } catch (e, s) {
          BgTaskUtils.$.warning(
            'BG Service: Failed to start foreground service: $e',
          );
          unawaited(Sentry.captureException(e, stackTrace: s));
        }
      } else {
        BgTaskUtils.$.info(
          'BG Service: Skipping foreground service (not internal user)',
        );
        unawaited(
          Sentry.addBreadcrumb(
            Breadcrumb(
              message: 'Foreground service skipped (not internal user)',
            ),
          ),
        );
      }
    }

    try {
      await runWithLogs(
        () async {
          try {
            BgTaskUtils.$.info('BG Task: Started $tlog');
            unawaited(
              Sentry.addBreadcrumb(
                Breadcrumb(message: 'Background task execution started'),
              ),
            );

            await runBackgroundTask(taskName, tlog).timeout(
              Platform.isIOS ? kBGTaskTimeout : const Duration(hours: 1),
              onTimeout: () async {
                BgTaskUtils.$.warning(
                  "TLE, committing seppuku for taskID: $taskName",
                );
                final timeoutError =
                    TimeoutException('Background task exceeded timeout');
                unawaited(
                  Sentry.captureException(
                    timeoutError,
                    stackTrace: StackTrace.current,
                  ),
                );
                unawaited(
                  Sentry.addBreadcrumb(
                    Breadcrumb(message: 'Background task timed out'),
                  ),
                );
                await BgTaskUtils.releaseResourcesForKill(taskName, prefs);
              },
            );

            BgTaskUtils.$.info('BG Task: Completed successfully $tlog');
            unawaited(
              Sentry.addBreadcrumb(
                Breadcrumb(message: 'Background task completed successfully'),
              ),
            );
            result = Future.value(true);
          } catch (e, s) {
            BgTaskUtils.$.warning('BG Task: Failed with error: $e');
            unawaited(Sentry.captureException(e, stackTrace: s));
            unawaited(
              Sentry.addBreadcrumb(
                Breadcrumb(
                  message: 'Background task failed',
                  data: {'error': e.toString()},
                ),
              ),
            );
            await BgTaskUtils.releaseResourcesForKill(taskName, prefs);
            result = Future.error(e.toString());
          }
        },
        prefix: "[bg]",
      ).onError((e, s) {
        BgTaskUtils.$.severe("BG Task: Didn't finish correctly!");
        unawaited(Sentry.captureException(e, stackTrace: s));
        result = Future.error("Didn't finished correctly!");
        return;
      });
    } finally {
      // Stop foreground service on Android
      if (Platform.isAndroid) {
        try {
          BgTaskUtils.$.info('BG Service: Stopping foreground service');
          await _fgCh.invokeMethod('stop');
          BgTaskUtils.$.info('BG Service: Foreground service stopped');
          unawaited(
            Sentry.addBreadcrumb(
              Breadcrumb(message: 'Foreground service stopped'),
            ),
          );
        } catch (e, s) {
          BgTaskUtils.$.warning(
            'BG Service: Failed to stop foreground service: $e',
          );
          unawaited(Sentry.captureException(e, stackTrace: s));
        }
      }

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
