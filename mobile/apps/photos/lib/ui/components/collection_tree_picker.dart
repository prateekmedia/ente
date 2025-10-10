import "package:flutter/material.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/services/collections_tree_service.dart";
import "package:photos/theme/ente_theme.dart";

/// Widget for picking a collection from a tree structure
class CollectionTreePicker extends StatefulWidget {
  final String title;
  final Collection? currentParent;
  final Set<int> excludedCollectionIDs;
  final ValueChanged<int?> onSelect;

  const CollectionTreePicker({
    required this.title,
    this.currentParent,
    this.excludedCollectionIDs = const {},
    required this.onSelect,
    super.key,
  });

  @override
  State<CollectionTreePicker> createState() => _CollectionTreePickerState();
}

class _CollectionTreePickerState extends State<CollectionTreePicker> {
  final CollectionsTreeService _treeService = CollectionsTreeService.instance;
  late CollectionTree _tree;
  List<CollectionTreeNode> _currentLevel = [];
  final List<CollectionTreeNode?> _navigationStack = [null]; // null = root

  @override
  void initState() {
    super.initState();
    _tree = _treeService.getTree(forceRefresh: true);
    _loadCurrentLevel();
  }

  void _loadCurrentLevel() {
    final currentNode = _navigationStack.last;

    if (currentNode == null) {
      // Show root level collections
      _currentLevel = _tree.roots
          .where(
            (node) =>
                !widget.excludedCollectionIDs.contains(node.collection.id),
          )
          .toList();
    } else {
      // Show children of current node
      _currentLevel = currentNode.children
          .where(
            (node) =>
                !widget.excludedCollectionIDs.contains(node.collection.id),
          )
          .toList();
    }

    setState(() {});
  }

  void _navigateToNode(CollectionTreeNode? node) {
    _navigationStack.add(node);
    _loadCurrentLevel();
  }

  void _navigateBack() {
    if (_navigationStack.length > 1) {
      _navigationStack.removeLast();
      _loadCurrentLevel();
    }
  }

  void _navigateToBreadcrumb(int index) {
    if (index < _navigationStack.length - 1) {
      _navigationStack.removeRange(index + 1, _navigationStack.length);
      _loadCurrentLevel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = getEnteColorScheme(context);
    final textTheme = getEnteTextTheme(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          // Breadcrumb navigation
          if (_navigationStack.length > 1)
            _buildBreadcrumbs(colorScheme, textTheme),

          // "Select Root" option
          if (_navigationStack.last == null)
            _buildRootOption(colorScheme, textTheme),

          // Current level collections
          Expanded(
            child: _currentLevel.isEmpty
                ? _buildEmptyState(textTheme)
                : ListView.builder(
                    itemCount: _currentLevel.length,
                    itemBuilder: (context, index) {
                      final node = _currentLevel[index];
                      return _buildCollectionTile(node, colorScheme, textTheme);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbs(colorScheme, textTheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.backgroundElevated,
        border: Border(bottom: BorderSide(color: colorScheme.strokeFaint)),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Root
                  GestureDetector(
                    onTap: () => _navigateToBreadcrumb(0),
                    child: Text(
                      "Root",
                      style: textTheme.small.copyWith(
                        color: _navigationStack.length == 1
                            ? colorScheme.primary700
                            : colorScheme.textMuted,
                      ),
                    ),
                  ),

                  // Intermediate nodes
                  for (int i = 1; i < _navigationStack.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: colorScheme.textMuted,
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _navigateToBreadcrumb(i),
                      child: Text(
                        _navigationStack[i]!.collection.displayName,
                        style: textTheme.small.copyWith(
                          color: i == _navigationStack.length - 1
                              ? colorScheme.primary700
                              : colorScheme.textMuted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (_navigationStack.length > 1)
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: _navigateBack,
            ),
        ],
      ),
    );
  }

  Widget _buildRootOption(colorScheme, textTheme) {
    final isSelected = widget.currentParent == null;

    return ListTile(
      leading: Icon(
        Icons.folder_open,
        color: isSelected ? colorScheme.primary700 : colorScheme.textMuted,
      ),
      title: Text(
        "Root (No parent)",
        style: textTheme.body.copyWith(
          color: isSelected ? colorScheme.primary700 : null,
        ),
      ),
      trailing:
          isSelected ? Icon(Icons.check, color: colorScheme.primary700) : null,
      onTap: () {
        widget.onSelect(null);
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildCollectionTile(node, colorScheme, textTheme) {
    final collection = node.collection;
    final isSelected = widget.currentParent?.id == collection.id;
    final hasChildren = !node.isLeaf;

    return ListTile(
      leading: Icon(
        hasChildren ? Icons.folder : Icons.photo_album,
        color: isSelected ? colorScheme.primary700 : colorScheme.textMuted,
      ),
      title: Text(
        collection.displayName,
        style: textTheme.body.copyWith(
          color: isSelected ? colorScheme.primary700 : null,
        ),
      ),
      subtitle: hasChildren
          ? Text(
              "${node.children.length} nested album${node.children.length != 1 ? 's' : ''}",
              style: textTheme.small.copyWith(color: colorScheme.textMuted),
            )
          : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSelected) Icon(Icons.check, color: colorScheme.primary700),
          if (hasChildren)
            Icon(
              Icons.chevron_right,
              color: colorScheme.textMuted,
            ),
        ],
      ),
      onTap: () {
        if (hasChildren) {
          _navigateToNode(node);
        } else {
          widget.onSelect(collection.id);
          Navigator.of(context).pop();
        }
      },
      onLongPress: hasChildren
          ? null
          : () {
              widget.onSelect(collection.id);
              Navigator.of(context).pop();
            },
    );
  }

  Widget _buildEmptyState(textTheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          "No albums available",
          style: textTheme.body.copyWith(color: Colors.grey),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
