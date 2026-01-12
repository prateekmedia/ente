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
    _startDownload();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _animController.dispose();
    super.dispose();
  }

  LLMService get _llm => LLMService.instance;

  Future<void> _startDownload() async {
    _subscription = _llm.downloadProgress.listen((progress) {
      if (!mounted) return;

      final rawStatus = progress.status ?? '';
      final isLoadingModel = rawStatus.contains('Loading');
      final isReady = rawStatus == 'Ready';
      final status = progress.hasError ? _formatError(rawStatus) : rawStatus;

      setState(() {
        _percent = progress.percent;
        _status = status;
        _hasError = progress.hasError;
        _isLoading = isLoadingModel;
        _isComplete = isReady;
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
      if (mounted) {
        setState(() {
          _hasError = true;
          _status = 'Error: ${_formatError(e)}';
          _isLoading = false;
        });
        widget.onError?.call();
      }
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
    });
    _startDownload();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final borderColor = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final mutedColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final accentColor = isDark ? EnsuColors.accentDark : EnsuColors.accent;

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
                      'Preparing model',
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
                      onPressed: _retry,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        'Retry',
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

/// Overlay entry helper for showing/hiding the toast
class DownloadToastOverlay {
  static OverlayEntry? _entry;
  static Completer<bool>? _completer;

  /// Show the download toast and return a Future that completes when done
  /// Returns true if download completed successfully, false if cancelled/error
  static Future<bool> show(BuildContext context) async {
    // If already showing, wait for existing
    if (_entry != null) {
      return _completer?.future ?? Future.value(false);
    }

    _completer = Completer<bool>();

    _entry = OverlayEntry(
      builder: (context) {
        final topOffset =
            MediaQuery.of(context).padding.top + kToolbarHeight + 8;
        return Positioned(
          left: 0,
          right: 0,
          top: topOffset,
          child: Material(
            type: MaterialType.transparency,
            child: DownloadToast(
              onComplete: () {
                _hide();
                _completer?.complete(true);
              },
              onCancel: () {
                _hide();
                _completer?.complete(false);
              },
              onError: () {
                // Don't auto-hide on error, let user dismiss
              },
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_entry!);

    return _completer!.future;
  }

  static void _hide() {
    _entry?.remove();
    _entry = null;
  }

  /// Force hide the toast
  static void dismiss() {
    _hide();
    _completer?.complete(false);
    _completer = null;
  }
}
