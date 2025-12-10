import "dart:async";
import "dart:isolate";

import "package:ffmpeg_kit_flutter/ffmpeg_kit.dart";
import "package:ffmpeg_kit_flutter/ffprobe_kit.dart";
import "package:flutter/services.dart";
import "package:photos/utils/ffprobe_util.dart";

class IsolatedFfmpegService {
  IsolatedFfmpegService._privateConstructor();

  static final IsolatedFfmpegService instance =
      IsolatedFfmpegService._privateConstructor();

  /// Flag to indicate if operations should be cancelled
  bool _isCancelled = false;

  /// Cancels all running FFmpeg sessions and marks the service as cancelled
  Future<void> cancelAll() async {
    _isCancelled = true;
    await FFmpegKit.cancel();
  }

  /// Resets the cancelled state to allow new operations
  void reset() {
    _isCancelled = false;
  }

  /// Returns true if the service has been cancelled
  bool get isCancelled => _isCancelled;

  Future<Map> runFfmpeg(String command) async {
    if (_isCancelled) {
      return {"returnCode": 255, "output": "Operation cancelled"};
    }
    final rootIsolateToken = RootIsolateToken.instance!;
    return await Isolate.run<Map>(() => _ffmpegRun(command, rootIsolateToken));
  }

  Future<Map> getVideoInfo(String file) async {
    if (_isCancelled) {
      return {};
    }
    final rootIsolateToken = RootIsolateToken.instance!;
    return await Isolate.run<Map>(() => _getVideoProps(file, rootIsolateToken));
  }
}

@pragma('vm:entry-point')
Future<Map> _getVideoProps(
  String filePath,
  RootIsolateToken rootIsolateToken,
) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  final session = await FFprobeKit.getMediaInformation(filePath);
  final mediaInfo = session.getMediaInformation();

  if (mediaInfo == null) {
    return {};
  }

  final metadata = await FFProbeUtil.getMetadata(mediaInfo);
  return metadata;
}

@pragma('vm:entry-point')
Future<Map> _ffmpegRun(String value, RootIsolateToken rootIsolateToken) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  final session = await FFmpegKit.execute(value, true);
  final returnCode = await session.getReturnCode();
  final output = await session.getOutput();

  return {
    "returnCode": returnCode?.getValue(),
    "output": output,
  };
}
