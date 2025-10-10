import "package:photos/models/collection/collection.dart";

/// Represents a node in the collection tree hierarchy
class CollectionTreeNode {
  final Collection collection;
  final List<CollectionTreeNode> children;
  final int depth;

  CollectionTreeNode({
    required this.collection,
    List<CollectionTreeNode>? children,
    this.depth = 0,
  }) : children = children ?? [];

  /// Returns true if this node is a root node (no parent)
  bool get isRoot => (collection.pubMagicMetadata.parentID ?? 0) == 0;

  /// Returns true if this node is a leaf node (no children)
  bool get isLeaf => children.isEmpty;

  /// Returns the parent ID, or 0 if this is a root node
  int get parentID => collection.pubMagicMetadata.parentID ?? 0;

  /// Returns the total count of descendants (children, grandchildren, etc.)
  int get descendantCount {
    int count = children.length;
    for (final child in children) {
      count += child.descendantCount;
    }
    return count;
  }

  /// Returns a flat list of all descendant collections
  List<Collection> get descendants {
    final List<Collection> result = [];
    for (final child in children) {
      result.add(child.collection);
      result.addAll(child.descendants);
    }
    return result;
  }

  /// Returns a flat list of all descendant collection IDs
  Set<int> get descendantIDs {
    final Set<int> result = {};
    for (final child in children) {
      result.add(child.collection.id);
      result.addAll(child.descendantIDs);
    }
    return result;
  }

  /// Checks if the given collection ID is a descendant of this node
  bool isDescendant(int collectionID) {
    return descendantIDs.contains(collectionID);
  }

  /// Adds a child node to this node
  void addChild(CollectionTreeNode child) {
    children.add(child);
  }

  /// Removes a child node from this node
  bool removeChild(int collectionID) {
    final initialLength = children.length;
    children.removeWhere((c) => c.collection.id == collectionID);
    return children.length < initialLength;
  }

  /// Finds a node by collection ID in this subtree
  CollectionTreeNode? findNode(int collectionID) {
    if (collection.id == collectionID) {
      return this;
    }
    for (final child in children) {
      final found = child.findNode(collectionID);
      if (found != null) {
        return found;
      }
    }
    return null;
  }
}

/// Represents the entire collection tree structure
class CollectionTree {
  final List<CollectionTreeNode> roots;
  final Map<int, CollectionTreeNode> _nodeMap;

  CollectionTree({required this.roots, Map<int, CollectionTreeNode>? nodeMap})
      : _nodeMap = nodeMap ?? {};

  /// Gets a node by collection ID
  CollectionTreeNode? getNode(int collectionID) {
    return _nodeMap[collectionID];
  }

  /// Gets all nodes as a flat list
  List<CollectionTreeNode> get allNodes => _nodeMap.values.toList();

  /// Gets all collections as a flat list
  List<Collection> get allCollections =>
      _nodeMap.values.map((node) => node.collection).toList();

  /// Gets the path from root to the given collection ID
  /// Returns null if collection is not found
  List<Collection>? getPath(int collectionID) {
    final node = _nodeMap[collectionID];
    if (node == null) return null;

    final List<Collection> path = [];
    CollectionTreeNode? current = node;

    while (current != null) {
      path.insert(0, current.collection);
      final parentID = current.parentID;
      if (parentID == 0) break;
      current = _nodeMap[parentID];
    }

    return path;
  }

  /// Gets breadcrumb trail for a collection (list of collection names from root)
  List<String> getBreadcrumbs(int collectionID) {
    final path = getPath(collectionID);
    if (path == null) return [];
    return path.map((c) => c.displayName).toList();
  }

  /// Checks if moving sourceID under targetID would create a cycle
  bool wouldCreateCycle(int sourceID, int targetID) {
    if (sourceID == targetID) return true;

    final sourceNode = _nodeMap[sourceID];
    if (sourceNode == null) return false;

    // Check if target is a descendant of source
    return sourceNode.isDescendant(targetID);
  }

  /// Gets the depth of a collection in the tree
  int getDepth(int collectionID) {
    final node = _nodeMap[collectionID];
    return node?.depth ?? 0;
  }
}
