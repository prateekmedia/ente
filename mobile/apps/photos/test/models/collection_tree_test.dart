import 'package:flutter_test/flutter_test.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/collection/collection_tree.dart';
import 'package:photos/models/metadata/collection_magic.dart';

void main() {
  group('CollectionTreeNode', () {
    test('isRoot returns true for node with no parent', () {
      final collection = _createCollection(id: 1, parentID: 0);
      final node = CollectionTreeNode(collection: collection);

      expect(node.isRoot, isTrue);
    });

    test('isRoot returns false for node with parent', () {
      final collection = _createCollection(id: 1, parentID: 5);
      final node = CollectionTreeNode(collection: collection);

      expect(node.isRoot, isFalse);
    });

    test('isLeaf returns true for node with no children', () {
      final collection = _createCollection(id: 1);
      final node = CollectionTreeNode(collection: collection);

      expect(node.isLeaf, isTrue);
    });

    test('isLeaf returns false for node with children', () {
      final parent = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);

      final parentNode = CollectionTreeNode(collection: parent);
      final childNode = CollectionTreeNode(collection: child);
      parentNode.addChild(childNode);

      expect(parentNode.isLeaf, isFalse);
    });

    test('descendantCount returns correct count', () {
      final root = _createCollection(id: 1);
      final child1 = _createCollection(id: 2, parentID: 1);
      final child2 = _createCollection(id: 3, parentID: 1);
      final grandchild = _createCollection(id: 4, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root);
      final child1Node = CollectionTreeNode(collection: child1);
      final child2Node = CollectionTreeNode(collection: child2);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      rootNode.addChild(child1Node);
      rootNode.addChild(child2Node);
      child1Node.addChild(grandchildNode);

      expect(rootNode.descendantCount, equals(3));
      expect(child1Node.descendantCount, equals(1));
      expect(child2Node.descendantCount, equals(0));
    });

    test('descendants returns all descendant collections', () {
      final root = _createCollection(id: 1);
      final child1 = _createCollection(id: 2, parentID: 1);
      final child2 = _createCollection(id: 3, parentID: 1);
      final grandchild = _createCollection(id: 4, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root);
      final child1Node = CollectionTreeNode(collection: child1);
      final child2Node = CollectionTreeNode(collection: child2);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      rootNode.addChild(child1Node);
      rootNode.addChild(child2Node);
      child1Node.addChild(grandchildNode);

      final descendants = rootNode.descendants;
      expect(descendants.length, equals(3));
      expect(descendants.map((c) => c.id), containsAll([2, 3, 4]));
    });

    test('isDescendant returns true for descendant', () {
      final root = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);
      final grandchild = _createCollection(id: 3, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root);
      final childNode = CollectionTreeNode(collection: child);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      rootNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      expect(rootNode.isDescendant(2), isTrue);
      expect(rootNode.isDescendant(3), isTrue);
      expect(childNode.isDescendant(3), isTrue);
    });

    test('isDescendant returns false for non-descendant', () {
      final root = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);

      final rootNode = CollectionTreeNode(collection: root);
      final childNode = CollectionTreeNode(collection: child);

      rootNode.addChild(childNode);

      expect(rootNode.isDescendant(99), isFalse);
      expect(childNode.isDescendant(1), isFalse);
    });

    test('findNode returns correct node', () {
      final root = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);
      final grandchild = _createCollection(id: 3, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root);
      final childNode = CollectionTreeNode(collection: child);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      rootNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      expect(rootNode.findNode(1), equals(rootNode));
      expect(rootNode.findNode(2), equals(childNode));
      expect(rootNode.findNode(3), equals(grandchildNode));
    });

    test('findNode returns null for non-existent node', () {
      final root = _createCollection(id: 1);
      final rootNode = CollectionTreeNode(collection: root);

      expect(rootNode.findNode(99), isNull);
    });
  });

  group('CollectionTree', () {
    test('getNode returns correct node', () {
      final collection = _createCollection(id: 1);
      final node = CollectionTreeNode(collection: collection);
      final tree = CollectionTree(
        roots: [node],
        nodeMap: {1: node},
      );

      expect(tree.getNode(1), equals(node));
    });

    test('getNode returns null for non-existent node', () {
      final tree = CollectionTree(roots: [], nodeMap: {});

      expect(tree.getNode(99), isNull);
    });

    test('getPath returns correct path', () {
      final root = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);
      final grandchild = _createCollection(id: 3, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root, depth: 0);
      final childNode = CollectionTreeNode(collection: child, depth: 1);
      final grandchildNode =
          CollectionTreeNode(collection: grandchild, depth: 2);

      rootNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      final tree = CollectionTree(
        roots: [rootNode],
        nodeMap: {
          1: rootNode,
          2: childNode,
          3: grandchildNode,
        },
      );

      final path = tree.getPath(3);
      expect(path, isNotNull);
      expect(path!.length, equals(3));
      expect(path.map((c) => c.id), equals([1, 2, 3]));
    });

    test('getPath returns null for non-existent collection', () {
      final tree = CollectionTree(roots: [], nodeMap: {});

      expect(tree.getPath(99), isNull);
    });

    test('getBreadcrumbs returns correct breadcrumb trail', () {
      final root = _createCollection(id: 1, name: 'Root');
      final child = _createCollection(id: 2, parentID: 1, name: 'Child');
      final grandchild = _createCollection(
        id: 3,
        parentID: 2,
        name: 'Grandchild',
      );

      final rootNode = CollectionTreeNode(collection: root);
      final childNode = CollectionTreeNode(collection: child);
      final grandchildNode = CollectionTreeNode(collection: grandchild);

      rootNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      final tree = CollectionTree(
        roots: [rootNode],
        nodeMap: {
          1: rootNode,
          2: childNode,
          3: grandchildNode,
        },
      );

      final breadcrumbs = tree.getBreadcrumbs(3);
      expect(breadcrumbs, equals(['Root', 'Child', 'Grandchild']));
    });

    test('wouldCreateCycle detects self-reference', () {
      final collection = _createCollection(id: 1);
      final node = CollectionTreeNode(collection: collection);
      final tree = CollectionTree(
        roots: [node],
        nodeMap: {1: node},
      );

      expect(tree.wouldCreateCycle(1, 1), isTrue);
    });

    test('wouldCreateCycle detects parent-child cycle', () {
      final parent = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);

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

      expect(tree.wouldCreateCycle(1, 2), isTrue);
    });

    test('wouldCreateCycle detects grandparent-grandchild cycle', () {
      final grandparent = _createCollection(id: 1);
      final parent = _createCollection(id: 2, parentID: 1);
      final child = _createCollection(id: 3, parentID: 2);

      final grandparentNode = CollectionTreeNode(collection: grandparent);
      final parentNode = CollectionTreeNode(collection: parent);
      final childNode = CollectionTreeNode(collection: child);

      grandparentNode.addChild(parentNode);
      parentNode.addChild(childNode);

      final tree = CollectionTree(
        roots: [grandparentNode],
        nodeMap: {
          1: grandparentNode,
          2: parentNode,
          3: childNode,
        },
      );

      expect(tree.wouldCreateCycle(1, 3), isTrue);
    });

    test('wouldCreateCycle returns false for valid move', () {
      final parent1 = _createCollection(id: 1);
      final parent2 = _createCollection(id: 2);
      final child = _createCollection(id: 3, parentID: 1);

      final parent1Node = CollectionTreeNode(collection: parent1);
      final parent2Node = CollectionTreeNode(collection: parent2);
      final childNode = CollectionTreeNode(collection: child);

      parent1Node.addChild(childNode);

      final tree = CollectionTree(
        roots: [parent1Node, parent2Node],
        nodeMap: {
          1: parent1Node,
          2: parent2Node,
          3: childNode,
        },
      );

      expect(tree.wouldCreateCycle(3, 2), isFalse);
    });

    test('getDepth returns correct depth', () {
      final root = _createCollection(id: 1);
      final child = _createCollection(id: 2, parentID: 1);
      final grandchild = _createCollection(id: 3, parentID: 2);

      final rootNode = CollectionTreeNode(collection: root, depth: 0);
      final childNode = CollectionTreeNode(collection: child, depth: 1);
      final grandchildNode =
          CollectionTreeNode(collection: grandchild, depth: 2);

      rootNode.addChild(childNode);
      childNode.addChild(grandchildNode);

      final tree = CollectionTree(
        roots: [rootNode],
        nodeMap: {
          1: rootNode,
          2: childNode,
          3: grandchildNode,
        },
      );

      expect(tree.getDepth(1), equals(0));
      expect(tree.getDepth(2), equals(1));
      expect(tree.getDepth(3), equals(2));
    });
  });
}

Collection _createCollection({
  required int id,
  int? parentID,
  String? name,
}) {
  final displayName = name ?? 'Collection $id';
  return Collection(
    id,
    null,
    null, // encryptedKey
    null, // keyDecryptionNonce
    displayName,
    null, // encryptedName
    null, // nameDecryptionNonce
    CollectionType.album,
    CollectionAttributes(),
    [],
    [],
    0,
  )..pubMagicMetadata = CollectionPubMagicMetadata(parentID: parentID);
}
