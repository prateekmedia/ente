import 'dart:convert';

import 'package:ensu/services/todo_session_store.dart';
import 'package:fllama/fllama.dart';

final List<Tool> todoTools = [
  Tool(
    name: 'todo_add',
    description:
        'Add a todo item to the current session list. Parameters: {"text": "..."}.',
    jsonSchema: _todoAddSchema,
  ),
  Tool(
    name: 'todo_list',
    description:
        'List all todo items for the current session. No parameters required.',
    jsonSchema: _todoListSchema,
  ),
  Tool(
    name: 'todo_clear',
    description:
        'Clear all todo items for the current session. No parameters required.',
    jsonSchema: _todoClearSchema,
  ),
];

const String _todoAddSchema = '{'
    '"type":"object",'
    '"properties":{'
    '"text":{"type":"string","description":"Todo item text"}'
    '},'
    '"required":["text"],'
    '"additionalProperties":false'
    '}';

const String _todoListSchema = '{'
    '"type":"object",'
    '"properties":{},'
    '"additionalProperties":false'
    '}';

const String _todoClearSchema = '{'
    '"type":"object",'
    '"properties":{},'
    '"additionalProperties":false'
    '}';

class TodoToolCall {
  final String name;
  final Map<String, dynamic> arguments;

  const TodoToolCall({required this.name, required this.arguments});
}

List<TodoToolCall> parseTodoToolCalls(String responseJson) {
  final normalized = _normalizeJsonText(responseJson);
  if (normalized.isEmpty) {
    return const [];
  }

  dynamic payload;
  try {
    payload = jsonDecode(normalized);
  } catch (_) {
    final sanitized = _sanitizeJsonText(normalized);
    if (sanitized.isNotEmpty) {
      try {
        payload = jsonDecode(sanitized);
      } catch (_) {
        payload = null;
      }
    } else {
      payload = null;
    }
  }

  if (payload == null) {
    return _fallbackTodoCallsFromText(normalized);
  }

  final toolCalls = _extractToolCalls(payload);
  if (toolCalls.isEmpty) {
    return _fallbackTodoCallsFromText(normalized);
  }

  final results = <TodoToolCall>[];
  for (final call in toolCalls) {
    if (call is! Map) {
      continue;
    }
    final function = call['function'] is Map ? call['function'] as Map : call;
    final name = function['name']?.toString() ?? call['name']?.toString();
    if (name == null || name.isEmpty) {
      continue;
    }
    final arguments = _parseArguments(
      function['arguments'] ??
          function['parameters'] ??
          function['args'] ??
          function['input'] ??
          call['arguments'] ??
          call['parameters'] ??
          call['args'] ??
          call['input'],
    );
    results.add(TodoToolCall(name: name, arguments: arguments));
  }

  return results;
}

List<dynamic> _extractToolCalls(dynamic payload) {
  if (payload is List) {
    return payload;
  }

  if (payload is Map) {
    final direct = payload['tool_calls'];
    if (direct is List) {
      return direct;
    }
    final directSingle = payload['tool_call'];
    if (directSingle != null) {
      return [directSingle];
    }
    final message = payload['message'];
    if (message is Map) {
      final msgCalls = message['tool_calls'];
      if (msgCalls is List) {
        return msgCalls;
      }
      final msgSingle = message['tool_call'];
      if (msgSingle != null) {
        return [msgSingle];
      }
    }
    final choices = payload['choices'];
    if (choices is List) {
      for (final choice in choices) {
        if (choice is! Map) continue;
        final choiceMessage = choice['message'];
        if (choiceMessage is Map) {
          final calls = choiceMessage['tool_calls'];
          if (calls is List) {
            return calls;
          }
          final single = choiceMessage['tool_call'];
          if (single != null) {
            return [single];
          }
        }
        final choiceCalls = choice['tool_calls'];
        if (choiceCalls is List) {
          return choiceCalls;
        }
      }
    }
    if (payload.containsKey('function') ||
        payload.containsKey('name') ||
        payload.containsKey('type')) {
      return [payload];
    }
  }

  return const [];
}

