import 'package:flutter_test/flutter_test.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/collection/collection_tree.dart';
import 'package:photos/models/metadata/collection_magic.dart';
import 'package:photos/utils/collection_validation_util.dart';

void main() {
  group('CollectionValidationUtil - validateSetParent', () {
    test('validates setting parent to null (moving to root)', () {
      final child = _createCollection(id: 1, ownerID: 100);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: null,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isTrue);
    });

    test('rejects setting collection as its own parent', () {
      final collection = _createCollection(id: 1, ownerID: 100);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: collection,
        newParent: collection,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('Cannot set a collection as its own parent'),
      );
    });

    test('rejects move when user is not owner of child', () {
      final child = _createCollection(id: 1, ownerID: 100);
      final parent = _createCollection(id: 2, ownerID: 200);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent,
        currentUserID: 200, // Not owner of child
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(result.errorMessage, contains('Only the owner can move'));
    });

    test('rejects move when user is not owner of parent', () {
      final child = _createCollection(id: 1, ownerID: 100);
      final parent = _createCollection(id: 2, ownerID: 200);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent,
        currentUserID: 100, // Not owner of parent
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('You can only move albums into albums you own'),
      );
    });

    test('rejects favorites as child', () {
      final child = _createCollection(
        id: 1,
        ownerID: 100,
        type: CollectionType.favorites,
      );
      final parent = _createCollection(id: 2, ownerID: 100);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('Favorites album cannot be nested'),
      );
    });

    test('rejects uncategorized as child', () {
      final child = _createCollection(
        id: 1,
        ownerID: 100,
        type: CollectionType.uncategorized,
      );
      final parent = _createCollection(id: 2, ownerID: 100);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('Uncategorized album cannot be nested'),
      );
    });

    test('rejects favorites as parent', () {
      final child = _createCollection(id: 1, ownerID: 100);
      final parent = _createCollection(
        id: 2,
        ownerID: 100,
        type: CollectionType.favorites,
      );
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
          result.errorMessage, contains('Cannot nest albums under Favorites'));
    });

    test('detects cycle when moving to descendant', () {
      final parent = _createCollection(id: 1, ownerID: 100);
      final child = _createCollection(id: 2, ownerID: 100, parentID: 1);
      final grandchild = _createCollection(id: 3, ownerID: 100, parentID: 2);

      final parentNode = CollectionTreeNode(collection: parent);
      final childNode = CollectionTreeNode(collection: child);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      parentNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      final tree = CollectionTree(
        roots: [parentNode],
        nodeMap: {
          1: parentNode,
          2: childNode,
          3: grandchildNode,
        },
      );

      final result = CollectionValidationUtil.validateSetParent(
        child: parent,
        newParent: grandchild,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('would create a circular hierarchy'),
      );
    });

    test('rejects move exceeding max depth at target', () {
      // Create a tree at depth 9 (max is 10)
      final collections = <Collection>[];
      final nodes = <CollectionTreeNode>[];

      for (int i = 0; i < 10; i++) {
        final collection = _createCollection(
          id: i,
          ownerID: 100,
          parentID: i > 0 ? i - 1 : null,
        );
        collections.add(collection);
        nodes.add(CollectionTreeNode(collection: collection, depth: i));
        if (i > 0) {
          nodes[i - 1].addChild(nodes[i]);
        }
      }

      final nodeMap = <int, CollectionTreeNode>{};
      for (int i = 0; i < 10; i++) {
        nodeMap[i] = nodes[i];
      }

      final tree = CollectionTree(roots: [nodes[0]], nodeMap: nodeMap);

      // Try to move a new collection under the deepest node
      final newCollection = _createCollection(id: 100, ownerID: 100);

      final result = CollectionValidationUtil.validateSetParent(
        child: newCollection,
        newParent: collections[9],
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(result.errorMessage, contains('maximum nesting depth'));
    });

    test('rejects move when child subtree would exceed max depth', () {
      // Create parent at depth 8
      final deepParent = _createCollection(id: 1, ownerID: 100);
      final deepParentNode =
          CollectionTreeNode(collection: deepParent, depth: 8);

      // Create child with 2 levels of descendants
      final child = _createCollection(id: 2, ownerID: 100);
      final grandchild = _createCollection(id: 3, ownerID: 100, parentID: 2);

      final childNode = CollectionTreeNode(collection: child, depth: 0);
      final grandchildNode =
          CollectionTreeNode(collection: grandchild, depth: 1);
      childNode.addChild(grandchildNode);

      final tree = CollectionTree(
        roots: [deepParentNode, childNode],
        nodeMap: {
          1: deepParentNode,
          2: childNode,
          3: grandchildNode,
        },
      );

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: deepParent,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isFalse);
      expect(
        result.errorMessage,
        contains('nested structure would exceed maximum depth'),
      );
    });

    test('allows valid move', () {
      final parent1 = _createCollection(id: 1, ownerID: 100);
      final parent2 = _createCollection(id: 2, ownerID: 100);
      final child = _createCollection(id: 3, ownerID: 100, parentID: 1);

      final parent1Node = CollectionTreeNode(collection: parent1, depth: 0);
      final parent2Node = CollectionTreeNode(collection: parent2, depth: 0);
      final childNode = CollectionTreeNode(collection: child, depth: 1);

      parent1Node.addChild(childNode);

      final tree = CollectionTree(
        roots: [parent1Node, parent2Node],
        nodeMap: {
          1: parent1Node,
          2: parent2Node,
          3: childNode,
        },
      );

      final result = CollectionValidationUtil.validateSetParent(
        child: child,
        newParent: parent2,
        currentUserID: 100,
        tree: tree,
      );

      expect(result.isValid, isTrue);
    });
  });

  group('CollectionValidationUtil - validateDelete', () {
    test('rejects delete when user is not owner', () {
      final collection = _createCollection(id: 1, ownerID: 100);
      final tree = CollectionTree(roots: [], nodeMap: {});

      final result = CollectionValidationUtil.validateDelete(
        collection: collection,
        currentUserID: 200,
        tree: tree,
        deleteDescendants: false,
      );

      expect(result.isValid, isFalse);
      expect(result.errorMessage, contains('Only the owner can delete'));
    });

    test('warns when deleting collection with children without cascade', () {
      final parent = _createCollection(id: 1, ownerID: 100);
      final child = _createCollection(id: 2, ownerID: 100, parentID: 1);

      final parentNode = CollectionTreeNode(collection: parent);
      final childNode = CollectionTreeNode(collection: child);
      parentNode.addChild(childNode);

      final tree = CollectionTree(
        roots: [parentNode],
        nodeMap: {
          1: parentNode,
          2: childNode,
        },
      );

      final result = CollectionValidationUtil.validateDelete(
        collection: parent,
        currentUserID: 100,
        tree: tree,
        deleteDescendants: false,
      );

      expect(result.isValid, isTrue);
      expect(result.hasWarning, isTrue);
      expect(result.warningMessage, contains('moved to the root level'));
    });
  });

  group('CollectionValidationUtil - canHaveChildren', () {
    test('allows normal albums to have children', () {
      final album = _createCollection(id: 1, ownerID: 100);

      final result = CollectionValidationUtil.canHaveChildren(album);

      expect(result.isValid, isTrue);
    });

    test('rejects favorites as parent', () {
      final favorites = _createCollection(
        id: 1,
        ownerID: 100,
        type: CollectionType.favorites,
      );

      final result = CollectionValidationUtil.canHaveChildren(favorites);

      expect(result.isValid, isFalse);
    });

    test('rejects uncategorized as parent', () {
      final uncategorized = _createCollection(
        id: 1,
        ownerID: 100,
        type: CollectionType.uncategorized,
      );

      final result = CollectionValidationUtil.canHaveChildren(uncategorized);

      expect(result.isValid, isFalse);
    });
  });
}

Collection _createCollection({
  required int id,
  required int ownerID,
  int? parentID,
  CollectionType type = CollectionType.album,
}) {
  return Collection(
    id,
    User(ownerID, '', '', 0),
    null, // encryptedKey
    null, // keyDecryptionNonce
    'Collection $id',
    null, // encryptedName
    null, // nameDecryptionNonce
    type,
    CollectionAttributes(),
    [],
    [],
    0,
  )..pubMagicMetadata = CollectionPubMagicMetadata(parentID: parentID);
}
