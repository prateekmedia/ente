/// Represents a chat session (conversation) with another person.
class ChatSession {
  /// Unique identifier for this session (local generated ID)
  final int generatedID;

  /// Remote server ID (null if not yet synced)
  final String? id;

  /// Title/name for this conversation
  final String title;

  /// Preview of the last message
  final String? lastMessagePreview;

  /// Timestamp of the last message (milliseconds since epoch)
  final int? lastMessageAt;

  /// When this session was created (milliseconds since epoch)
  final int createdAt;

  /// Whether this session needs to be synced to remote
  final bool shouldSync;

  const ChatSession({
    required this.generatedID,
    this.id,
    required this.title,
    this.lastMessagePreview,
    this.lastMessageAt,
    required this.createdAt,
    this.shouldSync = true,
  });

  ChatSession copyWith({
    int? generatedID,
    String? id,
    String? title,
    String? lastMessagePreview,
    int? lastMessageAt,
    int? createdAt,
    bool? shouldSync,
  }) {
    return ChatSession(
      generatedID: generatedID ?? this.generatedID,
      id: id ?? this.id,
      title: title ?? this.title,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      createdAt: createdAt ?? this.createdAt,
      shouldSync: shouldSync ?? this.shouldSync,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'generatedID': generatedID,
      'id': id,
      'title': title,
      'lastMessagePreview': lastMessagePreview,
      'lastMessageAt': lastMessageAt,
      'createdAt': createdAt,
      'shouldSync': shouldSync ? 1 : 0,
    };
  }

  factory ChatSession.fromMap(Map<String, dynamic> map) {
    return ChatSession(
      generatedID: map['generatedID'] as int,
      id: map['id'] as String?,
      title: map['title'] as String,
      lastMessagePreview: map['lastMessagePreview'] as String?,
      lastMessageAt: map['lastMessageAt'] as int?,
      createdAt: map['createdAt'] as int,
      shouldSync: (map['shouldSync'] as int?) == 1,
    );
  }
}
