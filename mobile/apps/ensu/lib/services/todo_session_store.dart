class TodoItem {
  final String id;
  final String text;
  final int createdAt;

  const TodoItem({
    required this.id,
    required this.text,
    required this.createdAt,
  });
}

class TodoSessionStore {
  static final TodoSessionStore instance = TodoSessionStore._();

  TodoSessionStore._();

  final Map<String, List<TodoItem>> _itemsBySession = {};
  int _nextId = 0;

  List<TodoItem> list(String sessionId) {
    final items = _itemsBySession[sessionId];
    if (items == null) {
      return const [];
    }
    return List.unmodifiable(items);
  }

  TodoItem add(String sessionId, String text) {
    final trimmed = text.trim();
    final entry = TodoItem(
      id: 'todo_${_nextId++}',
      text: trimmed,
      createdAt: DateTime.now().microsecondsSinceEpoch,
    );
    final items = _itemsBySession.putIfAbsent(sessionId, () => []);
    items.add(entry);
    return entry;
  }

  void clear(String sessionId) {
    _itemsBySession.remove(sessionId);
  }
}
