import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/ente_theme.dart";
import "package:screen_brightness/screen_brightness.dart";
import "package:volume_controller/volume_controller.dart";

/// Enum for the type of vertical gesture
enum VerticalGestureType {
  brightness,
  volume,
}

/// A widget that handles brightness and volume gestures on video player
class VideoGestureControls extends StatefulWidget {
  /// Callback when horizontal drag is performed for seeking
  final Function(double deltaX)? onHorizontalDrag;

  /// Callback when horizontal drag starts
  final VoidCallback? onHorizontalDragStart;

  /// Callback when horizontal drag ends with final position
  final Function(double finalPosition)? onHorizontalDragEnd;

  /// Current video duration in seconds
  final int? videoDuration;

  /// Current video position in seconds
  final int currentPosition;

  /// Whether to enable brightness control (left side)
  final bool enableBrightnessControl;

  /// Whether to enable volume control (right side)
  final bool enableVolumeControl;

  /// Whether to enable horizontal drag seeking
  final bool enableHorizontalDragSeeking;

  /// Child widget (usually the video player)
  final Widget? child;

  /// Callback for single tap
  final VoidCallback? onSingleTap;

  /// Whether controls are locked
  final bool controlsLocked;

  const VideoGestureControls({
    super.key,
    this.onHorizontalDrag,
    this.onHorizontalDragStart,
    this.onHorizontalDragEnd,
    this.videoDuration,
    this.currentPosition = 0,
    this.enableBrightnessControl = true,
    this.enableVolumeControl = true,
    this.enableHorizontalDragSeeking = true,
    this.child,
    this.onSingleTap,
    this.controlsLocked = false,
  });

  @override
  State<VideoGestureControls> createState() => _VideoGestureControlsState();
}

class _VideoGestureControlsState extends State<VideoGestureControls> {
  // Brightness and volume values
  double _brightness = 0.5;
  double _volume = 0.5;

  // Gesture state
  VerticalGestureType? _activeGestureType;
  bool _isVerticalDragging = false;
  bool _isHorizontalDragging = false;
  double _dragStartY = 0;
  double _dragStartX = 0;
  double _seekPosition = 0;

  // For showing indicators
  Timer? _indicatorTimer;
  bool _showBrightnessIndicator = false;
  bool _showVolumeIndicator = false;
  bool _showSeekIndicator = false;

  @override
  void initState() {
    super.initState();
    _initializeValues();
  }

  Future<void> _initializeValues() async {
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
      // Ignore errors
    }
  }

  @override
  void dispose() {
    _indicatorTimer?.cancel();
    // Reset brightness to system default
    try {
      ScreenBrightness.instance.resetApplicationScreenBrightness();
    } catch (e) {
      // Ignore
    }
    super.dispose();
  }

  void _handleVerticalDragStart(DragStartDetails details) {
    if (widget.controlsLocked) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final isLeftSide = details.localPosition.dx < screenWidth / 2;

    _dragStartY = details.localPosition.dy;

    if (isLeftSide && widget.enableBrightnessControl) {
      _activeGestureType = VerticalGestureType.brightness;
      _isVerticalDragging = true;
    } else if (!isLeftSide && widget.enableVolumeControl) {
      _activeGestureType = VerticalGestureType.volume;
      _isVerticalDragging = true;
    }
  }

  void _handleVerticalDragUpdate(DragUpdateDetails details) {
    if (!_isVerticalDragging || widget.controlsLocked) return;

    final screenHeight = MediaQuery.of(context).size.height;
    final deltaY = _dragStartY - details.localPosition.dy;
    final sensitivity = 1.5 / screenHeight; // Adjust sensitivity

    if (_activeGestureType == VerticalGestureType.brightness) {
      _updateBrightness(deltaY * sensitivity);
    } else if (_activeGestureType == VerticalGestureType.volume) {
      _updateVolume(deltaY * sensitivity);
    }

    _dragStartY = details.localPosition.dy;
  }

  void _handleVerticalDragEnd(DragEndDetails details) {
    _isVerticalDragging = false;
    _activeGestureType = null;
    _hideIndicatorAfterDelay();
  }

  void _updateBrightness(double delta) {
    setState(() {
      _brightness = (_brightness + delta).clamp(0.0, 1.0);
      _showBrightnessIndicator = true;
    });

    try {
      ScreenBrightness.instance.setApplicationScreenBrightness(_brightness);
    } catch (e) {
      // Ignore errors
    }
  }

  void _updateVolume(double delta) {
    setState(() {
      _volume = (_volume + delta).clamp(0.0, 1.0);
      _showVolumeIndicator = true;
    });

    try {
      VolumeController.instance.setVolume(_volume, showSystemUI: false);
    } catch (e) {
      // Ignore errors
    }
  }

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (widget.controlsLocked || !widget.enableHorizontalDragSeeking) return;

    _dragStartX = details.localPosition.dx;
    _isHorizontalDragging = true;
    _seekPosition = widget.currentPosition.toDouble();
    widget.onHorizontalDragStart?.call();

    setState(() {
      _showSeekIndicator = true;
    });
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (!_isHorizontalDragging ||
        widget.controlsLocked ||
        widget.videoDuration == null) return;

    final screenWidth = MediaQuery.of(context).size.width;
    final deltaX = details.localPosition.dx - _dragStartX;
    final sensitivity = widget.videoDuration! / screenWidth;

    setState(() {
      _seekPosition =
          (_seekPosition + deltaX * sensitivity * 0.5).clamp(0.0, widget.videoDuration!.toDouble());
    });

    _dragStartX = details.localPosition.dx;
    widget.onHorizontalDrag?.call(_seekPosition);
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (!_isHorizontalDragging) return;

    _isHorizontalDragging = false;
    widget.onHorizontalDragEnd?.call(_seekPosition);
    _hideIndicatorAfterDelay();
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

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _handleVerticalDragStart,
      onVerticalDragUpdate: _handleVerticalDragUpdate,
      onVerticalDragEnd: _handleVerticalDragEnd,
      onHorizontalDragStart: _handleHorizontalDragStart,
      onHorizontalDragUpdate: _handleHorizontalDragUpdate,
      onHorizontalDragEnd: _handleHorizontalDragEnd,
      onTap: widget.onSingleTap,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.child != null) widget.child!,
          // Brightness indicator
          if (_showBrightnessIndicator)
            Positioned(
              left: 40,
              child: _buildVerticalIndicator(
                icon: _brightness > 0.66
                    ? Icons.brightness_high
                    : _brightness > 0.33
                        ? Icons.brightness_medium
                        : Icons.brightness_low,
                value: _brightness,
              ),
            ),
          // Volume indicator
          if (_showVolumeIndicator)
            Positioned(
              right: 40,
              child: _buildVerticalIndicator(
                icon: _volume > 0.66
                    ? Icons.volume_up
                    : _volume > 0
                        ? Icons.volume_down
                        : Icons.volume_off,
                value: _volume,
              ),
            ),
          // Seek indicator
          if (_showSeekIndicator && widget.videoDuration != null)
            _buildSeekIndicator(),
        ],
      ),
    );
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
    final currentPos = _formatDuration(_seekPosition.toInt());
    final totalDuration = _formatDuration(widget.videoDuration ?? 0);
    final difference = (_seekPosition - widget.currentPosition).toInt();
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
}
