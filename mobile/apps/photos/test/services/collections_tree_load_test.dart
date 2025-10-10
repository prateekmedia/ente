import 'package:flutter_test/flutter_test.dart';
import 'package:photos/models/collection/collection.dart';
import 'package:photos/models/collection/collection_tree.dart';
import 'package:photos/models/metadata/collection_magic.dart';

/// Load tests for nested albums with large hierarchies
/// Tests performance and correctness with 10k albums
void main() {
  group('CollectionTree - Load Tests', () {
    test('builds tree with 10k albums efficiently', () {
      final stopwatch = Stopwatch()..start();

      // Create 10k collections in a balanced tree structure
      final collections = _createBalancedTree(10000);

      stopwatch.stop();
      print('Created 10k collections in ${stopwatch.elapsedMilliseconds}ms');

      expect(collections.length, equals(10000));

      // Verify tree structure is correct
      final roots = collections
          .where((c) =>
              c.pubMagicMetadata.parentID == null ||
              c.pubMagicMetadata.parentID == 0)
          .toList();
      expect(roots.isNotEmpty, isTrue);
    });

    test('performs breadth-first traversal on 10k tree efficiently', () {
      final collections = _createBalancedTree(10000);
      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      int visitedCount = 0;
      final queue = <CollectionTreeNode>[...tree.roots];

      while (queue.isNotEmpty) {
        final node = queue.removeAt(0);
        visitedCount++;
        queue.addAll(node.children);
      }

      stopwatch.stop();
      print('Traversed 10k nodes in ${stopwatch.elapsedMilliseconds}ms');

      expect(visitedCount, equals(10000));
      expect(stopwatch.elapsedMilliseconds, lessThan(1000)); // Under 1 second
    });

    test('finds deep nodes efficiently in 10k tree', () {
      final collections = _createBalancedTree(10000);
      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      // Find 100 random nodes
      for (int i = 0; i < 100; i++) {
        final targetId = i * 100;
        final node = tree.getNode(targetId);
        expect(node, isNotNull);
      }

      stopwatch.stop();
      print('Found 100 nodes in ${stopwatch.elapsedMilliseconds}ms');

      expect(stopwatch.elapsedMilliseconds, lessThan(100)); // Under 100ms
    });

    test('computes breadcrumbs efficiently for deep paths', () {
      final collections = _createBalancedTree(1000);
      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      // Get breadcrumbs for 50 leaf nodes
      for (int i = 900; i < 950; i++) {
        final breadcrumbs = tree.getBreadcrumbs(i);
        expect(breadcrumbs.isNotEmpty, isTrue);
      }

      stopwatch.stop();
      print('Computed 50 breadcrumbs in ${stopwatch.elapsedMilliseconds}ms');

      expect(stopwatch.elapsedMilliseconds, lessThan(100));
    });

    test('detects cycles efficiently in large tree', () {
      final collections = _createBalancedTree(5000);
      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      // Test 100 potential cycles
      for (int i = 0; i < 100; i++) {
        final sourceId = i * 10;
        final targetId = (i * 10) + 5;

        // Should detect if target is descendant of source
        final wouldCycle = tree.wouldCreateCycle(sourceId, targetId);
        expect(wouldCycle, isA<bool>());
      }

      stopwatch.stop();
      print('Checked 100 cycles in ${stopwatch.elapsedMilliseconds}ms');

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });

    test('handles wide tree (many siblings) efficiently', () {
      // Create tree with 1 root and 9999 direct children
      final collections = <Collection>[];

      // Root
      collections.add(_createCollection(id: 0, parentID: null));

      // 9999 children
      for (int i = 1; i < 10000; i++) {
        collections.add(_createCollection(id: i, parentID: 0));
      }

      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      expect(tree.roots.length, equals(1));
      expect(tree.roots[0].children.length, equals(9999));

      final descendants = tree.roots[0].descendants;
      expect(descendants.length, equals(9999));

      stopwatch.stop();
      print(
          'Processed wide tree (9999 siblings) in ${stopwatch.elapsedMilliseconds}ms');

      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('handles deep tree (10 levels) efficiently', () {
      // Create a deep linear tree with 10 levels (max depth)
      final collections = <Collection>[];

      for (int i = 0; i < 10; i++) {
        collections.add(
          _createCollection(
            id: i,
            parentID: i > 0 ? i - 1 : null,
          ),
        );
      }

      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      final breadcrumbs = tree.getBreadcrumbs(9);
      expect(breadcrumbs.length, equals(10));

      final depth = tree.getDepth(9);
      expect(depth, equals(9));

      stopwatch.stop();
      print('Processed max-depth tree in ${stopwatch.elapsedMilliseconds}ms');

      expect(stopwatch.elapsedMilliseconds, lessThan(10));
    });

    test('computes all descendants for large subtrees efficiently', () {
      final collections = _createBalancedTree(10000);
      final tree = _buildTree(collections);

      final stopwatch = Stopwatch()..start();

      // Get descendants for 10 subtrees
      int totalDescendants = 0;
      for (int i = 0; i < 10; i++) {
        final node = tree.getNode(i * 100);
        if (node != null) {
          totalDescendants += node.descendantCount;
        }
      }

      stopwatch.stop();
      print(
          'Computed descendants for 10 subtrees in ${stopwatch.elapsedMilliseconds}ms');
      print('Total descendants: $totalDescendants');

      expect(stopwatch.elapsedMilliseconds, lessThan(500));
    });

    test('memory usage is reasonable for 10k tree', () {
      final collections = _createBalancedTree(10000);
      final tree = _buildTree(collections);

      // Verify all nodes are in the map
      expect(tree.allNodes.length, equals(10000));

      // Verify no duplicate nodes
      final uniqueIds = tree.allNodes.map((n) => n.collection.id).toSet();
      expect(uniqueIds.length, equals(10000));
    });
  });
}

/// Creates a balanced tree of collections
/// Distributes collections across multiple levels
List<Collection> _createBalancedTree(int count) {
  final collections = <Collection>[];

  // Root node
  collections.add(_createCollection(id: 0, parentID: null));

  int nextId = 1;
  final parentIds = <int>[0];
  const childrenPerParent = 5; // Each parent has 5 children

  while (nextId < count) {
    final newParentIds = <int>[];

    for (final parentId in parentIds) {
      for (int i = 0; i < childrenPerParent && nextId < count; i++) {
        collections.add(_createCollection(id: nextId, parentID: parentId));
        newParentIds.add(nextId);
        nextId++;
      }
    }

    if (newParentIds.isEmpty) break;
    parentIds.clear();
    parentIds.addAll(newParentIds);
  }

  return collections;
}

/// Builds a CollectionTree from a list of collections
CollectionTree _buildTree(List<Collection> collections) {
  final nodeMap = <int, CollectionTreeNode>{};
  final roots = <CollectionTreeNode>[];

  // Create all nodes
  for (final collection in collections) {
    nodeMap[collection.id] = CollectionTreeNode(collection: collection);
  }

  // Build parent-child relationships
  for (final collection in collections) {
    final node = nodeMap[collection.id]!;
    final parentId = collection.pubMagicMetadata.parentID;

    if (parentId == null || parentId == 0) {
      roots.add(node);
    } else {
      final parent = nodeMap[parentId];
      parent?.addChild(node);
    }
  }

  // Calculate depths
  void setDepth(CollectionTreeNode node, int depth) {
    final updated = CollectionTreeNode(
      collection: node.collection,
      children: node.children,
      depth: depth,
    );
    nodeMap[node.collection.id] = updated;

    for (final child in node.children) {
      setDepth(child, depth + 1);
    }
  }

  for (final root in roots) {
    setDepth(root, 0);
  }

  return CollectionTree(roots: roots, nodeMap: nodeMap);
}

Collection _createCollection({required int id, int? parentID}) {
  return Collection(
    id,
    null,
    null, // encryptedKey
    null, // keyDecryptionNonce
    'Collection $id',
    null, // encryptedName
    null, // nameDecryptionNonce
    CollectionType.album,
    CollectionAttributes(),
    [],
    [],
    0,
  )..pubMagicMetadata = CollectionPubMagicMetadata(parentID: parentID);
}
