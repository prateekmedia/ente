import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ente_rust/ente_rust.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/gateway/chat_gateway.dart';
import 'package:ensu/models/chat_entity.dart';
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
  final int id;
  final String title;
  final int createdAt;
  final int updatedAt;
  final List<ChatMessage> messages;
  final String? lastMessagePreview;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messages,
    this.lastMessagePreview,
  });
}

/// Represents a single chat message.
class ChatMessage {
  final int id;
  final int sessionId;
  final bool isSelf;
  final String text;
  final int createdAt;
  final double? tokensPerSecond; // Performance metric for AI messages

  ChatMessage({
    required this.id,
    required this.sessionId,
    required this.isSelf,
    required this.text,
    required this.createdAt,
    this.tokensPerSecond,
  });
}

/// Service for managing chat sessions and messages.
/// Local-first: works offline, syncs when logged in.
class ChatService {
  final _logger = Logger('ChatService');
  final _config = Configuration.instance;
  late SharedPreferences _prefs;
  late ChatGateway _gateway;
  late ChatDB _db;
  final String _lastSyncTimeKey = "lastChatSyncTime";
  bool _isSyncing = false;

  ChatService._privateConstructor();
  static final ChatService instance = ChatService._privateConstructor();

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _db = ChatDB.instance;
    _gateway = ChatGateway();

