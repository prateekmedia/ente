import 'dart:async';
import 'dart:convert';

import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

class TodoListBlock {
  final String title;
  final String? status;
  final List<String> items;

  const TodoListBlock({
    required this.title,
    required this.items,
    this.status,
  });
}

class AssistantParts {
  final String markdown;
  final String think;
  final List<TodoListBlock> todoLists;

  const AssistantParts({
    required this.markdown,
    required this.think,
    this.todoLists = const [],
  });
}

AssistantParts parseAssistantParts(String raw) {
  if (raw.isEmpty) {
    return const AssistantParts(markdown: '', think: '');
  }

  final todoExtraction = _extractTodoBlocks(raw);
  final cleaned = todoExtraction.text;

  const startTag = '<think>';
  const endTag = '</think>';

  final visible = StringBuffer();
  final think = StringBuffer();

  var index = 0;
  while (index < cleaned.length) {
    final start = cleaned.indexOf(startTag, index);
    if (start == -1) {
      visible.write(cleaned.substring(index));
      break;
    }

    visible.write(cleaned.substring(index, start));

    final thinkStart = start + startTag.length;
    final end = cleaned.indexOf(endTag, thinkStart);
    if (end == -1) {
      think.write(cleaned.substring(thinkStart));
      break;
    }

    think.write(cleaned.substring(thinkStart, end));
    index = end + endTag.length;
  }

  var markdown = visible.toString();
  markdown = markdown.replaceFirst(RegExp(r'^[\r\n]+'), '');

  return AssistantParts(
    markdown: markdown,
    think: think.toString().trim(),
    todoLists: todoExtraction.todoLists,
  );
}

class _TodoExtraction {
  final String text;
  final List<TodoListBlock> todoLists;

  const _TodoExtraction({required this.text, required this.todoLists});
}

_TodoExtraction _extractTodoBlocks(String raw) {
  const startTag = '<todo_list>';
  const endTag = '</todo_list>';

  final blocks = <TodoListBlock>[];
  final buffer = StringBuffer();

  var index = 0;
  while (index < raw.length) {
    final start = raw.indexOf(startTag, index);
    if (start == -1) {
      buffer.write(raw.substring(index));
      break;
    }

    buffer.write(raw.substring(index, start));

    final contentStart = start + startTag.length;
    final end = raw.indexOf(endTag, contentStart);
    if (end == -1) {
      buffer.write(raw.substring(start));
      break;
    }

    final jsonText = raw.substring(contentStart, end).trim();
    final block = _parseTodoBlock(jsonText);
    if (block != null) {
      blocks.add(block);
    }

    index = end + endTag.length;
  }

  return _TodoExtraction(text: buffer.toString(), todoLists: blocks);
}

TodoListBlock? _parseTodoBlock(String raw) {
  if (raw.isEmpty) {
    return null;
  }

  dynamic payload;
  try {
    payload = jsonDecode(raw);
  } catch (_) {
    return null;
  }

  if (payload is! Map) {
    return null;
  }

  final title = payload['title']?.toString().trim().isNotEmpty == true
      ? payload['title'].toString()
      : 'Todo List';
  final status = payload['status']?.toString().trim();

  final items = <String>[];
  final rawItems = payload['items'];
  if (rawItems is List) {
    for (final item in rawItems) {
      if (item is String) {
        final trimmed = item.trim();
        if (trimmed.isNotEmpty) {
          items.add(trimmed);
        }
      } else if (item is Map) {
        final text = item['text']?.toString().trim();
        if (text != null && text.isNotEmpty) {
          items.add(text);
        }
      }
    }
  }

  return TodoListBlock(
    title: title,
    status: status == null || status.isEmpty ? null : status,
    items: items,
  );
}

class AssistantMessageRenderer extends StatelessWidget {
  final String rawText;
  final bool isStreaming;
  final String storageId;

  const AssistantMessageRenderer({
    super.key,
    required this.rawText,
    required this.storageId,
    required this.isStreaming,
  });

  @override
  Widget build(BuildContext context) {
    final parts = parseAssistantParts(rawText);
    final hasMarkdown = parts.markdown.trim().isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (parts.think.isNotEmpty) ...[
          AssistantThinkSection(
            storageId: storageId,
            thinkText: parts.think,
            isStreaming: isStreaming,
          ),
          const SizedBox(height: 8),
        ],
        if (parts.todoLists.isNotEmpty) ...[
          for (var i = 0; i < parts.todoLists.length; i++) ...[
            TodoListCard(block: parts.todoLists[i]),
            if (i < parts.todoLists.length - 1 || hasMarkdown)
              const SizedBox(height: 8),
          ],
        ],
        if (hasMarkdown) AssistantMarkdownView(markdown: parts.markdown),
      ],
    );
  }
}

