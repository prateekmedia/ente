import 'package:flutter/material.dart';

PopupMenuButton<dynamic> reportBugPopupMenu(BuildContext context) {
  // Deprecated: previously showed a "Contact support" action.
  // Kept for API compatibility; intentionally renders nothing.
  return PopupMenuButton<dynamic>(
    enabled: false,
    itemBuilder: (_) => const <PopupMenuEntry<dynamic>>[],
    child: const SizedBox.shrink(),
  );
}
