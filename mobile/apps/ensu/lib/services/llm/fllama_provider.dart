import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/services/llm/assistant_tool_feature.dart';
import 'package:ensu/services/llm/assistant_tool_registry.dart';
import 'package:ensu/services/llm/tool_call_parser.dart';
import 'package:fllama/fllama.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

void _fllamaLog(String log) {
  if (!kDebugMode) {
    return;
  }

  final trimmed = log.trim();
  if (trimmed.isEmpty) {
    return;
  }
  if (trimmed.contains('<unused') || trimmed.contains('ggml_')) {
    return;
  }

  print('[fllama] $trimmed');
}

/// FLlama Provider - uses fllama package with pre-built binaries
class FllamaProvider implements LLMProvider {
  final _logger = Logger('FllamaProvider');
  final _config = Configuration.instance;

  bool _isInitialized = false;
  bool _isReady = false;
  bool _isGenerating = false;

  int? _activeRequestId;
  int? _warmupRequestId;
  int? _loadedContextSize;
  int? _loadedGpuLayers;
  String? _modelsDir;
  String? _customModelsDir;
  ModelInfo? _currentModel;
  String? _customModelUrl;
  String? _customMmprojUrl;
  ModelInfo? _customModelInfo;

  final _downloadProgressController =
      StreamController<DownloadProgress>.broadcast();

  bool _downloadCancelled = false;
  http.Client? _httpClient;

  // LFM 2.5 VL 1.6B - multimodal (requires mmproj)
  static const _modelUrl =
      'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q4_0.gguf';
  static const _modelFilename = 'LFM2.5-VL-1.6B-Q4_0.gguf';
  static const _modelInfo = ModelInfo(
    id: 'lfm-2.5-vl-1.6b',
    name: 'LFM 2.5 VL 1.6B',
    size: '1.28 GB',
    description: 'LiquidAI\'s multimodal model (vision + text)',
  );

  static const _lfmVlMmprojUrl =
      'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-Q8_0.gguf';

  static const _qwen3VlMmprojUrl =
      'https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf';

  @override
  String get name => 'FLlama';

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

