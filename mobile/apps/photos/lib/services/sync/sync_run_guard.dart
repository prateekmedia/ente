import 'package:shared_preferences/shared_preferences.dart';

class SyncRunGuard {
  static const _kTs = 'sync_run_lock_ts';
  static const _kOwner = 'sync_run_lock_owner'; // fg/bg
  static const staleAfter = Duration(minutes: 30);

  static Future<bool> tryAcquire(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now().microsecondsSinceEpoch;
    final ts = prefs.getInt(_kTs) ?? 0;
    final currentOwner = prefs.getString(_kOwner);

    // If held by same owner and not stale, skip
    if (ts != 0 && !_isStale(ts) && currentOwner == owner) {
      return false;
    }
    // If held by different owner and not stale, respect it
    if (ts != 0 && !_isStale(ts) && currentOwner != owner) {
      return false;
    }
    // Acquire the lock
    await prefs.setInt(_kTs, now);
    await prefs.setString(_kOwner, owner);
    return true;
  }

  static Future<void> release() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kTs);
    await prefs.remove(_kOwner);
  }

  static Future<void> clearIfStale() async {
    final prefs = await SharedPreferences.getInstance();
    final ts = prefs.getInt(_kTs) ?? 0;
    if (ts != 0 && _isStale(ts)) {
      await release();
    }
  }

  static bool _isStale(int ts) {
    final age = DateTime.now().microsecondsSinceEpoch - ts;
    return age > staleAfter.inMicroseconds;
  }
}
