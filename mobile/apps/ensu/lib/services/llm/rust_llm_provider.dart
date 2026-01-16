import 'dart:async';
import 'dart:io';

import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/src/rust/api/llm.dart' show EngineHandle, ModelHandle;
import 'package:ensu/src/rust/engine/types.dart'
    show EngineConfig, GenerationOptions, ModelConfig, Prompt;
import 'package:ensu/src/rust/frb_generated.dart' show EnsuLlmRust;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

class RustLlmProvider implements LLMProvider {
  final _logger = Logger('RustLlmProvider');
  final _config = Configuration.instance;

  bool _isInitialized = false;
  bool _isReady = false;
  bool _isGenerating = false;

  EngineHandle? _engineHandle;
  ModelHandle? _modelHandle;
  String? _modelsDir;
  String? _customModelsDir;
  ModelInfo? _currentModel;
  String? _customModelUrl;
  ModelInfo? _customModelInfo;
  int? _loadedContextSize;

  final _downloadProgressController =
      StreamController<DownloadProgress>.broadcast();

  bool _downloadCancelled = false;
  http.Client? _httpClient;

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
  String get name => 'Rust LLM';

  @override
  List<ModelInfo> get availableModels {
    _refreshCustomModelInfo();
    final models = <ModelInfo>[_modelInfo];
    if (_customModelInfo != null) {
      models.add(_customModelInfo!);
    }
    return models;
  }

  @override
  ModelInfo? get currentModel => _isReady ? _currentModel : null;

  @override
  ModelInfo get targetModel {
    _refreshCustomModelInfo();
    final useCustom = _config.getUseCustomModel();
    if (useCustom && _customModelInfo != null) {
      return _customModelInfo!;
    }
    return _modelInfo;
  }

  @override
  bool get isReady => _isReady;

  @override
  bool get isGenerating => _isGenerating;

  @override
  Stream<DownloadProgress> get downloadProgress =>
      _downloadProgressController.stream;

  String _modelPathFor(ModelInfo model) {
    if (model.id == _modelInfo.id) {
      return '$_modelsDir/$_modelFilename';
    }
    final filename = model.metadata?['filename']?.toString() ?? 'custom.gguf';
    final hash = model.metadata?['hash']?.toString() ?? model.id;
    return '$_customModelsDir/${hash}_$filename';
  }

  String _modelUrlFor(ModelInfo model) {
    if (model.id == _modelInfo.id) {
      return _modelUrl;
    }
    final url = model.metadata?['url']?.toString();
    if (url == null || url.isEmpty) {
      throw Exception('Custom model URL is missing.');
    }
    return url;
  }

  bool _isCustomModel(ModelInfo model) => model.id != _modelInfo.id;

  int _defaultContextSize() => 8192;

  int _defaultMaxTokens() => 2048;

  int _resolveContextSize(ModelInfo model) {
    if (_isCustomModel(model)) {
      final custom = _config.getCustomModelContextLength();
      if (custom != null && custom > 0) {
        return custom;
      }
    }
    return _defaultContextSize();
  }

  int _resolveMaxTokens(ModelInfo model, int? requested) {
    final custom =
        _isCustomModel(model) ? _config.getCustomModelMaxOutputTokens() : null;
    final resolved = requested ?? custom ?? _defaultMaxTokens();
    final contextSize = _resolveContextSize(model);
    if (resolved > contextSize) {
      return contextSize;
    }
    return resolved;
  }

  @override
  Future<void> initialize() async {
    if (_isInitialized) return;

    final appDir = await getApplicationDocumentsDirectory();
    _modelsDir = '${appDir.path}/models';
    await Directory(_modelsDir!).create(recursive: true);
    _customModelsDir = '$_modelsDir/custom';
    await Directory(_customModelsDir!).create(recursive: true);
    _refreshCustomModelInfo();

    _logger.fine('Rust provider init: loading FRB library');
    await EnsuLlmRust.init();
    _logger.fine('Rust provider init: creating engine');
    _engineHandle = await EnsuLlmRust.instance.api.crateApiLlmInitEngine(
      config: EngineConfig(useGpu: false),
    );
    _logger.fine('Rust provider init: engine ready');

    _isInitialized = true;
    _logger.fine('Rust provider initialized, models dir: $_modelsDir');
  }

