import "package:logging/logging.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/collection/collection_tree.dart";
import "package:photos/utils/collection_tree_util.dart";

/// Result of a collection validation operation
class ValidationResult {
  final bool isValid;
  final String? errorMessage;
  final String? warningMessage;

  const ValidationResult.valid()
      : isValid = true,
        errorMessage = null,
        warningMessage = null;

  const ValidationResult.invalid(this.errorMessage)
      : isValid = false,
        warningMessage = null;

  const ValidationResult.warning(this.warningMessage)
      : isValid = true,
        errorMessage = null;

  bool get hasError => errorMessage != null;
  bool get hasWarning => warningMessage != null;
}

/// Utility class for validating collection tree operations
class CollectionValidationUtil {
  // ignore: unused_field
  static final _logger = Logger("CollectionValidationUtil");

  /// Maximum allowed tree depth to prevent extremely deep hierarchies
  static const int maxTreeDepth = 10;

  /// Validates if a collection can be set as a parent of another collection
  /// Returns ValidationResult with error/warning messages if invalid
  static ValidationResult validateSetParent({
    required Collection child,
    required Collection? newParent,
    required int currentUserID,
    required CollectionTree tree,
  }) {
    // Allow setting parent to null (moving to root)
    if (newParent == null) {
      return const ValidationResult.valid();
    }

    // Check if child and parent are the same
    if (child.id == newParent.id) {
      return const ValidationResult.invalid(
        "Cannot set a collection as its own parent",
      );
    }

    // Check ownership - only owner can reparent
    if (!child.isOwner(currentUserID)) {
      return const ValidationResult.invalid(
        "Only the owner can move this album",
      );
    }

    if (!newParent.isOwner(currentUserID)) {
      return const ValidationResult.invalid(
        "You can only move albums into albums you own",
      );
    }

    // Check collection type constraints
    final typeValidation = _validateCollectionTypes(child, newParent);
    if (typeValidation.hasError) {
      return typeValidation;
    }

    // Check for cycles
    if (tree.wouldCreateCycle(child.id, newParent.id)) {
      return const ValidationResult.invalid(
        "Cannot move album: this would create a circular hierarchy",
      );
    }

    // Check depth limit
    final newDepth = tree.getDepth(newParent.id) + 1;
    if (newDepth > maxTreeDepth) {
      return const ValidationResult.invalid(
        "Cannot move album: maximum nesting depth (10 levels) exceeded",
      );
    }

    // Check if child has descendants and would exceed depth limit
    final childNode = tree.getNode(child.id);
    if (childNode != null && childNode.descendantCount > 0) {
      final maxChildDepth = _getMaxDescendantDepth(childNode);
      if (newDepth + maxChildDepth > maxTreeDepth) {
        return const ValidationResult.invalid(
          "Cannot move album: the nested structure would exceed maximum depth (10 levels)",
        );
      }
    }

    // Check for share visibility mismatches
    final shareValidation = _checkShareVisibility(child, newParent);
    if (shareValidation.hasWarning) {
      return shareValidation;
    }

    return const ValidationResult.valid();
  }

  /// Validates collection type constraints
  static ValidationResult _validateCollectionTypes(
    Collection child,
    Collection parent,
  ) {
    // Favorites and uncategorized cannot be nested or have children
    if (child.type == CollectionType.favorites) {
      return const ValidationResult.invalid(
        "Favorites album cannot be nested under another album",
      );
    }

    if (child.type == CollectionType.uncategorized) {
      return const ValidationResult.invalid(
        "Uncategorized album cannot be nested under another album",
      );
    }

    if (parent.type == CollectionType.favorites) {
      return const ValidationResult.invalid(
        "Cannot nest albums under Favorites",
      );
    }

    if (parent.type == CollectionType.uncategorized) {
      return const ValidationResult.invalid(
        "Cannot nest albums under Uncategorized",
      );
    }

    return const ValidationResult.valid();
  }

