import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";

/// Widget that displays breadcrumb navigation for a collection
class CollectionBreadcrumbsWidget extends StatelessWidget {
  final Collection collection;
  final VoidCallback? onTap;
  final int maxItems;

  const CollectionBreadcrumbsWidget({
    required this.collection,
    this.onTap,
    this.maxItems = 3,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final treeService = CollectionsTreeService.instance;
    final path = treeService.getPath(collection.id);

    if (path == null || path.length <= 1) {
      // No breadcrumbs needed for root-level collections
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    // Build breadcrumb items (excluding the current collection)
    final ancestors = path.sublist(0, path.length - 1);

    // Truncate if too many ancestors
    final displayAncestors = ancestors.length > maxItems
        ? [
            ...ancestors.take(1), // Always show root
            ...ancestors.skip(ancestors.length - (maxItems - 2)),
          ]
        : ancestors;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder,
              size: 14,
              color: colorScheme.textMuted,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (int i = 0; i < displayAncestors.length; i++) ...[
                      // Show ellipsis if we skipped items
                      if (i == 1 && ancestors.length > maxItems) ...[
                        Text(
                          "...",
                          style: textTheme.mini.copyWith(
                            color: colorScheme.textMuted,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(
                            Icons.chevron_right,
                            size: 12,
                            color: colorScheme.textMuted,
                          ),
                        ),
                      ] else ...[
                        Text(
                          displayAncestors[i].displayName,
                          style: textTheme.mini.copyWith(
                            color: colorScheme.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (i < displayAncestors.length - 1)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: Icon(
                              Icons.chevron_right,
                              size: 12,
                              color: colorScheme.textMuted,
                            ),
                          ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Widget that displays full breadcrumb path in a more prominent way
class CollectionBreadcrumbsFullWidget extends StatelessWidget {
  final Collection collection;
  final ValueChanged<Collection>? onNavigate;

  const CollectionBreadcrumbsFullWidget({
    required this.collection,
    this.onNavigate,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final treeService = CollectionsTreeService.instance;
    final path = treeService.getPath(collection.id);

    if (path == null || path.isEmpty) {
      return const SizedBox.shrink();
    }

    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < path.length; i++) ...[
              GestureDetector(
                onTap: onNavigate != null ? () => onNavigate!(path[i]) : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: i == path.length - 1
                        ? colorScheme.fillFaint
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    path[i].displayName,
                    style: textTheme.small.copyWith(
                      color: i == path.length - 1
                          ? colorScheme.textBase
                          : colorScheme.textMuted,
                      fontWeight: i == path.length - 1
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
              ),
              if (i < path.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colorScheme.textMuted,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
