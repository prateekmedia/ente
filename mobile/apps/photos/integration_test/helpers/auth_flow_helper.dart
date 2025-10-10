import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:patrol_finders/patrol_finders.dart";
import "../mocks/test_config.dart";

/// AuthFlowHelper provides reusable methods for testing authentication flows
/// using Patrol finders for better widget selection
class AuthFlowHelper {
  final PatrolTester $;

  AuthFlowHelper(this.$);

  /// Navigate from landing page to login page by tapping sign-in button
  Future<void> navigateToLoginPage() async {
    print("[AUTH_HELPER] Looking for sign-in button");
    // Find and tap the sign-in button using patrol finder
    // Use ValueKey for reliable finding
    final signInButton = $(#signInButton);

    print("[AUTH_HELPER] Waiting for sign-in button to be visible");
    await signInButton.waitUntilVisible();
    print("[AUTH_HELPER] Tapping sign-in button");
    await signInButton.tap();

    // Use pump() instead of pumpAndSettle()
    await $.pump();
    await Future.delayed(const Duration(milliseconds: TestConfig.mediumDelay));
    print("[AUTH_HELPER] Navigation to login page complete");
  }

  /// Enter email on login page and proceed
  Future<void> enterEmail(String email) async {
    print("[AUTH_HELPER] Looking for email input field");
    // Find email input field - use first TextFormField
    final emailField = $(TextFormField).first;

    print("[AUTH_HELPER] Waiting for email field to be visible");
    await emailField.waitUntilVisible();
    print("[AUTH_HELPER] Entering email: $email");
    await emailField.enterText(email);

    // Close the keyboard by unfocusing
    print("[AUTH_HELPER] Closing keyboard");
    $.tester.testTextInput.hide();

    // Wait for UI to rebuild after keyboard dismissal
    print("[AUTH_HELPER] Waiting for UI to settle after keyboard close");
    await $.pump();
    await Future.delayed(
      const Duration(milliseconds: TestConfig.veryLongDelay),
    );
    await $.pump();
    print("[AUTH_HELPER] UI settled, looking for login button");

    // Tap the login button to proceed - use ValueKey
    final loginButton = $(#logInButton);

    print("[AUTH_HELPER] Waiting for login button to be visible");
    await loginButton.waitUntilVisible();
    print("[AUTH_HELPER] Tapping login button");
    await loginButton.tap();

    // Use pump() instead of pumpAndSettle()
    await $.pump();

    // Wait for navigation and any API calls
    print("[AUTH_HELPER] Waiting for navigation and API calls");
    await Future.delayed(
      const Duration(milliseconds: TestConfig.veryLongDelay),
    );
    print("[AUTH_HELPER] Email entry complete");
  }

  /// Enter password on password verification page and proceed
  Future<void> enterPassword(String password) async {
    print("[AUTH_HELPER] Looking for password input field");
    // Find password input field by ValueKey
    final passwordField = $(#passwordInputField);

    print("[AUTH_HELPER] Waiting for password field to be visible");
    await passwordField.waitUntilVisible();
    print("[AUTH_HELPER] Entering password");
    await passwordField.enterText(password);

    // Use pump() instead of pumpAndSettle()
    await $.pump();
    await Future.delayed(const Duration(milliseconds: TestConfig.shortDelay));
    print("[AUTH_HELPER] Password entered, looking for verify button");

    // Tap verify password button by ValueKey
    final verifyButton = $(#verifyPasswordButton);

    print("[AUTH_HELPER] Waiting for verify button to be visible");
    await verifyButton.waitUntilVisible();
    print("[AUTH_HELPER] Tapping verify password button");
    await verifyButton.tap();

    // Use pump() instead of pumpAndSettle()
    await $.pump();

    // Wait for authentication and navigation
    print("[AUTH_HELPER] Waiting for authentication and navigation");
    await Future.delayed(
      const Duration(milliseconds: TestConfig.veryLongDelay),
    );
    print("[AUTH_HELPER] Password entry complete");
  }

  /// Complete full password-based login flow
  Future<void> loginWithPassword({
    String? email,
    String? password,
  }) async {
    await navigateToLoginPage();
    await enterEmail(email ?? TestConfig.testEmail);
    await enterPassword(password ?? TestConfig.testPassword);
  }

  /// Enter OTT code on verification page
  Future<void> enterOttCode(String code) async {
    // Find OTT input field - usually first TextFormField
    final ottField = $(TextFormField).first;

    await ottField.waitUntilVisible();
    await ottField.enterText(code);
    await $.pumpAndSettle();

    // Wait for auto-verification or find verify button
    await Future.delayed(const Duration(milliseconds: TestConfig.longDelay));
  }

  /// Complete full OTT-based login flow
  Future<void> loginWithOtt({
    String? email,
    String? ottCode,
  }) async {
    await navigateToLoginPage();
    await enterEmail(email ?? TestConfig.testEmail);
    await enterOttCode(ottCode ?? TestConfig.testOttCode);
  }

  /// Enter 2FA code on two-factor authentication page
  Future<void> enter2FACode(String code) async {
    // Find 2FA input field
    final twoFAField = $(TextFormField).first;

    await twoFAField.waitUntilVisible();
    await twoFAField.enterText(code);
    await $.pumpAndSettle();

    await Future.delayed(const Duration(milliseconds: TestConfig.longDelay));
  }

  /// Dismiss update app dialog if it appears
  Future<void> dismissUpdateDialogIfPresent() async {
    print("[AUTH_HELPER] Attempting to dismiss update dialog");
    try {
      // Tap at top-left corner to dismiss
      await $.tester.tapAt(Offset.zero);
      await $.pumpAndSettle();
      print("[AUTH_HELPER] Update dialog dismissed (or wasn't present)");
    } catch (e) {
      // Dialog might not be present, continue
      print("[AUTH_HELPER] No update dialog to dismiss");
    }
  }

  /// Skip backup flow if prompted
  Future<void> skipBackupIfPrompted() async {
    print("[AUTH_HELPER] Checking for backup skip button");
    try {
      // Find and tap skip backup button by ValueKey
      final skipButton = $(#skipBackupButton);

      if (skipButton.exists) {
        print("[AUTH_HELPER] Skip backup button found, tapping");
        await skipButton.tap();
        await $.pumpAndSettle();
        await Future.delayed(
          const Duration(milliseconds: TestConfig.mediumDelay),
        );
        print("[AUTH_HELPER] Backup skipped");
      } else {
        print("[AUTH_HELPER] No backup skip button found");
      }
    } catch (e) {
      // Skip button might not exist
      print("[AUTH_HELPER] Skip backup button not present: $e");
    }
  }

  /// Skip permission request if prompted
  Future<void> skipPermissionIfPrompted() async {
    print("[AUTH_HELPER] Checking for permission prompt");
    try {
      // Give UI time to fully render
      await Future.delayed(
        const Duration(milliseconds: TestConfig.veryLongDelay),
      );
      await $.pump();

      // Look for the skip button specifically by its ValueKey
      final skipButton = $(#skipPermissionButton);

      // Also check if the grant permission button exists to confirm we're on the right screen
      final grantButton = $(#grantPermissionButton);

      if (skipButton.exists) {
        print("[AUTH_HELPER] Permission screen detected");
        print("[AUTH_HELPER] Skip button exists: ${skipButton.exists}");
        print("[AUTH_HELPER] Grant button exists: ${grantButton.exists}");

        // CRITICAL: Wait for skip button to be fully visible and interactive
        await skipButton.waitUntilVisible();
        await Future.delayed(const Duration(milliseconds: 1000));

        print(
          "[AUTH_HELPER] About to tap ONLY the skip button (NOT grant permission)...",
        );

        // Tap skip button using the ValueKey finder
        await skipButton.tap();

        print("[AUTH_HELPER] Skip button tap command sent");

        // Wait for navigation after skipping permissions
        await Future.delayed(
          const Duration(milliseconds: TestConfig.veryLongDelay),
        );
        await $.pump();

        print(
          "[AUTH_HELPER] Permission screen should be skipped, navigating away",
        );
      } else {
        print(
          "[AUTH_HELPER] Skip button not found - permission screen might not be showing",
        );
      }
    } catch (e) {
      // Permission prompt might not exist
      print("[AUTH_HELPER] Error during skip permission: $e");
    }
  }

  /// Verify that user has reached the home screen
  Future<void> verifyHomeScreen() async {
    print("[AUTH_HELPER] Verifying home screen");

    // Wait a bit longer for home screen to fully load and render
    await Future.delayed(
      const Duration(milliseconds: TestConfig.veryLongDelay),
    );
    await $.pump();

    // Look for indicators that we're on the home screen
    bool foundHomeIndicator = false;

    // Try to find PageView (used for swiping between tabs)
    print("[AUTH_HELPER] Checking for PageView");
    if ($(PageView).exists) {
      print("[AUTH_HELPER] Found PageView");
      foundHomeIndicator = true;
    }

    // Try to find any Icon widgets (bottom nav has icons)
    if (!foundHomeIndicator) {
      print("[AUTH_HELPER] Checking for Icon widgets");
      if ($(Icon).exists) {
        print("[AUTH_HELPER] Found Icon widgets");
        foundHomeIndicator = true;
      }
    }

    // Try to find SafeArea (home screen has SafeArea)
    if (!foundHomeIndicator) {
      print("[AUTH_HELPER] Checking for SafeArea");
      if ($(SafeArea).exists) {
        print("[AUTH_HELPER] Found SafeArea");
        foundHomeIndicator = true;
      }
    }

    if (!foundHomeIndicator) {
      print("[AUTH_HELPER] WARNING: No home screen indicators found!");
    }

    expect(
      foundHomeIndicator,
      true,
      reason: "Should be on home screen after successful login",
    );
    print("[AUTH_HELPER] Home screen verification complete!");
  }

  /// Complete full login flow and reach home screen
  Future<void> completeLoginFlow({
    String? email,
    String? password,
    bool skip2FA = true,
  }) async {
    await dismissUpdateDialogIfPresent();
    await loginWithPassword(email: email, password: password);
    await dismissUpdateDialogIfPresent();
    await skipPermissionIfPrompted();
    await skipBackupIfPrompted();
    await verifyHomeScreen();
  }
}
