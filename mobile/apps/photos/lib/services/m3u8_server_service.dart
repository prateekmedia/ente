import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

class M3u8ServerService {
  static final M3u8ServerService _instance = M3u8ServerService._internal();
  factory M3u8ServerService() => _instance;
  M3u8ServerService._internal();
  
  static M3u8ServerService get instance => _instance;
  
  final Logger _logger = Logger('M3u8ServerService');
  HttpServer? _server;
  int? _port;
  final Map<String, File> _fileMap = {};
  
  Future<void> initialize() async {
    if (_server != null) {
      _logger.info('M3U8 server already initialized on port $_port');
      return;
    }
    
    try {
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      _port = _server!.port;
      
      _logger.info('M3U8 server started on port $_port');
      
      _server!.listen((HttpRequest request) {
        _handleRequest(request);
      });
    } catch (e, s) {
      _logger.severe('Failed to start M3U8 server', e, s);
      rethrow;
    }
  }
  
  void _handleRequest(HttpRequest request) async {
    final pathSegments = request.uri.pathSegments;
    
    if (pathSegments.isEmpty) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('Not Found');
      await request.response.close();
      return;
    }
    
    final fileId = pathSegments.first;
    final file = _fileMap[fileId];
    
    if (file == null || !await file.exists()) {
      request.response
        ..statusCode = HttpStatus.notFound
        ..write('File not found');
      await request.response.close();
      return;
    }
    
    try {
      final extension = path.extension(file.path).toLowerCase();
      
      if (extension == '.m3u8') {
        request.response.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
        
        final content = await file.readAsString();
        final modifiedContent = _rewriteM3u8Content(content, fileId, file.parent.path);
        
        request.response
          ..statusCode = HttpStatus.ok
          ..write(modifiedContent);
      } else if (extension == '.ts') {
        request.response.headers.contentType = ContentType('video', 'mp2t');
        
        final bytes = await file.readAsBytes();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentLengthHeader, bytes.length)
          ..add(bytes);
      } else {
        final bytes = await file.readAsBytes();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.set(HttpHeaders.contentLengthHeader, bytes.length)
          ..add(bytes);
      }
      
      await request.response.close();
      _logger.fine('Served file: ${file.path}');
    } catch (e, s) {
      _logger.severe('Error serving file: ${file.path}', e, s);
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Internal Server Error');
      await request.response.close();
    }
  }
  
  String _rewriteM3u8Content(String content, String fileId, String basePath) {
    final lines = content.split('\n');
    final modifiedLines = <String>[];
    
    for (final line in lines) {
      if (line.trim().isEmpty || line.startsWith('#')) {
        modifiedLines.add(line);
      } else if (line.endsWith('.ts') || line.endsWith('.m3u8')) {
        final filename = path.basename(line);
        final segmentPath = path.join(basePath, filename);
        final segmentFile = File(segmentPath);
        
        final segmentId = _registerFile(segmentFile);
        modifiedLines.add('http://localhost:$_port/$segmentId');
      } else {
        modifiedLines.add(line);
      }
    }
    
    return modifiedLines.join('\n');
  }
  
  String registerM3u8File(String filePath) {
    final file = File(filePath);
    return _registerFile(file);
  }
  
  String _registerFile(File file) {
    final fileId = '${file.path.hashCode}_${DateTime.now().millisecondsSinceEpoch}';
    _fileMap[fileId] = file;
    
    Timer(const Duration(minutes: 5), () {
      _fileMap.remove(fileId);
      _logger.fine('Removed cached file mapping for: $fileId');
    });
    
    return fileId;
  }
  
  String? getHttpUrlForM3u8(String filePath) {
    if (_server == null || _port == null) {
      _logger.warning('M3U8 server not initialized');
      return null;
    }
    
    final fileId = registerM3u8File(filePath);
    return 'http://localhost:$_port/$fileId';
  }
  
  void cleanupFileMapping(String filePath) {
    _fileMap.removeWhere((key, file) => file.path == filePath);
  }
  
  Future<void> dispose() async {
    await _server?.close(force: true);
    _server = null;
    _port = null;
    _fileMap.clear();
    _logger.info('M3U8 server stopped');
  }
}