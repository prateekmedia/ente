import 'dart:async';
import 'dart:io';

import 'package:ensu/services/llm/llm_provider.dart';
import 'package:fllama/fllama.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// FLlama Provider - uses fllama package with pre-built binaries
class FllamaProvider implements LLMProvider {
  final _logger = Logger('FllamaProvider');

  bool _isInitialized = false;
  bool _isReady = false;
  bool _isGenerating = false;

  double? _contextId;
  String? _modelsDir;

  final _downloadProgressController = StreamController<DownloadProgress>.broadcast();

  bool _downloadCancelled = false;
  http.Client? _httpClient;
  StreamSubscription? _tokenStreamSubscription;

  // Llama 3.2 1B - optimized for mobile
  static const _modelUrl =
      'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf';
  static const _modelFilename = 'Llama-3.2-1B-Instruct-Q4_K_M.gguf';
  static const _modelInfo = ModelInfo(
    id: 'llama-3.2-1b',
    name: 'Llama 3.2 1B',
    size: '0.75 GB',
    description: 'Meta\'s latest, optimized for mobile',
  );

  @override
  String get name => 'FLlama';

  @override
  List<ModelInfo> get availableModels => [_modelInfo];

  @override
  ModelInfo? get currentModel => _isReady ? _modelInfo : null;

  @override
  bool get isReady => _isReady;

  @override
  bool get isGenerating => _isGenerating;

  @override
  Stream<DownloadProgress> get downloadProgress => _downloadProgressController.stream;

  String get _modelPath => '$_modelsDir/$_modelFilename';

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = '${appDir.path}/models';
    await Directory(_modelsDir!).create(recursive: true);

