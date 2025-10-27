import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/album_home_widget_service.dart';
import 'package:photos/services/home_widget_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group("Widget Capture File Test - useWidgetV2", () {
    final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    final Logger logger = Logger("WidgetCaptureFileTest");

    testWidgets(
      "Test favorite albums refresh and verify 1024px widget images",
      semanticsEnabled: false,
      (tester) async {
        await runZonedGuarded(
          () async {
            logger.info("Starting widget capture file test");

            // Initialize services
            await _initializeTest(logger);

            // Clear the last hash for albums to force refresh
            logger.info("Clearing albums last hash to force refresh");
            await AlbumHomeWidgetService.instance.setAlbumsLastHash("");

            // Force trigger favorite albums refresh
            logger.info("Triggering favorite albums widget refresh");
            await _triggerFavoriteAlbumsRefresh(logger);

            // Wait for captureFile operations to complete
            logger.info("Waiting for widget capture operations to complete");
            await _waitForWidgetCaptureComplete(logger);

            // Analyze saved widget images
            logger.info("Analyzing saved widget images");
            final testResults = await _analyzeWidgetImages(logger);

            // Report results
            _reportResults(testResults, logger);

            // Assert that all images are 1024px
            expect(
              testResults.failedFiles.isEmpty,
              true,
              reason: "All widget images should be 1024px. "
                  "Failed files: ${testResults.failedFiles.map((f) => "${f.fileName}: ${f.width}x${f.height}").join(", ")}",
            );

            logger.info("Widget capture file test completed successfully");
          },
          (error, stack) {
            logger.severe("Test failed with error", error, stack);
            rethrow;
          },
        );
      },
    );
  });
}

/// Initialize the test environment
Future<void> _initializeTest(Logger logger) async {
  try {
    logger.info("Initializing test environment");

    // Initialize SharedPreferences
    final prefs = await SharedPreferences.getInstance();

    // Initialize Dio instances
    final enteDio = Dio();
    final nonEnteDio = Dio();

    // Initialize PackageInfo
    final packageInfo = await PackageInfo.fromPlatform();

    // Initialize ServiceLocator with all required dependencies
    ServiceLocator.instance.init(prefs, enteDio, nonEnteDio, packageInfo);
    logger.info("ServiceLocator initialized");

    // Set up home widget app group for iOS
    await HomeWidgetService.instance.setAppGroup();
    logger.info("Home widget app group configured");

    logger.info("Test initialization complete");
  } catch (e, stackTrace) {
    logger.severe("Failed to initialize test", e, stackTrace);
    rethrow;
  }
}

/// Trigger favorite albums refresh
Future<void> _triggerFavoriteAlbumsRefresh(Logger logger) async {
  try {
    // Clear any existing widget data
    await AlbumHomeWidgetService.instance.clearWidget();
    logger.info("Cleared existing widget data");

    // Mark selection as changed to force re-computation
    await AlbumHomeWidgetService.instance.setSelectionChange(true);
    logger.info("Marked selection as changed");

    // Initialize album home widget which will trigger refresh
    await AlbumHomeWidgetService.instance.initAlbumHomeWidget(false);
    logger.info("Album home widget initialized and refresh triggered");
  } catch (e, stackTrace) {
    logger.severe("Failed to trigger favorite albums refresh", e, stackTrace);
    rethrow;
  }
}

/// Wait for widget capture operations to complete
Future<void> _waitForWidgetCaptureComplete(Logger logger) async {
  const maxAttempts = 30; // 30 seconds max wait
  const checkInterval = Duration(seconds: 1);
  int attempts = 0;

  logger.info("Waiting for widget capture to complete");

  while (attempts < maxAttempts) {
    final status = AlbumHomeWidgetService.instance.getAlbumsStatus();
    logger.info("Widget status: $status (attempt ${attempts + 1}/$maxAttempts)");

    // Check if widget has been synced
    if (status == WidgetStatus.syncedAll ||
        status == WidgetStatus.syncedPartially ||
        status == WidgetStatus.syncedEmpty) {
      logger.info("Widget capture completed with status: $status");

      // Wait additional time to ensure all files are written
      await Future.delayed(const Duration(seconds: 2));
      return;
    }

    await Future.delayed(checkInterval);
    attempts++;
  }

  logger.warning("Widget capture did not complete within timeout");
}

