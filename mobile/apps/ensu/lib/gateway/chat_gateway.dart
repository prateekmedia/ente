import 'package:dio/dio.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/models/chat_entity.dart';

/// Error thrown when chat key is not found on server.
class ChatKeyNotFound implements Exception {
  final StackTrace? stackTrace;
  ChatKeyNotFound([this.stackTrace]);
}

/// Error thrown on unauthorized access.
class UnauthorizedError implements Exception {}

/// Gateway for chat API calls.
/// Uses the same /authenticator endpoints as Auth app.
class ChatGateway {
  late Dio _dio;

  // Default to production API
  static const String _baseUrl = "https://api.ente.io";

  ChatGateway() {
    _dio = Dio(BaseOptions(
      baseUrl: _baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'X-Client-Package': 'io.ente.auth',
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

  Future<void> createKey(String encKey, String header) async {
    await _dio.post(
      "/authenticator/key",
      data: {
        "encryptedKey": encKey,
        "header": header,
      },
    );
  }

  Future<ChatKey> getKey() async {
    try {
      final response = await _dio.get("/authenticator/key");
      return ChatKey.fromMap(response.data);
    } on DioException catch (e) {
      if (e.response != null && (e.response!.statusCode ?? 0) == 404) {
        throw ChatKeyNotFound(StackTrace.current);
      }
      rethrow;
    }
  }

  Future<ChatEntity> createEntity(String encryptedData, String header) async {
    final response = await _dio.post(
      "/authenticator/entity",
      data: {
        "encryptedData": encryptedData,
        "header": header,
      },
    );
    return ChatEntity.fromMap(response.data);
  }

  Future<void> updateEntity(
    String id,
    String encryptedData,
    String header,
  ) async {
    await _dio.put(
      "/authenticator/entity",
      data: {
        "id": id,
        "encryptedData": encryptedData,
        "header": header,
      },
    );
  }

  Future<void> deleteEntity(String id) async {
    await _dio.delete(
      "/authenticator/entity",
      queryParameters: {"id": id},
    );
  }

  Future<(List<ChatEntity>, int?)> getDiff(
    int sinceTime, {
    int limit = 500,
  }) async {
    try {
      final response = await _dio.get(
        "/authenticator/entity/diff",
        queryParameters: {
          "sinceTime": sinceTime,
          "limit": limit,
        },
      );
      final List<ChatEntity> entities = [];
      final diff = response.data["diff"] as List;
      final int? timestamp = response.data["timestamp"] as int?;
      for (var entry in diff) {
        entities.add(ChatEntity.fromMap(entry));
      }
      return (entities, timestamp);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw UnauthorizedError();
      }
      rethrow;
    }
  }
}
