import 'package:ensu/services/llm/tool_call_parser.dart';
import 'package:fllama/fllama.dart';

sealed class AssistantToolExecutionResult {
  const AssistantToolExecutionResult();
}

/// Stop the agentic loop and return this directly to the user.
class AssistantToolFinalResponse extends AssistantToolExecutionResult {
  final String text;

  const AssistantToolFinalResponse(this.text);
}

/// Continue the agentic loop by feeding this back to the model as a tool message.
class AssistantToolToolResponse extends AssistantToolExecutionResult {
  final String content;

  const AssistantToolToolResponse(this.content);
}

abstract class AssistantToolFeature {
  String get id;

  /// Cheap heuristic to avoid starting a tool-loop for every prompt.
  bool shouldTrigger(String prompt);

  List<Tool> get tools;

  /// Tool names handled by this feature.
  Set<String> get toolNames;

  /// Best-effort fallback extraction map (rawKey -> canonicalKey).
  Map<String, String> get fallbackKeyMap;

  Future<AssistantToolExecutionResult> handleToolCall(
    LlmToolCall call,
    String sessionId,
    String originalPrompt,
  );
}