String _normalizeJsonText(String raw) {
  var trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  trimmed = _stripModelTokens(trimmed);

  if (trimmed.startsWith('```')) {
    final start = trimmed.indexOf('\n');
    final end = trimmed.lastIndexOf('```');
    if (start != -1 && end > start) {
      trimmed = trimmed.substring(start + 1, end).trim();
    }
  }

  final extracted = _extractJsonSubstring(trimmed);
  return extracted ?? trimmed;
}

String _stripModelTokens(String text) {
  var cleaned = text;
  cleaned = cleaned.replaceAll(RegExp(r'<\|[^>]*\|>'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'<eot_id\|>'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'</?s>'), ' ');
  cleaned = cleaned.replaceAll(RegExp(r'^\s*>+\s*\w+\s*$', multiLine: true), ' ');
  return cleaned.trim();
}

String? _extractJsonSubstring(String text) {
  final firstBrace = text.indexOf('{');
  final lastBrace = text.lastIndexOf('}');
  final firstBracket = text.indexOf('[');
  final lastBracket = text.lastIndexOf(']');

  int start = -1;
  int end = -1;

  if (firstBrace != -1 && (firstBrace < firstBracket || firstBracket == -1)) {
    start = firstBrace;
    end = lastBrace;
  } else if (firstBracket != -1) {
    start = firstBracket;
    end = lastBracket;
  }

  if (start == -1 || end <= start) {
    return null;
  }

  return text.substring(start, end + 1).trim();
}

String _sanitizeJsonText(String raw) {
  final buffer = StringBuffer();
  var inString = false;
  var escape = false;

  for (var i = 0; i < raw.length; i++) {
    final char = raw[i];

    if (inString) {
      buffer.write(char);
      if (escape) {
        escape = false;
      } else if (char == '\\') {
        escape = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }

    if (char == '"') {
      inString = true;
      buffer.write(char);
      continue;
    }

    if (_isAllowedJsonChar(char)) {
      buffer.write(char);
    }
  }

  return buffer.toString().trim();
}

bool _isAllowedJsonChar(String char) {
  if (char.trim().isEmpty) {
    return true;
  }
  const allowedSymbols = '{}[]:,.+-0123456789eE';
  if (allowedSymbols.contains(char)) {
    return true;
  }
  final codeUnit = char.codeUnitAt(0);
  if ((codeUnit >= 65 && codeUnit <= 90) ||
      (codeUnit >= 97 && codeUnit <= 122)) {
    return true;
  }
  return false;
}

List<TodoToolCall> _fallbackTodoCallsFromText(String text) {
  final lower = text.toLowerCase();
  if (!lower.contains('todo_add') &&
      !lower.contains('todo_list') &&
      !lower.contains('todo_clear')) {
    return const [];
  }

  final nameMatch = RegExp(r'(todo_add|todo_list|todo_clear)')
      .firstMatch(lower);
  if (nameMatch == null) {
    return const [];
  }

  final name = nameMatch.group(1)!;
  final arguments = <String, dynamic>{};

  if (name == 'todo_add') {
    const keys = [
      'text',
      'task',
      'todo',
      'item',
      'title',
      'description',
      'value',
    ];
    for (final key in keys) {
      final match = RegExp(
        '"$key"\\s*:\\s*"([^"]+)"',
        caseSensitive: false,
      ).firstMatch(text);
      if (match != null) {
        arguments['text'] = match.group(1)!.trim();
        break;
      }
    }
  }

  return [TodoToolCall(name: name, arguments: arguments)];
}

Map<String, dynamic> _parseArguments(dynamic raw) {
  if (raw == null) {
    return <String, dynamic>{};
  }
  if (raw is Map<String, dynamic>) {
    return raw;
  }
  if (raw is String) {
    final normalized = _normalizeJsonText(raw);
    if (normalized.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(normalized);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      return <String, dynamic>{};
    }
  }
  if (raw is Map) {
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }
  return <String, dynamic>{};
}

enum TodoToolAction { add, list, clear, error }

class TodoToolResult {
  final TodoToolAction action;
  final List<TodoItem> items;
  final String? message;
  final String? addedText;
  final String? error;

  const TodoToolResult({
    required this.action,
    required this.items,
    this.message,
    this.addedText,
    this.error,
  });

  bool get hasError => error != null && error!.isNotEmpty;
}

class TodoToolExecutor {
  final TodoSessionStore _store;

  TodoToolExecutor({TodoSessionStore? store})
      : _store = store ?? TodoSessionStore.instance;

  TodoToolResult execute(TodoToolCall call, String sessionId) {
    switch (call.name) {
      case 'todo_add':
        final text = extractTodoText(call.arguments);
        if (text.isEmpty) {
          return TodoToolResult(
            action: TodoToolAction.error,
            items: _store.list(sessionId),
            error: 'Todo item text is missing.',
          );
        }
        _store.add(sessionId, text);
        return TodoToolResult(
          action: TodoToolAction.add,
          items: _store.list(sessionId),
          addedText: text,
        );
      case 'todo_list':
        return TodoToolResult(
          action: TodoToolAction.list,
          items: _store.list(sessionId),
        );
      case 'todo_clear':
        _store.clear(sessionId);
        return const TodoToolResult(
          action: TodoToolAction.clear,
          items: <TodoItem>[],
        );
      default:
        return TodoToolResult(
          action: TodoToolAction.error,
          items: _store.list(sessionId),
          error: 'Unknown tool: ${call.name}.',
        );
    }
  }
}

String extractTodoText(Map<String, dynamic> arguments) {
  const keys = [
    'text',
    'task',
    'todo',
    'item',
    'title',
    'description',
    'value',
  ];
  for (final key in keys) {
    final value = arguments[key];
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    } else if (value is Map) {
      final nested = value['text'] ?? value['task'] ?? value['title'];
      if (nested is String) {
        final trimmed = nested.trim();
        if (trimmed.isNotEmpty) {
          return trimmed;
        }
      }
    }
  }
  return '';
}

