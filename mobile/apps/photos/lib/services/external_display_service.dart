import 'dart:async';
import 'dart:io';

import 'package:external_display_plugin/external_display_plugin.dart';
import 'package:logging/logging.dart';

import 'package:photos/models/external_display/video_lifecycle.dart';
import 'package:photos/models/external_display/video_session.dart';
import 'package:photos/models/file/file.dart';
import 'package:photos/service_locator.dart';
import 'package:photos/services/external_display/video_operation_queue.dart';
import 'package:photos/services/external_display/video_retry_manager.dart';
import 'package:photos/services/external_display/video_state_machine.dart';
import 'package:photos/services/video_preview_service.dart';
import 'package:photos/utils/file_util.dart';

class ExternalDisplayService {
  static final _logger = Logger("ExternalDisplayService");

  static const String _defaultLogoAsset = 'assets/external_display_couch.png';
  static const String _brandLogoAsset = 'assets/ente_photos_logo.png';
  static const String _defaultBackgroundColor = '#1a1a1a';

  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<VideoPlayerState>? _videoStateSubscription;

  bool _isConnected = false;
  VideoPlayerState? _currentVideoState;
  bool _isInitialized = false;
  EnteFile? _currentDisplayedFile;
  bool _lastKnownStreamMode = false;

  // Enhanced state management components
  final VideoStateMachine _stateMachine = VideoStateMachine();
  final VideoOperationQueue _operationQueue = VideoOperationQueue();
  final VideoRetryManager _retryManager = VideoRetryManager();
  VideoSession? _currentSession;

  // Enhanced state management for preventing concurrent operations
  final bool _isSyncing = false;
  int _syncFailureCount = 0;
  static const int _maxSyncRetries = 3;

  // Operation cancellation and mutex
  bool _isOperationLocked = false;
  Timer? _debounceTimer;
  String? _pendingOperationId;

  // Duration cache for videos
  final Map<String, Duration> _videoDurationCache = {};

  // Debug mode flag
  final bool _debugMode = true; // Enable debug overlay by default

  bool get isConnected => _isConnected;
  bool get isInitialized => _isInitialized;
  VideoPlayerState? get currentVideoState => _currentVideoState;
  EnteFile? get currentDisplayedFile => _currentDisplayedFile;
  bool get isSyncing => _isSyncing;
  bool get debugMode => _debugMode;
  VideoSession? get currentSession => _currentSession;
  VideoLifecycleState get currentLifecycleState => _stateMachine.currentState;

  bool get isSupported {
    return featureFlagService.isExternalDisplayEnabled;
  }

  Future<void> init() async {
    if (!isSupported) {
      _logger.info('External display support is disabled');
      return;
    }

    if (_isInitialized) return;

    try {
      _logger.info('Initializing external display service');

      // Check initial connection status
      _isConnected = await ExternalDisplayPlugin.isExternalDisplayConnected;
      _logger.info('Initial connection status: $_isConnected');

      // Setup default logo
      await _setupDefaultLogo();

      // Listen to connection changes
      _connectionSubscription =
          ExternalDisplayPlugin.displayConnectionStream.listen(
        _onConnectionChanged,
        onError: (error) => _logger.severe('Connection stream error: $error'),
      );

      // Listen to video state changes
      _videoStateSubscription =
          ExternalDisplayPlugin.videoPlayerStateStream.listen(
        _onVideoStateChanged,
        onError: (error) => _logger.severe('Video state stream error: $error'),
      );

      // Show default logo if already connected
      if (_isConnected) {
        await showDefaultLogo();
      }

      _isInitialized = true;
      _logger.info('External display service initialized successfully');
    } catch (e, s) {
      _logger.severe('Failed to initialize external display service', e, s);
    }
  }

  Future<void> dispose() async {
    if (!_isInitialized) return;

    try {
      // Cancel subscriptions
      await _connectionSubscription?.cancel();
      await _videoStateSubscription?.cancel();

      // Cancel any pending timers
      _debounceTimer?.cancel();
      _debounceTimer = null;

      // Clear operation queue
      await _operationQueue.clear();

      // Reset state machine
      await _stateMachine.reset();
      _stateMachine.dispose();

      // Clear retry manager statistics
      _retryManager.clearStatistics();

      // Dispose plugin
      await ExternalDisplayPlugin.dispose();

      // Clear references
      _connectionSubscription = null;
      _videoStateSubscription = null;
      _isConnected = false;
      _currentVideoState = null;
      _currentDisplayedFile = null;
      _currentSession = null;
      _isInitialized = false;

      _logger.info('External display service disposed');
    } catch (e, s) {
      _logger.severe('Error disposing external display service', e, s);
    }
  }

