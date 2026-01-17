import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ensu/core/configuration.dart';
import 'package:ensu/models/chat_attachment.dart';
import 'package:ente_crypto_api/ente_crypto_api.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
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
  final List<ChatAttachment> attachments;
  final int createdAt;

  const LocalMessage({
    required this.messageUuid,
    required this.sessionUuid,
    this.parentMessageUuid,
    required this.sender,
    required this.text,
    this.attachments = const [],
    required this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'messageUuid': messageUuid,
      'sessionUuid': sessionUuid,
      'parentMessageUuid': parentMessageUuid,
      'sender': sender,
      'text': text,
      'attachments':
          attachments.map((attachment) => attachment.toJson()).toList(),
      'createdAt': createdAt,
    };
  }

  factory LocalMessage.fromMap(Map<String, dynamic> map) {
    final attachmentsValue = map['attachments'];
    var attachments = const <ChatAttachment>[];
    if (attachmentsValue is List) {
      attachments = attachmentsValue
          .whereType<Map>()
          .map((entry) =>
              ChatAttachment.fromJson(Map<String, dynamic>.from(entry)))
          .toList();
    }

    return LocalMessage(
      messageUuid: map['messageUuid'] as String,
      sessionUuid: map['sessionUuid'] as String,
      parentMessageUuid: map['parentMessageUuid'] as String?,
      sender: map['sender'] as String,
      text: map['text'] as String,
      attachments: attachments,
      createdAt: map['createdAt'] as int,
    );
  }
}

class ChatSearchHit {
  final String messageUuid;
  final String sessionUuid;
  final String rootSessionUuid;
  final String sender;
  final int createdAt;
  final String snippet;

  const ChatSearchHit({
    required this.messageUuid,
    required this.sessionUuid,
    required this.rootSessionUuid,
    required this.sender,
    required this.createdAt,
    required this.snippet,
  });

  Map<String, dynamic> toJson() {
    return {
      'messageUuid': messageUuid,
      'sessionUuid': sessionUuid,
      'rootSessionUuid': rootSessionUuid,
      'sender': sender,
      'createdAt': createdAt,
      'snippet': snippet,
    };
  }
}

class PendingDeletion {
  final String entityType;
  final String entityId;
  final int createdAt;

  const PendingDeletion({
    required this.entityType,
    required this.entityId,
    required this.createdAt,
  });

  factory PendingDeletion.fromMap(Map<String, dynamic> map) {
    return PendingDeletion(
      entityType: map['entityType'] as String,
      entityId: map['entityId'] as String,
      createdAt: map['createdAt'] as int,
    );
  }
}

/// Database for storing chat data locally.
class ChatDB {
  static const _databaseName = "ente.ensu.v2.db";
  static const _databaseVersion = 3;
  static const _dbPasswordPrefix = 'ente_chat_db_v1:';
  static const _encryptedMigrationSuffix = '.enc';
  static const _plaintextBackupSuffix = '.unencrypted';
  static const sessionsTable = 'sessions';
  static const messagesTable = 'messages';
  static const messageTokenIndexTable = 'message_token_index';
  static const attachmentsTable = 'chat_attachments';
  static const branchSelectionsTable = 'branchSelections';
  static const deletionQueueTable = 'deletionQueue';
  static const deletionTypeSession = 'session';
  static const deletionTypeMessage = 'message';
  static const _encryptionPrefix = 'enc:v1:';
  static final Uuid _uuid = Uuid();
  final Map<String, String?> _sessionHeads = {};
  Uint8List? _localKey;
  Future<Uint8List>? _localKeyFuture;
  Future<void>? _searchIndexBackfillFuture;

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

  String _encodeAttachments(List<ChatAttachment> attachments) {
    return jsonEncode(
      attachments.map((attachment) => attachment.toJson()).toList(),
    );
  }

