/// Entity returned from the ensu chat API.
/// Supports both legacy camelCase and new snake_case fields.
class ChatEntity {
  final String id;
  final String encryptedData;
  final String header;
  final int createdAt;
  final int updatedAt;
  final bool isDeleted;

  const ChatEntity({
    required this.id,
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

    return ChatEntity(
      id: idValue as String,
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

/// Incremental diff from the ensu chat API.
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
