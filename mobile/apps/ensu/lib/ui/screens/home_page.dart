import 'dart:async';

import 'package:ensu/core/configuration.dart';
import 'package:ente_accounts/pages/login_page.dart';
import 'package:ensu/services/chat_dag.dart';
import 'package:ensu/ui/screens/model_settings_page.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:ente_ui/pages/developer_settings_page.dart' as ente_ui;
import 'package:ente_ui/pages/base_home_page.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/download_toast.dart';
import 'package:ente_ui/components/buttons/button_widget.dart';
import 'package:ente_ui/components/buttons/models/button_type.dart';
import 'package:ente_ui/utils/dialog_util.dart';
import 'package:ente_utils/email_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

class HomePage extends BaseHomePage {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends BaseHomePageState<HomePage>
    with WidgetsBindingObserver {
  static const int _developerModeTapThreshold = 5;
  static const String _rootBranchKey = '__root__';
  static const String _streamingBranchKey = '__streaming__';
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  List<ChatSession> _sessions = [];
  String? _currentSessionId;
  ChatSession? _currentSession;
  String _currentTitle = 'ensu';
  bool _isLoading = false;
  int _developerModeTapCount = 0;
  DateTime? _lastDeveloperTapAt;
  bool _isOpeningDeveloperSettings = false;
  bool _isGenerating = false;
  bool _isDownloading = false;
  bool _showDownloadToast = false;
  bool _autoSyncInFlight = false;
  Completer<bool>? _downloadToastCompleter;
  String _streamingResponse = '';
  final Map<String, Map<String, String>> _branchSelectionsBySession = {};
  StreamSubscription? _chatsSubscription;
  StreamSubscription? _logoutSubscription;
  StreamSubscription? _downloadProgressSubscription;
  double _previousBottomInset = 0;
  bool _shouldAutoScroll = true;
  bool _interruptRequested = false;
  final Set<String> _interruptedMessageUuids = {};
  ChatMessage? _editingMessage;
  String? _draftBeforeEdit;
  String? _streamingParentMessageUuid;
  int _loadSessionsToken = 0;

  LLMService get _llm => LLMService.instance;
  bool get _isLoggedIn => Configuration.instance.hasConfiguredAccount();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _chatsSubscription = eventBus.on<ChatsUpdatedEvent>().listen((_) {
      _loadSessions();
    });
    _logoutSubscription = eventBus.on<TriggerLogoutEvent>().listen((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session expired. Please sign in again.')),
      );
      setState(() {});
    });
    _loadSessions();
    unawaited(_triggerAutoSync());

    // Listen to scroll position to detect manual scroll-up during streaming
    _scrollController.addListener(_onScroll);

    // Listen to download progress
    _downloadProgressSubscription = _llm.downloadProgress.listen((progress) {
      if (mounted) {
        final isDownloading = progress.percent > 0 &&
            progress.percent < 100 &&
            (progress.status?.contains('Download') ?? false);
        if (_isDownloading != isDownloading) {
          setState(() {
            _isDownloading = isDownloading;
          });
        }
      }
    });