  void _onConnectionChanged(bool connected) {
    _logger.info('External display connection changed: $connected');
    _isConnected = connected;

    if (connected) {
      // Show default logo and brand logo when external display connects
      showDefaultLogo().catchError((e) {
        _logger.warning('Failed to show default logo on connection: $e');
        return false;
      });
    } else {
      // Clear current file reference when disconnected
      _currentDisplayedFile = null;
      _currentVideoState = null;
    }
  }

  void _onVideoStateChanged(VideoPlayerState state) {
    _currentVideoState = state;
    _logger.fine(
      'Video state changed: ${state.state}, position: ${state.position}',
    );

    // Handle video looping if enabled
    _handleVideoLooping(state);

    // Update debug overlay if enabled and displaying a file
    if (_debugMode && _currentDisplayedFile != null) {
      _updateDebugOverlayState();
    }
  }

  void _handleVideoLooping(VideoPlayerState state) {
    // Native looping is now handled in iOS plugin, but we still log state changes
    if (state.state == PlaybackState.ended) {
      _logger
          .info('Video ended - native loop handling should restart if enabled');
    }
    // Removed false restart detection that was causing log spam
    // Position 0 is normal immediately after starting a video
  }

  Future<void> _updateDebugOverlayState() async {
    if (!_debugMode || _currentDisplayedFile == null) return;

    try {
      final state =
          _currentVideoState?.state.toString().split('.').last ?? "Unknown";
      final position =
          _formatDuration(_currentVideoState?.position ?? Duration.zero);
      final duration =
          _formatDuration(_currentVideoState?.duration ?? Duration.zero);

      final debugInfo = '''
[DEBUG]
Mode: ${_lastKnownStreamMode ? "Stream" : "Original"}
State: $state
Time: $position / $duration
File: ${_currentDisplayedFile!.displayName.length > 30 ? _currentDisplayedFile!.displayName.substring(0, 30) + '...' : _currentDisplayedFile!.displayName}
Failures: $_syncFailureCount
''';

      await ExternalDisplayPlugin.showDebugOverlay(
        debugInfo,
        position: 'top-left',
        opacity: 0.7,
      );
    } catch (e) {
      // Silently fail for debug overlay updates
    }
  }

  /// Update loop setting immediately when app setting changes
  Future<void> updateLoopSetting(bool shouldLoop) async {
    if (!isSupported || !_isConnected) {
      return;
    }

    try {
      await ExternalDisplayPlugin.setVideoLoop(shouldLoop);
      _logger.info('Updated video loop setting to: $shouldLoop');
    } catch (e, s) {
      _logger.severe('Failed to update loop setting', e, s);
    }
  }

  Future<void> _setupDefaultLogo() async {
    try {
      await ExternalDisplayPlugin.setDefaultLogoFromAsset(
        _defaultLogoAsset,
        backgroundColor: _defaultBackgroundColor,
      );

      // Set up brand logo (Ente Photos) for top-right corner
      await ExternalDisplayPlugin.setBrandLogoFromAsset(
        _brandLogoAsset,
        padding: 20.0,
        opacity: 0.8,
      );

      _logger.info('Default logo and brand logo setup completed');
    } catch (e, s) {
      _logger.severe('Failed to setup logos', e, s);
    }
  }

  Future<bool> showDefaultLogo() async {
    if (!isSupported || !_isConnected) return false;

    try {
      final success = await ExternalDisplayPlugin.showDefaultLogo();
      if (success) {
        _currentDisplayedFile = null;
        // Also show the brand logo
        await ExternalDisplayPlugin.showBrandLogo();
        _logger.info('Default logo and brand logo displayed successfully');
      }
      return success;
    } catch (e, s) {
      _logger.severe('Failed to show default logo', e, s);
      return false;
    }
  }

