import 'package:dio/dio.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/models/chat_entity.dart';
import 'package:uuid/uuid.dart';

/// Error thrown when chat key is not found on server.
class ChatKeyNotFound implements Exception {
  final StackTrace? stackTrace;
  ChatKeyNotFound([this.stackTrace]);
}

/// Error thrown on unauthorized access.
class UnauthorizedError implements Exception {}

/// Gateway for ensu chat API calls.
/// Targets the dedicated /ensu/chat endpoints.
class ChatGateway {
  late Dio _dio;

  // Default to production API
  static const String _defaultBaseUrl = "https://api.ente.io";
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

    // Add auth interceptor
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final token = Configuration.instance.getToken();
        if (token != null) {
          options.headers['X-Auth-Token'] = token;
        }
        return handler.next(options);
      },
    ));
  }

  void updateEndpoint(String endpoint) {
    final updated = endpoint.isEmpty ? _defaultBaseUrl : endpoint;
    _dio.options.baseUrl = updated;
  }

  Future<Response<T>> _request<T>(Future<Response<T>> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }

  Future<void> createKey(String encKey, String header) async {
    await _request(() => _dio.post(
          "/ensu/chat/key",
          data: {
            "encrypted_key": encKey,
            "header": header,
          },
        ));
  }

  Future<ChatKey> getKey() async {
    try {
      final response = await _dio.get("/ensu/chat/key");
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
    String header,
  ) async {
    await _request(() => _dio.post(
          "/ensu/chat/session",
          data: {
            "session_uuid": sessionUuid,
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
    String header,
  ) async {
    await _request(() => _dio.post(
          "/ensu/chat/message",
          data: {
            "message_uuid": messageUuid,
            "session_uuid": sessionUuid,
            "parent_message_uuid": parentMessageUuid,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
  }

  Future<ChatEntity> createEntity(String encryptedData, String header) async {
    final sessionUuid = _uuid.v4();
    final response = await _request(() => _dio.post(
          "/ensu/chat/session",
          data: {
            "session_uuid": sessionUuid,
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
    await _request(() => _dio.post(
          "/ensu/chat/session",
          data: {
            "session_uuid": id,
            "encrypted_data": encryptedData,
            "header": header,
          },
        ));
  }

  Future<void> deleteEntity(String id) async {
    await _request(() => _dio.delete(
          "/ensu/chat/session",
          queryParameters: {"id": id},
        ));
  }

  Future<ChatDiff> getDiff(
    int sinceTime, {
    int limit = 500,
  }) async {
    try {
      final response = await _request(() => _dio.get(
            "/ensu/chat/diff",
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
