import "package:flutter/material.dart";
import "package:photos/theme/colors.dart";

/// A button to toggle mute/unmute state
class MuteButton extends StatelessWidget {
  /// Whether the video is currently muted
  final bool isMuted;

  /// Callback when mute state is toggled
  final VoidCallback onToggle;

  const MuteButton({
    super.key,
    required this.isMuted,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          shape: BoxShape.circle,
          border: Border.all(
            color: strokeFaintDark,
            width: 1,
          ),
        ),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (Widget child, Animation<double> animation) {
            return ScaleTransition(scale: animation, child: child);
          },
          child: Icon(
            isMuted ? Icons.volume_off : Icons.volume_up,
            key: ValueKey(isMuted),
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
