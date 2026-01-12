import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ensu/core/configuration.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

final _logger = Logger('ChatDB');

/// Local chat session stored in SQLite.
class LocalSession {
  final String sessionUuid;
  final String title;
  final int createdAt;
  final int updatedAt;
  final String rootSessionUuid;
  final String? branchFromMessageUuid;
  final String? remoteId; // ID from server (null if never synced)
  final bool needsSync;

  const LocalSession({
    required this.sessionUuid,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.rootSessionUuid,
    this.branchFromMessageUuid,
    this.remoteId,
    this.needsSync = true,
  });

  LocalSession copyWith({
    String? sessionUuid,
    String? title,
    int? createdAt,
    int? updatedAt,
    String? rootSessionUuid,
    String? branchFromMessageUuid,
    String? remoteId,
    bool? needsSync,
  }) {
    return LocalSession(
      sessionUuid: sessionUuid ?? this.sessionUuid,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rootSessionUuid: rootSessionUuid ?? this.rootSessionUuid,
      branchFromMessageUuid:
          branchFromMessageUuid ?? this.branchFromMessageUuid,
      remoteId: remoteId ?? this.remoteId,
      needsSync: needsSync ?? this.needsSync,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'sessionUuid': sessionUuid,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'rootSessionUuid': rootSessionUuid,
      'branchFromMessageUuid': branchFromMessageUuid,
      'remoteId': remoteId,
      'needsSync': needsSync ? 1 : 0,
    };
  }

  factory LocalSession.fromMap(Map<String, dynamic> map) {
    return LocalSession(
      sessionUuid: map['sessionUuid'] as String,
      title: map['title'] as String,
      createdAt: map['createdAt'] as int,
      updatedAt: map['updatedAt'] as int,
      rootSessionUuid: map['rootSessionUuid'] as String,
      branchFromMessageUuid: map['branchFromMessageUuid'] as String?,
      remoteId: map['remoteId'] as String?,
      needsSync: (map['needsSync'] as int?) == 1,
    );
  }
}

/// Local chat message stored in SQLite.
class LocalMessage {
  final String messageUuid;
  final String sessionUuid;
  final String? parentMessageUuid;
  final String sender; // 'self' or 'other'
  final String text;
  final int createdAt;

  const LocalMessage({
    required this.messageUuid,
    required this.sessionUuid,
    this.parentMessageUuid,
    required this.sender,
    required this.text,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageUuid': messageUuid,
      'sessionUuid': sessionUuid,
      'parentMessageUuid': parentMessageUuid,
      'sender': sender,
      'text': text,
      'createdAt': createdAt,
    };
  }

  factory LocalMessage.fromMap(Map<String, dynamic> map) {
    return LocalMessage(
      messageUuid: map['messageUuid'] as String,
      sessionUuid: map['sessionUuid'] as String,
      parentMessageUuid: map['parentMessageUuid'] as String?,
      sender: map['sender'] as String,
      text: map['text'] as String,
      createdAt: map['createdAt'] as int,
    );
  }
}

/// Database for storing chat data locally.
class ChatDB {
  static const _databaseName = "ente.ensu.v2.db";
  static const _databaseVersion = 3;
  static const sessionsTable = 'sessions';
  static const messagesTable = 'messages';
  static const branchSelectionsTable = 'branchSelections';
  static const _encryptionPrefix = 'enc:v1:';
  static final Uuid _uuid = Uuid();
  final Map<String, String?> _sessionHeads = {};
  Uint8List? _localKey;
  Future<Uint8List>? _localKeyFuture;

  ChatDB._privateConstructor();
  static final ChatDB instance = ChatDB._privateConstructor();

  static Future<Database>? _dbFuture;

  Future<Uint8List> _getLocalKey() {
    if (_localKey != null) {
      return Future.value(_localKey);
    }
    _localKeyFuture ??=
        Configuration.instance.getOrCreateOfflineChatSecretKey().then((key) {
      _localKey = key;
      return key;
    });
    return _localKeyFuture!;
  }

  bool _isEncryptedValue(String value) => value.startsWith(_encryptionPrefix);

  String _packEncrypted(String encryptedData, String header) {
    return '$_encryptionPrefix$encryptedData:$header';
  }

