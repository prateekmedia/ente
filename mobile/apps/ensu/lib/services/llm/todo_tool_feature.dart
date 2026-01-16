import 'dart:convert';

import 'package:ensu/services/llm/assistant_tool_feature.dart';
import 'package:ensu/services/llm/tool_call_parser.dart';
import 'package:ensu/services/llm/todo_tooling.dart';
import 'package:fllama/fllama.dart';

class TodoAssistantToolFeature implements AssistantToolFeature {
  static final RegExp _triggerPattern = RegExp(
    r'\b(todo|to-do|to do|task list|todos)\b',
    caseSensitive: false,
  );

  @override
  String get id => 'todo';

  @override
  bool shouldTrigger(String prompt) => _triggerPattern.hasMatch(prompt);

  @override
  List<Tool> get tools => todoTools;

  @override
  Set<String> get toolNames => const {'todo_add', 'todo_list', 'todo_clear'};

  @override
  Map<String, String> get fallbackKeyMap => const {
        'text': 'text',
        'task': 'text',
        'todo': 'text',
        'item': 'text',
        'title': 'text',
        'description': 'text',
        'value': 'text',
      };

  @override
  Future<AssistantToolExecutionResult> handleToolCall(
    LlmToolCall call,
    String sessionId,
    String originalPrompt,
  ) async {
    var resolved = call;
    if (call.name == 'todo_add') {
      final existingText = extractTodoText(call.arguments);
      if (existingText.isEmpty) {
        final inferred = _inferTodoTextFromPrompt(originalPrompt);
        if (inferred != null && inferred.isNotEmpty) {
          final updatedArgs = Map<String, dynamic>.from(call.arguments);
          updatedArgs['text'] = inferred;
          resolved = LlmToolCall(name: call.name, arguments: updatedArgs);
        }
      }
    }

    final executor = TodoToolExecutor();
    final result = executor.execute(
      TodoToolCall(name: resolved.name, arguments: resolved.arguments),
      sessionId,
    );

    final payload = <String, dynamic>{
      'title': 'Todo List',
      'items': result.items.map((item) => item.text).toList(),
      'action': result.action.name,
      if (result.addedText != null) 'addedText': result.addedText,
    };

    if (result.hasError) {
      payload['status'] = result.error;
    }

    final toolContent = '<todo_list>\n${jsonEncode(payload)}\n</todo_list>';
    return AssistantToolToolResponse(toolContent);
  }

  String? _inferTodoTextFromPrompt(String prompt) {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final patterns = [
      RegExp(
        r'\badd\s+(.+?)\s+to\s+(?:my\s+)?to-?do\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\badd\s+to-?do\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'\badd\s+todo\s+(.+)$',
        caseSensitive: false,
      ),
      RegExp(
        r'\badd\s+(.+?)\s+to\s+(?:my\s+)?list\b',
        caseSensitive: false,
      ),
      RegExp(
        r'\bput\s+(.+?)\s+on\s+(?:my\s+)?to-?do\b',
        caseSensitive: false,
      ),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(prompt);
      if (match == null) {
        continue;
      }
      final candidate = match.group(1);
      if (candidate == null) {
        continue;
      }
      final cleaned = _cleanTodoCandidate(candidate);
      if (cleaned != null) {
        return cleaned;
      }
    }

    return null;
  }

  String? _cleanTodoCandidate(String candidate) {
    var cleaned = candidate.trim();
    cleaned = cleaned.replaceAll(RegExp(r'[\s\.,;:!?]+$'), '');
    if (cleaned.isEmpty) {
      return null;
    }
    final lower = cleaned.toLowerCase();
    const invalid = {
      'todo',
      'to do',
      'to-do',
      'my todo',
      'my to do',
      'my to-do',
      'todo list',
      'to do list',
      'to-do list',
      'my todo list',
      'my to do list',
      'my to-do list',
    };
    if (invalid.contains(lower)) {
      return null;
    }
    return cleaned;
  }
}
