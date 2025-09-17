import 'dart:io';
import 'dart:typed_data';

import 'package:computer/computer.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:photos/core/cache/thumbnail_in_memory_cache.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/utils/file_util.dart';
import 'package:photos/utils/isolate/widget_image_operations.dart';
import "package:photos/utils/thumbnail_util.dart";

final _logger = Logger("WidgetImageUtil");

/// Smart widget image fetcher that checks multiple cache levels
/// and processes images in isolate to avoid UI blocking

Future<Uint8List?> getWidgetImage(
  EnteFile file, {
  double maxSize = 2048.0, // Enhanced size for better quality
  int quality = WidgetImageOperations.kDefaultQuality,
}) async {
  try {
    // Priority order:
    // 1. Check in-memory cache for high-res version
    final memCached = ThumbnailInMemoryLruCache.get(file, maxSize.toInt());
    if (memCached != null && memCached.isNotEmpty) {
      return memCached;
    }

    // 2. Check if high-res cached version exists (from main app viewing)
    final cachedImage = await _getHighResCachedImage(file, maxSize.toInt());
    if (cachedImage != null) {
      // Store in memory cache for quick access
      ThumbnailInMemoryLruCache.put(file, cachedImage, maxSize.toInt());
      return cachedImage;
    }

    // 3. For local files: Get original and process in isolate
    if (!file.isRemoteFile) {
      final processedImage = await _processLocalFile(file, maxSize, quality);
      if (processedImage != null) {
        // Cache the processed image
        await WidgetImageCache.cacheWidgetImage(
            file, processedImage, maxSize.toInt());
        ThumbnailInMemoryLruCache.put(file, processedImage, maxSize.toInt());
        return processedImage;
      }
    }

    // 4. For remote files: Try existing thumbnail first
    final thumbnail = await getThumbnail(file);
    if (thumbnail != null && thumbnail.isNotEmpty) {
      // Check if thumbnail quality is acceptable
      if (_isThumbnailQualityAcceptable(thumbnail, maxSize.toInt())) {
        return thumbnail;
      }

      // Try to enhance the thumbnail in isolate
      final enhanced = await _enhanceThumbnail(thumbnail, maxSize, quality);
      if (enhanced != null) {
        await WidgetImageCache.cacheWidgetImage(
            file, enhanced, maxSize.toInt());
        ThumbnailInMemoryLruCache.put(file, enhanced, maxSize.toInt());
        return enhanced;
      }

      // Use original thumbnail as fallback
      return thumbnail;
    }

    // 5. Last resort for remote files: Download original (expensive!)
    if (file.isRemoteFile) {
      final originalFile = await getFile(file, isOrigin: true);
      if (originalFile != null) {
        final processedImage = await _processFileInIsolate(
          originalFile.path,
          null,
          maxSize,
          quality,
        );

        // Clean up the downloaded file if it's remote
        if (file.isRemoteFile && originalFile.existsSync()) {
          await originalFile.delete();
        }

        if (processedImage != null) {
          await WidgetImageCache.cacheWidgetImage(
              file, processedImage, maxSize.toInt());
          ThumbnailInMemoryLruCache.put(file, processedImage, maxSize.toInt());
          return processedImage;
        }
      }
    }

    _logger.warning("Failed to get widget image for ${file.displayName}");
    return null;
  } catch (e) {
    _logger.severe("Error getting widget image for ${file.displayName}", e);
    return null;
  }
}

Future<Uint8List?> _getHighResCachedImage(EnteFile file, int minSize) async {
  try {
    // Check widget-specific cache first
    final widgetCached = await WidgetImageCache.getCachedImage(file, minSize);
    if (widgetCached != null) {
      return widgetCached;
    }

    // Check DefaultCacheManager (images viewed in main app)
    if (file.isRemoteFile && file.uploadedFileID != null) {
      final cacheManager = DefaultCacheManager();
      final fileInfo = await cacheManager.getFileFromCache(
        'file_${file.uploadedFileID}',
      );

      if (fileInfo != null && fileInfo.file.existsSync()) {
        final bytes = await fileInfo.file.readAsBytes();
        // Verify the image meets minimum size requirements
        if (_isThumbnailQualityAcceptable(bytes, minSize)) {
          return bytes;
        }
      }
    }

    return null;
  } catch (e) {
    _logger.warning("Error checking cached image", e);
    return null;
  }
}

Future<Uint8List?> _processLocalFile(
  EnteFile file,
  double maxSize,
  int quality,
) async {
  try {
    // Get the local asset
    final AssetEntity? asset = await file.getAsset;
    if (asset == null || !(await asset.exists)) {
      return null;
    }

    // Get the file path for the asset
    final File? originFile = await asset.originFile;
    if (originFile == null || !originFile.existsSync()) {
      // Fallback to getting file bytes directly
      final bytes = await asset.originBytes;
      if (bytes != null) {
        return _processFileInIsolate(null, bytes, maxSize, quality);
      }
      return null;
    }

    // Process the file in isolate with EXIF handling
    return _processFileInIsolate(originFile.path, null, maxSize, quality);
  } catch (e) {
    _logger.warning("Error processing local file", e);
    return null;
  }
}

