import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photos/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Login flow test', (WidgetTester tester) async {
    // Load environment variables
    await dotenv.load(fileName: 'integration_test/.env');
    final testEmail = dotenv.env['TEST_EMAIL'] ?? '';
    final testPassword = dotenv.env['TEST_PASSWORD'] ?? '';
    
    if (testEmail.isEmpty || testPassword.isEmpty) {
      throw Exception('Test credentials not found in .env file');
    }
    
    // Initialize and launch the app
    await app.main();
    await tester.pumpAndSettle(timeout: const Duration(seconds: 10));
    
    print('TEST: Looking for landing page elements...');
    
    // Tap on "Existing user" button
    final existingUserButton = find.text('Existing user');
    if (existingUserButton.evaluate().isNotEmpty) {
      print('TEST: Found "Existing user" button, tapping...');
      await tester.tap(existingUserButton);
      await tester.pumpAndSettle();
    }
    
    // Wait for email field to appear
    await tester.pumpAndSettle(timeout: const Duration(seconds: 3));
    
    print('TEST: Looking for email input field...');
    
    // Enter email
    final emailField = find.byWidgetPredicate(
      (widget) => widget is TextField && 
                  (widget.decoration?.hintText?.toLowerCase().contains('email') ?? false ||
                   widget.decoration?.labelText?.toLowerCase().contains('email') ?? false),
    );
    
    if (emailField.evaluate().isNotEmpty) {
      print('TEST: Found email field, entering email...');
      await tester.enterText(emailField, testEmail);
    } else {
      // Try to find any TextField
      final textField = find.byType(TextField);
      if (textField.evaluate().isNotEmpty) {
        print('TEST: Found text field, assuming it\'s email...');
        await tester.enterText(textField.first, testEmail);
      }
    }
    
    await tester.pumpAndSettle();
    
    // Look for continue/next button
    final continueButton = find.text('Continue');
    if (continueButton.evaluate().isNotEmpty) {
      print('TEST: Found Continue button, tapping...');
      await tester.tap(continueButton);
    } else {
      final nextButton = find.text('Next');
      if (nextButton.evaluate().isNotEmpty) {
        print('TEST: Found Next button, tapping...');
        await tester.tap(nextButton);
      }
    }
    
    await tester.pumpAndSettle(timeout: const Duration(seconds: 5));
    
    print('TEST: Looking for password field...');
    
    // Enter password
    final passwordField = find.byWidgetPredicate(
      (widget) => widget is TextField && 
                  (widget.obscureText == true ||
                   widget.decoration?.hintText?.toLowerCase().contains('password') ?? false ||
                   widget.decoration?.labelText?.toLowerCase().contains('password') ?? false),
    );
    
    if (passwordField.evaluate().isNotEmpty) {
      print('TEST: Found password field, entering password...');
      await tester.enterText(passwordField, testPassword);
    } else {
      // Try to find any TextField (might be the second one)
      final textFields = find.byType(TextField);
      if (textFields.evaluate().length > 1) {
        print('TEST: Found multiple text fields, using second one for password...');
        await tester.enterText(textFields.at(1), testPassword);
      } else if (textFields.evaluate().isNotEmpty) {
        print('TEST: Found text field, assuming it\'s password...');
        await tester.enterText(textFields.first, testPassword);
      }
    }
    
    await tester.pumpAndSettle();
    
    // Submit login
    final signInButton = find.text('Sign in');
    if (signInButton.evaluate().isNotEmpty) {
      print('TEST: Found Sign in button, tapping...');
      await tester.tap(signInButton);
    } else {
      final loginButton = find.text('Login');
      if (loginButton.evaluate().isNotEmpty) {
        print('TEST: Found Login button, tapping...');
        await tester.tap(loginButton);
      } else {
        final continueBtn = find.text('Continue');
        if (continueBtn.evaluate().isNotEmpty) {
          print('TEST: Found Continue button, tapping...');
          await tester.tap(continueBtn);
        }
      }
    }
    
    // Wait for login to complete
    print('TEST: Waiting for login to complete...');
    await tester.pumpAndSettle(timeout: const Duration(seconds: 10));
    
    // Look for and skip media selection if present
    print('TEST: Looking for media selection screen...');
    
    // Try to find and tap skip button if present
    final skipButton = find.text('Skip');
    if (skipButton.evaluate().isNotEmpty) {
      print('TEST: Found Skip button for media selection, tapping...');
      await tester.tap(skipButton);
      await tester.pumpAndSettle();
    } else {
      // Also try "Maybe later" or "Not now"
      final maybeLaterButton = find.text('Maybe later');
      if (maybeLaterButton.evaluate().isNotEmpty) {
        print('TEST: Found "Maybe later" button, tapping...');
        await tester.tap(maybeLaterButton);
        await tester.pumpAndSettle();
      } else {
        final notNowButton = find.text('Not now');
        if (notNowButton.evaluate().isNotEmpty) {
          print('TEST: Found "Not now" button, tapping...');
          await tester.tap(notNowButton);
          await tester.pumpAndSettle();
        }
      }
    }
    
    // Wait a bit more for home screen
    await tester.pumpAndSettle(timeout: const Duration(seconds: 5));
    
    // Check if we've reached the home screen
    print('TEST: Checking for home screen elements...');
    
    bool isLoggedIn = false;
    
    // Check for common home screen elements
    if (find.byType(BottomNavigationBar).evaluate().isNotEmpty) {
      print('TEST: Found BottomNavigationBar - login successful!');
      isLoggedIn = true;
    } else if (find.text('Photos').evaluate().isNotEmpty) {
      print('TEST: Found Photos text - likely on home screen');
      isLoggedIn = true;
    } else if (find.text('Albums').evaluate().isNotEmpty) {
      print('TEST: Found Albums text - likely on home screen');
      isLoggedIn = true;
    }
    
    expect(isLoggedIn, true, reason: 'Should be logged in after entering credentials');
    
    print('TEST: Login flow test completed successfully!');
  });
}