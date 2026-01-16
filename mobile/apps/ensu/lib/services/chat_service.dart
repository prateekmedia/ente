import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/gateway/chat_gateway.dart';
import 'package:ensu/models/chat_attachment.dart';
import 'package:ensu/models/chat_entity.dart';
import 'package:ensu/services/chat_attachment_store.dart';
import 'package:ensu/services/chat_conflict_resolver.dart';
import 'package:ensu/services/chat_dag.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:ente_crypto_cross_check_adapter/ente_crypto_cross_check_adapter.dart'
    show CryptoCrossCheckException;
import 'package:ensu/store/chat_db.dart';
import 'package:event_bus/event_bus.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Global event bus for the app.
final eventBus = EventBus();

/// Event fired when chat data is updated.
class ChatsUpdatedEvent {}

/// Event fired when logout is triggered.
class TriggerLogoutEvent {}

/// Represents a chat session with its messages for UI.
class ChatSession {
  final String sessionUuid;
  final String title;
  final int createdAt;
  final int updatedAt;
  final String rootSessionUuid;
  final String? branchFromMessageUuid;
  final List<ChatMessage> messages;
  final String? lastMessagePreview;

  ChatSession({
    required this.sessionUuid,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.rootSessionUuid,
    this.branchFromMessageUuid,
    required this.messages,
    this.lastMessagePreview,
  });
}

/// Represents a single chat message.
class ChatMessage {
  final String messageUuid;
  final String sessionUuid;
  final String? parentMessageUuid;
  final bool isSelf;
  final String text;
  final List<ChatAttachment> attachments;
  final int createdAt;
  final double? tokensPerSecond; // Performance metric for AI messages

  ChatMessage({
    required this.messageUuid,
    required this.sessionUuid,
    this.parentMessageUuid,
    required this.isSelf,
    required this.text,
    this.attachments = const [],
    required this.createdAt,
    this.tokensPerSecond,
  });
}

class _RemoteSession {
  final String sessionUuid;
  final String rootSessionUuid;
  final String? branchFromMessageUuid;
  final String title;
  final int createdAt;
  final int updatedAt;

  const _RemoteSession({
    required this.sessionUuid,
    required this.rootSessionUuid,
    this.branchFromMessageUuid,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });
}

class _RemoteMessage {
  final String messageUuid;
  final String sessionUuid;
  final String? parentMessageUuid;
  final String sender;
  final String text;
  final List<ChatAttachment> attachments;
  final int createdAt;

  const _RemoteMessage({
    required this.messageUuid,
    required this.sessionUuid,
    this.parentMessageUuid,
    required this.sender,
    required this.text,
    this.attachments = const [],
    required this.createdAt,
  });

  ChatConflictMessage toConflict() {
    return ChatConflictMessage(
      messageUuid: messageUuid,
      parentMessageUuid: parentMessageUuid,
      sender: sender,
      text: text,
      attachments: attachments,
      createdAt: createdAt,
    );
  }
}

/// Service for managing chat sessions and messages.
/// Local-first: works offline, syncs when logged in.
class ChatService {
  final _logger = Logger('ChatService');
  final _config = Configuration.instance;
  late SharedPreferences _prefs;
  late ChatGateway _gateway;
  late ChatDB _db;
  final String _lastSyncTimeKey = "lastChatSyncTimeUs";
  final String _searchIndexBackfillKey = "chatSearchIndexBackfillV1";
  final Map<String, double> _tokensPerSecondByMessageUuid = {};
  bool _isSyncing = false;
  bool _attachmentsApiUnavailable = false;

  ChatService._privateConstructor();
  static final ChatService instance = ChatService._privateConstructor();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _db = ChatDB.instance;
    _gateway = ChatGateway();

    final searchBackfillDone =
        _prefs.getBool(_searchIndexBackfillKey) ?? false;
    if (!searchBackfillDone) {
      unawaited(
        _db
            .startSearchIndexBackfill()
            .then((_) => _prefs.setBool(_searchIndexBackfillKey, true)),
      );
    }