    _isInitialized = true;
    _logger.info('FLlama provider initialized, models dir: $_modelsDir');
  }

  @override
  Future<void> dispose() async {
    _tokenStreamSubscription?.cancel();
    if (_contextId != null) {
      await Fllama.instance()?.releaseContext(_contextId!);
    }
    _downloadProgressController.close();
  }

  @override
  Future<bool> isModelInstalled(ModelInfo model) async {
    final file = File(_modelPath);
    if (!await file.exists()) return false;
    final size = await file.length();
    return size > 100 * 1024 * 1024; // > 100MB means probably valid
  }

  /// Ensure model is ready - downloads if needed
  @override
  Future<void> ensureModelReady() async {
    if (_isReady) return;

    final modelFile = File(_modelPath);
    final exists = await modelFile.exists();
    final size = exists ? await modelFile.length() : 0;

    _logger.info('Model path: $_modelPath, exists: $exists, size: ${_formatBytes(size)}');

    if (!exists || size < 100 * 1024 * 1024) {
      // Download if missing or too small
      if (exists) await modelFile.delete();
      await downloadModel(_modelInfo);
    } else {
      // Model exists, just need to load it
      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Loading model...',
      ));

      // Small delay to let UI update
      await Future.delayed(const Duration(milliseconds: 100));

      try {
        await _loadModel();
        _downloadProgressController.add(const DownloadProgress(
          percent: 100,
          status: 'Ready',
        ));
      } catch (e) {
        _logger.severe('Model load failed: $e');
        _downloadProgressController.add(DownloadProgress(
          percent: -1,
          status: 'Load failed: $e',
        ));
        rethrow;
      }
    }
  }

  /// Cancel ongoing download
  @override
  void cancelDownload() {
    _downloadCancelled = true;
    _httpClient?.close();
    _httpClient = null;
  }

  @override
  Future<void> downloadModel(ModelInfo model) async {
    _logger.info('Downloading Llama 3.2 1B...');
    _downloadCancelled = false;
    _downloadProgressController.add(const DownloadProgress(
      percent: 0,
      status: 'Starting download...',
    ));

    final file = File(_modelPath);

    try {
      _httpClient = http.Client();
      final request = http.Request('GET', Uri.parse(_modelUrl));
      final response = await _httpClient!.send(request);

      if (response.statusCode != 200) {
        throw Exception('Download failed: HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength ?? 0;
      var downloadedBytes = 0;

      final sink = file.openWrite();

      await for (final chunk in response.stream) {
        if (_downloadCancelled) {
          await sink.close();
          if (await file.exists()) {
            await file.delete();
          }
          _downloadProgressController.add(const DownloadProgress(
            percent: -1,
            status: 'Cancelled',
          ));
          return;
        }

        sink.add(chunk);
        downloadedBytes += chunk.length;

        if (totalBytes > 0) {
          final percent = ((downloadedBytes / totalBytes) * 100).round();
          _downloadProgressController.add(DownloadProgress(
            percent: percent,
            bytesDownloaded: downloadedBytes,
            totalBytes: totalBytes,
            status: '${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)}',
          ));
        }
      }

      await sink.close();
      _httpClient = null;

      if (_downloadCancelled) {
        if (await file.exists()) {
          await file.delete();
        }
        return;
      }

      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Loading model...',
      ));

      _logger.info('Model downloaded, loading...');
      await _loadModel();

      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Ready',
      ));
    } catch (e) {
      _logger.severe('Download failed', e);
      _httpClient = null;
      if (await file.exists()) {
        await file.delete();
      }
      if (!_downloadCancelled) {
        _downloadProgressController.add(DownloadProgress(
          percent: -1,
          status: 'Error: $e',
        ));
        rethrow;
      }
    }
  }

  @override
  Future<void> loadModel(ModelInfo model) async {
    await _loadModel();
  }

  /// Check if running on iOS simulator
  Future<bool> _isIOSSimulator() async {
    if (!Platform.isIOS) return false;
    try {
      // Check for simulator by looking at the device model
      final deviceInfo = await Fllama.instance()?.getCpuInfo();
      _logger.info('Device info: $deviceInfo');
      // Simulator typically has x86_64 or arm64 on Apple Silicon Mac
      // But we can also check the path - simulator paths contain "CoreSimulator"
      return _modelPath.contains('CoreSimulator');
    } catch (e) {
      // If we can't determine, check path
      return _modelPath.contains('CoreSimulator');
    }
  }

  Future<void> _loadModel() async {
    try {
      _logger.info('Loading model from: $_modelPath');

      // Check if running on iOS simulator - fllama doesn't support it
      if (await _isIOSSimulator()) {
        _logger.severe('iOS Simulator detected - fllama is not supported');
        throw Exception('LLM not supported on iOS Simulator. Please use a physical device.');
      }

      // Verify model file exists
      final modelFile = File(_modelPath);
      if (!await modelFile.exists()) {
        throw Exception('Model file not found at $_modelPath');
      }
      final fileSize = await modelFile.length();
      _logger.info('Model file size: ${_formatBytes(fileSize)}');

      // Release existing context if any
      if (_contextId != null) {
        try {
          await Fllama.instance()?.releaseContext(_contextId!);
        } catch (e) {
          _logger.warning('Failed to release previous context: $e');
        }
        _contextId = null;
      }

      // Listen for load progress
      _tokenStreamSubscription?.cancel();
      _tokenStreamSubscription = Fllama.instance()?.onTokenStream?.listen((data) {
        _logger.fine('Token stream event: $data');
        if (data['function'] == 'loadProgress') {
          // Progress can be int (0-100) or double (0.0-1.0)
          final rawProgress = data['result'];
          int percent;
          if (rawProgress is int) {
            percent = rawProgress;
          } else if (rawProgress is double) {
            percent = (rawProgress * 100).round();
          } else {
            percent = 0;
          }
          _downloadProgressController.add(DownloadProgress(
            percent: percent.clamp(0, 100),
            status: 'Loading model...',
          ));
        }
      });

      // Check CPU info
      try {
        final cpuInfo = await Fllama.instance()?.getCpuInfo();
        _logger.info('CPU info: $cpuInfo');
      } catch (e) {
        _logger.warning('Could not get CPU info: $e');
      }

      // Use smaller context for simulator/debug to avoid memory issues
      final isSimulatorOrDebug = kDebugMode;
      final contextSize = isSimulatorOrDebug ? 512 : 2048;
      final batchSize = isSimulatorOrDebug ? 128 : 512;
      
      _logger.info('Initializing context (ctx=$contextSize, batch=$batchSize, debug=$isSimulatorOrDebug)...');

      // Initialize context with conservative settings for mobile
      Map<Object?, dynamic>? result;
      try {
        result = await Fllama.instance()?.initContext(
          _modelPath,
          nCtx: contextSize,
          nBatch: batchSize,
          nThreads: 2, // Fewer threads for stability
          nGpuLayers: 0, // CPU only for compatibility
          useMlock: false,
          useMmap: true,
          emitLoadProgress: true,
        );
      } catch (e, stack) {
        _logger.severe('initContext threw exception: $e\n$stack');
        rethrow;
      }

      _logger.info('initContext returned: $result');

      if (result == null || result['contextId'] == null) {
        throw Exception('Failed to initialize model context: result=$result');
      }

      _contextId = double.parse(result['contextId'].toString());
      _logger.info('Model loaded successfully, contextId: $_contextId');

      _isReady = true;
    } catch (e, stack) {
      _logger.severe('Failed to load model: $e\n$stack');
      _isReady = false;
      _contextId = null;
      rethrow;
    }
  }

  @override
  Future<void> unloadModel() async {
    if (_contextId != null) {
      await Fllama.instance()?.releaseContext(_contextId!);
      _contextId = null;
    }
    _isReady = false;
  }

  @override
  Future<void> deleteModel(ModelInfo model) async {
    await unloadModel();
    final file = File(_modelPath);
    if (await file.exists()) {
      await file.delete();
    }
    _logger.info('Model deleted');
  }

  /// Format prompt - simple format that works with most models
  String _formatPrompt(String prompt, List<LLMMessage>? history) {
    final buffer = StringBuffer();
    
    // Simple conversational format
    buffer.write('You are a helpful assistant. ');
    
    // History
    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        if (msg.isUser) {
          buffer.write('User: ${msg.text}\n');
        } else {
          buffer.write('Assistant: ${msg.text}\n');
        }
      }
    }
    
    // Current user message
    buffer.write('User: $prompt\nAssistant:');
    
    return buffer.toString();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  }) async* {
    if (!_isReady || _contextId == null) {
      yield 'Model not loaded.';
      return;
    }

    if (_isGenerating) {
      yield 'Already generating...';
      return;
    }

    _isGenerating = true;

    try {
      // Format prompt manually (getFormattedChat has issues on Android)
      final formattedPrompt = _formatPrompt(prompt, history);
      _logger.fine('Formatted prompt: $formattedPrompt');

      // Set up streaming listener
      final completer = Completer<void>();
      final tokenController = StreamController<String>();
      var isTokenStreamClosed = false;

      Future<void> closeTokenStream() async {
        if (isTokenStreamClosed) return;
        isTokenStreamClosed = true;
        await _tokenStreamSubscription?.cancel();
        _tokenStreamSubscription = null;
        await tokenController.close();
      }
      
      // Tokens to filter out from output
      final filterTokens = [
        '<|eot_id|>',
        '<|end_of_text|>',
        '<|begin_of_text|>',
        '<|start_header_id|>',
        '<|end_header_id|>',
        '<eos>',
        'User:',
      ];
      
      _tokenStreamSubscription = Fllama.instance()?.onTokenStream?.listen((data) {
        _logger.fine('Stream event: $data');
        if (data['function'] == 'completion') {
          final result = data['result'];
          if (result is Map) {
            var token = result['token']?.toString() ?? '';
            
            // Filter out special tokens
            for (final filter in filterTokens) {
              token = token.replaceAll(filter, '');
            }
            
            if (token.isNotEmpty && !isTokenStreamClosed) {
              tokenController.add(token);
            }
          }
        }
      });

      final completionFuture = completer.future
          .timeout(const Duration(minutes: 2))
          .catchError((e) {
            _logger.warning('Completion timeout or error: $e');
          })
          .whenComplete(() async {
            await closeTokenStream();
          });

      // Start completion
      Fllama.instance()
          ?.completion(
        _contextId!,
        prompt: formattedPrompt,
        temperature: temperature ?? 0.7,
        nPredict: maxTokens ?? 256,
        topK: 40,
        topP: 0.9,
        penaltyRepeat: 1.1,
        emitRealtimeCompletion: true,
        stop: ['User:', '\nUser', '<eos>', '<|eot_id|>', '<|end_of_text|>'],
      )
          .then((result) {
        _logger.info('Completion finished: $result');
        if (!completer.isCompleted) {
          completer.complete();
        }
      }).catchError((e) {
        _logger.severe('Completion error: $e');
        if (!completer.isCompleted) {
          completer.completeError(e);
        }
      });

      // Yield tokens as they come
      try {
        await for (final token in tokenController.stream) {
          yield token;
        }
      } catch (e) {
        _logger.warning('Token stream error: $e');
      }

      await completionFuture;
    } catch (e) {
      _logger.severe('Generation error', e);
      yield '\n\nError: $e';
    } finally {
      _isGenerating = false;
    }
  }

  @override
  Future<String> generate(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  }) async {
    final buffer = StringBuffer();
    await for (final token in generateStream(prompt, history: history)) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  @override
  Future<void> stopGeneration() async {
    if (_contextId != null) {
      await Fllama.instance()?.stopCompletion(contextId: _contextId!);
    }
  }

  @override
  Future<void> resetContext() async {
    if (_isReady && _contextId != null) {
      // Reload the model to reset context
      await _loadModel();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
