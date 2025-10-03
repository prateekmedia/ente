import "package:flutter/material.dart";
import "package:photos/ente_theme_data.dart";
import "package:video_editor/video_editor.dart";

class VideoEditorPlayerControl extends StatelessWidget {
  const VideoEditorPlayerControl({
    super.key,
    required this.controller,
    this.fallbackDuration,
  });

  final VideoEditorController controller;
  final Duration? fallbackDuration;

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: "video_editor_player_control",
      child: AnimatedBuilder(
        animation: controller,
        builder: (_, __) {
          final totalDuration = _effectiveTotalDuration(controller);
          final positionDuration = _effectivePosition(controller, totalDuration);
          final isPlaying = controller.isPlaying;

          return GestureDetector(
            onTap: () {
              if (controller.isPlaying) {
                controller.nativeController?.pause();
              } else {
                controller.nativeController?.play();
              }
            },
            child: Container(
              height: 28,
              margin: const EdgeInsets.only(top: 24, bottom: 28),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.editorBackgroundColor,
                borderRadius: BorderRadius.circular(56),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    !isPlaying ? Icons.play_arrow : Icons.pause,
                    size: 21,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "${_durationLabel(positionDuration)} / ${_durationLabel(totalDuration, allowZero: false)}",
                    // ignore: prefer_const_constructors
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Duration _effectiveTotalDuration(VideoEditorController controller) {
    final trimmed = controller.trimmedDuration;
    if (trimmed > Duration.zero) {
      return trimmed;
    }
    final max = controller.maxDuration;
    if (max > Duration.zero) {
      return max;
    }
    final video = controller.videoDuration;
    if (video > Duration.zero) {
      return video;
    }
    if (fallbackDuration != null && fallbackDuration! > Duration.zero) {
      return fallbackDuration!;
    }
    return Duration.zero;
  }

  Duration _effectivePosition(
    VideoEditorController controller,
    Duration total,
  ) {
    if (total == Duration.zero) {
      return Duration.zero;
    }

    final rawPosition = controller.videoPosition - controller.startTrim;
    if (rawPosition.isNegative) {
      return Duration.zero;
    }
    if (rawPosition > total) {
      return total;
    }
    return rawPosition;
  }

  String _durationLabel(Duration duration, {bool allowZero = true}) {
    if (duration < Duration.zero) {
      duration = Duration.zero;
    }
    if (duration == Duration.zero) {
      return allowZero ? formatter(Duration.zero) : "--:--";
    }
    return formatter(duration);
  }

  String formatter(Duration duration) => [
        duration.inMinutes.remainder(60).toString().padLeft(2, '0'),
        duration.inSeconds.remainder(60).toString().padLeft(2, '0'),
      ].join(":");
}
