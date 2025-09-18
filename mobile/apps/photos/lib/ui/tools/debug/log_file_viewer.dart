import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import "package:photos/generated/l10n.dart";
import "package:photos/service_locator.dart";
import 'package:photos/theme/ente_theme.dart';
import 'package:photos/ui/common/loading_widget.dart';

class LogFileViewer extends StatefulWidget {
  final File file;
  const LogFileViewer(this.file, {super.key});

  @override
  State<LogFileViewer> createState() => _LogFileViewerState();
}

class _LogFileViewerState extends State<LogFileViewer> {
  String? _logs;
  String? _filteredLogs;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _selectedLogLevel = 'All';
  final List<String> _logLevels = [
    'All',
    'SEVERE',
    'WARNING',
    'INFO',
    'CONFIG',
    'FINE',
    'FINER',
    'FINEST',
  ];
  bool _showLineNumbers = false;
  bool _caseSensitiveSearch = false;
  int _matchCount = 0;
  int _currentMatchIndex = -1;
  final List<int> _matchPositions = [];

  @override
  void initState() {
    super.initState();
    widget.file.readAsString().then((logs) {
      setState(() {
        _logs = logs;
        _filteredLogs = logs;
      });
    });
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _filterLogs();
  }

  void _filterLogs() {
    if (_logs == null) return;

    String filtered = _logs!;
    _matchPositions.clear();
    _matchCount = 0;
    _currentMatchIndex = -1;

    // Filter by log level
    if (_selectedLogLevel != 'All') {
      final lines = filtered.split('\n');
      filtered = lines
          .where((line) => line.contains('[$_selectedLogLevel]'))
          .join('\n');
    }

    // Filter by search term
    final searchTerm = _searchController.text;
    if (searchTerm.isNotEmpty) {
      final lines = filtered.split('\n');
      final matchingLines = <String>[];

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final lineToSearch = _caseSensitiveSearch ? line : line.toLowerCase();
        final termToSearch =
            _caseSensitiveSearch ? searchTerm : searchTerm.toLowerCase();

        if (lineToSearch.contains(termToSearch)) {
          matchingLines.add(line);
          _matchPositions.add(i);
          _matchCount++;
        }
      }

      filtered = matchingLines.join('\n');

      if (_matchCount > 0 && _currentMatchIndex == -1) {
        _currentMatchIndex = 0;
      }
    }

    // Add line numbers if enabled
    if (_showLineNumbers && filtered.isNotEmpty) {
      final lines = filtered.split('\n');
      filtered = lines
          .asMap()
          .entries
          .map(
            (entry) =>
                '${(entry.key + 1).toString().padLeft(5)}: ${entry.value}',
          )
          .join('\n');
    }

