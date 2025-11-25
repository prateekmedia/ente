import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

/// Service for iOS iCloud backup operations.
/// Uses native iOS APIs via platform channel to access iCloud Documents.
class ICloudBackupService {
  ICloudBackupService._();

  static final ICloudBackupService instance = ICloudBackupService._();
  final _logger = Logger('ICloudBackupService');

  static const _channel = MethodChannel('io.ente.auth/icloud_backup');

  /// Check if iCloud is available on this device
  Future<bool> isICloudAvailable() async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isICloudAvailable');
      return result ?? false;
    } on PlatformException catch (e) {
      _logger.warning('Failed to check iCloud availability: ${e.message}');
      return false;
    }
  }

  /// Get the path to iCloud Documents directory
  Future<String?> getICloudDocumentsPath() async {
    if (!Platform.isIOS) return null;

    try {
      final result =
          await _channel.invokeMethod<String>('getICloudDocumentsPath');
      return result;
    } on PlatformException catch (e) {
      _logger.warning('Failed to get iCloud documents path: ${e.message}');
      return null;
    }
  }

  /// Write content to a file in iCloud
  Future<bool> writeFile(String path, String content) async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('writeFile', {
        'path': path,
        'content': content,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _logger.severe('Failed to write file to iCloud: ${e.message}');
      return false;
    }
  }

  /// Read content from a file in iCloud
  Future<String?> readFile(String path) async {
    if (!Platform.isIOS) return null;

    try {
      final result = await _channel.invokeMethod<String>('readFile', {
        'path': path,
      });
      return result;
    } on PlatformException catch (e) {
      _logger.warning('Failed to read file from iCloud: ${e.message}');
      return null;
    }
  }

  /// Delete a file from iCloud
  Future<bool> deleteFile(String path) async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('deleteFile', {
        'path': path,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _logger.warning('Failed to delete file from iCloud: ${e.message}');
      return false;
    }
  }

  /// List files in an iCloud directory
  Future<List<ICloudFileInfo>> listFiles(String path) async {
    if (!Platform.isIOS) return [];

    try {
      final result = await _channel.invokeMethod<List>('listFiles', {
        'path': path,
      });

      if (result == null) return [];

      return result.map((item) {
        final map = Map<String, dynamic>.from(item as Map);
        return ICloudFileInfo(
          name: map['name'] as String,
          path: map['path'] as String,
          creationDate: DateTime.fromMillisecondsSinceEpoch(
            ((map['creationDate'] as num) * 1000).toInt(),
          ),
        );
      }).toList();
    } on PlatformException catch (e) {
      _logger.warning('Failed to list iCloud files: ${e.message}');
      return [];
    }
  }

  /// Create a directory in iCloud
  Future<bool> createDirectory(String path) async {
    if (!Platform.isIOS) return false;

    try {
      final result = await _channel.invokeMethod<bool>('createDirectory', {
        'path': path,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      _logger.warning('Failed to create iCloud directory: ${e.message}');
      return false;
    }
  }
}

class ICloudFileInfo {
  final String name;
  final String path;
  final DateTime creationDate;

  ICloudFileInfo({
    required this.name,
    required this.path,
    required this.creationDate,
  });
}