Future<Uint8List?> _processFileInIsolate(
  String? imagePath,
  Uint8List? imageBytes,
  double maxSize,
  int quality,
) async {
  try {
    _logger.info(
        "Processing image in isolate: ${imagePath != null ? 'from path' : 'from bytes'}, maxSize: $maxSize, quality: $quality");

    final params = <String, dynamic>{
      if (imagePath != null) 'imagePath': imagePath,
      if (imageBytes != null) 'imageBytes': imageBytes,
      'maxSize': maxSize.toInt(),
      'quality': quality,
    };

    // Process in isolate to avoid UI blocking
    final result = await Computer.shared().compute(
      WidgetImageOperations.processWidgetImage,
      param: params,
    );

    if (result != null) {
      _logger.info(
          "Successfully processed image in isolate, result size: ${result.length} bytes");
    } else {
      _logger.warning(
          "Image processing returned null - check isolate logs for details");
    }

    return result;
  } catch (e, stackTrace) {
    _logger.severe("Error processing image in isolate", e, stackTrace);
    return null;
  }
}

Future<Uint8List?> _enhanceThumbnail(
  Uint8List thumbnail,
  double maxSize,
  int quality,
) async {
  // Only enhance if the thumbnail is significantly smaller than target
  if (thumbnail.length > 50000) {
    // ~50KB suggests reasonable quality already
    return null;
  }

  return _processFileInIsolate(null, thumbnail, maxSize, quality);
}

bool _isThumbnailQualityAcceptable(Uint8List imageData, int minSize) {
  // Simple heuristic: larger file size usually means higher quality
  // For a 512x512 JPEG at quality 85, expect ~50-100KB
  // For a 1024x1024 JPEG at quality 85, expect ~150-300KB

  if (minSize <= 512) {
    return imageData.length > 30000; // ~30KB minimum for 512px
  } else if (minSize <= 768) {
    return imageData.length > 75000; // ~75KB minimum for 768px
  } else {
    return imageData.length > 100000; // ~100KB minimum for 1024px+
  }
}

/// Batch process multiple widget images in parallel isolates
Future<void> refreshWidgetImages(List<EnteFile> files) async {
  _logger.info("Refreshing ${files.length} widget images");

  final futures = files.map(
    (file) => getWidgetImage(file).catchError((e) {
      _logger.warning(
        "Failed to refresh widget image for ${file.displayName}",
        e,
      );
      return null;
    }),
  );

  await Future.wait(futures, eagerError: false);
  _logger.info("Completed refreshing widget images");
}

/// Widget Image Cache Manager
class WidgetImageCache {
  static const String _cacheDirectory = 'widget_images_cache';
  static const int _maxCacheSize = 100 * 1024 * 1024; // 100MB

  /// Get cached widget image if it meets minimum size requirement
  static Future<Uint8List?> getCachedImage(EnteFile file, int minSize) async {
    try {
      final cacheDir = await _getCacheDirectory();
      final cacheFile =
          File('${cacheDir.path}/${file.generatedID}_${minSize}px.jpg');

      if (await cacheFile.exists()) {
        final bytes = await cacheFile.readAsBytes();
        if (_isThumbnailQualityAcceptable(bytes, minSize)) {
          return bytes;
        }
      }
    } catch (e) {
      _logger.warning("Error reading cached widget image", e);
    }
    return null;
  }

  /// Cache processed widget image for future use
  static Future<void> cacheWidgetImage(
      EnteFile file, Uint8List data, int size) async {
    try {
      final cacheDir = await _getCacheDirectory();
      final cacheFile =
          File('${cacheDir.path}/${file.generatedID}_${size}px.jpg');

      // Ensure directory exists
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }

      // Write image to cache
      await cacheFile.writeAsBytes(data);

      // Manage cache size
      await _manageCacheSize(cacheDir);
    } catch (e) {
      _logger.warning("Error caching widget image", e);
    }
  }

  /// Clear all cached widget images
  static Future<void> clearCache() async {
    try {
      final cacheDir = await _getCacheDirectory();
      if (await cacheDir.exists()) {
        await cacheDir.delete(recursive: true);
      }
    } catch (e) {
      _logger.warning("Error clearing widget image cache", e);
    }
  }

  static Future<Directory> _getCacheDirectory() async {
    final tempDir = await getTemporaryDirectory();
    return Directory('${tempDir.path}/$_cacheDirectory');
  }

  static Future<void> _manageCacheSize(Directory cacheDir) async {
    try {
      final files = await cacheDir
          .list()
          .where((entity) => entity is File)
          .cast<File>()
          .toList();

      // Calculate total size
      int totalSize = 0;
      final fileStats = <File, FileStat>{};

      for (final file in files) {
        final stat = await file.stat();
        fileStats[file] = stat;
        totalSize += stat.size;
      }

      // If under limit, nothing to do
      if (totalSize <= _maxCacheSize) {
        return;
      }

      // Sort by last accessed time (oldest first)
      final sortedFiles = files.toList()
        ..sort((a, b) {
          final statA = fileStats[a]!;
          final statB = fileStats[b]!;
          return statA.accessed.compareTo(statB.accessed);
        });

      // Delete oldest files until under limit
      for (final file in sortedFiles) {
        if (totalSize <= _maxCacheSize) {
          break;
        }

        final stat = fileStats[file]!;
        totalSize -= stat.size;
        await file.delete();
      }
    } catch (e) {
      _logger.warning("Error managing cache size", e);
    }
  }

  static bool _isThumbnailQualityAcceptable(Uint8List imageData, int minSize) {
    if (minSize <= 512) {
      return imageData.length > 30000;
    } else if (minSize <= 768) {
      return imageData.length > 75000;
    } else {
      return imageData.length > 100000;
    }
  }
}