  @override
  Future<void> dispose() async {
    if (_modelHandle != null) {
      await EnsuLlmRust.instance.api
          .crateApiLlmUnloadModel(model: _modelHandle!);
      _modelHandle = null;
    }
    _downloadProgressController.close();
    EnsuLlmRust.dispose();
  }

  @override
  Future<bool> isModelInstalled(ModelInfo model) async {
    final file = File(_modelPathFor(model));
    if (!await file.exists()) return false;
    final size = await file.length();
    if (size < _minModelSizeBytes(model)) return false;
    return await _isGgufFile(file);
  }

  @override
  Future<void> ensureModelReady() async {
    final selectedModel = targetModel;
    await _ensureSupportedModel(selectedModel);
    final desiredContextSize = _resolveContextSize(selectedModel);
    if (_isReady && _currentModel?.id == selectedModel.id) {
      if (_loadedContextSize == desiredContextSize) {
        return;
      }
      await unloadModel();
    }

    if (_isReady && _currentModel?.id != selectedModel.id) {
      await unloadModel();
    }

    final modelPath = _modelPathFor(selectedModel);
    final modelFile = File(modelPath);
    final exists = await modelFile.exists();
    final size = exists ? await modelFile.length() : 0;

    _logger.fine(
      'Model path: $modelPath, exists: $exists, size: ${_formatBytes(size)}',
    );

    final isValid =
        exists && size >= _minModelSizeBytes(selectedModel) &&
            await _isGgufFile(modelFile);

    if (!isValid) {
      if (exists) await modelFile.delete();
      await downloadModel(selectedModel);
      return;
    }

    _downloadProgressController.add(const DownloadProgress(
      percent: 100,
      status: 'Loading model...',
    ));

    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await _loadModel(selectedModel);
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

  @override
  void cancelDownload() {
    _downloadCancelled = true;
    _httpClient?.close();
    _httpClient = null;
  }

  @override
  Future<void> downloadModel(ModelInfo model) async {
    await _ensureSupportedModel(model);
    final modelUrl = _normalizeModelUrl(_modelUrlFor(model));

    if (_isCustomModel(model)) {
      _downloadProgressController.add(const DownloadProgress(
        percent: 0,
        status: 'Validating model...',
      ));
      await _validateRemoteModelUrl(modelUrl);
    }

    _logger.fine('Downloading ${model.name}...');
    _downloadCancelled = false;
    _downloadProgressController.add(const DownloadProgress(
      percent: 0,
      status: 'Starting download...',
    ));

    final file = File(_modelPathFor(model));
    await file.parent.create(recursive: true);

    try {
      _httpClient = http.Client();
      final request = http.Request('GET', Uri.parse(modelUrl));
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

      _logger.fine('Model downloaded, validating...');
      await _validateLocalModel(file.path);

      _logger.fine('Model validated, loading...');
      await _loadModel(model);

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
    await _loadModel(model);
  }

  Future<void> _loadModel(ModelInfo model) async {
    await _ensureSupportedModel(model);
    final modelPath = _modelPathFor(model);
    _logger.fine('Loading model from: $modelPath');

    if (_modelHandle != null) {
      await EnsuLlmRust.instance.api
          .crateApiLlmUnloadModel(model: _modelHandle!);
      _modelHandle = null;
    }

    if (await _isIOSSimulator(modelPath)) {
      _logger.severe('iOS Simulator detected - Rust LLM not supported');
      throw Exception('LLM not supported on iOS Simulator. Please use a device.');
    }

    final modelFile = File(modelPath);
    if (!await modelFile.exists()) {
      throw Exception('Model file not found at $modelPath');
    }

    await _validateLocalModel(modelPath);

    final isDebug = kDebugMode;
    final contextSize = _resolveContextSize(model);
    final batchSize = isDebug ? 128 : 512;

    final modelConfig = ModelConfig(
      path: modelPath,
      contextSize: contextSize,
      batchSize: batchSize,
      threads: 2,
      threadsBatch: 2,
      gpuLayers: 0,
    );

    _modelHandle = await EnsuLlmRust.instance.api.crateApiLlmLoadModel(
      engine: _engineHandle!,
      config: modelConfig,
    );

    _currentModel = model;
    _loadedContextSize = contextSize;
    _isReady = true;
    _logger.fine('Model loaded successfully');
  }

  @override
  Future<void> unloadModel() async {
    if (_modelHandle != null) {
      await EnsuLlmRust.instance.api
          .crateApiLlmUnloadModel(model: _modelHandle!);
      _modelHandle = null;
    }
    _isReady = false;
    _currentModel = null;
    _loadedContextSize = null;
  }

  @override
  Future<void> deleteModel(ModelInfo model) async {
    if (_currentModel?.id == model.id) {
      await unloadModel();
    }
    final file = File(_modelPathFor(model));
    if (await file.exists()) {
      await file.delete();
    }
    _logger.fine('Model deleted');
  }

  void _refreshCustomModelInfo() {
    final url = _config.getCustomModelUrl();
    if (url == null || url.trim().isEmpty) {
      _customModelUrl = null;
      _customModelInfo = null;
      return;
    }
    final normalizedUrl = _normalizeModelUrl(url);
    if (_customModelUrl == normalizedUrl && _customModelInfo != null) {
      return;
    }
    _customModelUrl = normalizedUrl;
    _customModelInfo = _buildCustomModelInfo(normalizedUrl);
  }

  ModelInfo? _buildCustomModelInfo(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.pathSegments.isEmpty) return null;
    final filename = uri.pathSegments.last;
    if (filename.isEmpty) return null;

    final name = _formatModelName(filename);
    final hash = _hashUrl(url);

    return ModelInfo(
      id: 'custom-$hash',
      name: name.isEmpty ? 'Custom model' : name,
      size: 'Custom',
      description: 'Custom model from Hugging Face',
      metadata: {
        'url': url,
        'filename': filename,
        'hash': hash,
      },
    );
  }

  int _minModelSizeBytes(ModelInfo model) {
    if (_isCustomModel(model)) {
      return 5 * 1024 * 1024;
    }
    return 100 * 1024 * 1024;
  }

  Future<void> _ensureSupportedModel(ModelInfo model) async {
    final reason = await _unsupportedModelReason(model);
    if (reason != null) {
      throw Exception(reason);
    }
  }

  Future<String?> _unsupportedModelReason(ModelInfo model) async {
    if (!_isCustomModel(model)) return null;

    final file = File(_modelPathFor(model));
    if (!await file.exists()) {
      return null;
    }

    try {
      await _validateLocalModel(file.path);
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  Future<void> _validateLocalModel(String path) async {
    await EnsuLlmRust.instance.api.crateApiLlmValidateModel(path: path);
  }

  Future<bool> _isGgufFile(File file) async {
    try {
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, 4)) {
        bytes.addAll(chunk);
        if (bytes.length >= 4) break;
      }
      if (bytes.length < 4) return false;
      final header = String.fromCharCodes(bytes.take(4));
      return header == 'GGUF';
    } catch (_) {
      return false;
    }
  }

  String _normalizeModelUrl(String url) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) return trimmed;
    if (!_isHuggingFaceHost(uri.host)) return trimmed;

