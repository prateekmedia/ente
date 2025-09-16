import "dart:async";
import "dart:isolate";

import "package:ffmpeg_kit_flutter/ffmpeg_kit.dart";
import "package:ffmpeg_kit_flutter/ffprobe_kit.dart";
import "package:flutter/services.dart";
import "package:logging/logging.dart";
import "package:photos/utils/ffprobe_util.dart";

class IsolatedFfmpegService {
  IsolatedFfmpegService._privateConstructor();

  static final IsolatedFfmpegService instance =
      IsolatedFfmpegService._privateConstructor();

  final _logger = Logger("IsolatedFfmpegService");
  Isolate? _currentIsolate;

  Future<Map> runFfmpeg(String command) async {
    final rootIsolateToken = RootIsolateToken.instance!;

    try {
      // Store isolate reference for potential cancellation
      final receivePort = ReceivePort();
      _currentIsolate = await Isolate.spawn(
        _ffmpegRunWithPort,
        [command, rootIsolateToken, receivePort.sendPort],
      );

      // Wait for result
      final result = await receivePort.first as Map;
      _currentIsolate = null;
      return result;
    } catch (e) {
      _currentIsolate = null;
      rethrow;
    }
  }

  /// Cancel all ongoing FFmpeg operations
  void cancelAllOperations() {
    _logger.info("Cancelling FFmpeg operations");

    if (_currentIsolate != null) {
      try {
        _currentIsolate!.kill(priority: Isolate.immediate);
        _currentIsolate = null;
        _logger.info("FFmpeg isolate killed");
      } catch (e) {
        _logger.warning("Failed to kill FFmpeg isolate", e);
      }
    }

    // Also cancel any active FFmpeg sessions globally
    FFmpegKit.cancel();
  }

  Future<Map> getVideoInfo(String file) async {
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

@pragma('vm:entry-point')
Future<void> _ffmpegRunWithPort(List<dynamic> args) async {
  final command = args[0] as String;
  final rootIsolateToken = args[1] as RootIsolateToken;
  final sendPort = args[2] as SendPort;

  BackgroundIsolateBinaryMessenger.ensureInitialized(rootIsolateToken);
  final session = await FFmpegKit.execute(command, true);
  final returnCode = await session.getReturnCode();
  final output = await session.getOutput();

  sendPort.send({
    "returnCode": returnCode?.getValue(),
    "output": output,
  });
}
