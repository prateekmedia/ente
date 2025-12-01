import "dart:async";

import "package:flutter/material.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/ente_theme.dart";

/// A widget that shows a ripple animation when double-tapped to seek.
class DoubleTapToSeek extends StatefulWidget {
  /// Duration to seek in seconds (default 10s)
  final int seekDuration;

  /// Whether seeking forward (right side) or backward (left side)
  final bool isForward;

  /// Callback when seek is triggered
  final VoidCallback onSeek;

  /// Whether controls are visible
  final bool showControls;

  const DoubleTapToSeek({
    super.key,
    this.seekDuration = 10,
    required this.isForward,
    required this.onSeek,
    required this.showControls,
  });

  @override
  State<DoubleTapToSeek> createState() => _DoubleTapToSeekState();
}

class _DoubleTapToSeekState extends State<DoubleTapToSeek>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _opacityAnimation;
  bool _showIndicator = false;
  int _tapCount = 0;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutCubic,
      ),
    );

    _opacityAnimation = Tween<double>(begin: 0.8, end: 0.0).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );

    _animationController.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _showIndicator = false;
          _tapCount = 0;
        });
        _animationController.reset();
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    _tapTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    _tapCount++;
    _tapTimer?.cancel();

    if (_tapCount >= 2) {
      // Double tap detected
      widget.onSeek();
      _showSeekIndicator();
      _tapCount = 0;
    } else {
      // Wait for potential second tap
      _tapTimer = Timer(const Duration(milliseconds: 250), () {
        _tapCount = 0;
      });
    }
  }

  void _showSeekIndicator() {
    setState(() {
      _showIndicator = true;
    });
    _animationController.forward();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _handleTap,
      child: Container(
        color: Colors.transparent,
        child: Stack(
          alignment: widget.isForward
              ? Alignment.centerRight
              : Alignment.centerLeft,
          children: [
            if (_showIndicator)
              Positioned(
                left: widget.isForward ? null : 20,
                right: widget.isForward ? 20 : null,
                child: AnimatedBuilder(
                  animation: _animationController,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _scaleAnimation.value,
                      child: Opacity(
                        opacity: _opacityAnimation.value,
                        child: _buildSeekIndicator(context),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeekIndicator(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: strokeFaintDark,
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            widget.isForward ? Icons.fast_forward : Icons.fast_rewind,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(width: 8),
          Text(
            "${widget.seekDuration}s",
            style: getEnteTextTheme(context).small.copyWith(
                  color: textBaseDark,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

/// A container that handles double-tap seeking on both sides of the video
class DoubleTapSeekOverlay extends StatelessWidget {
  /// Duration to seek in seconds
  final int seekDuration;

  /// Callback when seeking forward
  final VoidCallback onSeekForward;

  /// Callback when seeking backward
  final VoidCallback onSeekBackward;

  /// Single tap callback (for toggling controls)
  final VoidCallback? onSingleTap;

  /// Whether controls are visible
  final bool showControls;

  const DoubleTapSeekOverlay({
    super.key,
    this.seekDuration = 10,
    required this.onSeekForward,
    required this.onSeekBackward,
    this.onSingleTap,
    required this.showControls,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // Left side - seek backward
        Expanded(
          child: DoubleTapToSeek(
            seekDuration: seekDuration,
            isForward: false,
            onSeek: onSeekBackward,
            showControls: showControls,
          ),
        ),
        // Right side - seek forward
        Expanded(
          child: DoubleTapToSeek(
            seekDuration: seekDuration,
            isForward: true,
            onSeek: onSeekForward,
            showControls: showControls,
          ),
        ),
      ],
    );
  }
}
