import 'dart:async';

import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// A toast-style card that shows download/loading progress
/// Appears near the top of the screen to avoid blocking input
class DownloadToast extends StatefulWidget {
  final VoidCallback? onComplete;
  final VoidCallback? onCancel;
  final VoidCallback? onError;

  const DownloadToast({
    super.key,
    this.onComplete,
    this.onCancel,
    this.onError,
  });

  @override
  State<DownloadToast> createState() => _DownloadToastState();
}

class _DownloadToastState extends State<DownloadToast>
    with SingleTickerProviderStateMixin {
  int _percent = 0;
  String _status = 'Preparing...';
  bool _hasError = false;
  bool _isLoading = false;
  bool _isComplete = false;
  bool _didAttemptLoad = false;
  bool _offerRetryDownload = false;
  StreamSubscription? _subscription;

  late AnimationController _animController;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _animController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));

    _fadeAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    ));

    _animController.forward();
    unawaited(_startDownload());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _animController.dispose();
    super.dispose();
  }

  LLMService get _llm => LLMService.instance;

  Future<void> _startDownload() async {
    await _subscription?.cancel();
    _subscription = null;

    _didAttemptLoad = false;
    _offerRetryDownload = false;

    _subscription = _llm.downloadProgress.listen((progress) {
      if (!mounted) return;

      final rawStatus = progress.status ?? '';
      if (rawStatus.contains('Loading model')) {
        _didAttemptLoad = true;
      }

      final isLoadingModel = rawStatus.contains('Loading');
      final isReady = rawStatus == 'Ready';
      final status = progress.hasError ? _formatError(rawStatus) : rawStatus;
      final offerRetryDownload = progress.hasError &&
          (_didAttemptLoad || _isLoadFailureStatus(rawStatus));

      setState(() {
        _percent = progress.percent;
        _status = status;
        _hasError = progress.hasError;
        _isLoading = isLoadingModel;
        _isComplete = isReady;
        _offerRetryDownload = offerRetryDownload;
      });

      if (isReady) {
        _handleComplete();
      }
    });

    try {
      await _llm.ensureModelReady();
      if (_llm.isReady && !_isComplete) {
        _handleComplete();
      }
    } catch (e) {
      if (!mounted) return;

      final hadError = _hasError;
      final offerRetryDownload = _didAttemptLoad || _offerRetryDownload;

      setState(() {
        _hasError = true;
        _isLoading = false;
        _offerRetryDownload = offerRetryDownload;
        if (!hadError) {
          _status = 'Error: ${_formatError(e)}';
        }
      });
      widget.onError?.call();
    }
  }

  String _formatError(dynamic e) {
    final msg = e.toString();
    if (_isNoSpaceError(msg)) {
      return 'No space left on device';
    }
    if (msg.length > 50) {
      return '${msg.substring(0, 47)}...';
    }
    return msg;
  }

  bool _isNoSpaceError(String msg) {
    final lower = msg.toLowerCase();
    return lower.contains('no space left on device') ||
        lower.contains('errno = 28') ||
        lower.contains('enospc');
  }

  bool _isLoadFailureStatus(String status) {
    final trimmed = status.trimLeft().toLowerCase();
    return trimmed.startsWith('load failed');
  }

  void _handleComplete() {
    setState(() => _isComplete = true);
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        _animController.reverse().then((_) {
          widget.onComplete?.call();
        });
      }
    });
  }

  void _cancel() {
    _llm.cancelDownload();
    _animController.reverse().then((_) {
      widget.onCancel?.call();
    });
  }

  void _retry() {
    setState(() {
      _hasError = false;
      _percent = 0;
      _status = 'Retrying...';
      _didAttemptLoad = false;
      _offerRetryDownload = false;
    });
    unawaited(_startDownload());
  }

  Future<void> _retryDownload() async {
    setState(() {
      _hasError = false;
      _percent = 0;
      _status = 'Retrying download...';
      _didAttemptLoad = false;
      _offerRetryDownload = false;
    });

    try {
      _llm.cancelDownload();
      final targetModel = _llm.targetModel;
      if (targetModel != null) {
        await _llm.deleteModel(targetModel);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _status = 'Error: ${_formatError(e)}';
      });
      return;
    }

    if (!mounted) return;
    unawaited(_startDownload());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final borderColor = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final mutedColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final accentColor = isDark ? EnsuColors.accentDark : EnsuColors.accent;
    final title = _hasError
        ? _offerRetryDownload
            ? 'Model loading failed'
            : 'Model setup failed'
        : _isComplete
            ? 'Model ready'
            : _isLoading
                ? 'Loading model'
                : 'Downloading model';

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.1),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row
              Row(
                children: [
                  Icon(
                    _hasError
                        ? LucideIcons.alertCircle
                        : _isComplete
                            ? LucideIcons.checkCircle
                            : _isLoading
                                ? LucideIcons.cpu
                                : LucideIcons.download,
                    size: 20,
                    color: _hasError
                        ? Colors.red[400]
                        : _isComplete
                            ? Colors.green[400]
                            : accentColor,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: GoogleFonts.cormorantGaramond(
                        fontSize: 18,
                        fontWeight: FontWeight.w500,
                        color: textColor,
                      ),
                    ),
                  ),
                  if (!_isComplete && !_hasError)
                    GestureDetector(
                      onTap: _cancel,
                      child: Icon(LucideIcons.x, size: 18, color: mutedColor),
                    ),
                ],
              ),

              const SizedBox(height: 12),

              // Progress bar (only if not error)
              if (!_hasError) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _percent > 0 ? _percent / 100 : null,
                    minHeight: 4,
                    backgroundColor: borderColor,
                    valueColor: AlwaysStoppedAnimation(
                      _isComplete ? Colors.green[400]! : accentColor,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
              ],

              // Status row
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _hasError
                          ? _status
                          : _isLoading
                              ? 'Loading model...'
                              : _isComplete
                                  ? 'Ready'
                                  : _status,
                      style: GoogleFonts.sourceSerif4(
                        fontSize: 12,
                        color: _hasError ? Colors.red[400] : mutedColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (!_hasError && !_isComplete)
                    Text(
                      '$_percent%',
                      style: GoogleFonts.sourceSerif4(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: accentColor,
                      ),
                    ),
                ],
              ),

              // Error actions
              if (_hasError) ...[
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _cancel,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Dismiss',
                        style: GoogleFonts.sourceSerif4(
                          fontSize: 12,
                          color: mutedColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _offerRetryDownload ? _retryDownload : _retry,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        _offerRetryDownload ? 'Retry download' : 'Retry',
                        style: GoogleFonts.sourceSerif4(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: accentColor,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
