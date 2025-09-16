import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_to_airplay/flutter_to_airplay.dart';
import 'package:logging/logging.dart';
import 'package:photos/core/constants.dart';
import 'package:photos/core/event_bus.dart';
import 'package:photos/events/file_caption_updated_event.dart';
import 'package:photos/events/guest_view_event.dart';
import 'package:photos/events/loop_video_event.dart';
import 'package:photos/events/pause_video_event.dart';
import 'package:photos/events/stream_switched_event.dart';
import 'package:photos/generated/l10n.dart';
import 'package:photos/models/file/extensions/file_props.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/preview/playlist_data.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/airplay_service.dart';
import 'package:photos/services/files_service.dart';
import 'package:photos/utils/local_settings.dart';
import 'package:photos/services/wake_lock_service.dart';
import 'package:photos/theme/colors.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/actions/file/file_actions.dart';
import 'package:photos/ui/common/loading_widget.dart';
import 'package:photos/ui/viewer/file/thumbnail_widget.dart';
import 'package:photos/ui/viewer/file/video_stream_change.dart';
import 'package:photos/utils/dialog_util.dart';
import 'package:photos/utils/file_util.dart';
import 'package:photos/utils/standalone/debouncer.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:el_tooltip/el_tooltip.dart';

/// A video widget that uses FlutterAVPlayerView for iOS to support native AirPlay
/// with all the same controls and UI as the native video player
class VideoAirPlayWidget extends StatefulWidget {
  final EnteFile file;
  final String? tagPrefix;
  final Function(bool)? playbackCallback;
  final bool isFromMemories;
  final void Function()? onStreamChange;
  final PlaylistData? playlistData;
  final bool selectedPreview;
  final Function({required int memoryDuration})? onFinalFileLoad;

  const VideoAirPlayWidget(
    this.file, {
    this.tagPrefix,
    this.playbackCallback,
    this.isFromMemories = false,
    this.onStreamChange,
    this.playlistData,
    this.selectedPreview = false,
    this.onFinalFileLoad,
    super.key,
  });

  @override
  State<VideoAirPlayWidget> createState() => _VideoAirPlayWidgetState();
}

