/// Test configuration constants for integration tests
class TestConfig {
  // Test user credentials
  static const String testEmail = "test@example.com";
  static const String testPassword = "TestPassword123!";
  static const String testOttCode = "123456";
  static const String test2FACode = "654321";

  // API configuration
  static const String mockApiEndpoint = "https://api.ente.io";

  // Test delays (in milliseconds)
  static const int shortDelay = 500;
  static const int mediumDelay = 1000;
  static const int longDelay = 2000;
  static const int veryLongDelay = 5000;

  // Timeout values
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration longTimeout = Duration(seconds: 60);
}
