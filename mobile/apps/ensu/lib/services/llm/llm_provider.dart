import 'dart:async';

/// Model information for display
class ModelInfo {
  final String id;
  final String name;
  final String size;
  final String? description;
  final Map<String, dynamic>? metadata;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.size,
    this.description,
    this.metadata,
  });
}

/// Download progress information
class DownloadProgress {
  final int percent; // 0-100
  final int? bytesDownloaded;
  final int? totalBytes;
  final String? status;

  const DownloadProgress({
    required this.percent,
    this.bytesDownloaded,
    this.totalBytes,
    this.status,
  });

  bool get isComplete => percent >= 100;
  bool get hasError => percent < 0;
}

/// Chat message for context
class LLMMessage {
  final String text;
  final bool isUser;
  final int? timestamp;

  const LLMMessage({
    required this.text,
    required this.isUser,
    this.timestamp,
  });
}

/// Abstract LLM provider interface
/// Implement this to add support for different inference backends
abstract class LLMProvider {
  /// Provider name (e.g., "MediaPipe", "llama.cpp", "ONNX")
  String get name;

  /// Initialize the provider
  Future<void> initialize();

  /// Dispose resources
  Future<void> dispose();

  /// Get list of available models
  List<ModelInfo> get availableModels;

  /// Get currently loaded model info
  ModelInfo? get currentModel;

  /// Get selected model (may not be loaded yet)
  ModelInfo get targetModel;

  /// Check if a model is installed
  Future<bool> isModelInstalled(ModelInfo model);

  /// Check if provider is ready for inference
  bool get isReady;

  /// Check if currently generating
  bool get isGenerating;

  /// Download progress stream
  Stream<DownloadProgress> get downloadProgress;

  /// Download and install a model
  Future<void> downloadModel(ModelInfo model);

  /// Load an installed model
  Future<void> loadModel(ModelInfo model);

  /// Unload current model
  Future<void> unloadModel();

  /// Delete an installed model
  Future<void> deleteModel(ModelInfo model);

  /// Generate response (streaming)
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  });

  /// Generate response (complete)
  Future<String> generate(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  });

  /// Stop ongoing generation
  Future<void> stopGeneration();

  /// Reset conversation context
  Future<void> resetContext();

  /// Ensure model is ready - downloads if needed, loads if not loaded
  Future<void> ensureModelReady();

  /// Cancel ongoing download
  void cancelDownload();
}

/// LLM Service that wraps a provider
class LLMService {
  static final LLMService instance = LLMService._();
  LLMService._();

  LLMProvider? _provider;

  /// Set the LLM provider implementation
  void setProvider(LLMProvider provider) {
    _provider = provider;
  }

  /// Get current provider
  LLMProvider? get provider => _provider;

  /// Check if provider is set and ready
  bool get isReady => _provider?.isReady ?? false;

  /// Check if generating
  bool get isGenerating => _provider?.isGenerating ?? false;

  /// Current model info
  ModelInfo? get currentModel => _provider?.currentModel;

  /// Selected model (may not be loaded yet)
  ModelInfo? get targetModel => _provider?.targetModel;

  /// Available models
  List<ModelInfo> get availableModels => _provider?.availableModels ?? [];

  /// Download progress stream
  Stream<DownloadProgress> get downloadProgress =>
      _provider?.downloadProgress ?? const Stream.empty();

  /// Initialize the service with provider
  Future<void> init() async {
    await _provider?.initialize();
  }

  /// Download a model
  Future<void> downloadModel(ModelInfo model) async {
    await _provider?.downloadModel(model);
  }

  /// Load a model
  Future<void> loadModel(ModelInfo model) async {
    await _provider?.loadModel(model);
  }

  /// Delete a model
  Future<void> deleteModel(ModelInfo model) async {
    await _provider?.deleteModel(model);
  }

  /// Check if model is installed
  Future<bool> isModelInstalled(ModelInfo model) async {
    return await _provider?.isModelInstalled(model) ?? false;
  }

  /// Generate streaming response
  Stream<String> generateStream(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  }) {
    if (_provider == null) {
      return Stream.value('No LLM provider configured.');
    }
    return _provider!.generateStream(
      prompt,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  /// Generate complete response
  Future<String> generate(
    String prompt, {
    List<LLMMessage>? history,
    double? temperature,
    int? maxTokens,
  }) async {
    if (_provider == null) {
      return 'No LLM provider configured.';
    }
    return _provider!.generate(
      prompt,
      history: history,
      temperature: temperature,
      maxTokens: maxTokens,
    );
  }

  /// Stop generation
  Future<void> stopGeneration() async {
    await _provider?.stopGeneration();
  }

  /// Reset context
  Future<void> resetContext() async {
    await _provider?.resetContext();
  }

  /// Dispose
  Future<void> dispose() async {
    await _provider?.dispose();
  }

  /// Ensure model is ready
  Future<void> ensureModelReady() async {
    await _provider?.ensureModelReady();
  }

  /// Cancel ongoing download
  void cancelDownload() {
    _provider?.cancelDownload();
  }
}
