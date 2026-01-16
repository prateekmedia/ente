import 'package:ensu/services/chat_dag.dart';
import 'package:ensu/store/chat_db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orders messages parent-first and blocks pending branches', () {
    final messages = [
      LocalMessage(
        messageUuid: 'm1',
        sessionUuid: 's1',
        sender: 'self',
        text: 'root',
        createdAt: 1000,
      ),
      LocalMessage(
        messageUuid: 'm2',
        sessionUuid: 's1',
        parentMessageUuid: 'm1',
        sender: 'self',
        text: 'blocked',
        createdAt: 2000,
      ),
      LocalMessage(
        messageUuid: 'm3',
        sessionUuid: 's1',
        parentMessageUuid: 'm2',
        sender: 'self',
        text: 'child',
        createdAt: 3000,
      ),
      LocalMessage(
        messageUuid: 'm4',
        sessionUuid: 's1',
        parentMessageUuid: 'm1',
        sender: 'self',
        text: 'unblocked',
        createdAt: 2500,
      ),
    ];

    final ordered = ChatDag.orderForSync(messages, {'m2'});

    expect(ordered.map((m) => m.messageUuid).toList(), ['m1', 'm4']);
  });
}
