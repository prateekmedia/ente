import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:fllama/fllama.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

/// FLlama Provider - uses fllama package with pre-built binaries
class FllamaProvider implements LLMProvider {
  final _logger = Logger('FllamaProvider');
  final _config = Configuration.instance;

  bool _isInitialized = false;
  bool _isReady = false;
  bool _isGenerating = false;

  int? _activeRequestId;
  String? _modelsDir;
  String? _customModelsDir;
  ModelInfo? _currentModel;
  String? _customModelUrl;
  ModelInfo? _customModelInfo;

  final _downloadProgressController =
      StreamController<DownloadProgress>.broadcast();

  bool _downloadCancelled = false;
  http.Client? _httpClient;

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
    return await _isGgufFile(file);
  }

  /// Ensure model is ready - downloads if needed
  @override
  Future<void> ensureModelReady() async {
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
        'Model path: $modelPath, exists: $exists, size: ${_formatBytes(size)}');

    final isValid = exists &&
        size >= _minModelSizeBytes(selectedModel) &&
        await _isGgufFile(modelFile);

    if (!isValid) {
      if (exists) await modelFile.delete();
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
  }

  @override
  Future<void> downloadModel(ModelInfo model) async {
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

      _logger.fine('Model downloaded, loading...');
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

  /// Check if running on iOS simulator
  Future<bool> _isIOSSimulator(String modelPath) async {
    if (!Platform.isIOS) return false;
    return modelPath.contains('CoreSimulator');
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

      try {
        await fllamaChatTemplateGet(modelPath);
      } catch (e) {
        _logger.warning('Could not read chat template: $e');
      }

      _currentModel = model;
      _isReady = true;
      _logger.fine('Model ready for inference');
    } catch (e, stack) {
      _logger.severe('Failed to prepare model: $e\n$stack');
      _isReady = false;
      _currentModel = null;
      rethrow;
    }
  }

  @override
  Future<void> unloadModel() async {
    await stopGeneration();
    _isReady = false;
    _currentModel = null;
    _activeRequestId = null;
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

  List<Message> _buildMessages(String prompt, List<LLMMessage>? history) {
    final messages = <Message>[
      Message(Role.system, 'You are a helpful assistant.'),
    ];

    if (history != null && history.isNotEmpty) {
      for (final msg in history) {
        messages.add(
          Message(msg.isUser ? Role.user : Role.assistant, msg.text),
        );
      }
    }

    messages.add(Message(Role.user, prompt));
    return messages;
  }

  @override
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
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

    void handleResponse(String response, String responseJson, bool done) {
      final delta = deltaFromResponse(lastResponse, response);
      if (delta.isNotEmpty) {
        tokenController.add(delta);
      }
      lastResponse = response;
      if (done && !completer.isCompleted) {
        completer.complete();
      }
    }

    try {
      final modelPath = _modelPathFor(_currentModel!);
      final request = OpenAiRequest(
        messages: _buildMessages(prompt, history),
        modelPath: modelPath,
        maxTokens: maxTokens ?? 256,
        temperature: temperature ?? 0.7,
        topP: 0.9,
        frequencyPenalty: 0.0,
        presencePenalty: 1.1,
        numGpuLayers: 0,
        contextSize: kDebugMode ? 512 : 2048,
        logger: (log) {
          if (log.trim().isNotEmpty) {
            _logger.fine('[fllama] $log');
          }
        },
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
    final requestId = _activeRequestId;
    if (requestId != null) {
      fllamaCancelInference(requestId);
    }
  }

  @override
  Future<void> resetContext() async {
    if (_isReady && _currentModel != null) {
      await _loadModel(_currentModel!);
    }
  }

  static const int _ggufTypeUint8 = 0;
  static const int _ggufTypeInt8 = 1;
  static const int _ggufTypeUint16 = 2;
  static const int _ggufTypeInt16 = 3;
  static const int _ggufTypeUint32 = 4;
  static const int _ggufTypeInt32 = 5;
  static const int _ggufTypeFloat32 = 6;
  static const int _ggufTypeBool = 7;
  static const int _ggufTypeString = 8;
  static const int _ggufTypeArray = 9;
  static const int _ggufTypeUint64 = 10;
  static const int _ggufTypeInt64 = 11;
  static const int _ggufTypeFloat64 = 12;

  Future<String?> _readGgufStringValue(File file, String key) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final magic = await _readExact(raf, 4);
      if (ascii.decode(magic) != 'GGUF') {
        return null;
      }

      await _readUint32(raf); // version
      await _readUint64(raf); // tensor count
      final kvCount = await _readUint64(raf);

      for (var i = 0; i < kvCount; i++) {
        final keyName = await _readStringWithUint32Length(raf);
        final valueType = await _readUint32(raf);

        if (keyName == key && valueType == _ggufTypeString) {
          return await _readStringWithUint64Length(raf);
        }

        await _skipGgufValue(raf, valueType);
      }
    } catch (e) {
      _logger.warning('Failed to read GGUF metadata: $e');
      return null;
    } finally {
      await raf?.close();
    }

    return null;
  }

  Future<void> _skipGgufValue(RandomAccessFile raf, int valueType) async {
    if (valueType == _ggufTypeArray) {
      final elementType = await _readUint32(raf);
      final count = await _readUint64(raf);
      if (elementType == _ggufTypeString) {
        for (var i = 0; i < count; i++) {
          final length = await _readUint64(raf);
          await _skipBytes(raf, length);
        }
        return;
      }

      final elementSize = _ggufTypeSize(elementType);
      await _skipBytes(raf, elementSize * count);
      return;
    }

    if (valueType == _ggufTypeString) {
      final length = await _readUint64(raf);
      await _skipBytes(raf, length);
      return;
    }

    final size = _ggufTypeSize(valueType);
    await _skipBytes(raf, size);
  }

  int _ggufTypeSize(int valueType) {
    switch (valueType) {
      case _ggufTypeUint8:
      case _ggufTypeInt8:
      case _ggufTypeBool:
        return 1;
      case _ggufTypeUint16:
      case _ggufTypeInt16:
        return 2;
      case _ggufTypeUint32:
      case _ggufTypeInt32:
      case _ggufTypeFloat32:
        return 4;
      case _ggufTypeUint64:
      case _ggufTypeInt64:
      case _ggufTypeFloat64:
        return 8;
      default:
        throw Exception('Unsupported GGUF value type: $valueType');
    }
  }

  Future<String> _readStringWithUint32Length(RandomAccessFile raf) async {
    final length = await _readUint32(raf);
    final bytes = await _readExact(raf, length);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String> _readStringWithUint64Length(RandomAccessFile raf) async {
    final length = await _readUint64(raf);
    final bytes = await _readExact(raf, length);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<int> _readUint32(RandomAccessFile raf) async {
    final bytes = await _readExact(raf, 4);
    return ByteData.sublistView(bytes).getUint32(0, Endian.little);
  }

  Future<int> _readUint64(RandomAccessFile raf) async {
    final bytes = await _readExact(raf, 8);
    return ByteData.sublistView(bytes).getUint64(0, Endian.little);
  }

  Future<Uint8List> _readExact(RandomAccessFile raf, int length) async {
    final buffer = Uint8List(length);
    var offset = 0;
    while (offset < length) {
      final chunk = await raf.read(length - offset);
      if (chunk.isEmpty) {
        throw Exception('Unexpected end of file');
      }
      buffer.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return buffer;
  }

  Future<void> _skipBytes(RandomAccessFile raf, int length) async {
    final position = await raf.position();
    await raf.setPosition(position + length);
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