  String? _filenameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.pathSegments.isEmpty) return null;
    final filename = uri.pathSegments.last;
    if (filename.isEmpty) return null;
    return filename;
  }

  String? _inferMmprojUrlFromModelUrl(String modelUrl) {
    final normalized = _normalizeModelUrl(modelUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null) return null;
    if (!_isHuggingFaceHost(uri.host)) return null;

    final segments = uri.pathSegments;
    if (segments.length < 2) return null;

    final owner = segments[0].toLowerCase();
    final repo = segments[1].toLowerCase();

    if (owner == 'liquidai' && repo == 'lfm2.5-vl-1.6b-gguf') {
      final filename = segments.isNotEmpty ? segments.last.toLowerCase() : '';
      if (filename.startsWith('mmproj-')) return null;
      if (!filename.endsWith('.gguf')) return null;
      return _lfmVlMmprojUrl;
    }

    if (owner == 'qwen' && repo == 'qwen3-vl-2b-instruct-gguf') {
      final filename = segments.isNotEmpty ? segments.last.toLowerCase() : '';
      if (filename.startsWith('mmproj-')) return null;
      if (!filename.endsWith('.gguf')) return null;
      return _qwen3VlMmprojUrl;
    }

    return null;
  }

  String? _mmprojUrlFor(ModelInfo model) {
    final fromMetadata = model.metadata?['mmprojUrl']?.toString();
    if (fromMetadata != null && fromMetadata.trim().isNotEmpty) {
      return _normalizeModelUrl(fromMetadata);
    }

    final modelUrl = model.id == _modelInfo.id
        ? _modelUrlFor(model)
        : model.metadata?['url']?.toString();
    if (modelUrl == null || modelUrl.trim().isEmpty) {
      return null;
    }

    return _inferMmprojUrlFromModelUrl(modelUrl);
  }

  String? _mmprojPathFor(ModelInfo model) {
    final mmprojUrl = _mmprojUrlFor(model);
    if (mmprojUrl == null || mmprojUrl.trim().isEmpty) {
      return null;
    }

    final filename = _filenameFromUrl(mmprojUrl) ?? 'mmproj.gguf';
    if (model.id == _modelInfo.id) {
      return '$_modelsDir/$filename';
    }

    final hash = model.metadata?['hash']?.toString() ?? model.id;
    return '$_customModelsDir/${hash}_$filename';
  }

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

    _isInitialized = true;
    _logger.fine('FLlama provider initialized, models dir: $_modelsDir');
  }

  @override
  Future<void> dispose() async {
    await stopGeneration();
    _downloadProgressController.close();
  }

  @override
  Future<bool> isModelInstalled(ModelInfo model) async {
    final file = File(_modelPathFor(model));
    if (!await file.exists()) return false;
    final size = await file.length();
    if (size < _minModelSizeBytes(model)) return false;
    if (!await _isGgufFile(file)) return false;

    final mmprojPath = _mmprojPathFor(model);
    if (mmprojPath == null) {
      return true;
    }

    final mmprojFile = File(mmprojPath);
    if (!await mmprojFile.exists()) return false;
    final mmprojSize = await mmprojFile.length();
    if (mmprojSize < _minMmprojSizeBytes(model)) return false;
    return await _isGgufFile(mmprojFile);
  }

  /// Ensure model is ready - downloads if needed
  @override
  Future<void> ensureModelReady() async {
    _downloadCancelled = false;

    final selectedModel = targetModel;
    if (_isReady && _currentModel?.id == selectedModel.id) return;

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

    final isValid = exists &&
        size >= _minModelSizeBytes(selectedModel) &&
        await _isGgufFile(modelFile);

    final mmprojPath = _mmprojPathFor(selectedModel);
    var isMmprojValid = true;

    if (mmprojPath != null) {
      final mmprojFile = File(mmprojPath);
      final mmprojExists = await mmprojFile.exists();
      final mmprojSize = mmprojExists ? await mmprojFile.length() : 0;

      _logger.fine(
        'mmproj path: $mmprojPath, exists: $mmprojExists, size: ${_formatBytes(mmprojSize)}',
      );

      isMmprojValid = mmprojExists &&
          mmprojSize >= _minMmprojSizeBytes(selectedModel) &&
          await _isGgufFile(mmprojFile);

      if (!isMmprojValid && mmprojExists) {
        await mmprojFile.delete();
      }
    }

    if (!isValid || !isMmprojValid) {
      if (!isValid && exists) {
        await modelFile.delete();
      }
      await downloadModel(selectedModel);
      return;
    }

    // Model exists, just need to load it
    _downloadProgressController.add(const DownloadProgress(
      percent: 100,
      status: 'Loading model...',
    ));

    // Small delay to let UI update
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

  /// Cancel ongoing download
  @override
  void cancelDownload() {
    _downloadCancelled = true;
    _httpClient?.close();
    _httpClient = null;

    final warmupRequestId = _warmupRequestId;
    if (warmupRequestId != null) {
      fllamaCancelInference(warmupRequestId);
    }
  }

  @override
  Future<void> downloadModel(ModelInfo model) async {
    final modelUrl = _normalizeModelUrl(_modelUrlFor(model));
    _downloadCancelled = false;
    final rawMmprojUrl = _mmprojUrlFor(model);
    final mmprojUrl = rawMmprojUrl == null || rawMmprojUrl.trim().isEmpty
        ? null
        : _normalizeModelUrl(rawMmprojUrl);
    final mmprojPath = mmprojUrl == null ? null : _mmprojPathFor(model);

    final artifacts = <({
      String label,
      String url,
      String path,
      int minSizeBytes,
    })>[
      (
        label: 'model',
        url: modelUrl,
        path: _modelPathFor(model),
        minSizeBytes: _minModelSizeBytes(model),
      ),
      if (mmprojUrl != null && mmprojPath != null)
        (
          label: 'mmproj',
          url: mmprojUrl,
          path: mmprojPath,
          minSizeBytes: _minMmprojSizeBytes(model),
        ),
    ];

    final toDownload = <({
      String label,
      String url,
      String path,
      int minSizeBytes,
    })>[];

    for (final artifact in artifacts) {
      final file = File(artifact.path);
      final exists = await file.exists();
      final size = exists ? await file.length() : 0;
      final isValid =
          exists && size >= artifact.minSizeBytes && await _isGgufFile(file);

      if (isValid) {
        continue;
      }

      if (exists) {
        await file.delete();
      }
      toDownload.add(artifact);
    }

    if (toDownload.isEmpty) {
      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Loading model...',
      ));
      await Future.delayed(const Duration(milliseconds: 100));
      await _loadModel(model);
      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Ready',
      ));
      return;
    }

    final totalFiles = toDownload.length;
    final fileSizes = <String, int>{};

    if (_isCustomModel(model)) {
      _downloadProgressController.add(const DownloadProgress(
        percent: 0,
        status: 'Validating model...',
      ));

      for (final artifact in toDownload) {
        if (_downloadCancelled) {
          _downloadProgressController.add(const DownloadProgress(
            percent: -1,
            status: 'Cancelled',
          ));
          return;
        }

        final size = await _validateRemoteModelUrl(artifact.url);
        if (size != null && size > 0) {
          fileSizes[artifact.url] = size;
        }
      }
    }

    final totalBytes = fileSizes.length == totalFiles
        ? fileSizes.values.fold(0, (sum, size) => sum + size)
        : 0;

    _logger.fine('Downloading ${model.name}...');
    _downloadCancelled = false;
    _downloadProgressController.add(const DownloadProgress(
      percent: 0,
      status: 'Starting download...',
    ));

    for (final artifact in toDownload) {
      final file = File(artifact.path);
      await file.parent.create(recursive: true);
    }

    var overallDownloaded = 0;

    try {
      for (var index = 0; index < toDownload.length; index++) {
        final artifact = toDownload[index];
        if (_downloadCancelled) {
          _httpClient?.close();
          _httpClient = null;
          _downloadProgressController.add(const DownloadProgress(
            percent: -1,
            status: 'Cancelled',
          ));
          return;
        }

        final file = File(artifact.path);

        _httpClient?.close();
        _httpClient = http.Client();

        final request = http.Request('GET', Uri.parse(artifact.url));
        final response = await _httpClient!.send(request);

        if (response.statusCode != 200) {
          throw Exception('Download failed: HTTP ${response.statusCode}');
        }

        final fileTotalBytes = response.contentLength ?? 0;
        var fileDownloaded = 0;

        final sink = file.openWrite();
        var cancelled = false;

        try {
          await for (final chunk in response.stream) {
            if (_downloadCancelled) {
              cancelled = true;
              break;
            }

            sink.add(chunk);
            fileDownloaded += chunk.length;
            overallDownloaded += chunk.length;

            final percent = totalBytes > 0
                ? ((overallDownloaded / totalBytes) * 100).round()
                : (() {
                    final fileProgress = fileTotalBytes > 0
                        ? fileDownloaded / fileTotalBytes
                        : 0.0;
                    final overallProgress = (index + fileProgress) / totalFiles;
                    return (overallProgress * 100).round();
                  })();

            final status = totalBytes > 0
                ? 'Downloading ${artifact.label} (${index + 1}/$totalFiles)... ${_formatBytes(overallDownloaded)} / ${_formatBytes(totalBytes)}'
                : fileTotalBytes > 0
                    ? 'Downloading ${artifact.label} (${index + 1}/$totalFiles)... ${_formatBytes(fileDownloaded)} / ${_formatBytes(fileTotalBytes)}'
                    : 'Downloading ${artifact.label} (${index + 1}/$totalFiles)... ${_formatBytes(fileDownloaded)}';

            _downloadProgressController.add(DownloadProgress(
              percent: percent.clamp(0, 99).toInt(),
              bytesDownloaded: totalBytes > 0 ? overallDownloaded : null,
              totalBytes: totalBytes > 0 ? totalBytes : null,
              status: status,
            ));
          }
        } finally {
          await sink.close();
        }

        if (cancelled) {
          if (await file.exists()) {
            await file.delete();
          }
          _httpClient?.close();
          _httpClient = null;
          _downloadProgressController.add(const DownloadProgress(
            percent: -1,
            status: 'Cancelled',
          ));
          return;
        }

        if (!await _isGgufFile(file)) {
          await file.delete();
          throw Exception(
              'Downloaded ${artifact.label} is not a valid GGUF model');
        }
      }

      _httpClient?.close();
      _httpClient = null;

      if (_downloadCancelled) {
        return;
      }

      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Loading model...',
      ));

      _logger.fine('Model downloaded, loading...');
      await _loadModel(model);

      _downloadProgressController.add(const DownloadProgress(
        percent: 100,
        status: 'Ready',
      ));
    } catch (e) {
      _logger.severe('Download failed', e);
      _httpClient?.close();
      _httpClient = null;

      if (_downloadCancelled) {
        _downloadProgressController.add(const DownloadProgress(
          percent: -1,
          status: 'Cancelled',
        ));
        return;
      }

      _downloadProgressController.add(DownloadProgress(
        percent: -1,
        status: 'Error: $e',
      ));
      rethrow;
    }
  }

  @override
  Future<void> loadModel(ModelInfo model) async {
    await _loadModel(model);
  }

  /// Check if running on iOS simulator
  Future<bool> _isIOSSimulator(String modelPath) async {
    if (!Platform.isIOS) return false;
    return modelPath.contains('CoreSimulator');
  }

  bool _warmupOutputIndicatesFailure(String output) {
    final trimmed = output.trim();
    if (trimmed.isEmpty) return true;
    if (trimmed.startsWith('Error:')) return true;
    return fllamaOutputIndicatesLoadError(trimmed);
  }

  Future<String> _runWarmup({
    required ModelInfo model,
    required int contextSize,
    required int numGpuLayers,
  }) async {
    final completer = Completer<String>();
    var lastResponse = '';

    void callback(String response, String responseJson, bool done) {
      lastResponse = response;
      if (done && !completer.isCompleted) {
        completer.complete(lastResponse);
      }
    }

    final request = OpenAiRequest(
      messages: [
        Message(Role.system, 'You are a helpful assistant.'),
        Message(Role.user, 'Say "OK".'),
      ],
      modelPath: _modelPathFor(model),
      mmprojPath: _mmprojPathFor(model),
      maxTokens: 4,
      temperature: 0,
      topP: 1.0,
      frequencyPenalty: 0.0,
      presencePenalty: 1.1,
      numGpuLayers: numGpuLayers,
      contextSize: contextSize,
      logger: kDebugMode ? _fllamaLog : null,
    );

    final requestId = await fllamaChat(request, callback);
    _warmupRequestId = requestId;

    try {
      final output = await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          fllamaCancelInference(requestId);
          throw TimeoutException('Model warm-up timed out.');
        },
      );

      if (_downloadCancelled) {
        throw Exception('Cancelled');
      }

      return output;
    } finally {
      if (_warmupRequestId == requestId) {
        _warmupRequestId = null;
      }
    }
  }

  List<int> _buildContextCandidates(int desired) {
    final candidates = <int>[desired];
    const fallbacks = [4096, 2048, 1024];

    for (final fallback in fallbacks) {
      if (fallback < desired) {
        candidates.add(fallback);
      }
    }

    final unique = <int>[];
    for (final candidate in candidates) {
      if (candidate <= 0) continue;
      if (unique.contains(candidate)) continue;
      unique.add(candidate);
    }
    return unique;
  }

  Future<void> _loadModel(ModelInfo model) async {
    try {
      final modelPath = _modelPathFor(model);
      _logger.fine('Preparing model from: $modelPath');

      // Check if running on iOS simulator - fllama doesn't support it
      if (await _isIOSSimulator(modelPath)) {
        _logger.severe('iOS Simulator detected - fllama is not supported');
        throw Exception(
            'LLM not supported on iOS Simulator. Please use a physical device.');
      }

      // Verify model file exists
      final modelFile = File(modelPath);
      if (!await modelFile.exists()) {
        throw Exception('Model file not found at $modelPath');
      }
      final fileSize = await modelFile.length();
      _logger.fine('Model file size: ${_formatBytes(fileSize)}');

      if (fileSize < _minModelSizeBytes(model)) {
        throw Exception(
            'Model file appears incomplete (${_formatBytes(fileSize)})');
      }

      if (!await _isGgufFile(modelFile)) {
        throw Exception('Model file is not a valid GGUF model');
      }

      final mmprojPath = _mmprojPathFor(model);
      if (mmprojPath != null) {
        final mmprojFile = File(mmprojPath);
        if (!await mmprojFile.exists()) {
          throw Exception('mmproj file not found at $mmprojPath');
        }

        final mmprojSize = await mmprojFile.length();
        _logger.fine('mmproj file size: ${_formatBytes(mmprojSize)}');

        if (mmprojSize < _minMmprojSizeBytes(model)) {
          throw Exception(
              'mmproj file appears incomplete (${_formatBytes(mmprojSize)})');
        }

        if (!await _isGgufFile(mmprojFile)) {
          throw Exception('mmproj file is not a valid GGUF model');
        }
      }

      try {
        await fllamaChatTemplateGet(modelPath);
      } catch (e) {
        _logger.warning('Could not read chat template: $e');
      }

      _isReady = false;
      _currentModel = null;
      _loadedContextSize = null;
      _loadedGpuLayers = null;

      final desiredContextSize = _resolveContextSize(model);
      final contextCandidates = _buildContextCandidates(desiredContextSize);
      final gpuCandidates = Platform.isAndroid ? const [0] : const [99, 0];

      String? lastFailure;
      int? selectedContext;
      int? selectedGpu;

      for (final gpuLayers in gpuCandidates) {
        for (final contextSize in contextCandidates) {
          if (_downloadCancelled) {
            throw Exception('Cancelled');
          }

          _logger.fine(
            'Warming up model (context=$contextSize, gpuLayers=$gpuLayers)...',
          );

          final output = await _runWarmup(
            model: model,
            contextSize: contextSize,
            numGpuLayers: gpuLayers,
          );

          if (!_warmupOutputIndicatesFailure(output)) {
            selectedContext = contextSize;
            selectedGpu = gpuLayers;
            break;
          }

          lastFailure = output.trim();
          _logger.warning(
            'Model warm-up failed (context=$contextSize, gpuLayers=$gpuLayers): $lastFailure',
          );
        }

        if (selectedContext != null && selectedGpu != null) {
          break;
        }
      }

      if (selectedContext == null || selectedGpu == null) {
        final failure = lastFailure ?? 'Model warm-up failed.';
        throw Exception(failure);
      }

      _currentModel = model;
      _loadedContextSize = selectedContext;
      _loadedGpuLayers = selectedGpu;
      _isReady = true;
      _logger.fine(
        'Model ready for inference (context=$selectedContext, gpuLayers=$selectedGpu)',
      );
    } catch (e, stack) {
      _logger.severe('Failed to prepare model: $e\n$stack');
      _isReady = false;
      _currentModel = null;
      _loadedContextSize = null;
      _loadedGpuLayers = null;
      rethrow;
    }
  }

  @override
  Future<void> unloadModel() async {
    await stopGeneration();
    final warmupRequestId = _warmupRequestId;
    if (warmupRequestId != null) {
      fllamaCancelInference(warmupRequestId);
    }
    _isReady = false;
    _currentModel = null;
    _activeRequestId = null;
    _warmupRequestId = null;
    _loadedContextSize = null;
    _loadedGpuLayers = null;
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

    final mmprojPath = _mmprojPathFor(model);
    if (mmprojPath != null) {
      final mmprojFile = File(mmprojPath);
      if (await mmprojFile.exists()) {
        await mmprojFile.delete();
      }
    }

    _logger.fine('Model deleted');
  }

  void _refreshCustomModelInfo() {
    final url = _config.getCustomModelUrl();
    if (url == null || url.trim().isEmpty) {
      _customModelUrl = null;
      _customMmprojUrl = null;
      _customModelInfo = null;
      return;
    }

    final normalizedUrl = _normalizeModelUrl(url);

    final rawMmprojUrl = _config.getCustomMmprojUrl();
    final normalizedMmprojUrl =
        rawMmprojUrl == null || rawMmprojUrl.trim().isEmpty
            ? null
            : _normalizeModelUrl(rawMmprojUrl);

    final resolvedMmprojUrl =
        normalizedMmprojUrl ?? _inferMmprojUrlFromModelUrl(normalizedUrl);

    if (_customModelUrl == normalizedUrl &&
        _customMmprojUrl == resolvedMmprojUrl &&
        _customModelInfo != null) {
      return;
    }

    _customModelUrl = normalizedUrl;
    _customMmprojUrl = resolvedMmprojUrl;
    _customModelInfo = _buildCustomModelInfo(
      normalizedUrl,
      mmprojUrl: resolvedMmprojUrl,
    );
  }

  ModelInfo? _buildCustomModelInfo(String url, {String? mmprojUrl}) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    if (uri.pathSegments.isEmpty) return null;
    final filename = uri.pathSegments.last;
    if (filename.isEmpty) return null;

    final normalizedMmprojUrl = mmprojUrl == null || mmprojUrl.trim().isEmpty
        ? null
        : _normalizeModelUrl(mmprojUrl);

    final mmprojFilename = normalizedMmprojUrl == null
        ? null
        : _filenameFromUrl(normalizedMmprojUrl);

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
        if (normalizedMmprojUrl != null) 'mmprojUrl': normalizedMmprojUrl,
        if (mmprojFilename != null) 'mmprojFilename': mmprojFilename,
      },
    );
  }

  int _minModelSizeBytes(ModelInfo model) {
    if (_isCustomModel(model)) {
      return 5 * 1024 * 1024;
    }
    return 100 * 1024 * 1024;
  }

  int _minMmprojSizeBytes(ModelInfo model) {
    if (_isCustomModel(model)) {
      return 1 * 1024 * 1024;
    }
    return 1 * 1024 * 1024;
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
    } catch (e) {
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

  Future<int?> _validateRemoteModelUrl(String url) async {
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

    return await _probeRemoteGgufHeader(url);
  }

  Future<int?> _probeRemoteGgufHeader(String url) async {
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

      final contentRange = response.headers['content-range'];
      if (contentRange != null) {
        final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
        if (match != null) {
          return int.tryParse(match.group(1)!);
        }
      }

      if (response.statusCode == 200) {
        final lengthHeader = response.headers['content-length'];
        return int.tryParse(lengthHeader ?? '');
      }

      return null;
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

  static const String _defaultSystemPrompt =
      'You are a helpful assistant. Respond in English unless the user '
      'communicates in another language, in which case respond in that language.';
  List<Message> _buildMessages(
    String prompt,
    List<LLMMessage>? history, {
    List<LLMImage>? images,
    String systemPrompt = _defaultSystemPrompt,
  }) {
    final messages = <Message>[
      Message(Role.system, systemPrompt),
    ];

    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        messages.add(
          Message(msg.isUser ? Role.user : Role.assistant, msg.text),
        );
      }
    }

    if (images != null && images.isNotEmpty) {
      final parts = <MessageContentPart>[];
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final label = (image.name ?? '').trim().isEmpty
            ? 'Image ${index + 1}'
            : image.name!.trim();
        parts.add(MessageContentPart.text('$label:'));
        parts.add(
          MessageContentPart.imageBytes(
            image.bytes,
            mimeType: image.mimeType,
          ),
        );
      }

      final trimmedPrompt = prompt.trim();
      if (trimmedPrompt.isNotEmpty) {
        parts.add(MessageContentPart.text(trimmedPrompt));
      }

      messages.add(Message.multimodal(Role.user, parts: parts));
      return messages;
    }

    messages.add(Message(Role.user, prompt));
    return messages;
  }

  Future<_ChatResponse> _runChatRequest(OpenAiRequest request) async {
    final completer = Completer<_ChatResponse>();
    var lastResponse = '';
    var lastResponseJson = '';

    void handleResponse(String response, String responseJson, bool done) {
      lastResponse = response;
      if (responseJson.isNotEmpty) {
        lastResponseJson = responseJson;
      }
      if (done && !completer.isCompleted) {
        completer.complete(
          _ChatResponse(
            response: lastResponse,
            responseJson: lastResponseJson,
          ),
        );
      }
    }

    try {
      _activeRequestId = await fllamaChat(request, handleResponse);
    } catch (e, stack) {
      _logger.severe('Generation error: $e\n$stack');
      return _ChatResponse(
        response: '',
        responseJson: '',
        error: e.toString(),
      );
    }

    try {
      return await completer.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          _logger.warning('Completion timeout');
          return _ChatResponse(
            response: lastResponse,
            responseJson: lastResponseJson,
            error: 'Completion timeout',
          );
        },
      );
    } finally {
      _activeRequestId = null;
    }
  }

  static const int _assistantToolPlannerMaxTokens = 256;
  static const int _assistantToolMaxSteps = 6;

  static const String _assistantToolPlannerSystemPrompt =
      'Decide whether you should call one of the available tools. '
      'If you need a tool, respond ONLY with a JSON function call. '
      'If no tool is needed, respond ONLY with: NO_TOOL. '
      'Call at most one tool per response. Do not answer the user.';

  static const String _assistantToolAnswerSystemPrompt =
      'You are a helpful assistant. Respond in English unless the user '
      'communicates in another language, in which case respond in that language.'
      '\nYou may receive tool outputs as messages.'
      '\n- <memory_results>...</memory_results> is internal evidence. Use it to '
      'answer, but do not include it in your response.'
      '\n- <todo_list>...</todo_list> is UI payload. If present, include the '
      'latest <todo_list> block verbatim in your response.';

  Future<_AssistantToolLoopOutcome?> _maybeHandleAssistantTools(
    String prompt,
    List<LLMMessage>? history,
    String sessionId, {
    List<LLMImage>? images,
    double? temperature,
    int? maxTokens,
  }) async {
    if (!assistantToolFeatures
        .any((feature) => feature.shouldTrigger(prompt))) {
      return null;
    }

    final toolNameToFeature = <String, AssistantToolFeature>{};
    final allowedToolNames = <String>{};
    final fallbackKeyMap = <String, String>{};

    final tools = <Tool>[];
    final toolNamesAdded = <String>{};

    for (final feature in assistantToolFeatures) {
      for (final tool in feature.tools) {
        if (toolNamesAdded.add(tool.name)) {
          tools.add(tool);
        }
      }

      for (final toolName in feature.toolNames) {
        allowedToolNames.add(toolName);
        toolNameToFeature[toolName] = feature;
      }

      fallbackKeyMap.addAll(feature.fallbackKeyMap);
    }

    final model = _currentModel!;
    final modelPath = _modelPathFor(model);
    final contextSize = _loadedContextSize ?? _resolveContextSize(model);
    final resolvedMaxTokens =
        min(_resolveMaxTokens(model, maxTokens), contextSize);
    final gpuLayers = _loadedGpuLayers ?? (Platform.isAndroid ? 0 : 99);

    final plannerMaxTokens =
        min(resolvedMaxTokens, _assistantToolPlannerMaxTokens);

    final messages = <Message>[
      Message(Role.system, _assistantToolPlannerSystemPrompt),
    ];

    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        messages.add(
          Message(msg.isUser ? Role.user : Role.assistant, msg.text),
        );
      }
    }

    if (images != null && images.isNotEmpty) {
      final parts = <MessageContentPart>[];
      for (var index = 0; index < images.length; index++) {
        final image = images[index];
        final label = (image.name ?? '').trim().isEmpty
            ? 'Image ${index + 1}'
            : image.name!.trim();
        parts.add(MessageContentPart.text('$label:'));
        parts.add(
          MessageContentPart.imageBytes(
            image.bytes,
            mimeType: image.mimeType,
          ),
        );
      }

      final trimmedPrompt = prompt.trim();
      if (trimmedPrompt.isNotEmpty) {
        parts.add(MessageContentPart.text(trimmedPrompt));
      }

      messages.add(Message.multimodal(Role.user, parts: parts));
    } else {
      messages.add(Message(Role.user, prompt));
    }

    var usedTools = false;
    String? lastTodoListBlock;

    for (var step = 0; step < _assistantToolMaxSteps; step++) {
      final request = OpenAiRequest(
        messages: messages,
        tools: tools,
        toolChoice: ToolChoice.auto,
        modelPath: modelPath,
        mmprojPath: _mmprojPathFor(model),
        maxTokens: plannerMaxTokens,
        temperature: temperature ?? 0.2,
        topP: 0.9,
        frequencyPenalty: 0.0,
        presencePenalty: 1.1,
        numGpuLayers: gpuLayers,
        contextSize: contextSize,
        logger: kDebugMode ? _fllamaLog : null,
      );

      final response = await _runChatRequest(request);
      if (response.hasError) {
        return _AssistantToolLoopOutcome.immediate(
          '\n\nError: ${response.error}',
          lastTodoListBlock: lastTodoListBlock,
        );
      }

      var toolCalls = parseLlmToolCalls(
        response.responseJson,
        allowedToolNames: allowedToolNames,
        fallbackKeyMap: fallbackKeyMap,
      );
      if (toolCalls.isEmpty && response.response.trim().isNotEmpty) {
        toolCalls = parseLlmToolCalls(
          response.response,
          allowedToolNames: allowedToolNames,
          fallbackKeyMap: fallbackKeyMap,
        );
      }

      if (toolCalls.isEmpty) {
        if (!usedTools) {
          return null;
        }
        break;
      }

      final call = toolCalls.first;
      final feature = toolNameToFeature[call.name];
      if (feature == null) {
        messages.add(
          Message(
            Role.tool,
            'Unknown tool: ${call.name}',
            toolResponseName: call.name,
          ),
        );
        continue;
      }

      messages.add(
        Message(
          Role.assistant,
          '',
          toolCalls: [
            {
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': call.arguments,
              },
            },
          ],
        ),
      );

      final toolResult = await feature.handleToolCall(call, sessionId, prompt);
      if (toolResult is AssistantToolFinalResponse) {
        return _AssistantToolLoopOutcome.immediate(
          toolResult.text,
          lastTodoListBlock: lastTodoListBlock,
        );
      }

      if (toolResult is AssistantToolToolResponse) {
        usedTools = true;
        final content = toolResult.content;
        if (call.name.startsWith('todo_') && content.contains('<todo_list>')) {
          lastTodoListBlock = content;
        }

        messages.add(
          Message(Role.tool, content, toolResponseName: call.name),
        );
      }
    }

    if (!usedTools) {
      return null;
    }

    final finalMessages = <Message>[
      Message(Role.system, _assistantToolAnswerSystemPrompt),
      ...messages.skip(1),
    ];

    return _AssistantToolLoopOutcome.stream(
      messages: finalMessages,
      lastTodoListBlock: lastTodoListBlock,
    );
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
    if (!_isReady || _currentModel == null) {
      yield 'Model not loaded.';
      return;
    }

    if (_isGenerating) {
      yield 'Already generating...';
      return;
    }

    _isGenerating = true;

    try {
      List<Message>? toolMessages;
      String? ensuredTodoListBlock;
      var stripMemoryResults = false;

      if (enableTodoTools && todoSessionId != null) {
        final toolOutcome = await _maybeHandleAssistantTools(
          prompt,
          history,
          todoSessionId,
          images: images,
          temperature: temperature,
          maxTokens: maxTokens,
        );
        if (toolOutcome != null) {
          final immediate = toolOutcome.text;
          if (immediate != null) {
            yield immediate;
            return;
          }
          toolMessages = toolOutcome.messages;
          ensuredTodoListBlock = toolOutcome.lastTodoListBlock;
          stripMemoryResults = toolMessages != null;
        }
      }

      final tokenController = StreamController<String>();
      final completer = Completer<void>();
      var lastResponse = '';

      int commonPrefixLength(String a, String b) {
        final limit = min(a.length, b.length);
        var index = 0;
        while (index < limit && a.codeUnitAt(index) == b.codeUnitAt(index)) {
          index++;
        }
        return index;
      }

      String deltaFromResponse(String previous, String current) {
        if (current.isEmpty) return '';
        if (previous.isEmpty) return current;
        if (current.startsWith(previous)) {
          return current.substring(previous.length);
        }
        final prefix = commonPrefixLength(previous, current);
        return current.substring(prefix);
      }

      final memoryFilter =
          stripMemoryResults ? _StreamingTagFilter('memory_results') : null;

      void handleResponse(String response, String responseJson, bool done) {
        var delta = deltaFromResponse(lastResponse, response);
        if (delta.isNotEmpty) {
          if (memoryFilter != null) {
            delta = memoryFilter.process(delta);
          }
          if (delta.isNotEmpty) {
            tokenController.add(delta);
          }
        }
        lastResponse = response;
        if (done && !completer.isCompleted) {
          completer.complete();
        }
      }

      try {
        final model = _currentModel!;
        final modelPath = _modelPathFor(model);
        final contextSize = _loadedContextSize ?? _resolveContextSize(model);
        final resolvedMaxTokens =
            min(_resolveMaxTokens(model, maxTokens), contextSize);
        final gpuLayers = _loadedGpuLayers ?? (Platform.isAndroid ? 0 : 99);
        final request = OpenAiRequest(
          messages:
              toolMessages ?? _buildMessages(prompt, history, images: images),
          modelPath: modelPath,
          mmprojPath: _mmprojPathFor(model),
          maxTokens: resolvedMaxTokens,
          temperature: temperature ?? 0.7,
          topP: 0.9,
          frequencyPenalty: 0.0,
          presencePenalty: 1.1,
          numGpuLayers: gpuLayers,
          contextSize: contextSize,
          logger: kDebugMode ? _fllamaLog : null,
        );

        _activeRequestId = await fllamaChat(request, handleResponse);
      } catch (e, stack) {
        _logger.severe('Generation error: $e\n$stack');
        tokenController.add('\n\nError: $e');
        if (!completer.isCompleted) {
          completer.complete();
        }
      }

      final doneFuture =
          completer.future.timeout(const Duration(minutes: 2), onTimeout: () {
        _logger.warning('Completion timeout');
        if (!completer.isCompleted) {
          completer.complete();
        }
      }).then((_) {
        if (memoryFilter != null) {
          final remaining = memoryFilter.flush();
          if (remaining.isNotEmpty && !tokenController.isClosed) {
            tokenController.add(remaining);
          }
        }

        if (ensuredTodoListBlock != null) {
          final trimmedTodoListBlock = ensuredTodoListBlock.trim();
          if (trimmedTodoListBlock.isNotEmpty &&
              !lastResponse.contains('<todo_list>') &&
              !tokenController.isClosed) {
            tokenController.add('\n\n$trimmedTodoListBlock');
          }
        }
      }).whenComplete(() {
        if (!tokenController.isClosed) {
          tokenController.close();
        }
      });

      try {
        await for (final token in tokenController.stream) {
          yield token;
        }
      } catch (e) {
        _logger.warning('Token stream error: $e');
      } finally {
        await doneFuture;
        _activeRequestId = null;
      }
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
    final requestId = _activeRequestId;
    if (requestId != null) {
      fllamaCancelInference(requestId);
    }
  }

  @override
  Future<void> resetContext() async {}

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

