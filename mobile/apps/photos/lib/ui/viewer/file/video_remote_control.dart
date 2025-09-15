import 'dart:async';

import 'package:external_display_plugin/external_display_plugin.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/models/preview/playlist_data.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/external_display_service.dart';
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/viewer/file/thumbnail_widget.dart';
import 'package:photos/ui/viewer/file/video_stream_change.dart';

class VideoRemoteControl extends StatefulWidget {
  final EnteFile file;
  final Duration? videoDuration;
  final bool selectPreviewForPlay;
  final PlaylistData? playlistData;
  final Function()? onStreamChange;

  const VideoRemoteControl({
    required this.file,
    this.videoDuration,
    required this.selectPreviewForPlay,
    this.playlistData,
    this.onStreamChange,
    super.key,
  });

  @override
  State<VideoRemoteControl> createState() => _VideoRemoteControlState();
}

class _VideoRemoteControlState extends State<VideoRemoteControl> {
  final _logger = Logger('VideoRemoteControl');
  late final ExternalDisplayService _externalDisplayService;
  late StreamSubscription<VideoPlayerState> _videoStateSubscription;

  VideoPlayerState? _currentState;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  bool _isPlaying = false;
  bool _isSeeking = false;

  @override
  void initState() {
    super.initState();
    _externalDisplayService = externalDisplayService;
    _setupVideoStateListener();
    _initializeState();
  }

  void _setupVideoStateListener() {
    _videoStateSubscription =
        ExternalDisplayPlugin.videoPlayerStateStream.listen((state) {
      if (mounted) {
        setState(() {
          _currentState = state;
          // Only update position if not currently seeking to avoid conflicts
          if (!_isSeeking) {
            _currentPosition = state.position;
          }
          _isPlaying = state.state == PlaybackState.playing;

          // Update total duration if available
          if (state.duration > Duration.zero) {
            _totalDuration = state.duration;
          }
        });
      }
    });
  }

  void _initializeState() {
    _currentState = _externalDisplayService.currentVideoState;
    if (_currentState != null) {
      _currentPosition = _currentState!.position;
      _isPlaying = _currentState!.state == PlaybackState.playing;
      if (_currentState!.duration > Duration.zero) {
        _totalDuration = _currentState!.duration;
        _logger.info('Duration from current state: ${_currentState!.duration}');
      }
    }

    // Use provided video duration as fallback
    if (_totalDuration == Duration.zero && widget.videoDuration != null) {
      _totalDuration = widget.videoDuration!;
      _logger.info('Duration from widget param: ${widget.videoDuration}');
    }

    // Use file duration as final fallback
    if (_totalDuration == Duration.zero && widget.file.duration != null) {
      _totalDuration = Duration(microseconds: widget.file.duration!);
      _logger.info(
        'Duration from file: ${Duration(microseconds: widget.file.duration!)}',
      );
    }

    _logger.info('Final total duration: $_totalDuration');
  }

  @override
  void dispose() {
    _videoStateSubscription.cancel();
    super.dispose();
  }

  void _onPlayPause() async {
    try {
      if (_isPlaying) {
        await _externalDisplayService.pauseVideo();
      } else {
        await _externalDisplayService.resumeVideo();
      }
    } catch (e, s) {
      _logger.severe('Failed to toggle play/pause', e, s);
    }
  }

  void _onSeek(double value) async {
    if (!_isSeeking) return;

    final position = Duration(
      milliseconds: (value * _totalDuration.inMilliseconds).round(),
    );

    try {
      await _externalDisplayService.seekVideo(position);
    } catch (e, s) {
      _logger.severe('Failed to seek video', e, s);
    }
  }

  void _onSeekStart() {
    setState(() {
      _isSeeking = true;
    });
  }

  void _onSeekEnd() {
    setState(() {
      _isSeeking = false;
    });

    // After seeking ends, force a state refresh to ensure synchronization
    _logger.info('Seek ended at position: $_currentPosition');

    // Small delay to allow the external player to update its state
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted && _externalDisplayService.currentVideoState != null) {
        final externalState = _externalDisplayService.currentVideoState!;
        if (mounted) {
          setState(() {
            _currentPosition = externalState.position;
            _isPlaying = externalState.state == PlaybackState.playing;
          });
        }
      }
    });
  }

  String _formatDuration(Duration duration) {
    final seconds = duration.inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final secs = seconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = getEnteTextTheme(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Video thumbnail (centered, fit width)
          Center(
            child: Stack(
              children: [
                // Thumbnail with width constraint
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width,
                  ),
                  child: ThumbnailWidget(
                    widget.file,
                    fit: BoxFit.fitWidth,
                    shouldShowSyncStatus: false,
                    key: Key(
                      'remote_control_thumbnail_${widget.file.generatedID}',
                    ),
                  ),
                ),
                // Dark overlay to indicate external playback
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.3),
                  ),
                ),
                // AirPlay indicator (positioned lower to avoid play button)
                Positioned(
                  left: 0,
                  right: 0,
                  top: MediaQuery.of(context).size.height * 0.7,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.airplay,
                            color: Colors.blue,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Playing on External Display',
                            style: textTheme.body.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Play/Pause overlay (center, always visible)
          Center(
            child: GestureDetector(
              onTap: _onPlayPause,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.5),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: child,
                    );
                  },
                  child: Icon(
                    _isPlaying ? Icons.pause : Icons.play_arrow,
                    key: ValueKey(_isPlaying),
                    color: Colors.white,
                    size: _isPlaying ? 32 : 36,
                  ),
                ),
              ),
            ),
          ),

          // Bottom controls (positioned to match native video controls)
          Positioned(
            left: 0,
            right: 0,
            bottom: 96,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    _formatDuration(_currentPosition),
                    style: textTheme.mini.copyWith(color: Colors.white),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.0,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8.0,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14.0,
                          ),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor:
                              Colors.white.withValues(alpha: 0.3),
                          thumbColor: Colors.white,
                          overlayColor: Colors.white.withValues(alpha: 0.2),
                        ),
                        child: Slider(
                          value: _totalDuration.inMilliseconds > 0
                              ? (_currentPosition.inMilliseconds /
                                      _totalDuration.inMilliseconds)
                                  .clamp(0.0, 1.0)
                              : 0.0,
                          onChanged: _totalDuration.inMilliseconds > 0
                              ? (value) {
                                  if (!_isSeeking) return;
                                  final position = Duration(
                                    milliseconds:
                                        (value * _totalDuration.inMilliseconds)
                                            .round(),
                                  );
                                  setState(() {
                                    _currentPosition = position;
                                  });
                                }
                              : null,
                          onChangeStart: (_) => _onSeekStart(),
                          onChangeEnd: (value) {
                            _onSeek(value);
                            _onSeekEnd();
                          },
                        ),
                      ),
                    ),
                  ),
                  Text(
                    _formatDuration(_totalDuration),
                    style: textTheme.mini.copyWith(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          // Stream/Original toggle (positioned to match native controls)
          Positioned(
            right: 4,
            bottom: 136,
            child: VideoStreamChangeWidget(
              showControls: true,
              file: widget.file,
              onStreamChange: widget.onStreamChange,
              isPreviewPlayer: widget.selectPreviewForPlay,
            ),
          ),
        ],
      ),
    );
  }
}
