import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:photos/main.dart' as app;

void main() {
  patrolTest(
    'Login flow test',
    framePolicy: LiveTestWidgetsFlutterBindingFramePolicy.fullyLive,
    ($) async {
      // Load environment variables
      await dotenv.load(fileName: 'integration_test/.env');
      final testEmail = dotenv.env['TEST_EMAIL'] ?? '';
      final testPassword = dotenv.env['TEST_PASSWORD'] ?? '';
      
      if (testEmail.isEmpty || testPassword.isEmpty) {
        throw Exception('Test credentials not found in .env file');
      }
      
      // Initialize and launch the app
      await app.main();
      
      // Wait for app to fully initialize
      print('TEST: Waiting for app initialization...');
      await Future.delayed(const Duration(seconds: 10));
      await $.pumpAndSettle(timeout: const Duration(seconds: 30));
      
      print('TEST: Looking for landing page elements...');
      
      // Check if we're on the landing page
      // First try to skip onboarding if present
      try {
        // Look for "Skip" button if onboarding is shown
        final skipButton = find.text('Skip');
        if (skipButton.evaluate().isNotEmpty) {
          print('TEST: Found Skip button, tapping it...');
          await $(skipButton).tap();
          await $.pumpAndSettle();
        }
      } catch (e) {
        print('TEST: No skip button found, continuing...');
      }
      
      // Look for "Existing user" or "Sign in" button
      try {
        // Try to find "Existing user" button
        if (find.text('Existing user').evaluate().isNotEmpty) {
          print('TEST: Found "Existing user" button, tapping...');
          await $('Existing user').tap();
          await $.pumpAndSettle();
        } else if (find.text('Sign in').evaluate().isNotEmpty) {
          print('TEST: Found "Sign in" button, tapping...');
          await $('Sign in').tap();
          await $.pumpAndSettle();
        }
      } catch (e) {
        print('TEST: Error finding login button: $e');
      }
      
      // Wait for email field to appear
      await Future.delayed(const Duration(seconds: 3));
      await $.pumpAndSettle();
      
      print('TEST: Looking for email input field...');
      
      // Enter email
      try {
        // Look for TextField with email keyboard type
        final emailField = find.byWidgetPredicate(
          (widget) => widget is TextField && 
                      (widget.decoration?.hintText?.toLowerCase().contains('email') ?? false ||
                       widget.decoration?.labelText?.toLowerCase().contains('email') ?? false),
        );
        
        if (emailField.evaluate().isNotEmpty) {
          print('TEST: Found email field, entering email...');
          await $(emailField).enterText(testEmail);
        } else {
          // Try to find any TextField
          final textField = find.byType(TextField);
          if (textField.evaluate().isNotEmpty) {
            print('TEST: Found text field, assuming it\'s email...');
            await $(textField.first).enterText(testEmail);
          }
        }
        
        await $.pumpAndSettle();
      } catch (e) {
        print('TEST: Error entering email: $e');
      }
      
      // Look for continue/next button
      try {
        if (find.text('Continue').evaluate().isNotEmpty) {
          print('TEST: Found Continue button, tapping...');
          await $('Continue').tap();
        } else if (find.text('Next').evaluate().isNotEmpty) {
          print('TEST: Found Next button, tapping...');
          await $('Next').tap();
        } else if (find.text('Sign in').evaluate().isNotEmpty) {
          print('TEST: Found Sign in button, tapping...');
          await $('Sign in').tap();
        }
        
        await $.pumpAndSettle();
      } catch (e) {
        print('TEST: Error clicking continue: $e');
      }
      
      // Wait for OTP or password screen
      await Future.delayed(const Duration(seconds: 5));
      await $.pumpAndSettle();
      
      print('TEST: Looking for password field...');
      
      // Enter password
      try {
        // Look for password TextField
        final passwordField = find.byWidgetPredicate(
          (widget) => widget is TextField && 
                      (widget.obscureText == true ||
                       widget.decoration?.hintText?.toLowerCase().contains('password') ?? false ||
                       widget.decoration?.labelText?.toLowerCase().contains('password') ?? false),
        );
        
        if (passwordField.evaluate().isNotEmpty) {
          print('TEST: Found password field, entering password...');
          await $(passwordField).enterText(testPassword);
        } else {
          // Try to find any TextField (might be the second one)
          final textFields = find.byType(TextField);
          if (textFields.evaluate().length > 1) {
            print('TEST: Found multiple text fields, using second one for password...');
            await $(textFields.at(1)).enterText(testPassword);
          } else if (textFields.evaluate().isNotEmpty) {
            print('TEST: Found text field, assuming it\'s password...');
            await $(textFields.first).enterText(testPassword);
          }
        }
        
        await $.pumpAndSettle();
      } catch (e) {
        print('TEST: Error entering password: $e');
      }
      
      // Submit login
      try {
        if (find.text('Sign in').evaluate().isNotEmpty) {
          print('TEST: Found Sign in button, tapping...');
          await $('Sign in').tap();
        } else if (find.text('Login').evaluate().isNotEmpty) {
          print('TEST: Found Login button, tapping...');
          await $('Login').tap();
        } else if (find.text('Continue').evaluate().isNotEmpty) {
          print('TEST: Found Continue button, tapping...');
          await $('Continue').tap();
        }
        
        await $.pumpAndSettle();
      } catch (e) {
        print('TEST: Error submitting login: $e');
      }
      
      // Wait for login to complete
      print('TEST: Waiting for login to complete...');
      await Future.delayed(const Duration(seconds: 10));
      await $.pumpAndSettle();
      
      // Handle any permission dialogs
      try {
        if (await $.native.isPermissionDialogVisible()) {
          print('TEST: Permission dialog visible, granting...');
          await $.native.grantPermissionWhenInUse();
        }
      } catch (e) {
        print('TEST: No permission dialog or error: $e');
      }
      
      // Check if we've reached the home screen
      print('TEST: Checking for home screen elements...');
      
      // Look for signs we're logged in
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
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}