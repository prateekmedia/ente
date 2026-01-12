import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/ui/widgets/download_toast.dart';
import 'package:ensu/ui/widgets/ensu_button.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

class ModelSettingsPage extends StatefulWidget {
  const ModelSettingsPage({super.key});

  @override
  State<ModelSettingsPage> createState() => _ModelSettingsPageState();
}

class _ModelSettingsPageState extends State<ModelSettingsPage> {
  final _logger = Logger('ModelSettingsPage');
  final _urlController = TextEditingController();
  bool _isSaving = false;
  bool _useCustomModel = false;
  String? _urlError;

  @override
  void initState() {
    super.initState();
    final config = Configuration.instance;
    _urlController.text = config.getCustomModelUrl() ?? '';
    _useCustomModel = config.getUseCustomModel();
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  LLMService get _llm => LLMService.instance;

  Future<void> _applyCustomModel() async {
    final rawUrl = _urlController.text.trim();
    final normalizedUrl = _normalizeUrl(rawUrl);
    final error = _validateUrl(normalizedUrl);
    if (error != null) {
      setState(() {
        _urlError = error;
      });
      return;
    }

    if (normalizedUrl != rawUrl) {
      _urlController.text = normalizedUrl;
      _urlController.selection = TextSelection.fromPosition(
        TextPosition(offset: normalizedUrl.length),
      );
    }

    setState(() {
      _isSaving = true;
      _urlError = null;
    });

    try {
      await Configuration.instance.setCustomModelUrl(normalizedUrl);
      await Configuration.instance.setUseCustomModel(true);
      _useCustomModel = true;
      await _loadSelectedModel();
      if (!mounted) return;
      _showSnack('Custom model ready');
    } catch (e) {
      _logger.severe('Failed to apply custom model: $e');
      if (!mounted) return;
      _showSnack('Failed to load model: $e');
    } finally {
      if (mounted) {
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
    });

    try {
      await Configuration.instance.setUseCustomModel(false);
      _useCustomModel = false;
      await _loadSelectedModel();
      if (!mounted) return;
      _showSnack('Default model ready');
    } catch (e) {
      _logger.severe('Failed to switch to default model: $e');
      if (!mounted) return;
      _showSnack('Failed to load model: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _loadSelectedModel() async {
    final result = await DownloadToastOverlay.show(context);
    if (!mounted) return;
    setState(() {});
    if (!result) {
      _showSnack('Model setup cancelled');
    }
  }

  String? _validateUrl(String url) {
    if (url.isEmpty) {
      return 'Enter a Hugging Face .gguf URL';
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
                'Switching models does not delete downloads. The default Llama model stays cached.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
