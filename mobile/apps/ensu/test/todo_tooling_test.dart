import 'dart:convert';

import 'package:ensu/services/llm/todo_tooling.dart';
import 'package:ensu/services/todo_session_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseTodoToolCalls extracts tool calls', () {
    const responseJson = '{"choices":[{"message":{"tool_calls":[{"function":{"name":"todo_add","arguments":"{\\"text\\":\\"Buy milk\\"}"}}]}}]}';

    final calls = parseTodoToolCalls(responseJson);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'todo_add');
    expect(calls.first.arguments['text'], 'Buy milk');
  });

  test('parseTodoToolCalls handles raw tool payload', () {
    const responseJson = '{"type":"function","function":{"name":"todo_add","arguments":{"text":"Pay rent"}}}';

    final calls = parseTodoToolCalls(responseJson);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'todo_add');
    expect(calls.first.arguments['text'], 'Pay rent');
  });

  test('parseTodoToolCalls handles noisy tool payload', () {
    const responseJson =
        '<eot_id|><|start_header_id|>assistant<|end_header_id|>\n'
        '{"type": "function", "function": \u00bf "name": "todo_add", "parameters": {"text": "eat food" }}';

    final calls = parseTodoToolCalls(responseJson);

    expect(calls, hasLength(1));
    expect(calls.first.name, 'todo_add');
    expect(calls.first.arguments['text'], 'eat food');
  });

  test('extractTodoText handles alternate keys', () {
    expect(extractTodoText({'task': 'Walk dog'}), 'Walk dog');
    expect(extractTodoText({'todo': 'Call mom'}), 'Call mom');
    expect(extractTodoText({'item': {'text': 'Buy eggs'}}), 'Buy eggs');
  });

  test('todo executor add/list/clear flow', () {
    final executor = TodoToolExecutor();
    const sessionId = 'todo-test-session';
    TodoSessionStore.instance.clear(sessionId);

    final addResult = executor.execute(
      TodoToolCall(
        name: 'todo_add',
        arguments: {'text': 'Buy milk'},
      ),
      sessionId,
    );

    expect(addResult.items, hasLength(1));
    expect(addResult.items.first.text, 'Buy milk');

    final listResult = executor.execute(
      TodoToolCall(name: 'todo_list', arguments: {}),
      sessionId,
    );

    expect(listResult.items, hasLength(1));

    final clearResult = executor.execute(
      TodoToolCall(name: 'todo_clear', arguments: {}),
      sessionId,
    );

    expect(clearResult.items, isEmpty);
  });

  test('buildTodoAssistantResponse encodes todo list payload', () {
    final response = buildTodoAssistantResponse([
      TodoToolResult(
        action: TodoToolAction.list,
        items: [
          const TodoItem(id: '1', text: 'Plan trip', createdAt: 0),
        ],
      ),
    ]);

    expect(response, contains('<todo_list>'));
    expect(response, contains('</todo_list>'));

    final start = response.indexOf('<todo_list>');
    final end = response.indexOf('</todo_list>');
    final jsonText = response
        .substring(start + '<todo_list>'.length, end)
        .trim();
    final payload = jsonDecode(jsonText) as Map<String, dynamic>;
    expect(payload['items'], ['Plan trip']);
  });
}
