import 'dart:convert';

import 'package:ensu/services/llm/assistant_tool_feature.dart';
import 'package:ensu/services/llm/tool_call_parser.dart';
import 'package:ensu/store/chat_db.dart';
import 'package:fllama/fllama.dart';

final List<Tool> memoryTools = [
  Tool(
    name: 'memory_search',
    description:
        'Search through past chat messages to recall what the user said earlier. '
        'Parameters: {"query": "...", "scope": "current_root"|"current_session"|"all_sessions", '
        '"limit": 1-10, "contextChars": 40-400}.',
    jsonSchema: _memorySearchSchema,
  ),
];

const String _memorySearchSchema = '{'
    '"type":"object",'
    '"properties":{'
    '"query":{"type":"string","description":"Keyword(s) to search for"},'
    '"scope":{"type":"string","enum":["current_root","current_session","all_sessions"],'
    '"description":"Where to search"},'
    '"limit":{"type":"integer","minimum":1,"maximum":10,'
    '"description":"Maximum number of results"},'
    '"contextChars":{"type":"integer","minimum":40,"maximum":400,'
    '"description":"Context characters around the match"}'
    '},'
    '"required":["query"],'
    '"additionalProperties":false'
    '}';

class MemoryAssistantToolFeature implements AssistantToolFeature {
  static final RegExp _triggerPattern = RegExp(
    r'\b(what\s+is\s+my\b|who\s+am\s+i\b|my\s+name\b|my\s+email\b|my\s+phone\b|remind\s+me\b|did\s+i\b|as\s+i\s+said\b|earlier\b|previous(ly)?\b|last\s+time\b|remember\b|search\s+memory\b|in\s+our\s+chat\b|in\s+this\s+chat\b)\b',
    caseSensitive: false,
  );

  @override
  String get id => 'memory';

  @override
  bool shouldTrigger(String prompt) => _triggerPattern.hasMatch(prompt);

  @override
  List<Tool> get tools => memoryTools;

  @override
  Set<String> get toolNames => const {'memory_search'};

  @override
  Map<String, String> get fallbackKeyMap => const {
        'query': 'query',
        'pattern': 'query',
        'q': 'query',
        'text': 'query',
        'term': 'query',
        'scope': 'scope',
        'limit': 'limit',
        'contextChars': 'contextChars',
        'context_chars': 'contextChars',
      };

  @override
  Future<AssistantToolExecutionResult> handleToolCall(
    LlmToolCall call,
    String sessionId,
    String originalPrompt,
  ) async {
    final query = _extractQuery(call.arguments, originalPrompt);
    if (query.isEmpty) {
      return const AssistantToolToolResponse(
        '<memory_results>\n{"error":"missing query"}\n</memory_results>',
      );
    }

    final scope = (call.arguments['scope']?.toString() ?? '').trim();
    final limit = _clampInt(call.arguments['limit'], fallback: 6, min: 1, max: 10);
    final contextChars =
        _clampInt(call.arguments['contextChars'], fallback: 180, min: 40, max: 400);

    await ChatDB.instance.waitForSearchIndexBackfill();

    final resolvedScope = _normalizeScope(scope);
    String? rootSessionUuid;
    String? withinSessionUuid;

    if (resolvedScope == _MemoryScope.currentSession) {
      withinSessionUuid = sessionId;
    } else if (resolvedScope == _MemoryScope.currentRoot) {
      final session = await ChatDB.instance.getSession(sessionId);
      rootSessionUuid = session?.rootSessionUuid ?? sessionId;
    }

    final results = await ChatDB.instance.searchMessages(
      query,
      rootSessionUuid: rootSessionUuid,
      withinSessionUuid: withinSessionUuid,
      limit: limit,
      contextChars: contextChars,
    );

    final payload = <String, dynamic>{
      'query': query,
      'scope': _scopeLabel(resolvedScope),
      'totalReturned': results.length,
      'results': results.map((hit) => hit.toJson()).toList(),
    };

    final context = '<memory_results>\n${jsonEncode(payload)}\n</memory_results>';
    return AssistantToolToolResponse(context);
  }

  String _extractQuery(Map<String, dynamic> args, String originalPrompt) {
    final raw = args['query'] ?? args['pattern'] ?? args['q'] ?? args['text'];
    if (raw is String) {
      final trimmed = raw.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }

    final lowered = originalPrompt.toLowerCase();
    if (lowered.contains('what is my name') || lowered.contains('my name')) {
      return 'my name is';
    }
    if (lowered.contains('what is my email') || lowered.contains('my email')) {
      return 'my email';
    }
    if (lowered.contains('what is my phone') || lowered.contains('my phone')) {
      return 'my phone';
    }

    return originalPrompt.trim();
  }
}

enum _MemoryScope { currentRoot, currentSession, allSessions }

_MemoryScope _normalizeScope(String raw) {
  switch (raw) {
    case 'current_session':
      return _MemoryScope.currentSession;
    case 'current_root':
      return _MemoryScope.currentRoot;
    case 'all_sessions':
      return _MemoryScope.allSessions;
    default:
      return _MemoryScope.allSessions;
  }
}

String _scopeLabel(_MemoryScope scope) {
  switch (scope) {
    case _MemoryScope.currentSession:
      return 'current_session';
    case _MemoryScope.currentRoot:
      return 'current_root';
    case _MemoryScope.allSessions:
      return 'all_sessions';
  }
}

int _clampInt(
  dynamic value, {
  required int fallback,
  required int min,
  required int max,
}) {
  int? parsed;
  if (value is int) {
    parsed = value;
  } else if (value is String) {
    parsed = int.tryParse(value.trim());
  }

  final resolved = parsed ?? fallback;
  if (resolved < min) return min;
  if (resolved > max) return max;
  return resolved;
}
