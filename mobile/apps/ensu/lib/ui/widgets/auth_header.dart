import 'package:flutter/material.dart';

/// Page header for auth screens with consistent styling.
/// Contains title and optional subtitle.
class AuthPageHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const AuthPageHeader({
    super.key,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                  fontSize: 32,
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(top: 0),
              child: Text(
                subtitle!,
                style: Theme.of(context).textTheme.titleMedium!.copyWith(
                      fontSize: 14,
                    ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Subtitle that appears below the header (for email display etc.)
class AuthSubtitle extends StatelessWidget {
  final String text;

  const AuthSubtitle({
    super.key,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium!.copyWith(
              fontSize: 14,
            ),
      ),
    );
  }
}