class TodoListCard extends StatelessWidget {
  final TodoListBlock block;

  const TodoListCard({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final border = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final muted = isDark ? EnsuColors.mutedDark : EnsuColors.muted;
    final accent = isDark ? EnsuColors.accentDark : EnsuColors.accent;

    final headerStyle = GoogleFonts.sourceSerif4(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: textColor,
      height: 1.2,
    );
    final statusStyle = GoogleFonts.sourceSerif4(
      fontSize: 12.5,
      color: muted,
      height: 1.4,
    );
    final itemStyle = GoogleFonts.sourceSerif4(
      fontSize: 14,
      color: textColor,
      height: 1.5,
    );

    final items = block.items;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(block.title, style: headerStyle),
              const Spacer(),
              Text('${items.length}', style: statusStyle),
            ],
          ),
          if (block.status != null) ...[
            const SizedBox(height: 6),
            Text(block.status!, style: statusStyle),
          ],
          const SizedBox(height: 8),
          if (items.isEmpty)
            Text('No todos yet.', style: statusStyle)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Icon(
                          Icons.circle,
                          size: 6,
                          color: accent,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(items[i], style: itemStyle)),
                    ],
                  ),
                  if (i < items.length - 1) const SizedBox(height: 6),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _CopyableCodeBlockBuilder extends MarkdownElementBuilder {
  final TextStyle codeStyle;
  final EdgeInsets padding;
  final Decoration decoration;
  final Color iconColor;
  final Color iconBackground;
  final Color iconBorder;

  _CopyableCodeBlockBuilder({
    required this.codeStyle,
    required this.padding,
    required this.decoration,
    required this.iconColor,
    required this.iconBackground,
    required this.iconBorder,
  });

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final raw = element.textContent;
    if (raw.trim().isEmpty) {
      return const SizedBox.shrink();
    }

    final code = raw.endsWith('\n') ? raw.substring(0, raw.length - 1) : raw;

    return _CopyableCodeBlock(
      code: code,
      codeStyle: codeStyle,
      padding: padding,
      decoration: decoration,
      iconColor: iconColor,
      iconBackground: iconBackground,
      iconBorder: iconBorder,
    );
  }
}

class _CopyableCodeBlock extends StatelessWidget {
  final String code;
  final TextStyle codeStyle;
  final EdgeInsets padding;
  final Decoration decoration;
  final Color iconColor;
  final Color iconBackground;
  final Color iconBorder;

