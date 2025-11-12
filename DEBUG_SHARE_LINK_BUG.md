# Share Link Hash-Only Bug - Debugging Guide

## The Bug

**Symptom**: Share links intermittently share only the hash fragment instead of the full URL.
- Expected: `https://albums.ente.io/collection/xyz#abc123`
- Actual: `#abc123`

## Root Causes (Fixed in commit ead1fd733)

1. **No validation of backend URLs** - Code blindly trusted whatever the backend returned
2. **Fragile string manipulation** - Used `replaceFirst()` which could corrupt URLs
3. **String concatenation for fragments** - Used `"$url#key"` instead of `Uri.replace(fragment:)`
4. **No output validation** - Never checked if the generated URL was actually valid

## How to Reproduce (Old Code)

### Quick Test with Debug Script

Run the provided debug script:
```bash
cd /home/user/ente/mobile/apps/photos
dart scripts/debug_share_url.dart
```

This will show you exactly how different malformed inputs cause the bug.

### Method 1: Inject Bad Data in Code

In `lib/services/collections_service.dart`, modify `createShareUrl()`:

```dart
Future<void> createShareUrl(Collection collection, {bool enableCollect = false}) async {
  try {
    final response = await _enteDio.post(...);

    // INJECT TEST DATA HERE:
    response.data["result"]["url"] = "";  // ← Test empty URL
    // OR
    response.data["result"]["url"] = "/collection/abc";  // ← Test relative URL
    // OR
    response.data["result"]["url"] = "https://albums.ente.io#oldkey";  // ← Test existing fragment

    collection.publicURLs.add(PublicURL.fromMap(response.data["result"]));
    await _db.insert(List.from([collection]));
    ...
  }
}
```

Then create a share link and try to share it. You'll see only the hash.

### Method 2: Intercept at Share Time

In `lib/ui/sharing/share_collection_page.dart` line 176:

```dart
// Add before getting the URL
print("DEBUG: collection.publicURLs.first.url = '${widget.collection.publicURLs.first.url}'");

// Temporarily inject bad data to test
widget.collection.publicURLs.first.url = "";  // ← TEST THIS

final String url = CollectionsService.instance.getPublicUrl(widget.collection);
print("DEBUG: Generated share URL = '$url'");
```

### Method 3: Add Comprehensive Logging

In OLD code, add logging at every step in `getPublicUrl()`:

```dart
String getPublicUrl(Collection c) {
  final PublicURL url = c.publicURLs.firstOrNull!;
  _logger.info("1. Backend url.url = '${url.url}'");

  Uri publicUrl = Uri.parse(url.url);
  _logger.info("2. Parsed Uri: scheme=${publicUrl.hasScheme}, "
              "host='${publicUrl.host}', path='${publicUrl.path}'");

  final String customDomain = flagService.customDomain;
  _logger.info("3. Custom domain = '$customDomain'");

  if (customDomain.isNotEmpty) {
    publicUrl = publicUrl.replace(host: customDomain, scheme: "https", port: 443);
    _logger.info("4. After custom domain: '${publicUrl.toString()}'");
  }

  final String collectionKey = Base58Encode(
    CollectionsService.instance.getCollectionKey(c.id),
  );
  _logger.info("5. Collection key = '$collectionKey'");

  String finalUrl = publicUrl.toString();
  _logger.info("6. finalUrl before IDN = '$finalUrl'");

  if (customDomain.isNotEmpty && publicUrl.host.contains('%')) {
    final decodedHost = Uri.decodeComponent(publicUrl.host);
    finalUrl = finalUrl.replaceFirst(publicUrl.host, decodedHost);
    _logger.info("7. After IDN decode: '$finalUrl'");
  }

  String result = "$finalUrl#$collectionKey";
  _logger.info("8. FINAL RESULT = '$result'");

  return result;
}
```

Then monitor the logs when users report the bug. You'll see exactly where it fails.

### Method 4: Database Inspection

Check what's stored in the database:

```bash
# Find the database file
find ~/Library/Application\ Support -name "*.db" -path "*/io.ente.photos/*"
# or on Android:
adb pull /data/data/io.ente.photos/databases/ente.db

# Query the public URLs
sqlite3 ente.db
> SELECT * FROM collection_public_urls;
```

Look for:
- Empty `url` values
- Relative URLs (starting with `/`)
- URLs with `#` already in them
- Malformed URLs

## Expected Failure Scenarios (Old Code)

| Backend Returns | Old Code Returns | Why It's Broken |
|----------------|------------------|-----------------|
| `""` (empty) | `"#abc123"` | No validation, empty + fragment = hash only |
| `"/path"` (relative) | `"#abc123"` or partial | Relative URL loses path on host replacement |
| `"https://...#old"` | `"https://...#old#new"` | Double fragment (malformed) |
| URL with percent-encoded host in path | Corrupted URL | `replaceFirst()` replaces wrong occurrence |

## Testing the Fix (New Code)

The new code validates at multiple points:

```dart
// 1. Input validation
if (url.url.isEmpty) {
  throw AssertionError("Empty public URL from backend");
}

// 2. Scheme/authority validation
if (!publicUrl.hasScheme || !publicUrl.hasAuthority) {
  throw AssertionError("Invalid public URL: missing scheme or host");
}

// 3. Fragment cleanup
if (publicUrl.hasFragment) {
  publicUrl = publicUrl.replace(fragment: '');  // Clean removal
}

// 4. Proper fragment addition
final Uri finalUri = publicUrl.replace(fragment: collectionKey);  // Not string concat!

// 5. Safe IDN handling
// Build URL manually with StringBuffer instead of replaceFirst()

// 6. Output validation
if (finalUrl.isEmpty || !finalUrl.contains('#')) {
  throw AssertionError("Generated invalid public URL");
}
```

### Verify the Fix

1. Try injecting bad data with the new code - it should throw AssertionError
2. Check logs for validation error messages
3. Test with custom domains and IDN domains
4. Ensure existing valid URLs still work

## Why It Was Intermittent

The bug appeared "randomly" because it depended on:
1. **Backend state** - If the backend occasionally returned malformed URLs due to bugs
2. **Cache state** - If corrupted data was cached locally
3. **Custom domain settings** - More likely with custom domains due to the replaceFirst() issue
4. **Network issues** - Partial responses could result in empty URLs
5. **Database corruption** - Rare cases of corrupted database entries

## Key Files

- `lib/services/collections_service.dart` - Contains `getPublicUrl()` (line 827)
- `lib/ui/sharing/share_collection_page.dart` - Uses the URL for sharing (line 176)
- `lib/models/api/collection/public_url.dart` - Defines `PublicURL` model
- `test/services/url_bug_reproduction_test.dart` - Unit tests demonstrating the bug
- `scripts/debug_share_url.dart` - Debug script to test various inputs

## Prevention

The fix prevents this by:
1. ✅ Validating input URLs have scheme and host
2. ✅ Properly cleaning existing fragments
3. ✅ Using Uri methods instead of string manipulation
4. ✅ Validating output before returning
5. ✅ Logging errors for debugging
6. ✅ Throwing early on invalid input

## See Also

- Commit: `ead1fd733` - The fix
- Related: Custom domain support (commit `5e993b952`)
- Related: IDN domain handling (commit `58a09e3b7`)
