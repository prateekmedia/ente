import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/ui/widgets/ensu_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class _SuggestedModel {
  final String name;
  final String url;
  final String? mmprojUrl;
  final int contextLength;
  final int maxOutputTokens;

  const _SuggestedModel({
    required this.name,
    required this.url,
    this.mmprojUrl,
    required this.contextLength,
    required this.maxOutputTokens,
  });
}

class ModelSettingsPage extends StatefulWidget {
  const ModelSettingsPage({super.key});

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  final _logger = Logger('ModelSettingsPage');
  final _urlController = TextEditingController();
  final _mmprojController = TextEditingController();
  final _contextController = TextEditingController();
  final _maxTokensController = TextEditingController();
  bool _isSaving = false;
  bool _useCustomModel = false;
  String? _urlError;
  String? _mmprojError;
  String? _contextError;
  String? _maxTokensError;

  static const List<_SuggestedModel> _suggestedModels = [
    _SuggestedModel(
      name: 'Qwen3-VL 2B Instruct (Q4_K_M) + mmproj',
      url:
          'https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/main/Qwen3VL-2B-Instruct-Q4_K_M.gguf',
      mmprojUrl:
          'https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen3VL-2B-Instruct-Q8_0.gguf',
      contextLength: 32768,
      maxOutputTokens: 4096,
    ),
    _SuggestedModel(
      name: 'LFM 2.5 1.2B Instruct (Q4_0)',
      url:
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_0.gguf',
      contextLength: 32768,
      maxOutputTokens: 4096,
    ),
    _SuggestedModel(
      name: 'LFM 2.5 VL 1.6B (Q4_0) + mmproj',
      url:
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q4_0.gguf',
      mmprojUrl:
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-Q8_0.gguf',
      contextLength: 32768,
      maxOutputTokens: 4096,
    ),
    _SuggestedModel(
      name: 'Llama 3.2 1B Instruct (Q4_K_M)',
      url:
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      contextLength: 8192,
      maxOutputTokens: 2048,
    ),
  ];

