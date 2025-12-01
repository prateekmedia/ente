import "package:flutter/material.dart";
import "package:photos/theme/colors.dart";
import "package:photos/theme/ente_theme.dart";

/// Available playback speeds
const List<double> playbackSpeeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

/// A widget that displays the current playback speed as a button
/// and opens a speed selection menu when tapped.
class PlaybackSpeedButton extends StatelessWidget {
  /// Current playback speed
  final double currentSpeed;

  /// Callback when speed is changed
  final ValueChanged<double> onSpeedChanged;

  const PlaybackSpeedButton({
    super.key,
    required this.currentSpeed,
    required this.onSpeedChanged,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _showSpeedSelector(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: strokeFaintDark,
            width: 1,
          ),
        ),
        child: Text(
          currentSpeed == 1.0 ? "1x" : "${currentSpeed}x",
          style: getEnteTextTheme(context).mini.copyWith(
                color: textBaseDark,
                fontWeight: FontWeight.w600,
              ),
        ),
      ),
    );
  }

  void _showSpeedSelector(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => PlaybackSpeedSelector(
        currentSpeed: currentSpeed,
        onSpeedChanged: (speed) {
          onSpeedChanged(speed);
          Navigator.pop(context);
        },
      ),
    );
  }
}

/// Bottom sheet for selecting playback speed
class PlaybackSpeedSelector extends StatelessWidget {
  final double currentSpeed;
  final ValueChanged<double> onSpeedChanged;

  const PlaybackSpeedSelector({
    super.key,
    required this.currentSpeed,
    required this.onSpeedChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: strokeFaintDark,
          width: 1,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              "Playback Speed",
              style: getEnteTextTheme(context).body.copyWith(
                    color: textBaseDark,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const Divider(color: strokeFaintDark, height: 1),
          ...playbackSpeeds.map((speed) => _buildSpeedOption(context, speed)),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildSpeedOption(BuildContext context, double speed) {
    final isSelected = speed == currentSpeed;
    return InkWell(
      onTap: () => onSpeedChanged(speed),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                speed == 1.0 ? "Normal" : "${speed}x",
                style: getEnteTextTheme(context).body.copyWith(
                      color: isSelected
                          ? const Color(0xFF00D09C)
                          : textBaseDark,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal,
                    ),
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check,
                color: Color(0xFF00D09C),
                size: 20,
              ),
          ],
        ),
      ),
    );
  }
}
