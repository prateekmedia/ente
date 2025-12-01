import "dart:async";
import "dart:io";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:logging/logging.dart";
import "package:native_video_player/native_video_player.dart";
import "package:photos/core/constants.dart";
import "package:photos/core/event_bus.dart";
import "package:photos/events/file_caption_updated_event.dart";
import "package:photos/events/guest_view_event.dart";
import "package:photos/events/pause_video_event.dart";
import "package:photos/events/seekbar_triggered_event.dart";
import "package:photos/events/stream_switched_event.dart";
import "package:photos/events/use_media_kit_for_video.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/models/file/extensions/file_props.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/preview/playlist_data.dart";
import "package:photos/module/download/task.dart";
import "package:photos/service_locator.dart";
import "package:photos/services/files_service.dart";
import "package:photos/services/wake_lock_service.dart";
import "package:photos/states/detail_page_state.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/actions/file/file_actions.dart";
import "package:photos/ui/common/loading_widget.dart";
import "package:photos/ui/notification/toast.dart";
import "package:photos/ui/viewer/file/native_video_player_controls/play_pause_button.dart";
import "package:photos/ui/viewer/file/native_video_player_controls/seek_bar.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";
import "package:photos/ui/viewer/file/video_controls/double_tap_to_seek.dart";
import "package:photos/ui/viewer/file/video_controls/lock_controls_button.dart";
import "package:photos/ui/viewer/file/video_controls/mute_button.dart";
import "package:photos/ui/viewer/file/video_controls/playback_speed_control.dart";
import "package:photos/ui/viewer/file/video_stream_change.dart";
import "package:photos/utils/dialog_util.dart";
import "package:photos/utils/exif_util.dart";
import "package:photos/utils/file_util.dart";
import "package:photos/utils/standalone/date_time.dart";
import "package:photos/utils/standalone/debouncer.dart";
import "package:screen_brightness/screen_brightness.dart";
import "package:visibility_detector/visibility_detector.dart";
import "package:volume_controller/volume_controller.dart";

class VideoWidgetNative extends StatefulWidget {
  final EnteFile file;
  final String? tagPrefix;
  final FullScreenRequestCallback? playbackCallback;
  final bool isFromMemories;
  final void Function()? onStreamChange;
  final PlaylistData? playlistData;
  final bool selectedPreview;
  final Function({required int memoryDuration})? onFinalFileLoad;

  const VideoWidgetNative(
    this.file, {
    this.tagPrefix,
    this.playbackCallback,
    this.isFromMemories = false,
    required this.onStreamChange,
    super.key,
    this.playlistData,
    this.onFinalFileLoad,
    required this.selectedPreview,
  });

  @override
  State<VideoWidgetNative> createState() => _VideoWidgetNativeState();
}

