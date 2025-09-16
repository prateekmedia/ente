import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:fluttertoast/fluttertoast.dart";
import "package:logging/logging.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/stream_switched_event.dart";
import "package:photos/events/use_media_kit_for_video.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/preview/playlist_data.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/video_preview_service.dart";
import "package:photos/theme/colors.dart";
import "package:photos/ui/common/loading_widget.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/file/video_widget_media_kit.dart";
import "package:photos/services/airplay_service.dart";
import "package:photos/ui/viewer/file/video_widget_native.dart";
import "package:photos/utils/standalone/data.dart";

class VideoWidget extends StatefulWidget {
  final EnteFile file;
  final String? tagPrefix;
  final Function(bool)? playbackCallback;
  final Function({required int memoryDuration})? onFinalFileLoad;
  final bool isFromMemories;

  const VideoWidget(
    this.file, {
    this.tagPrefix,
    this.playbackCallback,
    this.onFinalFileLoad,
    this.isFromMemories = false,
    super.key,
  });

  @override
  State<VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> {
  final _logger = Logger("VideoWidget");
  bool useNativeVideoPlayer = true;
  late final StreamSubscription<UseMediaKitForVideo>
      useMediaKitForVideoSubscription;
  late bool selectPreviewForPlay = widget.file.localID == null;
  PlaylistData? playlistData;
  final nativePlayerKey = GlobalKey();
  final mediaKitKey = GlobalKey();

  bool isPreviewLoadable = false;

  @override
  void initState() {
    super.initState();
    useMediaKitForVideoSubscription =
        Bus.instance.on<UseMediaKitForVideo>().listen((event) {
      _logger.info("Switching to MediaKit for video playback");
      setState(() {
        useNativeVideoPlayer = false;
      });
    });

    if (widget.file.isUploaded) {
      _initializePreviewState();
    }
  }

  Future<void> _initializePreviewState() async {
    // Ensure previewIds are loaded from database first
    await fileDataService.ensurePreviewIdsLoaded();

    if (!mounted) return;

    // Check if preview exists in previewIds
    isPreviewLoadable =
        fileDataService.previewIds.containsKey(widget.file.uploadedFileID);

    // For shared videos, always try to load preview
    if (!widget.file.isOwner) {
      isPreviewLoadable = true;
    }

    if (mounted) {
      setState(() {});
      _checkForPreview();
    }
  }

  @override
  void dispose() {
    useMediaKitForVideoSubscription.cancel();
    super.dispose();
  }

  Future<void> _checkForPreview() async {
    if (!widget.file.isOwner) {
      final bool isStreamable =
          await VideoPreviewService.instance.isSharedFileStreamble(widget.file);
      if (!isStreamable && mounted) {
        isPreviewLoadable = false;
        setState(() {});
      }
    }
    if (!isPreviewLoadable) {
      return;
    }
    widget.playbackCallback?.call(false);
    final data = await VideoPreviewService.instance
        .getPlaylist(widget.file)
        .onError((error, stackTrace) {
      if (!mounted) return;
      _logger.warning("Failed to download preview video", error, stackTrace);
      Fluttertoast.showToast(msg: "Failed to download preview!");
      return null;
    });
    if (!mounted) return;
    if (data != null) {
      if (flagService.internalUser &&
          data.size != null &&
          widget.file.fileSize != null) {
        final size = formatBytes(widget.file.fileSize!);
        showToast(
          context,
          gravity: ToastGravity.TOP,
          "[i] Preview OG Size ($size), previewSize: ${formatBytes(data.size!)}",
        );
      }
      playlistData = data;
    } else {
      isPreviewLoadable = false;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Check if AirPlay is active
    final bool isAirPlaying =
        Platform.isIOS ? AirPlayService.instance.isAirPlaying : false;

    // If AirPlay is active, always use original (not stream) as local m3u8 doesn't work with AirPlay
    final playPreview =
        isPreviewLoadable && selectPreviewForPlay && !isAirPlaying;

    if (playPreview && playlistData == null) {
      return Center(
        child: Container(
          width: 48,
          height: 48,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: Colors.black.withValues(alpha: 0.3),
            border: Border.all(
              color: strokeFaintDark,
              width: 1,
            ),
          ),
          child: const EnteLoadingWidget(
            size: 32,
            color: fillBaseDark,
            padding: 0,
          ),
        ),
      );
    }

    // On iOS, listen to AirPlay state and use native player when AirPlay is active
    if (Platform.isIOS) {
      return StreamBuilder<bool>(
        stream: AirPlayService.instance.isAirPlayingStream,
        initialData: AirPlayService.instance.isAirPlaying,
        builder: (context, snapshot) {
          final isAirPlaying = snapshot.data ?? false;
          // Always use native player when AirPlay is active
          if (isAirPlaying) {
            return _buildNativePlayer(playPreview, playlistData);
          }
          // Otherwise use default behavior
          if (useNativeVideoPlayer && !playPreview) {
            return _buildNativePlayer(playPreview, playlistData);
          } else {
            return _buildMediaKitPlayer(playPreview, playlistData);
          }
        },
      );
    }

    // On Android, use native for original and MediaKit for stream
    if ((useNativeVideoPlayer && !playPreview) ||
        (playPreview && Platform.isAndroid)) {
      return _buildNativePlayer(playPreview, playlistData);
    }
    return _buildMediaKitPlayer(playPreview, playlistData);
  }

  Widget _buildNativePlayer(bool playPreview, PlaylistData? playlistData) {
    return VideoWidgetNative(
      widget.file,
      key: nativePlayerKey,
      tagPrefix: widget.tagPrefix,
      playbackCallback: widget.playbackCallback,
      playlistData: playlistData,
      selectedPreview: playPreview,
      isFromMemories: widget.isFromMemories,
      onStreamChange: () {
        setState(() {
          selectPreviewForPlay = !selectPreviewForPlay;
          // If switching to preview but preview not loaded, load it now
          if (selectPreviewForPlay && this.playlistData == null) {
            _checkForPreview();
          }
          Bus.instance.fire(
            StreamSwitchedEvent(
              selectPreviewForPlay,
              Platform.isAndroid && useNativeVideoPlayer
                  ? PlayerType.nativeVideoPlayer
                  : PlayerType.mediaKit,
            ),
          );
        });
      },
      onFinalFileLoad: widget.onFinalFileLoad,
    );
  }

  Widget _buildMediaKitPlayer(bool playPreview, PlaylistData? playlistData) {
    return VideoWidgetMediaKit(
      widget.file,
      key: mediaKitKey,
      tagPrefix: widget.tagPrefix,
      playbackCallback: widget.playbackCallback,
      preview: playlistData?.preview,
      selectedPreview: playPreview,
      isFromMemories: widget.isFromMemories,
      onStreamChange: () {
        setState(() {
          selectPreviewForPlay = !selectPreviewForPlay;
          // If switching to preview but preview not loaded, load it now
          if (selectPreviewForPlay && this.playlistData == null) {
            _checkForPreview();
          }
          Bus.instance.fire(
            StreamSwitchedEvent(
              selectPreviewForPlay,
              Platform.isAndroid
                  ? PlayerType.nativeVideoPlayer
                  : PlayerType.mediaKit,
            ),
          );
        });
      },
      onFinalFileLoad: widget.onFinalFileLoad,
    );
  }
}