    // Background sync if logged in
    if (_config.hasConfiguredAccount()) {
      unawaited(_backgroundSync());
    }
  }

  /// Get all chat sessions with messages.
  Future<List<ChatSession>> getAllSessions() async {
    final sessions = await _db.getAllSessions();
    final result = <ChatSession>[];

    for (final session in sessions) {
      final messages = await _db.getMessages(session.id);
      final lastMsg = messages.isNotEmpty ? messages.last : null;

      result.add(ChatSession(
        id: session.id,
        title: session.title,
        createdAt: session.createdAt,
        updatedAt: session.updatedAt,
        messages: messages
            .map((m) => ChatMessage(
                  id: m.id,
                  sessionId: m.sessionId,
                  isSelf: m.sender == 'self',
                  text: m.text,
                  createdAt: m.createdAt,
                  tokensPerSecond: m.tokensPerSecond,
                ))
            .toList(),
        lastMessagePreview: lastMsg != null
            ? (lastMsg.text.length > 50
                ? '${lastMsg.text.substring(0, 47)}...'
                : lastMsg.text)
            : null,
      ));
    }

    return result;
  }

  /// Get a single session with messages.
  Future<ChatSession?> getSession(int sessionId) async {
    final session = await _db.getSession(sessionId);
    if (session == null) return null;

    final messages = await _db.getMessages(sessionId);
    final lastMsg = messages.isNotEmpty ? messages.last : null;

    return ChatSession(
      id: session.id,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      messages: messages
          .map((m) => ChatMessage(
                id: m.id,
                sessionId: m.sessionId,
                isSelf: m.sender == 'self',
                text: m.text,
                createdAt: m.createdAt,
                tokensPerSecond: m.tokensPerSecond,
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
  Future<int> createSession(String title) async {
    final sessionId = await _db.insertSession(title);
    _logger.info("Created session $sessionId: $title");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
    return sessionId;
  }

  /// Send a message in a session.
  Future<void> sendMessage(int sessionId, String text) async {
    await _db.insertMessage(sessionId, 'self', text);
    _logger.info("Sent message to session $sessionId");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  /// Add an AI response message to a session.
  Future<void> addAIMessage(
    int sessionId,
    String text, {
    double? tokensPerSecond,
  }) async {
    await _db.insertMessage(
      sessionId,
      'other',
      text,
      tokensPerSecond: tokensPerSecond,
    );
    _logger.info(
        "Added AI message to session $sessionId (${tokensPerSecond?.toStringAsFixed(2)} tokens/sec)");
    eventBus.fire(ChatsUpdatedEvent());
    _triggerBackgroundSync();
  }

  /// Update the last AI message (for streaming).
  Future<void> updateLastAIMessage(int sessionId, String text) async {
    final messages = await _db.getMessages(sessionId);
    if (messages.isNotEmpty && messages.last.sender == 'other') {
      // Delete the last message and re-insert with new text
      // (Simple approach - could optimize with UPDATE)
      final db = await _db.database;
      await db.delete(
        'messages',
        where: 'id = ?',
        whereArgs: [messages.last.id],
      );
    }
    await _db.insertMessage(sessionId, 'other', text);
    eventBus.fire(ChatsUpdatedEvent());
  }

  /// Delete the last AI message from a session.
  /// Returns the user message that prompted this AI response (for retry).
  Future<String?> deleteLastAIMessage(int sessionId) async {
    final messages = await _db.getMessages(sessionId);
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
    final db = await _db.database;
    await db.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [lastAIMessage.id],
    );
    await _db.markSessionForSync(sessionId);
    _logger.info("Deleted last AI message from session $sessionId");
    eventBus.fire(ChatsUpdatedEvent());

    return precedingUserMessage;
  }

  /// Delete a chat session.
  Future<void> deleteSession(int sessionId) async {
    // If synced to server, delete there too
    final session = await _db.getSession(sessionId);
    if (session?.remoteId != null && _config.hasConfiguredAccount()) {
      try {
        await _gateway.deleteEntity(session!.remoteId!);
      } catch (e) {
        _logger.warning("Failed to delete from server: $e");
      }
    }

    await _db.deleteSession(sessionId);
    _logger.info("Deleted session $sessionId");
    eventBus.fire(ChatsUpdatedEvent());
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
      _logger.warning("Background sync failed: ${e.runtimeType} - $e", e, s);
    } finally {
      _isSyncing = false;
    }
  }

  /// Manual sync - pull from server then push.
  Future<bool> sync() async {
    if (!_config.hasConfiguredAccount()) {
      _logger.info("Sync skipped: No configured account");
      return false;
    }

    try {
      _logger.info("Starting manual sync");

      // Pull phase
      try {
        await _pullFromServer();
        _logger.fine("Pull from server completed");
      } catch (e, s) {
        _logger.warning("Failed to pull from server: $e", e, s);
        // Continue with push even if pull fails
      }

      // Push phase
      try {
        await _pushToServer();
        _logger.fine("Push to server completed");
      } catch (e, s) {
        _logger.warning("Failed to push to server: $e", e, s);
        // Push failure shouldn't prevent completion
      }

      eventBus.fire(ChatsUpdatedEvent());
      _logger.info("Sync completed");
      return true;
    } on UnauthorizedError {
      _logger.warning("Unauthorized during sync - triggering logout");
      eventBus.fire(TriggerLogoutEvent());
      return false;
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

    List<ChatEntity> entities;
    try {
      final (fetchedEntities, _) =
          await _gateway.getDiff(lastSyncTime, limit: 500);
      entities = fetchedEntities;
      _logger.info("Pulled ${entities.length} entities from server");
    } catch (e, s) {
      _logger.severe("Failed to fetch entities from server: $e", e, s);
      rethrow;
    }

    if (entities.isEmpty) return;

    int maxSyncTime = lastSyncTime;
    int processedCount = 0;
    int errorCount = 0;

    for (final entity in entities) {
      maxSyncTime = max(maxSyncTime, entity.updatedAt);

      if (entity.isDeleted) {
        // Find and delete local session with this remoteId
        final sessions = await _db.getAllSessions();
        for (final s in sessions) {
          if (s.remoteId == entity.id) {
            await _db.deleteSession(s.id);
            _logger
                .fine("Deleted local session ${s.id} (remote: ${entity.id})");
            break;
          }
        }
        processedCount++;
        continue;
      }

      // Decrypt and parse
      try {
        final decrypted = decryptData(
          encryptedDataB64: entity.encryptedData,
          key: key,
          headerB64: entity.header,
        );
        final json = jsonDecode(utf8.decode(decrypted)) as Map<String, dynamic>;

        // Only process ensu_chat type
        if (json['type'] != 'ensu_chat') {
          _logger.fine("Skipping entity ${entity.id}: type=${json['type']}");
          continue;
        }

        // Check if we already have this session
        final sessions = await _db.getAllSessions();
        LocalSession? existing;
        for (final s in sessions) {
          if (s.remoteId == entity.id) {
            existing = s;
            break;
          }
        }

        if (existing == null) {
          // Import new session from server
          await _importSession(entity.id, json);
          processedCount++;
        }
        // If exists, we could merge - for now, local wins
      } catch (e, s) {
        errorCount++;
        _logger.warning("Failed to process entity ${entity.id}: $e", e, s);
      }
    }

    await _prefs.setInt(_lastSyncTimeKey, maxSyncTime);
    _logger.info(
        "Pull completed: processed $processedCount entities, $errorCount errors");
  }

  /// Import a session from server data.
  Future<void> _importSession(
      String remoteId, Map<String, dynamic> json) async {
    final sessionJson = json['session'] as Map<String, dynamic>;
    final messagesJson = json['messages'] as List<dynamic>;

    final sessionId = await _db.insertSession(sessionJson['title'] as String);

    // Update with remote ID
    final session = await _db.getSession(sessionId);
    if (session != null) {
      await _db.updateSession(session.copyWith(
        remoteId: remoteId,
        needsSync: false,
        createdAt: sessionJson['createdAt'] as int,
      ));
    }

    // Import messages
    for (final m in messagesJson) {
      final msg = m as Map<String, dynamic>;
      await _db.insertMessage(
        sessionId,
        msg['sender'] as String,
        msg['text'] as String,
      );
    }

    _logger.info("Imported session from server: $remoteId");
  }

  /// Push local changes to server.
  Future<void> _pushToServer() async {
    final sessionsToSync = await _db.getSessionsNeedingSync();
    if (sessionsToSync.isEmpty) {
      _logger.fine("No sessions need syncing");
      return;
    }

    Uint8List key;
    try {
      key = await _getOrCreateChatKey();
    } catch (e, s) {
      _logger.severe("Failed to get/create chat key for push: $e", e, s);
      rethrow;
    }

    _logger.info("Pushing ${sessionsToSync.length} sessions to server");
    int successCount = 0;
    int errorCount = 0;

    for (final session in sessionsToSync) {
      try {
        final messages = await _db.getMessages(session.id);

        // Build the sync payload
        final payload = {
          'type': 'ensu_chat',
          'version': 1,
          'session': {
            'title': session.title,
            'createdAt': session.createdAt,
            'lastMessageAt': session.updatedAt,
          },
          'messages': messages
              .map((m) => <String, dynamic>{
                    'sender': m.sender,
                    'text': m.text,
                    'createdAt': m.createdAt,
                  })
              .toList(),
        };

        final jsonStr = jsonEncode(payload);
        final encrypted = encryptData(
          plaintext: Uint8List.fromList(utf8.encode(jsonStr)),
          key: key,
        );

        if (session.remoteId == null) {
          // Create new entity on server
          final entity = await _gateway.createEntity(
            encrypted.encryptedData,
            encrypted.header,
          );
          await _db.updateSession(session.copyWith(
            remoteId: entity.id,
            needsSync: false,
          ));
          _logger.fine(
              "Created remote entity ${entity.id} for session ${session.id}");
          successCount++;
        } else {
          // Update existing entity
          await _gateway.updateEntity(
            session.remoteId!,
            encrypted.encryptedData,
            encrypted.header,
          );
          await _db.updateSession(session.copyWith(needsSync: false));
          _logger.fine(
              "Updated remote entity ${session.remoteId} for session ${session.id}");
          successCount++;
        }
      } catch (e, s) {
        errorCount++;
        _logger.warning(
            "Failed to sync session ${session.id} (${session.title}): $e",
            e,
            s);
      }
    }

    _logger.info("Push completed: $successCount succeeded, $errorCount failed");
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
      final chatKey = decryptSync(
        cipher: decodeB64(data: response.encryptedKey),
        key: masterKey,
        nonce: decodeB64(data: response.header),
      );
      await _config.setChatSecretKey(encodeB64(data: chatKey));
      return chatKey;
    } on ChatKeyNotFound {
      // Create new key
      _logger.info("Creating new chat key");
      final key = Uint8List.fromList(generateKey());
      final masterKey = _config.getKey()!;
      final encrypted = encryptSync(plaintext: key, key: masterKey);
      await _gateway.createKey(
        encodeB64(data: encrypted.encryptedData),
        encodeB64(data: encrypted.nonce),
      );
      await _config.setChatSecretKey(encodeB64(data: key));
      return key;
    }
  }
}
