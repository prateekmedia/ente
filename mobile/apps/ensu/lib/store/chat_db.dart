import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Local chat session stored in SQLite.
class LocalSession {
  final int id;
  final String title;
  final int createdAt;
  final int updatedAt;
  final String? remoteId; // ID from server (null if never synced)
  final bool needsSync;

  const LocalSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.remoteId,
    this.needsSync = true,
  });

  LocalSession copyWith({
    int? id,
    String? title,
    int? createdAt,
    int? updatedAt,
    String? remoteId,
    bool? needsSync,
  }) {
    return LocalSession(
      id: id ?? this.id,
      title: title ?? this.title,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      remoteId: remoteId ?? this.remoteId,
      needsSync: needsSync ?? this.needsSync,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id == 0 ? null : id,
      'title': title,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      'remoteId': remoteId,
      'needsSync': needsSync ? 1 : 0,
    };
  }

  factory LocalSession.fromMap(Map<String, dynamic> map) {
    return LocalSession(
      id: map['id'] as int,
      title: map['title'] as String,
      createdAt: map['createdAt'] as int,
      updatedAt: map['updatedAt'] as int,
      remoteId: map['remoteId'] as String?,
      needsSync: (map['needsSync'] as int?) == 1,
    );
  }
}

/// Local chat message stored in SQLite.
class LocalMessage {
  final int id;
  final int sessionId;
  final String sender; // 'self' or 'other'
  final String text;
  final int createdAt;
  final double? tokensPerSecond; // null for user messages or if not calculated

  const LocalMessage({
    required this.id,
    required this.sessionId,
    required this.sender,
    required this.text,
    required this.createdAt,
    this.tokensPerSecond,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id == 0 ? null : id,
      'sessionId': sessionId,
      'sender': sender,
      'text': text,
      'createdAt': createdAt,
      'tokensPerSecond': tokensPerSecond,
    };
  }

  factory LocalMessage.fromMap(Map<String, dynamic> map) {
    return LocalMessage(
      id: map['id'] as int,
      sessionId: map['sessionId'] as int,
      sender: map['sender'] as String,
      text: map['text'] as String,
      createdAt: map['createdAt'] as int,
      tokensPerSecond: map['tokensPerSecond'] as double?,
    );
  }
}

/// Database for storing chat data locally.
class ChatDB {
  static const _databaseName = "ente.ensu.v2.db";
  static const _databaseVersion = 2;
  static const sessionsTable = 'sessions';
  static const messagesTable = 'messages';

  ChatDB._privateConstructor();
  static final ChatDB instance = ChatDB._privateConstructor();

  static Future<Database>? _dbFuture;

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
    debugPrint("ChatDB path: $path");

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

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $sessionsTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        title TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL,
        remoteId TEXT,
        needsSync INTEGER DEFAULT 1,
        UNIQUE(remoteId)
      )
    ''');

    await db.execute('''
      CREATE TABLE $messagesTable (
        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
        sessionId INTEGER NOT NULL,
        sender TEXT NOT NULL,
        text TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        tokensPerSecond REAL,
        FOREIGN KEY (sessionId) REFERENCES $sessionsTable(id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_messages_session ON $messagesTable(sessionId)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // Add tokensPerSecond column if upgrading from v1
      await db.execute('''
        ALTER TABLE $messagesTable ADD COLUMN tokensPerSecond REAL
      ''');
    }
  }

  // Session operations
  Future<int> insertSession(String title) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    return await db.insert(sessionsTable, {
      'title': title,
      'createdAt': now,
      'updatedAt': now,
      'needsSync': 1,
    });
  }

  Future<void> updateSession(LocalSession session) async {
    final db = await database;
    await db.update(
      sessionsTable,
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  Future<void> markSessionForSync(int sessionId) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      sessionsTable,
      {'needsSync': 1, 'updatedAt': now},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<LocalSession?> getSession(int id) async {
    final db = await database;
    final rows = await db.query(sessionsTable, where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return LocalSession.fromMap(rows.first);
  }

  Future<List<LocalSession>> getAllSessions() async {
    final db = await database;
    final rows = await db.query(sessionsTable, orderBy: 'updatedAt DESC');
    return rows.map((r) => LocalSession.fromMap(r)).toList();
  }

  Future<List<LocalSession>> getSessionsNeedingSync() async {
    final db = await database;
    final rows = await db.query(
      sessionsTable,
      where: 'needsSync = ?',
      whereArgs: [1],
    );
    return rows.map((r) => LocalSession.fromMap(r)).toList();
  }

  Future<void> deleteSession(int id) async {
    final db = await database;
    // Messages are deleted by CASCADE
    await db.delete(sessionsTable, where: 'id = ?', whereArgs: [id]);
  }

  // Message operations
  Future<int> insertMessage(
    int sessionId,
    String sender,
    String text, {
    double? tokensPerSecond,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final msgId = await db.insert(messagesTable, {
      'sessionId': sessionId,
      'sender': sender,
      'text': text,
      'createdAt': now,
      'tokensPerSecond': tokensPerSecond,
    });

    // Update session's updatedAt and mark for sync
    await db.update(
      sessionsTable,
      {'updatedAt': now, 'needsSync': 1},
      where: 'id = ?',
      whereArgs: [sessionId],
    );

    return msgId;
  }

  Future<List<LocalMessage>> getMessages(int sessionId) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'createdAt ASC',
    );
    return rows.map((r) => LocalMessage.fromMap(r)).toList();
  }

  Future<LocalMessage?> getLastMessage(int sessionId) async {
    final db = await database;
    final rows = await db.query(
      messagesTable,
      where: 'sessionId = ?',
      whereArgs: [sessionId],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return LocalMessage.fromMap(rows.first);
  }

  Future<void> clearAllData() async {
    final db = await database;
    await db.delete(messagesTable);
    await db.delete(sessionsTable);
  }
}
