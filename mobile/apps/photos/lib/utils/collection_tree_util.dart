import "package:logging/logging.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";

/// Utility class for building and manipulating collection trees
class CollectionTreeUtil {
  static final _logger = Logger("CollectionTreeUtil");

  /// Builds a collection tree from a flat list of collections
  /// Orphaned collections (whose parent doesn't exist) are placed at root level
  static CollectionTree buildTree(List<Collection> collections) {
    // Create nodes for all collections
    final Map<int, CollectionTreeNode> nodeMap = {};
    final Map<int, List<CollectionTreeNode>> childrenByParent = {};

    // First pass: create all nodes
    for (final collection in collections) {
      final node = CollectionTreeNode(collection: collection, children: []);
      nodeMap[collection.id] = node;
    }

    // Second pass: organize into parent-child relationships
    for (final node in nodeMap.values) {
      final parentID = node.parentID;

      // Root node or orphaned node (parent doesn't exist)
      if (parentID == 0 || !nodeMap.containsKey(parentID)) {
        childrenByParent.putIfAbsent(0, () => []).add(node);
        if (parentID != 0 && !nodeMap.containsKey(parentID)) {
          _logger.warning(
            "Collection ${node.collection.id} has parent $parentID that doesn't exist, placing at root",
          );
        }
      } else {
        childrenByParent.putIfAbsent(parentID, () => []).add(node);
      }
    }

    // Third pass: build the tree and calculate depths
    final List<CollectionTreeNode> roots = childrenByParent[0] ?? [];
    _buildSubtree(roots, childrenByParent, nodeMap, 0);

    return CollectionTree(roots: roots, nodeMap: nodeMap);
  }

  /// Recursively builds subtrees and updates node depths
  static void _buildSubtree(
    List<CollectionTreeNode> nodes,
    Map<int, List<CollectionTreeNode>> childrenByParent,
    Map<int, CollectionTreeNode> nodeMap,
    int depth,
  ) {
    for (final node in nodes) {
      // Update depth (create new node with updated depth)
      final updatedNode = CollectionTreeNode(
        collection: node.collection,
        depth: depth,
      );

      // Get and add children
      final children = childrenByParent[node.collection.id] ?? [];
      for (final child in children) {
        updatedNode.addChild(child);
      }

      // Update the map reference
      nodeMap[node.collection.id] = updatedNode;

      // Recursively process children
      if (children.isNotEmpty) {
        _buildSubtree(children, childrenByParent, nodeMap, depth + 1);
      }
    }
  }

  /// Gets the maximum depth in a collection tree
  static int getMaxDepth(CollectionTree tree) {
    int maxDepth = 0;
    for (final node in tree.allNodes) {
      if (node.depth > maxDepth) {
        maxDepth = node.depth;
      }
    }
    return maxDepth;
  }

  /// Returns all collections at a specific depth level
  static List<Collection> getCollectionsAtDepth(
    CollectionTree tree,
    int depth,
  ) {
    return tree.allNodes
        .where((node) => node.depth == depth)
        .map((node) => node.collection)
        .toList();
  }

  /// Flattens a tree into a list in depth-first order
  static List<Collection> flattenDepthFirst(CollectionTree tree) {
    final List<Collection> result = [];

    void traverse(CollectionTreeNode node) {
      result.add(node.collection);
      for (final child in node.children) {
        traverse(child);
      }
    }

    for (final root in tree.roots) {
      traverse(root);
    }

    return result;
  }

  /// Flattens a tree into a list in breadth-first order
  static List<Collection> flattenBreadthFirst(CollectionTree tree) {
    final List<Collection> result = [];
    final List<CollectionTreeNode> queue = List.from(tree.roots);

    while (queue.isNotEmpty) {
      final node = queue.removeAt(0);
      result.add(node.collection);
      queue.addAll(node.children);
    }

    return result;
  }

  /// Gets all siblings of a collection (collections with the same parent)
  static List<Collection> getSiblings(
    CollectionTree tree,
    int collectionID, {
    bool includeSelf = false,
  }) {
    final node = tree.getNode(collectionID);
    if (node == null) return [];

    final parentID = node.parentID;
    final siblings = tree.allNodes
        .where(
          (n) =>
              n.parentID == parentID &&
              (includeSelf || n.collection.id != collectionID),
        )
        .map((n) => n.collection)
        .toList();

    return siblings;
  }

  /// Gets all ancestors of a collection (parent, grandparent, etc.)
  static List<Collection> getAncestors(CollectionTree tree, int collectionID) {
    final path = tree.getPath(collectionID);
    if (path == null || path.isEmpty) return [];

    // Remove the collection itself, leaving only ancestors
    return path.sublist(0, path.length - 1);
  }

  /// Checks if a collection has any children
  static bool hasChildren(CollectionTree tree, int collectionID) {
    final node = tree.getNode(collectionID);
    return node != null && !node.isLeaf;
  }

  /// Gets immediate children of a collection
  static List<Collection> getChildren(CollectionTree tree, int collectionID) {
    final node = tree.getNode(collectionID);
    if (node == null) return [];
    return node.children.map((child) => child.collection).toList();
  }

  /// Gets all descendants of a collection (children, grandchildren, etc.)
  static List<Collection> getDescendants(
    CollectionTree tree,
    int collectionID,
  ) {
    final node = tree.getNode(collectionID);
    if (node == null) return [];
    return node.descendants;
  }

  /// Counts total descendants of a collection
  static int countDescendants(CollectionTree tree, int collectionID) {
    final node = tree.getNode(collectionID);
    if (node == null) return 0;
    return node.descendantCount;
  }
}
