# iOS 18.1 Photo Backup API - Research & Implementation Plan

**Date**: 2025-11-12
**Context**: Ente Photos - Flutter-based end-to-end encrypted photo backup app
**Objective**: Assess feasibility of integrating iOS 18.1's new Background Resource Upload extension

---

## Executive Summary

**Recommendation**: ⚠️ **NOT FEASIBLE in current form** - Major architectural incompatibilities exist

The iOS 18.1 Photo Backup API provides a superior background upload experience but requires native iOS App Extension development that is fundamentally incompatible with Ente's Flutter-based architecture and pure-Dart encryption implementation.

**Key Blocker**: App Extensions run in isolated processes without Flutter runtime, making it impossible to reuse Ente's Dart-based libsodium encryption code.

---

## 1. iOS 18.1 Photo Backup API Overview

### What is it?

Apple introduced a new **Background Resource Upload Extension** in iOS 18.1 specifically for photo backup apps. This allows third-party apps to:

- Upload photos/videos reliably in the background
- Let the system manage timing, network, and power optimization
- Continue uploads even when app is terminated or device is locked
- Provide seamless "set it and forget it" backup experience like iCloud Photos

### Key Components

1. **PHBackgroundAssetResourceUploadExtension** - App Extension type
2. **PHAssetResourceManager** - Provides access to asset data
3. **System-managed scheduling** - iOS decides when to run uploads based on network, battery, usage patterns
4. **Long-running background execution** - Not limited to 30 seconds like BGTaskScheduler

### Architecture

```
┌─────────────────────────────────────────────┐
│  iOS System (PhotoKit)                      │
│  - Monitors photo library changes           │
│  - Decides optimal upload timing            │
└─────────────────┬───────────────────────────┘
                  │ Launches when appropriate
                  ↓
┌─────────────────────────────────────────────┐
│  Photo Backup Extension (Separate Process)  │
│  - Native Swift/Objective-C code            │
│  - Receives PHAsset references              │
│  - Accesses asset data via                  │
│    PHAssetResourceManager                   │
│  - Performs upload to cloud                 │
│  - Reports progress to system               │
└─────────────────────────────────────────────┘
```

### Benefits over Current Approach

| Feature | Current (WorkManager) | iOS 18.1 Photo Backup |
|---------|----------------------|----------------------|
| Max execution time | 28 seconds | Hours (system-managed) |
| Frequency | Every 30 min (scheduled) | Event-driven + periodic |
| Photo library access | Via Flutter plugin | Direct PHAsset access |
| System integration | Limited | Deep (optimized scheduling) |
| User perception | "Manual" feel | Seamless like iCloud |
| Battery optimization | Basic | Advanced (ML-based) |

---

## 2. Current Ente iOS Upload Architecture

### Technology Stack

