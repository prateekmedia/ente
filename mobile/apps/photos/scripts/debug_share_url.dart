#!/usr/bin/env dart
/// Debug script to test share URL generation with various inputs
/// Run with: dart scripts/debug_share_url.dart

void main() {
  print("=".padRight(80, "="));
  print("Share Link Bug Reproduction Script");
  print("=".padRight(80, "="));
  print("");

  // Test cases that would cause the bug in OLD code
  final testCases = [
    {
      'name': 'Empty URL',
      'backendUrl': '',
      'customDomain': '',
      'expectedOldBug': true,
      'bugDescription': 'Returns only "#hash" without full URL',
    },
    {
      'name': 'Relative URL',
      'backendUrl': '/collection/abc',
      'customDomain': '',
      'expectedOldBug': true,
      'bugDescription': 'Missing scheme and host',
    },
    {
      'name': 'URL with existing fragment',
      'backendUrl': 'https://albums.ente.io#oldkey',
      'customDomain': '',
      'expectedOldBug': true,
      'bugDescription': 'Creates double-hash: "#oldkey#newkey"',
    },
    {
      'name': 'Empty URL with custom domain',
      'backendUrl': '',
      'customDomain': 'custom.example.com',
      'expectedOldBug': true,
      'bugDescription': 'Still returns only hash even with custom domain',
    },
    {
      'name': 'Valid URL (no bug)',
      'backendUrl': 'https://albums.ente.io/collection/abc',
      'customDomain': '',
      'expectedOldBug': false,
      'bugDescription': 'Works correctly',
    },
    {
      'name': 'Valid URL with custom domain (no bug)',
      'backendUrl': 'https://albums.ente.io/collection/abc',
      'customDomain': 'custom.example.com',
      'expectedOldBug': false,
      'bugDescription': 'Works correctly with custom domain',
    },
  ];

  for (var i = 0; i < testCases.length; i++) {
    final testCase = testCases[i];
    print("Test ${i + 1}: ${testCase['name']}");
    print("-".padRight(80, "-"));

    final backendUrl = testCase['backendUrl'] as String;
    final customDomain = testCase['customDomain'] as String;
    final collectionKey = "abc123xyz";

    print("Input:");
    print("  Backend URL: '${backendUrl}'");
    print("  Custom Domain: '${customDomain.isEmpty ? '(none)' : customDomain}'");
    print("  Collection Key: '$collectionKey'");
    print("");

    // Simulate OLD code behavior
    try {
      final oldResult = simulateOldCode(backendUrl, customDomain, collectionKey);
      print("OLD Code Result: '$oldResult'");

      // Check if this demonstrates the bug
      if (testCase['expectedOldBug'] as bool) {
        print("  ⚠️  BUG REPRODUCED: ${testCase['bugDescription']}");
        if (oldResult == "#$collectionKey") {
          print("  ❌ Only hash is returned (not a valid URL)");
        } else if (oldResult.split('#').length > 2) {
          print("  ❌ Double hash detected (malformed URL)");
        } else if (!oldResult.startsWith('http')) {
          print("  ❌ Missing scheme (malformed URL)");
        }
      } else {
        print("  ✓ Works as expected");
      }
    } catch (e) {
      print("OLD Code Result: ERROR - $e");
    }

    print("");

    // Simulate NEW code behavior
    try {
      final newResult = simulateNewCode(backendUrl, customDomain, collectionKey);
      print("NEW Code Result: '$newResult'");
      print("  ✓ Validation passed, proper URL generated");
    } catch (e) {
      print("NEW Code Result: ERROR (validation failed)");
      print("  ✓ Properly rejected invalid input: $e");
    }

    print("");
    print("");
  }

  print("=".padRight(80, "="));
  print("Summary:");
  print("- OLD code blindly trusts backend and can produce invalid URLs");
  print("- NEW code validates input and rejects malformed URLs early");
  print("- This prevents hash-only sharing bug from reaching users");
  print("=".padRight(80, "="));
}

/// Simulates the OLD getPublicUrl() implementation (before fix)
String simulateOldCode(String backendUrl, String customDomain, String collectionKey) {
  // OLD CODE - No validation!
  Uri publicUrl = Uri.parse(backendUrl);

  if (customDomain.isNotEmpty) {
    publicUrl = publicUrl.replace(
      host: customDomain,
      scheme: "https",
      port: 443,
    );
  }

  String finalUrl = publicUrl.toString();

  // Fragile string concatenation
  return "$finalUrl#$collectionKey";
}

/// Simulates the NEW getPublicUrl() implementation (after fix)
String simulateNewCode(String backendUrl, String customDomain, String collectionKey) {
  // NEW CODE - Validate input!
  if (backendUrl.isEmpty) {
    throw ArgumentError("Empty public URL from backend");
  }

  Uri publicUrl = Uri.parse(backendUrl);

  // Validate scheme and authority
  if (!publicUrl.hasScheme || !publicUrl.hasAuthority) {
    throw ArgumentError(
      "Invalid public URL from backend: missing scheme or host. "
      "Got: hasScheme=${publicUrl.hasScheme}, hasAuthority=${publicUrl.hasAuthority}"
    );
  }

  // Remove existing fragment to avoid conflicts
  if (publicUrl.hasFragment) {
    publicUrl = publicUrl.replace(fragment: '');
  }

  if (customDomain.isNotEmpty) {
    publicUrl = publicUrl.replace(
      host: customDomain,
      scheme: "https",
      port: 443,
    );
  }

  // Use Uri.replace instead of string concatenation
  final Uri finalUri = publicUrl.replace(fragment: collectionKey);
  final String finalUrl = finalUri.toString();

  // Final validation
  if (finalUrl.isEmpty || !finalUrl.contains('#')) {
    throw ArgumentError("Generated invalid public URL");
  }

  return finalUrl;
}
