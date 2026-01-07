import 'dart:async';

import 'package:ensu/auth/email_entry_page.dart';
import 'package:ensu/core/configuration.dart';
import 'package:ensu/services/chat_service.dart';
import 'package:ensu/services/llm/llm_provider.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:ensu/ui/widgets/dismiss_keyboard.dart';
import 'package:ensu/ui/widgets/download_toast.dart';
import 'package:ente_ui/components/buttons/button_widget.dart';
import 'package:ente_ui/components/buttons/models/button_type.dart';
import 'package:ente_ui/utils/dialog_util.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons/lucide_icons.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<ChatSession> _sessions = [];
  int? _currentSessionId;
  ChatSession? _currentSession;
  String _currentTitle = 'ensu';
  bool _isLoading = false;
  bool _isGenerating = false;
  bool _isDownloading = false;
  String _streamingResponse = '';
  StreamSubscription? _chatsSubscription;
  StreamSubscription? _downloadProgressSubscription;
  double _previousBottomInset = 0;
  bool _shouldAutoScroll = true;

  LLMService get _llm => LLMService.instance;
  bool get _isLoggedIn => Configuration.instance.hasConfiguredAccount();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSessions();
    _chatsSubscription = eventBus.on<ChatsUpdatedEvent>().listen((_) {
      _loadSessions();
    });
    
    // Listen to scroll position to detect manual scroll-up during streaming
    _scrollController.addListener(_onScroll);
    
    // Listen to download progress
    _downloadProgressSubscription = _llm.downloadProgress.listen((progress) {
      if (mounted) {
        final isDownloading = progress.percent > 0 && progress.percent < 100 &&
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

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    
    // Check if user scrolled up (not at the bottom)
    final position = _scrollController.position;
    final isAtBottom = position.pixels >= position.maxScrollExtent - 50;
    
    if (_isGenerating && !isAtBottom && _shouldAutoScroll) {
      // User scrolled up during streaming - disable auto-scroll
      setState(() {
        _shouldAutoScroll = false;
      });
    } else if (isAtBottom && !_shouldAutoScroll) {
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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _chatsSubscription?.cancel();
    _downloadProgressSubscription?.cancel();
    super.dispose();
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

  Future<void> _loadSessions() async {
    try {
      final sessions = await ChatService.instance.getAllSessions();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _isLoading = false;

          if (_currentSessionId != null) {
            _currentSession =
                sessions.where((s) => s.id == _currentSessionId).firstOrNull;
            if (_currentSession != null) {
              _currentTitle = _currentSession!.title;
            }
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _selectSession(ChatSession session) {
    _llm.resetContext();
    setState(() {
      _currentSessionId = session.id;
      _currentSession = session;
      _currentTitle = session.title;
      _streamingResponse = '';
      _shouldAutoScroll = true;
    });
    Navigator.pop(context);
    _scrollToBottom(force: true);
  }

  void _startNewChat() {
    _llm.resetContext();
    setState(() {
      _currentSessionId = null;
      _currentSession = null;
      _currentTitle = 'ensu';
      _streamingResponse = '';
    });
    Navigator.pop(context);
  }

  Future<void> _deleteSession(int sessionId) async {
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
      await ChatService.instance.deleteSession(sessionId);
      if (_currentSessionId == sessionId) {
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
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _retryLastMessage() async {
    if (_currentSessionId == null || _isGenerating) return;

    // Delete the last AI message and get the last user message
    final lastUserMessage = await ChatService.instance.deleteLastAIMessage(_currentSessionId!);
    await _loadSessions();
    
    if (lastUserMessage == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No message to retry')),
        );
      }
      return;
    }

    // Ensure model is ready
    if (!await _ensureModelReady()) {
      return;
    }

    // Reset LLM context and regenerate
    await _llm.resetContext();
    _shouldAutoScroll = true;
    
    setState(() {
      _isGenerating = true;
      _streamingResponse = '';
    });

    try {
      final buffer = StringBuffer();
      final startTime = DateTime.now();
      int tokenCount = 0;

      await for (final token in _llm.generateStream(lastUserMessage)) {
        buffer.write(token);
        tokenCount = buffer.toString().split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty).length;
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

        await ChatService.instance.addAIMessage(
          _currentSessionId!, 
          buffer.toString(),
          tokensPerSecond: tokensPerSecond,
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
      });
    }
  }

  Future<bool> _ensureModelReady() async {
    if (_llm.isReady) return true;

    // Show download toast (non-blocking)
    final result = await DownloadToastOverlay.show(context);

    return result && _llm.isReady;
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _isGenerating || _isDownloading) return;

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

    // Save user message
    await ChatService.instance.sendMessage(_currentSessionId!, text);
    await _loadSessions();
    _scrollToBottom(force: true);

    // Generate AI response
    setState(() {
      _isGenerating = true;
      _streamingResponse = '';
    });

    try {
      final buffer = StringBuffer();
      final startTime = DateTime.now();
      int tokenCount = 0;

      await for (final token in _llm.generateStream(text)) {
        buffer.write(token);
        // Simple token approximation: count words (split by whitespace)
        tokenCount = buffer.toString().split(RegExp(r'\s+'))
            .where((s) => s.isNotEmpty).length;
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

        await ChatService.instance.addAIMessage(
          _currentSessionId!, 
          buffer.toString(),
          tokensPerSecond: tokensPerSecond,
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
      MaterialPageRoute(builder: (context) => const EmailEntryPage()),
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
      MaterialPageRoute(builder: (context) => const EmailEntryPage()),
    ).then((_) {
      setState(() {});
      if (_isLoggedIn) {
        ChatService.instance.sync();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final email = Configuration.instance.getEmail() ?? '';
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final messages = _currentSession?.messages ?? [];

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
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty && _streamingResponse.isEmpty
                  ? _buildEmptyState(isDark)
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      itemCount: messages.length + (_streamingResponse.isNotEmpty ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index < messages.length) {
                          final message = messages[index];
                          // Find if this is the last agent message (for showing retry button)
                          final isLastAgentMessage = !message.isSelf && 
                              !_isGenerating &&
                              _streamingResponse.isEmpty &&
                              index == messages.lastIndexWhere((m) => !m.isSelf);
                          return _MessageBubble(
                            message: message,
                            isLastAgentMessage: isLastAgentMessage,
                            onRetry: isLastAgentMessage ? _retryLastMessage : null,
                          );
                        } else {
                          return _StreamingBubble(
                            text: _streamingResponse,
                            isLoading: _isGenerating,
                          );
                        }
                      },
                    ),
            ),
            _buildMessageInput(isDark),
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
                          Text(
                            'ensu',
                            style: GoogleFonts.cormorantGaramond(
                              fontSize: 32,
                              fontWeight: FontWeight.w400,
                              letterSpacing: 1,
                              color: ink,
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
                                      final success = await ChatService.instance.sync();
                                      await _loadSessions();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              success ? 'Sync completed' : 'Sync failed',
                                            ),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    } catch (e) {
                                      await _loadSessions();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('Sync failed: $e'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  icon: const Icon(LucideIcons.refreshCw, size: 18),
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
                                onPressed: _startNewChat,
                                icon: const Icon(LucideIcons.plus, size: 18),
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
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No chats yet.\nStart typing to begin.',
                              textAlign: TextAlign.center,
                              style: GoogleFonts.sourceSerif4(
                                fontSize: 14,
                                color: muted,
                              ),
                            ),
                          ),
                        )
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
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                      onTap: () {
                        Navigator.pop(context);
                        _logout();
                      },
                    ),
                  ] else ...[
                    ListTile(
                      dense: true,
                      leading: Icon(LucideIcons.uploadCloud, size: 20, color: accent),
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
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
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
  Map<String, List<ChatSession>> _groupSessionsByDate(List<ChatSession> sessions) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final thisWeekStart = today.subtract(Duration(days: today.weekday - 1));
    final lastWeekStart = thisWeekStart.subtract(const Duration(days: 7));
    final thisMonthStart = DateTime(now.year, now.month, 1);

    final Map<String, List<ChatSession>> grouped = {};

    for (final session in sessions) {
      final sessionDate = DateTime.fromMillisecondsSinceEpoch(session.updatedAt);
      final sessionDay = DateTime(sessionDate.year, sessionDate.month, sessionDate.day);

      String category;
      if (sessionDay.isAtSameMomentAs(today) || sessionDay.isAfter(today)) {
        category = 'TODAY';
      } else if (sessionDay.isAtSameMomentAs(yesterday)) {
        category = 'YESTERDAY';
      } else if (sessionDay.isAfter(thisWeekStart) || sessionDay.isAtSameMomentAs(thisWeekStart)) {
        category = 'THIS WEEK';
      } else if (sessionDay.isAfter(lastWeekStart) || sessionDay.isAtSameMomentAs(lastWeekStart)) {
        category = 'LAST WEEK';
      } else if (sessionDay.isAfter(thisMonthStart) || sessionDay.isAtSameMomentAs(thisMonthStart)) {
        category = 'THIS MONTH';
      } else {
        category = 'OLDER';
      }

      grouped.putIfAbsent(category, () => []);
      grouped[category]!.add(session);
    }

    return grouped;
  }

  Widget _buildGroupedSessionsList(Color muted, Color tint, ShapeBorder tileShape) {
    final grouped = _groupSessionsByDate(_sessions);
    
    // Define order for categories
    const categoryOrder = ['TODAY', 'YESTERDAY', 'THIS WEEK', 'LAST WEEK', 'THIS MONTH', 'OLDER'];
    
    final orderedCategories = categoryOrder.where((cat) => grouped.containsKey(cat)).toList();
    
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      itemCount: orderedCategories.fold<int>(0, (sum, cat) => sum + 1 + grouped[cat]!.length),
      itemBuilder: (context, index) {
        // Calculate which category and item this index corresponds to
        int runningIndex = 0;
        for (final category in orderedCategories) {
          final sessions = grouped[category]!;
          
          // Check if this is a category header
          if (index == runningIndex) {
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
          if (index < runningIndex + sessions.length) {
            final sessionIndex = index - runningIndex;
            final session = sessions[sessionIndex];
            final isSelected = session.id == _currentSessionId;
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: ListTile(
                dense: true,
                selected: isSelected,
                selectedTileColor: tint,
                shape: tileShape,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
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
                  onPressed: () => _deleteSession(session.id),
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

  Widget _buildMessageInput(bool isDark) {
    return Container(
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextField(
                controller: _messageController,
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
                    color: isDark ? EnsuColors.mutedDark : EnsuColors.muted,
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
                    offset: const Offset(0, -0.5),  // Adjusted: less negative to move icon down slightly
                    child: Icon(
                      _isGenerating
                          ? LucideIcons.hourglass
                          : _isDownloading
                              ? LucideIcons.download
                              : LucideIcons.send,
                      size: 20,
                      color: (_isGenerating || _isDownloading)
                          ? (isDark ? EnsuColors.ruleDark : EnsuColors.rule)
                          : (isDark ? EnsuColors.mutedDark : EnsuColors.muted),
                    ),
                  ),
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: (_isGenerating || _isDownloading) ? null : _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Message bubble widget
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isLastAgentMessage;
  final VoidCallback? onRetry;

  const _MessageBubble({
    required this.message,
    this.isLastAgentMessage = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelf = message.isSelf;

    final textColor = isSelf
        ? (isDark ? EnsuColors.sentDark : EnsuColors.sent)
        : (isDark ? EnsuColors.inkDark : EnsuColors.ink);
    final timeColor = isDark ? EnsuColors.mutedDark : EnsuColors.muted;

    return Padding(
      padding: EdgeInsets.only(
        top: 8,
        bottom: 20,
        left: isSelf ? 80 : 0,
        right: isSelf ? 0 : 80,
      ),
      child: Column(
        crossAxisAlignment: isSelf ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
          // First row: Copy and Retry buttons for agent messages
          if (!isSelf) ...[
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
                if (isLastAgentMessage && onRetry != null) ...[
                  _ActionButton(
                    icon: LucideIcons.refreshCw,
                    color: timeColor,
                    tooltip: 'Retry',
                    onTap: onRetry!,
                    compact: true,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
          ],
          // Second row (or first for self messages): Time and token/s
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(message.createdAt),
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.5,
                  color: timeColor,
                ),
              ),
              if (!isSelf && message.tokensPerSecond != null) ...[
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
    return '$hour12:$minute $period';
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

  const _StreamingBubble({required this.text, required this.isLoading});

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

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 20, right: 80),
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