```
┌──────────────────────────────────────────────┐
│  Foreground App (Flutter)                    │
│  ┌────────────────────────────────────────┐  │
│  │  Dart Code                             │  │
│  │  - FileUploader service                │  │
│  │  - Lock management (SQLite)            │  │
│  │  - Heartbeat system                    │  │
│  │  - Queue management                    │  │
│  └────────────┬───────────────────────────┘  │
│               │ Platform Channel             │
│  ┌────────────▼───────────────────────────┐  │
│  │  Native iOS (Swift)                    │  │
│  │  - photo_manager plugin                │  │
│  │  - Wraps PHPhotoLibrary                │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│  Background Task (WorkManager)                │
│  ┌────────────────────────────────────────┐  │
│  │  Dart Code (in Flutter isolate)       │  │
│  │  - Same FileUploader logic             │  │
│  │  - 28-second timeout                   │  │
│  │  - Runs every 30 minutes               │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

### Upload Flow (11 Steps)

1. **Selection** - User picks photos or auto-sync detects new photos
2. **Queue** - Added to LinkedHashMap `_queue`
3. **Lock Acquisition** - SQLite lock prevents duplicate processing
4. **Asset Fetch** - `photo_manager` gets PHAsset via platform channel
5. **File Data** - Retrieve originFile (15-sec timeout)
6. **Live Photo Handling** - Extract video component, create .elp zip
7. **Thumbnail** - Generate 512x512 compressed thumbnail
8. **Encryption** - **Pure Dart libsodium** in isolate worker
   - XChaCha20-Poly1305 streaming cipher
   - 4 MB chunks
   - Encrypted in background isolate (non-blocking)
9. **Upload** - Multipart upload to S3 (>5MB) or single-part (<5MB)
10. **Server API** - POST /files or PUT /files/update
11. **Cleanup** - Release lock, update DB, fire events

### Lock & Heartbeat System

**Purpose**: Prevent foreground and background processes from uploading the same file simultaneously

**Mechanism**:
- SQLite table `upload_locks` with columns: `id` (file.localID), `owner` (ProcessType), `time`
- Lock acquisition uses `ConflictAlgorithm.fail` for atomicity
- Heartbeat updated every 1 second to SharedPreferences
- Each process checks other's heartbeat before starting
- If FG detects BG active (heartbeat within 30 sec), FG waits
- If BG detects FG active, BG exits early
- Stale locks (>4 hours old) cleaned up on process init

**Concurrency Limits**:
- Max 4 total concurrent uploads
- Max 2 concurrent video uploads
- Tracked via `_uploadCounter` and `_videoUploadCounter`

### Encryption Details

**Integration**: Pure Dart FFI (no native code)
- `ente_crypto` plugin wraps `flutter_sodium`
- `flutter_sodium` provides FFI bindings to C libsodium
- All encryption in Dart using `Computer` package (isolate pool)

**Algorithm**: XChaCha20-Poly1305
- Authenticated encryption with associated data (AEAD)
- Stream cipher for files (4 MB chunks)
- Each chunk: 17-byte MAC overhead

**Key Hierarchy**:
```
Master Key (from password + Argon2id)
    ↓
Collection Key (encrypted with master)
    ↓
File Key (32-byte random, encrypted with collection key)
```

**Critical Metadata** (stored in DB):
- `encryptedKey` - File key encrypted with collection key
- `keyDecryptionNonce` - 24-byte nonce for key decryption
- `fileDecryptionHeader` - 24-byte XChaCha20 header

**Performance**:
- Non-blocking (runs in isolates)
- Up to 4 concurrent encryptions
- No native code required

---

## 3. Compatibility Assessment

### Critical Incompatibilities

#### 🚫 1. Flutter Runtime Unavailable in App Extensions

**Problem**:
- iOS App Extensions run in **separate processes** from the main app
- They do **NOT** have access to Flutter runtime
- Cannot execute Dart code
- Must be written in Swift/Objective-C

**Impact on Ente**:
- 100% of upload logic is in Dart (`file_uploader.dart` - 1787 lines)
- Cannot reuse any existing code in the extension
- Would need complete rewrite in Swift

#### 🚫 2. Encryption Library Incompatibility

**Problem**:
- Ente's encryption is pure Dart using `flutter_sodium` FFI bindings
- App Extension cannot use Flutter packages
- Would need to integrate libsodium directly in Swift

**Challenges**:
```swift
// Extension needs to replicate this Dart logic in Swift:
// 1. XChaCha20-Poly1305 streaming encryption
// 2. 4 MB chunking
// 3. Key derivation (Argon2id)
// 4. Collection key decryption
// 5. File key generation and encryption
// 6. Maintaining identical encrypted format for cross-platform compatibility
```

**Risk**:
- Any difference in implementation between Dart and Swift encryption would cause decryption failures
- Maintaining two separate encryption implementations is error-prone
- Must ensure byte-for-byte identical output

#### 🚫 3. Shared State & Database Access

**Problem**:
- App Extensions have limited shared container access with main app
- Cannot directly access main app's SQLite databases
- `upload_locks` table requires migration to shared App Group container

**Current dependencies needing migration**:
- `upload_locks.db` - Lock management
- `ente.db` - File metadata (encryptedKey, nonces, headers)
- `SharedPreferences` - Heartbeat timestamps
- Encrypted key storage - Master key, collection keys

#### 🚫 4. Three-Way Lock Coordination

**Problem**: Now have 3 processes that could upload:
1. Foreground app (Dart)
2. WorkManager background task (Dart)
3. Photo Backup Extension (Swift)

**Complexity**:
```
┌─────────────────────────────────────────────────────┐
│  Lock Coordination Layer (Shared Container)         │
│  - SQLite in App Group container                    │
│  - Heartbeat mechanism needs extension support      │
│  - Process death detection for extension            │
└─────────────────────────────────────────────────────┘
         ↓                    ↓                    ↓
    Foreground          WorkManager           Photo Backup
    (Dart)              (Dart)                Extension (Swift)
