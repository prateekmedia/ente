# Client-Side Nested Albums Implementation Plan (Production Ready)

## Overview
Implements nested albums primarily on the client side using public magic metadata for hierarchy, ensuring all participants see consistent structure. Minimizes server changes while providing full production features including Hide, Archive, Trash, Share, and all sub-album operations with proper UI/UX.

## Core Design Principles
1. **Shared Visibility**: Use public magic metadata so all participants see same hierarchy
2. **Minimal Redundancy**: Store only essential fields (parentID, sortOrder)
3. **Production Ready**: Full feature support, not an MVP
4. **Backward Compatible**: Old clients see flat structure, continue working
5. **Atomic Operations**: Critical operations use server-side batching
6. **Performance Optimized**: Handle large collections efficiently

## Data Model

### Collection Public Magic Metadata
```typescript
interface CollectionPublicMagicMetadataData {
  // Existing fields
  coverID?: number;

  // NEW: Hierarchy fields (minimal set)
  parentID?: number | null;     // Direct parent, null for root
  sortOrder?: number;           // Order within parent (for UI)
}
```

### Why Public Metadata?
- **Consistency**: All participants (owner, collaborators, viewers) see same structure
- **Sharing**: When album is shared, recipient sees it in correct position
- **Public Links**: Future enhancement can show hierarchy in public views

### Local Cache (Performance Only)
```typescript
// In-memory cache, rebuilt from source of truth
interface HierarchyCache {
  collectionId: number;
  parentId: number | null;
  children: number[];      // Computed, not stored
  depth: number;           // Computed for UI rendering
  path: number[];          // Computed for breadcrumbs
}
```

## Implementation

### 1. Core Hierarchy Service

**Web (collection-hierarchy.ts)**
```typescript
export class CollectionHierarchyService {
  private cache = new Map<number, HierarchyCache>();

  // Single source of truth: rebuild from collections
  rebuildCache(collections: Collection[]): void {
    this.cache.clear();

    for (const collection of collections) {
      const parentID = collection.pubMagicMetadata?.data?.parentID ?? null;

      this.cache.set(collection.id, {
        collectionId: collection.id,
        parentId: parentID,
        children: [],
        depth: 0,
        path: []
      });
    }

    // Compute children and validate
    this.computeChildren();
    this.validateAndFixCycles();
    this.computeDepthsAndPaths();
  }

  // Validate before operations
  canMoveToParent(collectionId: number, newParentId: number | null): boolean {
    if (newParentId === null) return true;
    if (newParentId === collectionId) return false;

    // Check for cycles
    if (this.wouldCreateCycle(collectionId, newParentId)) return false;

    // Check depth limit
    const parentDepth = this.getDepth(newParentId);
    if (parentDepth >= 9) return false; // Max depth 10

    // Check special collections
    const collection = this.getCollection(collectionId);
    if (collection?.type === 'favorites' ||
        collection?.type === 'uncategorized') return false;

    return true;
  }

  // Move with validation
  async moveToParent(
    collectionId: number,
    newParentId: number | null
  ): Promise<void> {
    if (!this.canMoveToParent(collectionId, newParentId)) {
      throw new Error("Invalid move operation");
    }

    const collection = await getCollection(collectionId);
    const collectionKey = await decryptCollectionKey(collection);

    // Update public metadata
    const metadata: CollectionPublicMagicMetadataData = {
      ...collection.pubMagicMetadata?.data,
      parentID: newParentId
    };

    await updateCollectionPublicMagicMetadata({
      id: collectionId,
      magicMetadata: await encryptMagicMetadata(
        createMagicMetadata(metadata),
        collectionKey
      )
    });

    // Rebuild cache
    await this.syncAndRebuild();
  }
}
```

**Mobile (nested_collection_service.dart)**
```dart
extension NestedCollectionService on CollectionsService {
  // Similar structure to web
  Map<int, HierarchyNode> _hierarchyCache = {};

  Future<bool> moveToParent(int collectionId, int? newParentId) async {
    if (!canMoveToParent(collectionId, newParentId)) {
      return false;
    }

    final collection = getCollectionByID(collectionId);
    final metadata = collection.pubMagicMetadata ?? {};
    metadata['parentID'] = newParentId;

    await updatePublicMagicMetadata(
      collectionId,
      metadata,
    );

    await sync();
    rebuildHierarchy();
    return true;
  }
}
```

### 2. Batch Operations for Complex Features

