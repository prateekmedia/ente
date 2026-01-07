import 'package:ensu/models/chat_session.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

class SessionTile extends StatelessWidget {
  final ChatSession session;
  final bool hasSynced;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const SessionTile({
    super.key,
    required this.session,
    required this.hasSynced,
    required this.onTap,
    required this.onDelete,
  });

  String _formatTime(int? timestamp) {
    if (timestamp == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays > 0) {
      return '${diff.inDays}d ago';
    } else if (diff.inHours > 0) {
      return '${diff.inHours}h ago';
    } else if (diff.inMinutes > 0) {
      return '${diff.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(
          session.title.isNotEmpty ? session.title[0].toUpperCase() : '?',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onPrimaryContainer,
          ),
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(session.title)),
          if (!hasSynced)
            const Icon(
              LucideIcons.cloud,
              size: 16,
              color: Colors.orange,
            ),
        ],
      ),
      subtitle: Text(
        session.lastMessagePreview ?? 'No messages yet',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _formatTime(session.lastMessageAt ?? session.createdAt),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      onTap: onTap,
      onLongPress: onDelete,
    );
  }
}