class _AssistantToolLoopOutcome {
  final List<Message>? messages;
  final String? text;
  final String? lastTodoListBlock;

  const _AssistantToolLoopOutcome._({
    this.messages,
    this.text,
    this.lastTodoListBlock,
  });

  const _AssistantToolLoopOutcome.stream({
    required List<Message> messages,
    String? lastTodoListBlock,
  }) : this._(messages: messages, lastTodoListBlock: lastTodoListBlock);

  const _AssistantToolLoopOutcome.immediate(
    String text, {
    String? lastTodoListBlock,
  }) : this._(text: text, lastTodoListBlock: lastTodoListBlock);
}

class _StreamingTagFilter {
  final String startTag;
  final String endTag;

  bool _inside = false;
  String _carry = '';

  _StreamingTagFilter(String tagName)
      : startTag = '<$tagName>',
        endTag = '</$tagName>';

  String process(String input) {
    if (input.isEmpty && _carry.isEmpty) {
      return '';
    }

    var chunk = '$_carry$input';
    _carry = '';

    final output = StringBuffer();

    while (chunk.isNotEmpty) {
      if (!_inside) {
        final idx = chunk.indexOf(startTag);
        if (idx == -1) {
          final keep = startTag.length - 1;
          if (chunk.length <= keep) {
            _carry = chunk;
            break;
          }
          output.write(chunk.substring(0, chunk.length - keep));
          _carry = chunk.substring(chunk.length - keep);
          break;
        }

        output.write(chunk.substring(0, idx));
        chunk = chunk.substring(idx + startTag.length);
        _inside = true;
        continue;
      }

      final idx = chunk.indexOf(endTag);
      if (idx == -1) {
        final keep = endTag.length - 1;
        if (chunk.length <= keep) {
          _carry = chunk;
          break;
        }
        _carry = chunk.substring(chunk.length - keep);
        break;
      }

      chunk = chunk.substring(idx + endTag.length);
      _inside = false;
    }

    return output.toString();
  }

  String flush() {
    if (_inside) {
      _carry = '';
      return '';
    }

    final remainder = _carry;
    _carry = '';
    return remainder;
  }
}

class _ChatResponse {
  final String response;
  final String responseJson;
  final String? error;

  const _ChatResponse({
    required this.response,
    required this.responseJson,
    this.error,
  });

  bool get hasError => error != null && error!.isNotEmpty;
}