#### Trash with Descendants
```typescript
async function trashCollectionWithDescendants(
  collectionId: number,
  includeDescendants: boolean
): Promise<void> {
  const hierarchy = getHierarchyService();

  if (includeDescendants) {
    // Get all descendants
    const descendants = hierarchy.getDescendants(collectionId);

    // Build batch request for server
    const batch: TrashBatchRequest = {
      collections: [collectionId, ...descendants.map(d => d.id)],
      strategy: 'cascade'
    };

    // Single atomic operation
    await postTrashBatch(batch);
  } else {
    // Reparent children first
    const children = hierarchy.getChildren(collectionId);
    const parent = hierarchy.getParent(collectionId);

    // Batch update children's parents
    const updates = children.map(child => ({
      id: child.id,
      parentID: parent?.id ?? null
    }));

    if (updates.length > 0) {
      await batchUpdateParents(updates);
    }

    // Then trash the collection
    await trashCollection(collectionId);
  }
}
```

#### Archive/Hide Propagation
```typescript
async function setVisibilityWithDescendants(
  collectionId: number,
  visibility: 'archive' | 'hidden' | 'visible',
  includeDescendants: boolean
): Promise<void> {
  const targets = includeDescendants
    ? [collectionId, ...getDescendants(collectionId)]
    : [collectionId];

  // Batch update - split if > 1000 items
  const batches = chunk(targets, 1000);

  for (const batch of batches) {
    const updates = batch.map(id => ({
      id,
      magicMetadata: {
        visibility: visibility === 'visible' ? 0 :
                   visibility === 'archive' ? 1 : 2
      }
    }));

    await batchUpdateMagicMetadata(updates);

    // Rate limit between batches
    if (batches.length > 1) {
      await sleep(1000);
    }
  }
}
```

### 3. Share Operations

#### Share with Descendants
```typescript
async function shareWithDescendants(
  collectionId: number,
  email: string,
  role: 'VIEWER' | 'COLLABORATOR',
  includeDescendants: boolean
): Promise<void> {
  const targets = includeDescendants
    ? [collectionId, ...getDescendants(collectionId)]
    : [collectionId];

  // Get public key for recipient
  const recipientKey = await getPublicKey(email);

  // Prepare sealed keys for each collection
  const sealedKeys: Record<number, string> = {};

  for (const id of targets) {
    const collection = await getCollection(id);
    const collectionKey = await decryptCollectionKey(collection);
    sealedKeys[id] = await boxSeal(collectionKey, recipientKey);
  }

  // Batch share request
  await postShareBatch({
    email,
    role,
    collections: sealedKeys
  });
}
```

### 4. UI Components

#### Web - Tree View with All Operations
```typescript
const CollectionTreeView: React.FC = () => {
  const [expanded, setExpanded] = useState<Set<number>>(new Set());
  const [draggedItem, setDraggedItem] = useState<number | null>(null);
  const hierarchy = useHierarchyService();

  const handleDrop = async (targetId: number, draggedId: number) => {
    if (hierarchy.canMoveToParent(draggedId, targetId)) {
      await hierarchy.moveToParent(draggedId, targetId);
    } else {
      showError("Cannot move album here");
    }
  };

  const renderCollection = (collection: Collection, depth: number) => {
    const children = hierarchy.getChildren(collection.id);
    const isExpanded = expanded.has(collection.id);

    return (
      <div key={collection.id}>
        <CollectionItem
          collection={collection}
          depth={depth}
          isExpanded={isExpanded}
          hasChildren={children.length > 0}
          onToggle={() => toggleExpanded(collection.id)}
          onDrop={(e) => handleDrop(collection.id, draggedItem)}
          onDragStart={() => setDraggedItem(collection.id)}
          contextMenu={
            <CollectionContextMenu
              collection={collection}
              onCreateSubAlbum={() => createSubAlbum(collection.id)}
              onMoveToSubAlbum={() => showMoveDialog(collection.id)}
              onTrash={(includeDescendants) =>
                trashCollectionWithDescendants(collection.id, includeDescendants)
              }
              onArchive={(includeDescendants) =>
                setVisibilityWithDescendants(collection.id, 'archive', includeDescendants)
              }
              onHide={(includeDescendants) =>
                setVisibilityWithDescendants(collection.id, 'hidden', includeDescendants)
              }
              onShare={(includeDescendants) =>
                showShareDialog(collection.id, includeDescendants)
              }
            />
          }
        />

        {isExpanded && children.map(child =>
          renderCollection(child, depth + 1)
        )}
      </div>
    );
  };

  return (
    <VirtualList
      items={hierarchy.getRoots()}
      renderItem={(item) => renderCollection(item, 0)}
      overscan={5}
    />
  );
};
```

