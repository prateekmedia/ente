# Integration Test Progress Report

## Summary

This document tracks the progress of creating an integration test for the Ente Photos sign-in flow with mocked API endpoints.

## What Works ✅

### 1. Test Infrastructure
- ✅ Created `MockApiInterceptor` with `http_mock_adapter` to intercept Dio requests
- ✅ Created `AuthFlowHelper` with reusable test flow methods
- ✅ Created `TestConfig` with centralized test constants
- ✅ Implemented dependency injection in `NetworkClient` and `main()` to support mock Dio instances

### 2. Mock API Endpoints
- ✅ Mock: GET `/users/srp/attributes` - Returns SRP salt and parameters
- ✅ Mock: POST `/users/srp/create-session` - Creates SRP session and returns srpB
- ✅ Mock: POST `/users/srp/verify-session` - Verifies SRP session
- ✅ Mock: POST `/users/ott` - Sends one-time token to email
- ✅ Mock: POST `/users/verify-email` - Verifies OTT
- ✅ Mock: POST `/users/two-factor/verify` - Verifies 2FA code
- ✅ Mock: GET `/users/two-factor/status` - Returns 2FA status

### 3. Cryptographic Parameters
- ✅ Fixed salt sizes (16 bytes for argon2)
- ✅ Fixed encrypted data sizes (32 bytes data + 16 bytes auth tag = 48 bytes)
- ✅ Fixed nonce sizes (24 bytes for XChaCha20)
- ✅ Fixed public key size (32 bytes for X25519)
- ✅ Key derivation works successfully (argon2)
- ✅ SRP protocol authentication works

### 4. Test Execution
- ✅ App launches with mocked network layer
- ✅ Navigates to login screen
- ✅ Enters email successfully
- ✅ Enters password successfully
- ✅ Performs SRP key derivation
- ✅ Completes SRP handshake

## What Doesn't Work ❌

### 1. Encrypted Token Requirement
**Issue:** The SRP authentication flow requires a cryptographically valid `encryptedToken` in the response.

**Details:**
- After successful SRP verification, the app expects `encryptedToken` to be a sealed box (libsodium sealed box)
- The sealed box must be encrypted with the user's public key
- The app attempts to decrypt it using:  `CryptoUtil.openSealSync(encryptedToken, publicKey, secretKey)`
- We cannot easily generate a valid sealed box because:
  - We'd need the actual secret key to test decryption
  - The secret key itself is encrypted in the mock response
  - Creating a self-consistent set of test keys requires generating all cryptographic material together

**Error in logs:**
```
Exception: unexpected response during email verification
at UserService.verifyEmailViaPassword (user_service.dart:800)
```

**Code location:** `lib/services/account/user_service.dart:790-801`

### 2. Missing Mock Endpoints
After authentication, the app makes additional API calls that we haven't mocked:
- ❌ POST `/push/token` - Push notification token registration
- ❌ GET `/remote-store/feature-flags` - Feature flag sync

**Errors in logs:**
```
Error: Assertion failed: "Could not find mocked route matching request for POST /push/token"
Error: Assertion failed: "Could not find mocked route matching request for GET /remote-store/feature-flags"
```

### 3. Test Assertion Failure
The test fails at home screen verification because authentication didn't complete:

```
Expected: <true>
  Actual: <false>
Should be on home screen after successful login
```

## Approaches to Fix

### Approach 1: Generate Cryptographically Consistent Test Data (Complex but Complete)

**Pros:**
- Tests the full end-to-end authentication flow
- Verifies cryptographic operations work correctly
- Most realistic test scenario

**Cons:**
- High complexity - requires generating a complete set of consistent cryptographic keys
- Need to generate: master key, recovery key, keypair, encrypted keys, sealed token
- All keys must be mathematically consistent for encryption/decryption to work

**Implementation steps:**
1. Create a test key generation utility that generates a full set of consistent keys
2. Use the known test password to derive keyEncryptionKey
3. Encrypt master key with keyEncryptionKey
4. Encrypt secret key with master key
5. Create a test token and seal it with the public key using the secret key
6. Return all encrypted data in the mock response

### Approach 2: Mock at a Higher Level (Simpler but Less Complete)

**Pros:**
- Simpler implementation
- Tests UI flow without complex cryptography
- Faster to implement

**Cons:**
- Doesn't test actual cryptographic operations
- Less realistic
- May need to bypass authentication checks

**Implementation steps:**
1. Modify the test to skip cryptographic verification
2. Mock additional endpoints (`/push/token`, `/feature-flags`)
3. Set authenticated state directly after login UI flow

### Approach 3: Document as Limitation and Use for UI-Only Testing

**Pros:**
- Acknowledges current state
- Still valuable for testing UI navigation
- Documents the challenge for future work

**Cons:**
- Doesn't achieve full integration testing
- Authentication flow incomplete

## Recommendations

1. **Short term:** Document the current progress and use the test for UI navigation validation
2. **Medium term:** Implement Approach 1 to create fully functional integration tests
3. **Long term:** Consider adding a "test mode" flag in the app that uses simpler authentication for integration tests

## Files Modified

### New Files
- `integration_test/mocks/mock_api_interceptor.dart` - HTTP mock interceptor
- `integration_test/mocks/test_config.dart` - Test configuration constants
- `integration_test/helpers/auth_flow_helper.dart` - Reusable authentication flow helpers
- `integration_test/sign_in_flow_test.dart` - Main integration test file
- `integration_test/README.md` - Documentation for the integration test suite

### Modified Files
- `lib/core/network/network.dart` - Added optional Dio parameters for testing
- `lib/main.dart` - Added optional Dio parameters that flow through initialization

### Dependencies Added
- `http_mock_adapter: ^0.6.1` - For mocking HTTP requests
- `patrol_finders: ^2.3.1` - For enhanced widget finding

## Key Learnings

1. **Cryptographic Mocking is Complex:** Mocking cryptographic authentication requires all keys to be mathematically consistent
2. **Dependency Injection Helps:** Being able to inject mock Dio instances makes testing much more feasible
3. **Integration Tests Need Careful Planning:** End-to-end tests of encrypted apps require thorough understanding of the crypto flow
4. **Sealed Boxes are Tricky:** Libsodium sealed boxes require the secret key for both encryption and decryption, making mocking difficult

## Next Steps

To complete the integration test:

1. **Generate consistent test keys:**
   - Create a helper that generates a master key, recovery key, and keypair
   - Use the test password ("TestPassword123!") to derive keyEncryptionKey
   - Encrypt all keys consistently

2. **Create valid encrypted token:**
   - Generate a test JWT token
   - Seal it using the generated public key and secret key
   - Return it in the mock response

3. **Mock remaining endpoints:**
   - Add mock for POST `/push/token`
   - Add mock for GET `/remote-store/feature-flags`

4. **Verify home screen:**
   - Ensure the test reaches the home screen
   - Verify expected UI elements are present

## Test Execution Logs

Latest test run: `/tmp/flutter_integration_test_plaintoken.log`

Key log excerpts:
- Line 80-82: Key derivation succeeded
- Line 85-88: "Exception: unexpected response during email verification"
- Line 125-127: Test assertion failed - not on home screen
