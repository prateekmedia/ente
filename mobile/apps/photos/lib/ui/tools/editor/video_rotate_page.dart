import 'package:flutter/material.dart';
import "package:photos/ente_theme_data.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_aspect_ratio.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_bottom_action.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_main_actions.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_navigation_options.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_player_control.dart";
import 'package:video_editor/video_editor.dart';

class VideoRotatePage extends StatelessWidget {
  final int quarterTurnsForRotationCorrection;
  final Duration? fallbackDuration;
  const VideoRotatePage({
    super.key,
    required this.controller,
    required this.quarterTurnsForRotationCorrection,
    this.fallbackDuration,
  });

  final VideoEditorController controller;

  @override
  Widget build(BuildContext context) {
    final rotation = controller.rotation;
    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        toolbarHeight: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Hero(
                tag: "video-editor-preview",
                child: AnimatedBuilder(
                  animation: controller,
                  builder: (_, __) => _buildRotatedPreview(
                    CropGridViewer.preview(
                      controller: controller,
                    ),
                  ),
                ),
              ),
            ),
            VideoEditorPlayerControl(
              controller: controller,
              fallbackDuration: fallbackDuration,
            ),
            VideoEditorMainActions(
              children: [
                VideoEditorBottomAction(
                  label: AppLocalizations.of(context).left,
                  onPressed: () =>
                      controller.rotate90Degrees(RotateDirection.left),
                  icon: Icons.rotate_left,
                ),
                const SizedBox(width: 40),
                VideoEditorBottomAction(
                  label: AppLocalizations.of(context).right,
                  onPressed: () =>
                      controller.rotate90Degrees(RotateDirection.right),
                  icon: Icons.rotate_right,
                ),
              ],
            ),
            const SizedBox(height: 40),
            VideoEditorNavigationOptions(
              color: Theme.of(context).colorScheme.videoPlayerPrimaryColor,
              secondaryText: AppLocalizations.of(context).done,
              onPrimaryPressed: () {
                while (controller.rotation != rotation) {
                  controller.rotate90Degrees(RotateDirection.left);
                }
                Navigator.pop(context);
              },
              onSecondaryPressed: () {
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRotatedPreview(Widget child) {
    final normalizedQuarterTurns = controller.displayQuarterTurns;
    double? aspectRatio;
    aspectRatio = effectiveAspectRatio(controller, normalizedQuarterTurns);

    if (aspectRatio == null) {
      return child;
    }

    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: child,
      ),
    );
  }
}
