import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";
import "package:photos/ui/collections/album/row_item.dart";

/// Widget that displays albums in a nested/hierarchical grid structure
/// with expand/collapse functionality
class NestedAlbumGridWidget extends StatefulWidget {
  final List<Collection> collections;
  final SelectedAlbums? selectedAlbums;
  final bool enableSelection;
  final VoidCallback? onAlbumTap;
  final double thumbnailSize;

  const NestedAlbumGridWidget({
    required this.collections,
    this.selectedAlbums,
    this.enableSelection = false,
    this.onAlbumTap,
    this.thumbnailSize = 160.0,
    super.key,
  });

  @override
  State<NestedAlbumGridWidget> createState() => _NestedAlbumGridWidgetState();
}

class _NestedAlbumGridWidgetState extends State<NestedAlbumGridWidget> {
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
  void didUpdateWidget(NestedAlbumGridWidget oldWidget) {
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
    final items = _buildFlatList();

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index >= items.length) return null;
            final item = items[index];
            return _buildTreeSection(item, context);
          },
          childCount: items.length,
        ),
      ),
    );
  }

  /// Builds a flat list from the tree for display, grouping by parent
  List<_TreeDisplaySection> _buildFlatList() {
    final List<_TreeDisplaySection> sections = [];

    void traverse(CollectionTreeNode node, int depth) {
      final children = node.children;

      if (children.isNotEmpty && _expandedNodes.contains(node.collection.id)) {
        sections.add(
          _TreeDisplaySection(
            parentNode: node,
            depth: depth,
            childNodes: children,
          ),
        );

        for (final child in children) {
          traverse(child, depth + 1);
        }
      }
    }

    // Add root level as a section
    if (_tree.roots.isNotEmpty) {
      sections.insert(
        0,
        _TreeDisplaySection(
          parentNode: null,
          depth: 0,
          childNodes: _tree.roots,
        ),
      );
    }

    // Traverse to build nested sections
    for (final root in _tree.roots) {
      traverse(root, 0);
    }

    return sections;
  }

  Widget _buildTreeSection(_TreeDisplaySection section, BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount =
        (screenWidth / widget.thumbnailSize).floor().clamp(2, 6);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section header (for non-root sections)
        if (section.parentNode != null) ...[
          const SizedBox(height: 16),
          Padding(
            padding: EdgeInsets.only(left: section.depth * 16.0),
            child: Row(
              children: [
                // Expand/collapse button
                GestureDetector(
                  onTap: () =>
                      _toggleExpanded(section.parentNode!.collection.id),
                  child: Icon(
                    _expandedNodes.contains(section.parentNode!.collection.id)
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 20,
                    color: colorScheme.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.folder,
                  size: 16,
                  color: colorScheme.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    section.parentNode!.collection.displayName,
                    style: textTheme.bodyBold,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],

        // Grid of albums
        Padding(
          padding: EdgeInsets.only(left: section.depth * 16.0),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.75,
            ),
            itemCount: section.childNodes.length,
            itemBuilder: (context, index) {
              final node = section.childNodes[index];
              return _buildAlbumTile(node, colorScheme, textTheme);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildAlbumTile(
    CollectionTreeNode node,
    colorScheme,
    textTheme,
  ) {
    final collection = node.collection;
    final hasChildren = !node.isLeaf;

    return Stack(
      children: [
        AlbumRowItemWidget(
          collection,
          widget.thumbnailSize,
          selectedAlbums: widget.selectedAlbums,
          onTapCallback: widget.enableSelection
              ? (c) {
                  widget.selectedAlbums?.toggleSelection(c);
                  widget.onAlbumTap?.call();
                }
              : null,
          onLongPressCallback: widget.enableSelection
              ? (c) {
                  widget.selectedAlbums?.toggleSelection(c);
                  widget.onAlbumTap?.call();
                }
              : null,
        ),
        // Folder indicator for albums with children
        if (hasChildren)
          Positioned(
            top: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colorScheme.backgroundElevated.withOpacity(0.9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: colorScheme.strokeFaint,
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.folder,
                size: 16,
                color: colorScheme.primary700,
              ),
            ),
          ),
      ],
    );
  }
}

class _TreeDisplaySection {
  final CollectionTreeNode? parentNode;
  final int depth;
  final List<CollectionTreeNode> childNodes;

  _TreeDisplaySection({
    this.parentNode,
    required this.depth,
    required this.childNodes,
  });
}
