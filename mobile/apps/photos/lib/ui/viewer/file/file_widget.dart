import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/file/file_type.dart';
import 'package:photos/service_locator.dart';
import "package:photos/ui/viewer/file/video_widget.dart";
import "package:photos/ui/viewer/file/zoomable_live_image_new.dart";

class FileWidget extends StatefulWidget {
  final EnteFile file;
  final String tagPrefix;
  final Function(bool)? shouldDisableScroll;
  final Function(bool)? playbackCallback;
  final BoxDecoration? backgroundDecoration;
  final bool? autoPlay;
  final bool? isFromMemories;
  final Function({required int memoryDuration})? onFinalFileLoad;

  const FileWidget(
    this.file, {
    this.autoPlay,
    this.shouldDisableScroll,
    this.playbackCallback,
    required this.tagPrefix,
    this.backgroundDecoration,
    this.isFromMemories = false,
    this.onFinalFileLoad,
    super.key,
  });

  @override
  State<FileWidget> createState() => _FileWidgetState();
}

class _FileWidgetState extends State<FileWidget> {
  @override
  void initState() {
    super.initState();
    _displayOnExternalScreen();
  }

  @override
  void didUpdateWidget(FileWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file) {
      _displayOnExternalScreen();
    }
  }

  void _displayOnExternalScreen() {
    // Early return if external display feature is not enabled
    if (!featureFlagService.isExternalDisplayEnabled) {
      return;
    }
    
    final externalDisplay = externalDisplayService;
    if (!externalDisplay.isSupported || !externalDisplay.isConnected) {
      return;
    }

    // Display image on external display
    if (widget.file.fileType == FileType.image || widget.file.fileType == FileType.livePhoto) {
      externalDisplay.displayImage(widget.file).catchError((e) {
        Logger('FileWidget').warning('Failed to display image on external display: $e');
        return false;
      });
    } else if (widget.file.fileType == FileType.video) {
      // For videos, we'll handle external display in the VideoWidget itself
      // as it needs to coordinate with playback controls
    }
  }

  @override
  Widget build(BuildContext context) {
    // Specify key to ensure that the widget is rebuilt when the file changes
    // Before changing this, ensure that file deletes are handled properly

    final String fileKey =
        "file_genID_${widget.file.generatedID}___file_id_${widget.file.uploadedFileID}";
    if (widget.file.fileType == FileType.livePhoto ||
        widget.file.fileType == FileType.image) {
      return ZoomableLiveImageNew(
        widget.file,
        shouldDisableScroll: widget.shouldDisableScroll,
        tagPrefix: widget.tagPrefix,
        backgroundDecoration: widget.backgroundDecoration,
        isFromMemories: widget.isFromMemories ?? false,
        key: widget.key ?? ValueKey(fileKey),
        onFinalFileLoad: widget.onFinalFileLoad,
      );
    } else if (widget.file.fileType == FileType.video) {
      // use old video widget on iOS simulator as the new one crashes while
      // playing certain videos on iOS simulator
      // if (kDebugMode && Platform.isIOS) {
      //   return VideoWidgetChewie(
      //     file,
      //     tagPrefix: tagPrefix,
      //     playbackCallback: playbackCallback,
      //   );
      // }

      return VideoWidget(
        widget.file,
        tagPrefix: widget.tagPrefix,
        playbackCallback: widget.playbackCallback,
        onFinalFileLoad: widget.onFinalFileLoad,
        isFromMemories: widget.isFromMemories ?? false,
        key: widget.key ?? ValueKey(fileKey),
      );
    } else {
      Logger('FileWidget').severe('unsupported file type ${widget.file.fileType}');
      return const Icon(Icons.error);
    }
  }
}
