import 'package:collection/collection.dart';
import 'package:ensu/models/chat_attachment.dart';
import 'package:ensu/store/chat_db.dart';

const _attachmentEquality = DeepCollectionEquality();

class ChatConflictMessage {
  final String messageUuid;
  final String? parentMessageUuid;
  final String sender;
  final String text;
  final List<ChatAttachment> attachments;
  final int createdAt;

  const ChatConflictMessage({
    required this.messageUuid,
    this.parentMessageUuid,
    required this.sender,
    required this.text,
    this.attachments = const [],
    required this.createdAt,
  });

  factory ChatConflictMessage.fromLocal(LocalMessage message) {
    return ChatConflictMessage(
      messageUuid: message.messageUuid,
      parentMessageUuid: message.parentMessageUuid,
      sender: message.sender,
      text: message.text,
      attachments: message.attachments,
      createdAt: message.createdAt,
    );
  }
}

enum ChatConflictResolutionType { noChange, fastForward, branch }

class ChatConflictResolution {
  final ChatConflictResolutionType type;
  final String? branchFromMessageUuid;
  final List<ChatConflictMessage> messagesToAppend;
  final List<ChatConflictMessage> messagesToBranch;

  const ChatConflictResolution._({
    required this.type,
    this.branchFromMessageUuid,
    this.messagesToAppend = const [],
    this.messagesToBranch = const [],
  });

  const ChatConflictResolution.noChange()
      : this._(type: ChatConflictResolutionType.noChange);

  factory ChatConflictResolution.fastForward({
    required List<ChatConflictMessage> messagesToAppend,
  }) {
    return ChatConflictResolution._(
      type: ChatConflictResolutionType.fastForward,
      messagesToAppend: List.unmodifiable(messagesToAppend),
    );
  }

  factory ChatConflictResolution.branch({
    required String? branchFromMessageUuid,
    required List<ChatConflictMessage> messagesToAppend,
    required List<ChatConflictMessage> messagesToBranch,
  }) {
    return ChatConflictResolution._(
      type: ChatConflictResolutionType.branch,
      branchFromMessageUuid: branchFromMessageUuid,
      messagesToAppend: List.unmodifiable(messagesToAppend),
      messagesToBranch: List.unmodifiable(messagesToBranch),
    );
  }

  bool get hasChanges => type != ChatConflictResolutionType.noChange;
}

class ChatConflictResolver {
  static const int defaultDuplicateWindowUs = 2000000;

  static ChatConflictResolution resolve({
    required List<ChatConflictMessage> localMessages,
    required List<ChatConflictMessage> remoteMessages,
    int duplicateWindowUs = defaultDuplicateWindowUs,
  }) {
    final filteredRemote = _filterRemoteDuplicates(
      localMessages: localMessages,
      remoteMessages: remoteMessages,
      windowUs: duplicateWindowUs,
    );

    if (filteredRemote.isEmpty) {
      return const ChatConflictResolution.noChange();
    }

    if (localMessages.isEmpty) {
      return ChatConflictResolution.fastForward(
        messagesToAppend: _sortMessages(filteredRemote),
      );
    }

    final localHead = _pickHead(localMessages);
    final remoteHead = _pickHead(filteredRemote);
    if (localHead == null || remoteHead == null) {
      return const ChatConflictResolution.noChange();
    }

    final byId = _indexById(localMessages, filteredRemote);
    final localIds = localMessages.map((m) => m.messageUuid).toSet();
    final remoteIds = filteredRemote.map((m) => m.messageUuid).toSet();

    if (_isAncestor(localHead.messageUuid, remoteHead.messageUuid, byId)) {
      final path = _pathFromAncestor(
        ancestorId: localHead.messageUuid,
        headId: remoteHead.messageUuid,
        byId: byId,
      );
      final toAppend = path
          .where((message) => remoteIds.contains(message.messageUuid))
          .toList();

      if (toAppend.isEmpty) {
        return const ChatConflictResolution.noChange();
      }

      return ChatConflictResolution.fastForward(messagesToAppend: toAppend);
    }

    if (_isAncestor(remoteHead.messageUuid, localHead.messageUuid, byId)) {
      return const ChatConflictResolution.noChange();
    }

    final ancestorId = _findCommonAncestor(
        localHead.messageUuid, remoteHead.messageUuid, byId);

    final messagesToAppend = _pathOrFallback(
      ancestorId: ancestorId,
      headId: remoteHead.messageUuid,
      byId: byId,
      includeIds: remoteIds,
      excludeIds: localIds,
      fallbackMessages: filteredRemote,
    );

    final messagesToBranch = _pathOrFallback(
      ancestorId: ancestorId,
      headId: localHead.messageUuid,
      byId: byId,
      includeIds: localIds,
      excludeIds: const {},
      fallbackMessages: localMessages,
    );

    if (messagesToAppend.isEmpty && messagesToBranch.isEmpty) {
      return const ChatConflictResolution.noChange();
    }

    return ChatConflictResolution.branch(
      branchFromMessageUuid: ancestorId,
      messagesToAppend: messagesToAppend,
      messagesToBranch: messagesToBranch,
    );
  }
}

