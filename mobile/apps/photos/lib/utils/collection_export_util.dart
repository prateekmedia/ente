import "dart:io";

import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:path/path.dart" as path;
import "package:path_provider/path_provider.dart";
import "package:photos/db/files_db.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/utils/file_util.dart";
import "package:share_plus/share_plus.dart";

final _logger = Logger("CollectionExportUtil");

/// Exports a collection with breadcrumb-based folder structure
///
/// Creates a temporary directory with nested folders based on album hierarchy,
/// copies files into the appropriate folders, and shares the result
Future<void> exportCollectionWithStructure(
  BuildContext context,
  Collection collection, {
  bool includeSubAlbums = false,
  Function(int completed, int total)? onProgress,
}) async {
  final startTime = DateTime.now();

  _logger.info(
    "Export started: collection_id=${collection.id}, "
    "include_sub_albums=$includeSubAlbums",
  );

  try {
    final treeService = CollectionsTreeService.instance;

    // Get all collections to export
    final List<Collection> collectionsToExport = [collection];
    if (includeSubAlbums) {
      final descendants = treeService.getDescendants(collection.id);
      collectionsToExport.addAll(descendants);

      _logger.info(
        "Export includes descendants: count=${descendants.length}",
      );
    }

    // Build file list with breadcrumb paths
    final Map<EnteFile, List<String>> filePathsMap = {};
    for (final coll in collectionsToExport) {
      final fileResult = await FilesDB.instance.getFilesInCollection(
        coll.id,
        0,
        DateTime.now().microsecondsSinceEpoch,
      );
      final files = fileResult.files;
      final breadcrumbs = treeService.getBreadcrumbs(coll.id);

      for (final file in files) {
        filePathsMap[file] = breadcrumbs;
      }
    }

    if (filePathsMap.isEmpty) {
      _logger.warning("No files to export");
      return;
    }

    // Create temp directory with folder structure
    final tempDir = await getTemporaryDirectory();
    final exportRootPath = path.join(
      tempDir.path,
      "ente_export_${DateTime.now().millisecondsSinceEpoch}",
    );
    final exportRoot = Directory(exportRootPath);
    await exportRoot.create(recursive: true);

    // Copy files to appropriate folders
    int completedCount = 0;
    final totalCount = filePathsMap.length;

    for (final entry in filePathsMap.entries) {
      final file = entry.key;
      final breadcrumbs = entry.value;

      // Build folder path from breadcrumbs
      final folderPath = path.joinAll([exportRootPath, ...breadcrumbs]);
      final folder = Directory(folderPath);
      await folder.create(recursive: true);

      // Get file from server or local cache
      final File? sourceFile = await getFile(file, isOrigin: true);
      if (sourceFile == null) {
        _logger.warning("Could not download file: ${file.title}");
        continue;
      }

      // Copy file to destination
      final destPath =
          path.join(folderPath, file.title ?? "file_${file.uploadedFileID}");
      await sourceFile.copy(destPath);

      completedCount++;
      onProgress?.call(completedCount, totalCount);
    }

    // Share the exported directory
    await _shareExportedDirectory(context, exportRoot);

    // Cleanup temp directory after sharing
    try {
      await exportRoot.delete(recursive: true);
    } catch (e) {
      _logger.warning("Failed to cleanup temp directory: $e");
    }

    final duration = DateTime.now().difference(startTime);
    _logger.info(
      "Export completed: total_files=$totalCount, "
      "total_collections=${collectionsToExport.length}, "
      "duration_ms=${duration.inMilliseconds}",
    );
  } catch (e, s) {
    final duration = DateTime.now().difference(startTime);
    _logger.severe(
      "Export failed after ${duration.inMilliseconds}ms",
      e,
      s,
    );
    rethrow;
  }
}

/// Shares the exported directory
///
/// On mobile platforms, converts directory to list of files and shares via system share sheet
Future<void> _shareExportedDirectory(
  BuildContext context,
  Directory exportRoot,
) async {
  // Get all files in the directory (recursively)
  final List<XFile> filesToShare = [];
  await for (final entity in exportRoot.list(recursive: true)) {
    if (entity is File) {
      filesToShare.add(XFile(entity.path));
    }
  }

  if (filesToShare.isEmpty) {
    _logger.warning("No files to share");
    return;
  }

  // Share using system share sheet
  await SharePlus.instance.share(
    ShareParams(
      files: filesToShare,
      subject: "Exported from Ente Photos",
    ),
  );
}