```

**Challenges**:
- Extension doesn't have SharedPreferences access
- Need new IPC mechanism for heartbeats
- Race conditions between 3 processes
- Deadlock potential increases

#### 🚫 5. photo_manager Plugin Won't Work

**Problem**:
- `photo_manager` is a Flutter plugin
- Extensions can't use Flutter plugins
- Extension gets PHAsset directly from system

**Impact**:
- Extension needs different code path for asset access
- Cannot reuse `file_uploader_util.dart` logic
- Live Photo handling needs Swift implementation
- Thumbnail generation needs Swift implementation

---

### What COULD Work

#### ✅ 1. Read-Only Asset Access
- Extension gets PHAsset references directly from PhotoKit
- Can use PHAssetResourceManager to read photo/video data
- Access to all metadata (location, date, etc.)

#### ✅ 2. Network Access
- Extensions can perform URLSession uploads
- Can upload to S3 same as main app
- Background URL sessions supported

#### ✅ 3. Shared Container Storage
- Can migrate databases to App Group container
- Both main app and extension can access shared SQLite
- UserDefaults in shared suite works

#### ✅ 4. libsodium Integration
- libsodium is C library, can link in Swift
- Same underlying crypto implementation
- Just need Swift wrapper code

---

## 4. Implementation Approaches

### Option A: Full Native Extension (High Effort, Full Benefits)

**Architecture**:
```
┌────────────────────────────────────────────────┐
│  Photo Backup Extension (Swift)                │
│  ┌──────────────────────────────────────────┐  │
│  │  Native Encryption Module                │  │
│  │  - libsodium Swift wrapper               │  │
│  │  - XChaCha20-Poly1305 implementation     │  │
│  │  - Identical to Dart logic               │  │
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  Upload Manager                          │  │
│  │  - PHAsset → data extraction             │  │
│  │  - Thumbnail generation                  │  │
│  │  - S3 multipart upload                   │  │
│  │  - Lock coordination                     │  │
│  └──────────────────────────────────────────┘  │
│  ┌──────────────────────────────────────────┐  │
│  │  Shared Database Access                  │  │
│  │  - Read encryption keys from container   │  │
│  │  - Write upload progress                 │  │
│  │  - Manage locks                          │  │
│  └──────────────────────────────────────────┘  │
└────────────────────────────────────────────────┘
```

**Requirements**:
1. Create Swift wrapper for libsodium
2. Implement XChaCha20-Poly1305 streaming in Swift
3. Port encryption logic from `ente_crypto/lib/src/crypto.dart` (1075 lines)
4. Migrate databases to App Group container
5. Implement three-way lock coordination
6. Add heartbeat mechanism for extension
7. Port Live Photo handling to Swift
8. Implement S3 multipart upload in Swift
9. Add server API calls in Swift
10. Testing: Ensure encryption compatibility between Dart and Swift

**Estimated Effort**: 6-8 weeks for experienced iOS developer

**Risks**:
- **HIGH**: Encryption implementation bugs could cause data loss
- **HIGH**: Maintaining two encryption codebases (Dart + Swift)
- **MEDIUM**: Lock coordination race conditions
- **MEDIUM**: Testing cross-platform encryption compatibility

**Benefits**:
- ✅ True system-integrated background upload
- ✅ No 28-second timeout limitation
- ✅ Better battery and network optimization
- ✅ Event-driven uploads (instant when new photo taken)
- ✅ User experience on par with iCloud Photos

---

### Option B: Hybrid - Extension Triggers Dart Upload (Medium Effort, Partial Benefits)

**Architecture**:
```
┌────────────────────────────────────────────────┐
│  Photo Backup Extension (Swift)                │
│  - Detect new assets                           │
│  - Write asset IDs to shared container         │
│  - Wake up main app if possible                │
└────────────────────────────────────────────────┘
                      ↓