    if (!uri.path.contains('/blob/')) {
      return trimmed;
    }

    final normalizedPath = uri.path.replaceFirst('/blob/', '/resolve/');
    return uri.replace(path: normalizedPath).toString();
  }

  Future<void> _validateRemoteModelUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      throw Exception('Invalid model URL');
    }
    if (!_isHuggingFaceHost(uri.host)) {
      throw Exception('Only Hugging Face URLs are supported');
    }
    if (!uri.path.toLowerCase().endsWith('.gguf')) {
      throw Exception('Model must be a .gguf file');
    }

    await _verifyRemoteGgufHeader(url);
  }

  Future<void> _verifyRemoteGgufHeader(String url) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['Range'] = 'bytes=0-3';
      final response = await client.send(request);

      if (response.statusCode != 200 && response.statusCode != 206) {
        throw Exception('Unable to fetch model header');
      }

      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (bytes.length >= 4) break;
      }

      if (bytes.length < 4) {
        throw Exception('Model header is missing');
      }

      final header = String.fromCharCodes(bytes.take(4));
      if (header != 'GGUF') {
        throw Exception('File is not a GGUF model');
      }
    } finally {
      client.close();
    }
  }

  bool _isHuggingFaceHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'huggingface.co' ||
        lower.endsWith('.huggingface.co') ||
        lower == 'hf.co';
  }

  String _formatModelName(String filename) {
    final base = filename.toLowerCase().endsWith('.gguf')
        ? filename.substring(0, filename.length - 5)
        : filename;
    return base.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  }

  String _hashUrl(String input) {
    var hash = 0x811c9dc5;
    for (final codeUnit in input.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  String _formatPrompt(String prompt, List<LLMMessage>? history) {
    final buffer = StringBuffer();
    buffer.write('You are a helpful assistant. ');

    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        if (msg.isUser) {
          buffer.write('User: ${msg.text}\n');
        } else {
          buffer.write('Assistant: ${msg.text}\n');
        }
      }
    }

    buffer.write('User: $prompt\nAssistant:');
    return buffer.toString();
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    List<LLMImage>? images,
    double? temperature,
    int? maxTokens,
    bool enableTodoTools = false,
    String? todoSessionId,
  }) async* {
    if (!_isReady || _modelHandle == null) {
      yield 'Model not loaded.';
      return;
    }

    if (_isGenerating) {
      yield 'Already generating...';
      return;
    }

    _isGenerating = true;

    try {
      final formattedPrompt = _formatPrompt(prompt, history);
      final model = _currentModel!;
      final resolvedMaxTokens = _resolveMaxTokens(model, maxTokens);
      final options = GenerationOptions(
        temperature: temperature,
        maxTokens: resolvedMaxTokens,
        topK: 40,
        topP: 0.9,
        repeatPenalty: 1.1,
      );

      final stream = EnsuLlmRust.instance.api.crateApiLlmGenerateStream(
        model: _modelHandle!,
        prompt: Prompt(text: formattedPrompt),
        options: options,
      );

      const filterTokens = [
        '<|eot_id|>',
        '<|end_of_text|>',
        '<|begin_of_text|>',
        '<|start_header_id|>',
        '<|end_header_id|>',
        '<eos>',
        'User:',
      ];

      await for (final token in stream) {
        var output = token;
        for (final filter in filterTokens) {
          output = output.replaceAll(filter, '');
        }
        if (output.isNotEmpty) {
          yield output;
        }
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
    List<LLMImage>? images,
    double? temperature,
    int? maxTokens,
    bool enableTodoTools = false,
    String? todoSessionId,
  }) async {
    final buffer = StringBuffer();
    await for (final token in generateStream(
      prompt,
      history: history,
      images: images,
      temperature: temperature,
      maxTokens: maxTokens,
      enableTodoTools: enableTodoTools,
      todoSessionId: todoSessionId,
    )) {
      buffer.write(token);
    }
    return buffer.toString();
  }

  @override
  Future<void> stopGeneration() async {
    if (_modelHandle != null) {
      await EnsuLlmRust.instance.api
          .crateApiLlmStopGeneration(model: _modelHandle!);
    }
  }

  @override
  Future<void> resetContext() async {
    if (_isReady && _modelHandle != null) {
      await EnsuLlmRust.instance.api
          .crateApiLlmResetContext(model: _modelHandle!);
    }
  }

  Future<bool> _isIOSSimulator(String modelPath) async {
    if (!Platform.isIOS) return false;
    try {
      return modelPath.contains('CoreSimulator');
    } catch (_) {
      return modelPath.contains('CoreSimulator');
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
