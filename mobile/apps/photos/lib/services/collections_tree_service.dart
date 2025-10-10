import "package:logging/logging.dart";
import "package:photos/core/configuration.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/utils/collection_tree_util.dart";
import "package:photos/utils/collection_validation_util.dart";

/// Service for managing collection tree operations
/// Provides high-level API for nested album functionality
class CollectionsTreeService {
  static final _logger = Logger("CollectionsTreeService");

  final CollectionsService _collectionsService;
  CollectionTree? _cachedTree;
  int? _cacheTimestamp;

  static const int _cacheValidityMs = 5000; // 5 seconds

  CollectionsTreeService._privateConstructor()
      : _collectionsService = CollectionsService.instance;

  static final CollectionsTreeService instance =
      CollectionsTreeService._privateConstructor();

  /// Gets the current collection tree, building it from active collections
  /// Returns cached tree if available and fresh
  CollectionTree getTree({bool forceRefresh = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;

    if (!forceRefresh &&
        _cachedTree != null &&
        _cacheTimestamp != null &&
        (now - _cacheTimestamp!) < _cacheValidityMs) {
      return _cachedTree!;
    }

    final collections = _collectionsService.getActiveCollections();
    final tree = CollectionTreeUtil.buildTree(collections);

    _cachedTree = tree;
    _cacheTimestamp = now;

    return tree;
  }

  /// Clears the cached tree, forcing a rebuild on next access
  void clearCache() {
    _cachedTree = null;
    _cacheTimestamp = null;
  }

  /// Moves a collection under a new parent
  /// Validates the operation before performing it
  /// Returns ValidationResult indicating success or failure
  Future<ValidationResult> moveCollection({
    required Collection child,
    required int? newParentID,
  }) async {
    final currentUserID = Configuration.instance.getUserID()!;
    final tree = getTree(forceRefresh: true);

    // Get parent collection if newParentID is provided
    Collection? newParent;
    if (newParentID != null && newParentID != 0) {
      newParent = _collectionsService.getCollectionByID(newParentID);
      if (newParent == null) {
        return const ValidationResult.invalid("Parent album not found");
      }
    }

    // Validate the move operation
    final validation = CollectionValidationUtil.validateSetParent(
      child: child,
      newParent: newParent,
      currentUserID: currentUserID,
      tree: tree,
    );

    if (!validation.isValid) {
      _logger.warning(
        "Validation failed for moving collection ${child.id}: ${validation.errorMessage}",
      );
      return validation;
    }

    // Perform the move
    final oldParentID = child.pubMagicMetadata.parentID;
    final currentDepth = tree.getDepth(child.id);

    _logger.info(
      "Moving album: id=${child.id}, old_parent=$oldParentID, "
      "new_parent=$newParentID, current_depth=$currentDepth",
    );

    try {
      await _collectionsService.setParent(child, newParentID);
      clearCache(); // Invalidate cache after successful move

      final newDepth = getTree(forceRefresh: true).getDepth(child.id);
      _logger.info(
        "Album moved successfully: id=${child.id}, new_depth=$newDepth",
      );

      return const ValidationResult.valid();
    } catch (e, s) {
      _logger.severe("Failed to move collection", e, s);
      return ValidationResult.invalid("Failed to move album: ${e.toString()}");
    }
  }

  /// Gets the breadcrumb path for a collection
  List<String> getBreadcrumbs(int collectionID) {
    final tree = getTree();
    return tree.getBreadcrumbs(collectionID);
  }

  /// Gets the full path (list of collections) from root to the given collection
  List<Collection>? getPath(int collectionID) {
    final tree = getTree();
    return tree.getPath(collectionID);
  }

  /// Gets all children of a collection
  List<Collection> getChildren(int collectionID) {
    final tree = getTree();
    return CollectionTreeUtil.getChildren(tree, collectionID);
  }

  /// Gets all descendants of a collection (recursive)
  List<Collection> getDescendants(int collectionID) {
    final tree = getTree();
    return CollectionTreeUtil.getDescendants(tree, collectionID);
  }

  /// Gets all root-level collections (no parent)
  List<Collection> getRootCollections() {
    final tree = getTree();
    return tree.roots.map((node) => node.collection).toList();
  }

  /// Checks if a collection has any children
  bool hasChildren(int collectionID) {
    final tree = getTree();
    return CollectionTreeUtil.hasChildren(tree, collectionID);
  }

  /// Gets the depth of a collection in the tree
  int getDepth(int collectionID) {
    final tree = getTree();
    return tree.getDepth(collectionID);
  }

  /// Gets siblings of a collection (collections with same parent)
  List<Collection> getSiblings(int collectionID, {bool includeSelf = false}) {
    final tree = getTree();
    return CollectionTreeUtil.getSiblings(
      tree,
      collectionID,
      includeSelf: includeSelf,
    );
  }

  /// Gets all ancestors of a collection (parent, grandparent, etc.)
  List<Collection> getAncestors(int collectionID) {
    final tree = getTree();
    return CollectionTreeUtil.getAncestors(tree, collectionID);
  }

  /// Counts total descendants of a collection
  int countDescendants(int collectionID) {
    final tree = getTree();
    return CollectionTreeUtil.countDescendants(tree, collectionID);
  }

  /// Validates if a collection can have children
  ValidationResult canHaveChildren(Collection collection) {
    return CollectionValidationUtil.canHaveChildren(collection);
  }

  /// Validates if a collection can be deleted
  ValidationResult canDelete({
    required Collection collection,
    required bool deleteDescendants,
  }) {
    final currentUserID = Configuration.instance.getUserID()!;
    final tree = getTree();

    return CollectionValidationUtil.validateDelete(
      collection: collection,
      currentUserID: currentUserID,
      tree: tree,
      deleteDescendants: deleteDescendants,
    );
  }

  /// Gets collections organized by depth level
  Map<int, List<Collection>> getCollectionsByDepth() {
    final tree = getTree();
    final Map<int, List<Collection>> result = {};
    final maxDepth = CollectionTreeUtil.getMaxDepth(tree);

    for (int depth = 0; depth <= maxDepth; depth++) {
      result[depth] = CollectionTreeUtil.getCollectionsAtDepth(tree, depth);
    }

    return result;
  }

  /// Gets a flat list of collections in depth-first order
  List<Collection> getFlattenedDepthFirst() {
    final tree = getTree();
    return CollectionTreeUtil.flattenDepthFirst(tree);
  }

  /// Gets a flat list of collections in breadth-first order
  List<Collection> getFlattenedBreadthFirst() {
    final tree = getTree();
    return CollectionTreeUtil.flattenBreadthFirst(tree);
  }

  /// Checks if moving source under target would create a cycle
  bool wouldCreateCycle(int sourceID, int targetID) {
    final tree = getTree();
    return tree.wouldCreateCycle(sourceID, targetID);
  }
}