  const _CopyableCodeBlock({
    required this.code,
    required this.codeStyle,
    required this.padding,
    required this.decoration,
    required this.iconColor,
    required this.iconBackground,
    required this.iconBorder,
  });

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: code));
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('Copied code'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const buttonInset = 8.0;
    const buttonSizeReserve = 44.0;

    BorderRadius clipRadius = BorderRadius.circular(12);
    final decorationValue = decoration;
    if (decorationValue is BoxDecoration) {
      final radius = decorationValue.borderRadius;
      if (radius is BorderRadius) {
        clipRadius = radius;
      }
    }

    final contentPadding = padding.copyWith(
      bottom: padding.bottom + buttonSizeReserve,
    );

    return ClipRRect(
      borderRadius: clipRadius,
      child: Container(
        decoration: decoration,
        child: Stack(
          children: [
            Padding(
              padding: contentPadding,
              child: SelectionArea(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Text(
                    code,
                    style: codeStyle,
                    softWrap: false,
                  ),
                ),
              ),
            ),
            Positioned(
              right: buttonInset,
              bottom: buttonInset,
              child: Tooltip(
                message: 'Copy',
                child: Material(
                  color: iconBackground,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: iconBorder),
                  ),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => _copy(context),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: iconColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class AssistantMarkdownView extends StatelessWidget {
  final String markdown;

  const AssistantMarkdownView({super.key, required this.markdown});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final accent = isDark ? EnsuColors.accentDark : EnsuColors.accent;
    final codeBg = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final rule = isDark ? EnsuColors.ruleDark : EnsuColors.rule;

    final baseTextStyle = GoogleFonts.sourceSerif4(
      fontSize: 15,
      height: 1.7,
      color: textColor,
    );

    final codeStyle = GoogleFonts.jetBrainsMono(
      fontSize: 13,
      color: textColor,
    );

    final styleSheet = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: baseTextStyle,
      a: baseTextStyle.copyWith(color: accent),
      h1: baseTextStyle.copyWith(
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      h2: baseTextStyle.copyWith(
        fontSize: 20,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      h3: baseTextStyle.copyWith(
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      em: baseTextStyle,
      strong: baseTextStyle.copyWith(fontWeight: FontWeight.w700),
      listBullet: baseTextStyle,
      blockquote: baseTextStyle,
      blockquoteDecoration: BoxDecoration(
        color: codeBg,
        border: Border(left: BorderSide(color: rule, width: 3)),
      ),
      code: codeStyle.copyWith(backgroundColor: codeBg),
      codeblockPadding: const EdgeInsets.all(12),
      codeblockDecoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: rule),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: rule)),
      ),
    );

    return MarkdownBody(
      data: markdown,
      selectable: true,
      styleSheet: styleSheet,
      builders: {
        'pre': _CopyableCodeBlockBuilder(
          codeStyle: codeStyle,
          padding: const EdgeInsets.all(12),
          decoration: styleSheet.codeblockDecoration!,
          iconColor: isDark ? EnsuColors.inkDark : EnsuColors.ink,
          iconBackground: isDark
              ? EnsuColors.creamDark.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.65),
          iconBorder: rule,
        ),
      },
      onTapLink: (text, href, title) {
        final link = href;
        if (link == null) return;
        final uri = Uri.tryParse(link);
        if (uri == null) return;
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      },
    );
  }
}

class AssistantThinkSection extends StatefulWidget {
  final String storageId;
  final String thinkText;
  final bool isStreaming;

  const AssistantThinkSection({
    super.key,
    required this.storageId,
    required this.thinkText,
    required this.isStreaming,
  });

  @override
  State<AssistantThinkSection> createState() => _AssistantThinkSectionState();
}

class _AssistantThinkSectionState extends State<AssistantThinkSection>
    with TickerProviderStateMixin {
  bool _expanded = false;
  bool _initializedFromStorage = false;

  String get _storageKey => 'think-expanded:${widget.storageId}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initializedFromStorage) return;
    _initializedFromStorage = true;

    final bucket = PageStorage.of(context);
    final stored = bucket.readState(
      context,
      identifier: _storageKey,
    );
    if (stored is bool) {
      _expanded = stored;
    }
  }

  @override
  void didUpdateWidget(covariant AssistantThinkSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isStreaming && !widget.isStreaming) {
      _setExpanded(false);
    }
  }

  void _setExpanded(bool value) {
    if (_expanded == value) return;
    setState(() {
      _expanded = value;
    });
    PageStorage.of(context).writeState(
      context,
      value,
      identifier: _storageKey,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? EnsuColors.codeBgDark : EnsuColors.codeBg;
    final border = isDark ? EnsuColors.ruleDark : EnsuColors.rule;
    final textColor = isDark ? EnsuColors.inkDark : EnsuColors.ink;
    final muted = isDark ? EnsuColors.mutedDark : EnsuColors.muted;

    final showPeek = widget.isStreaming && !_expanded;

    final headerTextStyle = TextStyle(
      fontSize: 12,
      letterSpacing: 0.5,
      color: muted,
      fontWeight: FontWeight.w600,
    );

    final thinkStyle = GoogleFonts.jetBrainsMono(
      fontSize: 12.5,
      height: 1.45,
      color: textColor,
    );

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _setExpanded(!_expanded),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeInOut,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('THINK', style: headerTextStyle),
                    const Spacer(),
                    Icon(
                      _expanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      size: 18,
                      color: muted,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: 8),
                  SelectableText(widget.thinkText, style: thinkStyle),
                ] else if (showPeek) ...[
                  const SizedBox(height: 8),
                  StartTruncatedText(
                    text: widget.thinkText,
                    maxLines: 4,
                    style: thinkStyle,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class StartTruncatedText extends StatelessWidget {
  final String text;
  final int maxLines;
  final TextStyle style;

  const StartTruncatedText({
    super.key,
    required this.text,
    required this.maxLines,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final original = text;
        if (original.isEmpty) {
          return const SizedBox.shrink();
        }

        final painter = TextPainter(
          textDirection: TextDirection.ltr,
          maxLines: maxLines,
        );

        bool fits(String candidate) {
          painter.text = TextSpan(text: candidate, style: style);
          painter.layout(maxWidth: constraints.maxWidth);
          return !painter.didExceedMaxLines;
        }

        if (fits(original)) {
          return Text(original, style: style);
        }

        var low = 0;
        var high = original.length;
        var best = '…${original.substring(original.length - 1)}';

        while (low <= high) {
          final mid = (low + high) >> 1;
          final candidate = '…${original.substring(mid)}';
          if (fits(candidate)) {
            best = candidate;
            high = mid - 1;
          } else {
            low = mid + 1;
          }
        }

        return Text(best, style: style, maxLines: maxLines);
      },
    );
  }
}