  Future<bool> displayImage(EnteFile file) async {
    if (!isSupported || !_isConnected) return false;

    try {
      _logger.info('Displaying image on external display: ${file.displayName}');

      // Get the file from cache or download it
      final File? localFile = await getFile(file);
      if (localFile == null) {
        _logger.warning('Failed to get local file for ${file.displayName}');
        return false;
      }

      // Use the new displayImageFromFile method
      final success = await ExternalDisplayPlugin.displayImageFromFile(
        localFile.path,
        scaleMode: 'fit',
      );

      if (success) {
        _currentDisplayedFile = file;
        _logger.info('Image displayed successfully: ${file.displayName}');
      }

      return success;
    } catch (e, s) {
      _logger.severe('Failed to display image: ${file.displayName}', e, s);
      return false;
    }
  }

  Future<bool> playVideo(EnteFile file, {bool isStreamMode = false}) async {
    if (!isSupported || !_isConnected) {
      _logger.warning(
        'External display not supported or not connected. Supported: $isSupported, Connected: $_isConnected',
      );
      return false;
    }

    // Create new session for this video
    final session = VideoSession(
      fileId: file.uploadedFileID?.toString() ??
          file.localID ??
          file.generatedID.toString(),
      isStreamMode: isStreamMode,
    );

    // Cancel any pending operations before starting new one
    await _cancelPendingOperations();

    _currentSession = session;
    _stateMachine.attachSession(session);

    // Use intelligent debouncing instead of simple time-based blocking
    return await _executeWithDebouncing(
      operationId: 'PlayVideo_${session.shortSessionId}',
      operation: () => _operationQueue.enqueue(
        PlayVideoOperation(
          playFunction: () => _executePlayVideo(file, session, isStreamMode),
          name: 'PlayVideo_${session.shortSessionId}',
        ),
      ),
    );
  }

  Future<T> _executeWithDebouncing<T>(
      {required String operationId,
      required Future<T> Function() operation,}) async {
    // Cancel previous debounce timer if exists
    _debounceTimer?.cancel();

    // If this is a different operation, allow it immediately
    if (_pendingOperationId != operationId) {
      _pendingOperationId = operationId;
      return await operation();
    }

    // For same operation, use intelligent debouncing (shorter delay)
    final completer = Completer<T>();
    _debounceTimer = Timer(const Duration(milliseconds: 150), () async {
      try {
        final result = await operation();
        if (!completer.isCompleted) {
          completer.complete(result);
        }
      } catch (e, s) {
        if (!completer.isCompleted) {
          completer.completeError(e, s);
        }
      }
    });

    return completer.future;
  }

  Future<void> _cancelPendingOperations() async {
    // Cancel debounce timer
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _pendingOperationId = null;

    // Clear operation queue of non-critical operations
    await _operationQueue.cancelPendingOperations();

    _logger.info('Cancelled pending operations for new video');
  }

