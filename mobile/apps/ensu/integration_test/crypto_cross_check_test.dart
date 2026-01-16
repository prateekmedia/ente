import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart';
import 'package:ente_crypto_dart_adapter/ente_crypto_dart_adapter.dart';
import 'package:ente_crypto_rust_adapter/ente_crypto_rust_adapter.dart';
import 'package:ente_rust/ente_rust.dart' hide CryptoUtil;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const int _chunkSize = 4 * 1024 * 1024;
const int _smallSize = 512 * 1024;

class _FileCase {
  const _FileCase(this.label, this.size);

  final String label;
  final int size;
}

const List<_FileCase> _fileCases = [
  _FileCase('empty', 0),
  _FileCase('small', _smallSize),
  _FileCase('exact_chunk', _chunkSize),
  _FileCase('over_chunk', _chunkSize + 1),
  _FileCase('multiple_chunks', _chunkSize * 2),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await EnteRust.init();
    initCrypto();
  });

  testWidgets('crypto cross-check adapter', (tester) async {
    registerCryptoApi(EnteCryptoCrossCheckAdapter());
    await CryptoUtil.init();

    final payload = Uint8List.fromList(const [1, 2, 3, 4, 5, 6]);
    final key = CryptoUtil.generateKey();
    final encrypted = CryptoUtil.encryptSync(payload, key);
    final decrypted = CryptoUtil.decryptSync(
      encrypted.encryptedData!,
      key,
      encrypted.nonce!,
    );

    expect(decrypted, equals(payload));
  });

  testWidgets('file crypto parity for chunk boundaries', (tester) async {
    final rustAdapter = EnteCryptoRustAdapter();
    const dartAdapter = EnteCryptoDartAdapter();
    await rustAdapter.init();
    await dartAdapter.init();

    for (final testCase in _fileCases) {
      final tempDir = await Directory.systemTemp.createTemp(
        'ensu_file_crypto_${testCase.label}_',
      );
      try {
        final sourceFile = await _writeTestFile(
          tempDir,
          'source_${testCase.label}',
          testCase.size,
        );
        final key = dartAdapter.generateKey();

        await _exerciseEncryptFileParity(
          label: '${testCase.label}:rust_to_dart',
          encryptAdapter: rustAdapter,
          decryptAdapter: dartAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/rust.enc'),
          decryptedFile: File('${tempDir.path}/dart.dec'),
          key: key,
        );

        await _exerciseEncryptFileParity(
          label: '${testCase.label}:dart_to_rust',
          encryptAdapter: dartAdapter,
          decryptAdapter: rustAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/dart.enc'),
          decryptedFile: File('${tempDir.path}/rust.dec'),
          key: key,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    }
  });

  testWidgets('file crypto md5 parity for chunk boundaries', (tester) async {
    final rustAdapter = EnteCryptoRustAdapter();
    const dartAdapter = EnteCryptoDartAdapter();
    await rustAdapter.init();
    await dartAdapter.init();

    for (final testCase in _fileCases) {
      final tempDir = await Directory.systemTemp.createTemp(
        'ensu_file_md5_${testCase.label}_',
      );
      try {
        final sourceFile = await _writeTestFile(
          tempDir,
          'source_${testCase.label}',
          testCase.size,
        );
        final key = rustAdapter.generateKey();

        await _exerciseEncryptFileWithMd5Parity(
          label: '${testCase.label}:rust_to_dart_full_md5',
          encryptAdapter: rustAdapter,
          decryptAdapter: dartAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/rust_full.enc'),
          decryptedFile: File('${tempDir.path}/dart_full.dec'),
          key: key,
        );

        await _exerciseEncryptFileWithMd5Parity(
          label: '${testCase.label}:dart_to_rust_full_md5',
          encryptAdapter: dartAdapter,
          decryptAdapter: rustAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/dart_full.enc'),
          decryptedFile: File('${tempDir.path}/rust_full.dec'),
          key: key,
        );

        await _exerciseEncryptFileWithMd5Parity(
          label: '${testCase.label}:rust_to_dart_part_md5',
          encryptAdapter: rustAdapter,
          decryptAdapter: dartAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/rust_part.enc'),
          decryptedFile: File('${tempDir.path}/dart_part.dec'),
          key: key,
          multiPartChunkSizeInBytes: _chunkSize,
        );

        await _exerciseEncryptFileWithMd5Parity(
          label: '${testCase.label}:dart_to_rust_part_md5',
          encryptAdapter: dartAdapter,
          decryptAdapter: rustAdapter,
          sourceFile: sourceFile,
          encryptedFile: File('${tempDir.path}/dart_part.enc'),
          decryptedFile: File('${tempDir.path}/rust_part.dec'),
          key: key,
          multiPartChunkSizeInBytes: _chunkSize,
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    }
  });
}

Future<File> _writeTestFile(
  Directory tempDir,
  String name,
  int size,
) async {
  final file = File('${tempDir.path}/$name.bin');
  if (size == 0) {
    await file.writeAsBytes(const [], flush: true);
    return file;
  }
  final bytes = Uint8List(size);
  for (var index = 0; index < size; index++) {
    bytes[index] = index % 251;
  }
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<void> _exerciseEncryptFileParity({
  required String label,
  required CryptoApi encryptAdapter,
  required CryptoApi decryptAdapter,
  required File sourceFile,
  required File encryptedFile,
  required File decryptedFile,
  required Uint8List key,
}) async {
  final result = await encryptAdapter.encryptFile(
    sourceFile.path,
    encryptedFile.path,
    key: key,
  );
  expect(result.header, isNotNull, reason: '$label header');
  await decryptAdapter.decryptFile(
    encryptedFile.path,
    decryptedFile.path,
    result.header!,
    key,
  );
  await _expectFilesMatch(sourceFile, decryptedFile, label: label);
}

Future<void> _exerciseEncryptFileWithMd5Parity({
  required String label,
  required CryptoApi encryptAdapter,
  required CryptoApi decryptAdapter,
  required File sourceFile,
  required File encryptedFile,
  required File decryptedFile,
  required Uint8List key,
  int? multiPartChunkSizeInBytes,
}) async {
  final result = await encryptAdapter.encryptFileWithMd5(
    sourceFile.path,
    encryptedFile.path,
    key: key,
    multiPartChunkSizeInBytes: multiPartChunkSizeInBytes,
  );
  await decryptAdapter.decryptFile(
    encryptedFile.path,
    decryptedFile.path,
    result.header,
    result.key,
  );
  await _expectFilesMatch(sourceFile, decryptedFile, label: label);

  if (multiPartChunkSizeInBytes == null) {
    expect(result.partMd5s, isNull, reason: '$label partMd5s');
    expect(result.partSize, isNull, reason: '$label partSize');
    expect(result.fileMd5, isNotNull, reason: '$label fileMd5');
    final fileMd5 = await _fileMd5Base64(encryptedFile);
    expect(result.fileMd5, fileMd5, reason: '$label fileMd5 match');
  } else {
    expect(result.fileMd5, isNull, reason: '$label fileMd5');
    expect(
      result.partSize,
      multiPartChunkSizeInBytes,
      reason: '$label partSize',
    );
    final partMd5s = await _filePartMd5Base64s(
      encryptedFile,
      multiPartChunkSizeInBytes,
    );
    expect(result.partMd5s, isNotNull, reason: '$label partMd5s');
    expect(result.partMd5s, partMd5s, reason: '$label partMd5s match');
  }
}

Future<void> _expectFilesMatch(
  File expected,
  File actual, {
  required String label,
}) async {
  final expectedLength = await expected.length();
  final actualLength = await actual.length();
  expect(actualLength, expectedLength, reason: '$label length');
  final expectedHash = await _fileMd5Base64(expected);
  final actualHash = await _fileMd5Base64(actual);
  expect(actualHash, expectedHash, reason: '$label hash');
}

Future<String> _fileMd5Base64(File file) async {
  final accumulator = AccumulatorSink<Digest>();
  final md5Sink = md5.startChunkedConversion(accumulator);
  await for (final chunk in file.openRead()) {
    md5Sink.add(chunk);
  }
  md5Sink.close();
  return base64.encode(accumulator.events.single.bytes);
}

Future<List<String>> _filePartMd5Base64s(File file, int partSize) async {
  final partMd5s = <String>[];
  final reader = file.openSync(mode: FileMode.read);
  try {
    while (true) {
      final chunk = reader.readSync(partSize);
      if (chunk.isEmpty) {
        break;
      }
      final digest = md5.convert(chunk);
      partMd5s.add(base64.encode(digest.bytes));
    }
  } finally {
    reader.closeSync();
  }
  return partMd5s;
}