    // Background sync if logged in
    if (_config.hasConfiguredAccount()) {
      unawaited(_backgroundSync());
    }
  }

  void updateEndpoint(String endpoint) {
    _gateway.updateEndpoint(endpoint);
  }

  /// Get all chat sessions with messages.
  Future<List<ChatSession>> getAllSessions() async {
    final sessions = await _db.getAllSessions();
    if (sessions.isEmpty) return [];

    final sessionsByRoot = <String, List<LocalSession>>{};
    for (final session in sessions) {
      sessionsByRoot
          .putIfAbsent(session.rootSessionUuid, () => [])
          .add(session);
    }

    final result = <ChatSession>[];
    for (final entry in sessionsByRoot.entries) {
      result.add(await _buildMergedSession(entry.key, entry.value));
    }

    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<Map<String, String>> getBranchSelections(
    String rootSessionUuid,
  ) async {
    return _db.getBranchSelections(rootSessionUuid);
  }

  Future<Map<String, Map<String, String>>> getBranchSelectionsForRoots(
    List<String> rootSessionUuids,
  ) async {
    return _db.getBranchSelectionsForRoots(rootSessionUuids);
  }

  Future<void> setBranchSelection(
    String rootSessionUuid,
    String selectionKey,
    String selectedMessageUuid,
  ) async {
    await _db.upsertBranchSelection(
      rootSessionUuid,
      selectionKey,
      selectedMessageUuid,
    );
  }

  Future<ChatSession> _buildMergedSession(
    String rootSessionUuid,
    List<LocalSession> sessions,
  ) async {
    final rootSession = sessions.firstWhere(
      (session) => session.sessionUuid == rootSessionUuid,
      orElse: () => sessions.first,
    );

    final messageById = <String, LocalMessage>{};
    for (final session in sessions) {
      final messages = await _db.getMessages(session.sessionUuid);
      for (final message in messages) {
        messageById[message.messageUuid] = message;
      }
    }

    final mergedMessages = messageById.values.toList()
      ..sort((a, b) {
        final timeCompare = a.createdAt.compareTo(b.createdAt);
        if (timeCompare != 0) return timeCompare;
        return a.messageUuid.compareTo(b.messageUuid);
      });

    LocalMessage? lastMsg;
    for (final message in mergedMessages) {
      if (lastMsg == null ||
          message.createdAt > lastMsg.createdAt ||
          (message.createdAt == lastMsg.createdAt &&
              message.messageUuid.compareTo(lastMsg.messageUuid) > 0)) {
        lastMsg = message;
      }
    }

    final latestUpdatedAt =
        sessions.map((session) => session.updatedAt).reduce(max);
    final earliestCreatedAt =
        sessions.map((session) => session.createdAt).reduce(min);
    final latestMessageAt = lastMsg?.createdAt;
    final resolvedUpdatedAt = latestMessageAt == null
        ? latestUpdatedAt
        : max(latestUpdatedAt, latestMessageAt);

    return ChatSession(
      sessionUuid: rootSessionUuid,
      title: rootSession.title,
      createdAt: earliestCreatedAt,
      updatedAt: resolvedUpdatedAt,
      rootSessionUuid: rootSessionUuid,
      branchFromMessageUuid: rootSession.branchFromMessageUuid,
      messages: mergedMessages
          .map((m) => ChatMessage(
                messageUuid: m.messageUuid,
                sessionUuid: m.sessionUuid,
                parentMessageUuid: m.parentMessageUuid,
                isSelf: m.sender == 'self',
                text: m.text,
                attachments: m.attachments,
                createdAt: m.createdAt,
                tokensPerSecond: _tokensPerSecondByMessageUuid[m.messageUuid],
              ))
          .toList(),
      lastMessagePreview: lastMsg != null
          ? (lastMsg.text.length > 50
              ? '${lastMsg.text.substring(0, 47)}...'
              : lastMsg.text)
          : null,
    );
  }

  /// Get a single session with messages.
  Future<ChatSession?> getSession(String sessionUuid) async {
    final session = await _db.getSession(sessionUuid);
    if (session == null) return null;

    final messages = await _db.getMessages(sessionUuid);
    final lastMsg = messages.isNotEmpty ? messages.last : null;

    return ChatSession(
      sessionUuid: session.sessionUuid,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      rootSessionUuid: session.rootSessionUuid,
      branchFromMessageUuid: session.branchFromMessageUuid,
      messages: messages
          .map((m) => ChatMessage(
                messageUuid: m.messageUuid,
                sessionUuid: m.sessionUuid,
                parentMessageUuid: m.parentMessageUuid,
                isSelf: m.sender == 'self',
                text: m.text,
                attachments: m.attachments,
                createdAt: m.createdAt,
                tokensPerSecond: _tokensPerSecondByMessageUuid[m.messageUuid],
              ))
          .toList(),
      lastMessagePreview: lastMsg != null
          ? (lastMsg.text.length > 50
              ? '${lastMsg.text.substring(0, 47)}...'
              : lastMsg.text)
          : null,
    );
  }

  /// Create a new chat session.
  Future<String> createSession(String title) async {
    final sessionUuid = await _db.insertSession(title);
    _logger.fine("Created session");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
    return sessionUuid;
  }

  /// Send a message in a session.
  Future<String> sendMessage(
    String sessionUuid,
    String text, {
    String? parentMessageUuid,
    bool useSessionHeadWhenParentNull = true,
    List<ChatAttachment> attachments = const [],
  }) async {
    final messageUuid = await _db.insertMessage(
      sessionUuid,
      'self',
      text,
      parentMessageUuid: parentMessageUuid,
      useSessionHeadWhenParentNull: useSessionHeadWhenParentNull,
      attachments: attachments,
    );
    _logger.fine("Sent message");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
    return messageUuid;
  }

  /// Add an AI response message to a session.
  Future<String> addAIMessage(
    String sessionUuid,
    String text, {
    double? tokensPerSecond,
    String? parentMessageUuid,
    bool useSessionHeadWhenParentNull = true,
    List<ChatAttachment> attachments = const [],
  }) async {
    final messageUuid = await _db.insertMessage(
      sessionUuid,
      'other',
      text,
      parentMessageUuid: parentMessageUuid,
      useSessionHeadWhenParentNull: useSessionHeadWhenParentNull,
      attachments: attachments,
    );
    if (tokensPerSecond != null) {
      _tokensPerSecondByMessageUuid[messageUuid] = tokensPerSecond;
    }
    _logger.fine(
        "Added AI message (${tokensPerSecond?.toStringAsFixed(2)} tokens/sec)");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
    return messageUuid;
  }

  Future<void> updateMessageText(String messageUuid, String text) async {
    await _db.updateMessageText(messageUuid, text);
    _logger.fine("Updated message text");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  Future<void> _queueDeletion(String entityType, String entityId) async {
    await _db.enqueueDeletion(entityType, entityId);
    if (!_config.hasConfiguredAccount()) {
      return;
    }
    try {
      final deleted = await _deleteRemoteEntity(
        entityType,
        entityId,
        propagateUnauthorized: false,
      );
      if (deleted) {
        await _db.removePendingDeletion(entityType, entityId);
      }
    } catch (e, s) {
      _logger.warning(
        'Failed to delete $entityType ($entityId) during background sync',
        e,
        s,
      );
    }
  }

  Future<void> deleteMessage(String sessionUuid, String messageUuid) async {
    final session = await _db.getSession(sessionUuid);
    if (session?.remoteId != null) {
      await _queueDeletion(ChatDB.deletionTypeMessage, messageUuid);
    }

    await _db.deleteMessage(messageUuid);
    _tokensPerSecondByMessageUuid.remove(messageUuid);
    await _db.markSessionForSync(sessionUuid);
    _logger.fine("Deleted message");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  Future<bool> downloadAttachment(String attachmentId) async {
    final downloaded = await downloadAttachments([attachmentId]);
    return downloaded > 0;
  }

  Future<int> downloadAttachments(List<String> attachmentIds) async {
    if (_attachmentsApiUnavailable || !_config.hasConfiguredAccount()) {
      return 0;
    }

    final uniqueIds = attachmentIds.where((id) => id.isNotEmpty).toSet();
    if (uniqueIds.isEmpty) {
      return 0;
    }

    var downloadedCount = 0;

    for (final attachmentId in uniqueIds) {
      try {
        final alreadyPresent =
            await ChatAttachmentStore.instance.hasAttachment(attachmentId);
        if (alreadyPresent) {
          continue;
        }

        final encryptedBytes = await _gateway.downloadAttachment(attachmentId);
        await ChatAttachmentStore.instance.storeEncryptedAttachmentBytes(
          attachmentId,
          encryptedBytes,
        );
        downloadedCount += 1;
      } on UnauthorizedError {
        await _handleUnauthorized('attachment download');
        return downloadedCount;
      } catch (e, s) {
        if (_isNotFoundError(e)) {
          _logger.fine('Attachment not found on server: $attachmentId');
          continue;
        }
        _logger.warning('Attachment download failed: $attachmentId', e, s);
      }
    }

    return downloadedCount;
  }

  /// Update the last AI message (for streaming).
  Future<void> updateLastAIMessage(String sessionUuid, String text) async {
    final messages = await _db.getMessages(sessionUuid);
    if (messages.isNotEmpty && messages.last.sender == 'other') {
      // Delete the last message and re-insert with new text
      // (Simple approach - could optimize with UPDATE)
      await _db.deleteMessage(messages.last.messageUuid);
      _tokensPerSecondByMessageUuid.remove(messages.last.messageUuid);
    }
    await _db.insertMessage(sessionUuid, 'other', text);
    eventBus.fire(ChatsUpdatedEvent());
  }

  /// Delete the last AI message from a session.
  /// Returns the user message that prompted this AI response (for retry).
  Future<String?> deleteLastAIMessage(String sessionUuid) async {
    final messages = await _db.getMessages(sessionUuid);
    if (messages.isEmpty) return null;

    // Find the last AI message
    int lastAIMessageIndex = -1;
    for (int i = messages.length - 1; i >= 0; i--) {
      if (messages[i].sender == 'other') {
        lastAIMessageIndex = i;
        break;
      }
    }

    if (lastAIMessageIndex == -1) return null;

    final lastAIMessage = messages[lastAIMessageIndex];

    // Find the user message that immediately precedes this AI message
    // (the message that triggered the AI response we're retrying)
    String? precedingUserMessage;
    for (int i = lastAIMessageIndex - 1; i >= 0; i--) {
      if (messages[i].sender == 'self') {
        precedingUserMessage = messages[i].text;
        break;
      }
    }

    // Delete the AI message
    final session = await _db.getSession(sessionUuid);
    if (session?.remoteId != null) {
      await _queueDeletion(
        ChatDB.deletionTypeMessage,
        lastAIMessage.messageUuid,
      );
    }
    await _db.deleteMessage(lastAIMessage.messageUuid);
    _tokensPerSecondByMessageUuid.remove(lastAIMessage.messageUuid);
    await _db.markSessionForSync(sessionUuid);
    _logger.fine("Deleted last AI message");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();

    return precedingUserMessage;
  }

  /// Delete a chat session.
  Future<void> deleteSession(String sessionUuid) async {
    final session = await _db.getSession(sessionUuid);
    if (session?.remoteId != null) {
      await _queueDeletion(ChatDB.deletionTypeSession, session!.remoteId!);
    }

    await _db.deleteSession(sessionUuid);
    _logger.fine("Deleted session");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  /// Delete a session tree (root + branches).
  Future<void> deleteSessionTree(String rootSessionUuid) async {
    final sessions = await _db.getSessionsByRoot(rootSessionUuid);
    if (sessions.isEmpty) return;

    for (final session in sessions) {
      if (session.remoteId != null) {
        await _queueDeletion(ChatDB.deletionTypeSession, session.remoteId!);
      }
      await _db.deleteSession(session.sessionUuid);
    }

    _logger.fine("Deleted session tree");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  /// Trigger background sync (non-blocking).
  void _triggerBackgroundSync() {
    if (_config.hasConfiguredAccount()) {
      unawaited(_backgroundSync());
    }
  }

  /// Background sync - pushes local changes to server.
  Future<void> _backgroundSync() async {
    if (_isSyncing) {
      _logger.fine("Background sync skipped: already syncing");
      return;
    }
    if (!_config.hasConfiguredAccount()) {
      _logger.fine("Background sync skipped: no configured account");
      return;
    }

    _isSyncing = true;
    _logger.fine("Starting background sync");

    try {
      await _pushToServer();
      _logger.fine("Background sync completed");
    } catch (e, s) {
      if (e is UnauthorizedError) {
        await _handleUnauthorized("background sync");
        return;
      }
      if (e is CryptoCrossCheckException) {
        _logger.severe(
          "Background sync aborted due to crypto cross-check failure",
          e,
          s,
        );
        rethrow;
      }
      _logger.warning("Background sync failed: ${e.runtimeType} - $e", e, s);
    } finally {
      _isSyncing = false;
    }
  }

  /// Manual sync - pull from server then push.
  ///
  /// Returns `true` only if both pull and push succeed. Manual sync is still
  /// best-effort: if one phase fails, the other is attempted.
  Future<bool> sync() async {
    if (!_config.hasConfiguredAccount()) {
      _logger.fine("Sync skipped: No configured account");
      return false;
    }

    var pullSucceeded = true;
    var pushSucceeded = true;

    try {
      _logger.fine("Starting manual sync");

      // Pull phase
      try {
        await _pullFromServer();
        _logger.fine("Pull from server completed");
      } catch (e, s) {
        pullSucceeded = false;
        if (e is UnauthorizedError) {
          rethrow;
        }
        if (e is CryptoCrossCheckException) {
          _logger.severe(
            "Crypto cross-check failed during pull",
            e,
            s,
          );
          rethrow;
        }
        _logger.warning("Failed to pull from server: $e", e, s);
        // Continue with push even if pull fails.
      }

      // Push phase
      try {
        await _pushToServer();
        _logger.fine("Push to server completed");
      } catch (e, s) {
        pushSucceeded = false;
        if (e is UnauthorizedError) {
          rethrow;
        }
        if (e is CryptoCrossCheckException) {
          _logger.severe(
            "Crypto cross-check failed during push",
            e,
            s,
          );
          rethrow;
        }
        _logger.warning("Failed to push to server: $e", e, s);
      }

      final success = pullSucceeded && pushSucceeded;
      eventBus.fire(ChatsUpdatedEvent());
      _logger.fine(
        success
            ? "Sync completed"
            : "Sync completed with errors (pull=$pullSucceeded push=$pushSucceeded)",
      );
      return success;
    } on UnauthorizedError {
      await _handleUnauthorized("manual sync");
      return false;
    } on CryptoCrossCheckException catch (e, s) {
      _logger.severe(
        "Sync aborted due to crypto cross-check failure",
        e,
        s,
      );
      rethrow;
    } catch (e, s) {
      _logger.severe(
          "Sync failed with unexpected error: ${e.runtimeType} - $e", e, s);
      return false;
    }
  }

  /// Pull changes from server.
  Future<void> _pullFromServer() async {
    final lastSyncTime = _prefs.getInt(_lastSyncTimeKey) ?? 0;
    _logger.fine("Pulling from server (sinceTime: $lastSyncTime)");

    Uint8List key;
    try {
      key = await _getOrCreateChatKey();
    } catch (e, s) {
      _logger.severe("Failed to get/create chat key: $e", e, s);
      rethrow;
    }

    var sinceTime = lastSyncTime;
    const limit = 500;
    var processedCount = 0;
    var errorCount = 0;

    while (true) {
      ChatDiff diff;
      try {
        diff = await _gateway.getDiff(sinceTime, limit: limit);
        _logger.fine(
          "Pulled ${diff.sessions.length} sessions, ${diff.messages.length} messages, "
          "${diff.sessionTombstones.length} session tombstones, "
          "${diff.messageTombstones.length} message tombstones from server",
        );
      } catch (e, s) {
        _logger.severe("Failed to fetch diff from server: $e", e, s);
        rethrow;
      }

      final totalItems = diff.sessions.length +
          diff.messages.length +
          diff.sessionTombstones.length +
          diff.messageTombstones.length;
      final nextSinceTime = max(sinceTime, diff.timestamp ?? sinceTime);

      if (totalItems == 0) {
        sinceTime = nextSinceTime;
        break;
      }

      final tombstonedSessions = {
        for (final tombstone in diff.sessionTombstones) tombstone.id,
      };
      final sessionsById = <String, _RemoteSession>{};
      for (final entity in diff.sessions) {
        try {
          final payload = await _decodeEntityPayload(
            entity,
            key,
            label: 'chatSessionDecrypt',
          );
          if (payload == null) continue;
          final session = _parseRemoteSession(entity, payload);
          if (session == null) continue;
          if (tombstonedSessions.contains(session.sessionUuid)) {
            continue;
          }
          sessionsById[session.sessionUuid] = session;
        } catch (e, s) {
          if (e is CryptoCrossCheckException) {
            _logger.severe(
              "Crypto cross-check failed while processing session",
              e,
              s,
            );
            rethrow;
          }
          errorCount++;
          _logger.warning(
            "Failed to process session: $e",
            e,
            s,
          );
        }
      }

      final messagesBySession = <String, Map<String, _RemoteMessage>>{};
      for (final entity in diff.messages) {
        try {
          final payload = await _decodeEntityPayload(
            entity,
            key,
            label: 'chatMessageDecrypt',
          );
          if (payload == null) continue;
          final message = _parseRemoteMessage(entity, payload);
          if (message == null) continue;
          if (tombstonedSessions.contains(message.sessionUuid)) {
            continue;
          }
          messagesBySession.putIfAbsent(
              message.sessionUuid, () => {})[message.messageUuid] = message;
        } catch (e, s) {
          if (e is CryptoCrossCheckException) {
            _logger.severe(
              "Crypto cross-check failed while processing message",
              e,
              s,
            );
            rethrow;
          }
          errorCount++;
          _logger.warning(
            "Failed to process message: $e",
            e,
            s,
          );
        }
      }

      for (final session in sessionsById.values) {
        await _db.upsertSessionFromRemote(
          sessionUuid: session.sessionUuid,
          title: session.title,
          createdAt: session.createdAt,
          updatedAt: session.updatedAt,
          rootSessionUuid: session.rootSessionUuid,
          branchFromMessageUuid: session.branchFromMessageUuid,
        );
        processedCount++;
      }

      final sessionsNeedingHeadRefresh = <String>{};

      for (final entry in messagesBySession.entries) {
        final sessionUuid = entry.key;
        final remoteMessages = entry.value.values.toList();
        if (remoteMessages.isEmpty) {
          continue;
        }

        final session = await _db.getSession(sessionUuid);
        if (session == null) {
          _logger.warning("Skipping remote messages for unknown session");
          continue;
        }

        final localMessages = await _db.getMessages(sessionUuid);
        final localConflictMessages =
            localMessages.map(ChatConflictMessage.fromLocal).toList();
        final remoteConflictMessages =
            remoteMessages.map((m) => m.toConflict()).toList();

        final resolution = ChatConflictResolver.resolve(
          localMessages: localConflictMessages,
          remoteMessages: remoteConflictMessages,
        );

        if (!resolution.hasChanges) {
          continue;
        }

        final remoteById = {
          for (final message in remoteMessages) message.messageUuid: message,
        };

        if (resolution.type == ChatConflictResolutionType.fastForward ||
            resolution.messagesToBranch.isEmpty) {
          processedCount += await _applyRemoteMessages(
            sessionUuid,
            resolution.messagesToAppend,
            remoteById,
          );
          sessionsNeedingHeadRefresh.add(sessionUuid);
          continue;
        }

        final branchSessionUuid = await _db.insertSession(
          session.title,
          rootSessionUuid: session.rootSessionUuid,
          branchFromMessageUuid: resolution.branchFromMessageUuid,
        );

        final branchMessageUuids =
            resolution.messagesToBranch.map((m) => m.messageUuid).toList();
        await _db.moveMessagesToSession(branchMessageUuids, branchSessionUuid);
        processedCount += branchMessageUuids.length;

        if (resolution.messagesToBranch.isNotEmpty) {
          final latestBranchUpdate =
              resolution.messagesToBranch.map((m) => m.createdAt).reduce(max);
          final branchSession = await _db.getSession(branchSessionUuid);
          if (branchSession != null &&
              latestBranchUpdate > branchSession.updatedAt) {
            await _db.updateSession(
              branchSession.copyWith(updatedAt: latestBranchUpdate),
            );
          }
        }

        processedCount += await _applyRemoteMessages(
          sessionUuid,
          resolution.messagesToAppend,
          remoteById,
        );

        sessionsNeedingHeadRefresh
          ..add(sessionUuid)
          ..add(branchSessionUuid);
      }

      for (final tombstone in diff.sessionTombstones) {
        await _db.deleteSession(tombstone.id);
        await _db.removePendingDeletion(
          ChatDB.deletionTypeSession,
          tombstone.id,
        );
        processedCount++;
      }

      for (final tombstone in diff.messageTombstones) {
        await _db.deleteMessage(tombstone.id);
        await _db.removePendingDeletion(
          ChatDB.deletionTypeMessage,
          tombstone.id,
        );
        processedCount++;
      }

      for (final sessionUuid in sessionsNeedingHeadRefresh) {
        await _refreshSessionHead(sessionUuid);
      }

      if (totalItems < limit || nextSinceTime == sinceTime) {
        if (totalItems >= limit && nextSinceTime == sinceTime) {
          _logger.warning("Diff pagination stalled at $sinceTime");
        }
        sinceTime = nextSinceTime;
        break;
      }

      sinceTime = nextSinceTime;
    }

    await _prefs.setInt(_lastSyncTimeKey, sinceTime);
    _logger.fine(
      "Pull completed: processed $processedCount entities, $errorCount errors",
    );
  }

  Future<int> _applyRemoteMessages(
    String sessionUuid,
    List<ChatConflictMessage> messages,
    Map<String, _RemoteMessage> remoteById,
  ) async {
    if (messages.isEmpty) return 0;

    var applied = 0;
    int? latestCreatedAt;

    for (final message in messages) {
      final remote = remoteById[message.messageUuid];
      if (remote == null) {
        _logger.warning("Missing remote payload for message");
        continue;
      }

      await _db.upsertMessageFromRemote(
        messageUuid: remote.messageUuid,
        sessionUuid: remote.sessionUuid,
        parentMessageUuid: remote.parentMessageUuid,
        sender: remote.sender,
        text: remote.text,
        attachments: remote.attachments,
        createdAt: remote.createdAt,
      );
      applied++;
      if (latestCreatedAt == null || remote.createdAt > latestCreatedAt) {
        latestCreatedAt = remote.createdAt;
      }
    }

    if (latestCreatedAt != null) {
      final session = await _db.getSession(sessionUuid);
      if (session != null && latestCreatedAt > session.updatedAt) {
        await _db.updateSession(
          session.copyWith(updatedAt: latestCreatedAt),
        );
      }
    }

    return applied;
  }

  Future<Map<String, dynamic>?> _decodeEntityPayload(
    ChatEntity entity,
    Uint8List key, {
    required String label,
  }) async {
    if (entity.encryptedData.isEmpty || entity.header.isEmpty) {
      _logger.warning("Skipping $label: missing payload");
      return null;
    }

    final decrypted = await CryptoUtil.decryptData(
      CryptoUtil.base642bin(entity.encryptedData),
      key,
      CryptoUtil.base642bin(entity.header),
    );

    final decoded = jsonDecode(utf8.decode(decrypted));
    if (decoded is! Map<String, dynamic>) {
      _logger.warning("Skipping $label: invalid payload");
      return null;
    }

    return decoded;
  }

  _RemoteSession? _parseRemoteSession(
    ChatEntity entity,
    Map<String, dynamic> json,
  ) {
    final type = _readString(json['type']);
    if (type != null && type != 'llmchat_session') {
      _logger.fine("Skipping session: type=$type");
      return null;
    }

    final payloadId = _readString(json['session_uuid'] ?? json['sessionUuid']);
    final sessionUuid = payloadId ?? entity.sessionUuid ?? entity.id;
    if (payloadId != null && payloadId != entity.id) {
      _logger.warning("Session id mismatch between payload and entity");
    }

    final rootSessionUuid = entity.rootSessionUuid ??
        _readString(json['root_session_uuid'] ?? json['rootSessionUuid']) ??
            sessionUuid;
    final branchFromMessageUuid = entity.branchFromMessageUuid ??
        _readString(
            json['branch_from_message_uuid'] ?? json['branchFromMessageUuid']);
    final title = _readString(json['title']) ?? 'Chat';
    final createdAt = entity.createdAt != 0
        ? entity.createdAt
        : _readInt(
            json['created_at'] ?? json['createdAt'],
            entity.createdAt,
          );
    final updatedAt = entity.updatedAt != 0
        ? entity.updatedAt
        : _readInt(
            json['updated_at'] ?? json['updatedAt'],
            entity.updatedAt,
          );
    final resolvedUpdatedAt = updatedAt < createdAt ? createdAt : updatedAt;

    return _RemoteSession(
      sessionUuid: sessionUuid,
      rootSessionUuid: rootSessionUuid,
      branchFromMessageUuid: branchFromMessageUuid,
      title: title,
      createdAt: createdAt,
      updatedAt: resolvedUpdatedAt,
    );
  }

  _RemoteMessage? _parseRemoteMessage(
    ChatEntity entity,
    Map<String, dynamic> json,
  ) {
    final type = _readString(json['type']);
    if (type != null && type != 'llmchat_message') {
      _logger.fine("Skipping message: type=$type");
      return null;
    }

    final payloadId = _readString(json['message_uuid'] ?? json['messageUuid']);
    final messageUuid = payloadId ?? entity.id;
    if (payloadId != null && payloadId != entity.id) {
      _logger.warning("Message id mismatch between payload and entity");
    }

    final sessionUuid = entity.sessionUuid ??
        _readString(json['session_uuid'] ?? json['sessionUuid']);
    if (sessionUuid == null) {
      _logger.warning("Skipping message: missing session_uuid");
      return null;
    }

    final parentMessageUuid = entity.parentMessageUuid ??
        _readString(json['parent_message_uuid'] ?? json['parentMessageUuid']);
    final sender = entity.sender ?? _readString(json['sender']);
    if (sender == null) {
      _logger.warning("Skipping message: missing sender");
      return null;
    }
    final text = _readString(json['text']) ?? '';

    final attachments = entity.attachments.isNotEmpty
        ? entity.attachments
        : _readAttachments(
            json['attachments'] ??
                json['attachment_ids'] ??
                json['attachmentIds'],
          );

    final createdAt = entity.createdAt != 0
        ? entity.createdAt
        : _readInt(
            json['created_at'] ?? json['createdAt'],
            entity.createdAt,
          );

    return _RemoteMessage(
      messageUuid: messageUuid,
      sessionUuid: sessionUuid,
      parentMessageUuid: parentMessageUuid,
      sender: sender,
      text: text,
      attachments: attachments,
      createdAt: createdAt,
    );
  }

  Future<void> _refreshSessionHead(String sessionUuid) async {
    final session = await _db.getSession(sessionUuid);
    if (session == null) return;

    final messages = await _db.getMessages(sessionUuid);
    String? head;
    if (messages.isNotEmpty) {
      final heads = ChatDag.findHeads(messages);
      head = heads.isNotEmpty ? heads.last.messageUuid : null;
    }

    head ??= session.branchFromMessageUuid;
    _db.setSessionHead(sessionUuid, head);
  }

  int _readInt(dynamic value, int fallback) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return fallback;
  }

  String? _readString(dynamic value) {
    if (value is String) return value;
    return null;
  }

  List<ChatAttachment> _readAttachments(dynamic value) {
    if (value is List) {
      if (value.isEmpty) return const [];

      final attachments = <ChatAttachment>[];
      for (final entry in value) {
        if (entry is Map) {
          try {
            attachments.add(
              ChatAttachment.fromJson(Map<String, dynamic>.from(entry)),
            );
          } catch (_) {
            continue;
          }
        } else if (entry is String && entry.isNotEmpty) {
          attachments.add(
            ChatAttachment(
              id: entry,
              kind: ChatAttachmentKind.document,
              size: 0,
            ),
          );
        }
      }
      return attachments;
    }

    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        return _readAttachments(decoded);
      } catch (_) {
        return const [];
      }
    }

    return const [];
  }

  bool _isNotFoundError(Object error) {
    return error is DioException && error.response?.statusCode == 404;
  }

  Future<bool> _deleteRemoteEntity(
    String entityType,
    String entityId, {
    required bool propagateUnauthorized,
  }) async {
    try {
      if (entityType == ChatDB.deletionTypeSession) {
        await _gateway.deleteSession(entityId);
      } else {
        await _gateway.deleteMessage(entityId);
      }
      return true;
    } on UnauthorizedError catch (e, s) {
      if (propagateUnauthorized) {
        rethrow;
      }
      _logger.warning(
        "Unauthorized while deleting $entityType: $entityId",
        e,
        s,
      );
      return false;
    } catch (e, s) {
      if (_isNotFoundError(e)) {
        _logger.fine("$entityType already deleted on server: $entityId");
        return true;
      }
      _logger.warning(
        "Failed to delete $entityType $entityId from server: $e",
        e,
        s,
      );
      return false;
    }
  }

  Future<void> _handleUnauthorized(String context) async {
    _logger.warning("Unauthorized during $context - logging out");
    await _config.logout();
    eventBus.fire(TriggerLogoutEvent());
  }

  Future<void> _pushPendingDeletions(
    List<PendingDeletion> deletions,
  ) async {
    _logger.fine("Pushing ${deletions.length} deletions to server");
    int successCount = 0;
    int errorCount = 0;

    for (final deletion in deletions) {
      final deleted = await _deleteRemoteEntity(
        deletion.entityType,
        deletion.entityId,
        propagateUnauthorized: true,
      );
      if (deleted) {
        await _db.removePendingDeletion(
          deletion.entityType,
          deletion.entityId,
        );
        successCount++;
      } else {
        errorCount++;
      }
    }

    _logger.fine(
      "Deletion push completed: $successCount succeeded, $errorCount failed",
    );
  }

  Future<void> _uploadPendingAttachments(Set<String> attachmentIds) async {
    if (_attachmentsApiUnavailable || attachmentIds.isEmpty) {
      return;
    }

    final states = await _db.getAttachmentStates(attachmentIds.toList());
    for (final attachmentId in attachmentIds) {
      if (attachmentId.isEmpty) {
        continue;
      }
      final state = states[attachmentId];
      if (state == null || state == ChatAttachmentUploadState.uploaded) {
        continue;
      }

      await _db.markAttachmentUploading(attachmentId);
      eventBus.fire(ChatsUpdatedEvent());
      try {
        final encryptedBytes =
            await ChatAttachmentStore.instance.readEncryptedAttachmentBytes(
          attachmentId,
        );
        if (encryptedBytes == null) {
          await _db.markAttachmentFailed(attachmentId);
          eventBus.fire(ChatsUpdatedEvent());
          continue;
        }

        await _gateway.uploadAttachment(attachmentId, encryptedBytes);
        await _db.markAttachmentUploaded(attachmentId);
        eventBus.fire(ChatsUpdatedEvent());
      } on UnauthorizedError {
        rethrow;
      } catch (e, s) {
        if (_isNotFoundError(e)) {
          _attachmentsApiUnavailable = true;
          _logger.fine('Attachment API not available on server');
          await _db.markAttachmentFailed(attachmentId);
          eventBus.fire(ChatsUpdatedEvent());
          return;
        }
        await _db.markAttachmentFailed(attachmentId);
        eventBus.fire(ChatsUpdatedEvent());
        _logger.warning('Attachment upload failed: $attachmentId', e, s);
      }
    }
  }

  Set<String> _messagesWithPendingAttachments(
    List<LocalMessage> messages,
    Map<String, ChatAttachmentUploadState> states,
  ) {
    final pending = <String>{};
    for (final message in messages) {
      for (final attachment in message.attachments) {
        final state = states[attachment.id];
        if (state != null && state != ChatAttachmentUploadState.uploaded) {
          pending.add(message.messageUuid);
          break;
        }
      }
    }
    return pending;
  }

  /// Push local changes to server.
  Future<void> _pushToServer() async {
    final pendingDeletions = await _db.getPendingDeletions();
    final sessionsToSync = await _db.getSessionsNeedingSync();
    if (pendingDeletions.isEmpty && sessionsToSync.isEmpty) {
      _logger.fine("No sessions or deletions need syncing");
      return;
    }

    if (pendingDeletions.isNotEmpty) {
      await _pushPendingDeletions(pendingDeletions);
    }

    if (sessionsToSync.isEmpty) {
      return;
    }

    Uint8List key;
    try {
      key = await _getOrCreateChatKey();
    } catch (e, s) {
      _logger.severe("Failed to get/create chat key for push: $e", e, s);
      rethrow;
    }

    _logger.fine("Pushing ${sessionsToSync.length} sessions to server");
    int successCount = 0;
    int errorCount = 0;

    for (final session in sessionsToSync) {
      try {
        final messages = await _db.getMessages(session.sessionUuid);

        final attachmentIds = <String>{};
        for (final message in messages) {
          for (final attachment in message.attachments) {
            if (attachment.id.isNotEmpty) {
              attachmentIds.add(attachment.id);
            }
          }
        }

        await _uploadPendingAttachments(attachmentIds);
        final attachmentStates =
            await _db.getAttachmentStates(attachmentIds.toList());
        final blockedMessageIds =
            _messagesWithPendingAttachments(messages, attachmentStates);
        final messagesToSync =
            ChatDag.orderForSync(messages, blockedMessageIds);

        final sessionPayload = {
          'title': session.title,
        };

        final sessionBytes =
            Uint8List.fromList(utf8.encode(jsonEncode(sessionPayload)));
        final encryptedSession = await CryptoUtil.encryptData(
          sessionBytes,
          key,
        );
        final encryptedSessionData =
            CryptoUtil.bin2base64(encryptedSession.encryptedData!);
        final encryptedSessionHeader =
            CryptoUtil.bin2base64(encryptedSession.header!);

        await _gateway.upsertSession(
          session.sessionUuid,
          encryptedSessionData,
          encryptedSessionHeader,
          rootSessionUuid: session.rootSessionUuid,
          branchFromMessageUuid: session.branchFromMessageUuid,
          createdAt: session.createdAt,
        );

        for (final message in messagesToSync) {
          final messagePayload = {
            'text': message.text,
          };

          final messageBytes =
              Uint8List.fromList(utf8.encode(jsonEncode(messagePayload)));
          final encryptedMessage = await CryptoUtil.encryptData(
            messageBytes,
            key,
          );
          final encryptedMessageData =
              CryptoUtil.bin2base64(encryptedMessage.encryptedData!);
          final encryptedMessageHeader =
              CryptoUtil.bin2base64(encryptedMessage.header!);

          await _gateway.upsertMessage(
            message.messageUuid,
            message.sessionUuid,
            message.parentMessageUuid,
            encryptedMessageData,
            encryptedMessageHeader,
            sender: message.sender,
            attachments: message.attachments
                .map((attachment) => attachment.toServerJson())
                .toList(),
            createdAt: message.createdAt,
          );
        }

        final hasBlockedMessages = messagesToSync.length != messages.length;
        await _db.updateSession(session.copyWith(
          remoteId: session.sessionUuid,
          needsSync: hasBlockedMessages,
        ));
        _logger.fine(
          "Synced session with ${messagesToSync.length} messages",
        );
        successCount++;
      } catch (e, s) {
        if (e is UnauthorizedError) {
          rethrow;
        }
        if (e is CryptoCrossCheckException) {
          _logger.severe(
            "Crypto cross-check failed while syncing session",
            e,
            s,
          );
          rethrow;
        }
        errorCount++;
        _logger.warning("Failed to sync session: $e", e, s);
      }
    }

    _logger.fine("Push completed: $successCount succeeded, $errorCount failed");
  }

  Future<Uint8List> getOrCreateChatKey() async {
    return _getOrCreateChatKey();
  }

  /// Get or create the chat encryption key.
  Future<Uint8List> _getOrCreateChatKey() async {
    // Check cached key
    if (_config.getChatSecretKey() != null) {
      return _config.getChatSecretKey()!;
    }

    // Try to get from server
    try {
      final response = await _gateway.getKey();
      final masterKey = _config.getKey()!;
      final encryptedKey = CryptoUtil.base642bin(response.encryptedKey);
      final header = CryptoUtil.base642bin(response.header);
      final chatKey = CryptoUtil.decryptSync(
        encryptedKey,
        masterKey,
        header,
      );
      await _config.setChatSecretKey(CryptoUtil.bin2base64(chatKey));
      return chatKey;
    } on ChatKeyNotFound {
      // Create new key
      _logger.fine("Creating new chat key");
      final key = CryptoUtil.generateKey();
      final masterKey = _config.getKey()!;
      final encrypted = CryptoUtil.encryptSync(key, masterKey);
      await _gateway.createKey(
        CryptoUtil.bin2base64(encrypted.encryptedData!),
        CryptoUtil.bin2base64(encrypted.nonce!),
      );
      await _config.setChatSecretKey(CryptoUtil.bin2base64(key));
      return key;
    }
  }
}
