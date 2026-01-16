import 'package:ensu/services/chat_conflict_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

ChatConflictMessage _msg(
  String id,
  String? parentId,
  int createdAt, {
  String sender = 'self',
  String text = 'text',
}) {
  return ChatConflictMessage(
    messageUuid: id,
    parentMessageUuid: parentId,
    sender: sender,
    text: text,
    createdAt: createdAt,
  );
}

void main() {
  test('fast-forward appends remote chain in order', () {
    final local = [
      _msg('m1', null, 1000, text: 'root'),
      _msg('m2', 'm1', 2000, text: 'local'),
    ];
    final remote = [
      _msg('m3', 'm2', 3000, sender: 'other', text: 'remote1'),
      _msg('m4', 'm3', 4000, sender: 'other', text: 'remote2'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.fastForward);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['m3', 'm4']);
    expect(result.messagesToBranch, isEmpty);
  });

  test('branches when heads diverge', () {
    final local = [
      _msg('m1', null, 1000, text: 'root'),
      _msg('m2', 'm1', 2000, text: 'common'),
      _msg('m3', 'm2', 3000, sender: 'self', text: 'local'),
    ];
    final remote = [
      _msg('m4', 'm2', 3100, sender: 'other', text: 'remote'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.branch);
    expect(result.branchFromMessageUuid, 'm2');
    expect(result.messagesToBranch.map((m) => m.messageUuid), ['m3']);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['m4']);
  });

  test('suppresses duplicate remote children', () {
    final local = [
      _msg('m1', null, 1000, text: 'root'),
      _msg('m2', 'm1', 2000, text: 'parent'),
      _msg('m3', 'm2', 3000, sender: 'other', text: 'dup'),
    ];
    final remote = [
      _msg('m4', 'm2', 3001, sender: 'other', text: 'dup'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.noChange);
    expect(result.messagesToAppend, isEmpty);
    expect(result.messagesToBranch, isEmpty);
  });

  test('no change when remote head is ancestor of local', () {
    final local = [
      _msg('m3', 'm2', 3000, text: 'leaf'),
    ];
    final remote = [
      _msg('m1', null, 1000, sender: 'other', text: 'root'),
      _msg('m2', 'm1', 2000, sender: 'other', text: 'mid'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.noChange);
    expect(result.messagesToAppend, isEmpty);
    expect(result.messagesToBranch, isEmpty);
  });

  test('branches with fallback when ancestor is missing', () {
    final local = [
      _msg('m1', null, 1000, text: 'local-root'),
      _msg('m2', 'm1', 2000, text: 'local-child'),
    ];
    final remote = [
      _msg('m3', 'm9', 1500, sender: 'other', text: 'remote-only'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.branch);
    expect(result.branchFromMessageUuid, isNull);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['m3']);
    expect(result.messagesToBranch.map((m) => m.messageUuid), ['m1', 'm2']);
  });

  test('no change when both sides empty', () {
    final result = ChatConflictResolver.resolve(
      localMessages: const [],
      remoteMessages: const [],
    );

    expect(result.type, ChatConflictResolutionType.noChange);
    expect(result.messagesToAppend, isEmpty);
    expect(result.messagesToBranch, isEmpty);
  });

  test('no change when remote is empty', () {
    final local = [
      _msg('m1', null, 1000, text: 'local'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: const [],
    );

    expect(result.type, ChatConflictResolutionType.noChange);
    expect(result.messagesToAppend, isEmpty);
    expect(result.messagesToBranch, isEmpty);
  });

  test('fast-forward when local is empty', () {
    final remote = [
      _msg('m2', null, 2000, sender: 'other', text: 'later'),
      _msg('m1', null, 1000, sender: 'other', text: 'earlier'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: const [],
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.fastForward);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['m1', 'm2']);
    expect(result.messagesToBranch, isEmpty);
  });

  test('filters remote duplicates by UUID', () {
    final local = [
      _msg('m1', null, 1000, text: 'root'),
      _msg('m2', 'm1', 2000, text: 'local'),
    ];
    final remote = [
      _msg('m2', 'm1', 4000, sender: 'other', text: 'dup-uuid'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.noChange);
    expect(result.messagesToAppend, isEmpty);
    expect(result.messagesToBranch, isEmpty);
  });

  test('orders same-timestamp remote messages by uuid', () {
    final remote = [
      _msg('b', null, 1000, sender: 'other', text: 'second'),
      _msg('a', null, 1000, sender: 'other', text: 'first'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: const [],
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.fastForward);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['a', 'b']);
  });

  test('branches when local has multiple heads', () {
    final local = [
      _msg('m1', null, 1000, text: 'root'),
      _msg('m2', 'm1', 2000, text: 'older-head'),
      _msg('m3', 'm1', 3000, text: 'newer-head'),
    ];
    final remote = [
      _msg('m4', 'm2', 2500, sender: 'other', text: 'remote'),
    ];

    final result = ChatConflictResolver.resolve(
      localMessages: local,
      remoteMessages: remote,
    );

    expect(result.type, ChatConflictResolutionType.branch);
    expect(result.branchFromMessageUuid, 'm1');
    expect(result.messagesToBranch.map((m) => m.messageUuid), ['m3']);
    expect(result.messagesToAppend.map((m) => m.messageUuid), ['m4']);
  });
}
