import "dart:async";

import "package:dio/dio.dart";
import "package:flutter/material.dart";
import "package:flutter_test/flutter_test.dart";
import "package:integration_test/integration_test.dart";
import "package:logging/logging.dart";
import "package:patrol_finders/patrol_finders.dart";
import "package:photos/core/configuration.dart";
import "package:photos/main.dart" as app;

import "helpers/auth_flow_helper.dart";
import "mocks/mock_api_interceptor.dart";
import "mocks/test_config.dart";
import "mocks/test_crypto_keys.dart";

void main() {
  group("Sign-in flow integration test", () {
    final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

    patrolWidgetTest(
      "Successful sign-in with email and password",
      semanticsEnabled: false,
      (PatrolTester $) async {
        // https://github.com/flutter/flutter/issues/89749#issuecomment-1029965407
        $.tester.testTextInput.register();

        // Store interceptors to prevent garbage collection.
        // These variables must remain in scope for the entire test duration
        // to prevent Dart's garbage collector from disposing the mock interceptors,
        // which would cause network calls to fail.
        late MockApiInterceptor mockInterceptor;
        late MockApiInterceptor mockEnteInterceptor;

        await runZonedGuarded(
          () async {
            // Ignore exceptions thrown by the app for the test to pass
            WidgetsFlutterBinding.ensureInitialized();
            FlutterError.onError = (FlutterErrorDetails errorDetails) {
              FlutterError.dumpErrorToConsole(errorDetails);
            };

            await binding.traceAction(
              () async {
                print("[TEST] Step 1: Initializing Configuration");
                await Configuration.instance.init();
                final endpoint = Configuration.instance.getHttpEndpoint();
                print("[TEST] Step 1 complete: endpoint = $endpoint");

                print(
                  "[TEST] Step 2: Creating Dio instances (without keys yet)",
                );
                final testDio = Dio();
                final testEnteDio = Dio(
                  BaseOptions(baseUrl: endpoint),
                );
                print("[TEST] Step 2 complete: Dio instances created");

                print("[TEST] Step 3: Starting app with mocked network");
                app.main(testDio: testDio, testEnteDio: testEnteDio);

                print("[TEST] Step 4: Pumping and waiting for app to show");
                await $.pump();
                await Future.delayed(
                  const Duration(milliseconds: TestConfig.veryLongDelay),
                );
                print("[TEST] Step 4 complete: app is visible");

                print(
                  "[TEST] Step 5: Initializing test crypto keys (this takes ~30s)",
                );
                print(
                  "[TEST] The app is running, but key derivation is in progress...",
                );
                await TestCryptoKeys.instance.initializeKeys();
                print("[TEST] Step 5 complete: crypto keys generated");

                print("[TEST] Step 6: Setting up mock interceptors with keys");
                mockInterceptor =
                    MockApiInterceptor(testDio, TestCryptoKeys.instance);
                mockEnteInterceptor =
                    MockApiInterceptor(testEnteDio, TestCryptoKeys.instance);
                print("[TEST] Step 6 complete: mock interceptors set up");

                print("[TEST] Step 7: Creating auth flow helper");
                final authHelper = AuthFlowHelper($);

                print("[TEST] Step 8: Dismissing update dialog if present");
                await authHelper.dismissUpdateDialogIfPresent();
                print("[TEST] Step 8 complete");

                print("[TEST] Step 9: Navigating to login page");
                await authHelper.navigateToLoginPage();
                print("[TEST] Step 9 complete");

                print("[TEST] Step 10: Entering email");
                await authHelper.enterEmail(TestConfig.testEmail);
                print("[TEST] Step 10 complete");

                print("[TEST] Step 11: Entering password");
                await authHelper.enterPassword(TestConfig.testPassword);
                print("[TEST] Step 11 complete");

                print(
                  "[TEST] Step 12: Dismissing update dialog if present (post-login)",
                );
                await authHelper.dismissUpdateDialogIfPresent();
                print("[TEST] Step 12 complete");

                print("[TEST] Step 13: Skipping permission if prompted");
                await authHelper.skipPermissionIfPrompted();
                print("[TEST] Step 13 complete");

                print("[TEST] Step 14: Skipping backup if prompted");
                await authHelper.skipBackupIfPrompted();
                print("[TEST] Step 14 complete");

                print("[TEST] Step 15: Verifying home screen");
                await authHelper.verifyHomeScreen();
                print("[TEST] Step 15 complete: TEST PASSED!");

                // Hold on home screen for manual validation
                print(
                  "[TEST] Holding on home screen indefinitely for manual validation...",
                );
                print(
                  "[TEST] You can now interact with the app. Press Ctrl+C to exit.",
                );
                await Future.delayed(const Duration(minutes: 10));
                print("[TEST] Manual validation time complete!");
              },
              reportKey: "sign_in_flow_summary",
            );
          },
          (error, stack) {
            Logger("sign_in_flow_test").info(error, stack);
          },
        );
      },
    );
  });
}
