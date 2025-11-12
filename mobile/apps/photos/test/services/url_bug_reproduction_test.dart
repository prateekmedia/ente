import 'package:test/test.dart';

/// This test demonstrates how the OLD code (before the fix) would fail
/// with various malformed backend responses.
void main() {
  group('Share Link Bug Reproduction - OLD CODE BEHAVIOR', () {
    test('Empty URL from backend produces hash-only output', () {
      // Simulate old getPublicUrl behavior without validation
      String getPublicUrlOld(String backendUrl, String collectionKey) {
        Uri publicUrl = Uri.parse(backendUrl);
        String finalUrl = publicUrl.toString();
        return "$finalUrl#$collectionKey";
      }

      // Backend returns empty string (could happen due to backend bug,
      // network issue, cache corruption, etc.)
      String result = getPublicUrlOld("", "abc123");

      print("Empty URL test:");
      print("  Backend URL: ''");
      print("  Result: '$result'");
      print("  Expected: Full URL like 'https://albums.ente.io/collection/xyz#abc123'");
      print("  Actual: '$result'");

      // This is the bug! Only hash is returned
      expect(result, equals("#abc123"));
      expect(result.contains("http"), isFalse);
    });

    test('URL with existing fragment creates malformed double-hash URL', () {
      String getPublicUrlOld(String backendUrl, String collectionKey) {
        Uri publicUrl = Uri.parse(backendUrl);
        String finalUrl = publicUrl.toString();
        return "$finalUrl#$collectionKey";
      }

      // Backend accidentally returns URL with a fragment already
      String result = getPublicUrlOld(
        "https://albums.ente.io#oldkey",
        "newkey123",
      );

      print("\nExisting fragment test:");
      print("  Backend URL: 'https://albums.ente.io#oldkey'");
      print("  Result: '$result'");

      // Malformed URL with double hash
      expect(result, equals("https://albums.ente.io#oldkey#newkey123"));
      expect(result.split('#').length, equals(3)); // Two # signs!
    });

    test('Relative URL from backend loses scheme/host', () {
      String getPublicUrlOld(String backendUrl, String collectionKey) {
        Uri publicUrl = Uri.parse(backendUrl);

        // Simulate custom domain replacement on relative URL
        String customDomain = "custom.example.com";
        if (customDomain.isNotEmpty) {
          publicUrl = publicUrl.replace(
            host: customDomain,
            scheme: "https",
            port: 443,
          );
        }

        String finalUrl = publicUrl.toString();
        return "$finalUrl#$collectionKey";
      }

      // Backend returns relative URL (missing scheme/host)
      String result = getPublicUrlOld("/collection/abc", "key123");

      print("\nRelative URL test:");
      print("  Backend URL: '/collection/abc'");
      print("  Result: '$result'");

      // The result is malformed - custom domain replace doesn't work properly
      // on relative URLs
      expect(result.startsWith("https://"), isTrue);
      // But the path might be lost or malformed
    });

    test('replaceFirst can corrupt URLs with repeated host strings', () {
      // Simulate the IDN domain handling in old code
      String simulateOldIdnHandling(String fullUrl, String encodedHost) {
        // Old code did: finalUrl.replaceFirst(publicUrl.host, decodedHost)
        String decodedHost = Uri.decodeComponent(encodedHost);
        return fullUrl.replaceFirst(encodedHost, decodedHost);
      }

      // URL that contains the host string multiple times
      String url = "https://albums.ente.io/share/albums.ente.io/data";
      String host = "albums.ente.io";

      String result = simulateOldIdnHandling(url, host);

      print("\nreplaceFirst edge case test:");
      print("  Original URL: '$url'");
      print("  Host to replace: '$host'");
      print("  Result: '$result'");

      // replaceFirst only replaces the FIRST occurrence, which is in the
      // hostname portion - but if we wanted to replace in the path,
      // this would be wrong
      expect(result, equals(url)); // No change since no encoding

      // But with percent-encoding:
      String encodedUrl = "https://example%2Ecom/path/example%2Ecom/data";
      String encodedHost = "example%2Ecom";
      String resultEncoded = simulateOldIdnHandling(encodedUrl, encodedHost);
      print("\n  With encoding:");
      print("  Original: '$encodedUrl'");
      print("  Result: '$resultEncoded'");

      // This replaces the FIRST occurrence only
      expect(resultEncoded, equals("https://example.com/path/example%2Ecom/data"));
      // Notice: Only the first occurrence is replaced!
    });

    test('Uri.parse on empty string creates empty Uri', () {
      Uri emptyUri = Uri.parse("");

      print("\nUri.parse('') behavior:");
      print("  hasScheme: ${emptyUri.hasScheme}");
      print("  hasAuthority: ${emptyUri.hasAuthority}");
      print("  host: '${emptyUri.host}'");
      print("  path: '${emptyUri.path}'");
      print("  toString(): '${emptyUri.toString()}'");

      expect(emptyUri.hasScheme, isFalse);
      expect(emptyUri.hasAuthority, isFalse);
      expect(emptyUri.toString(), equals(""));
    });
  });

  group('Fixed Code Behavior', () {
    test('NEW code validates and throws on empty URL', () {
      String getPublicUrlNew(String backendUrl, String collectionKey) {
        // Validation added in the fix
        if (backendUrl.isEmpty) {
          throw AssertionError("Empty public URL from backend");
        }

        Uri publicUrl = Uri.parse(backendUrl);

        // Validate scheme and authority
        if (!publicUrl.hasScheme || !publicUrl.hasAuthority) {
          throw AssertionError("Invalid public URL from backend: missing scheme or host");
        }

        // Remove existing fragment
        if (publicUrl.hasFragment) {
          publicUrl = publicUrl.replace(fragment: '');
        }

        // Use Uri.replace instead of string concatenation
        Uri finalUri = publicUrl.replace(fragment: collectionKey);
        String finalUrl = finalUri.toString();

        // Final validation
        if (finalUrl.isEmpty || !finalUrl.contains('#')) {
          throw AssertionError("Generated invalid public URL");
        }

        return finalUrl;
      }

      print("\nFixed code with empty URL:");
      expect(
        () => getPublicUrlNew("", "abc123"),
        throwsA(isA<AssertionError>()),
      );
      print("  ✓ Throws AssertionError instead of returning '#abc123'");
    });

    test('NEW code properly handles URL with existing fragment', () {
      String getPublicUrlNew(String backendUrl, String collectionKey) {
        if (backendUrl.isEmpty) {
          throw AssertionError("Empty public URL from backend");
        }

        Uri publicUrl = Uri.parse(backendUrl);

        if (!publicUrl.hasScheme || !publicUrl.hasAuthority) {
          throw AssertionError("Invalid public URL from backend");
        }

        // Remove existing fragment - THIS IS KEY
        if (publicUrl.hasFragment) {
          publicUrl = publicUrl.replace(fragment: '');
        }

        // Use Uri.replace to set new fragment
        Uri finalUri = publicUrl.replace(fragment: collectionKey);
        return finalUri.toString();
      }

      String result = getPublicUrlNew(
        "https://albums.ente.io#oldkey",
        "newkey123",
      );

      print("\nFixed code with existing fragment:");
      print("  Backend URL: 'https://albums.ente.io#oldkey'");
      print("  Result: '$result'");

      // Now it correctly replaces the fragment instead of appending
      expect(result, equals("https://albums.ente.io#newkey123"));
      expect(result.split('#').length, equals(2)); // Only ONE # sign
      print("  ✓ Correctly replaces fragment instead of appending");
    });
  });
}