┌────────────────────────────────────────────────┐
│  Main App (Dart)                               │
│  - Monitor shared container                    │
│  - Pick up queued asset IDs                    │
│  - Perform encryption & upload                 │
└────────────────────────────────────────────────┘
```

**How it works**:
1. Extension wakes periodically (system-managed)
2. Extension queries PHPhotoLibrary for new assets
3. Extension writes asset localIDs to shared container queue
4. Extension attempts to wake main app via URL scheme or push notification
5. Main app (if woken) processes queue using existing Dart code

**Limitations**:
- ❌ Main app might not wake successfully
- ❌ Cannot actually perform upload in extension (defeats the purpose)
- ❌ User experience not much better than current approach
- ❌ Still requires user to open app periodically

**Effort**: 2-3 weeks

**Verdict**: ⚠️ Not worth it - minimal improvement over current WorkManager approach

---

### Option C: Keep Current WorkManager (Status Quo)

**Decision**: Continue using current architecture

**Rationale**:
- WorkManager approach is working
- No risk of introducing encryption bugs
- Single codebase (Dart) for all platforms
- 30-minute frequency is acceptable for most users
- Background upload limitation is understood by users

**Improvements to Current Approach**:
1. Increase background task frequency if possible (currently 30 min on iOS)
2. Improve user education about backgroundRefresh permission
3. Add notification when background upload completes
4. Optimize encryption speed to fit more uploads in 28-second window
5. Prioritize recent photos in upload queue

---

## 5. Conflict Analysis - Current vs. New API

### Scenario: Both Systems Active

If we implemented Option A, we'd need to prevent conflicts:

```
User takes photo
    ↓
┌─────────────────────────────────────────────────┐
│  iOS System detects new asset                   │
└───────────┬─────────────────┬───────────────────┘
            │                 │
            ↓                 ↓
    Extension Triggered   WorkManager Scheduled
            │                 │
            ↓                 ↓
    Tries to acquire     Tries to acquire
    lock for file        lock for file
            │                 │
            └────────┬────────┘
                     ↓
            First to acquire wins
            Second one skips file
```

**Lock table coordination**:
```sql
-- Extension tries
INSERT INTO upload_locks (id, owner, time)
VALUES ('photo123', 'extension', 1699876543000000)
ON CONFLICT DO NOTHING;

-- Returns number of rows inserted
-- If 0, file is already locked (skip)
-- If 1, successfully acquired lock (proceed)
```

**Required changes**:
1. Migrate `upload_locks.db` to App Group container
2. Add `extension` as third ProcessType enum value
3. Update both Dart and Swift to check extension heartbeat
4. Extension updates heartbeat to shared UserDefaults

---

## 6. Encryption Portability Challenge

### Dart Implementation (Current)

```dart
// From ente_crypto/lib/src/crypto.dart
Future<EncryptionResult> encryptFile(
  String sourceFilePath,
  String destinationFilePath,
  Uint8List key,
) async {
  final sourceFile = File(sourceFilePath);
  final destinationFile = File(destinationFilePath);

  // XChaCha20-Poly1305 streaming
  final header = Sodium.cryptoSecretstreamXchacha20poly1305InitPush(key);
  final state = header.state;

  // 4 MB chunks
  const chunkSize = 4 * 1024 * 1024;
  final buffer = Uint8List(chunkSize);

  await for (final chunk in sourceFile.openRead()) {
    final encryptedChunk = Sodium.cryptoSecretstreamXchacha20poly1305Push(
      state,
      chunk,
      null, // No associated data
      isLastChunk ? TAG_FINAL : TAG_MESSAGE,
    );
    await destinationFile.writeAsBytes(encryptedChunk, mode: FileMode.append);
  }

  return EncryptionResult(
    encryptedData: destinationFile,
    header: header.header, // 24 bytes
    nonce: ...,
  );
}
```

### Swift Implementation (Required)

```swift
// Would need to implement in Swift
func encryptFile(
    sourceURL: URL,
    destinationURL: URL,
    key: Data
) throws -> EncryptionResult {
    // Link libsodium.a
    // Call C functions: crypto_secretstream_xchacha20poly1305_*
    // Must produce IDENTICAL output to Dart version
    // Any byte difference = decryption failure on other platforms
}
```

**Testing Requirements**:
1. Encrypt same file in Dart and Swift
2. Verify byte-for-byte identical output
3. Decrypt Dart-encrypted file in Swift ✓
4. Decrypt Swift-encrypted file in Dart ✓
5. Test all edge cases (0-byte files, exactly 4MB files, live photos, etc.)
6. Continuous integration tests to prevent drift

**Maintenance Burden**:
- Any change to encryption logic needs implementation in BOTH Dart and Swift
- Double the code review effort
- Higher risk of security vulnerabilities
- Platform-specific bugs could cause upload failures

---

## 7. Recommendation & Decision Tree

### Decision Tree

```
Do we NEED iOS 18.1 Photo Backup API?
    ├─ YES (competitive pressure, user demand)
    │   └─→ Option A (Full Native Extension)
    │       ├─ Hire iOS specialist for 2-3 months
    │       ├─ Budget $30k-50k development cost
    │       ├─ Accept 6+ month timeline
    │       └─ Commit to maintaining dual encryption codebase
    │
    └─ NO (current approach is adequate)
        └─→ Option C (Keep WorkManager)
            ├─ Improve current implementation
            ├─ Focus development on other features
            └─ Revisit if competitive landscape changes
