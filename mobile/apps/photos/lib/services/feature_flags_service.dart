import "package:photos/service_locator.dart";

/// Simple feature flags service for mobile nested albums functionality
class FeatureFlagsService {
  
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