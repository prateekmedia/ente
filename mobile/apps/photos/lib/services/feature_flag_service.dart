import 'package:photos/service_locator.dart';

class FeatureFlagService {
  static final FeatureFlagService _instance = FeatureFlagService._internal();
  factory FeatureFlagService() => _instance;
  FeatureFlagService._internal();

  static FeatureFlagService get instance => _instance;

  // External Display Feature Flag
  // Controlled by internal user flag - only available for Ente internal users
  bool get isExternalDisplayEnabled {
    return flagService.internalUser;
  }

  // In the future, other feature flags can be added here
  // For example:
  // bool get isNewVideoPlayerEnabled => ...
  // bool get isMLSearchEnabled => ...
}