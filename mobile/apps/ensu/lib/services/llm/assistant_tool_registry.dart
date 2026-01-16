import 'package:ensu/services/llm/assistant_tool_feature.dart';
import 'package:ensu/services/llm/memory_tooling.dart';
import 'package:ensu/services/llm/todo_tool_feature.dart';

/// Plug-and-play registry.
///
/// Add/remove tool features here to enable/disable them.
final List<AssistantToolFeature> assistantToolFeatures = [
  TodoAssistantToolFeature(),
  MemoryAssistantToolFeature(),
];
