import 'dart:convert';

import 'package:ensu/models/chat_attachment.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ChatEntity');

/// Entity returned from the llmchat chat API.
/// Supports both legacy camelCase and new snake_case fields.
class ChatEntity {
  final String id;
  final String? sessionUuid;
  final String? rootSessionUuid;
  final String? branchFromMessageUuid;
  final String? parentMessageUuid;
  final String? sender;
  final List<ChatAttachment> attachments;
  final String encryptedData;
  final String header;
  final int createdAt;
  final int updatedAt;
  final bool isDeleted;

  const ChatEntity({
    required this.id,
    this.sessionUuid,
    this.rootSessionUuid,
    this.branchFromMessageUuid,
    this.parentMessageUuid,
    this.sender,
    this.attachments = const [],
    required this.encryptedData,
    required this.header,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  factory ChatEntity.fromMap(Map<String, dynamic> map) {
    int readInt(dynamic value, {int fallback = 0}) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return fallback;
    }

    bool readBool(dynamic value) {
      if (value is bool) return value;
      if (value is int) return value != 0;
      return false;
    }

    String? readString(dynamic value) {
      if (value is String) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        return trimmed;
      }
      return null;
    }

    List<ChatAttachment> readAttachments(dynamic value) {
      if (value is List) {
        if (value.isEmpty) return const [];

        final attachments = <ChatAttachment>[];
        for (final entry in value) {
          if (entry is Map) {
            try {
              attachments.add(
                ChatAttachment.fromJson(Map<String, dynamic>.from(entry)),
              );
            } catch (e, s) {
              _logger.warning('Failed to parse chat attachment entry', e, s);
              continue;
            }
          } else if (entry is String && entry.isNotEmpty) {
            attachments.add(
              ChatAttachment(
                id: entry,
                kind: ChatAttachmentKind.document,
                size: 0,
              ),
            );
          }
        }
        return attachments;
      }

      if (value is String && value.isNotEmpty) {
        try {
          final decoded = jsonDecode(value);
          return readAttachments(decoded);
        } catch (_) {
          return const [];
        }
      }

      return const [];
    }

    final idValue = map['id'] ?? map['session_uuid'] ?? map['message_uuid'];
    if (idValue == null) {
      throw ArgumentError('ChatEntity id is missing');
    }

    final deletedAt = map['deleted_at'];
    final createdAt = readInt(
      map['createdAt'] ?? map['created_at'] ?? deletedAt,
    );
    final updatedAt = readInt(
      map['updatedAt'] ?? map['updated_at'] ?? deletedAt,
      fallback: createdAt,
    );
    final isDeleted =
        readBool(map['isDeleted'] ?? map['is_deleted']) || deletedAt != null;

    final sessionUuid = readString(map['sessionUuid'] ?? map['session_uuid']);
    final rootSessionUuid =
        readString(map['rootSessionUuid'] ?? map['root_session_uuid']);
    final branchFromMessageUuid = readString(
        map['branchFromMessageUuid'] ?? map['branch_from_message_uuid']);
    final parentMessageUuid =
        readString(map['parentMessageUuid'] ?? map['parent_message_uuid']);
    final sender = readString(map['sender']);
    final attachments = readAttachments(
      map['attachments'] ?? map['attachment_ids'] ?? map['attachmentIds'],
    );

    return ChatEntity(
      id: idValue as String,
      sessionUuid: sessionUuid,
      rootSessionUuid: rootSessionUuid,
      branchFromMessageUuid: branchFromMessageUuid,
      parentMessageUuid: parentMessageUuid,
      sender: sender,
      attachments: attachments,
      encryptedData:
          (map['encryptedData'] ?? map['encrypted_data'] ?? '') as String,
      header: (map['header'] ?? '') as String,
      createdAt: createdAt,
      updatedAt: updatedAt,
      isDeleted: isDeleted,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'encryptedData': encryptedData,
      'header': header,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'isDeleted': isDeleted,
    };
  }
}

/// Incremental diff from the llmchat chat API.
class ChatDiff {
  final List<ChatEntity> sessions;
  final List<ChatEntity> messages;
  final List<ChatEntity> sessionTombstones;
  final List<ChatEntity> messageTombstones;
  final int? timestamp;

  const ChatDiff({
    required this.sessions,
    required this.messages,
    required this.sessionTombstones,
    required this.messageTombstones,
    required this.timestamp,
  });
}

/// The key used to encrypt/decrypt chat data (stored on server).
class ChatKey {
  final String encryptedKey;
  final String header;

  const ChatKey({
    required this.encryptedKey,
    required this.header,
  });

  factory ChatKey.fromMap(Map<String, dynamic> map) {
    return ChatKey(
      encryptedKey: (map['encryptedKey'] ?? map['encrypted_key']) as String,
      header: map['header'] as String,
    );
  }
}