Map<String, ChatConflictMessage> _indexById(
  List<ChatConflictMessage> localMessages,
  List<ChatConflictMessage> remoteMessages,
) {
  final byId = <String, ChatConflictMessage>{};
  for (final message in remoteMessages) {
    byId[message.messageUuid] = message;
  }
  for (final message in localMessages) {
    byId[message.messageUuid] = message;
  }
  return byId;
}

ChatConflictMessage? _pickHead(List<ChatConflictMessage> messages) {
  final heads = _findHeads(messages);
  if (heads.isEmpty) return null;
  return heads.last;
}

List<ChatConflictMessage> _findHeads(List<ChatConflictMessage> messages) {
  if (messages.isEmpty) return [];

  final parents = <String>{};
  for (final message in messages) {
    final parentId = message.parentMessageUuid;
    if (parentId != null) {
      parents.add(parentId);
    }
  }

  final heads = <ChatConflictMessage>[];
  for (final message in messages) {
    if (!parents.contains(message.messageUuid)) {
      heads.add(message);
    }
  }

  heads.sort(_compareByCreatedAt);
  return heads;
}

bool _isAncestor(
  String ancestorId,
  String descendantId,
  Map<String, ChatConflictMessage> byId,
) {
  var currentId = descendantId;
  final seen = <String>{};

  while (true) {
    if (currentId == ancestorId) {
      return true;
    }
    if (!seen.add(currentId)) {
      return false;
    }

    final current = byId[currentId];
    if (current == null) {
      return false;
    }

    final parentId = current.parentMessageUuid;
    if (parentId == null) {
      return false;
    }

    currentId = parentId;
  }
}

String? _findCommonAncestor(
  String localHeadId,
  String remoteHeadId,
  Map<String, ChatConflictMessage> byId,
) {
  final localAncestors = <String>{};
  var currentId = localHeadId;
  final seenLocal = <String>{};

  while (true) {
    if (!seenLocal.add(currentId)) {
      break;
    }
    localAncestors.add(currentId);
    final parentId = byId[currentId]?.parentMessageUuid;
    if (parentId == null) {
      break;
    }
    currentId = parentId;
  }

  currentId = remoteHeadId;
  final seenRemote = <String>{};

  while (true) {
    if (!seenRemote.add(currentId)) {
      return null;
    }
    if (localAncestors.contains(currentId)) {
      return currentId;
    }
    final parentId = byId[currentId]?.parentMessageUuid;
    if (parentId == null) {
      return null;
    }
    currentId = parentId;
  }
}