```

### Recommendation: **Option C - Keep WorkManager**

**Reasons**:

1. **Risk vs. Reward**
   - HIGH risk: Encryption bugs, data loss, security vulnerabilities
   - MEDIUM reward: Better UX for iOS users only (Android unaffected)

2. **Development Cost**
   - 6-8 weeks senior iOS developer time
   - Ongoing maintenance of Swift encryption codebase
   - Extensive testing requirements

3. **Current Approach Works**
   - Background uploads function reliably
   - 30-minute frequency acceptable for most use cases
   - Users understand the limitation

4. **Alternative Improvements** (Lower hanging fruit)
   - Optimize Dart encryption to process more files in 28 seconds
   - Better user education on backgroundRefresh permission
   - Add foreground upload during app usage (already implemented)
   - Improve upload queue prioritization

5. **Team Capacity**
   - Is there dedicated iOS expertise?
   - Other high-priority features waiting?
   - Can team maintain two encryption codebases long-term?

---

## 8. If Proceeding with Option A - Implementation Checklist

### Phase 1: Foundation (Week 1-2)

- [ ] Set up App Group for shared container
- [ ] Create Photo Backup Extension target in Xcode
- [ ] Integrate libsodium via CocoaPods or SPM
- [ ] Create Swift wrapper for libsodium functions
- [ ] Implement basic XChaCha20-Poly1305 encryption test
- [ ] Migrate upload_locks.db to shared container
- [ ] Update Dart code to use shared container DB

### Phase 2: Encryption Parity (Week 3-4)

- [ ] Port encryption logic from crypto.dart to Swift
- [ ] Implement 4 MB chunking in Swift
- [ ] Implement key derivation (Argon2id)
- [ ] Add collection key decryption
- [ ] Create automated tests comparing Dart vs Swift output
- [ ] Verify byte-for-byte encryption compatibility
- [ ] Test decryption cross-platform (Dart↔Swift)

### Phase 3: Extension Core Logic (Week 5-6)

- [ ] Implement PHAsset enumeration
- [ ] Extract asset data via PHAssetResourceManager
- [ ] Generate thumbnails in Swift
- [ ] Handle Live Photos (extract video component)
- [ ] Implement three-way lock acquisition
- [ ] Add heartbeat mechanism for extension
- [ ] Implement S3 multipart upload in Swift
- [ ] Add retry logic and error handling

### Phase 4: Integration & Testing (Week 7-8)

- [ ] Integrate extension with main app
- [ ] Test foreground + extension coordination
- [ ] Test WorkManager + extension coordination
- [ ] Test all three processes active simultaneously
- [ ] Handle process death scenarios
- [ ] Add progress reporting to system
- [ ] Add user-facing status in main app
- [ ] Beta test with small user group

### Phase 5: Monitoring & Rollout (Week 9+)

- [ ] Add analytics for extension success/failure rates
- [ ] Monitor encryption compatibility errors
- [ ] Gradual rollout to 10% → 50% → 100%
- [ ] Document Swift encryption API
- [ ] Set up CI for Swift encryption tests
- [ ] Train team on maintaining both codebases

---

## 9. Key Files Reference

### Current Implementation
- `mobile/apps/photos/lib/utils/file_uploader.dart` (1787 lines) - Main upload logic
- `mobile/apps/photos/lib/utils/bg_task_utils.dart` (118 lines) - Background task setup
- `mobile/apps/photos/lib/db/upload_locks_db.dart` - Lock management
- `mobile/apps/photos/plugins/ente_crypto/lib/src/crypto.dart` (1075 lines) - Encryption
- `mobile/apps/photos/ios/Runner/AppDelegate.swift` (48 lines) - iOS entry point

### Would Need to Create (Option A)
- `mobile/apps/photos/ios/PhotoBackupExtension/` - New extension target
- `mobile/apps/photos/ios/PhotoBackupExtension/EnteCrypto.swift` - Encryption wrapper
- `mobile/apps/photos/ios/PhotoBackupExtension/UploadManager.swift` - Upload orchestration
- `mobile/apps/photos/ios/PhotoBackupExtension/LockCoordinator.swift` - Lock management
- `mobile/apps/photos/ios/Shared/SharedContainer.swift` - Shared storage access

---

## 10. Alternatives to Consider

### A. Wait for Flutter Extension Support
- Flutter team may add App Extension support in future
- Would allow reusing Dart code
- Timeline: Unknown, possibly 1-2+ years

### B. Use React Native or Native iOS App
- Rebuild Ente Photos as native iOS app
- Not feasible for cross-platform product
- Would lose Android/web/desktop code sharing

### C. Hybrid App with Native Upload Module
- Keep Flutter for UI
- Move encryption and upload to native module
- Significant architecture change
- Would enable iOS 18.1 API and improve performance
- Effort: Similar to Option A but affects all platforms

### D. Server-Side Processing (Not E2EE)
- Extension uploads encrypted data to intermediate server
- Server performs actual processing
- **Violates Ente's E2EE principle** - Not acceptable

---

## 11. Questions for Stakeholders

1. **Product**: Do we have user feedback requesting better iOS background upload?
2. **Product**: Is current 30-minute background sync a significant complaint?
3. **Engineering**: Do we have iOS expertise to implement and maintain Swift encryption?
4. **Engineering**: What's the opportunity cost vs. other roadmap items?
5. **Security**: Are we comfortable maintaining two encryption implementations?
6. **Business**: Does iOS App Store ranking/reviews suffer from current limitation?
7. **Support**: What percentage of support tickets relate to background upload?

---

## 12. Conclusion

The iOS 18.1 Photo Backup API provides excellent system integration but is **fundamentally incompatible with Flutter-based architecture**. The primary blocker is Ente's pure-Dart encryption implementation, which cannot run in iOS App Extensions.

**Viable path forward requires**:
- Complete Swift reimplementation of encryption logic
- Maintaining two separate encryption codebases
- Extensive cross-platform testing
- Significant engineering investment (6-8 weeks)

**Recommended approach**:
- Continue with current WorkManager implementation (Option C)
- Invest in optimizations to current approach
- Revisit if competitive pressure increases or Flutter adds extension support

**If proceeding with native extension**:
- Budget 2-3 months development time
- Hire or assign dedicated iOS specialist
- Prioritize encryption compatibility testing
- Plan for ongoing maintenance of dual codebase

---

## Appendix: Apple Documentation Resources

Since direct access to Apple's developer documentation was blocked, here are the key resources to review:

1. **Uploading asset resources in the background**
   URL: https://developer.apple.com/documentation/photokit/uploading-asset-resources-in-the-background

2. **PHAssetResourceManager**
   URL: https://developer.apple.com/documentation/photos/phassetresourcemanager

3. **App Extensions Programming Guide**
   URL: https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/

4. **WWDC 2024 Sessions**
   Search for sessions on iOS 18 PhotoKit updates

5. **libsodium Swift Integration**
   GitHub: https://github.com/jedisct1/swift-sodium
