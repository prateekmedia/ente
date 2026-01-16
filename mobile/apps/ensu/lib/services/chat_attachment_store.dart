import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

class ChatAttachmentInfo {
  final String attachmentId;
  final int size;
  final String? encryptedName;

  const ChatAttachmentInfo({
    required this.attachmentId,
    required this.size,
    this.encryptedName,
  });
}

class ChatAttachmentStore {
  static const int _nonceLength = 24;
  static const int _attachmentKeyLength = 32;
  static const String _attachmentKeyInfo = 'llmchat_attachment_v1';
  static const String _attachmentsDirName = 'chat_attachments';
  static const String _attachmentMetadataExtension = '.meta';
  static const String _metadataPrefix = 'enc:v1:';
  static final Uuid _uuid = Uuid();
  static final CryptoApi _fileCrypto = EnteCryptoCrossCheckAdapter();

  ChatAttachmentStore._();
  static final ChatAttachmentStore instance = ChatAttachmentStore._();

  Future<void> _ensureFileCryptoReady() => _fileCrypto.init();

  Future<ChatAttachmentInfo> writeAttachment(
    String sourceFilePath, {
    required String sessionUuid,
    Uint8List? baseKey,
    String? attachmentId,
    String? fileName,
    Map<String, dynamic>? metadata,
  }) async {
    await _ensureFileCryptoReady();
    final resolvedKey = await _resolveKey(sessionUuid, baseKey);
    final id = attachmentId ?? _uuid.v4();
    final attachmentsDir = await _getAttachmentsDir();
    final encryptedPath = join(attachmentsDir.path, id);
    final tempPath = '$encryptedPath.tmp';
    final sourceFile = File(sourceFilePath);
    final sourceSize = await sourceFile.length();

    final result = await _fileCrypto.encryptFile(
      sourceFilePath,
      tempPath,
      key: resolvedKey,
    );
    final header = result.header;
    if (header == null || header.length != _nonceLength) {
      throw StateError('Invalid attachment header');
    }

    final outputFile = File(encryptedPath);
    final sink = outputFile.openWrite();
    sink.add(header);
    await sink.addStream(File(tempPath).openRead());
    await sink.close();
    await File(tempPath).delete();

    if (metadata != null && metadata.isNotEmpty) {
      await _writeAttachmentMetadata(
        id,
        sessionUuid,
        metadata,
        resolvedKey,
      );
    }

    String? encryptedName;
    if (fileName != null && fileName.trim().isNotEmpty) {
      encryptedName = await _encryptAttachmentName(fileName, resolvedKey);
    }

    return ChatAttachmentInfo(
      attachmentId: id,
      size: sourceSize,
      encryptedName: encryptedName,
    );
  }

  Future<void> decryptAttachment(
    String attachmentId,
    String destinationFilePath, {
    required String sessionUuid,
    Uint8List? baseKey,
  }) async {
    await _ensureFileCryptoReady();
    final resolvedKey = await _resolveKey(sessionUuid, baseKey);
    final encryptedFile = await _getAttachmentFile(attachmentId);
    final header = await _readHeader(encryptedFile);
    final payloadPath = '${encryptedFile.path}.payload';
    await encryptedFile
        .openRead(_nonceLength)
        .pipe(File(payloadPath).openWrite());
    await _fileCrypto.decryptFile(
      payloadPath,
      destinationFilePath,
      header,
      resolvedKey,
    );
    await File(payloadPath).delete();
  }

  Future<void> deleteAttachment(String attachmentId) async {
    final file = await _getAttachmentFile(attachmentId);
    if (await file.exists()) {
      await file.delete();
    }
    final metadataFile = await _getAttachmentMetadataFile(attachmentId);
    if (await metadataFile.exists()) {
      await metadataFile.delete();
    }
  }

  Future<bool> hasAttachment(String attachmentId) async {
    final file = await _getAttachmentFile(attachmentId);
    return file.exists();
  }

  Future<Uint8List?> readEncryptedAttachmentBytes(String attachmentId) async {
    final file = await _getAttachmentFile(attachmentId);
    if (!await file.exists()) {
      return null;
    }
    return file.readAsBytes();
  }

  Future<void> storeEncryptedAttachmentBytes(
    String attachmentId,
    Uint8List encryptedBytes,
  ) async {
    final file = await _getAttachmentFile(attachmentId);
    await file.writeAsBytes(encryptedBytes, flush: true);
  }

