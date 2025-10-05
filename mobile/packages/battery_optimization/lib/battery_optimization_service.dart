import 'dart:io';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

class BatteryOptimizationService {
  static const _channel = MethodChannel('io.ente.photos/battery');
  final _logger = Logger('BatteryOptimizationService');

  static final BatteryOptimizationService instance =
      BatteryOptimizationService._();

  BatteryOptimizationService._();

  /// Returns true if app is ignoring battery optimizations (good for background tasks)
  /// Returns false if battery optimization is enabled (bad for background tasks)
  /// Only works on Android M (API 23) and above, returns true for older versions
  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;

    try {
      final result = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } catch (e) {
      _logger.severe('Failed to check battery optimization status', e);
      return true; // Assume OK to avoid false warnings
    }
  }

  /// Requests user to disable battery optimization for the app
  /// Opens system settings on Android M (API 23) and above
  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return;

    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      _logger.severe('Failed to request battery optimization exemption', e);
    }
  }

  /// Returns the device manufacturer (e.g., "samsung", "xiaomi", "realme")
  Future<String> getDeviceManufacturer() async {
    if (!Platform.isAndroid) return 'unknown';

    try {
      final result = await _channel.invokeMethod<String>(
        'getDeviceManufacturer',
      );
      return result?.toLowerCase() ?? 'unknown';
    } catch (e) {
      _logger.severe('Failed to get device manufacturer', e);
      return 'unknown';
    }
  }

  /// Returns true if the device manufacturer is known to have aggressive
  /// battery optimization that kills background tasks frequently
  Future<bool> isAggressiveManufacturer() async {
    final manufacturer = await getDeviceManufacturer();
    const aggressiveOEMs = [
      'realme',
      'oppo',
      'vivo',
      'xiaomi',
      'huawei',
      'oneplus',
    ];
    return aggressiveOEMs.contains(manufacturer);
  }
}
