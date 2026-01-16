import 'package:flutter/material.dart';

/// A widget that dismisses the keyboard when the user taps outside of text fields
/// or swipes down on the content area.
/// 
/// Usage:
/// ```dart
/// DismissKeyboard(
///   child: YourContent(),
/// )
/// ```
class DismissKeyboard extends StatelessWidget {
  final Widget child;
  
  /// If true, allows swipe down gesture to dismiss keyboard
  final bool enableSwipeToDismiss;

  const DismissKeyboard({
    super.key,
    required this.child,
    this.enableSwipeToDismiss = true,
  });

  void _dismissKeyboard(BuildContext context) {
    final currentFocus = FocusScope.of(context);
    if (!currentFocus.hasPrimaryFocus && currentFocus.focusedChild != null) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (enableSwipeToDismiss) {
      return GestureDetector(
        onTap: () => _dismissKeyboard(context),
        onVerticalDragEnd: (details) {
          // Dismiss keyboard on swipe down (positive velocity)
          if (details.primaryVelocity != null && details.primaryVelocity! > 100) {
            _dismissKeyboard(context);
          }
        },
        behavior: HitTestBehavior.translucent,
        child: child,
      );
    }

    return GestureDetector(
      onTap: () => _dismissKeyboard(context),
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}

/// A mixin that provides keyboard dismiss functionality for StatefulWidgets.
/// 
/// Usage:
/// ```dart
/// class _MyPageState extends State<MyPage> with KeyboardDismissMixin {
///   // Call dismissKeyboard() when needed
/// }
/// ```
mixin KeyboardDismissMixin<T extends StatefulWidget> on State<T> {
  void dismissKeyboard() {
    final currentFocus = FocusScope.of(context);
    if (!currentFocus.hasPrimaryFocus && currentFocus.focusedChild != null) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
  }
}
