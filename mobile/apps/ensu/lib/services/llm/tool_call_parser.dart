import 'dart:convert';

/// Represents a single tool call emitted by the model.
class LlmToolCall {
  final String name;
  final Map<String, dynamic> arguments;

  const LlmToolCall({required this.name, required this.arguments});
}

/// Parse OpenAI-style tool calls from a model response.
///
/// Supports:
/// - Full OpenAI response JSON with `choices[].message.tool_calls`
/// - Direct tool-call payload objects
/// - Noisy wrappers (code fences, model tokens)
///
/// If parsing fails, it can optionally fall back to a best-effort regex-based
/// extraction for known tool names.
List<LlmToolCall> parseLlmToolCalls(
  String responseText, {
  Set<String>? allowedToolNames,
  Map<String, String> fallbackKeyMap = const {},
}) {
  final normalized = _normalizeJsonText(responseText);
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
    if (allowedToolNames == null || allowedToolNames.isEmpty) {
      return const [];
    }
    return _fallbackCallsFromText(
      normalized,
      allowedToolNames: allowedToolNames,
      fallbackKeyMap: fallbackKeyMap,
    );
  }

  final toolCalls = _extractToolCalls(payload);
  if (toolCalls.isEmpty) {
    if (allowedToolNames == null || allowedToolNames.isEmpty) {
      return const [];
    }
    return _fallbackCallsFromText(
      normalized,
      allowedToolNames: allowedToolNames,
      fallbackKeyMap: fallbackKeyMap,
    );
  }

  final results = <LlmToolCall>[];
  for (final call in toolCalls) {
    if (call is! Map) {
      continue;
    }
    final function = call['function'] is Map ? call['function'] as Map : call;
    final name = function['name']?.toString() ?? call['name']?.toString();
    if (name == null || name.isEmpty) {
      continue;
    }
    if (allowedToolNames != null && !allowedToolNames.contains(name)) {
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

    results.add(LlmToolCall(name: name, arguments: arguments));
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

List<LlmToolCall> _fallbackCallsFromText(
  String text, {
  required Set<String> allowedToolNames,
  required Map<String, String> fallbackKeyMap,
}) {
  final lower = text.toLowerCase();

  String? selectedName;
  var selectedIndex = -1;

  for (final toolName in allowedToolNames) {
    final idx = lower.indexOf(toolName.toLowerCase());
    if (idx == -1) {
      continue;
    }
    if (selectedName == null || idx < selectedIndex) {
      selectedName = toolName;
      selectedIndex = idx;
    }
  }

  if (selectedName == null) {
    return const [];
  }

  final arguments = <String, dynamic>{};

  for (final entry in fallbackKeyMap.entries) {
    final rawKey = entry.key;
    final canonicalKey = entry.value;

    final stringMatch = RegExp(
      '"$rawKey"\\s*:\\s*"([^"]+)"',
      caseSensitive: false,
    ).firstMatch(text);
    if (stringMatch != null) {
      arguments[canonicalKey] = stringMatch.group(1)!.trim();
      continue;
    }

    final numMatch = RegExp(
      '"$rawKey"\\s*:\\s*(\\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (numMatch != null) {
      arguments[canonicalKey] = int.tryParse(numMatch.group(1)!) ?? numMatch.group(1);
      continue;
    }

    final boolMatch = RegExp(
      '"$rawKey"\\s*:\\s*(true|false)',
      caseSensitive: false,
    ).firstMatch(text);
    if (boolMatch != null) {
      arguments[canonicalKey] = boolMatch.group(1)!.toLowerCase() == 'true';
    }
  }

  return [LlmToolCall(name: selectedName, arguments: arguments)];
}
