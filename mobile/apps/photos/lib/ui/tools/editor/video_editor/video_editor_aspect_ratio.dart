import 'package:flutter/material.dart';
import 'package:video_editor/video_editor.dart';

double? effectiveAspectRatio(
  VideoEditorController controller,
  int quarterTurns,
) {
  final Size dimension = controller.videoDimension;
  if (dimension.width <= 0 || dimension.height <= 0) {
    return null;
  }

  final normalized = ((quarterTurns % 4) + 4) % 4;
  final baseRatio = dimension.width / dimension.height;
  return normalized.isOdd ? dimension.height / dimension.width : baseRatio;
}