List<ChatConflictMessage> _pathOrFallback({
  required String? ancestorId,
  required String headId,
  required Map<String, ChatConflictMessage> byId,
  required Set<String> includeIds,
  required Set<String> excludeIds,
  required List<ChatConflictMessage> fallbackMessages,
}) {
  if (ancestorId == null) {
    return _filterByIds(
      _sortMessages(fallbackMessages),
      includeIds,
      excludeIds,
    );
  }

  final path = _pathFromAncestor(
    ancestorId: ancestorId,
    headId: headId,
    byId: byId,
  );

  if (path.isEmpty && ancestorId != headId) {
    return _filterByIds(
      _sortMessages(fallbackMessages),
      includeIds,
      excludeIds,
    );
  }

  return _filterByIds(path, includeIds, excludeIds);
}

List<ChatConflictMessage> _pathFromAncestor({
  required String ancestorId,
  required String headId,
  required Map<String, ChatConflictMessage> byId,
}) {
  if (ancestorId == headId) return [];

  final path = <ChatConflictMessage>[];
  var currentId = headId;
  final seen = <String>{};

  while (currentId != ancestorId) {
    if (!seen.add(currentId)) {
      return [];
    }

    final current = byId[currentId];
    if (current == null) {
      return [];
    }
    path.add(current);

    final parentId = current.parentMessageUuid;
    if (parentId == null) {
      return [];
    }
    currentId = parentId;
  }

  return path.reversed.toList();
}

List<ChatConflictMessage> _filterRemoteDuplicates({
  required List<ChatConflictMessage> localMessages,
  required List<ChatConflictMessage> remoteMessages,
  required int windowUs,
}) {
  if (remoteMessages.isEmpty) return [];

  final localChildren = _buildChildrenMap(localMessages);
  final remoteChildren = <String?, List<ChatConflictMessage>>{};
  final sortedRemote = _sortMessages(remoteMessages);
  final accepted = <ChatConflictMessage>[];

  for (final message in sortedRemote) {
    final parentId = message.parentMessageUuid;
    final siblings = <ChatConflictMessage>[
      ...?localChildren[parentId],
      ...?remoteChildren[parentId],
    ];

    if (_isDuplicateChild(message, siblings, windowUs)) {
      continue;
    }

    accepted.add(message);
    remoteChildren.putIfAbsent(parentId, () => []).add(message);
  }

  return accepted;
}

Map<String?, List<ChatConflictMessage>> _buildChildrenMap(
  List<ChatConflictMessage> messages,
) {
  final children = <String?, List<ChatConflictMessage>>{};
  for (final message in messages) {
    children.putIfAbsent(message.parentMessageUuid, () => []).add(message);
  }
  return children;
}

bool _isDuplicateChild(
  ChatConflictMessage candidate,
  List<ChatConflictMessage> siblings,
  int windowUs,
) {
  for (final sibling in siblings) {
    if (sibling.messageUuid == candidate.messageUuid) {
      return true;
    }
    if (_sameSignature(candidate, sibling) &&
        (candidate.createdAt - sibling.createdAt).abs() <= windowUs) {
      return true;
    }
  }
  return false;
}

bool _sameSignature(ChatConflictMessage a, ChatConflictMessage b) {
  return a.sender == b.sender &&
      a.text == b.text &&
      _attachmentEquality.equals(a.attachments, b.attachments);
}

List<ChatConflictMessage> _filterByIds(
  List<ChatConflictMessage> messages,
  Set<String> includeIds,
  Set<String> excludeIds,
) {
  return messages
      .where((message) => includeIds.contains(message.messageUuid))
      .where((message) => !excludeIds.contains(message.messageUuid))
      .toList();
}

List<ChatConflictMessage> _sortMessages(
  List<ChatConflictMessage> messages,
) {
  final sorted = List<ChatConflictMessage>.from(messages);
  sorted.sort(_compareByCreatedAt);
  return sorted;
}

int _compareByCreatedAt(ChatConflictMessage a, ChatConflictMessage b) {
  final timeCompare = a.createdAt.compareTo(b.createdAt);
  if (timeCompare != 0) return timeCompare;
  return a.messageUuid.compareTo(b.messageUuid);
}