  @override
  void initState() {
    super.initState();
    final config = Configuration.instance;
    _urlController.text = config.getCustomModelUrl() ?? '';
    _mmprojController.text = config.getCustomMmprojUrl() ?? '';
    _useCustomModel = config.getUseCustomModel();
    final customContext = config.getCustomModelContextLength();
    if (customContext != null) {
      _contextController.text = customContext.toString();
    }
    final customMaxTokens = config.getCustomModelMaxOutputTokens();
    if (customMaxTokens != null) {
      _maxTokensController.text = customMaxTokens.toString();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _mmprojController.dispose();
    _contextController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  LLMService get _llm => LLMService.instance;

  int get _defaultContextSize => 8192;

  int get _defaultMaxTokens => 2048;

  Future<void> _applyCustomModel() async {
    final rawUrl = _urlController.text.trim();
    final normalizedUrl = _normalizeUrl(rawUrl);
    final urlError = _validateUrl(normalizedUrl);
    if (urlError != null) {
      setState(() {
        _urlError = urlError;
      });
      return;
    }

    final rawMmprojUrl = _mmprojController.text.trim();
    final normalizedMmprojUrl = _normalizeUrl(rawMmprojUrl);
    final mmprojError =
        _validateUrl(normalizedMmprojUrl, allowEmpty: true);
    if (mmprojError != null) {
      setState(() {
        _mmprojError = mmprojError;
      });
      return;
    }

    if (normalizedUrl != rawUrl) {
      _urlController.text = normalizedUrl;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: normalizedUrl.length),
      );
    }

    if (normalizedMmprojUrl != rawMmprojUrl) {
      _mmprojController.text = normalizedMmprojUrl;
      _mmprojController.selection = TextSelection.fromPosition(
        TextPosition(offset: normalizedMmprojUrl.length),
      );
    }

    final limitsStored = await _storeCustomLimits();
    if (!limitsStored) {
      return;
    }

    setState(() {
      _isSaving = true;
      _urlError = null;
      _mmprojError = null;
    });

    try {
      await Configuration.instance.setCustomModelUrl(normalizedUrl);
      await Configuration.instance.setCustomMmprojUrl(
        normalizedMmprojUrl.isEmpty ? null : normalizedMmprojUrl,
      );
      await Configuration.instance.setUseCustomModel(true);
      _useCustomModel = true;

      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
      Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _logger.severe('Failed to apply custom model: $e');
      if (!mounted) return;
      _showSnack('Failed to apply custom model: $e');
    } finally {
      if (mounted && _isSaving) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _useDefaultModel() async {
    setState(() {
      _isSaving = true;
      _urlError = null;
      _mmprojError = null;
    });

    try {
      await Configuration.instance.setUseCustomModel(false);
      _useCustomModel = false;

      if (!mounted) return;
      setState(() {
        _isSaving = false;
      });
      Navigator.of(context).pop(true);
      return;
    } catch (e) {
      _logger.severe('Failed to switch to default model: $e');
      if (!mounted) return;
      _showSnack('Failed to switch to default model: $e');
    } finally {
      if (mounted && _isSaving) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  String? _validateUrl(String url, {bool allowEmpty = false}) {
    if (url.isEmpty) {
      return allowEmpty ? null : 'Enter a Hugging Face .gguf URL';
    }
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return 'Invalid URL';
    }
    if (!_isHuggingFaceHost(uri.host)) {
      return 'Only Hugging Face URLs are supported';
    }
    if (!uri.path.toLowerCase().endsWith('.gguf')) {
      return 'URL must end with .gguf';
    }
    return null;
  }

  bool _isHuggingFaceHost(String host) {
    final lower = host.toLowerCase();
    return lower == 'huggingface.co' ||
        lower.endsWith('.huggingface.co') ||
        lower == 'hf.co';
  }

  String _normalizeUrl(String url) {
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

  ({int? contextLength, int? maxTokens})? _parseCustomLimits() {
    final contextRaw = _contextController.text.trim();
    final maxTokensRaw = _maxTokensController.text.trim();
    String? contextError;
    String? maxTokensError;
    int? contextValue;
    int? maxTokensValue;

    if (contextRaw.isNotEmpty) {
      contextValue = int.tryParse(contextRaw);
      if (contextValue == null || contextValue <= 0) {
        contextError = 'Enter a positive number';
      }
    }

    if (maxTokensRaw.isNotEmpty) {
      maxTokensValue = int.tryParse(maxTokensRaw);
      if (maxTokensValue == null || maxTokensValue <= 0) {
        maxTokensError = 'Enter a positive number';
      }
    }

    if (contextError == null && maxTokensError == null) {
      if (contextValue != null && maxTokensValue != null) {
        if (maxTokensValue > contextValue) {
          maxTokensError = 'Must be <= context length';
        }
      }
    }

    if (contextError != _contextError || maxTokensError != _maxTokensError) {
      setState(() {
        _contextError = contextError;
        _maxTokensError = maxTokensError;
      });
    }

    if (contextError != null || maxTokensError != null) {
      return null;
    }

    return (contextLength: contextValue, maxTokens: maxTokensValue);
  }

  Future<bool> _storeCustomLimits() async {
    final limits = _parseCustomLimits();
    if (limits == null) {
      return false;
    }
    await Configuration.instance.setCustomModelContextLength(
      limits.contextLength,
    );
    await Configuration.instance.setCustomModelMaxOutputTokens(
      limits.maxTokens,
    );
    return true;
  }

  void _applySuggestedModel(_SuggestedModel model) {
    setState(() {
      _urlController.text = model.url;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: model.url.length),
      );
      _mmprojController.text = model.mmprojUrl ?? '';
      _mmprojController.selection = TextSelection.fromPosition(
        TextPosition(offset: _mmprojController.text.length),
      );
      _contextController.text = model.contextLength.toString();
      _maxTokensController.text = model.maxOutputTokens.toString();
      _urlError = null;
      _mmprojError = null;
      _contextError = null;
      _maxTokensError = null;
    });
    _showSnack('Model URL filled');
  }

  String _suggestedMetadata(_SuggestedModel model) {
    return 'Context: ${model.contextLength} tokens • Max output: ${model.maxOutputTokens} (<= context - prompt tokens)';
  }

  Widget _buildSuggestedModels() {
    return Column(
      children: _suggestedModels.map((model) {
        final metadata = _suggestedMetadata(model);
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            title: Text(model.name),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(model.url),
                if (model.mmprojUrl != null) ...[
                  const SizedBox(height: 4),
                  Text('mmproj: ${model.mmprojUrl}'),
                ],
                const SizedBox(height: 4),
                Text(
                  metadata,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            trailing: TextButton(
              onPressed: () => _applySuggestedModel(model),
              child: const Text('Fill'),
            ),
          ),
        );
      }).toList(),
    );
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targetModel = _llm.targetModel;
    final currentModel = _llm.currentModel;
    final isLoaded = _llm.isReady &&
        targetModel != null &&
        currentModel != null &&
        targetModel.id == currentModel.id;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Settings'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Selected model',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                targetModel?.name ?? 'Default',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 4),
              Text(
                isLoaded ? 'Loaded' : 'Not loaded',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Text(
                'Custom Hugging Face model',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Direct .gguf file URL',
                  hintText:
                      'https://huggingface.co/.../resolve/main/model.gguf',
                  errorText: _urlError,
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  if (_urlError != null) {
                    setState(() => _urlError = null);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _mmprojController,
                decoration: InputDecoration(
                  labelText: 'Optional mmproj .gguf file URL',
                  hintText:
                      'https://huggingface.co/.../resolve/main/mmproj.gguf',
                  errorText: _mmprojError,
                ),
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) {
                  if (_mmprojError != null) {
                    setState(() => _mmprojError = null);
                  }
                },
              ),
              const SizedBox(height: 16),
              Text(
                'Suggested models',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              _buildSuggestedModels(),
              const SizedBox(height: 16),
              Text(
                'Custom model limits',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _contextController,
                decoration: InputDecoration(
                  labelText: 'Context length (tokens)',
                  hintText: 'Default: $_defaultContextSize',
                  errorText: _contextError,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) {
                  if (_contextError != null) {
                    setState(() => _contextError = null);
                  }
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _maxTokensController,
                decoration: InputDecoration(
                  labelText: 'Max output tokens',
                  hintText: 'Default: $_defaultMaxTokens',
                  errorText: _maxTokensError,
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) {
                  if (_maxTokensError != null) {
                    setState(() => _maxTokensError = null);
                  }
                },
              ),
              const SizedBox(height: 8),
              Text(
                'Leave blank to use defaults. Max output should be <= context length - prompt tokens.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              EnsuPrimaryButton(
                text: _useCustomModel
                    ? 'Reload Custom Model'
                    : 'Use Custom Model',
                isLoading: _isSaving,
                onPressed: _isSaving ? null : _applyCustomModel,
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : _useDefaultModel,
                    child: const Text('Use Default Model'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Switching models does not delete downloads. Previously downloaded models stay cached.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
