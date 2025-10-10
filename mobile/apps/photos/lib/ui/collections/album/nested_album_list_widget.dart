import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_items.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/collections/album/list_item.dart";
import "package:photos/ui/viewer/gallery/collection_page.dart";
import "package:photos/utils/navigation_util.dart";

/// Widget that displays albums in a nested/hierarchical tree structure
/// with expand/collapse functionality
class NestedAlbumListWidget extends StatefulWidget {
  final List<Collection> collections;
  final SelectedAlbums? selectedAlbums;
  final bool enableSelection;
  final VoidCallback? onAlbumTap;

  const NestedAlbumListWidget({
    required this.collections,
    this.selectedAlbums,
    this.enableSelection = false,
    this.onAlbumTap,
    super.key,
  });

  @override
  State<NestedAlbumListWidget> createState() => _NestedAlbumListWidgetState();
}

class _NestedAlbumListWidgetState extends State<NestedAlbumListWidget> {
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
  void didUpdateWidget(NestedAlbumListWidget oldWidget) {
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
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final items = _buildFlatList();
          if (index >= items.length) return null;

          final item = items[index];
          return _buildTreeItem(item, colorScheme, textTheme);
        },
        childCount: _buildFlatList().length,
      ),
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

  Widget _buildTreeItem(
    _TreeDisplayItem item,
    colorScheme,
    textTheme,
  ) {
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
                  color: colorScheme.textMuted,
                ),
              ),
            )
          else
            const SizedBox(width: 32),

          // Album item
          Expanded(
            child: AlbumListItemWidget(
              collection,
              selectedAlbums: widget.selectedAlbums,
              onTapCallback: widget.enableSelection
                  ? (c) {
                      widget.selectedAlbums?.toggleSelection(c);
                      widget.onAlbumTap?.call();
                    }
                  : (c) async {
                      final thumbnail =
                          await CollectionsService.instance.getCover(c);
                      if (context.mounted) {
                        await routeToPage(
                          context,
                          CollectionPage(
                            CollectionWithThumbnail(c, thumbnail),
                          ),
                        );
                      }
                    },
              onLongPressCallback: widget.enableSelection
                  ? (c) {
                      widget.selectedAlbums?.toggleSelection(c);
                      widget.onAlbumTap?.call();
                    }
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
