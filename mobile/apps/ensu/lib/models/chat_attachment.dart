enum ChatAttachmentKind {
  image,
  document,
}

enum ChatAttachmentUploadState {
  pending,
  uploading,
  uploaded,
  failed,
}

class ChatAttachment {
  final String id;
  final ChatAttachmentKind kind;
  final int size;
  final String? extension;
  final String? encryptedName;
  final ChatAttachmentUploadState? uploadState;

  const ChatAttachment({
    required this.id,
    required this.kind,
    required this.size,
    this.extension,
    this.encryptedName,
    this.uploadState,
  });

  @override
  bool operator ==(Object other) {
    return other is ChatAttachment &&
        other.id == id &&
        other.kind == kind &&
        other.size == size &&
        other.extension == extension &&
        other.encryptedName == encryptedName;
  }

  @override
  int get hashCode =>
      Object.hash(id, kind, size, extension, encryptedName);

  ChatAttachment copyWith({
    String? id,
    ChatAttachmentKind? kind,
    int? size,
    String? extension,
    String? encryptedName,
    ChatAttachmentUploadState? uploadState,
  }) {
    return ChatAttachment(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      size: size ?? this.size,
      extension: extension ?? this.extension,
      encryptedName: encryptedName ?? this.encryptedName,
      uploadState: uploadState ?? this.uploadState,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'kind': kind.name,
      'size': size,
      if (encryptedName != null) 'encrypted_name': encryptedName,
      if (extension != null) 'extension': extension,
    };
  }

  Map<String, dynamic> toServerJson() {
    final data = <String, dynamic>{
      'id': id,
      'size': size,
    };
    if (encryptedName != null) {
      data['encrypted_name'] = encryptedName;
    }
    return data;
  }

  factory ChatAttachment.fromJson(Map<String, dynamic> json) {
    ChatAttachmentKind parseKind(dynamic value) {
      if (value is String) {
        return ChatAttachmentKind.values.firstWhere(
          (kind) => kind.name == value,
          orElse: () => ChatAttachmentKind.document,
        );
      }
      return ChatAttachmentKind.document;
    }

    int parseInt(dynamic value) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      return 0;
    }

    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw ArgumentError('ChatAttachment id is missing');
    }

    final ext = (json['extension'] is String)
        ? (json['extension'] as String).trim()
        : null;
    final encryptedNameValue = json['encrypted_name'] ?? json['encryptedName'];
    final encryptedName = encryptedNameValue is String &&
            encryptedNameValue.trim().isNotEmpty
        ? encryptedNameValue.trim()
        : null;

    return ChatAttachment(
      id: id,
      kind: parseKind(json['kind']),
      size: parseInt(json['size']),
      extension: (ext == null || ext.isEmpty) ? null : ext,
      encryptedName: encryptedName,
    );
  }
}
