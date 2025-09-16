/// Stream version constants for video streaming
/// Version 1: Legacy - AES-128 + CRF + Fixed IV (0x00000000)
/// Version 2: Enhanced - AES-256 + Bitrate control + Random IV per segment
class StreamVersion {
  static const int LEGACY = 1; // AES-128 + CRF + Fixed IV
  static const int ENHANCED = 2; // AES-256 + Bitrate + Random IV

  // Default to LEGACY for backward compatibility
  static const int DEFAULT = LEGACY;

  /// Check if a version is valid
  static bool isValidVersion(int version) {
    return version == LEGACY || version == ENHANCED;
  }

  /// Get version name for logging
  static String getVersionName(int version) {
    switch (version) {
      case LEGACY:
        return 'Legacy (v1)';
      case ENHANCED:
        return 'Enhanced (v2)';
      default:
        return 'Unknown';
    }
  }
}