class _VideoAirPlayWidgetState extends State<VideoAirPlayWidget> 
    with WidgetsBindingObserver {
  final _logger = Logger('VideoAirPlayWidget');
  String? _videoPath;
  bool _isLoading = true;
  String? _errorMessage;
  bool _isDisposed = false;
  bool _isCompletelyVisible = false;
  bool _isGuestView = false;
  bool _shouldLoop = false;
  
  late StreamSubscription<GuestViewEvent> _guestViewEventSubscription;
  StreamSubscription<PauseVideoEvent>? _pauseVideoSubscription;
  StreamSubscription<FileCaptionUpdatedEvent>? _captionUpdatedSubscription;
  StreamSubscription<LoopVideoEvent>? _loopVideoEventSubscription;
  StreamSubscription<StreamSwitchedEvent>? _streamSwitchedSubscription;
  
  final ValueNotifier<bool> _showControls = ValueNotifier(true);
  final ValueNotifier<bool> _isPlaybackReady = ValueNotifier(false);
  final Debouncer _debouncer = Debouncer(
    const Duration(seconds: 3),
    executionInterval: const Duration(seconds: 1),
  );
  final ElTooltipController _elTooltipController = ElTooltipController();
  final ValueNotifier<double> _progressNotifier = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shouldLoop = localSettings.shouldLoopVideo();
    
    _initializeEventListeners();
    _loadVideo();
    
    EnteWakeLockService.instance
        .updateWakeLock(enable: true, wakeLockFor: WakeLockFor.videoPlayback);
  }

  void _initializeEventListeners() {
    _guestViewEventSubscription =
        Bus.instance.on<GuestViewEvent>().listen((event) {
      setState(() {
        _isGuestView = event.isGuestView;
      });
    });
    
    _pauseVideoSubscription = Bus.instance.on<PauseVideoEvent>().listen((event) {
      // Handle pause events if needed for FlutterAVPlayerView
    });
    
    _captionUpdatedSubscription =
        Bus.instance.on<FileCaptionUpdatedEvent>().listen((event) {
      if (event.fileGeneratedID == widget.file.generatedID) {
        if (mounted) {
          setState(() {});
        }
      }
    });
    
    _loopVideoEventSubscription =
        Bus.instance.on<LoopVideoEvent>().listen((event) {
      if (mounted) {
        setState(() {
          _shouldLoop = event.shouldLoop;
        });
      }
    });
    
    _streamSwitchedSubscription =
        Bus.instance.on<StreamSwitchedEvent>().listen((event) {
      if (mounted) {
        _loadVideo();
      }
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pauseVideoSubscription?.cancel();
    _captionUpdatedSubscription?.cancel();
    _loopVideoEventSubscription?.cancel();
    _streamSwitchedSubscription?.cancel();
    _guestViewEventSubscription.cancel();
    _showControls.dispose();
    _isPlaybackReady.dispose();
    _progressNotifier.dispose();
    _debouncer.cancelDebounceTimer();
    _elTooltipController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    EnteWakeLockService.instance
        .updateWakeLock(enable: false, wakeLockFor: WakeLockFor.videoPlayback);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // Pause playback when app goes to background
      // Note: FlutterAVPlayerView handles this internally
    }
  }

  Future<void> _loadVideo() async {
    try {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });

      String? videoPath;
      
      if (widget.selectedPreview && widget.playlistData != null) {
        // Load preview from playlist
        videoPath = widget.playlistData!.preview.path;
      } else if (widget.file.isRemoteFile) {
        // Download the file locally for AirPlay
        final file = await getFileFromServer(
          widget.file,
          progressCallback: (count, total) {
            if (!_isDisposed && mounted) {
              _progressNotifier.value = count / (widget.file.fileSize ?? total);
            }
          },
        );
        if (file != null) {
          videoPath = file.path;
        }
      } else if (widget.file.isSharedMediaToAppSandbox) {
        final localFile = File(getSharedMediaFilePath(widget.file));
        if (localFile.existsSync()) {
          videoPath = localFile.path;
        }
      } else {
        final localFile = await getFile(widget.file, isOrigin: true);
        if (localFile != null && localFile.existsSync()) {
          videoPath = localFile.path;
        }
      }

      if (!_isDisposed && mounted) {
        setState(() {
          _videoPath = videoPath;
          _isLoading = false;
          _isPlaybackReady.value = videoPath != null;
        });
        
        if (videoPath != null) {
          // TODO: Get video duration if needed
          widget.onFinalFileLoad?.call(memoryDuration: 10);
        }
        
        widget.playbackCallback?.call(videoPath != null);
      }
    } catch (e, s) {
      _logger.severe('Failed to load video for AirPlay', e, s);
      if (!_isDisposed && mounted) {
        setState(() {
          _errorMessage = 'Failed to load video: ${e.toString()}';
          _isLoading = false;
        });
        widget.playbackCallback?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isIOS || !featureFlagService.isAirplaySupported) {
      return Center(
        child: Text(
          'AirPlay is not supported on this device',
          style: getEnteTextTheme(context).body,
        ),
      );
    }

    return Hero(
      tag: widget.tagPrefix != null 
          ? widget.tagPrefix! + widget.file.tag
          : widget.file.tag,
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
          onTap: () {
            if (_showControls.value) {
              _showControls.value = false;
            } else {
              _showControls.value = true;
              _startControlDebouncer();
            }
          },
          child: _buildVideoContent(context),
        ),
      ),
    );
  }

  Widget _buildVideoContent(BuildContext context) {
    if (_isLoading) {
      return Center(
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
                          fillBaseDark,
                        ),
                      ),
                      Positioned.fill(
                        child: Center(
                          child: Text(
                            "${(progress * 100).toInt()}%",
                            style: getEnteTextTheme(context).mini.copyWith(
                                  color: fillBaseDark,
                                ),
                          ),
                        ),
                      ),
                    ],
                  );
          },
        ),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 48,
              color: getEnteColorScheme(context).warning700,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              style: getEnteTextTheme(context).body,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: _loadVideo,
              child: Text(AppLocalizations.of(context).retry),
            ),
          ],
        ),
      );
    }

    if (_videoPath == null) {
      return Center(
        child: Text(
          'No video available',
          style: getEnteTextTheme(context).body,
        ),
      );
    }

    // FlutterAVPlayerView automatically shows AirPlay overlay when active
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Video player with native AirPlay support
          Center(
            child: FlutterAVPlayerView(
              filePath: _videoPath,
            ),
          ),
          
          // Thumbnail overlay when loading
          if (!_isCompletelyVisible)
            Center(
              child: ThumbnailWidget(
                widget.file,
                fit: BoxFit.contain,
              ),
            ),
          
          // AirPlay button in top right
          Positioned(
            top: 40,
            right: 16,
            child: SafeArea(
              child: ValueListenableBuilder(
                valueListenable: _showControls,
                builder: (context, value, _) {
                  return AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: value ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: !value,
                      child: AirPlayService.instance.buildAirPlayButton(
                        tintColor: Colors.white,
                        activeTintColor: Colors.blue,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          
          // Bottom controls
          if (!widget.isFromMemories)
            Positioned(
              bottom: 0,
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
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Stream change widget
                      ValueListenableBuilder(
                        valueListenable: _showControls,
                        builder: (context, value, _) {
                          return VideoStreamChangeWidget(
                            showControls: value,
                            file: widget.file,
                            isPreviewPlayer: widget.selectedPreview,
                            onStreamChange: widget.onStreamChange,
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _startControlDebouncer() {
    _debouncer.run(() async {
      if (mounted && _showControls.value) {
        _showControls.value = false;
        widget.playbackCallback?.call(true);
      }
    });
  }
}