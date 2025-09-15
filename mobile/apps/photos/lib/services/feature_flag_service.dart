import 'package:photos/service_locator.dart';

class FeatureFlagService {
  static final FeatureFlagService _instance = FeatureFlagService._internal();
  factory FeatureFlagService() => _instance;
  FeatureFlagService._internal();

  static FeatureFlagService get instance => _instance;

  bool get isAirplaySupported {
    return flagService.internalUser;
  }
}