    setState(() {
      _filteredLogs = filtered;
    });
  }

  void _scrollToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollToBottom() {
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _copyAllLogs() {
    Clipboard.setData(ClipboardData(text: _filteredLogs ?? ''));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _selectedLogLevel = 'All';
      _showLineNumbers = false;
      _caseSensitiveSearch = false;
    });
    _filterLogs();
  }

  void _navigateToMatch(int direction) {
    if (_matchCount == 0) return;

    setState(() {
      _currentMatchIndex = (_currentMatchIndex + direction) % _matchCount;
      if (_currentMatchIndex < 0) {
        _currentMatchIndex = _matchCount - 1;
      }
    });

    // TODO: Implement scrolling to specific match position
  }

  @override
  Widget build(BuildContext context) {
    final isInternalUser = flagService.internalUser;
    final colorScheme = getEnteColorScheme(context);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        title: Text(AppLocalizations.of(context).todaysLogs),
        actions: [
          if (isInternalUser) ...[
            if (_matchCount > 0 && _searchController.text.isNotEmpty) ...[
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: Text(
                    '${_currentMatchIndex + 1}/$_matchCount',
                    style: TextStyle(
                      color: colorScheme.textMuted,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                onPressed: () => _navigateToMatch(-1),
                tooltip: 'Previous match',
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                onPressed: () => _navigateToMatch(1),
                tooltip: 'Next match',
              ),
            ],
            IconButton(
              icon: const Icon(Icons.copy, size: 20),
              onPressed: _copyAllLogs,
              tooltip: 'Copy filtered logs',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (isInternalUser) _buildSearchBar(colorScheme),
          Expanded(
            child: _getBody(isInternalUser),
          ),
        ],
      ),
      floatingActionButton: isInternalUser ? _buildFloatingButtons() : null,
    );
  }

  Widget _buildSearchBar(colorScheme) {
    return Container(
      color: colorScheme.backgroundElevated,
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // Search input
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search logs...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 20),
                      onPressed: _clearSearch,
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: colorScheme.strokeFaint),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 8),
          // Filter controls
          Row(
            children: [
              // Log level dropdown
              Expanded(
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: colorScheme.strokeFaint),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedLogLevel,
                      isExpanded: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 20),
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.textBase,
                      ),
                      items: _logLevels.map((level) {
                        return DropdownMenuItem(
                          value: level,
                          child: Text(level),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() {
                          _selectedLogLevel = value!;
                        });
                        _filterLogs();
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Toggle buttons
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: colorScheme.strokeFaint),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        Icons.format_list_numbered,
                        size: 18,
                        color: _showLineNumbers
                            ? colorScheme.primary700
                            : colorScheme.textMuted,
                      ),
                      onPressed: () {
                        setState(() {
                          _showLineNumbers = !_showLineNumbers;
                        });
                        _filterLogs();
                      },
                      tooltip: 'Toggle line numbers',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                    Container(
                      width: 1,
                      height: 20,
                      color: colorScheme.strokeFaint,
                    ),
                    IconButton(
                      icon: Icon(
                        Icons.text_fields,
                        size: 18,
                        color: _caseSensitiveSearch
                            ? colorScheme.primary700
                            : colorScheme.textMuted,
                      ),
                      onPressed: () {
                        setState(() {
                          _caseSensitiveSearch = !_caseSensitiveSearch;
                        });
                        _filterLogs();
                      },
                      tooltip: 'Case sensitive',
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_filteredLogs != null &&
              _filteredLogs!.isEmpty &&
              _searchController.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'No matches found',
                style: TextStyle(
                  color: colorScheme.textMuted,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFloatingButtons() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: 'scrollTop',
          onPressed: _scrollToTop,
          tooltip: 'Scroll to top',
          child: const Icon(Icons.keyboard_arrow_up),
        ),
        const SizedBox(height: 8),
        FloatingActionButton.small(
          heroTag: 'scrollBottom',
          onPressed: _scrollToBottom,
          tooltip: 'Scroll to bottom',
          child: const Icon(Icons.keyboard_arrow_down),
        ),
      ],
    );
  }

  Widget _getBody(bool isInternalUser) {
    if (_filteredLogs == null) {
      return const EnteLoadingWidget();
    }

    if (_filteredLogs!.isEmpty) {
      return Center(
        child: Text(
          _searchController.text.isNotEmpty
              ? 'No matching logs found'
              : 'No logs available',
          style: TextStyle(
            color: getEnteColorScheme(context).textMuted,
            fontSize: 16,
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.only(left: 12, top: 8, right: 12),
      child: Scrollbar(
        controller: _scrollController,
        interactive: true,
        thickness: 4,
        radius: const Radius.circular(2),
        child: SingleChildScrollView(
          controller: _scrollController,
          child: isInternalUser
              ? SelectableText(
                  _filteredLogs!,
                  style: const TextStyle(
                    fontFeatures: [
                      FontFeature.tabularFigures(),
                    ],
                    height: 1.2,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                )
              : Text(
                  _filteredLogs!,
                  style: const TextStyle(
                    fontFeatures: [
                      FontFeature.tabularFigures(),
                    ],
                    height: 1.2,
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
        ),
      ),
    );
  }
}
