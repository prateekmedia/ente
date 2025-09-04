# Patrol Integration Tests for Ente Photos

This directory contains Patrol integration tests for the Ente Photos app.

## Setup Instructions

### Prerequisites

1. **Install Patrol CLI globally:**
   ```bash
   dart pub global activate patrol_cli
   ```

2. **Bootstrap Patrol for the project:**
   ```bash
   patrol bootstrap --flavor independent
   ```

3. **Ensure you have a device/simulator ready:**
   - For iOS: Open an iOS Simulator
   - For Android: Start an Android Emulator

### Running Tests

#### Development Mode (Interactive)

Run tests with hot restart capability:
```bash
patrol develop --target integration_test/login_flow_test.dart --flavor independent
```

Press 'r' in the terminal to hot restart the test.

#### Test Execution

Run tests in CI/headless mode:
```bash
patrol test --target integration_test/login_flow_test.dart --flavor independent
```

### Available Tests

1. **login_flow_test.dart** - Comprehensive login flow test covering:
   - Landing page and onboarding slides
   - New user sign up flow
   - Email verification
   - Password creation
   - Media permissions
   - Navigation to home screen
   - Existing user login flow

2. **patrol_simple_test.dart** - Basic test to verify Patrol setup

3. **test_bundle.dart** - Test configuration and bundle runner

## Test Structure

The login flow test follows the actual app flow:

1. **Landing Page** - Tests onboarding carousel and navigation
2. **Sign Up Flow** - Tests email entry, password creation, terms acceptance
3. **OTP Verification** - Tests email verification code entry
4. **Recovery Key** - Tests recovery key generation and saving
5. **Permissions** - Tests photo library permission requests
6. **Media Selection** - Tests backup folder selection
7. **Home Screen** - Verifies successful navigation to main app

## Troubleshooting

### iOS Issues

If you encounter CocoaPods issues:
```bash
cd ios
rm -rf Pods Podfile.lock
pod deintegrate
pod install
```

### Android Issues

Ensure you have the latest Android SDK and emulator:
```bash
flutter doctor --android-licenses
```

### Common Issues

1. **"No devices found"** - Start a simulator/emulator first
2. **"Patrol command not found"** - Install patrol_cli globally
3. **Test timeouts** - Increase timeout in PatrolTesterConfig
4. **Permission dialogs** - Tests handle native permissions automatically

## Writing New Tests

To add a new Patrol test:

1. Create a new file in `integration_test/`
2. Import patrol and flutter_test packages
3. Use `patrolTest()` instead of `testWidgets()`
4. Use `$` parameter for patrol-specific methods
5. Add to test_bundle.dart if needed

Example:
```dart
import 'package:patrol/patrol.dart';

void main() {
  patrolTest('My test', ($) async {
    await $.pumpAndSettle();
    await $.tap(find.text('Button'));
    await $.enterText(find.byType(TextField), 'text');
    await $.native.grantPermission();
  });
}
```

## CI/CD Integration

For CI environments, use:
```bash
patrol build ios --flavor independent
patrol build android --flavor independent
```

Then run tests with:
```bash
patrol test --flavor independent
```