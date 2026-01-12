import 'dart:async';
import 'dart:io';

import 'package:ensu/services/llm/llm_provider.dart';
import 'package:http/http.dart' as http;
import 'package:llama_cpp_dart/llama_cpp_dart.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// LlamaCpp Provider using llama_cpp_dart
/// Uses Llama 3.2 3B - auto-downloads when needed
class LlamaCppProvider implements LLMProvider {
  final _logger = Logger('LlamaCppProvider');

  bool _isInitialized = false;
  bool _isReady = false;
  bool _isGenerating = false;

  LlamaParent? _llama;
  String? _modelsDir;

  final _downloadProgressController =
      StreamController<DownloadProgress>.broadcast();

  bool _downloadCancelled = false;
  http.Client? _httpClient;

  // Llama 3.2 1B - smaller model for mobile
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
  String get name => 'LlamaCpp';

  @override
  List<ModelInfo> get availableModels => [_modelInfo];

  @override
  ModelInfo? get currentModel => _isReady ? _modelInfo : null;

  @override
  ModelInfo get targetModel => _modelInfo;

  @override
  bool get isReady => _isReady;

  @override
  bool get isGenerating => _isGenerating;

  @override
  Stream<DownloadProgress> get downloadProgress =>
      _downloadProgressController.stream;

  String get _modelPath => '$_modelsDir/$_modelFilename';

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = '${appDir.path}/models';
    await Directory(_modelsDir!).create(recursive: true);

    _isInitialized = true;
    _logger.fine('LlamaCpp provider initialized');

    // Don't auto-load - let user trigger it when sending first message
  }

  @override
  Future<void> dispose() async {
    _llama?.dispose();
    _downloadProgressController.close();
  }

  @override
  Future<bool> isModelInstalled(ModelInfo model) async {
    return await File(_modelPath).exists();
  }

  /// Ensure model is ready - downloads if needed
  @override
  Future<void> ensureModelReady() async {
    if (_isReady) return;

    final modelFile = File(_modelPath);
    final exists = await modelFile.exists();

    _logger.fine('Model path: $_modelPath, exists: $exists');

    if (!exists) {
      await downloadModel(_modelInfo);
    } else {
      // Model exists, just need to load it
      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Loading model...',
      ));

      await _loadModel();

      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Ready',
      ));
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
    _logger.fine('Downloading Llama 3.2 3B...');
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
            status:
                '${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)}',
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

      _logger.fine('Model downloaded, loading...');
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

  Future<void> _loadModel() async {
    try {
      _logger.fine('Loading Llama 3.2 3B from: $_modelPath');

      // Verify model file exists and has size
      final modelFile = File(_modelPath);
      if (!await modelFile.exists()) {
        throw Exception('Model file not found at $_modelPath');
      }
      final fileSize = await modelFile.length();
      _logger.fine('Model file size: ${_formatBytes(fileSize)}');

      if (fileSize < 1000000) {
        // Less than 1MB - probably corrupted/incomplete
        throw Exception(
            'Model file appears incomplete (${_formatBytes(fileSize)})');
      }

      _llama?.dispose();
      _llama = null;

      final modelParams = ModelParams();
      // Start with 0 GPU layers for compatibility, can increase if device supports
      modelParams.nGpuLayers = 0;

      final contextParams = ContextParams();
      // Reduce context for mobile - less memory usage
      contextParams.nCtx = 1024;
      contextParams.nBatch = 256;

      final samplerParams = SamplerParams();
      samplerParams.temp = 0.7;
      samplerParams.topK = 40;
      samplerParams.topP = 0.9;
      samplerParams.penaltyRepeat = 1.1;

      final loadCommand = LlamaLoad(
        path: _modelPath,
        modelParams: modelParams,
        contextParams: contextParams,
        samplingParams: samplerParams,
        format: ChatMLFormat(),
      );

      _logger.fine('Creating LlamaParent...');
      _llama = LlamaParent(loadCommand);

      _logger.fine('Initializing model (this may take a while)...');

      // Add timeout to prevent infinite hang
      await _llama!.init().timeout(
        const Duration(minutes: 5),
        onTimeout: () {
          throw TimeoutException('Model loading timed out after 5 minutes');
        },
      );

      _isReady = true;
      _logger.fine('Model loaded successfully');
    } catch (e, stack) {
      _logger.severe('Failed to load model: $e\n$stack');
      _isReady = false;
      _llama?.dispose();
      _llama = null;
      rethrow;
    }
  }

  @override
  Future<void> unloadModel() async {
    _llama?.dispose();
    _llama = null;
    _isReady = false;
  }

  @override
  Future<void> deleteModel(ModelInfo model) async {
    await unloadModel();
    final file = File(_modelPath);
    if (await file.exists()) {
      await file.delete();
    }
    _logger.fine('Model deleted');
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  }) async* {
    if (!_isReady || _llama == null) {
      yield 'Model not loaded.';
      return;
    }

    if (_isGenerating) {
      yield 'Already generating...';
      return;
    }

    _isGenerating = true;

    try {
      _llama!.sendPrompt(prompt);

      await for (final token in _llama!.stream) {
        yield token;
      }
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
    _llama?.stop();
  }

  @override
  Future<void> resetContext() async {
    if (_isReady) {
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