  Future<String> _encryptStringWithKey(
    String value,
    Uint8List key,
  ) async {
    if (value.isEmpty || _isEncryptedValue(value)) {
      return value;
    }
    final encrypted = await CryptoUtil.encryptData(
      Uint8List.fromList(utf8.encode(value)),
      key,
    );
    final encryptedDataB64 = CryptoUtil.bin2base64(encrypted.encryptedData!);
    final headerB64 = CryptoUtil.bin2base64(encrypted.header!);
    return _packEncrypted(encryptedDataB64, headerB64);
  }

  Future<String> _encryptString(String value) async {
    final key = await _getLocalKey();
    return _encryptStringWithKey(value, key);
  }

  Future<String> _decryptStringWithKey(
    String value,
    Uint8List key,
  ) async {
    if (!_isEncryptedValue(value)) {
      return value;
    }
    final payload = value.substring(_encryptionPrefix.length);
    final parts = payload.split(':');
    if (parts.length != 2) {
      return '';
    }
    try {
      final decrypted = await CryptoUtil.decryptData(
        CryptoUtil.base642bin(parts[0]),
        key,
        CryptoUtil.base642bin(parts[1]),
      );
      return utf8.decode(decrypted, allowMalformed: true);
    } catch (e) {
      _logger.warning('Failed to decrypt chat payload: $e');
      return '';
    }
  }

  Future<String> _decryptString(String value) async {
    final key = await _getLocalKey();
    return _decryptStringWithKey(value, key);
  }

  Future<Database> get database async {
    _dbFuture ??= _initDatabase();
    return _dbFuture!;
  }

