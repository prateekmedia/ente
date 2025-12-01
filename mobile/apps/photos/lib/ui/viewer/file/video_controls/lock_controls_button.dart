import "package:flutter/material.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/ente_theme.dart";

/// A button to lock/unlock video controls
class LockControlsButton extends StatelessWidget {
  /// Whether controls are currently locked
  final bool isLocked;

  /// Callback when lock state is toggled
  final VoidCallback onToggle;

  const LockControlsButton({
    super.key,
    required this.isLocked,
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
            isLocked ? Icons.lock : Icons.lock_open,
            key: ValueKey(isLocked),
            size: 18,
            color: isLocked ? const Color(0xFFFF9500) : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// An overlay shown when controls are locked
class LockedControlsOverlay extends StatelessWidget {
  /// Callback when unlock button is tapped
  final VoidCallback onUnlock;

  const LockedControlsOverlay({
    super.key,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16,
      left: 0,
      right: 0,
      child: Center(
        child: GestureDetector(
          onTap: onUnlock,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: strokeFaintDark,
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock,
                  color: Color(0xFFFF9500),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  "Tap to unlock",
                  style: getEnteTextTheme(context).small.copyWith(
                        color: textBaseDark,
                      ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
