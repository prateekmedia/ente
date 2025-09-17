/// Cancel token for managing compute operation cancellation
class CancelToken {
  bool _isCancelled = false;
  final List<Function()> _onCancelCallbacks = [];

  bool get isCancelled => _isCancelled;

  void cancel() {
    if (_isCancelled) return;

    _isCancelled = true;

    // Execute all registered callbacks
    for (final callback in _onCancelCallbacks) {
      try {
        callback();
      } catch (e) {
        // Silently ignore callback errors
      }
    }
    _onCancelCallbacks.clear();
  }

  void onCancel(Function() callback) {
    if (_isCancelled) {
      // If already cancelled, execute immediately
      callback();
    } else {
      _onCancelCallbacks.add(callback);
    }
  }

  void reset() {
    _isCancelled = false;
    _onCancelCallbacks.clear();
  }
}