  Future<String> _getDatabasePath() async {
    if (Platform.isWindows || Platform.isLinux) {
      final Directory appSupportDir = await getApplicationSupportDirectory();
      return join(appSupportDir.path, _databaseName);
    }
    final Directory documentsDirectory = Platform.isMacOS
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, _databaseName);
  }

  Future<Database> _initDatabase() async {
    final path = await _getDatabasePath();
    _logger.fine("ChatDB path: $path");

    if (Platform.isWindows || Platform.isLinux) {
      var databaseFactory = databaseFactoryFfi;
      return await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: _databaseVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }

    return await openDatabase(
      path,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _createBranchSelectionsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $branchSelectionsTable (
        rootSessionUuid TEXT NOT NULL,
        selectionKey TEXT NOT NULL,
        selectedMessageUuid TEXT NOT NULL,
        PRIMARY KEY (rootSessionUuid, selectionKey)
      )
    ''');
  }

  Future<void> _createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $sessionsTable (
        sessionUuid TEXT PRIMARY KEY NOT NULL,
        title TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        rootSessionUuid TEXT NOT NULL,
        branchFromMessageUuid TEXT,
        remoteId TEXT,
        needsSync INTEGER DEFAULT 1,
        UNIQUE(remoteId)
      )
    ''');

    await db.execute('''
      CREATE TABLE $messagesTable (
        messageUuid TEXT PRIMARY KEY NOT NULL,
        sessionUuid TEXT NOT NULL,
        parentMessageUuid TEXT,
        sender TEXT NOT NULL,
        text TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        FOREIGN KEY (sessionUuid) REFERENCES $sessionsTable(sessionUuid) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_session ON $messagesTable(sessionUuid)
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_parent ON $messagesTable(parentMessageUuid)
    ''');

    await _createBranchSelectionsTable(db);
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createSchema(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 3) {
      final hasSessionUuid =
          await _columnExists(db, sessionsTable, 'sessionUuid');
      if (!hasSessionUuid) {
        await _migrateLegacySchema(db);
      } else {
        await _createBranchSelectionsTable(db);
      }
    }
  }

  Future<bool> _columnExists(
    Database db,
    String table,
    String column,
  ) async {
    try {
      final rows = await db.rawQuery('PRAGMA table_info($table)');
      return rows.any((row) => row['name'] == column);
    } catch (_) {
      return false;
    }
  }

  Future<void> _migrateLegacySchema(Database db) async {
    await db.transaction((txn) async {
      await txn.execute(
        'ALTER TABLE $sessionsTable RENAME TO ${sessionsTable}_legacy',
      );
      await txn.execute(
        'ALTER TABLE $messagesTable RENAME TO ${messagesTable}_legacy',
      );

      await _createSchema(txn);

      final legacySessions = await txn.query('${sessionsTable}_legacy');
      final sessionIdToUuid = <int, String>{};

      for (final row in legacySessions) {
        final sessionUuid = _uuid.v4();
        final legacyId = row['id'] as int?;
        if (legacyId != null) {
          sessionIdToUuid[legacyId] = sessionUuid;
        }

        final title = row['title'] as String? ?? '';
        final createdAt =
            (row['createdAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch;
        final updatedAt = (row['updatedAt'] as int?) ?? createdAt;
        final needsSync = (row['needsSync'] as int?) ?? 1;

        await txn.insert(sessionsTable, {
          'sessionUuid': sessionUuid,
          'title': await _encryptString(title),
          'createdAt': createdAt,
          'updatedAt': updatedAt,
          'rootSessionUuid': sessionUuid,
          'branchFromMessageUuid': null,
          'remoteId': row['remoteId'] as String?,
          'needsSync': needsSync,
        });
      }

      final legacyMessages = await txn.query('${messagesTable}_legacy');
      for (final row in legacyMessages) {
        final sessionId = row['sessionId'] as int?;
        final sessionUuid =
            sessionId == null ? null : sessionIdToUuid[sessionId];
        if (sessionUuid == null) {
          continue;
        }
        final text = row['text'] as String? ?? '';
        final createdAt =
            (row['createdAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch;

        await txn.insert(messagesTable, {
          'messageUuid': _uuid.v4(),
          'sessionUuid': sessionUuid,
          'parentMessageUuid': null,
          'sender': row['sender'] as String? ?? 'self',
          'text': await _encryptString(text),
          'createdAt': createdAt,
        });
      }

      await txn.execute('DROP TABLE ${messagesTable}_legacy');
      await txn.execute('DROP TABLE ${sessionsTable}_legacy');
    });
  }

  Future<LocalSession> _sessionFromRow(Map<String, dynamic> row) async {
    final decryptedTitle = await _decryptString(row['title'] as String);
    return LocalSession(
      sessionUuid: row['sessionUuid'] as String,
      title: decryptedTitle,
      createdAt: row['createdAt'] as int,
      updatedAt: row['updatedAt'] as int,
      rootSessionUuid: row['rootSessionUuid'] as String,
      branchFromMessageUuid: row['branchFromMessageUuid'] as String?,
      remoteId: row['remoteId'] as String?,
      needsSync: (row['needsSync'] as int?) == 1,
    );
  }

  Future<LocalMessage> _messageFromRow(Map<String, dynamic> row) async {
    final decryptedText = await _decryptString(row['text'] as String);
    return LocalMessage(
      messageUuid: row['messageUuid'] as String,
      sessionUuid: row['sessionUuid'] as String,
      parentMessageUuid: row['parentMessageUuid'] as String?,
      sender: row['sender'] as String,
      text: decryptedText,
      createdAt: row['createdAt'] as int,
    );
  }

  Future<String?> _getSessionHead(String sessionUuid) async {
    if (_sessionHeads.containsKey(sessionUuid)) {
      return _sessionHeads[sessionUuid];
    }

    final lastMessage = await getLastMessage(sessionUuid);
    if (lastMessage != null) {
      _sessionHeads[sessionUuid] = lastMessage.messageUuid;
      return lastMessage.messageUuid;
    }

    final session = await getSession(sessionUuid);
    final head = session?.branchFromMessageUuid;
    _sessionHeads[sessionUuid] = head;
    return head;
  }

  void setSessionHead(String sessionUuid, String? messageUuid) {
    _sessionHeads[sessionUuid] = messageUuid;
  }

  // Session operations
  Future<String> insertSession(
    String title, {
    String? rootSessionUuid,
    String? branchFromMessageUuid,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final sessionUuid = _uuid.v4();
    final rootUuid = rootSessionUuid ?? sessionUuid;

    final encryptedTitle = await _encryptString(title);
    await db.insert(sessionsTable, {
      'sessionUuid': sessionUuid,
      'title': encryptedTitle,
      'createdAt': now,
      'updatedAt': now,
      'rootSessionUuid': rootUuid,
      'branchFromMessageUuid': branchFromMessageUuid,
      'needsSync': 1,
    });

    _sessionHeads[sessionUuid] = branchFromMessageUuid;
    return sessionUuid;
  }

  Future<void> updateSession(LocalSession session) async {
    final db = await database;
    final values = session.toMap();
    values['title'] = await _encryptString(session.title);
    await db.update(
      sessionsTable,
      values,
      where: 'sessionUuid = ?',
      whereArgs: [session.sessionUuid],
    );
  }

  Future<void> upsertSessionFromRemote({
    required String sessionUuid,
    required String title,
    required int createdAt,
    required int updatedAt,
    required String rootSessionUuid,
    String? branchFromMessageUuid,
  }) async {
    final existing = await getSession(sessionUuid);
    if (existing == null) {
      final db = await database;
      final encryptedTitle = await _encryptString(title);
      await db.insert(sessionsTable, {
        'sessionUuid': sessionUuid,
        'title': encryptedTitle,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'rootSessionUuid': rootSessionUuid,
        'branchFromMessageUuid': branchFromMessageUuid,
        'remoteId': sessionUuid,
        'needsSync': 0,
      });
      _sessionHeads[sessionUuid] = branchFromMessageUuid;
      return;
    }

    final resolvedCreatedAt =
        existing.createdAt < createdAt ? existing.createdAt : createdAt;
    final resolvedUpdatedAt =
        existing.updatedAt > updatedAt ? existing.updatedAt : updatedAt;

    await updateSession(existing.copyWith(
      title: title,
      createdAt: resolvedCreatedAt,
      updatedAt: resolvedUpdatedAt,
      rootSessionUuid: rootSessionUuid,
      branchFromMessageUuid: branchFromMessageUuid,
      remoteId: existing.remoteId ?? sessionUuid,
      needsSync: existing.needsSync,
    ));
  }

  Future<void> markSessionForSync(String sessionUuid) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      sessionsTable,
      {'needsSync': 1, 'updatedAt': now},
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
    );
  }

  Future<LocalSession?> getSession(String sessionUuid) async {
    final db = await database;
    final rows = await db.query(
      sessionsTable,
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
    );
    if (rows.isEmpty) return null;
    return _sessionFromRow(rows.first);
  }

  Future<List<LocalSession>> getAllSessions() async {
    final db = await database;
    final rows = await db.query(sessionsTable, orderBy: 'updatedAt DESC');
    final sessions = <LocalSession>[];
    for (final row in rows) {
      sessions.add(await _sessionFromRow(row));
    }
    return sessions;
  }

  Future<List<LocalSession>> getSessionsByRoot(String rootSessionUuid) async {
    final db = await database;
    final rows = await db.query(
      sessionsTable,
      where: 'rootSessionUuid = ?',
      whereArgs: [rootSessionUuid],
    );
    final sessions = <LocalSession>[];
    for (final row in rows) {
      sessions.add(await _sessionFromRow(row));
    }
    return sessions;
  }

  Future<List<LocalSession>> getSessionsNeedingSync() async {
    final db = await database;
    final rows = await db.query(
      sessionsTable,
      where: 'needsSync = ?',
      whereArgs: [1],
    );
    final sessions = <LocalSession>[];
    for (final row in rows) {
      sessions.add(await _sessionFromRow(row));
    }
    return sessions;
  }

  Future<Map<String, String>> getBranchSelections(
    String rootSessionUuid,
  ) async {
    final db = await database;
    final rows = await db.query(
      branchSelectionsTable,
      where: 'rootSessionUuid = ?',
      whereArgs: [rootSessionUuid],
    );
    final selections = <String, String>{};
    for (final row in rows) {
      selections[row['selectionKey'] as String] =
          row['selectedMessageUuid'] as String;
    }
    return selections;
  }

  Future<Map<String, Map<String, String>>> getBranchSelectionsForRoots(
    List<String> rootSessionUuids,
  ) async {
    if (rootSessionUuids.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(rootSessionUuids.length, '?').join(',');
    final rows = await db.query(
      branchSelectionsTable,
      where: 'rootSessionUuid IN ($placeholders)',
      whereArgs: rootSessionUuids,
    );
    final selectionsByRoot = <String, Map<String, String>>{};
    for (final row in rows) {
      final rootUuid = row['rootSessionUuid'] as String;
      final selectionKey = row['selectionKey'] as String;
      final selectedMessageUuid = row['selectedMessageUuid'] as String;
      selectionsByRoot.putIfAbsent(rootUuid, () => {})[selectionKey] =
          selectedMessageUuid;
    }
    return selectionsByRoot;
  }

  Future<void> upsertBranchSelection(
    String rootSessionUuid,
    String selectionKey,
    String selectedMessageUuid,
  ) async {
    final db = await database;
    await db.insert(
      branchSelectionsTable,
      {
        'rootSessionUuid': rootSessionUuid,
        'selectionKey': selectionKey,
        'selectedMessageUuid': selectedMessageUuid,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteBranchSelectionsForRoot(String rootSessionUuid) async {
    final db = await database;
    await db.delete(
      branchSelectionsTable,
      where: 'rootSessionUuid = ?',
      whereArgs: [rootSessionUuid],
    );
  }

  Future<void> deleteSession(String sessionUuid) async {
    final db = await database;
    final rows = await db.query(
      sessionsTable,
      columns: ['rootSessionUuid'],
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final rootSessionUuid = rows.first['rootSessionUuid'] as String;

    // Messages are deleted by CASCADE
    await db.delete(
      sessionsTable,
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
    );
    _sessionHeads.remove(sessionUuid);

    final remaining = await db.query(
      sessionsTable,
      columns: ['sessionUuid'],
      where: 'rootSessionUuid = ?',
      whereArgs: [rootSessionUuid],
      limit: 1,
    );
    if (remaining.isEmpty) {
      await deleteBranchSelectionsForRoot(rootSessionUuid);
    }
  }

  // Message operations
  Future<String> insertMessage(
    String sessionUuid,
    String sender,
    String text, {
    String? parentMessageUuid,
    bool useSessionHeadWhenParentNull = true,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final messageUuid = _uuid.v4();
    final resolvedParentMessageUuid = parentMessageUuid ??
        (useSessionHeadWhenParentNull
            ? await _getSessionHead(sessionUuid)
            : null);

    final encryptedText = await _encryptString(text);
    await db.insert(messagesTable, {
      'messageUuid': messageUuid,
      'sessionUuid': sessionUuid,
      'parentMessageUuid': resolvedParentMessageUuid,
      'sender': sender,
      'text': encryptedText,
      'createdAt': now,
    });

    _sessionHeads[sessionUuid] = messageUuid;

    // Update session's updatedAt and mark for sync
    await db.update(
      sessionsTable,
      {'updatedAt': now, 'needsSync': 1},
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
    );

    return messageUuid;
  }

  Future<void> updateMessageText(String messageUuid, String text) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      columns: ['sessionUuid'],
      where: 'messageUuid = ?',
      whereArgs: [messageUuid],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final sessionUuid = rows.first['sessionUuid'] as String;
    final encryptedText = await _encryptString(text);
    await db.update(
      messagesTable,
      {'text': encryptedText},
      where: 'messageUuid = ?',
      whereArgs: [messageUuid],
    );

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      sessionsTable,
      {'updatedAt': now, 'needsSync': 1},
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
    );
  }

  Future<void> upsertMessageFromRemote({
    required String messageUuid,
    required String sessionUuid,
    String? parentMessageUuid,
    required String sender,
    required String text,
    required int createdAt,
  }) async {
    final db = await database;
    final encryptedText = await _encryptString(text);
    await db.insert(
      messagesTable,
      {
        'messageUuid': messageUuid,
        'sessionUuid': sessionUuid,
        'parentMessageUuid': parentMessageUuid,
        'sender': sender,
        'text': encryptedText,
        'createdAt': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> moveMessagesToSession(
    List<String> messageUuids,
    String newSessionUuid,
  ) async {
    if (messageUuids.isEmpty) return;

    final db = await database;
    final placeholders = List.filled(messageUuids.length, '?').join(',');
    await db.update(
      messagesTable,
      {'sessionUuid': newSessionUuid},
      where: 'messageUuid IN ($placeholders)',
      whereArgs: messageUuids,
    );
  }

  Future<void> deleteMessage(String messageUuid) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      columns: ['sessionUuid'],
      where: 'messageUuid = ?',
      whereArgs: [messageUuid],
      limit: 1,
    );
    if (rows.isEmpty) return;

    final sessionUuid = rows.first['sessionUuid'] as String;
    await db.delete(
      messagesTable,
      where: 'messageUuid = ?',
      whereArgs: [messageUuid],
    );

    final lastMessage = await getLastMessage(sessionUuid);
    if (lastMessage != null) {
      _sessionHeads[sessionUuid] = lastMessage.messageUuid;
      return;
    }

    final session = await getSession(sessionUuid);
    _sessionHeads[sessionUuid] = session?.branchFromMessageUuid;
  }

  Future<List<LocalMessage>> getMessages(String sessionUuid) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
      orderBy: 'createdAt ASC',
    );
    final messages = <LocalMessage>[];
    for (final row in rows) {
      messages.add(await _messageFromRow(row));
    }
    return messages;
  }

  Future<LocalMessage?> getLastMessage(String sessionUuid) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      where: 'sessionUuid = ?',
      whereArgs: [sessionUuid],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _messageFromRow(rows.first);
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete(messagesTable);
    await db.delete(sessionsTable);
    await db.delete(branchSelectionsTable);
    _sessionHeads.clear();
  }
}