  Future<Map<String, dynamic>?> readAttachmentMetadata(
    String attachmentId, {
    required String sessionUuid,
    Uint8List? baseKey,
  }) async {
    final file = await _getAttachmentMetadataFile(attachmentId);
    if (!await file.exists()) {
      return null;
    }
    try {
      final content = await file.readAsString();
      if (!content.startsWith(_metadataPrefix)) {
        return null;
      }
      final payload = content.substring(_metadataPrefix.length);
      final parts = payload.split(':');
      if (parts.length != 2) {
        return null;
      }
      final encryptedData = CryptoUtil.base642bin(parts[0]);
      final header = CryptoUtil.base642bin(parts[1]);
      final resolvedKey = await _resolveKey(sessionUuid, baseKey);
      final decrypted =
          await CryptoUtil.decryptData(encryptedData, resolvedKey, header);
      final decoded = utf8.decode(decrypted, allowMalformed: true);
      final parsed = jsonDecode(decoded);
      if (parsed is Map<String, dynamic>) {
        return parsed;
      }
      if (parsed is Map) {
        return Map<String, dynamic>.from(parsed);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<File> _getAttachmentFile(String attachmentId) async {
    final dir = await _getAttachmentsDir();
    return File(join(dir.path, attachmentId));
  }

  Future<File> _getAttachmentMetadataFile(String attachmentId) async {
    final dir = await _getAttachmentsDir();
    return File(join(dir.path, '$attachmentId$_attachmentMetadataExtension'));
  }

  Future<void> _writeAttachmentMetadata(
    String attachmentId,
    String sessionUuid,
    Map<String, dynamic> metadata,
    Uint8List resolvedKey,
  ) async {
    final payload = utf8.encode(jsonEncode(metadata));
    final encrypted =
        await CryptoUtil.encryptData(Uint8List.fromList(payload), resolvedKey);
    final encryptedData = CryptoUtil.bin2base64(encrypted.encryptedData!);
    final header = CryptoUtil.bin2base64(encrypted.header!);
    final content = '$_metadataPrefix$encryptedData:$header';
    final metadataFile = await _getAttachmentMetadataFile(attachmentId);
    await metadataFile.writeAsString(content, flush: true);
  }

  Future<String> _encryptAttachmentName(
    String fileName,
    Uint8List resolvedKey,
  ) async {
    final payload = utf8.encode(fileName);
    final encrypted =
        await CryptoUtil.encryptData(Uint8List.fromList(payload), resolvedKey);
    final encryptedData = CryptoUtil.bin2base64(encrypted.encryptedData!);
    final header = CryptoUtil.bin2base64(encrypted.header!);
    return '$_metadataPrefix$encryptedData:$header';
  }

  Future<Uint8List> _readHeader(File file) async {
    final raf = await file.open();
    final header = await raf.read(_nonceLength);
    await raf.close();
    if (header.length != _nonceLength) {
      throw StateError('Invalid attachment header');
    }
    return header;
  }

  Future<Directory> _getAttachmentsDir() async {
    final Directory baseDir;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      baseDir = await getApplicationSupportDirectory();
    } else {
      baseDir = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(join(baseDir.path, _attachmentsDirName));
    await dir.create(recursive: true);
    return dir;
  }

  Future<Uint8List> _resolveKey(
    String sessionUuid,
    Uint8List? baseKey,
  ) async {
    final resolvedBaseKey = baseKey ?? await _resolveBaseKey();
    return _deriveAttachmentKey(resolvedBaseKey, sessionUuid);
  }

  Future<Uint8List> _resolveBaseKey() async {
    if (Configuration.instance.hasConfiguredAccount()) {
      return ChatService.instance.getOrCreateChatKey();
    }
    return Configuration.instance.getOrCreateOfflineChatSecretKey();
  }

  Uint8List _deriveAttachmentKey(Uint8List baseKey, String sessionUuid) {
    final salt = Uint8List.fromList(utf8.encode(sessionUuid));
    final info = Uint8List.fromList(utf8.encode(_attachmentKeyInfo));
    final hkdf = HKDFKeyDerivator(SHA256Digest());
    hkdf.init(HkdfParameters(baseKey, _attachmentKeyLength, salt, info));
    final derived = Uint8List(_attachmentKeyLength);
    hkdf.deriveKey(null, 0, derived, 0);
    return derived;
  }
}
