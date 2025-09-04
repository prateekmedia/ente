import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';
import 'package:photos/main.dart' as app;

void main() {
  patrolTest(
    'Complete login flow test - from onboarding to home screen',
    ($) async {
      // Start the app
      app.main();
      
      // Use longer timeout for splash screen
      await $.pumpAndSettle(timeout: const Duration(seconds: 10));
      
      // Additional wait to ensure splash completes
      await Future.delayed(const Duration(seconds: 5));
      await $.pumpAndSettle();
      
      // Test 1: Landing Page - Onboarding Slides
      await _testLandingPageOnboarding($);
      
      // Test 2: Sign Up Flow
      await _testSignUpFlow($);
      
      // Test 3: Permissions and Media Selection
      await _testPermissionsAndMediaSelection($);
      
      // Test 4: Verify Home Screen
      await _testHomeScreen($);
    },
  );

  patrolTest(
    'Existing user login flow test',
    ($) async {
      // Start the app
      app.main();
      
      // Use longer timeout for splash screen
      await $.pumpAndSettle(timeout: const Duration(seconds: 10));
      
      // Additional wait to ensure splash completes
      await Future.delayed(const Duration(seconds: 5));
      await $.pumpAndSettle();
      
      // Skip onboarding and go to login
      await _skipOnboardingAndLogin($);
      
      // Test password entry
      await _testPasswordEntry($);
      
      // Test permissions and media
      await _testPermissionsAndMediaSelection($);
      
      // Verify home screen
      await _testHomeScreen($);
    },
  );
}

// Helper function to test landing page and onboarding
Future<void> _testLandingPageOnboarding(PatrolIntegrationTester $) async {
  // Wait for landing page to load
  await $.pumpAndSettle();
  
  // Check if we're on the landing page with onboarding slides
  expect(find.text('Private backups'), findsWidgets);
  
  // Swipe through onboarding slides
  await $.scrollUntilVisible(
    finder: find.text('Available everywhere'),
    view: find.byType(PageView),
  );
  
  // Go back to first slide
  await $.scrollUntilVisible(
    finder: find.text('Private backups'),
    view: find.byType(PageView),
    scrollDirection: AxisDirection.right,
  );
  
  // Tap on "New to Ente" button for sign up
  final newUserButton = find.text('New to Ente');
  if (newUserButton.evaluate().isNotEmpty) {
    await $.tap(newUserButton);
  } else {
    // Alternative text
    await $.tap(find.text('Sign up'));
  }
  
  await $.pumpAndSettle();
}

// Helper function to test the sign up flow
Future<void> _testSignUpFlow(PatrolIntegrationTester $) async {
  // Email Entry Page - Step 1 of 4
  expect(find.text('Step 1 of 4'), findsOneWidget);
  
  // Enter email
  final emailField = find.byType(TextField).first;
  await $.enterText(emailField, 'test.user@example.com');
  await $.pumpAndSettle();
  
  // Create password
  final passwordField = find.byType(TextField).at(1);
  await $.enterText(passwordField, 'TestPassword123!@#');
  await $.pumpAndSettle();
  
  // Confirm password
  final confirmPasswordField = find.byType(TextField).at(2);
  await $.enterText(confirmPasswordField, 'TestPassword123!@#');
  await $.pumpAndSettle();
  
  // Check password strength indicator
  expect(find.text('Strong'), findsOneWidget);
  
  // Select referral source
  final referralDropdown = find.byType(DropdownButton<String>);
  if (referralDropdown.evaluate().isNotEmpty) {
    await $.tap(referralDropdown);
    await $.pumpAndSettle();
    await $.tap(find.text('Friends or family').last);
    await $.pumpAndSettle();
  }
  
  // Accept terms and conditions
  final termsCheckbox = find.byType(Checkbox).first;
  await $.tap(termsCheckbox);
  await $.pumpAndSettle();
  
  // Accept privacy policy
  final privacyCheckbox = find.byType(Checkbox).at(1);
  await $.tap(privacyCheckbox);
  await $.pumpAndSettle();
  
  // Accept encryption acknowledgment
  final encryptionCheckbox = find.byType(Checkbox).at(2);
  await $.tap(encryptionCheckbox);
  await $.pumpAndSettle();
  
  // Tap create account button
  await $.tap(find.text('Create account'));
  await $.pumpAndSettle();
  
  // OTP Verification Page - Step 2 of 4
  expect(find.text('Step 2 of 4'), findsOneWidget);
  
  // In a real test, we would need to get the OTP from email
  // For testing, we'll simulate entering an OTP
  final otpFields = find.byType(TextField);
  if (otpFields.evaluate().length >= 6) {
    // Enter 6-digit OTP
    await $.enterText(otpFields.at(0), '1');
    await $.enterText(otpFields.at(1), '2');
    await $.enterText(otpFields.at(2), '3');
    await $.enterText(otpFields.at(3), '4');
    await $.enterText(otpFields.at(4), '5');
    await $.enterText(otpFields.at(5), '6');
  } else {
    // Single OTP field
    await $.enterText(otpFields.first, '123456');
  }
  
  await $.pumpAndSettle();
  
  // Tap verify button
  await $.tap(find.text('Verify'));
  await $.pumpAndSettle();
  await Future.delayed(const Duration(seconds: 2));
  
  // Recovery Key Page - Step 3 of 4
  if (find.text('Step 3 of 4').evaluate().isNotEmpty) {
    expect(find.text('Recovery key'), findsOneWidget);
    
    // The recovery key would be displayed here
    // Tap continue or save button
    final continueButton = find.text('Continue');
    if (continueButton.evaluate().isNotEmpty) {
      await $.tap(continueButton);
    } else {
      await $.tap(find.text('I have saved my recovery key'));
    }
    
    await $.pumpAndSettle();
  }
}

