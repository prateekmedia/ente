import "package:flutter/material.dart";
import "package:intl/intl.dart";
import "package:logging/logging.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/models/file/file.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/components/buttons/icon_button_widget.dart";
import "package:photos/ui/viewer/file/no_thumbnail_widget.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";

/// Widget that displays collections in a tree structure with selection support
/// Used in collection action sheet for add/move operations
class CollectionTreeSelector extends StatefulWidget {
  final List<Collection> collections;
  final List<Collection> selectedCollections;
  final bool enableSelection;
  final Function(Collection)? onCollectionTap;
  final String searchQuery;

  const CollectionTreeSelector({
    required this.collections,
    required this.selectedCollections,
    this.enableSelection = false,
    this.onCollectionTap,
    this.searchQuery = "",
    super.key,
  });

  @override
  State<CollectionTreeSelector> createState() => _CollectionTreeSelectorState();
}

class _CollectionTreeSelectorState extends State<CollectionTreeSelector> {
  final CollectionsTreeService _treeService = CollectionsTreeService.instance;
  final Set<int> _expandedNodes = {};
  late CollectionTree _tree;

  @override
  void initState() {
    super.initState();
    _buildTree();
    // Auto-expand root level
    for (final root in _tree.roots) {
      _expandedNodes.add(root.collection.id);
    }
  }

  @override
  void didUpdateWidget(CollectionTreeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collections != widget.collections) {
      _buildTree();
    }
  }

  void _buildTree() {
    _tree = _treeService.getTree(forceRefresh: true);
  }

  void _toggleExpanded(int collectionID) {
    setState(() {
      if (_expandedNodes.contains(collectionID)) {
        _expandedNodes.remove(collectionID);
      } else {
        _expandedNodes.add(collectionID);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // If search is active, show flat filtered list
    if (widget.searchQuery.isNotEmpty) {
      final filteredCollections = widget.collections
          .where(
            (c) => c.displayName
                .toLowerCase()
                .contains(widget.searchQuery.toLowerCase()),
          )
          .toList();
      return ListView.separated(
        itemCount: filteredCollections.length,
        itemBuilder: (context, index) {
          return _buildFlatCollectionItem(filteredCollections[index]);
        },
        separatorBuilder: (context, index) => const SizedBox(height: 8),
      );
    }

    // Show tree structure when no search
    final items = _buildFlatList();
    return ListView.separated(
      itemCount: items.length,
      itemBuilder: (context, index) {
        return _buildTreeItem(items[index]);
      },
      separatorBuilder: (context, index) => const SizedBox(height: 8),
    );
  }

  /// Builds a flat list from the tree for display
  List<_TreeDisplayItem> _buildFlatList() {
    final List<_TreeDisplayItem> items = [];

    void traverse(CollectionTreeNode node, int depth) {
      items.add(
        _TreeDisplayItem(
          node: node,
          depth: depth,
          isExpanded: _expandedNodes.contains(node.collection.id),
          hasChildren: !node.isLeaf,
        ),
      );

      if (_expandedNodes.contains(node.collection.id)) {
        for (final child in node.children) {
          traverse(child, depth + 1);
        }
      }
    }

    for (final root in _tree.roots) {
      traverse(root, 0);
    }

    return items;
  }

  Widget _buildTreeItem(_TreeDisplayItem item) {
    final collection = item.node.collection;
    final indentWidth = item.depth * 24.0;

    return Padding(
      padding: EdgeInsets.only(left: indentWidth),
      child: Row(
        children: [
          // Expand/collapse button
          if (item.hasChildren)
            GestureDetector(
              onTap: () => _toggleExpanded(collection.id),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                child: Icon(
                  item.isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 20,
                  color: getEnteColorScheme(context).textMuted,
                ),
              ),
            )
          else
            const SizedBox(width: 32),

          // Collection item
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onCollectionTap?.call(collection),
              child: _buildCollectionItem(collection, item.hasChildren),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlatCollectionItem(Collection collection) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onCollectionTap?.call(collection),
      child: _buildCollectionItem(collection, false),
    );
  }

  Widget _buildCollectionItem(Collection collection, bool hasChildren) {
    final textTheme = getEnteTextTheme(context);
    final colorScheme = getEnteColorScheme(context);
    const sideOfThumbnail = 60.0;
    final isSelected = widget.selectedCollections.contains(collection);

    return AnimatedContainer(
      curve: Curves.easeOut,
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        border: Border.all(
          color:
              isSelected ? colorScheme.strokeMuted : colorScheme.strokeFainter,
        ),
        borderRadius: const BorderRadius.all(Radius.circular(6)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            flex: 6,
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: sideOfThumbnail,
                    width: sideOfThumbnail,
                    child: Stack(
                      children: [
                        FutureBuilder<EnteFile?>(
                          future:
                              CollectionsService.instance.getCover(collection),
                          builder: (context, snapshot) {
                            if (snapshot.hasData) {
                              final thumbnail = snapshot.data!;
                              return ThumbnailWidget(
                                thumbnail,
                                showFavForAlbumOnly: true,
                                shouldShowOwnerAvatar: false,
                              );
                            } else {
                              return const NoThumbnailWidget(addBorder: false);
                            }
                          },
                        ),
                        // Folder indicator for albums with children
                        if (hasChildren)
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: colorScheme.backgroundElevated
                                    .withValues(alpha: 0.9),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: colorScheme.strokeFaint,
                                  width: 0.5,
                                ),
                              ),
                              child: Icon(
                                Icons.folder,
                                size: 12,
                                color: colorScheme.primary700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          collection.displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                        FutureBuilder<int>(
                          future: CollectionsService.instance.getFileCount(
                            collection,
                          ),
                          builder: (context, snapshot) {
                            if (snapshot.hasData) {
                              return Text(
                                "${NumberFormat().format(snapshot.data!)} items",
                                style: textTheme.miniMuted,
                              );
                            } else {
                              if (snapshot.hasError) {
                                Logger("CollectionTreeSelector").severe(
                                  "Failed to fetch file count of collection",
                                  snapshot.error,
                                );
                              }
                              return Text(
                                "",
                                style: textTheme.small.copyWith(
                                  color: colorScheme.textMuted,
                                ),
                              );
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.enableSelection)
            Flexible(
              flex: 1,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: isSelected
                    ? IconButtonWidget(
                        key: const ValueKey("selected"),
                        icon: Icons.check_circle_rounded,
                        iconButtonType: IconButtonType.secondary,
                        iconColor: colorScheme.blurStrokeBase,
                      )
                    : null,
              ),
            ),
        ],
      ),
    );
  }
}

class _TreeDisplayItem {
  final CollectionTreeNode node;
  final int depth;
  final bool isExpanded;
  final bool hasChildren;

  _TreeDisplayItem({
    required this.node,
    required this.depth,
    required this.isExpanded,
    required this.hasChildren,
  });
}
