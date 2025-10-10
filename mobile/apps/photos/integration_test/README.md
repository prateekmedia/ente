# Integration Tests for Sign-In Flow

This directory contains integration tests for the Ente Photos app sign-in flow, using mocked API responses and Patrol Finders for improved widget selection.

## Overview

The sign-in flow test validates the complete authentication process from landing page to home screen, using:

- **Mock API Server**: HTTP responses are mocked using `http_mock_adapter` to avoid hitting real servers
- **Patrol Finders**: Enhanced widget finding with `patrol_finders` package for better test reliability
- **Reusable Helpers**: Modular helper methods for common authentication flows

## Project Structure

```
integration_test/
├── mocks/
│   ├── mock_api_interceptor.dart    # Dio interceptor for API mocking
│   └── test_config.dart               # Test configuration constants
├── helpers/
│   └── auth_flow_helper.dart          # Reusable authentication flow methods
├── sign_in_flow_test.dart             # Main sign-in integration test
└── README.md                          # This file
```

## Test Files

### `sign_in_flow_test.dart`

Main integration test file containing:
- **Test 1**: Sign-in using helper methods (cleaner approach)
- **Test 2**: Sign-in using ValueKey finders (explicit approach)

Both tests cover the complete flow:
1. Launch app
2. Navigate to sign-in page
3. Enter email
4. Enter password
5. Handle post-login screens (permissions, backup)
6. Verify home screen reached

### `mocks/mock_api_interceptor.dart`

Provides mock API responses for:
- `GET /users/srp/attributes` - SRP setup check
- `POST /users/srp/create-session` - SRP authentication step 1
- `POST /users/srp/verify-session` - SRP authentication step 2
- `POST /users/ott` - One-time token request
- `POST /users/verify-email` - OTT verification
- `POST /users/two-factor/verify` - 2FA verification
- `GET /users/two-factor/status` - 2FA status check

Additional helper methods:
- `setupMockWith2FA()` - Mock 2FA-enabled login
- `setupMockForInvalidCredentials()` - Mock failed login
- `setupMockForNetworkError()` - Mock network errors

### `mocks/test_config.dart`

Test configuration constants:
- Test credentials (email, password, OTT codes)
- API endpoint configuration
- Timing delays for UI interactions
- Timeout values

### `helpers/auth_flow_helper.dart`

Reusable helper methods using Patrol Finders:
- `navigateToLoginPage()` - Tap sign-in button
- `enterEmail(email)` - Enter email and proceed
- `enterPassword(password)` - Enter password and verify
- `enterOttCode(code)` - Enter OTT verification code
- `enter2FACode(code)` - Enter 2FA code
- `loginWithPassword()` - Complete password-based login
- `loginWithOtt()` - Complete OTT-based login
- `skipBackupIfPrompted()` - Skip backup setup
- `skipPermissionIfPrompted()` - Skip permission requests
- `verifyHomeScreen()` - Verify home screen reached
- `completeLoginFlow()` - End-to-end login flow

## Running the Tests

### Prerequisites

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Ensure you have a device or emulator running:
   ```bash
   # For iOS Simulator
   open -a Simulator

   # For Android Emulator
   emulator -avd <your_avd_name>

   # List available devices
   flutter devices
   ```

### Run Tests

Run all sign-in integration tests:
```bash
flutter test integration_test/sign_in_flow_test.dart
```

Run on specific device:
```bash
flutter test integration_test/sign_in_flow_test.dart -d <device_id>
```

Run with verbose output:
```bash
flutter test integration_test/sign_in_flow_test.dart --verbose
```

### Using `flutter drive` (Alternative)

For performance profiling:
```bash
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/sign_in_flow_test.dart \
  --profile
```

## Test Configuration

### Modifying Test Credentials

Edit `mocks/test_config.dart` to change test data:

```dart
class TestConfig {
  static const String testEmail = "your-test@example.com";
  static const String testPassword = "YourTestPassword123!";
  static const String testOttCode = "123456";
  static const String test2FACode = "654321";
}
```

