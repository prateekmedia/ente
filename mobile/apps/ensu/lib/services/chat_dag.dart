import 'package:collection/collection.dart';
import 'package:ensu/store/chat_db.dart';

const _attachmentEquality = DeepCollectionEquality();

/// Helpers for reasoning about the chat message DAG.
class ChatDag {
  /// Time window used to consider children identical (microseconds).
  static const int defaultDuplicateWindowUs = 2000000;

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

  /// Return parent-first order excluding blocked messages and descendants.
  static List<LocalMessage> orderForSync(
    Iterable<LocalMessage> messages,
    Set<String> blockedMessageIds,
  ) {
    final list = messages.toList();
    if (list.isEmpty) return [];

    final byId = indexById(list);
    final children = buildChildrenMap(list);
    final blocked = _expandBlocked(blockedMessageIds, children);

    final roots = list
        .where((message) {
          final parentId = message.parentMessageUuid;
          return parentId == null || !byId.containsKey(parentId);
        })
        .toList()
      ..sort(_compareByCreatedAt);

    final ordered = <LocalMessage>[];
    final visited = <String>{};

    void visit(LocalMessage message) {
      if (blocked.contains(message.messageUuid)) {
        return;
      }
      if (!visited.add(message.messageUuid)) {
        return;
      }
      ordered.add(message);
      final childList = children[message.messageUuid];
      if (childList == null || childList.isEmpty) {
        return;
      }
      for (final child in childList) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }

    if (ordered.length < list.length) {
      final remaining = list
          .where((message) =>
              !visited.contains(message.messageUuid) &&
              !blocked.contains(message.messageUuid))
          .toList()
        ..sort(_compareByCreatedAt);
      for (final message in remaining) {
        visit(message);
      }
    }

    return ordered;
  }

  static Set<String> _expandBlocked(
    Set<String> blockedMessageIds,
    Map<String?, List<LocalMessage>> children,
  ) {
    final blocked = Set<String>.from(blockedMessageIds);
    final queue = List<String>.from(blockedMessageIds);

    while (queue.isNotEmpty) {
      final parentId = queue.removeLast();
      final childList = children[parentId];
      if (childList == null) {
        continue;
      }
      for (final child in childList) {
        if (blocked.add(child.messageUuid)) {
          queue.add(child.messageUuid);
        }
      }
    }

    return blocked;
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
    int windowUs = defaultDuplicateWindowUs,
  }) {
    for (final sibling in siblings) {
      if (sibling.messageUuid == candidate.messageUuid) {
        continue;
      }
      if (_sameSignature(candidate, sibling) &&
          (candidate.createdAt - sibling.createdAt).abs() <= windowUs) {
        return true;
      }
    }

    return false;
  }

  /// Remove duplicate children, keeping the earliest entry per signature window.
  static List<LocalMessage> dedupeChildren(
    Iterable<LocalMessage> children, {
    int windowUs = defaultDuplicateWindowUs,
  }) {
    final sorted = children.toList()..sort(_compareByCreatedAt);
    final unique = <LocalMessage>[];

    for (final child in sorted) {
      if (!isDuplicateChild(child, unique, windowUs: windowUs)) {
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
    return a.sender == b.sender &&
        a.text == b.text &&
        _attachmentEquality.equals(a.attachments, b.attachments);
  }
}
