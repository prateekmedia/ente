// Debug-only crypto parity/cross-check utilities.
//
// NOTE: This code is intended for development/testing and may log sensitive
// material on mismatches. It should not be shipped to production and is
// expected to be removed/disabled for production builds.
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:ente_crypto_cross_check_adapter/src/crypto_cross_check_exception.dart';
import 'package:logging/logging.dart';

final Logger _logger = Logger('CryptoCrossCheck');
const ListEquality<int> _bytesEqual = ListEquality<int>();

void assertEqualBytes(
  Uint8List actual,
  Uint8List expected,
  String label, {
  bool redact = false,
}) {
  if (!_bytesEqual.equals(actual, expected)) {
    failCrossCheck(
      label,
      'byte mismatch len=${actual.length} vs ${expected.length} '
      'actual=${_shortB64(actual)} expected=${_shortB64(expected)}',
    );
  }
}

void assertEqualString(String actual, String expected, String label) {
  if (actual != expected) {
    failCrossCheck(
      label,
      'string mismatch actual="$actual" expected="$expected"',
    );
  }
}

void assertEqualInt(int actual, int expected, String label) {
  if (actual != expected) {
    failCrossCheck(label, 'int mismatch actual=$actual expected=$expected');
  }
}

Never failCrossCheck(String label, String details) {
  _logger.severe('Crypto cross-check failed [$label] $details');
  throw CryptoCrossCheckException(label);
}

String _shortB64(Uint8List data) {
  return base64Encode(data);
}
