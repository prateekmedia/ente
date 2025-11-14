import 'package:ente_auth/ente_theme_data.dart';
import 'package:ente_auth/l10n/l10n.dart';
import 'package:ente_auth/theme/ente_theme.dart';
import 'package:flutter/material.dart';

/// Widget displayed when a specific code fails to render
class CodeRenderErrorWidget extends StatelessWidget {
  final String? issuer;
  final String? account;
  final String errorMessage;

  const CodeRenderErrorWidget({
    super.key,
    this.issuer,
    this.account,
    required this.errorMessage,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final codeIdentifier = _buildCodeIdentifier();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.codeCardBackgroundColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: colorScheme.errorCodeProgressColor.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.error_outline,
                size: 20,
                color: colorScheme.errorCodeProgressColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.error,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.errorCardTextColor,
                  ),
                ),
              ),
            ],
          ),
          if (codeIdentifier != null) ...[
            const SizedBox(height: 8),
            Text(
              codeIdentifier,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            context.l10n.couldNotLoadCode,
            style: TextStyle(
              fontSize: 13,
              color: colorScheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  String? _buildCodeIdentifier() {
    if (issuer != null && account != null && account!.isNotEmpty) {
      return '$issuer ($account)';
    } else if (issuer != null) {
      return issuer;
    } else if (account != null) {
      return account;
    }
    return null;
  }
}