String buildTodoAssistantResponse(List<TodoToolResult> results) {
  final errors = results
      .where((result) => result.hasError)
      .map((result) => result.error!)
      .toList();
  final items = results.isEmpty ? const <TodoItem>[] : results.last.items;

  String assistantText;
  String? status;

  if (errors.isNotEmpty) {
    status = errors.join(' ');
    assistantText =
        'I couldn’t add that yet — what should I put on your todo list?';
  } else if (results.any((r) => r.action == TodoToolAction.clear)) {
    assistantText = 'All set — cleared your todo list.';
  } else if (results.any((r) => r.action == TodoToolAction.add)) {
    final added = results
        .where((r) => r.action == TodoToolAction.add)
        .map((r) => r.addedText)
        .whereType<String>()
        .toList();
    if (added.length == 1) {
      assistantText = 'Added “${added.first}”.';
    } else if (added.isNotEmpty) {
      assistantText = 'Added ${added.length} todo items.';
    } else {
      assistantText = 'Todo list updated.';
    }
  } else if (items.isEmpty) {
    assistantText = 'Your todo list is empty.';
  } else {
    assistantText = 'Here is your todo list.';
  }

  final payload = <String, dynamic>{
    'title': 'Todo List',
    'items': items.map((item) => item.text).toList(),
  };
  if (status != null && status.isNotEmpty) {
    payload['status'] = status;
  }

  final buffer = StringBuffer();
  if (assistantText.isNotEmpty) {
    buffer.writeln(assistantText);
    buffer.writeln();
  }
  buffer.write('<todo_list>\n${jsonEncode(payload)}\n</todo_list>');
  return buffer.toString();
}