    // Start model download/load immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureModelReady();
    });
  }

  Future<void> _triggerAutoSync() async {
    if (!_isLoggedIn || _autoSyncInFlight) {
      return;
    }

    _autoSyncInFlight = true;
    try {
      await ChatService.instance.sync();
    } finally {
      _autoSyncInFlight = false;
    }

    if (mounted) {
      _loadSessions();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;

    // Check if user scrolled up (not at the bottom)
    final position = _scrollController.position;
    final isAtBottom = position.pixels >= position.maxScrollExtent - 50;
    final isUserScrollingUp =
        position.userScrollDirection == ScrollDirection.forward;

    if (_isGenerating && _shouldAutoScroll && isUserScrollingUp) {
      // User started scrolling up during streaming - disable auto-scroll
      setState(() {
        _shouldAutoScroll = false;
      });
    } else if (isAtBottom && !_shouldAutoScroll && !isUserScrollingUp) {
      // User scrolled back to bottom - re-enable auto-scroll
      setState(() {
        _shouldAutoScroll = true;
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _chatsSubscription?.cancel();
    _logoutSubscription?.cancel();
    _downloadProgressSubscription?.cancel();
    if (_downloadToastCompleter != null &&
        !_downloadToastCompleter!.isCompleted) {
      _downloadToastCompleter!.complete(false);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      unawaited(_triggerAutoSync());
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // Scroll to bottom when keyboard appears
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final bottomInset = MediaQuery.of(context).viewInsets.bottom;
      if (bottomInset > _previousBottomInset && bottomInset > 0) {
        // Keyboard appeared - scroll to bottom (force scroll)
        _scrollToBottom(force: true);
      }
      _previousBottomInset = bottomInset;
    });
  }

  Future<void> _handleDeveloperTap() async {
    final now = DateTime.now();
    final lastTap = _lastDeveloperTapAt;

    if (lastTap == null ||
        now.difference(lastTap) > const Duration(seconds: 2)) {
      _developerModeTapCount = 0;
    }

    _lastDeveloperTapAt = now;
    _developerModeTapCount += 1;

    if (_developerModeTapCount < _developerModeTapThreshold ||
        _isOpeningDeveloperSettings) {
      return;
    }

    _developerModeTapCount = 0;
    _isOpeningDeveloperSettings = true;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            ente_ui.DeveloperSettingsPage(Configuration.instance),
      ),
    );

    _isOpeningDeveloperSettings = false;
  }

  Future<void> _loadSessions() async {
    final token = ++_loadSessionsToken;
    try {
      final sessions = await ChatService.instance.getAllSessions();
      final selectionsBySession =
          await ChatService.instance.getBranchSelectionsForRoots(
        sessions.map((session) => session.sessionUuid).toList(),
      );
      if (!mounted || token != _loadSessionsToken) {
        return;
      }
      setState(() {
        _sessions = sessions;
        _isLoading = false;
        _mergeBranchSelections(sessions, selectionsBySession);

        if (_currentSessionId != null) {
          final directSession = sessions
              .where((s) => s.sessionUuid == _currentSessionId)
              .firstOrNull;
          final mappedSession = directSession ??
              sessions
                  .where((s) =>
                      s.messages.any((m) => m.sessionUuid == _currentSessionId))
                  .firstOrNull;
          if (mappedSession != null &&
              mappedSession.sessionUuid != _currentSessionId) {
            _currentSessionId = mappedSession.sessionUuid;
          }
          _currentSession = mappedSession;
          if (_currentSession != null) {
            _currentTitle = _currentSession!.title;
          }
        }
      });
    } catch (e) {
      if (!mounted || token != _loadSessionsToken) {
        return;
      }
      setState(() => _isLoading = false);
    }
  }

  void _selectSession(ChatSession session) {
    if (_isGenerating) {
      unawaited(_stopGeneration());
    }
    _cancelEditing(restoreDraft: true);
    _llm.resetContext();
    setState(() {
      _currentSessionId = session.sessionUuid;
      _currentSession = session;
      _currentTitle = session.title;
      _streamingResponse = '';
      _shouldAutoScroll = true;
    });
    Navigator.pop(context);
    _scrollToBottom(force: true);
  }

  void _startNewChat() {
    if (_isGenerating) {
      unawaited(_stopGeneration());
    }
    _cancelEditing(restoreDraft: true);
    _llm.resetContext();
    setState(() {
      _currentSessionId = null;
      _currentSession = null;
      _currentTitle = 'ensu';
      _streamingResponse = '';
    });
    Navigator.pop(context);
  }

  Future<void> _deleteSession(String rootSessionUuid) async {
    final result = await showChoiceDialog(
      context,
      title: 'Delete Chat',
      body: 'Are you sure you want to delete this chat?',
      firstButtonLabel: 'Delete',
      secondButtonLabel: 'Cancel',
      firstButtonType: ButtonType.critical,
      isCritical: true,
    );

    if (result?.action == ButtonAction.first) {
      await ChatService.instance.deleteSessionTree(rootSessionUuid);
      if (_currentSessionId == rootSessionUuid) {
        setState(() {
          _currentSessionId = null;
          _currentSession = null;
          _currentTitle = 'ensu';
        });
      }
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && !_shouldAutoScroll) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      final position = _scrollController.position;
      final target = position.maxScrollExtent;

      if (force || _isGenerating) {
        position.jumpTo(target);
        return;
      }

      _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _retryMessage(ChatMessage targetMessage) async {
    if (_currentSession == null || _isGenerating) return;

    final session = _currentSession!;
    final messageState = _buildMessagePath(session);
    final messages = messageState.messages;

    final byId = <String, ChatMessage>{
      for (final message in session.messages) message.messageUuid: message,
    };

    ChatMessage? parentUserMessage;
    final parentId = targetMessage.parentMessageUuid;
    if (parentId != null) {
      final candidate = byId[parentId];
      if (candidate != null && candidate.isSelf) {
        parentUserMessage = candidate;
      }
    }

    if (parentUserMessage == null) {
      final targetIndex = messages.indexWhere(
        (m) => m.messageUuid == targetMessage.messageUuid,
      );
      if (targetIndex != -1) {
        for (int i = targetIndex - 1; i >= 0; i--) {
          if (messages[i].isSelf) {
            parentUserMessage = messages[i];
            break;
          }
        }
      }
    }

    if (parentUserMessage == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No message to retry')),
        );
      }
      return;
    }

    final shouldReplace =
        _nonPersistentResponseNotice(targetMessage.text) != null;

    // Ensure model is ready
    if (!await _ensureModelReady()) {
      return;
    }

    if (shouldReplace) {
      await ChatService.instance.deleteMessage(
        targetMessage.sessionUuid,
        targetMessage.messageUuid,
      );
      await _loadSessions();
    }

    // Reset LLM context and regenerate
    await _llm.resetContext();
    _shouldAutoScroll = true;
    final parentMessage = parentUserMessage;

    setState(() {
      _isGenerating = true;
      _streamingResponse = '';
      _interruptRequested = false;
      _streamingParentMessageUuid = parentMessage.messageUuid;
      final currentSessionId = _currentSessionId;
      if (currentSessionId != null) {
        _branchSelectionsForSession(
            currentSessionId)[parentMessage.messageUuid] = _streamingBranchKey;
      }
    });

    try {
      final buffer = StringBuffer();
      final startTime = DateTime.now();
      int tokenCount = 0;

      await for (final token in _llm.generateStream(parentMessage.text)) {
        buffer.write(token);
        tokenCount = buffer
            .toString()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .length;
        setState(() {
          _streamingResponse = buffer.toString();
        });
        _scrollToBottom();
      }

      if (buffer.isNotEmpty) {
        final responseText = buffer.toString();
        if (!_shouldPersistGeneratedResponse(responseText)) {
          _showNonPersistentResponseNotice(responseText);
          return;
        }

        final endTime = DateTime.now();
        final durationSeconds =
            endTime.difference(startTime).inMilliseconds / 1000.0;
        final tokensPerSecond =
            durationSeconds > 0 ? tokenCount / durationSeconds : 0.0;

        final messageUuid = await ChatService.instance.addAIMessage(
          targetMessage.sessionUuid,
          responseText,
          tokensPerSecond: tokensPerSecond,
          parentMessageUuid: parentMessage.messageUuid,
        );
        if (_interruptRequested) {
          _interruptedMessageUuids.add(messageUuid);
        }
        final sessionKey = _currentSessionId ?? targetMessage.sessionUuid;
        if (mounted) {
          setState(() {
            _branchSelectionsForSession(sessionKey)[parentMessage.messageUuid] =
                messageUuid;
          });
        } else {
          _branchSelectionsForSession(sessionKey)[parentMessage.messageUuid] =
              messageUuid;
        }
        _persistBranchSelection(
          sessionKey,
          parentMessage.messageUuid,
          messageUuid,
        );
        await _loadSessions();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      setState(() {
        _isGenerating = false;
        _streamingResponse = '';
        _interruptRequested = false;
        _streamingParentMessageUuid = null;
      });
    }
  }

  void _finishDownloadToast(bool result) {
    if (mounted) {
      setState(() {
        _showDownloadToast = false;
      });
    } else {
      _showDownloadToast = false;
    }

    final completer = _downloadToastCompleter;
    _downloadToastCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
  }

  Future<bool> _ensureModelReady() async {
    if (_llm.isReady) return true;

    if (_downloadToastCompleter != null) {
      final result = await _downloadToastCompleter!.future;
      return result && _llm.isReady;
    }

    _downloadToastCompleter = Completer<bool>();
    if (mounted) {
      setState(() {
        _showDownloadToast = true;
      });
    } else {
      _showDownloadToast = true;
    }

    final result = await _downloadToastCompleter!.future;
    return result && _llm.isReady;
  }

  Future<void> _stopGeneration() async {
    if (!_isGenerating) return;

    _interruptRequested = true;
    try {
      await _llm.stopGeneration();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error stopping response: $e')),
        );
      }
    }
  }

  String? _nonPersistentResponseNotice(String text) {
    final normalized = text.trim();
    if (normalized == 'Model not loaded.') {
      return 'Model not loaded. Download a model first.';
    }
    if (normalized == 'No LLM provider configured.') {
      return 'No model provider configured.';
    }
    if (normalized == 'Already generating...') {
      return 'Already generating a response.';
    }
    return null;
  }

  bool _shouldPersistGeneratedResponse(String text) {
    return _nonPersistentResponseNotice(text) == null;
  }

  void _showNonPersistentResponseNotice(String text) {
    final notice = _nonPersistentResponseNotice(text);
    if (notice == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(notice)),
    );
  }

  void _startEditingMessage(ChatMessage message) {
    if (_editingMessage?.messageUuid == message.messageUuid) return;
    _draftBeforeEdit ??= _messageController.text;

    setState(() {
      _editingMessage = message;
    });

    _messageController.text = message.text;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: _messageController.text.length),
    );
    _messageFocusNode.requestFocus();
  }

  void _cancelEditing({bool restoreDraft = true}) {
    if (_editingMessage == null) return;
    final draft = _draftBeforeEdit ?? '';

    setState(() {
      _editingMessage = null;
      _draftBeforeEdit = null;
    });

    if (restoreDraft) {
      _messageController.text = draft;
    } else {
      _messageController.clear();
    }
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: _messageController.text.length),
    );
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isGenerating || _isDownloading) return;

    final editingMessage = _editingMessage;
    if (editingMessage != null) {
      if (text == editingMessage.text) {
        _cancelEditing(restoreDraft: false);
        FocusManager.instance.primaryFocus?.unfocus();
        return;
      }

      _shouldAutoScroll = true;
      if (!await _ensureModelReady()) {
        return;
      }

      await _llm.resetContext();

      final parentMessageUuid = editingMessage.parentMessageUuid;
      final targetSessionUuid = editingMessage.sessionUuid;
      final userMessageUuid = await ChatService.instance.sendMessage(
        targetSessionUuid,
        text,
        parentMessageUuid: parentMessageUuid,
        useSessionHeadWhenParentNull: false,
      );

      final selectionKey = parentMessageUuid ?? _rootBranchKey;
      final sessionKey = _currentSessionId ?? targetSessionUuid;
      _branchSelectionsForSession(sessionKey)[selectionKey] = userMessageUuid;
      _persistBranchSelection(sessionKey, selectionKey, userMessageUuid);

      _cancelEditing(restoreDraft: false);
      await _loadSessions();
      _scrollToBottom(force: true);
      FocusManager.instance.primaryFocus?.unfocus();

      setState(() {
        _isGenerating = true;
        _streamingResponse = '';
        _interruptRequested = false;
        _streamingParentMessageUuid = userMessageUuid;
        _branchSelectionsForSession(sessionKey)[userMessageUuid] =
            _streamingBranchKey;
      });

      try {
        final buffer = StringBuffer();
        final startTime = DateTime.now();
        int tokenCount = 0;

        await for (final token in _llm.generateStream(text)) {
          buffer.write(token);
          tokenCount = buffer
              .toString()
              .split(RegExp(r'\s+'))
              .where((s) => s.isNotEmpty)
              .length;
          setState(() {
            _streamingResponse = buffer.toString();
          });
          _scrollToBottom();
        }

        if (buffer.isNotEmpty) {
          final endTime = DateTime.now();
          final durationSeconds =
              endTime.difference(startTime).inMilliseconds / 1000.0;
          final tokensPerSecond =
              durationSeconds > 0 ? tokenCount / durationSeconds : 0.0;

          final messageUuid = await ChatService.instance.addAIMessage(
            targetSessionUuid,
            buffer.toString(),
            tokensPerSecond: tokensPerSecond,
            parentMessageUuid: userMessageUuid,
          );
          if (_interruptRequested) {
            _interruptedMessageUuids.add(messageUuid);
          }
          if (mounted) {
            setState(() {
              _branchSelectionsForSession(sessionKey)[userMessageUuid] =
                  messageUuid;
            });
          } else {
            _branchSelectionsForSession(sessionKey)[userMessageUuid] =
                messageUuid;
          }
          _persistBranchSelection(sessionKey, userMessageUuid, messageUuid);
          await _loadSessions();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      } finally {
        setState(() {
          _isGenerating = false;
          _streamingResponse = '';
          _interruptRequested = false;
          _streamingParentMessageUuid = null;
        });
      }
      return;
    }

    _messageController.clear();

    // Dismiss keyboard after sending message for better UX
    FocusManager.instance.primaryFocus?.unfocus();

    // Reset auto-scroll when user sends a new message
    _shouldAutoScroll = true;

    // Ensure model is ready
    if (!await _ensureModelReady()) {
      // User cancelled or error
      return;
    }

    // Create session if needed
    if (_currentSessionId == null) {
      try {
        final title = text.length > 30 ? '${text.substring(0, 27)}...' : text;
        final sessionId = await ChatService.instance.createSession(title);
        setState(() {
          _currentSessionId = sessionId;
          _currentTitle = title;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating chat: $e')),
          );
        }
        return;
      }
    }

    var targetSessionUuid = _currentSessionId!;
    String? parentMessageUuid;
    final session = _currentSession;
    if (session != null && session.messages.isNotEmpty) {
      final pathState = _buildMessagePath(session);
      if (pathState.messages.isNotEmpty) {
        final leaf = pathState.messages.last;
        targetSessionUuid = leaf.sessionUuid;
        parentMessageUuid = leaf.messageUuid;
      }
    }

    // Save user message
    final userMessageUuid = await ChatService.instance.sendMessage(
      targetSessionUuid,
      text,
      parentMessageUuid: parentMessageUuid,
    );
    final selectionKey = parentMessageUuid ?? _rootBranchKey;
    final sessionKey = _currentSessionId ?? targetSessionUuid;
    _branchSelectionsForSession(sessionKey)[selectionKey] = userMessageUuid;
    _persistBranchSelection(sessionKey, selectionKey, userMessageUuid);
    await _loadSessions();
    _scrollToBottom(force: true);

    // Generate AI response
    setState(() {
      _isGenerating = true;
      _streamingResponse = '';
      _interruptRequested = false;
      _streamingParentMessageUuid = userMessageUuid;
      _branchSelectionsForSession(sessionKey)[userMessageUuid] =
          _streamingBranchKey;
    });

    try {
      final buffer = StringBuffer();
      final startTime = DateTime.now();
      int tokenCount = 0;

      await for (final token in _llm.generateStream(text)) {
        buffer.write(token);
        // Simple token approximation: count words (split by whitespace)
        tokenCount = buffer
            .toString()
            .split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty)
            .length;
        setState(() {
          _streamingResponse = buffer.toString();
        });
        _scrollToBottom();
      }

      if (buffer.isNotEmpty) {
        final endTime = DateTime.now();
        final durationSeconds =
            endTime.difference(startTime).inMilliseconds / 1000.0;
        final tokensPerSecond =
            durationSeconds > 0 ? tokenCount / durationSeconds : 0.0;

        final messageUuid = await ChatService.instance.addAIMessage(
          targetSessionUuid,
          buffer.toString(),
          tokensPerSecond: tokensPerSecond,
          parentMessageUuid: userMessageUuid,
        );
        if (_interruptRequested) {
          _interruptedMessageUuids.add(messageUuid);
        }
        if (mounted) {
          setState(() {
            _branchSelectionsForSession(sessionKey)[userMessageUuid] =
                messageUuid;
          });
        } else {
          _branchSelectionsForSession(sessionKey)[userMessageUuid] =
              messageUuid;
        }
        _persistBranchSelection(sessionKey, userMessageUuid, messageUuid);
        await _loadSessions();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      setState(() {
        _isGenerating = false;
        _streamingResponse = '';
        _interruptRequested = false;
        _streamingParentMessageUuid = null;
      });
    }
  }

  Future<void> _logout() async {
    final result = await showChoiceDialog(
      context,
      title: 'Sign Out',
      body: 'This will stop syncing. Your local chats will remain.',
      firstButtonLabel: 'Sign Out',
      secondButtonLabel: 'Cancel',
      firstButtonType: ButtonType.neutral,
    );

    if (result?.action == ButtonAction.first) {
      await Configuration.instance.logout();
      if (mounted) setState(() {});
    }
  }

  void _navigateToSignIn() {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LoginPage(
          Configuration.instance,
          appBarTitle: Text(
            'ensu',
            style: getEnsuTextTheme(context).h3Bold,
          ),
        ),
      ),
    ).then((_) {
      setState(() {});
      if (_isLoggedIn) {
        ChatService.instance.sync();
      }
    });
  }

  void _navigateToSignInFromAppBar() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => LoginPage(
          Configuration.instance,
          appBarTitle: Text(
            'ensu',
            style: getEnsuTextTheme(context).h3Bold,
          ),
        ),
      ),
    ).then((_) {
      setState(() {});
      if (_isLoggedIn) {
        ChatService.instance.sync();
      }
    });
  }

  Future<void> _openLogs() async {
    Navigator.pop(context);
    if (!mounted) return;
    await sendLogs(
      context,
      'support@ente.io',
      postShare: () {},
    );
  }

  void _openModelSettings() {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const ModelSettingsPage(),
      ),
    );
  }

  Map<String, String> _branchSelectionsForSession(String sessionUuid) {
    return _branchSelectionsBySession.putIfAbsent(sessionUuid, () => {});
  }

  void _mergeBranchSelections(
    List<ChatSession> sessions,
    Map<String, Map<String, String>> persistedSelections,
  ) {
    final validSessionUuids =
        sessions.map((session) => session.sessionUuid).toSet();
    _branchSelectionsBySession.removeWhere(
      (sessionUuid, _) => !validSessionUuids.contains(sessionUuid),
    );

    for (final entry in persistedSelections.entries) {
      final selections =
          _branchSelectionsBySession.putIfAbsent(entry.key, () => {});
      for (final selectionEntry in entry.value.entries) {
        selections.putIfAbsent(
          selectionEntry.key,
          () => selectionEntry.value,
        );
      }
    }
  }

  _MessagePathState _buildMessagePath(ChatSession session) {
    final messages = session.messages;
    if (messages.isEmpty) {
      return const _MessagePathState.empty();
    }

    final byId = <String, ChatMessage>{};
    for (final message in messages) {
      byId[message.messageUuid] = message;
    }

    final childrenMap = <String?, List<ChatMessage>>{};
    for (final message in messages) {
      childrenMap.putIfAbsent(message.parentMessageUuid, () => []).add(message);
    }
    for (final entry in childrenMap.values) {
      entry.sort(_compareMessages);
    }

    final roots = <ChatMessage>[];
    for (final message in messages) {
      final parentId = message.parentMessageUuid;
      if (parentId == null || !byId.containsKey(parentId)) {
        roots.add(message);
      }
    }

    final dedupedRoots = _dedupeChildren(roots);
    if (dedupedRoots.isEmpty) {
      return const _MessagePathState.empty();
    }

    final branchSelections = _branchSelectionsForSession(session.sessionUuid);
    final branchSwitchers = <String, _BranchSwitcherState>{};
    final path = <ChatMessage>[];
    int? streamingIndex;

    final streamingParentId = _streamingParentMessageUuid;
    final hasStreaming = streamingParentId != null &&
        (_isGenerating || _streamingResponse.isNotEmpty) &&
        byId.containsKey(streamingParentId);

    late ChatMessage current;
    final rootSelectionTargets =
        dedupedRoots.map((message) => message.messageUuid).toList();
    if (dedupedRoots.length > 1) {
      final rootIndex = _resolveSelectionIndex(
        branchSelections,
        _rootBranchKey,
        rootSelectionTargets,
      );
      final selectedRoot = dedupedRoots[rootIndex];
      branchSwitchers[selectedRoot.messageUuid] = _buildBranchSwitcher(
        sessionUuid: session.sessionUuid,
        selectionKey: _rootBranchKey,
        selectedIndex: rootIndex,
        selectionTargets: rootSelectionTargets,
      );
      current = selectedRoot;
    } else {
      current = dedupedRoots.last;
    }

    final visited = <String>{};

    while (visited.add(current.messageUuid)) {
      path.add(current);
      final children = _dedupeChildren(childrenMap[current.messageUuid] ?? []);

      if (hasStreaming && current.messageUuid == streamingParentId) {
        final selectionTargets = [
          for (final child in children) child.messageUuid,
          _streamingBranchKey,
        ];
        final currentIndex = _resolveSelectionIndex(
          branchSelections,
          current.messageUuid,
          selectionTargets,
        );

        if (currentIndex == selectionTargets.length - 1) {
          branchSwitchers[_streamingBranchKey] = _buildBranchSwitcher(
            sessionUuid: session.sessionUuid,
            selectionKey: current.messageUuid,
            selectedIndex: currentIndex,
            selectionTargets: selectionTargets,
          );
          streamingIndex = path.length;
          break;
        }

        if (children.isNotEmpty) {
          final selectedChild = children[currentIndex];
          branchSwitchers[selectedChild.messageUuid] = _buildBranchSwitcher(
            sessionUuid: session.sessionUuid,
            selectionKey: current.messageUuid,
            selectedIndex: currentIndex,
            selectionTargets: selectionTargets,
          );
          current = selectedChild;
          continue;
        }
      }

      if (children.isEmpty) {
        break;
      }

      if (children.length > 1) {
        final selectionTargets =
            children.map((child) => child.messageUuid).toList();
        final currentIndex = _resolveSelectionIndex(
          branchSelections,
          current.messageUuid,
          selectionTargets,
        );
        final selectedChild = children[currentIndex];
        branchSwitchers[selectedChild.messageUuid] = _buildBranchSwitcher(
          sessionUuid: session.sessionUuid,
          selectionKey: current.messageUuid,
          selectedIndex: currentIndex,
          selectionTargets: selectionTargets,
        );
        current = selectedChild;
      } else {
        current = children.first;
      }
    }

    return _MessagePathState(
      messages: path,
      switchers: branchSwitchers,
      streamingIndex: streamingIndex,
    );
  }

  _BranchSwitcherState _buildBranchSwitcher({
    required String sessionUuid,
    required String selectionKey,
    required int selectedIndex,
    required List<String> selectionTargets,
  }) {
    return _BranchSwitcherState(
      current: selectedIndex + 1,
      total: selectionTargets.length,
      onPrevious: () => _updateBranchSelection(
        sessionUuid,
        selectionKey,
        selectionTargets,
        selectedIndex - 1,
      ),
      onNext: () => _updateBranchSelection(
        sessionUuid,
        selectionKey,
        selectionTargets,
        selectedIndex + 1,
      ),
    );
  }

  int _resolveSelectionIndex(
    Map<String, String> selections,
    String key,
    List<String> selectionTargets,
  ) {
    if (selectionTargets.isEmpty) return 0;
    final selected = selections[key];
    if (selected == null) {
      return selectionTargets.length - 1;
    }
    final index = selectionTargets.indexOf(selected);
    if (index == -1) {
      return selectionTargets.length - 1;
    }
    return index;
  }

  void _persistBranchSelection(
    String sessionUuid,
    String selectionKey,
    String selectedMessageUuid,
  ) {
    if (selectedMessageUuid == _streamingBranchKey) return;
    unawaited(ChatService.instance.setBranchSelection(
      sessionUuid,
      selectionKey,
      selectedMessageUuid,
    ));
  }

  void _updateBranchSelection(
    String sessionUuid,
    String selectionKey,
    List<String> selectionTargets,
    int newIndex,
  ) {
    final total = selectionTargets.length;
    if (total <= 1) return;
    if (_isGenerating) {
      unawaited(_stopGeneration());
    }
    final wrappedIndex = newIndex % total;
    final normalizedIndex =
        wrappedIndex < 0 ? wrappedIndex + total : wrappedIndex;
    final selectedTarget = selectionTargets[normalizedIndex];
    setState(() {
      _branchSelectionsForSession(sessionUuid)[selectionKey] = selectedTarget;
    });
    _persistBranchSelection(sessionUuid, selectionKey, selectedTarget);
  }

  List<ChatMessage> _dedupeChildren(List<ChatMessage> children) {
    if (children.length <= 1) {
      return children;
    }

    final sorted = List<ChatMessage>.from(children)..sort(_compareMessages);
    final unique = <ChatMessage>[];

    for (final child in sorted) {
      if (!_isDuplicateChild(child, unique)) {
        unique.add(child);
      }
    }

    return unique;
  }

  bool _isDuplicateChild(ChatMessage candidate, List<ChatMessage> siblings) {
    for (final sibling in siblings) {
      if (candidate.messageUuid == sibling.messageUuid) {
        continue;
      }
      if (candidate.isSelf == sibling.isSelf &&
          candidate.text == sibling.text &&
          (candidate.createdAt - sibling.createdAt).abs() <=
              ChatDag.defaultDuplicateWindowMs) {
        return true;
      }
    }

    return false;
  }

  int _compareMessages(ChatMessage a, ChatMessage b) {
    final timeCompare = a.createdAt.compareTo(b.createdAt);
    if (timeCompare != 0) return timeCompare;
    return a.messageUuid.compareTo(b.messageUuid);
  }

  @override
  Widget build(BuildContext context) {
    final email = Configuration.instance.getEmail() ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messageState = _currentSession == null
        ? const _MessagePathState.empty()
        : _buildMessagePath(_currentSession!);
    final messages = messageState.messages;
    final branchSwitchers = messageState.switchers;
    final streamingIndex = messageState.streamingIndex;
    final hasStreaming = streamingIndex != null &&
        (_isGenerating || _streamingResponse.isNotEmpty);

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: _buildAppBarTitle(isDark),
        centerTitle: false,
        titleSpacing: 0,
        leadingWidth: 52,
        // Hamburger menu icon with vertical alignment fix
        // Alternative offsets to try if needed: 1.0, 2.0, or 2.5
        leading: Align(
          alignment: Alignment.center,
          child: IconButton(
            icon: Center(
              child: Transform.translate(
                offset: const Offset(0, 1.5),
                child: const Icon(LucideIcons.menu, size: 22),
              ),
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => _scaffoldKey.currentState?.openDrawer(),
          ),
        ),
        actions: [
          if (!_isLoggedIn)
            TextButton.icon(
              onPressed: _navigateToSignInFromAppBar,
              icon: Icon(
                LucideIcons.logIn,
                size: 16,
                color: isDark ? EnsuColors.accentDark : EnsuColors.accent,
              ),
              label: Text(
                'Sign in',
                style: TextStyle(
                  color: isDark ? EnsuColors.accentDark : EnsuColors.accent,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(width: 4),
        ],
      ),
      drawer: _buildDrawer(email, isDark),
      body: DismissKeyboard(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: messages.isEmpty && _streamingResponse.isEmpty
                      ? _buildEmptyState(isDark)
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 16),
                          itemCount: messages.length + (hasStreaming ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (hasStreaming && index == streamingIndex) {
                              final branchSwitcher =
                                  branchSwitchers[_streamingBranchKey];
                              return _StreamingBubble(
                                text: _streamingResponse,
                                isLoading: _isGenerating,
                                branchSwitcher: branchSwitcher,
                              );
                            }

                            final messageIndex =
                                hasStreaming && index > streamingIndex
                                    ? index - 1
                                    : index;
                            final message = messages[messageIndex];
                            return _MessageBubble(
                              message: message,
                              isInterrupted: _interruptedMessageUuids
                                  .contains(message.messageUuid),
                              onRetry: message.isSelf
                                  ? null
                                  : () => _retryMessage(message),
                              onEdit: message.isSelf
                                  ? () => _startEditingMessage(message)
                                  : null,
                              branchSwitcher:
                                  branchSwitchers[message.messageUuid],
                            );
                          },
                        ),
                ),
                _buildMessageInput(isDark),
              ],
            ),
            if (_showDownloadToast)
              Positioned(
                left: 0,
                right: 0,
                top: 8,
                child: Material(
                  type: MaterialType.transparency,
                  child: DownloadToast(
                    onComplete: () => _finishDownloadToast(true),
                    onCancel: () => _finishDownloadToast(false),
                    onError: () {},
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAppBarTitle(bool isDark) {
    final sessionTitle = _currentSessionId == null ? '' : _currentTitle;
    if (sessionTitle.isEmpty || sessionTitle == 'ensu') {
      return const Text('ensu');
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('ensu'),
        Text(
          sessionTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: GoogleFonts.inter(
            fontSize: 12,
            letterSpacing: 0.3,
            color: isDark ? EnsuColors.mutedDark : EnsuColors.muted,
          ),
        ),
      ],
    );
  }

  Widget _buildDrawer(String email, bool isDark) {
    final accent = isDark ? EnsuColors.accentDark : EnsuColors.accent;
    final muted = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final rule = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final ink = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final surface = isDark ? EnsuColors.creamDark : EnsuColors.cream;
    final tint = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final tileShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    );

    return Drawer(
      child: Container(
        color: surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 24,
                left: 20,
                right: 20,
                bottom: 20,
              ),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    tint.withValues(alpha: 0.85),
                    surface,
                  ],
                ),
                border: Border(
                  bottom: BorderSide(color: rule),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onTap: _handleDeveloperTap,
                            behavior: HitTestBehavior.translucent,
                            child: Text(
                              'ensu',
                              style: GoogleFonts.cormorantGaramond(
                                fontSize: 32,
                                fontWeight: FontWeight.w400,
                                letterSpacing: 1,
                                color: ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isLoggedIn) ...[
                              SizedBox(
                                height: 40,
                                width: 40,
                                child: IconButton.filled(
                                  onPressed: () async {
                                    Navigator.pop(context);
                                    setState(() => _isLoading = true);
                                    try {
                                      final success =
                                          await ChatService.instance.sync();
                                      await _loadSessions();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              success
                                                  ? 'Sync completed'
                                                  : 'Sync failed',
                                            ),
                                            duration:
                                                const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      await _loadSessions();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(
                                          SnackBar(
                                            content: Text('Sync failed: $e'),
                                            duration:
                                                const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  icon: const Icon(LucideIcons.refreshCw,
                                      size: 18),
                                  style: IconButton.styleFrom(
                                    backgroundColor: tint,
                                    foregroundColor: ink,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                            ],
                            SizedBox(
                              height: 40,
                              width: 40,
                              child: IconButton.filled(
                                onPressed: _openLogs,
                                icon: const Icon(LucideIcons.bug, size: 18),
                                style: IconButton.styleFrom(
                                  backgroundColor: tint,
                                  foregroundColor: ink,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 40,
                              width: 40,
                              child: IconButton.filled(
                                onPressed: _openModelSettings,
                                icon: const Icon(LucideIcons.cpu, size: 18),
                                style: IconButton.styleFrom(
                                  backgroundColor: tint,
                                  foregroundColor: ink,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_isLoggedIn) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: rule),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.cloud, size: 14, color: accent),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              email,
                              style: TextStyle(
                                fontSize: 12,
                                color: muted,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _sessions.isEmpty
                      ? _buildEmptySessionsList(muted, tint, tileShape)
                      : _buildGroupedSessionsList(muted, tint, tileShape),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Divider(color: rule),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Column(
                children: [
                  if (_isLoggedIn) ...[
                    ListTile(
                      dense: true,
                      leading: const Icon(LucideIcons.logOut, size: 20),
                      title: const Text('Sign Out'),
                      shape: tileShape,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      onTap: () {
                        Navigator.pop(context);
                        _logout();
                      },
                    ),
                  ] else ...[
                    ListTile(
                      dense: true,
                      leading: Icon(LucideIcons.uploadCloud,
                          size: 20, color: accent),
                      title: Text(
                        'Sign In to Backup',
                        style: TextStyle(color: accent),
                      ),
                      subtitle: Text(
                        'Sync chats with Ente',
                        style: TextStyle(
                          fontSize: 12,
                          color: muted,
                        ),
                      ),
                      shape: tileShape,
                      tileColor: tint,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      onTap: _navigateToSignIn,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Groups sessions by date category and returns a map with category labels
  Map<String, List<ChatSession>> _groupSessionsByDate(
      List<ChatSession> sessions) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    final thisMonthStart = DateTime(now.year, now.month, 1);

    final Map<String, List<ChatSession>> grouped = {};

    for (final session in sessions) {
      final sessionDate =
          DateTime.fromMillisecondsSinceEpoch(session.updatedAt);
      final sessionDay =
          DateTime(sessionDate.year, sessionDate.month, sessionDate.day);

      String category;
      if (sessionDay.isAtSameMomentAs(today) || sessionDay.isAfter(today)) {
        category = 'TODAY';
      } else if (sessionDay.isAtSameMomentAs(yesterday)) {
        category = 'YESTERDAY';
      } else if (sessionDay.isAfter(thisWeekStart) ||
          sessionDay.isAtSameMomentAs(thisWeekStart)) {
        category = 'THIS WEEK';
      } else if (sessionDay.isAfter(lastWeekStart) ||
          sessionDay.isAtSameMomentAs(lastWeekStart)) {
        category = 'LAST WEEK';
      } else if (sessionDay.isAfter(thisMonthStart) ||
          sessionDay.isAtSameMomentAs(thisMonthStart)) {
        category = 'THIS MONTH';
      } else {
        category = 'OLDER';
      }

      grouped.putIfAbsent(category, () => []);
      grouped[category]!.add(session);
    }

    return grouped;
  }

  Widget _buildNewChatTile(Color tint, ShapeBorder tileShape) {
    return ListTile(
      dense: true,
      leading: const Icon(LucideIcons.plus, size: 18),
      title: const Text('New Chat'),
      shape: tileShape,
      tileColor: tint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      onTap: _startNewChat,
    );
  }

  Widget _buildEmptySessionsList(
      Color muted, Color tint, ShapeBorder tileShape) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      children: [
        _buildNewChatTile(tint, tileShape),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'No chats yet.\nStart typing to begin.',
            textAlign: TextAlign.center,
            style: GoogleFonts.sourceSerif4(
              fontSize: 14,
              color: muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGroupedSessionsList(
      Color muted, Color tint, ShapeBorder tileShape) {
    final grouped = _groupSessionsByDate(_sessions);

    // Define order for categories
    const categoryOrder = [
      'TODAY',
      'YESTERDAY',
      'THIS WEEK',
      'LAST WEEK',
      'THIS MONTH',
      'OLDER'
    ];

    final orderedCategories =
        categoryOrder.where((cat) => grouped.containsKey(cat)).toList();
    final totalItems = orderedCategories.fold<int>(
        0, (sum, cat) => sum + 1 + grouped[cat]!.length);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: 1 + totalItems,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildNewChatTile(tint, tileShape),
          );
        }

        final listIndex = index - 1;

        // Calculate which category and item this index corresponds to
        int runningIndex = 0;
        for (final category in orderedCategories) {
          final sessions = grouped[category]!;

          // Check if this is a category header
          if (listIndex == runningIndex) {
            return Padding(
              padding: EdgeInsets.only(
                left: 8,
                right: 4,
                top: runningIndex == 0 ? 12 : 20,
                bottom: 4,
              ),
              child: Text(
                category,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1,
                  color: muted,
                ),
              ),
            );
          }

          runningIndex++; // Move past header

          // Check if this index is within this category's sessions
          if (listIndex < runningIndex + sessions.length) {
            final sessionIndex = listIndex - runningIndex;
            final session = sessions[sessionIndex];
            final isSelected = session.sessionUuid == _currentSessionId;

            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: ListTile(
                dense: true,
                selected: isSelected,
                selectedTileColor: tint,
                shape: tileShape,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                title: Text(
                  session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
                subtitle: session.lastMessagePreview != null
                    ? Text(
                        session.lastMessagePreview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: muted,
                        ),
                      )
                    : null,
                onTap: () => _selectSession(session),
                trailing: IconButton(
                  icon: Icon(LucideIcons.x, size: 16, color: muted),
                  splashRadius: 18,
                  onPressed: () => _deleteSession(session.rootSessionUuid),
                ),
              ),
            );
          }

          runningIndex += sessions.length;
        }

        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildEmptyState(bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Start typing to begin a conversation',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isDark ? EnsuColors.mutedDark : EnsuColors.muted,
          ),
        ),
      ),
    );
  }

  Widget _buildEditBanner(ChatMessage message, bool isDark) {
    final muted = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final accent = isDark ? EnsuColors.accentDark : EnsuColors.accent;
    final tint = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final preview = message.text.length > 60
        ? '${message.text.substring(0, 57)}...'
        : message.text;

    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(color: accent, width: 2),
        ),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.pencil, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Editing: $preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: muted,
              ),
            ),
          ),
          TextButton(
            onPressed: _cancelEditing,
            style: TextButton.styleFrom(
              foregroundColor: accent,
              padding: EdgeInsets.zero,
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Cancel',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInput(bool isDark) {
    final isKeyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 100;
    final arrowBorderColor = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final arrowFillColor = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final arrowIconColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;

    final inputContainer = Container(
      padding: const EdgeInsets.only(left: 20, right: 8, top: 4, bottom: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? EnsuColors.ruleDark : EnsuColors.rule,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_editingMessage != null)
              _buildEditBanner(_editingMessage!, isDark),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      decoration: InputDecoration(
                        hintText: _isGenerating
                            ? 'Generating... (keep typing)'
                            : _isDownloading
                                ? 'Downloading model... (queue messages)'
                                : 'Compose your message...',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintStyle: GoogleFonts.sourceSerif4(
                          color:
                              isDark ? EnsuColors.mutedDark : EnsuColors.muted,
                        ),
                      ),
                      style: GoogleFonts.sourceSerif4(
                        fontSize: 15,
                        height: 1.5,
                      ),
                      maxLines: 5,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Align(
                  alignment: Alignment.center,
                  child: IconButton(
                    icon: Center(
                      child: Transform.translate(
                        offset: const Offset(0,
                            -0.5), // Adjusted: less negative to move icon down slightly
                        child: _isGenerating
                            ? const Icon(
                                Icons.stop_circle,
                                size: 24,
                                color: Colors.red,
                              )
                            : Icon(
                                _isDownloading
                                    ? LucideIcons.download
                                    : LucideIcons.send,
                                size: 22,
                                color: _isDownloading
                                    ? (isDark
                                        ? EnsuColors.ruleDark
                                        : EnsuColors.rule)
                                    : (isDark
                                        ? EnsuColors.mutedDark
                                        : EnsuColors.muted),
                              ),
                      ),
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _isGenerating
                        ? _stopGeneration
                        : _isDownloading
                            ? null
                            : _sendMessage,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    const double arrowSize = 40;
    const double arrowGap = 6;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        inputContainer,
        if (isKeyboardOpen)
          Positioned(
            right: 8,
            top: -(arrowSize + arrowGap),
            child: Tooltip(
              message: 'Hide keyboard',
              child: Material(
                color: arrowFillColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: arrowBorderColor),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  child: SizedBox(
                    width: arrowSize,
                    height: arrowSize,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 22,
                      color: arrowIconColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BranchSwitcherState {
  final int current;
  final int total;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  const _BranchSwitcherState({
    required this.current,
    required this.total,
    required this.onPrevious,
    required this.onNext,
  });
}

class _MessagePathState {
  final List<ChatMessage> messages;
  final Map<String, _BranchSwitcherState> switchers;
  final int? streamingIndex;

  const _MessagePathState({
    required this.messages,
    required this.switchers,
    this.streamingIndex,
  });

  const _MessagePathState.empty()
      : messages = const [],
        switchers = const <String, _BranchSwitcherState>{},
        streamingIndex = null;
}

const String _timeWidthSample = '88:88 PM';

double _measureTextWidth(String text, TextStyle style) {
  final textPainter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout();
  return textPainter.width;
}

/// Message bubble widget
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isInterrupted;
  final VoidCallback? onRetry;
  final VoidCallback? onEdit;
  final _BranchSwitcherState? branchSwitcher;

  const _MessageBubble({
    required this.message,
    this.isInterrupted = false,
    this.onRetry,
    this.onEdit,
    this.branchSwitcher,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelf = message.isSelf;

    final textColor = isSelf
        ? (isDark ? EnsuColors.sentDark : EnsuColors.sent)
        : (isDark ? EnsuColors.inkDark : EnsuColors.ink);
    final timeColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final branchSwitcher = this.branchSwitcher;
    final hasBranchSwitcher =
        branchSwitcher != null && branchSwitcher.total > 1;
    final showEditAction = isSelf && onEdit != null;
    final showTokens = !isSelf && message.tokensPerSecond != null;
    final timeStyle = TextStyle(
      fontSize: 11,
      letterSpacing: 0.5,
      color: timeColor,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final timeLabel = _formatTime(message.createdAt);
    final timeWidth = _measureTextWidth(_timeWidthSample, timeStyle) + 2;

    return Padding(
      padding: EdgeInsets.only(
        top: 8,
        bottom: 20,
        left: isSelf ? 80 : 0,
        right: isSelf ? 0 : 80,
      ),
      child: Column(
        crossAxisAlignment:
            isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: () => _copyToClipboard(context),
            child: Text(
              message.text,
              style: GoogleFonts.sourceSerif4(
                fontSize: 15,
                height: 1.7,
                color: textColor,
              ),
              textAlign: isSelf ? TextAlign.right : TextAlign.left,
            ),
          ),
          const SizedBox(height: 6),
          // First row: self actions (edit, copy) or agent actions (copy, retry, tok/s)
          if (isSelf) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showEditAction) ...[
                  _ActionButton(
                    icon: LucideIcons.pencil,
                    color: timeColor,
                    tooltip: 'Edit',
                    onTap: onEdit!,
                    compact: true,
                  ),
                  const SizedBox(width: 6),
                ],
                _ActionButton(
                  icon: LucideIcons.copy,
                  color: timeColor,
                  tooltip: 'Copy',
                  onTap: () => _copyToClipboard(context),
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasBranchSwitcher) ...[
                  _InlineBranchSwitcher(
                    state: branchSwitcher,
                    color: timeColor,
                  ),
                  const SizedBox(width: 6),
                ],
                SizedBox(
                  width: timeWidth,
                  child: Text(
                    timeLabel,
                    style: timeStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ],
            ),
          ] else ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ActionButton(
                  icon: LucideIcons.copy,
                  color: timeColor,
                  tooltip: 'Copy',
                  onTap: () => _copyToClipboard(context),
                  compact: true,
                ),
                if (onRetry != null) ...[
                  _ActionButton(
                    icon: LucideIcons.refreshCw,
                    color: timeColor,
                    tooltip: 'Retry',
                    onTap: onRetry!,
                    compact: true,
                  ),
                ],
                if (showTokens) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${message.tokensPerSecond?.toStringAsFixed(1)} tok/s',
                    style: TextStyle(
                      fontSize: 10,
                      color: timeColor,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: timeWidth,
                  child: Text(
                    timeLabel,
                    style: timeStyle,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                ),
                if (hasBranchSwitcher) ...[
                  const SizedBox(width: 6),
                  _InlineBranchSwitcher(
                    state: branchSwitcher,
                    color: timeColor,
                  ),
                ],
              ],
            ),
          ],
          if (!isSelf && isInterrupted) ...[
            const SizedBox(height: 4),
            Text(
              'Interrupted',
              style: TextStyle(
                fontSize: 11,
                color: timeColor,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: message.text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  String _formatTime(int timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final hour = date.hour;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
    final hourLabel = hour12.toString().padLeft(2, ' ');
    return '$hourLabel:$minute $period';
  }
}

class _InlineBranchSwitcher extends StatelessWidget {
  final _BranchSwitcherState state;
  final Color color;

  const _InlineBranchSwitcher({
    required this.state,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (state.total <= 1) {
      return const SizedBox.shrink();
    }

    final totalWidth = state.total.toString().length;
    final currentLabel = state.current.toString().padLeft(totalWidth, ' ');
    final switcherLabel = '$currentLabel/${state.total}';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _TextActionButton(
          label: '<',
          color: color,
          tooltip: 'Previous branch',
          onTap: state.onPrevious,
          compact: true,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            switcherLabel,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.4,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        _TextActionButton(
          label: '>',
          color: color,
          tooltip: 'Next branch',
          onTap: state.onNext,
          compact: true,
        ),
      ],
    );
  }
}

class _TextActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final bool compact;

  const _TextActionButton({
    required this.label,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 48.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size / 2),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: size,
              minHeight: size,
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: color,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Action button with touch target for accessibility
/// When compact is true, uses 36x36dp touch target for tighter layout
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final bool compact;

  const _ActionButton({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = compact ? 36.0 : 48.0;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size / 2),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: size,
              minHeight: size,
            ),
            child: Center(
              child: Icon(icon, size: 16, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// Streaming response bubble with animated cursor
class _StreamingBubble extends StatefulWidget {
  final String text;
  final bool isLoading;
  final _BranchSwitcherState? branchSwitcher;

  const _StreamingBubble({
    required this.text,
    required this.isLoading,
    this.branchSwitcher,
  });

  @override
  State<_StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends State<_StreamingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _cursorController;
  late Animation<double> _cursorOpacity;

  @override
  void initState() {
    super.initState();
    _cursorController = AnimationController(
      duration: const Duration(milliseconds: 530),
      vsync: this,
    );
    _cursorOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _cursorController, curve: Curves.easeInOut),
    );
    if (widget.isLoading && widget.text.isNotEmpty) {
      _cursorController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant _StreamingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isLoading && widget.text.isNotEmpty) {
      if (!_cursorController.isAnimating) {
        _cursorController.repeat(reverse: true);
      }
    } else {
      _cursorController.stop();
      _cursorController.value = 0;
    }
  }

  @override
  void dispose() {
    _cursorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final mutedColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final cursorColor = isDark ? EnsuColors.accentDark : EnsuColors.accent;
    final branchSwitcher = widget.branchSwitcher;
    final hasBranchSwitcher =
        branchSwitcher != null && branchSwitcher.total > 1;

    return Padding(
      padding: EdgeInsets.only(
        top: 8,
        bottom: hasBranchSwitcher ? 12 : 20,
        right: 80,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.text.isEmpty && widget.isLoading)
            _LoadingDots(color: mutedColor)
          else
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: widget.text,
                    style: GoogleFonts.sourceSerif4(
                      fontSize: 15,
                      height: 1.7,
                      color: textColor,
                    ),
                  ),
                  if (widget.isLoading)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: AnimatedBuilder(
                        animation: _cursorOpacity,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _cursorOpacity.value,
                            child: Container(
                              width: 2,
                              height: 18,
                              margin: const EdgeInsets.only(left: 1),
                              decoration: BoxDecoration(
                                color: cursorColor,
                                borderRadius: BorderRadius.circular(1),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          if (hasBranchSwitcher) ...[
            const SizedBox(height: 6),
            _InlineBranchSwitcher(
              state: branchSwitcher,
              color: mutedColor,
            ),
          ],
        ],
      ),
    );
  }
}

/// Animated loading dots
class _LoadingDots extends StatefulWidget {
  final Color color;

  const _LoadingDots({required this.color});

  @override
  State<_LoadingDots> createState() => _LoadingDotsState();
}

class _LoadingDotsState extends State<_LoadingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final dots = _getDots(_controller.value);
        return Text(
          dots,
          style: GoogleFonts.sourceSerif4(
            fontSize: 15,
            color: widget.color,
            fontStyle: FontStyle.italic,
          ),
        );
      },
    );
  }

  String _getDots(double value) {
    if (value < 0.25) return '.';
    if (value < 0.5) return '..';
    if (value < 0.75) return '...';
    return '';
  }
}
