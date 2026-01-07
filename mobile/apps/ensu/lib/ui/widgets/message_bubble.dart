import 'package:ensu/models/chat_message.dart';
import 'package:ensu/ui/theme/ensu_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isSelf = message.sender == MessageSender.self;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    // Colors based on sender and theme
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
          // Message text
          GestureDetector(
            onLongPress: () => _copyToClipboard(context),
            child: Text(
              message.text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: textColor,
                height: 1.7,
              ),
              textAlign: isSelf ? TextAlign.right : TextAlign.left,
            ),
          ),
          const SizedBox(height: 6),
          // Timestamp row
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _formatTime(message.createdAt),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: timeColor,
                  letterSpacing: 0.5,
                ),
              ),
              if (!isSelf) ...[
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _copyToClipboard(context),
                  child: Icon(LucideIcons.copy, size: 14, color: timeColor),
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