  List<ChatAttachment> _decodeAttachments(String value) {
    if (value.isEmpty) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map((entry) =>
                ChatAttachment.fromJson(Map<String, dynamic>.from(entry)))
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  static final RegExp _searchTokenPattern =
      RegExp(r'[a-z0-9]+', caseSensitive: false);
  static const Set<String> _searchStopWords = {
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'but',
    'by',
    'for',
    'from',
    'has',
    'have',
    'i',
    'in',
    'is',
    'it',
    'me',
    'my',
    'of',
    'on',
    'or',
    'that',
    'the',
    'this',
    'to',
    'was',
    'we',
    'with',
    'you',
    'your',
  };

  Iterable<String> _tokenizeForSearch(String text) sync* {
    if (text.isEmpty) {
      return;
    }

    final lower = text.toLowerCase();
    for (final match in _searchTokenPattern.allMatches(lower)) {
      final token = match.group(0);
      if (token == null) {
        continue;
      }
      final trimmed = token.trim();
      if (trimmed.length < 2) {
        continue;
      }
      if (_searchStopWords.contains(trimmed)) {
        continue;
      }
      if (trimmed.length > 40) {
        continue;
      }
      yield trimmed;
    }
  }

  int _hashTokenWithKey(String token, Uint8List key) {
    var hash = 0x811c9dc5;

    // Salt with 4 bytes from the offline chat key.
    final limit = key.length < 4 ? key.length : 4;
    for (var i = 0; i < limit; i++) {
      hash ^= key[i];
      hash = (hash * 0x01000193) & 0xffffffff;
    }

    for (final codeUnit in token.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }

    // Keep it positive for SQLite INTEGER.
    return hash & 0x7fffffff;
  }

  Future<Set<int>> _tokenHashesForText(String text) async {
    final key = await _getLocalKey();
    final hashes = <int>{};
    for (final token in _tokenizeForSearch(text)) {
      hashes.add(_hashTokenWithKey(token, key));
    }
    return hashes;
  }

  Future<void> _indexMessageTokens(
    DatabaseExecutor db,
    String messageUuid,
    String text,
  ) async {
    final hashes = await _tokenHashesForText(text);
    if (hashes.isEmpty) {
      return;
    }

    final batch = db.batch();
    for (final tokenHash in hashes) {
      batch.insert(
        messageTokenIndexTable,
        {
          'tokenHash': tokenHash,
          'messageUuid': messageUuid,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _deleteIndexedTokens(
      DatabaseExecutor db, String messageUuid) async {
    await db.delete(
      messageTokenIndexTable,
      where: 'messageUuid = ?',
      whereArgs: [messageUuid],
    );
  }

  ChatAttachmentUploadState _parseUploadState(String? value) {
    if (value == null || value.isEmpty) {
      return ChatAttachmentUploadState.pending;
    }
    return ChatAttachmentUploadState.values.firstWhere(
      (state) => state.name == value,
      orElse: () => ChatAttachmentUploadState.pending,
    );
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

  Future<String> _getDatabasePassword() async {
    final key = await _getLocalKey();
    return '$_dbPasswordPrefix${CryptoUtil.bin2base64(key)}';
  }

  Future<Database> _openEncryptedDatabase(String path) async {
    final password = await _getDatabasePassword();
    return sqlcipher.openDatabase(
      path,
      password: password,
      version: _databaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _copyTable(
    Database source,
    Database destination,
    String tableName,
  ) async {
    try {
      final rows = await source.query(tableName);
      if (rows.isEmpty) {
        return;
      }
      final batch = destination.batch();
      for (final row in rows) {
        batch.insert(
          tableName,
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (e, s) {
      _logger.warning('Skipping migration for $tableName', e, s);
    }
  }

  Future<void> _copyTables(Database source, Database destination) async {
    await _copyTable(source, destination, sessionsTable);
    await _copyTable(source, destination, messagesTable);
    await _copyTable(source, destination, messageTokenIndexTable);
    await _copyTable(source, destination, attachmentsTable);
    await _copyTable(source, destination, branchSelectionsTable);
    await _copyTable(source, destination, deletionQueueTable);
  }

  Future<Database?> _migratePlaintextDatabase(String path) async {
    final dbFile = File(path);
    if (!await dbFile.exists()) {
      return null;
    }

    final tempPath = '$path$_encryptedMigrationSuffix';
    final tempFile = File(tempPath);
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
    Database? plaintextDb;
    Database? encryptedDb;

    try {
      plaintextDb = await sqflite.openDatabase(path, readOnly: true);
      encryptedDb = await _openEncryptedDatabase(tempPath);
      await _copyTables(plaintextDb, encryptedDb);
    } catch (e, s) {
      _logger.warning('Failed to migrate chat DB to encrypted format', e, s);
      return null;
    } finally {
      await plaintextDb?.close();
      await encryptedDb?.close();
    }

    try {
      final backupPath = '$path$_plaintextBackupSuffix';
      final backupFile = File(backupPath);
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      await dbFile.rename(backupPath);
      await File(tempPath).rename(path);
    } catch (e, s) {
      _logger.warning('Failed to finalize chat DB encryption migration', e, s);
      return null;
    }

    return _openEncryptedDatabase(path);
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

    try {
      return await _openEncryptedDatabase(path);
    } catch (e, s) {
      _logger.warning(
          'Encrypted ChatDB open failed, attempting migration', e, s);
      final migrated = await _migratePlaintextDatabase(path);
      if (migrated != null) {
        return migrated;
      }
      _logger.warning('ChatDB migration failed; recreating encrypted DB', e, s);
      final dbFile = File(path);
      if (await dbFile.exists()) {
        await dbFile.delete();
      }
      return _openEncryptedDatabase(path);
    }
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

  Future<void> _createDeletionQueueTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE $deletionQueueTable (
        entityType TEXT NOT NULL,
        entityId TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        PRIMARY KEY (entityType, entityId)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_deletion_queue_created
      ON $deletionQueueTable(createdAt)
    ''');
  }

  Future<void> _createAttachmentsTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $attachmentsTable (
        attachmentId TEXT PRIMARY KEY NOT NULL,
        sessionUuid TEXT,
        size INTEGER NOT NULL,
        encryptedName TEXT,
        uploadState TEXT NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_chat_attachments_session
      ON $attachmentsTable(sessionUuid)
    ''');

    await db.execute('''
      CREATE INDEX idx_chat_attachments_state
      ON $attachmentsTable(uploadState)
    ''');
  }

  Future<void> _createMessageTokenIndexTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $messageTokenIndexTable (
        tokenHash INTEGER NOT NULL,
        messageUuid TEXT NOT NULL,
        PRIMARY KEY (tokenHash, messageUuid)
      )
    ''');

    await db.execute('''
      CREATE INDEX IF NOT EXISTS idx_message_token_index_message
      ON $messageTokenIndexTable(messageUuid)
    ''');

    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS trg_messages_delete_token_index
      AFTER DELETE ON $messagesTable
      BEGIN
        DELETE FROM $messageTokenIndexTable WHERE messageUuid = OLD.messageUuid;
      END;
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
        attachments TEXT,
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

    await _createMessageTokenIndexTable(db);
    await _createAttachmentsTable(db);
    await _createBranchSelectionsTable(db);
    await _createDeletionQueueTable(db);
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createSchema(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createAttachmentsTable(db);
    }
    if (oldVersion < 3) {
      await _createMessageTokenIndexTable(db);
    }
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

    final attachmentsValue = row['attachments'] as String?;
    final decryptedAttachments =
        attachmentsValue == null ? '' : await _decryptString(attachmentsValue);
    var attachments = _decodeAttachments(decryptedAttachments);

    if (attachments.isNotEmpty) {
      final states = await getAttachmentStates(
        attachments.map((attachment) => attachment.id).toList(),
      );
      attachments = attachments
          .map((attachment) => attachment.copyWith(
                uploadState:
                    states[attachment.id] ?? ChatAttachmentUploadState.uploaded,
              ))
          .toList();
    }

    return LocalMessage(
      messageUuid: row['messageUuid'] as String,
      sessionUuid: row['sessionUuid'] as String,
      parentMessageUuid: row['parentMessageUuid'] as String?,
      sender: row['sender'] as String,
      text: decryptedText,
      attachments: attachments,
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
    final now = DateTime.now().microsecondsSinceEpoch;
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
    final now = DateTime.now().microsecondsSinceEpoch;
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

  Future<void> enqueueDeletion(String entityType, String entityId) async {
    final db = await database;
    final now = DateTime.now().microsecondsSinceEpoch;
    await db.insert(
      deletionQueueTable,
      {
        'entityType': entityType,
        'entityId': entityId,
        'createdAt': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<List<PendingDeletion>> getPendingDeletions() async {
    final db = await database;
    final rows = await db.query(
      deletionQueueTable,
      orderBy: 'createdAt ASC',
    );
    return rows.map(PendingDeletion.fromMap).toList();
  }

  Future<void> removePendingDeletion(
    String entityType,
    String entityId,
  ) async {
    final db = await database;
    await db.delete(
      deletionQueueTable,
      where: 'entityType = ? AND entityId = ?',
      whereArgs: [entityType, entityId],
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

  // Attachment operations
  Future<void> insertPendingAttachment({
    required String attachmentId,
    required int size,
    String? encryptedName,
    String? sessionUuid,
  }) async {
    final db = await database;
    final now = DateTime.now().microsecondsSinceEpoch;
    await db.insert(
      attachmentsTable,
      {
        'attachmentId': attachmentId,
        'sessionUuid': sessionUuid,
        'size': size,
        'encryptedName': encryptedName,
        'uploadState': ChatAttachmentUploadState.pending.name,
        'updatedAt': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> markAttachmentUploading(String attachmentId) async {
    await _updateAttachmentState(
        attachmentId, ChatAttachmentUploadState.uploading);
  }

  Future<void> markAttachmentUploaded(String attachmentId) async {
    await _updateAttachmentState(
        attachmentId, ChatAttachmentUploadState.uploaded);
  }

  Future<void> markAttachmentFailed(String attachmentId) async {
    await _updateAttachmentState(
        attachmentId, ChatAttachmentUploadState.failed);
  }

  Future<void> _updateAttachmentState(
    String attachmentId,
    ChatAttachmentUploadState state,
  ) async {
    final db = await database;
    final now = DateTime.now().microsecondsSinceEpoch;
    await db.update(
      attachmentsTable,
      {
        'uploadState': state.name,
        'updatedAt': now,
      },
      where: 'attachmentId = ?',
      whereArgs: [attachmentId],
    );
  }

  Future<Map<String, ChatAttachmentUploadState>> getAttachmentStates(
    List<String> attachmentIds,
  ) async {
    if (attachmentIds.isEmpty) return {};
    final db = await database;
    final placeholders = List.filled(attachmentIds.length, '?').join(',');
    final rows = await db.query(
      attachmentsTable,
      columns: ['attachmentId', 'uploadState'],
      where: 'attachmentId IN ($placeholders)',
      whereArgs: attachmentIds,
    );
    final states = <String, ChatAttachmentUploadState>{};
    for (final row in rows) {
      final id = row['attachmentId'] as String;
      states[id] = _parseUploadState(row['uploadState'] as String?);
    }
    return states;
  }

  // Message operations
  Future<String> insertMessage(
    String sessionUuid,
    String sender,
    String text, {
    String? parentMessageUuid,
    bool useSessionHeadWhenParentNull = true,
    List<ChatAttachment> attachments = const [],
  }) async {
    final db = await database;
    final now = DateTime.now().microsecondsSinceEpoch;
    final messageUuid = _uuid.v4();
    final resolvedParentMessageUuid = parentMessageUuid ??
        (useSessionHeadWhenParentNull
            ? await _getSessionHead(sessionUuid)
            : null);

    final encryptedText = await _encryptString(text);
    final encryptedAttachments =
        await _encryptString(_encodeAttachments(attachments));

    await db.transaction((txn) async {
      await txn.insert(messagesTable, {
        'messageUuid': messageUuid,
        'sessionUuid': sessionUuid,
        'parentMessageUuid': resolvedParentMessageUuid,
        'sender': sender,
        'text': encryptedText,
        'attachments': encryptedAttachments,
        'createdAt': now,
      });

      await _indexMessageTokens(txn, messageUuid, text);

      // Update session's updatedAt and mark for sync
      await txn.update(
        sessionsTable,
        {'updatedAt': now, 'needsSync': 1},
        where: 'sessionUuid = ?',
        whereArgs: [sessionUuid],
      );
    });

    _sessionHeads[sessionUuid] = messageUuid;

    return messageUuid;
  }

  Future<void> updateMessageText(String messageUuid, String text) async {
    final db = await database;

    await db.transaction((txn) async {
      final rows = await txn.query(
        messagesTable,
        columns: ['sessionUuid'],
        where: 'messageUuid = ?',
        whereArgs: [messageUuid],
        limit: 1,
      );
      if (rows.isEmpty) return;

      final sessionUuid = rows.first['sessionUuid'] as String;
      final encryptedText = await _encryptString(text);
      await txn.update(
        messagesTable,
        {'text': encryptedText},
        where: 'messageUuid = ?',
        whereArgs: [messageUuid],
      );

      await _deleteIndexedTokens(txn, messageUuid);
      await _indexMessageTokens(txn, messageUuid, text);

      final now = DateTime.now().microsecondsSinceEpoch;
      await txn.update(
        sessionsTable,
        {'updatedAt': now, 'needsSync': 1},
        where: 'sessionUuid = ?',
        whereArgs: [sessionUuid],
      );
    });
  }

  Future<void> upsertMessageFromRemote({
    required String messageUuid,
    required String sessionUuid,
    String? parentMessageUuid,
    required String sender,
    required String text,
    List<ChatAttachment> attachments = const [],
    required int createdAt,
  }) async {
    final db = await database;
    final encryptedText = await _encryptString(text);
    final encryptedAttachments =
        await _encryptString(_encodeAttachments(attachments));

    await db.transaction((txn) async {
      await _deleteIndexedTokens(txn, messageUuid);

      await txn.insert(
        messagesTable,
        {
          'messageUuid': messageUuid,
          'sessionUuid': sessionUuid,
          'parentMessageUuid': parentMessageUuid,
          'sender': sender,
          'text': encryptedText,
          'attachments': encryptedAttachments,
          'createdAt': createdAt,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await _indexMessageTokens(txn, messageUuid, text);
    });
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

    await db.transaction((txn) async {
      await _deleteIndexedTokens(txn, messageUuid);
      await txn.delete(
        messagesTable,
        where: 'messageUuid = ?',
        whereArgs: [messageUuid],
      );
    });

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

  Future<void> startSearchIndexBackfill({int batchSize = 200}) {
    _searchIndexBackfillFuture ??= _backfillSearchIndex(batchSize: batchSize);
    return _searchIndexBackfillFuture!;
  }

  Future<void> waitForSearchIndexBackfill() async {
    final future = _searchIndexBackfillFuture;
    if (future != null) {
      await future;
    }
  }

  Future<void> _backfillSearchIndex({required int batchSize}) async {
    final db = await database;
    await _createMessageTokenIndexTable(db);

    final key = await _getLocalKey();

    var offset = 0;
    while (true) {
      final rows = await db.query(
        messagesTable,
        columns: ['messageUuid', 'text'],
        orderBy: 'createdAt ASC',
        limit: batchSize,
        offset: offset,
      );
      if (rows.isEmpty) {
        break;
      }

      final batch = db.batch();

      for (final row in rows) {
        final messageUuid = row['messageUuid'] as String;
        final encryptedText = row['text'] as String;
        final decryptedText = await _decryptStringWithKey(encryptedText, key);

        final hashes = <int>{};
        for (final token in _tokenizeForSearch(decryptedText)) {
          hashes.add(_hashTokenWithKey(token, key));
        }

        for (final tokenHash in hashes) {
          batch.insert(
            messageTokenIndexTable,
            {
              'tokenHash': tokenHash,
              'messageUuid': messageUuid,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }

      await batch.commit(noResult: true);

      offset += rows.length;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<List<ChatSearchHit>> searchMessages(
    String query, {
    String? rootSessionUuid,
    String? withinSessionUuid,
    int limit = 6,
    int contextChars = 180,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const [];
    }

    final tokens = _tokenizeForSearch(trimmed).toSet().toList();
    if (tokens.isEmpty) {
      return const [];
    }

    final key = await _getLocalKey();
    final tokenHashes = tokens.map((t) => _hashTokenWithKey(t, key)).toList();

    final db = await database;
    final placeholders = List.filled(tokenHashes.length, '?').join(',');

    final whereClauses = <String>[];
    final whereArgs = <Object?>[];
    if (withinSessionUuid != null && withinSessionUuid.isNotEmpty) {
      whereClauses.add('m.sessionUuid = ?');
      whereArgs.add(withinSessionUuid);
    }
    if (rootSessionUuid != null && rootSessionUuid.isNotEmpty) {
      whereClauses.add('s.rootSessionUuid = ?');
      whereArgs.add(rootSessionUuid);
    }

    final whereSql =
        whereClauses.isEmpty ? '' : 'WHERE ${whereClauses.join(' AND ')}';

    final candidateLimit = limit < 10 ? 200 : 500;

    final rows = await db.rawQuery(
      '''
      SELECT
        m.messageUuid,
        m.sessionUuid,
        s.rootSessionUuid,
        m.sender,
        m.createdAt,
        m.text
      FROM $messagesTable m
      JOIN $sessionsTable s ON s.sessionUuid = m.sessionUuid
      JOIN (
        SELECT messageUuid
        FROM $messageTokenIndexTable
        WHERE tokenHash IN ($placeholders)
        GROUP BY messageUuid
        HAVING COUNT(DISTINCT tokenHash) = ?
      ) idx ON idx.messageUuid = m.messageUuid
      $whereSql
      ORDER BY m.createdAt DESC
      LIMIT ?
      ''',
      [
        ...tokenHashes,
        tokenHashes.length,
        ...whereArgs,
        candidateLimit,
      ],
    );

    if (rows.isEmpty) {
      return const [];
    }

    final hits = <ChatSearchHit>[];
    for (final row in rows) {
      if (hits.length >= limit) {
        break;
      }

      final messageUuid = row['messageUuid'] as String;
      final sessionUuid = row['sessionUuid'] as String;
      final rootUuid = row['rootSessionUuid'] as String;
      final sender = row['sender'] as String;
      final createdAt = row['createdAt'] as int;
      final encryptedText = row['text'] as String;

      final decryptedText = await _decryptString(encryptedText);
      if (decryptedText.isEmpty) {
        continue;
      }

      final snippet = _buildSnippet(decryptedText, tokens, contextChars);
      if (snippet.isEmpty) {
        continue;
      }

      hits.add(ChatSearchHit(
        messageUuid: messageUuid,
        sessionUuid: sessionUuid,
        rootSessionUuid: rootUuid,
        sender: sender,
        createdAt: createdAt,
        snippet: snippet,
      ));
    }

    return hits;
  }

  String _buildSnippet(String text, List<String> tokens, int contextChars) {
    final lower = text.toLowerCase();

    var bestIndex = -1;
    var bestTokenLength = 0;
    for (final token in tokens) {
      final idx = lower.indexOf(token);
      if (idx == -1) {
        continue;
      }
      if (bestIndex == -1 || idx < bestIndex) {
        bestIndex = idx;
        bestTokenLength = token.length;
      }
    }

    if (bestIndex == -1) {
      return '';
    }

    for (final token in tokens) {
      if (!lower.contains(token)) {
        return '';
      }
    }

    final startIdx = bestIndex;
    final half = contextChars ~/ 2;
    var start = startIdx - half;
    if (start < 0) start = 0;
    var end = startIdx + bestTokenLength + half;
    if (end > text.length) end = text.length;

    var snippet = text.substring(start, end).trim();
    if (snippet.isEmpty) {
      return '';
    }

    if (start > 0) {
      snippet = '…$snippet';
    }
    if (end < text.length) {
      snippet = '$snippet…';
    }

    return snippet;
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete(messagesTable);
    await db.delete(messageTokenIndexTable);
    await db.delete(sessionsTable);
    await db.delete(attachmentsTable);
    await db.delete(branchSelectionsTable);
    await db.delete(deletionQueueTable);
    _sessionHeads.clear();
  }
}
