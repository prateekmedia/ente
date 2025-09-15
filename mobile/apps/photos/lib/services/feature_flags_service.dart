import "package:photos/service_locator.dart";

/// Simple feature flags service for mobile nested albums functionality
class FeatureFlagsService {
  static FeatureFlagsService? _instance;
  
  FeatureFlagsService._();
  
  static FeatureFlagsService get instance {
    _instance ??= FeatureFlagsService._();
    return _instance!;
  }
  
  /// Initialize the service (no-op for now, kept for compatibility)
  void init() {
    // No initialization needed currently
  }
  
  /// Fetch feature flags (no-op for now, kept for compatibility)
  Future<void> fetchFeatureFlags() async {
    // Feature flags are fetched through flagService
  }
  
  /// Get all flags (returns empty map for now, kept for compatibility)
  Map<String, dynamic> getAllFlags() {
    return {};
  }
  
  /// Check if nested collections are enabled for this user
  /// Uses the same logic as web implementation (tied to internalUser)
  bool isNestedCollectionsEnabled() {
    return flagService.isNestedAlbumsEnabled;
  }

  /// Deprecated: Use isNestedCollectionsEnabled() instead
  bool isNestedAlbumsEnabled() {
    return isNestedCollectionsEnabled();
  }
}