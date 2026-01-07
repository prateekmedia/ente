/// Entity returned from the server (using auth's entity format).
/// We store chat data as encrypted JSON in the same format as auth codes.
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
    return ChatEntity(
      id: map['id'] as String,
      encryptedData: map['encryptedData'] as String,
      header: map['header'] as String,
      createdAt: map['createdAt'] as int,
      updatedAt: map['updatedAt'] as int,
      isDeleted: map['isDeleted'] as bool? ?? false,
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
      encryptedKey: map['encryptedKey'] as String,
      header: map['header'] as String,
    );
  }
}