#### Mobile - Native Tree with Gestures
```dart
class CollectionTreeWidget extends StatefulWidget {
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      onReorder: (oldIndex, newIndex) async {
        final item = collections[oldIndex];
        final target = collections[newIndex];
        await moveToParent(item.id, target.parentId);
      },
      itemBuilder: (context, index) {
        final collection = collections[index];

        return Dismissible(
          key: Key('collection-${collection.id}'),
          direction: DismissDirection.horizontal,
          confirmDismiss: (direction) async {
            if (direction == DismissDirection.endToStart) {
              return await showTrashDialog(collection);
            } else {
              return await showArchiveDialog(collection);
            }
          },
          child: ExpansionTile(
            title: CollectionTile(collection),
            children: getChildren(collection.id)
              .map((child) => Padding(
                padding: EdgeInsets.only(left: 16),
                child: CollectionTile(child),
              ))
              .toList(),
            trailing: PopupMenuButton(
              itemBuilder: (context) => [
                PopupMenuItem(
                  child: Text('Add sub-album'),
                  onTap: () => createSubAlbum(collection.id),
                ),
                PopupMenuItem(
                  child: Text('Move to sub-album'),
                  onTap: () => showMoveDialog(collection.id),
                ),
                PopupMenuItem(
                  child: Text('Hide (with sub-albums)'),
                  onTap: () => hideWithDescendants(collection.id),
                ),
                PopupMenuItem(
                  child: Text('Share'),
                  onTap: () => showShareOptions(collection.id),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
```

### 5. Watch Folder Integration

```typescript
class WatchFolderWithHierarchy {
  async syncFolderStructure(rootPath: string): Promise<void> {
    const folders = await getFolderStructure(rootPath);
    const existingCollections = await getCollections();

    // Build path -> collection map
    const pathMap = new Map<string, Collection>();

    for (const folder of folders) {
      const parts = folder.relativePath.split('/');
      let parentId: number | null = null;

      for (let i = 0; i < parts.length; i++) {
        const pathSoFar = parts.slice(0, i + 1).join('/');

        let collection = pathMap.get(pathSoFar);

        if (!collection) {
          // Find or create collection
          collection = existingCollections.find(c =>
            c.name === parts[i] &&
            c.pubMagicMetadata?.data?.parentID === parentId
          );

          if (!collection) {
            collection = await createCollection(parts[i], 'folder', {
              parentID: parentId,
              devicePath: pathSoFar
            });
          }

          pathMap.set(pathSoFar, collection);
        }

        parentId = collection.id;
      }
    }
  }
}
```

### 6. Import/Export with Hierarchy

```typescript
// Export preserving structure
async function exportWithHierarchy(
  collectionId: number,
  targetDir: string,
  includeDescendants: boolean
): Promise<void> {
  const hierarchy = getHierarchyService();
  const collections = includeDescendants
    ? [collectionId, ...hierarchy.getDescendants(collectionId)]
    : [collectionId];

  for (const id of collections) {
    const collection = await getCollection(id);
    const path = hierarchy.getBreadcrumbs(id).map(c => c.name).join('/');
    const fullPath = `${targetDir}/${path}`;

    await fs.mkdir(fullPath, { recursive: true });

    const files = await getCollectionFiles(id);
    for (const file of files) {
      await exportFile(file, fullPath);
    }
  }
}

// Import creating hierarchy
async function importWithHierarchy(
  sourcePath: string,
  createNested: boolean
): Promise<void> {
  const structure = await scanDirectory(sourcePath);

  if (createNested) {
    // Create albums matching folder structure
    const rootAlbum = await createCollection(
      path.basename(sourcePath),
      'album'
    );

    await createNestedAlbums(structure, rootAlbum.id);
  } else {
    // Flat import (existing behavior)
    await importFlat(structure);
  }
}
```

### 7. Sync & Conflict Resolution

```typescript
class HierarchySyncManager {
  async syncCollections(): Promise<void> {
    const lastSync = await getLastSyncTime();
    let hasMore = true;
    let sinceTime = lastSync;

    while (hasMore) {
      // Fetch in batches respecting CollectionDiffLimit
      const diff = await fetchCollectionDiff(sinceTime, 2000);

      // Validate incoming changes
      const valid = this.validateChanges(diff.collections);

      // Resolve conflicts
      const resolved = this.resolveConflicts(valid);

      // Apply changes
      await this.applyChanges(resolved);

      hasMore = diff.collections.length >= 2000;
      sinceTime = diff.collections[diff.collections.length - 1]?.updationTime ?? sinceTime;

      // Rate limit
      if (hasMore) await sleep(1000);
    }

    // Rebuild hierarchy cache
    this.rebuildCache();
  }

  resolveConflicts(collections: Collection[]): Collection[] {
    const resolved = [...collections];

    for (const collection of resolved) {
      const parentID = collection.pubMagicMetadata?.data?.parentID;

      if (parentID) {
        // Check if parent exists and is not deleted
        const parent = resolved.find(c => c.id === parentID && !c.isDeleted);

        if (!parent) {
          // Orphaned - move to root
          collection.pubMagicMetadata.data.parentID = null;
        }

        // Check for cycles
        if (this.detectCycle(collection.id, parentID, resolved)) {
          // Break cycle - move to root
          collection.pubMagicMetadata.data.parentID = null;
        }
      }
    }

    return resolved;
  }
}
```

