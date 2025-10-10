import 'dart:io';

import 'package:dio/dio.dart';
import "package:native_dio_adapter/native_dio_adapter.dart";
import 'package:package_info_plus/package_info_plus.dart';
import "package:photos/core/configuration.dart";
import "package:photos/core/event_bus.dart";
import 'package:photos/core/network/ente_interceptor.dart';
import "package:photos/events/endpoint_updated_event.dart";
import "package:ua_client_hints/ua_client_hints.dart";

class NetworkClient {
  late Dio _dio;
  late Dio _enteDio;
  static const kConnectTimeout = 15;

  Future<void> init(
    PackageInfo packageInfo, {
    Dio? dio,
    Dio? enteDio,
  }) async {
    final String ua = await userAgent();
    final endpoint = Configuration.instance.getHttpEndpoint();

    // Use provided Dio instances for testing, or create new ones
    _dio = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: kConnectTimeout),
            headers: {
              HttpHeaders.userAgentHeader: ua,
              'X-Client-Version': packageInfo.version,
              'X-Client-Package': packageInfo.packageName,
            },
          ),
        );
    _enteDio = enteDio ??
        Dio(
          BaseOptions(
            baseUrl: endpoint,
            connectTimeout: const Duration(seconds: kConnectTimeout),
            headers: {
              HttpHeaders.userAgentHeader: ua,
              'X-Client-Version': packageInfo.version,
              'X-Client-Package': packageInfo.packageName,
            },
          ),
        );

    // Only use NativeAdapter on iOS. On Android, Cronet (used by NativeAdapter)
    // doesn't work in background tasks on Android 15, causing CronetException
    // during background sync. Use default adapter on Android instead.
    if (Platform.isIOS && enteDio == null) {
      _enteDio.httpClientAdapter = NativeAdapter();
    }

    _setupInterceptors(endpoint);

    Bus.instance.on<EndpointUpdatedEvent>().listen((event) {
      final endpoint = Configuration.instance.getHttpEndpoint();
      _enteDio.options.baseUrl = endpoint;
      _setupInterceptors(endpoint);
    });
  }

  void _setupInterceptors(String endpoint) {
    _enteDio.interceptors.clear();
    _enteDio.interceptors.add(EnteRequestInterceptor(endpoint));
  }

  NetworkClient._privateConstructor();

  static NetworkClient instance = NetworkClient._privateConstructor();

  Dio getDio() => _dio;

  Dio get enteDio => _enteDio;
}
