import 'package:flutter/material.dart';
import "package:photos/ente_theme_data.dart";
import "package:photos/generated/l10n.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_aspect_ratio.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_navigation_options.dart";
import "package:photos/ui/tools/editor/video_editor/video_editor_player_control.dart";
import 'package:video_editor/video_editor.dart';

class VideoTrimPage extends StatefulWidget {
  final int quarterTurnsForRotationCorrection;
  final Duration? fallbackDuration;
  const VideoTrimPage({
    super.key,
    required this.controller,
    required this.quarterTurnsForRotationCorrection,
    this.fallbackDuration,
  });

  final VideoEditorController controller;

  @override
  State<VideoTrimPage> createState() => _VideoTrimPageState();
}

class _VideoTrimPageState extends State<VideoTrimPage> {
  final double height = 60;
  late double _initialMinTrim;
  late double _initialMaxTrim;

  @override
  void initState() {
    super.initState();
    _cacheInitialTrim();
  }

  @override
  void didUpdateWidget(covariant VideoTrimPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _cacheInitialTrim();
    }
  }

  void _cacheInitialTrim() {
    _initialMinTrim = widget.controller.minTrim;
    _initialMaxTrim = widget.controller.maxTrim;
  }

  @override
  Widget build(BuildContext context) {


    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        toolbarHeight: 0,
      ),
      body: SafeArea(
        child: Column(
          children: [
            VideoEditorPlayerControl(
              controller: widget.controller,
              fallbackDuration: widget.fallbackDuration,
            ),
            Expanded(
              child: Hero(
                tag: "video-editor-preview",
                child: AnimatedBuilder(
                  animation: widget.controller,
                  builder: (_, __) => _buildRotatedPreview(
                    CropGridViewer.preview(
                      controller: widget.controller,
                    ),
                  ),
                ),
              ),
            ),
            ..._trimSlider(),
            const SizedBox(height: 40),
            VideoEditorNavigationOptions(
              color: Theme.of(context).colorScheme.videoPlayerPrimaryColor,
              secondaryText: AppLocalizations.of(context).done,
              onPrimaryPressed: () {
                widget.controller.updateTrim(
                  _initialMinTrim,
                  _initialMaxTrim,
                );
                widget.controller.isTrimming = false;
                Navigator.pop(context);
              },
              onSecondaryPressed: () {
                // WAY 1: validate crop parameters set in the crop view
                widget.controller.applyCacheCrop();
                // WAY 2: update manually with Offset values
                // controller.updateCrop(const Offset(0.2, 0.2), const Offset(0.8, 0.8));
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _trimSlider() {
    return [
      Container(
        width: MediaQuery.of(context).size.width,
        margin: EdgeInsets.symmetric(vertical: height / 4, horizontal: 20),
        child: TrimSlider(
          controller: widget.controller,
          height: height,
          horizontalMargin: height / 4,
        ),
      ),
    ];
  }

  Widget _buildRotatedPreview(Widget child) {
    final normalizedQuarterTurns = widget.controller.displayQuarterTurns;
    double? aspectRatio;
    aspectRatio =
        effectiveAspectRatio(widget.controller, normalizedQuarterTurns);

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

  String formatter(Duration duration) => [
        duration.inMinutes.remainder(60).toString().padLeft(2, '0'),
        duration.inSeconds.remainder(60).toString().padLeft(2, '0'),
      ].join(":");
}