  Future<bool> _executePlayVideo(
    EnteFile file,
    VideoSession session,
    bool isStreamMode,
  ) async {
    // Acquire operation lock to prevent concurrent executions
    if (_isOperationLocked) {
      _logger.warning(
          '[Session: ${session.shortSessionId}] Operation already in progress, skipping',);
      return false;
    }

    _isOperationLocked = true;

    // Track the stream mode for proper looping and state management
    _lastKnownStreamMode = isStreamMode;

    // Reset state machine if in disposed state
    if (_stateMachine.currentState == VideoLifecycleState.disposed) {
      await _stateMachine.reset();
      _logger.info(
          '[Session: ${session.shortSessionId}] Reset state machine from disposed state',);
    }

    // Ensure we're in uninitialized state and can transition properly
    if (_stateMachine.currentState != VideoLifecycleState.uninitialized &&
        _stateMachine.currentState != VideoLifecycleState.initializing) {
      await _stateMachine.reset();
      _logger.info(
          '[Session: ${session.shortSessionId}] Reset state machine to ensure proper state flow',);
    }

    // Only transition to initializing if we're in uninitialized state
    if (_stateMachine.currentState == VideoLifecycleState.uninitialized) {
      await _stateMachine.transition(
        VideoLifecycleState.initializing,
        reason: 'Starting video playback',
      );
    }

    // Set loop mode based on app settings
    final shouldLoop = localSettings.shouldLoopVideo();
    await ExternalDisplayPlugin.setVideoLoop(shouldLoop);
    _logger.info(
        '[Session: ${session.shortSessionId}] Set video loop to: $shouldLoop',);

    try {
      // First, properly cleanup any existing video
      await _cleanupCurrentVideo();

      _logger.info(
        '[Session: ${session.shortSessionId}] Starting video playback on external display: ${file.displayName}',
      );
      _logger.info(
          '[Session: ${session.shortSessionId}] File info: isRemoteFile=${file.isRemoteFile}, '
          'localID=${file.localID}, '
          'uploadedFileID=${file.uploadedFileID}, '
          'isStreamMode=$isStreamMode');

      // Transition to loading state (we should be in initializing state now)
      if (_stateMachine.currentState == VideoLifecycleState.initializing) {
        await _stateMachine.transition(
          VideoLifecycleState.loading,
          reason: 'Loading video source',
        );
      } else {
        _logger.warning(
            '[Session: ${session.shortSessionId}] Unexpected state: ${_stateMachine.currentState}, resetting',);
        await _stateMachine.reset();
        await _stateMachine.recoverFromError(
            reason: 'Unexpected state during video playback',);
        await _stateMachine.transition(VideoLifecycleState.initializing,
            reason: 'Recovery transition',);
        await _stateMachine.transition(VideoLifecycleState.loading,
            reason: 'Loading video source',);
      }

      bool success = false;

      if (isStreamMode) {
        // Use local playlist file for stream mode
        _logger.info('Attempting STREAM MODE playback');
        try {
          final playlistData =
              await VideoPreviewService.instance.getPlaylist(file);
          if (playlistData?.preview != null) {
            final previewPath = playlistData!.preview.path;
            _logger.info(
              'Using STREAM MODE playback with local playlist: $previewPath',
            );

            // Check if file exists and is readable
            final previewFile = File(previewPath);
            final exists = await previewFile.exists();
            final size = exists ? await previewFile.length() : 0;
            _logger.info('Preview file exists: $exists, size: $size bytes');

            // Debug: Read and analyze playlist content
            if (exists) {
              try {
                final content = await previewFile.readAsString();
                _logger.info(
                    'Playlist content preview (first 300 chars): ${content.length > 300 ? content.substring(0, 300) + "..." : content}',);

                // Check for common HLS issues
                if (!content.contains('#EXTM3U')) {
                  _logger.severe('Invalid HLS: Missing #EXTM3U header');
                }
                if (content.contains('output.ts')) {
                  _logger.warning(
                      'Playlist still contains local references to output.ts',);
                }

                // Count video segments (including byte-range segments)
                final lines = content.split('\n');
                final traditionalSegments = lines
                    .where((line) =>
                        line.startsWith('http') || line.endsWith('.ts'),)
                    .length;
                final byteRangeSegments = lines
                    .where((line) => line.startsWith('#EXT-X-BYTERANGE'))
                    .length;
                final totalSegments = traditionalSegments + byteRangeSegments;

                _logger.info(
                    'Found $totalSegments video segments in playlist ($traditionalSegments traditional, $byteRangeSegments byte-range)',);

                if (content.contains('#EXT-X-BYTERANGE')) {
                  _logger.info(
                      'Using single-file HLS format with byte-range segments',);
                }

                if (totalSegments == 0) {
                  _logger.severe('Playlist contains no valid video segments!');
                }
              } catch (e) {
                _logger.severe('Failed to read playlist content: $e');
              }
            }

            if (!exists) {
              _logger.severe('Preview file does not exist: $previewPath');
              return false;
            }

            success = await ExternalDisplayPlugin.playVideoFromFile(
              previewPath,
              scaleMode: VideoScaleMode.fit,
              autoPlay: true,
            );
            _logger.info('Stream mode playback result: $success');

            if (!success) {
              _logger.severe('Stream mode playback failed for: $previewPath');

              // Enhanced error reporting for failed playlist playback
              try {
                final playlistContent = await previewFile.readAsString();
                _logger.severe('Failed playlist content: $playlistContent');

                // Analyze failure reasons
                if (playlistContent.isEmpty) {
                  _logger.severe('Failure reason: Playlist file is empty');
                } else if (!playlistContent.contains('#EXTM3U')) {
                  _logger.severe(
                      'Failure reason: Not a valid HLS playlist (missing #EXTM3U)',);
                } else if (!playlistContent.contains('http')) {
                  _logger.severe(
                      'Failure reason: No remote URLs found in playlist',);
                } else {
                  _logger.severe(
                      'Failure reason: Unknown - playlist seems valid but AVPlayer failed',);
                }
              } catch (e) {
                _logger
                    .severe('Could not read failed playlist for analysis: $e');
              }

              // Try fallback to non-stream mode instead of clearing display
              _logger.info(
                  'Attempting fallback to non-stream mode for failed playlist',);
              try {
                success = await _playVideoDirectFile(file);
                if (success) {
                  _logger.info('✅ Fallback to direct file mode succeeded');
                } else {
                  _logger.severe(
                      '❌ Both stream and direct file modes failed, clearing display',);
                  await clearDisplay();
                }
              } catch (e) {
                _logger.severe('Fallback to direct file mode failed: $e');
                await clearDisplay();
              }
            }
          } else {
            _logger.warning(
              'No playlist available for stream mode, falling back to URL',
            );
            final videoUrl = getStreamUrl(file);
            _logger.info('Fallback stream URL: $videoUrl');
            success = await ExternalDisplayPlugin.playVideo(
              videoUrl,
              scaleMode: VideoScaleMode.fit,
              autoPlay: true,
            );
            _logger.info('Stream URL playback result: $success');
            if (!success) {
              await clearDisplay();
            }
          }
        } catch (e, s) {
          _logger.severe('Stream mode failed, falling back to URL: $e', e, s);
          await clearDisplay();
          final videoUrl = getStreamUrl(file);
          _logger.info('Final fallback stream URL: $videoUrl');
          success = await ExternalDisplayPlugin.playVideo(
            videoUrl,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          _logger.info('Final fallback stream playback result: $success');
          if (!success) {
            await clearDisplay();
          }
        }
      } else if (file.isRemoteFile) {
        // For remote files, try to get local file first, then fallback to URL
        _logger.info('Attempting REMOTE FILE playback');
        try {
          // First try to get the actual downloaded file (using same params as native video player)
          _logger.info(
              'Getting file for ${file.displayName}: downloadUrl=${file.downloadUrl}, uploadedFileID=${file.uploadedFileID}',);
          final File? localFile = await getFile(file, isOrigin: true);
          if (localFile != null && await localFile.exists()) {
            final filePath = localFile.path;
            final fileSize = await localFile.length();
            _logger.info(
              'Using downloaded file for playback: $filePath (size: $fileSize bytes)',
            );

            // Check file permissions and accessibility
            try {
              final readable = await localFile.readAsBytes();
              _logger.info(
                'File is readable, first 10 bytes: ${readable.take(10).toList()}',
              );
            } catch (e) {
              _logger.severe('File is not readable: $e');
            }

            success = await ExternalDisplayPlugin.playVideoFromFile(
              filePath,
              scaleMode: VideoScaleMode.fit,
              autoPlay: true,
            );
            _logger.info('Downloaded file playback result: $success');

            if (!success) {
              _logger.severe('Downloaded file playback failed for: $filePath');
              await clearDisplay();
            }
          }

          // If local file failed, try playlist
          if (!success) {
            _logger.info('Trying playlist for remote file');
            final playlistData =
                await VideoPreviewService.instance.getPlaylist(file);
            if (playlistData?.preview != null) {
              final previewPath = playlistData!.preview.path;
              _logger.info(
                'Using FILE-based playback with local playlist: $previewPath',
              );

              final previewFile = File(previewPath);
              final exists = await previewFile.exists();
              final size = exists ? await previewFile.length() : 0;
              _logger.info('Playlist file exists: $exists, size: $size bytes');

              if (exists) {
                success = await ExternalDisplayPlugin.playVideoFromFile(
                  previewPath,
                  scaleMode: VideoScaleMode.fit,
                  autoPlay: true,
                );
                _logger.info('Playlist file playback result: $success');
                if (!success) {
                  await clearDisplay();
                }
              }
            }
          }

          // Final fallback to URL
          if (!success) {
            final videoUrl = getFileUrl(file);
            _logger.info(
              'No local file available, using URL-based playback: $videoUrl',
            );
            success = await ExternalDisplayPlugin.playVideo(
              videoUrl,
              scaleMode: VideoScaleMode.fit,
              autoPlay: true,
            );
            _logger.info('URL-based playback result: $success');
            if (!success) {
              await clearDisplay();
            }
          }
        } catch (e, s) {
          _logger.severe('Remote file processing failed: $e', e, s);
          final videoUrl = getFileUrl(file);
          _logger.info('Final fallback URL: $videoUrl');
          success = await ExternalDisplayPlugin.playVideo(
            videoUrl,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          _logger.info('Final URL playback result: $success');
          if (!success) {
            await clearDisplay();
          }
        }
      } else {
        // For local files, get the file and use file-based playback (using same params as native video player)
        _logger.info('Attempting LOCAL FILE playback');
        _logger.info(
            'Getting file for ${file.displayName}: downloadUrl=${file.downloadUrl}, uploadedFileID=${file.uploadedFileID}',);
        final File? localFile = await getFile(file, isOrigin: true);
        if (localFile != null) {
          final filePath = localFile.path;
          final exists = await localFile.exists();
          final size = exists ? await localFile.length() : 0;

          _logger.info(
            'Using FILE-based playback with path: $filePath (exists: $exists, size: $size bytes)',
          );

          if (!exists) {
            _logger.severe('Local file does not exist: $filePath');
            return false;
          }

          // Test file accessibility
          try {
            final readable = await localFile.readAsBytes();
            _logger.info(
              'Local file is readable, first 10 bytes: ${readable.take(10).toList()}',
            );
          } catch (e) {
            _logger.severe('Local file is not readable: $e');
            return false;
          }

          success = await ExternalDisplayPlugin.playVideoFromFile(
            filePath,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          _logger.info('Local file playback result: $success');

          if (!success) {
            _logger.severe('Local file playback failed for: $filePath');
            await clearDisplay();
          }
        } else {
          _logger.severe('Could not get local file for: ${file.displayName}');
        }
      }

      if (success) {
        _currentDisplayedFile = file;
        _syncFailureCount = 0; // Reset failure count on success

        // Transition to playing state
        await _stateMachine.transition(
          VideoLifecycleState.playing,
          reason: 'Video started successfully',
        );

        _logger.info(
            '[Session: ${session.shortSessionId}] ✅ Video started successfully: ${file.displayName}',);

        // Cache duration if available
        if (_currentVideoState?.duration != null &&
            _currentVideoState!.duration > Duration.zero) {
          final cacheKey = file.uploadedFileID?.toString() ??
              file.localID ??
              file.generatedID.toString();
          _videoDurationCache[cacheKey] = _currentVideoState!.duration;
          _logger.info(
              '[Session: ${session.shortSessionId}] Cached duration: ${_currentVideoState!.duration}',);
        }

        // Show debug overlay if enabled
        if (_debugMode) {
          await _showDebugOverlay(file, isStreamMode);
        }
      } else {
        _syncFailureCount++;
        session.retryCount = _syncFailureCount;

        // Transition to error state
        await _stateMachine.transition(
          VideoLifecycleState.error,
          reason: 'Video playback failed',
        );

        _logger.severe(
          '[Session: ${session.shortSessionId}] ❌ All video playback attempts failed for: ${file.displayName} (failure count: $_syncFailureCount)',
        );

        // If too many failures, temporarily disable external display
        if (_syncFailureCount >= _maxSyncRetries) {
          _logger.severe(
              '[Session: ${session.shortSessionId}] Max sync failures reached, showing fallback logo',);
          await showDefaultLogo();
        }
      }

      return success;
    } catch (e, s) {
      _logger.severe(
        '[Session: ${session.shortSessionId}] Critical error during video playback: ${file.displayName}',
        e,
        s,
      );

      // Transition to error state
      await _stateMachine.transition(
        VideoLifecycleState.error,
        reason: 'Critical error: $e',
        force: true,
      );

      session.errorDetails = e.toString();
      return false;
    } finally {
      // Always release the operation lock
      _isOperationLocked = false;
    }
  }

  Future<void> _cleanupCurrentVideo() async {
    try {
      _logger.info('Cleaning up current video state');

      // Transition to disposing state
      if (_stateMachine.currentState != VideoLifecycleState.uninitialized &&
          _stateMachine.currentState != VideoLifecycleState.disposed) {
        await _stateMachine.transition(
          VideoLifecycleState.disposing,
          reason: 'Cleaning up for new video',
        );
      }

      // Stop current video if playing
      await stopVideo();

      // Clear the display to prevent black screen
      await clearDisplay();

      // Small delay to ensure cleanup completes
      await Future.delayed(const Duration(milliseconds: 100));

      // Transition to disposed state
      await _stateMachine.transition(
        VideoLifecycleState.disposed,
        reason: 'Cleanup completed',
      );

      // Reset to uninitialized for next video
      await _stateMachine.reset();

      _logger.info('Video cleanup completed');
    } catch (e, s) {
      _logger.severe('Error during video cleanup', e, s);
    }
  }

  Future<void> _showDebugOverlay(EnteFile file, bool isStreamMode) async {
    if (!_debugMode || _currentSession == null) return;

    try {
      final state = _stateMachine.currentState.displayName;
      final position =
          _formatDuration(_currentVideoState?.position ?? Duration.zero);
      final duration =
          _formatDuration(_currentVideoState?.duration ?? Duration.zero);
      final queueStats = _operationQueue.getStatistics();

      final debugInfo = '''
[DEBUG]
Mode: ${isStreamMode ? "Stream" : "Original"}
State: $state
Time: $position / $duration
File: ${file.displayName.length > 30 ? file.displayName.substring(0, 30) + '...' : file.displayName}
Session: ${_currentSession!.shortSessionId}
Retries: ${_currentSession!.retryCount}
Queue: ${queueStats['pendingOperations']} pending
''';

      // Try to show on external display
      final overlayShown = await ExternalDisplayPlugin.showDebugOverlay(
        debugInfo,
        position: 'top-left',
        opacity: 0.7,
      );

      if (overlayShown) {
        _logger.info('Debug overlay shown on external display');
      } else {
        // Fallback to logging if overlay not available
        _logger.info('Debug overlay (not shown on display):\n$debugInfo');
      }
    } catch (e, s) {
      _logger.warning('Failed to show debug overlay', e, s);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<bool> pauseVideo() async {
    if (!isSupported || !_isConnected || _currentVideoState == null) {
      return false;
    }

    try {
      return await ExternalDisplayPlugin.pauseVideo();
    } catch (e, s) {
      _logger.severe('Failed to pause video', e, s);
      return false;
    }
  }

  Future<bool> resumeVideo() async {
    if (!isSupported || !_isConnected || _currentVideoState == null) {
      return false;
    }

    try {
      return await ExternalDisplayPlugin.resumeVideo();
    } catch (e, s) {
      _logger.severe('Failed to resume video', e, s);
      return false;
    }
  }

  Future<bool> stopVideo() async {
    if (!isSupported || !_isConnected) return false;

    try {
      final success = await ExternalDisplayPlugin.stopVideo();
      if (success) {
        _currentVideoState = null;
      }
      return success;
    } catch (e, s) {
      _logger.severe('Failed to stop video', e, s);
      return false;
    }
  }

  Future<bool> seekVideo(Duration position) async {
    if (!isSupported || !_isConnected || _currentVideoState == null) {
      return false;
    }

    try {
      return await ExternalDisplayPlugin.seekVideo(position);
    } catch (e, s) {
      _logger.severe('Failed to seek video to $position', e, s);
      return false;
    }
  }

  Future<bool> clearDisplay() async {
    if (!isSupported || !_isConnected) return false;

    try {
      final success = await ExternalDisplayPlugin.clearDisplay();
      if (success) {
        _currentDisplayedFile = null;
        _currentVideoState = null;
      }
      return success;
    } catch (e, s) {
      _logger.severe('Failed to clear display', e, s);
      return false;
    }
  }

  String getStreamUrl(EnteFile file) {
    try {
      // Generate proper streaming URL using video preview service playlist
      // This will return the actual HLS .m3u8 URL that can be used for streaming
      _logger.info(
          'Generating streaming URL using playlist for ${file.displayName}',);

      // Note: The getPlaylist call is async, but this method needs to be sync
      // The streaming URL will be handled by the playlist-based approach in _executePlayVideo
      // For now, return the file URL with stream parameter as a fallback
      final baseUrl = getFileUrl(file);
      final streamingUrl = baseUrl.contains('?')
          ? '$baseUrl&stream=true'
          : '$baseUrl?stream=true';
      _logger.info('Generated fallback streaming URL for ${file.displayName}');
      return streamingUrl;
    } catch (e, s) {
      _logger.severe(
          'Failed to generate streaming URL for ${file.displayName}', e, s,);
      return getFileUrl(file);
    }
  }

  // Enhanced playVideo with retry and fallback mechanisms
  Future<bool> playVideoWithFallback(EnteFile file,
      {bool isStreamMode = false,}) async {
    if (!isSupported || !_isConnected) return false;

    // Use retry manager for the main operation
    return await _retryManager.executeWithRetryAndTimeout(
      operation: () async {
        try {
          // Try primary method
          return await playVideo(file, isStreamMode: isStreamMode);
        } catch (e) {
          _logger.warning('Primary playback failed: $e');

          // Fallback 1: Try opposite mode
          if (isStreamMode) {
            _logger.info('Trying fallback: Original mode instead of Stream');
            final result = await playVideo(file, isStreamMode: false);
            if (result) return result;
          } else {
            _logger.info('Trying fallback: Stream mode instead of Original');
            final result = await playVideo(file, isStreamMode: true);
            if (result) return result;
          }

          // Fallback 2: Full reset and retry
          _logger.info('Trying fallback: Full reset and retry');
          await fullReset();
          await Future.delayed(const Duration(seconds: 1));

          final resetResult = await playVideo(file, isStreamMode: false);
          if (resetResult) return resetResult;

          // Fallback 3: Show error message
          _logger.severe('All fallbacks failed, showing error');
          await showErrorMessage(
              'Unable to play video. Please try reconnecting.',);
          return false;
        }
      },
      operationName: 'PlayVideoWithFallback',
      timeout: const Duration(seconds: 45),
      maxRetries: 2,
    );
  }

  Future<void> fullReset() async {
    _logger.info('Performing full reset of external display');

    try {
      // Cancel any pending operations
      await _cancelPendingOperations();

      // Clear operation queue
      await _operationQueue.clear();

      // Reset state machine
      await _stateMachine.reset();

      // Clear display
      await clearDisplay();

      // Dispose and reinitialize
      await dispose();
      await Future.delayed(const Duration(milliseconds: 500));
      await init();

      _logger.info('Full reset completed');
    } catch (e, s) {
      _logger.severe('Error during full reset', e, s);
    }
  }

  Future<void> showErrorMessage(String message) async {
    if (!_isConnected) return;

    try {
      final errorInfo = '''
[ERROR]
━━━━━━━━━━━━━━━━━━━━
$message
━━━━━━━━━━━━━━━━━━━━

Please try:
• Reconnecting display
• Restarting the app
• Checking network connection
''';

      await ExternalDisplayPlugin.showDebugOverlay(
        errorInfo,
        position: 'center',
        opacity: 0.9,
      );

      // Show for 5 seconds then clear
      await Future.delayed(const Duration(seconds: 5));
      await ExternalDisplayPlugin.hideDebugOverlay();
      await showDefaultLogo();
    } catch (e) {
      _logger.warning('Failed to show error message: $e');
    }
  }

  String getFileUrl(EnteFile file) {
    // Use the existing file URL generation from the app
    if (file.isUploaded) {
      // Use ente's file serving endpoint
      return "https://files.ente.io/file/download/${file.uploadedFileID}";
    } else if (file.isSharedMediaToAppSandbox) {
      return file.localID!;
    } else {
      return file.localID ?? "";
    }
  }

  /// Try to play video using direct file access (fallback when streaming fails)
  Future<bool> _playVideoDirectFile(EnteFile file) async {
    try {
      if (file.isRemoteFile) {
        // For remote files, try to get local file first, then fallback to URL
        _logger.info('Attempting DIRECT FILE playback for remote file');
        final File? localFile = await getFile(file, isOrigin: true);
        if (localFile != null && await localFile.exists()) {
          final filePath = localFile.path;
          final fileSize = await localFile.length();
          _logger.info(
            'Using downloaded file for direct playback: $filePath (size: $fileSize bytes)',
          );

          final success = await ExternalDisplayPlugin.playVideoFromFile(
            filePath,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          _logger.info('Direct file playback result: $success');
          return success;
        } else {
          // Fallback to URL for remote file
          final videoUrl = getFileUrl(file);
          _logger.info('Fallback to remote URL: $videoUrl');
          final success = await ExternalDisplayPlugin.playVideo(
            videoUrl,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          return success;
        }
      } else {
        // For local files, get the path directly
        _logger.info('Attempting DIRECT FILE playback for local file');
        final File? localFile = await getFile(file);
        if (localFile != null && await localFile.exists()) {
          final filePath = localFile.path;
          _logger.info('Using local file for direct playback: $filePath');

          final success = await ExternalDisplayPlugin.playVideoFromFile(
            filePath,
            scaleMode: VideoScaleMode.fit,
            autoPlay: true,
          );
          _logger.info('Local direct file playback result: $success');
          return success;
        }
      }

      return false;
    } catch (e, s) {
      _logger.severe('Direct file playback failed', e, s);
      return false;
    }
  }
}