/// Analyze all saved widget images and verify dimensions
Future<WidgetImageTestResults> _analyzeWidgetImages(Logger logger) async {
  final failedFiles = <FailedImageInfo>[];
  final passedFiles = <String>[];
  int totalFiles = 0;

  try {
    // Get widget storage directory
    final widgetDirectory = await _getWidgetStorageDirectory();
    final widgetPath =
        '$widgetDirectory/${HomeWidgetService.WIDGET_DIRECTORY}';
    final widgetDir = Directory(widgetPath);

    logger.info("Analyzing images in: $widgetPath");

    if (!await widgetDir.exists()) {
      logger.warning("Widget directory does not exist: $widgetPath");
      return WidgetImageTestResults(
        failedFiles: [],
        passedFiles: [],
        totalFiles: 0,
      );
    }

    // Get all PNG files in the widget directory
    final files = await widgetDir
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.png'))
        .cast<File>()
        .toList();

    totalFiles = files.length;
    logger.info("Found $totalFiles widget image files to analyze");

    for (final file in files) {
      final fileName = file.path.split('/').last;
      logger.info("Analyzing file: $fileName");

      try {
        // Read and decode the image
        final imageBytes = await file.readAsBytes();
        final image = img.decodeImage(imageBytes);

        if (image == null) {
          logger.warning("Failed to decode image: $fileName");
          failedFiles.add(FailedImageInfo(
            fileName: fileName,
            width: 0,
            height: 0,
            error: "Failed to decode image",
          ));
          continue;
        }

        final width = image.width;
        final height = image.height;

        logger.info("Image dimensions: $fileName - ${width}x$height");

        // Check if image is 1024px (expecting square images)
        const expectedSize = 1024;
        if (width == expectedSize && height == expectedSize) {
          passedFiles.add(fileName);
          logger.info("✓ PASS: $fileName (${width}x$height)");
        } else {
          failedFiles.add(FailedImageInfo(
            fileName: fileName,
            width: width,
            height: height,
            error: null,
          ));
          logger.warning("✗ FAIL: $fileName - Expected ${expectedSize}x$expectedSize, got ${width}x$height");
        }
      } catch (e, stackTrace) {
        logger.severe("Error analyzing file: $fileName", e, stackTrace);
        failedFiles.add(FailedImageInfo(
          fileName: fileName,
          width: 0,
          height: 0,
          error: e.toString(),
        ));
      }
    }
  } catch (e, stackTrace) {
    logger.severe("Error analyzing widget images", e, stackTrace);
    rethrow;
  }

  return WidgetImageTestResults(
    failedFiles: failedFiles,
    passedFiles: passedFiles,
    totalFiles: totalFiles,
  );
}

/// Get widget storage directory based on platform
Future<String> _getWidgetStorageDirectory() async {
  if (Platform.isIOS) {
    final PathProviderFoundation provider = PathProviderFoundation();
    return (await provider.getContainerPath(
      appGroupIdentifier: iOSGroupIDMemory,
    ))!;
  } else {
    return (await getApplicationSupportDirectory()).path;
  }
}

/// Report test results
void _reportResults(WidgetImageTestResults results, Logger logger) {
  logger.info("\n" + "=" * 80);
  logger.info("WIDGET CAPTURE FILE TEST RESULTS");
  logger.info("=" * 80);
  logger.info("Total files analyzed: ${results.totalFiles}");
  logger.info("Passed files: ${results.passedFiles.length}");
  logger.info("Failed files: ${results.failedFiles.length}");
  logger.info("=" * 80);

  if (results.passedFiles.isNotEmpty) {
    logger.info("\n✓ PASSED FILES (1024x1024):");
    for (final fileName in results.passedFiles) {
      logger.info("  ✓ $fileName");
    }
  }

  if (results.failedFiles.isNotEmpty) {
    logger.info("\n✗ FAILED FILES:");
    for (final failedFile in results.failedFiles) {
      if (failedFile.error != null) {
        logger.warning(
          "  ✗ ${failedFile.fileName} - Error: ${failedFile.error}",
        );
      } else {
        logger.warning(
          "  ✗ ${failedFile.fileName} - Dimensions: ${failedFile.width}x${failedFile.height} (expected 1024x1024)",
        );
      }
    }
  }

  logger.info("=" * 80 + "\n");
}

/// Data class to hold test results
class WidgetImageTestResults {
  final List<FailedImageInfo> failedFiles;
  final List<String> passedFiles;
  final int totalFiles;

  WidgetImageTestResults({
    required this.failedFiles,
    required this.passedFiles,
    required this.totalFiles,
  });
}

/// Data class to hold information about failed images
class FailedImageInfo {
  final String fileName;
  final int width;
  final int height;
  final String? error;

  FailedImageInfo({
    required this.fileName,
    required this.width,
    required this.height,
    this.error,
  });
}