### Adjusting Delays

Modify timing constants if tests are flaky:

```dart
class TestConfig {
  static const int shortDelay = 500;    // Increase for slow devices
  static const int mediumDelay = 1000;  // Increase for slow networks
  static const int longDelay = 2000;    // Increase for slow API responses
  static const int veryLongDelay = 5000; // For authentication flows
}
```

## Mock API Responses

### Customizing Mock Responses

To modify mock API responses, edit `mocks/mock_api_interceptor.dart`:

```dart
// Example: Change mock user ID
dioAdapter.onPost(
  "$baseUrl/users/srp/verify-session",
  (server) => server.reply(
    200,
    {
      "id": 99999, // Your custom user ID
      "token": "your-custom-token",
      // ... rest of response
    },
  ),
  data: Matchers.any,
);
```

### Testing Different Scenarios

```dart
// Test with 2FA enabled
mockInterceptor.setupMockWith2FA();

// Test with invalid credentials
mockInterceptor.setupMockForInvalidCredentials();

// Test network errors
mockInterceptor.setupMockForNetworkError();
```

## Patrol Finders Usage

### Finding Widgets

Patrol Finders provide multiple strategies for finding widgets:

```dart
// By ValueKey
$(#signInButton)

// By widget type
$(TextFormField)

// Get first match
$(TextFormField).first

// By text (note: text matching may vary by Patrol version)
$("Sign in")
```

### Widget Interactions

```dart
// Wait for widget to appear
await $(#loginButton).waitUntilVisible();

// Tap widget
await $(#loginButton).tap();

// Enter text
await $(#emailField).enterText("user@example.com");

// Check existence
if ($(#optionalWidget).exists) {
  // Widget exists
}
```

## Troubleshooting

### Test Fails at Login

- Check mock API responses match actual API structure
- Verify test credentials in `test_config.dart`
- Increase delays if app is slow to respond

### Widget Not Found

- Use `await $.pumpAndSettle()` before finding widgets
- Add delays with `Future.delayed()` for slow-rendering widgets
- Check ValueKeys in the actual app code
- Try using widget type finders instead of keys

### Mock Interceptor Not Working

- Ensure `NetworkClient` is initialized before setting up mocks
- Check base URL matches configuration
- Verify Dio instance is the same one used by `UserService`

### Flaky Tests

- Increase timeout values in `test_config.dart`
- Add more `await $.pumpAndSettle()` calls
- Use `waitUntilVisible()` before interactions
- Check for race conditions in async operations

## Best Practices

1. **Always use ValueKeys** where possible for reliable widget finding
2. **Add delays** after navigation and async operations
3. **Use pumpAndSettle** before checking widget state
4. **Handle optional screens** (permissions, backup) gracefully
5. **Mock all API calls** to avoid external dependencies
6. **Test multiple scenarios** (success, failure, 2FA, etc.)
7. **Keep tests isolated** - each test should be independent
8. **Use helper methods** for common flows to reduce duplication

## Future Enhancements

- [ ] Add tests for OTT-based login flow
- [ ] Test 2FA verification flow
- [ ] Test error scenarios (network errors, invalid credentials)
- [ ] Add performance profiling
- [ ] Test recovery key flow
- [ ] Add screenshot capture on failure
- [ ] Integrate with CI/CD pipeline

## Contributing

When adding new integration tests:

1. Follow the existing structure (helpers, mocks, tests)
2. Use Patrol Finders for widget selection
3. Mock all API calls using `MockApiInterceptor`
4. Add test configuration to `test_config.dart`
5. Document new helpers in this README
6. Ensure tests pass `flutter analyze` and `dart format`

## References

- [Flutter Integration Testing](https://docs.flutter.dev/testing/integration-tests)
- [Patrol Finders Documentation](https://pub.dev/packages/patrol_finders)
- [http_mock_adapter Documentation](https://pub.dev/packages/http_mock_adapter)
- [Dio Documentation](https://pub.dev/packages/dio)