// Helper function to test permissions and media selection
Future<void> _testPermissionsAndMediaSelection(PatrolIntegrationTester $) async {
  // Handle native photo permissions dialog
  if (await $.native.isPermissionDialogVisible()) {
    await $.native.grantPermissionWhenInUse();
    await $.pumpAndSettle();
  }
  
  // Alternative permission handling for different OS versions
  final allowButton = find.text('Allow');
  if (allowButton.evaluate().isNotEmpty) {
    await $.tap(allowButton);
    await $.pumpAndSettle();
  }
  
  // Grant permissions using native API
  try {
    await $.native.grantPermissionOnlyThisTime();
  } catch (e) {
    // Permission might already be granted or not needed in test
    debugPrint('Permission handling: $e');
  }
  
  // Wait for photos to load
  await $.pumpAndSettle();
  await Future.delayed(const Duration(seconds: 3));
  
  // Loading Photos Widget
  if (find.text('Loading your photos...').evaluate().isNotEmpty) {
    // Wait for loading to complete
    await $.pumpAndSettle();
    await Future.delayed(const Duration(seconds: 5));
  }
  
  // Backup folder selection might appear
  final startBackupButton = find.text('Start backup');
  if (startBackupButton.evaluate().isNotEmpty) {
    await $.tap(startBackupButton);
    await $.pumpAndSettle();
    
    // Select folders to backup
    final selectAllButton = find.text('Select all');
    if (selectAllButton.evaluate().isNotEmpty) {
      await $.tap(selectAllButton);
      await $.pumpAndSettle();
    }
    
    // Confirm backup
    final backupButton = find.text('Backup');
    if (backupButton.evaluate().isNotEmpty) {
      await $.tap(backupButton);
      await $.pumpAndSettle();
    }
  }
}

// Helper function to verify home screen
Future<void> _testHomeScreen(PatrolIntegrationTester $) async {
  // Wait for home screen to load
  await $.pumpAndSettle();
  await Future.delayed(const Duration(seconds: 2));
  
  // Verify we're on the home screen by checking for navigation tabs
  expect(find.text('Photos'), findsOneWidget);
  expect(find.text('Albums'), findsOneWidget);
  expect(find.text('Shared'), findsOneWidget);
  
  // Verify gallery is visible
  final galleryWidget = find.byType(GridView);
  if (galleryWidget.evaluate().isEmpty) {
    // Alternative: Check for empty state
    expect(
      find.textContaining(RegExp(r'(No photos|Start backup|Add photos)')),
      findsWidgets,
    );
  } else {
    expect(galleryWidget, findsOneWidget);
  }
  
  // Test navigation between tabs
  await $.tap(find.text('Albums'));
  await $.pumpAndSettle();
  
  await $.tap(find.text('Shared'));
  await $.pumpAndSettle();
  
  await $.tap(find.text('Photos'));
  await $.pumpAndSettle();
  
  // Verify settings is accessible
  final settingsIcon = find.byIcon(Icons.settings);
  if (settingsIcon.evaluate().isNotEmpty) {
    await $.tap(settingsIcon);
    await $.pumpAndSettle();
    
    // Verify settings page loaded
    expect(find.text('Settings'), findsOneWidget);
    
    // Go back to home
    await $.tap(find.byType(BackButton));
    await $.pumpAndSettle();
  }
}

// Helper function for existing user login
Future<void> _skipOnboardingAndLogin(PatrolIntegrationTester $) async {
  // Wait for landing page
  await $.pumpAndSettle();
  
  // Tap on "Existing User" button
  final existingUserButton = find.text('Existing user');
  if (existingUserButton.evaluate().isNotEmpty) {
    await $.tap(existingUserButton);
  } else {
    await $.tap(find.text('Sign in'));
  }
  
  await $.pumpAndSettle();
  
  // Login Page - Enter email
  final emailField = find.byType(TextField).first;
  await $.enterText(emailField, 'existing.user@example.com');
  await $.pumpAndSettle();
  
  // Tap login button
  await $.tap(find.text('Log in'));
  await $.pumpAndSettle();
  
  // Handle OTP verification if required
  if (find.text('Verify email').evaluate().isNotEmpty) {
    // Enter OTP
    final otpField = find.byType(TextField).first;
    await $.enterText(otpField, '123456');
    await $.pumpAndSettle();
    
    await $.tap(find.text('Verify'));
    await $.pumpAndSettle();
  }
}

// Helper function for password entry
Future<void> _testPasswordEntry(PatrolIntegrationTester $) async {
  // Password verification page
  if (find.text('Enter password').evaluate().isNotEmpty) {
    final passwordField = find.byType(TextField).first;
    await $.enterText(passwordField, 'ExistingPassword123!');
    await $.pumpAndSettle();
    
    // Tap login/unlock button
    final unlockButton = find.text('Unlock');
    if (unlockButton.evaluate().isNotEmpty) {
      await $.tap(unlockButton);
    } else {
      await $.tap(find.text('Log in'));
    }
    
    await $.pumpAndSettle();
  }
  
  // Handle 2FA if enabled
  if (find.text('Two-factor authentication').evaluate().isNotEmpty) {
    final tfaField = find.byType(TextField).first;
    await $.enterText(tfaField, '123456');
    await $.pumpAndSettle();
    
    await $.tap(find.text('Verify'));
    await $.pumpAndSettle();
  }
}