class _VideoWidgetNativeState extends State<VideoWidgetNative>
    with WidgetsBindingObserver {
  final Logger _logger = Logger("VideoWidgetNative");
  static const verticalMargin = 64.0;
  static const int _seekDuration = 10; // seconds for double-tap seek
  final _progressNotifier = ValueNotifier<double?>(null);
  late StreamSubscription<PauseVideoEvent> pauseVideoSubscription;
  bool _isGuestView = false;
  late final StreamSubscription<GuestViewEvent> _guestViewEventSubscription;
  NativeVideoPlayerController? _controller;
  String? _filePath;
  String? duration;
  double? aspectRatio;
  final _isPlaybackReady = ValueNotifier(false);
  bool _shouldClearCache = false;
  bool _isCompletelyVisible = false;
  final _showControls = ValueNotifier(true);
  final _isSeeking = ValueNotifier(false);
  final _debouncer = Debouncer(
    const Duration(milliseconds: 2000),
  );
  StreamSubscription<PlaybackEvent>? _subscription;
  StreamSubscription<StreamSwitchedEvent>? _streamSwitchedSubscription;
  StreamSubscription<DownloadTask>? downloadTaskSubscription;
  late final StreamSubscription<FileCaptionUpdatedEvent>
      _captionUpdatedSubscription;
  int position = 0;

  // New video player controls state
  double _playbackSpeed = 1.0;
  bool _isMuted = false;
  bool _controlsLocked = false;
  double _brightness = 0.5;
  double _volume = 0.5;
  bool _showBrightnessIndicator = false;
  bool _showVolumeIndicator = false;
  bool _showSeekIndicator = false;
  double _seekPosition = 0;
  bool _isLongPressing = false;
  double _previousSpeed = 1.0;
  Timer? _indicatorTimer;

  @override
  void initState() {
    _logger.info(
      'initState for ${widget.file.generatedID} with tag ${widget.file.tag} and name ${widget.file.displayName}',
    );
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (widget.selectedPreview) {
      loadPreview();
    } else {
      loadOriginal();
    }

    pauseVideoSubscription = Bus.instance.on<PauseVideoEvent>().listen((event) {
      _controller?.pause();
    });
    _guestViewEventSubscription =
        Bus.instance.on<GuestViewEvent>().listen((event) {
      setState(() {
        _isGuestView = event.isGuestView;
      });
    });
    _streamSwitchedSubscription =
        Bus.instance.on<StreamSwitchedEvent>().listen((event) {
      if (event.type != PlayerType.nativeVideoPlayer) return;
      _filePath = null;
      if (event.selectedPreview) {
        loadPreview(update: true);
      } else {
        loadOriginal(update: true);
      }
    });

    _captionUpdatedSubscription =
        Bus.instance.on<FileCaptionUpdatedEvent>().listen((event) {
      if (event.fileGeneratedID == widget.file.generatedID) {
        if (mounted) {
          setState(() {});
        }
      }
    });
    if (widget.file.isUploaded) {
      downloadTaskSubscription = downloadManager
          .watchDownload(
        widget.file.uploadedFileID!,
      )
          .listen((event) {
        _progressNotifier.value = event.progress;
      });
    }

    EnteWakeLockService.instance
        .updateWakeLock(enable: true, wakeLockFor: WakeLockFor.videoPlayback);

    _initializeBrightnessAndVolume();
  }

  Future<void> _initializeBrightnessAndVolume() async {
    try {
      _brightness = await ScreenBrightness.instance.application;
      VolumeController.instance.getVolume().then((value) {
        if (mounted) {
          setState(() {
            _volume = value;
          });
        }
      });
    } catch (e) {
      _logger.warning("Failed to initialize brightness/volume: $e");
    }
  }

  Future<void> setVideoSource() async {
    if (_filePath == null) {
      _logger.info('Stop video player, file path is null');
      await _controller?.stop();
      return;
    }
    final videoSource = VideoSource(
      path: _filePath!,
      type: VideoSourceType.file,
    );
    await _controller?.loadVideo(videoSource);
    await _controller?.play();

    Bus.instance.fire(SeekbarTriggeredEvent(position: 0));
  }

  void loadPreview({bool update = false}) async {
    _setFilePathForNativePlayer(widget.playlistData!.preview.path, update);

    await setVideoSource();
  }

  void loadOriginal({bool update = false}) async {
    if (widget.file.isRemoteFile) {
      _loadNetworkVideo(update);
      _setFileSizeIfNull();
    } else if (widget.file.isSharedMediaToAppSandbox) {
      final localFile = File(getSharedMediaFilePath(widget.file));
      if (localFile.existsSync()) {
        _setFilePathForNativePlayer(localFile.path, update);
      } else if (widget.file.uploadedFileID != null) {
        _loadNetworkVideo(update);
      }
    } else {
      await widget.file.getAsset.then((asset) async {
        if (asset == null || !(await asset.exists)) {
          if (widget.file.uploadedFileID != null) {
            _loadNetworkVideo(update);
          }
        } else {
          // ignore: unawaited_futures
          getFile(widget.file, isOrigin: true).then((file) {
            _setFilePathForNativePlayer(file!.path, update);
            if (Platform.isIOS) {
              _shouldClearCache = true;
            }
          });
        }
      });
    }
    if (update) {
      await setVideoSource();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      if (_controller?.playbackStatus == PlaybackStatus.playing) {
        _controller?.pause();
      }
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _controller?.dispose();
    if (downloadTaskSubscription != null) {
      downloadTaskSubscription!.cancel();
      downloadManager.pause(widget.file.uploadedFileID!).ignore();
    }

    //https://github.com/fluttercandies/flutter_photo_manager/blob/8afba2745ebaac6af8af75de9cbded9157bc2690/README.md#clear-caches
    if (_shouldClearCache) {
      _logger.info("Clearing cache");
      final file = File(_filePath!);

      /// Checking if exists to avoid observed PathNotFoundException. Didn't find
      /// root cause.
      if (file.existsSync()) {
        file.delete().then(
          (value) {
            _logger.info("Cache cleared");
          },
        );
      }
    }
    _streamSwitchedSubscription?.cancel();
    _guestViewEventSubscription.cancel();
    pauseVideoSubscription.cancel();
    removeCallBack(widget.file);
    _progressNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    _isPlaybackReady.dispose();
    _showControls.dispose();
    _isSeeking.removeListener(_seekListener);
    _isSeeking.dispose();
    _debouncer.cancelDebounceTimer();
    _captionUpdatedSubscription.cancel();
    _indicatorTimer?.cancel();
    // Reset brightness to system default
    try {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (e) {
      // Ignore
    }
    EnteWakeLockService.instance
        .updateWakeLock(enable: false, wakeLockFor: WakeLockFor.videoPlayback);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: widget.tagPrefix! + widget.file.tag,
      child: VisibilityDetector(
        key: Key(widget.file.generatedID.toString()),
        onVisibilityChanged: (info) {
          if (info.visibleFraction == 1) {
            setState(() {
              _isCompletelyVisible = true;
            });
          }
        },
        child: GestureDetector(
          onVerticalDragUpdate: _isGuestView
              ? null
              : (d) => {
                    if (d.delta.dy > dragSensitivity)
                      {
                        Navigator.of(context).pop(),
                      }
                    else if (d.delta.dy < (dragSensitivity * -1))
                      {
                        showDetailsSheet(context, widget.file),
                      },
                  },
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 750),
            switchOutCurve: Curves.easeOutExpo,
            switchInCurve: Curves.easeInExpo,
            //Loading two high-res potrait videos together causes one to
            //go blank. So only loading video when it is completely visible.
            child: !_isCompletelyVisible || _filePath == null
                ? _getLoadingWidget()
                : Stack(
                    key: const ValueKey("video_ready"),
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: aspectRatio ?? 1,
                          child: NativeVideoPlayerView(
                            onViewReady: _initializeController,
                          ),
                        ),
                      ),
                      // Main gesture handler
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: widget.isFromMemories
                            ? () {
                                widget.playbackCallback?.call(
                                  false,
                                  FullScreenRequestReason.userInteraction,
                                );
                                _controller?.pause();
                              }
                            : _controlsLocked
                                ? null
                                : _onLongPressStart,
                        onLongPressUp: widget.isFromMemories
                            ? () {
                                widget.playbackCallback?.call(
                                  true,
                                  FullScreenRequestReason.userInteraction,
                                );
                                _controller?.play();
                              }
                            : _controlsLocked
                                ? null
                                : _onLongPressEnd,
                        child: Container(
                          constraints: const BoxConstraints.expand(),
                        ),
                      ),
                      // Double tap to seek overlay
                      if (!widget.isFromMemories && !_controlsLocked)
                        Positioned.fill(
                          child: DoubleTapSeekOverlay(
                            seekDuration: _seekDuration,
                            onSeekForward: _seekForward,
                            onSeekBackward: _seekBackward,
                            showControls: _showControls.value,
                            onSingleTap: () {
                              _showControls.value = !_showControls.value;
                              if (widget.playbackCallback != null) {
                                widget.playbackCallback!(
                                  !_showControls.value,
                                  FullScreenRequestReason.userInteraction,
                                );
                              }
                            },
                          ),
                        ),
                      // Brightness indicator (left side)
                      if (_showBrightnessIndicator)
                        Positioned(
                          left: 40,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildVerticalIndicator(
                              icon: _brightness > 0.66
                                  ? Icons.brightness_high
                                  : _brightness > 0.33
                                      ? Icons.brightness_medium
                                      : Icons.brightness_low,
                              value: _brightness,
                            ),
                          ),
                        ),
                      // Volume indicator (right side)
                      if (_showVolumeIndicator)
                        Positioned(
                          right: 40,
                          top: 0,
                          bottom: 0,
                          child: Center(
                            child: _buildVerticalIndicator(
                              icon: _volume > 0.66
                                  ? Icons.volume_up
                                  : _volume > 0
                                      ? Icons.volume_down
                                      : Icons.volume_off,
                              value: _volume,
                            ),
                          ),
                        ),
                      // Seek indicator
                      if (_showSeekIndicator)
                        Positioned.fill(
                          child: Center(child: _buildSeekIndicator()),
                        ),
                      // Long press fast forward indicator
                      if (_isLongPressing)
                        Positioned.fill(
                          child: Center(child: _buildFastForwardIndicator()),
                        ),
                      // Play/pause button
                      widget.isFromMemories
                          ? const SizedBox.shrink()
                          : Positioned.fill(
                              child: Center(
                                child: ValueListenableBuilder(
                                  builder:
                                      (BuildContext context, bool value, _) {
                                    return value
                                        ? ValueListenableBuilder(
                                            builder: (context, bool value, _) {
                                              return AnimatedOpacity(
                                                duration: const Duration(
                                                  milliseconds: 200,
                                                ),
                                                opacity: value &&
                                                        !_controlsLocked
                                                    ? 1
                                                    : 0,
                                                curve: Curves.easeInOutQuad,
                                                child: IgnorePointer(
                                                  ignoring:
                                                      !value || _controlsLocked,
                                                  child: PlayPauseButton(
                                                    _controller,
                                                  ),
                                                ),
                                              );
                                            },
                                            valueListenable: _showControls,
                                          )
                                        : const SizedBox();
                                  },
                                  valueListenable: _isPlaybackReady,
                                ),
                              ),
                            ),
                      // Top control bar (speed, mute, lock)
                      if (!widget.isFromMemories)
                        ValueListenableBuilder(
                          valueListenable: _showControls,
                          builder: (context, showControls, _) {
                            return AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: showControls ? 1 : 0,
                              child: IgnorePointer(
                                ignoring: !showControls,
                                child: Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: SafeArea(
                                    bottom: false,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.end,
                                        children: [
                                          PlaybackSpeedButton(
                                            currentSpeed: _playbackSpeed,
                                            onSpeedChanged: _setPlaybackSpeed,
                                          ),
                                          const SizedBox(width: 8),
                                          MuteButton(
                                            isMuted: _isMuted,
                                            onToggle: _toggleMute,
                                          ),
                                          const SizedBox(width: 8),
                                          LockControlsButton(
                                            isLocked: _controlsLocked,
                                            onToggle: _toggleLock,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      // Locked controls overlay
                      if (_controlsLocked)
                        LockedControlsOverlay(onUnlock: _toggleLock),
                      // Bottom controls
                      widget.isFromMemories
                          ? const SizedBox.shrink()
                          : Positioned(
                              bottom: verticalMargin,
                              right: 0,
                              left: 0,
                              child: SafeArea(
                                top: false,
                                left: false,
                                right: false,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: widget.isFromMemories ? 32 : 0,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      ValueListenableBuilder(
                                        valueListenable: _showControls,
                                        builder: (context, value, _) {
                                          return VideoStreamChangeWidget(
                                            showControls:
                                                value && !_controlsLocked,
                                            file: widget.file,
                                            isPreviewPlayer:
                                                widget.selectedPreview,
                                            onStreamChange:
                                                widget.onStreamChange,
                                          );
                                        },
                                      ),
                                      ValueListenableBuilder(
                                        valueListenable: _isPlaybackReady,
                                        builder: (
                                          BuildContext context,
                                          bool value,
                                          _,
                                        ) {
                                          return value
                                              ? _SeekBarAndDuration(
                                                  controller: _controller,
                                                  duration: duration,
                                                  showControls: _showControls,
                                                  isSeeking: _isSeeking,
                                                  position: position,
                                                  file: widget.file,
                                                  controlsLocked:
                                                      _controlsLocked,
                                                )
                                              : const SizedBox();
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // ===== New video control methods =====

  void _seekForward() {
    if (_controller == null) return;
    final currentPos = position ~/ 1000;
    final durationSeconds = durationToSeconds(duration) ?? 0;
    final newPos = (currentPos + _seekDuration).clamp(0, durationSeconds);
    _controller!.seekTo(Duration(seconds: newPos));
    Bus.instance.fire(SeekbarTriggeredEvent(position: newPos));
    HapticFeedback.lightImpact();
  }

  void _seekBackward() {
    if (_controller == null) return;
    final currentPos = position ~/ 1000;
    final durationSeconds = durationToSeconds(duration) ?? 0;
    final newPos = (currentPos - _seekDuration).clamp(0, durationSeconds);
    _controller!.seekTo(Duration(seconds: newPos));
    Bus.instance.fire(SeekbarTriggeredEvent(position: newPos));
    HapticFeedback.lightImpact();
  }

  void _setPlaybackSpeed(double speed) {
    setState(() {
      _playbackSpeed = speed;
    });
    _controller?.setPlaybackSpeed(speed);
  }

  void _toggleMute() {
    setState(() {
      _isMuted = !_isMuted;
    });
    _controller?.setVolume(_isMuted ? 0 : 1);
    HapticFeedback.lightImpact();
  }

  void _toggleLock() {
    setState(() {
      _controlsLocked = !_controlsLocked;
    });
    HapticFeedback.mediumImpact();
  }

  void _onLongPressStart() {
    if (_controller == null ||
        _controller!.playbackStatus != PlaybackStatus.playing) return;

    setState(() {
      _isLongPressing = true;
      _previousSpeed = _playbackSpeed;
    });
    _controller?.setPlaybackSpeed(2.0);
    HapticFeedback.mediumImpact();
  }

  void _onLongPressEnd() {
    if (!_isLongPressing) return;

    setState(() {
      _isLongPressing = false;
    });
    _controller?.setPlaybackSpeed(_previousSpeed);
  }

  void _hideIndicatorAfterDelay() {
    _indicatorTimer?.cancel();
    _indicatorTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) {
        setState(() {
          _showBrightnessIndicator = false;
          _showVolumeIndicator = false;
          _showSeekIndicator = false;
        });
      }
    });
  }

  Widget _buildVerticalIndicator({
    required IconData icon,
    required double value,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: strokeFaintDark,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 100,
            width: 4,
            child: RotatedBox(
              quarterTurns: -1,
              child: LinearProgressIndicator(
                value: value,
                backgroundColor: fillMutedDark,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "${(value * 100).toInt()}%",
            style: getEnteTextTheme(context).mini.copyWith(
                  color: textBaseDark,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildSeekIndicator() {
    final durationSeconds = durationToSeconds(duration) ?? 0;
    final currentPos = _formatDuration(_seekPosition.toInt());
    final totalDuration = _formatDuration(durationSeconds);
    final difference = (_seekPosition - position ~/ 1000).toInt();
    final differenceStr = difference >= 0 ? "+$difference" : "$difference";

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: strokeFaintDark,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                currentPos,
                style: getEnteTextTheme(context).body.copyWith(
                      color: textBaseDark,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              Text(
                " / $totalDuration",
                style: getEnteTextTheme(context).body.copyWith(
                      color: textMutedDark,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            "[$differenceStr s]",
            style: getEnteTextTheme(context).small.copyWith(
                  color: difference >= 0
                      ? const Color(0xFF00D09C)
                      : const Color(0xFFFF6B6B),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildFastForwardIndicator() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: strokeFaintDark,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.fast_forward,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(width: 8),
          Text(
            "2x",
            style: getEnteTextTheme(context).body.copyWith(
                  color: textBaseDark,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(1, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(1, '0')}:${secs.toString().padLeft(2, '0')}';
    }
  }

  // ===== End new video control methods =====

  Future<void> _initializeController(
    NativeVideoPlayerController controller,
  ) async {
    try {
      _logger.info(
        "Initializing native video player controller for file gen id: ${widget.file.generatedID}",
      );
      _controller = controller;

      _subscription = controller.events.listen(_listen);

      _isSeeking.addListener(_seekListener);

      await setVideoSource();
    } catch (e) {
      _logger.severe(
        "Error initializing native video player controller for file gen id: ${widget.file.generatedID}",
        e,
      );
    }
  }

  void _listen(PlaybackEvent event) {
    switch (event) {
      case PlaybackStatusChangedEvent():
        _onPlaybackStatusChanged();
      case PlaybackReadyEvent():
        _onPlaybackReady();
        break;
      case PlaybackPositionChangedEvent():
        position = event.positionInMilliseconds;
        if (mounted) {
          setState(() {});
        }
        break;
      case PlaybackEndedEvent():
        _onPlaybackEnded();
        break;
      case PlaybackErrorEvent():
        _onError(event.errorMessage);
        break;
      default:
    }
  }

  void _seekListener() {
    if (widget.isFromMemories) return;
    if (!_isSeeking.value &&
        _controller?.playbackStatus == PlaybackStatus.playing) {
      _debouncer.run(() async {
        if (mounted) {
          if (_isSeeking.value ||
              _controller?.playbackStatus != PlaybackStatus.playing) {
            return;
          }
          _showControls.value = false;
          if (widget.playbackCallback != null) {
            widget.playbackCallback!(
              true,
              FullScreenRequestReason.playbackStateChange,
            );
          }
        }
      });
    }
  }

  void _onPlaybackStatusChanged() {
    if (widget.isFromMemories) return;
    final duration = widget.file.duration != null
        ? widget.file.duration! * 1000
        : _controller?.videoInfo?.durationInMilliseconds;

    if (_isSeeking.value ||
        _controller?.playbackPosition.inMilliseconds == duration) {
      return;
    }
    if (_controller!.playbackStatus == PlaybackStatus.playing) {
      if (mounted) {
        _debouncer.run(() async {
          if (mounted) {
            if (_isSeeking.value ||
                _controller!.playbackStatus != PlaybackStatus.playing) {
              return;
            }
            _showControls.value = false;
            if (widget.playbackCallback != null) {
              widget.playbackCallback!(
                true,
                FullScreenRequestReason.playbackStateChange,
              );
            }
          }
        });
      }
    } else {
      if (widget.playbackCallback != null && mounted) {
        widget.playbackCallback!(
          false,
          FullScreenRequestReason.playbackStateChange,
        );
      }
    }

    _handleWakeLockOnPlaybackChanges();
  }

  void _onError(String errorMessage) {
    //This doesn't work all the time
    _logger.severe(
      "Error in native video player controller for file gen id: ${widget.file.generatedID}",
    );
    _logger.severe(errorMessage);
    Bus.instance.fire(UseMediaKitForVideo());
  }

  Future<void> _onPlaybackReady() async {
    if (_isPlaybackReady.value) return;
    await _controller!.play();
    final durationInSeconds = durationToSeconds(duration) ?? 10;
    widget.onFinalFileLoad?.call(memoryDuration: durationInSeconds);
    unawaited(_controller!.setVolume(1));
    _isPlaybackReady.value = true;
  }

  void _onPlaybackEnded() async {
    await _controller?.stop();
    if (localSettings.shouldLoopVideo()) {
      Bus.instance.fire(SeekbarTriggeredEvent(position: 0));
      await _controller?.play();
    }
  }

  void _loadNetworkVideo(bool update) {
    getFileFromServer(
      widget.file,
      progressCallback: (count, total) {
        if (!mounted) {
          return;
        }
        _progressNotifier.value = count / (widget.file.fileSize ?? total);
        if (_progressNotifier.value == 1) {
          if (mounted) {
            showShortToast(
              context,
              AppLocalizations.of(context).decryptingVideo,
            );
          }
        }
      },
    ).then((file) {
      if (file != null) {
        _setFilePathForNativePlayer(file.path, update);
      }
    }).onError((error, stackTrace) {
      showErrorDialog(
        context,
        AppLocalizations.of(context).error,
        AppLocalizations.of(context).failedToDownloadVideo,
      );
    });
  }

  void _setFileSizeIfNull() {
    if (widget.file.fileSize == null && widget.file.canEditMetaInfo) {
      FilesService.instance
          .getFileSize(widget.file.uploadedFileID!)
          .then((value) {
        widget.file.fileSize = value;
        if (mounted) {
          setState(() {});
        }
      });
    }
  }

  void _handleWakeLockOnPlaybackChanges() {
    final playbackStatus = _controller?.playbackStatus;
    if (playbackStatus == PlaybackStatus.playing) {
      EnteWakeLockService.instance.updateWakeLock(
        enable: true,
        wakeLockFor: WakeLockFor.videoPlayback,
      );
    } else {
      EnteWakeLockService.instance.updateWakeLock(
        enable: false,
        wakeLockFor: WakeLockFor.videoPlayback,
      );
    }
  }

  Widget _getLoadingWidget() {
    return Stack(
      key: const ValueKey("video_loading"),
      children: [
        Container(
          color: Colors.black,
          constraints: const BoxConstraints.expand(),
          child: _getThumbnail(),
        ),
        Container(
          color: Colors.black.withValues(alpha: 0.3),
          constraints: const BoxConstraints.expand(),
        ),
        Center(
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
            child: ValueListenableBuilder(
              valueListenable: _progressNotifier,
              builder: (BuildContext context, double? progress, _) {
                return progress == null || progress == 1
                    ? const EnteLoadingWidget(
                        size: 32,
                        color: fillBaseDark,
                        padding: 0,
                      )
                    : Stack(
                        children: [
                          CircularProgressIndicator(
                            backgroundColor: Colors.transparent,
                            value: progress,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              Color.fromRGBO(45, 194, 98, 1.0),
                            ),
                            strokeWidth: 2,
                            strokeCap: StrokeCap.round,
                          ),
                          Center(
                            child: Text(
                              "${(progress * 100).toStringAsFixed(0)}%",
                              style: getEnteTextTheme(context).tiny.copyWith(
                                    color: textBaseDark,
                                  ),
                            ),
                          ),
                        ],
                      );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _getThumbnail() {
    return ThumbnailWidget(
      widget.file,
      fit: BoxFit.contain,
      shouldShowVideoOverlayIcon: false,
      rawThumbnail: true,
    );
  }

  void _setFilePathForNativePlayer(String url, bool update) {
    if (!mounted) return;
    setState(() {
      _filePath = url;
    });
    _setAspectRatioFromVideoProps().then((_) {
      setState(() {});
    });

    if (update) {
      setVideoSource();
    }
  }

  Future<void> _setAspectRatioFromVideoProps() async {
    if (aspectRatio != null && duration != null) return;

    if (widget.playlistData != null && widget.selectedPreview) {
      aspectRatio = widget.playlistData!.width! / widget.playlistData!.height!;
      if (duration == "0:00" || duration == null) {
        if ((widget.file.duration ?? 0) > 0) {
          duration = secondsToDuration(widget.file.duration!);
        } else if (widget.playlistData!.durationInSeconds != null) {
          duration = secondsToDuration(
            widget.playlistData!.durationInSeconds!,
          );
        }
      }
      _logger.info("Getting aspect ratio from preview video");
      return;
    }
    final videoProps = await getVideoPropsAsync(File(_filePath!));
    if (videoProps != null) {
      duration = videoProps.propData?["duration"];

      if (videoProps.width != null && videoProps.height != null) {
        if (videoProps.width != null && videoProps.height != 0) {
          aspectRatio = videoProps.width! / videoProps.height!;
        } else {
          _logger.info("Video props height or width is 0");
          aspectRatio = 1;
        }
      } else {
        _logger.info("Video props width and height are null");
        aspectRatio = 1;
      }
    } else {
      _logger.info("Video props are null");
      aspectRatio = 1;
    }
  }
}

class _SeekBarAndDuration extends StatelessWidget {
  final NativeVideoPlayerController? controller;
  final String? duration;
  final ValueNotifier<bool> showControls;
  final ValueNotifier<bool> isSeeking;
  final int position;
  final EnteFile file;
  final bool controlsLocked;

  const _SeekBarAndDuration({
    required this.controller,
    required this.duration,
    required this.showControls,
    required this.isSeeking,
    required this.position,
    required this.file,
    this.controlsLocked = false,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: showControls,
      builder: (BuildContext context, bool value, _) {
        final shouldShow = value && !controlsLocked;
        return AnimatedOpacity(
          duration: const Duration(
            milliseconds: 200,
          ),
          curve: Curves.easeInQuad,
          opacity: shouldShow ? 1 : 0,
          child: IgnorePointer(
            ignoring: !shouldShow,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 8,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                  16,
                  4,
                  16,
                  4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.3),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(8),
                  ),
                  border: Border.all(
                    color: strokeFaintDark,
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    file.caption != null && file.caption!.isNotEmpty
                        ? Padding(
                            padding: const EdgeInsets.fromLTRB(
                              0,
                              8,
                              0,
                              12,
                            ),
                            child: GestureDetector(
                              onTap: () {
                                showDetailsSheet(context, file);
                              },
                              child: Text(
                                file.caption!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: getEnteTextTheme(context)
                                    .mini
                                    .copyWith(color: textBaseDark),
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                    Row(
                      children: [
                        AnimatedSize(
                          duration: const Duration(
                            seconds: 5,
                          ),
                          curve: Curves.easeInOut,
                          child: Text(
                            secondsToDuration(position ~/ 1000),
                            style: getEnteTextTheme(
                              context,
                            ).mini.copyWith(
                                  color: textBaseDark,
                                ),
                          ),
                        ),
                        Expanded(
                          child: SeekBar(
                            controller!,
                            durationToSeconds(duration),
                            isSeeking,
                          ),
                        ),
                        Text(
                          duration ?? "0:00",
                          style: getEnteTextTheme(context).mini.copyWith(
                                color: textBaseDark,
                              ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
