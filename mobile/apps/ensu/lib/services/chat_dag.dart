import 'package:ensu/store/chat_db.dart';

/// Helpers for reasoning about the chat message DAG.
class ChatDag {
  /// Time window used to consider children identical (milliseconds).
  static const int defaultDuplicateWindowMs = 2000;

  /// Index messages by UUID for quick parent traversal.
  static Map<String, LocalMessage> indexById(
    Iterable<LocalMessage> messages,
  ) {
    final byId = <String, LocalMessage>{};
    for (final message in messages) {
      byId[message.messageUuid] = message;
    }
    return byId;
  }

  /// Build a parent -> children map. Children are ordered by createdAt.
  static Map<String?, List<LocalMessage>> buildChildrenMap(
    Iterable<LocalMessage> messages,
  ) {
    final children = <String?, List<LocalMessage>>{};

    for (final message in messages) {
      final parentId = message.parentMessageUuid;
      children.putIfAbsent(parentId, () => []).add(message);
    }

    for (final entry in children.values) {
      entry.sort(_compareByCreatedAt);
    }

    return children;
  }

  /// Return leaf messages with no children (heads).
  static List<LocalMessage> findHeads(Iterable<LocalMessage> messages) {
    final list = messages.toList();
    if (list.isEmpty) return [];

    final parentIds = <String>{};
    for (final message in list) {
      final parentId = message.parentMessageUuid;
      if (parentId != null) {
        parentIds.add(parentId);
      }
    }

    final heads = <LocalMessage>[];
    for (final message in list) {
      if (!parentIds.contains(message.messageUuid)) {
        heads.add(message);
      }
    }

    heads.sort(_compareByCreatedAt);
    return heads;
  }

  /// Returns true if ancestorId is in descendantId's parent chain (inclusive).
  static bool isAncestor({
    required String ancestorId,
    required String descendantId,
    required Map<String, LocalMessage> byId,
  }) {
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

  /// Returns true if candidate is a duplicate of any sibling.
  static bool isDuplicateChild(
    LocalMessage candidate,
    Iterable<LocalMessage> siblings, {
    int windowMs = defaultDuplicateWindowMs,
  }) {
    for (final sibling in siblings) {
      if (sibling.messageUuid == candidate.messageUuid) {
        continue;
      }
      if (_sameSignature(candidate, sibling) &&
          (candidate.createdAt - sibling.createdAt).abs() <= windowMs) {
        return true;
      }
    }

    return false;
  }

  /// Remove duplicate children, keeping the earliest entry per signature window.
  static List<LocalMessage> dedupeChildren(
    Iterable<LocalMessage> children, {
    int windowMs = defaultDuplicateWindowMs,
  }) {
    final sorted = children.toList()..sort(_compareByCreatedAt);
    final unique = <LocalMessage>[];

    for (final child in sorted) {
      if (!isDuplicateChild(child, unique, windowMs: windowMs)) {
        unique.add(child);
      }
    }

    return unique;
  }

  static int _compareByCreatedAt(LocalMessage a, LocalMessage b) {
    final timeCompare = a.createdAt.compareTo(b.createdAt);
    if (timeCompare != 0) return timeCompare;
    return a.messageUuid.compareTo(b.messageUuid);
  }

  static bool _sameSignature(LocalMessage a, LocalMessage b) {
    return a.sender == b.sender && a.text == b.text;
  }
}
