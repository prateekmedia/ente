import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/models/chat_entity.dart';
import 'package:ente_network/network.dart';
import 'package:uuid/uuid.dart';

/// Error thrown when chat key is not found on server.
class ChatKeyNotFound implements Exception {
  final StackTrace? stackTrace;
  ChatKeyNotFound([this.stackTrace]);
}

/// Error thrown on unauthorized access.
class UnauthorizedError implements Exception {}

/// Gateway for llmchat chat API calls.
class ChatGateway {
  late Dio _dio;

  // Default to production API
  static const String _defaultBaseUrl = "https://api.ente.io";
  static const String _chatPath = "/llmchat/chat";
  static final Uuid _uuid = Uuid();

  ChatGateway() {
    final endpoint = Configuration.instance.getHttpEndpoint();
    _dio = Dio(BaseOptions(
      baseUrl: endpoint.isEmpty ? _defaultBaseUrl : endpoint,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'X-Client-Package': 'io.ente.ensu',
      },
    ));

    _dio.httpClientAdapter = Network.instance.enteDio.httpClientAdapter;
    _dio.interceptors.add(EnteRequestInterceptor(Configuration.instance));
  }

  void updateEndpoint(String endpoint) {
    final updated = endpoint.isEmpty ? _defaultBaseUrl : endpoint;
    _dio.options.baseUrl = updated;
    try {
      _dio.httpClientAdapter = Network.instance.enteDio.httpClientAdapter;
    } catch (_) {}
  }

  String _buildPath(String prefix, String path) {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    return "$prefix/$normalized";
  }

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function(String pathPrefix) call,
  ) async {
    try {
      return await call(_chatPath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }

  Future<void> createKey(String encKey, String header) async {
    await _request((pathPrefix) => _dio.post(
          _buildPath(pathPrefix, "key"),
          data: {
            "encrypted_key": encKey,
            "header": header,
          },
        ));
  }

  Future<ChatKey> getKey() async {
    try {
      final response = await _request(
        (pathPrefix) => _dio.get(_buildPath(pathPrefix, "key")),
      );
      return ChatKey.fromMap(response.data);
    } on DioException catch (e) {
      if (e.response != null && (e.response!.statusCode ?? 0) == 404) {
        throw ChatKeyNotFound(StackTrace.current);
      }
      if (e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }

  Future<void> upsertSession(
    String sessionUuid,
    String encryptedData,
    String header, {
    required String rootSessionUuid,
    String? branchFromMessageUuid,
    int? createdAt,
  }) async {
    await _request((pathPrefix) => _dio.post(
          _buildPath(pathPrefix, "session"),
          data: {
            "session_uuid": sessionUuid,
            "root_session_uuid": rootSessionUuid,
            if (branchFromMessageUuid != null)
              "branch_from_message_uuid": branchFromMessageUuid,
            if (createdAt != null) "created_at": createdAt,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
  }

  Future<void> upsertMessage(
    String messageUuid,
    String sessionUuid,
    String? parentMessageUuid,
    String encryptedData,
    String header, {
    required String sender,
    required List<Map<String, dynamic>> attachments,
    int? createdAt,
  }) async {
    await _request((pathPrefix) => _dio.post(
          _buildPath(pathPrefix, "message"),
          data: {
            "message_uuid": messageUuid,
            "session_uuid": sessionUuid,
            "parent_message_uuid": parentMessageUuid,
            "sender": sender,
            "attachments": attachments,
            if (createdAt != null) "created_at": createdAt,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
  }

  Future<ChatEntity> createEntity(String encryptedData, String header) async {
    final sessionUuid = _uuid.v4();
    final response = await _request((pathPrefix) => _dio.post(
          _buildPath(pathPrefix, "session"),
          data: {
            "session_uuid": sessionUuid,
            "root_session_uuid": sessionUuid,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
    return ChatEntity.fromMap(response.data);
  }

  Future<void> updateEntity(
    String id,
    String encryptedData,
    String header,
  ) async {
    await _request((pathPrefix) => _dio.post(
          _buildPath(pathPrefix, "session"),
          data: {
            "session_uuid": id,
            "root_session_uuid": id,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
  }

  Future<void> deleteSession(String sessionUuid) async {
    await _request((pathPrefix) => _dio.delete(
          _buildPath(pathPrefix, "session"),
          queryParameters: {"id": sessionUuid},
        ));
  }

  Future<void> deleteMessage(String messageUuid) async {
    await _request((pathPrefix) => _dio.delete(
          _buildPath(pathPrefix, "message"),
          queryParameters: {"id": messageUuid},
        ));
  }

  Future<void> uploadAttachment(
    String attachmentId,
    Uint8List encryptedBytes,
  ) async {
    await _request((pathPrefix) => _dio.put(
          _buildPath(pathPrefix, "attachment/$attachmentId"),
          data: Stream.fromIterable([encryptedBytes]),
          options: Options(
            contentType: 'application/octet-stream',
            headers: {
              Headers.contentLengthHeader: encryptedBytes.length,
            },
          ),
        ));
  }

  Future<Uint8List> downloadAttachment(String attachmentId) async {
    final response = await _request<List<int>>(
      (pathPrefix) => _dio.get<List<int>>(
        _buildPath(pathPrefix, "attachment/$attachmentId"),
        options: Options(responseType: ResponseType.bytes),
      ),
    );

    final bytes = response.data;
    if (bytes == null) {
      throw StateError('Attachment download failed: empty response');
    }
    return Uint8List.fromList(bytes);
  }

  Future<ChatDiff> getDiff(
    int sinceTime, {
    int limit = 500,
  }) async {
    try {
      final response = await _request((pathPrefix) => _dio.get(
            _buildPath(pathPrefix, "diff"),
            queryParameters: {
              "sinceTime": sinceTime,
              "limit": limit,
            },
          ));

      final sessions = <ChatEntity>[];
      final messages = <ChatEntity>[];
      final sessionTombstones = <ChatEntity>[];
      final messageTombstones = <ChatEntity>[];

      final sessionEntries = response.data["sessions"];
      if (sessionEntries is List) {
        for (final entry in sessionEntries) {
          sessions.add(ChatEntity.fromMap(
            Map<String, dynamic>.from(entry as Map),
          ));
        }
      }

      final messageEntries = response.data["messages"];
      if (messageEntries is List) {
        for (final entry in messageEntries) {
          messages.add(ChatEntity.fromMap(
            Map<String, dynamic>.from(entry as Map),
          ));
        }
      }

      final tombstones = response.data["tombstones"];
      if (tombstones is Map) {
        final sessionEntries = tombstones["sessions"];
        if (sessionEntries is List) {
          for (final entry in sessionEntries) {
            sessionTombstones.add(ChatEntity.fromMap(
              Map<String, dynamic>.from(entry as Map),
            ));
          }
        }

        final messageEntries = tombstones["messages"];
        if (messageEntries is List) {
          for (final entry in messageEntries) {
            messageTombstones.add(ChatEntity.fromMap(
              Map<String, dynamic>.from(entry as Map),
            ));
          }
        }
      }

      final int? timestamp = response.data["timestamp"] as int?;
      return ChatDiff(
        sessions: sessions,
        messages: messages,
        sessionTombstones: sessionTombstones,
        messageTombstones: messageTombstones,
        timestamp: timestamp,
      );
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }
}