### 8. Performance Optimizations

```typescript
// Lazy loading for large trees
class LazyTreeLoader {
  private loaded = new Set<number>();
  private loading = new Set<number>();

  async loadChildren(parentId: number): Promise<Collection[]> {
    if (this.loaded.has(parentId)) {
      return this.getChildrenFromCache(parentId);
    }

    if (this.loading.has(parentId)) {
      return []; // Already loading
    }

    this.loading.add(parentId);

    try {
      const children = await fetchChildren(parentId);
      this.cacheChildren(parentId, children);
      this.loaded.add(parentId);
      return children;
    } finally {
      this.loading.delete(parentId);
    }
  }
}

// Virtual scrolling for large lists
const VirtualCollectionTree: React.FC = () => {
  const rowVirtualizer = useVirtualizer({
    count: flattenedTree.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 48,
    overscan: 10,
  });

  return (
    <div ref={scrollRef} style={{ height: '100%', overflow: 'auto' }}>
      <div style={{ height: rowVirtualizer.getTotalSize() }}>
        {rowVirtualizer.getVirtualItems().map(virtualItem => (
          <div
            key={virtualItem.key}
            style={{
              position: 'absolute',
              top: 0,
              left: 0,
              width: '100%',
              height: virtualItem.size,
              transform: `translateY(${virtualItem.start}px)`,
            }}
          >
            <CollectionRow
              collection={flattenedTree[virtualItem.index]}
              depth={getDepth(flattenedTree[virtualItem.index].id)}
            />
          </div>
        ))}
      </div>
    </div>
  );
};
```

## API Additions (Minimal)

### Batch Operations Endpoint
```http
POST /collections/batch
{
  "operations": [
    {
      "type": "updatePublicMetadata",
      "collectionId": 123,
      "metadata": { "parentID": 456 }
    }
  ]
}
```

### Batch Trash Endpoint
```http
POST /collections/trash/batch
{
  "collectionIds": [123, 456, 789],
  "strategy": "cascade" | "reparent"
}
```

## Testing Strategy

### Unit Tests
```typescript
describe('Hierarchy Operations', () => {
  it('prevents circular references', async () => {
    await createCollection('A');
    await createCollection('B', { parentID: A.id });
    await createCollection('C', { parentID: B.id });

    expect(() => moveToParent(A.id, C.id))
      .toThrow('Would create cycle');
  });

  it('handles orphaned collections', async () => {
    const child = await createCollection('Child', { parentID: 123 });
    await syncManager.resolveConflicts([child]);

    expect(child.pubMagicMetadata.data.parentID).toBeNull();
  });

  it('respects CollectionDiffLimit', async () => {
    const collections = await createCollections(3000);
    await syncManager.syncCollections();

    expect(fetchSpy).toHaveBeenCalledTimes(2); // 2000 + 1000
  });
});
```

### Integration Tests
- Create nested structure with 5 levels
- Share parent and verify descendants
- Trash parent with cascade option
- Archive/Hide with descendants
- Move collection between parents
- Import folder structure as nested albums
- Export nested albums as folder structure

## Migration Strategy

### Phase 1: Deploy Client Support (Week 1-2)
- Add hierarchy service
- Keep UI flat initially
- Start storing parentID in metadata

### Phase 2: Enable Tree UI (Week 3-4)
- Feature flag for tree view
- 10% rollout initially
- Monitor performance metrics

### Phase 3: Full Rollout (Week 5-6)
- Enable for all users
- Migration tool for organizing existing albums
- Documentation and tutorials

## Rollback Plan
1. Feature flag to disable tree UI
2. Keep parentID in metadata (ignored)
3. Revert to flat view instantly
4. No data loss

## Success Metrics
- Tree adoption: > 50% of active users
- Performance: < 100ms to render 1000 collections
- Sync reliability: > 99.9%
- Feature usage: All operations (trash, share, etc.) used with descendants

## Timeline
- Week 1-2: Core implementation
- Week 3-4: UI and testing
- Week 5-6: Rollout and optimization
- Total: 6 weeks