  /// Gets the maximum depth of descendants
  static int _getMaxDescendantDepth(CollectionTreeNode node) {
    if (node.isLeaf) return 0;

    int maxDepth = 0;
    for (final child in node.children) {
      final childDepth = 1 + _getMaxDescendantDepth(child);
      if (childDepth > maxDepth) {
        maxDepth = childDepth;
      }
    }
    return maxDepth;
  }

  /// Checks for share visibility mismatches
  static ValidationResult _checkShareVisibility(
    Collection child,
    Collection parent,
  ) {
    // Check if share settings differ
    final childHasSharees = child.hasSharees;
    final parentHasSharees = parent.hasSharees;

    if (childHasSharees != parentHasSharees) {
      return const ValidationResult.warning(
        "The album you're moving has different sharing settings than the destination. "
        "You may want to update sharing settings for consistency.",
      );
    }

    // Check if child is shared with people not on parent's list
    if (childHasSharees && parentHasSharees) {
      final childShareeIds = child.sharees.map((s) => s.id).toSet();
      final parentShareeIds = parent.sharees.map((s) => s.id).toSet();

      if (!childShareeIds.containsAll(parentShareeIds) ||
          !parentShareeIds.containsAll(childShareeIds)) {
        return const ValidationResult.warning(
          "The album is shared with different people than the destination album. "
          "Consider updating sharing settings for consistency.",
        );
      }
    }

    return const ValidationResult.valid();
  }

  /// Validates if a collection can be deleted
  static ValidationResult validateDelete({
    required Collection collection,
    required int currentUserID,
    required CollectionTree tree,
    required bool deleteDescendants,
  }) {
    // Check ownership
    if (!collection.isOwner(currentUserID)) {
      return const ValidationResult.invalid(
        "Only the owner can delete this album",
      );
    }

    // Check type constraints
    if (!collection.type.canDelete) {
      return const ValidationResult.invalid("This album cannot be deleted");
    }

    // Check if has children and warn
    final node = tree.getNode(collection.id);
    if (node != null && !node.isLeaf && !deleteDescendants) {
      return ValidationResult.warning(
        "This album contains ${node.children.length} nested albums. "
        "They will be moved to the root level.",
      );
    }

    return const ValidationResult.valid();
  }

  /// Validates if collections can be shared as a subtree
  static ValidationResult validateSubtreeShare({
    required Collection parent,
    required int currentUserID,
    required CollectionTree tree,
  }) {
    // Check ownership
    if (!parent.isOwner(currentUserID)) {
      return const ValidationResult.invalid(
        "Only the owner can share this album",
      );
    }

    // Get all descendants
    final descendants = CollectionTreeUtil.getDescendants(tree, parent.id);

    // Check if all descendants are owned by current user
    for (final descendant in descendants) {
      if (!descendant.isOwner(currentUserID)) {
        return ValidationResult.invalid(
          "Cannot share subtree: descendant album '${descendant.displayName}' is not owned by you",
        );
      }
    }

    // Warn about large subtrees
    if (descendants.length > 100) {
      return ValidationResult.warning(
        "You're about to share ${descendants.length + 1} albums. This may take some time.",
      );
    }

    return const ValidationResult.valid();
  }

  /// Validates batch operations on multiple collections
  static ValidationResult validateBatchOperation({
    required List<Collection> collections,
    required int limit,
  }) {
    if (collections.isEmpty) {
      return const ValidationResult.invalid("No albums selected");
    }

    if (collections.length > limit) {
      return ValidationResult.invalid(
        "Too many albums selected. Maximum is $limit per operation.",
      );
    }

    return const ValidationResult.valid();
  }

  /// Checks if a collection can have children added
  static ValidationResult canHaveChildren(Collection collection) {
    if (collection.type == CollectionType.favorites) {
      return const ValidationResult.invalid(
        "Favorites album cannot have nested albums",
      );
    }

    if (collection.type == CollectionType.uncategorized) {
      return const ValidationResult.invalid(
        "Uncategorized album cannot have nested albums",
      );
    }

    return const ValidationResult.valid();
  }
}
