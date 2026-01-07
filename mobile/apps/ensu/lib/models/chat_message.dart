/// Sender type for messages
enum MessageSender {
  self,
  other,
}

/// Represents a single chat message within a session.
class ChatMessage {
  /// Unique identifier for this message (local generated ID)
  final int generatedID;

  /// Remote server ID (null if not yet synced)
  final String? id;

  /// The session this message belongs to
  final int sessionGeneratedID;

  /// Who sent the message
  final MessageSender sender;

  /// The message text content
  final String text;

  /// When this message was created (milliseconds since epoch)
  final int createdAt;

  /// Whether this message needs to be synced to remote
  final bool shouldSync;

  /// Tokens per second during generation (null if user message or not calculated)
  final double? tokensPerSecond;

  const ChatMessage({
    required this.generatedID,
    this.id,
    required this.sessionGeneratedID,
    required this.sender,
    required this.text,
    required this.createdAt,
    this.shouldSync = true,
    this.tokensPerSecond,
  });

  /// Helper to check if this message is from the user
  bool get isSelf => sender == MessageSender.self;

  ChatMessage copyWith({
    int? generatedID,
    String? id,
    int? sessionGeneratedID,
    MessageSender? sender,
    String? text,
    int? createdAt,
    bool? shouldSync,
    double? tokensPerSecond,
  }) {
    return ChatMessage(
      generatedID: generatedID ?? this.generatedID,
      id: id ?? this.id,
      sessionGeneratedID: sessionGeneratedID ?? this.sessionGeneratedID,
      sender: sender ?? this.sender,
      text: text ?? this.text,
      createdAt: createdAt ?? this.createdAt,
      shouldSync: shouldSync ?? this.shouldSync,
      tokensPerSecond: tokensPerSecond ?? this.tokensPerSecond,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'generatedID': generatedID,
      'id': id,
      'sessionGeneratedID': sessionGeneratedID,
      'sender': sender == MessageSender.self ? 'self' : 'other',
      'text': text,
      'createdAt': createdAt,
      'shouldSync': shouldSync ? 1 : 0,
      'tokensPerSecond': tokensPerSecond,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      generatedID: map['generatedID'] as int,
      id: map['id'] as String?,
      sessionGeneratedID: map['sessionGeneratedID'] as int,
      sender:
          map['sender'] == 'self' ? MessageSender.self : MessageSender.other,
      text: map['text'] as String,
      createdAt: map['createdAt'] as int,
      shouldSync: (map['shouldSync'] as int?) == 1,
      tokensPerSecond: map['tokensPerSecond'] as double?,
    );
  }
}
