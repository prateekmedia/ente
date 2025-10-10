# Nested Albums Implementation Plans

## Overview
This document presents a progressive implementation approach for nested albums/collections in Ente that establishes proper parent-child relationships from the start:

1. **Phase 1 - Hybrid Approach**: Start with PubMagicMetadata but structure it to mirror future database relationships
2. **Phase 2 - Server Migration**: Migrate to proper database schema with minimal client changes
3. **Phase 3 - Full Nested Albums**: Extend to complete nested album features with UI for management

The key insight is to use `parentCollectionId` in metadata from day one, making the transition seamless.

## Phase 1: Hybrid Approach (Start Here)

### Core Design Principle
Use `parentCollectionId` as the primary relationship mechanism in PubMagicMetadata, exactly matching what will eventually be a database column. This ensures:
- Clean parent-child relationships from day one
- Easy migration to server-side later
- No ambiguity in hierarchy structure

### Metadata Structure
```typescript
interface NestedAlbumMetadata {
  // Existing fields
  asc?: boolean;
  coverID?: number;
  layout?: string;

  // CRITICAL: Parent-child relationship
  parentCollectionId?: number;    // THE source of truth for hierarchy

  // Cached/derived fields for optimization
  pathCache?: string;              // "/id1/id2/id3" - for fast lookup
  depthCache?: number;             // Pre-calculated depth
  childrenIds?: number[];          // Direct children cache
}
```

### Why This Structure Works
1. **parentCollectionId** is the single source of truth - just like it will be in the database
2. Path-based lookups are just a cache/index, not the primary relationship
3. When we migrate to server-side, we just move `parentCollectionId` from metadata to a database column

## Phase 2: Server-Side Implementation (Future Migration)

### Database Schema Changes

#### 1. Collections Table Modification
```sql
ALTER TABLE collections ADD COLUMN parent_collection_id BIGINT DEFAULT NULL;
ALTER TABLE collections ADD CONSTRAINT fk_parent_collection
    FOREIGN KEY (parent_collection_id) REFERENCES collections(id) ON DELETE CASCADE;
CREATE INDEX idx_collections_parent ON collections(parent_collection_id);
CREATE INDEX idx_collections_owner_parent ON collections(owner_id, parent_collection_id);
```

#### 2. Collection Path Materialization Table (for optimization)
```sql
CREATE TABLE collection_paths (
    collection_id BIGINT PRIMARY KEY,
    path_array BIGINT[],  -- Array of collection IDs from root to current
    path_string TEXT,      -- e.g., "/1/45/789" for quick matching
    depth INT,
    root_collection_id BIGINT,
    FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE
);
CREATE INDEX idx_collection_paths_root ON collection_paths(root_collection_id);
CREATE INDEX idx_collection_paths_string ON collection_paths(path_string text_pattern_ops);
```

### Server API Changes

#### 1. Collection Entity Updates
```go
// server/ente/collection.go
type Collection struct {
    // ... existing fields
    ParentCollectionID *int64 `json:"parentCollectionID,omitempty"`
    Children []Collection `json:"children,omitempty"` // For tree responses
    Path string `json:"path,omitempty"` // "/RootName/Parent/Current"
    Depth int `json:"depth,omitempty"`
}

type CreateCollectionRequest struct {
    // ... existing fields
    ParentCollectionID *int64 `json:"parentCollectionID,omitempty"`
}
```

#### 2. New API Endpoints
```go
// GET /collections/tree - Get hierarchical collection tree
// GET /collections/:id/children - Get direct children of a collection
// POST /collections/:id/move - Move collection to new parent
// GET /collections/path?path=/Root/Folder1/Folder2 - Find by path
```

#### 3. Repository Layer Changes
```go
// pkg/repo/collection.go
func (r *CollectionRepository) CreateWithParent(collection Collection, parentID *int64) (Collection, error)
func (r *CollectionRepository) GetCollectionTree(userID int64) ([]Collection, error)
func (r *CollectionRepository) GetChildren(collectionID int64) ([]Collection, error)
func (r *CollectionRepository) MoveCollection(collectionID, newParentID int64) error
func (r *CollectionRepository) GetByPath(userID int64, path string) (*Collection, error)
func (r *CollectionRepository) UpdatePaths(rootCollectionID int64) error // Rebuild path cache
```

### Web Implementation (Desktop Watcher)

#### 1. Enhanced Collection Mapping
```typescript
// web/packages/gallery/services/upload/nested-collections.ts
export type NestedCollectionMapping = "root" | "parent" | "nested";

interface CollectionNode {
    id: number;
    name: string;
    parentId: number | null;
    children: CollectionNode[];
    path: string; // Full path from root
}

class NestedCollectionManager {
    private pathCache: Map<string, number>; // path -> collectionId
    private treeCache: Map<number, CollectionNode>;

    async findOrCreateNestedCollection(
        itemPath: string,
        rootCollectionId?: number
    ): Promise<number> {
        const pathComponents = this.getPathComponents(itemPath);
        let currentParentId = rootCollectionId || null;

        for (const component of pathComponents) {
            const path = this.buildPath(currentParentId, component);

            // Check cache first
            if (this.pathCache.has(path)) {
                currentParentId = this.pathCache.get(path);
                continue;
            }

            // Check server
            let collection = await this.findCollectionByPath(path);
            if (!collection) {
                // Create new nested collection
                collection = await this.createNestedCollection(
                    component,
                    currentParentId
                );
            }

            this.pathCache.set(path, collection.id);
            currentParentId = collection.id;
        }

        return currentParentId;
    }

    private async findCollectionByPath(path: string): Promise<Collection | null> {
        // Use new server endpoint
        return await getCollectionByPath(path);
    }

    private async createNestedCollection(
        name: string,
        parentId: number | null
    ): Promise<Collection> {
        return await createCollection({
            name,
            type: "folder",
            parentCollectionID: parentId
        });
    }

    // Optimize duplicate detection
    async findExactMatch(
        name: string,
        parentId: number | null,
        rootPath: string
    ): Promise<number | null> {
        const fullPath = `${rootPath}/${name}`;
        return this.pathCache.get(fullPath) || null;
    }
}
```

#### 2. Web Watcher Integration
```typescript
// web/packages/gallery/services/upload/folder-watcher.ts
export class FolderWatcher {
    private nestedManager: NestedCollectionManager;

    async handleFolderImport(
        folderPath: string,
        mapping: NestedCollectionMapping
    ) {
        const items = await this.scanFolder(folderPath);

        if (mapping === "nested") {
            // Build complete hierarchy
            await this.importWithNestedStructure(items, folderPath);
        } else if (mapping === "parent") {
            // Existing behavior
            await this.importWithParentMapping(items);
        } else {
            // Root: all in one collection
            await this.importToSingleCollection(items);
        }
    }

    private async importWithNestedStructure(
        items: UploadItem[],
        rootPath: string
    ) {
        // Group by folder depth first for optimal creation
        const depthGroups = this.groupByDepth(items);

        // Create collections depth by depth
        for (const [depth, depthItems] of depthGroups) {
            await Promise.all(
                depthItems.map(item =>
                    this.nestedManager.findOrCreateNestedCollection(
                        item.relativePath,
                        null
                    )
                )
            );
        }

        // Upload files to their respective collections
        await this.uploadToNestedCollections(items);
    }
}
```

### Mobile Implementation

#### 1. Collection Model Updates
```dart
// mobile/apps/photos/lib/models/collection/collection.dart
class Collection {
  // ... existing fields
  final int? parentCollectionId;
  final List<Collection>? children;
  final String? fullPath;
  final int depth;

  bool get isNested => parentCollectionId != null;

  String get hierarchicalName {
    if (fullPath != null) {
      return fullPath!.split('/').last;
    }
    return displayName;
  }
}
```

#### 2. UI Components
```dart
// mobile/apps/photos/lib/ui/collections/nested_album_tree.dart
class NestedAlbumTree extends StatelessWidget {
  final List<Collection> rootCollections;

  Widget buildTree(Collection collection, int depth) {
    return Column(
      children: [
        InkWell(
          onTap: () => navigateToCollection(collection),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0),
            child: AlbumTile(collection: collection),
          ),
        ),
        if (collection.children?.isNotEmpty ?? false)
          ...collection.children!.map(
            (child) => buildTree(child, depth + 1)
          ),
      ],
    );
  }
}
```

### Advantages
- **Clean data model**: Proper parent-child relationships in database
- **Efficient queries**: Can leverage SQL for tree operations
- **Consistency**: Single source of truth for hierarchy
- **Performance**: Indexed paths for fast lookups
- **Features**: Easy to implement move, copy, bulk operations

### Disadvantages
- **Migration complexity**: Need to migrate existing collections
- **Breaking changes**: API changes require client updates
- **Server load**: More complex queries and transactions
- **Rollback difficulty**: Hard to revert schema changes

### Web Implementation for Phase 1

```typescript
// web/packages/media/nested-collections.ts
export class NestedCollectionService {
    // Two indices for different lookup needs
    private parentChildIndex: Map<number, Set<number>> = new Map();  // parentId -> Set<childIds>
    private childParentIndex: Map<number, number> = new Map();       // childId -> parentId
    private pathCache: Map<string, number> = new Map();              // "/name1/name2" -> collectionId

    constructor(private collections: Map<number, Collection>) {
        this.rebuildIndices();
    }

    private rebuildIndices() {
        this.parentChildIndex.clear();
        this.childParentIndex.clear();
        this.pathCache.clear();

        // First pass: build parent-child relationships
        for (const collection of this.collections.values()) {
            const metadata = collection.pubMagicMetadata?.data as NestedAlbumMetadata;

            if (metadata?.parentCollectionId) {
                // This collection has a parent
                this.childParentIndex.set(collection.id, metadata.parentCollectionId);

                // Add to parent's children set
                if (!this.parentChildIndex.has(metadata.parentCollectionId)) {
                    this.parentChildIndex.set(metadata.parentCollectionId, new Set());
                }
                this.parentChildIndex.get(metadata.parentCollectionId)!.add(collection.id);
            }
        }

        // Second pass: build path cache
        for (const collection of this.collections.values()) {
            const path = this.buildPathForCollection(collection.id);
            this.pathCache.set(path, collection.id);
        }
    }

    private buildPathForCollection(collectionId: number): string {
        const pathComponents: string[] = [];
        let currentId: number | undefined = collectionId;

        while (currentId !== undefined) {
            const collection = this.collections.get(currentId);
            if (!collection) break;

            pathComponents.unshift(collection.name);
            currentId = this.childParentIndex.get(currentId);
        }

        return '/' + pathComponents.join('/');
    }

    // CRITICAL: This is the main method for web watcher
    async findOrCreateNestedCollection(
        folderPath: string,
        rootCollectionName?: string
    ): Promise<number> {
        const pathComponents = folderPath.split('/').filter(Boolean);
        if (rootCollectionName) {
            pathComponents.unshift(rootCollectionName);
        }

        let parentId: number | undefined;
        let currentPath = '';

        for (const componentName of pathComponents) {
            currentPath = currentPath ? `${currentPath}/${componentName}` : `/${componentName}`;

            // Try to find existing collection at this path
            let collectionId = this.findCollectionByNameAndParent(componentName, parentId);

            if (!collectionId) {
                // Create new collection with parent relationship
                const newCollection = await this.createCollection({
                    name: componentName,
                    type: 'folder',
                    pubMagicMetadata: {
                        parentCollectionId: parentId,  // CRITICAL: Set parent relationship
                        pathCache: currentPath,
                        depthCache: pathComponents.indexOf(componentName)
                    }
                });

                collectionId = newCollection.id;
                this.collections.set(collectionId, newCollection);

                // Update indices
                if (parentId) {
                    this.childParentIndex.set(collectionId, parentId);
                    if (!this.parentChildIndex.has(parentId)) {
                        this.parentChildIndex.set(parentId, new Set());
                    }
                    this.parentChildIndex.get(parentId)!.add(collectionId);
                }

                this.pathCache.set(currentPath, collectionId);
            }

            parentId = collectionId;
        }

        return parentId!;
    }

    private findCollectionByNameAndParent(
        name: string,
        parentId: number | undefined
    ): number | undefined {
        // If no parent, look for root collections
        if (!parentId) {
            for (const [id, collection] of this.collections) {
                const metadata = collection.pubMagicMetadata?.data as NestedAlbumMetadata;
                if (collection.name === name && !metadata?.parentCollectionId) {
                    return id;
                }
            }
            return undefined;
        }

        // Look for children of specific parent
        const childrenIds = this.parentChildIndex.get(parentId);
        if (!childrenIds) return undefined;

        for (const childId of childrenIds) {
            const child = this.collections.get(childId);
            if (child?.name === name) {
                return childId;
            }
        }

        return undefined;
    }

    // Get all ancestors of a collection
    getAncestors(collectionId: number): number[] {
        const ancestors: number[] = [];
        let currentId = this.childParentIndex.get(collectionId);

        while (currentId !== undefined) {
            ancestors.push(currentId);
            currentId = this.childParentIndex.get(currentId);
        }

        return ancestors;
    }

    // Get all descendants of a collection
    getDescendants(collectionId: number): number[] {
        const descendants: number[] = [];
        const toProcess: number[] = [collectionId];

        while (toProcess.length > 0) {
            const currentId = toProcess.pop()!;
            const children = this.parentChildIndex.get(currentId);

            if (children) {
                for (const childId of children) {
                    descendants.push(childId);
                    toProcess.push(childId);
                }
            }
        }

        return descendants;
    }

    // Move a collection to a new parent
    async moveCollection(
        collectionId: number,
        newParentId: number | undefined
    ): Promise<void> {
        // Validate: Can't move to own descendant
        if (newParentId) {
            const descendants = this.getDescendants(collectionId);
            if (descendants.includes(newParentId)) {
                throw new Error("Cannot move collection to its own descendant");
            }
        }

        const collection = this.collections.get(collectionId);
        if (!collection) throw new Error("Collection not found");

        const metadata = collection.pubMagicMetadata?.data as NestedAlbumMetadata;
        const oldParentId = metadata?.parentCollectionId;

        // Update metadata
        await this.updateCollectionMetadata(collectionId, {
            ...metadata,
            parentCollectionId: newParentId
        });

        // Update indices
        if (oldParentId) {
            this.parentChildIndex.get(oldParentId)?.delete(collectionId);
        }

        if (newParentId) {
            this.childParentIndex.set(collectionId, newParentId);
            if (!this.parentChildIndex.has(newParentId)) {
                this.parentChildIndex.set(newParentId, new Set());
            }
            this.parentChildIndex.get(newParentId)!.add(collectionId);
        } else {
            this.childParentIndex.delete(collectionId);
        }

        // Rebuild path cache for moved collection and descendants
        this.rebuildPathsForSubtree(collectionId);
    }
}
```

### Web Watcher Integration

```typescript
// web/packages/gallery/services/upload/watcher.ts
export class EnhancedFolderWatcher {
    private nestedService: NestedCollectionService;
    private watchedPaths: Map<string, WatchConfig> = new Map();

    async watchFolder(
        folderPath: string,
        mapping: "root" | "parent" | "nested",
        rootCollectionName?: string
    ) {
        const config: WatchConfig = {
            path: folderPath,
            mapping,
            rootCollectionName: rootCollectionName || path.basename(folderPath)
        };

        this.watchedPaths.set(folderPath, config);

        if (mapping === "nested") {
            await this.setupNestedWatcher(config);
        }
    }

    private async setupNestedWatcher(config: WatchConfig) {
        const watcher = chokidar.watch(config.path, {
            persistent: true,
            ignoreInitial: false,
            awaitWriteFinish: true
        });

        watcher.on('add', async (filePath) => {
            await this.handleFileAdded(filePath, config);
        });

        watcher.on('addDir', async (dirPath) => {
            // Pre-create collection for directory
            await this.handleDirectoryAdded(dirPath, config);
        });
    }

    private async handleFileAdded(filePath: string, config: WatchConfig) {
        const relativePath = path.relative(config.path, filePath);
        const dirPath = path.dirname(relativePath);

        // Build collection path
        const collectionPath = dirPath === '.' ? '' : dirPath;

        // Find or create nested collection
        const collectionId = await this.nestedService.findOrCreateNestedCollection(
            collectionPath,
            config.rootCollectionName
        );

        // Upload file to this collection
        await this.uploadFileToCollection(filePath, collectionId);
    }

    private async handleDirectoryAdded(dirPath: string, config: WatchConfig) {
        if (dirPath === config.path) return; // Skip root

        const relativePath = path.relative(config.path, dirPath);

        // Pre-create collection for this directory
        await this.nestedService.findOrCreateNestedCollection(
            relativePath,
            config.rootCollectionName
        );
    }

    // Handle complex scenarios with multiple folders of same name
    async resolveAmbiguousPath(
        targetPath: string,
        contextPath: string
    ): Promise<number> {
        // When we have multiple "2017" folders, use full path context
        // Example: If uploading to "Photos/2017" vs "Backup/2017"

        const fullPath = `/${contextPath}/${targetPath}`;

        // First, try exact match by full path
        const exactMatch = await this.nestedService.findByExactPath(fullPath);
        if (exactMatch) return exactMatch;

        // If not found, create the full hierarchy
        return await this.nestedService.findOrCreateNestedCollection(
            targetPath,
            contextPath
        );
    }
}
```

---

## Migration Strategy: From Phase 1 to Phase 2

### The Beauty of Using parentCollectionId from Day One

When we migrate from metadata to database, the transition is seamless:

#### Before Migration (Phase 1)
```typescript
// Collection stored in metadata
collection.pubMagicMetadata = {
    parentCollectionId: 12345,  // Parent relationship
    pathCache: "/Root/Folder1",
    depthCache: 2
}
```

#### After Migration (Phase 2)
```sql
-- Same parentCollectionId, now in database
UPDATE collections
SET parent_collection_id = 12345  -- Same value, just moved!
WHERE id = ?;
```

### Migration Steps

1. **Add database column** (non-breaking)
```sql
ALTER TABLE collections ADD COLUMN parent_collection_id BIGINT DEFAULT NULL;
```

2. **Populate from metadata** (one-time migration)
```sql
UPDATE collections c
SET parent_collection_id = (
    SELECT (pub_magic_metadata->>'parentCollectionId')::BIGINT
    FROM collections
    WHERE id = c.id
)
WHERE pub_magic_metadata->>'parentCollectionId' IS NOT NULL;
```

3. **Client code barely changes**
```typescript
// Phase 1 code
const parentId = collection.pubMagicMetadata?.parentCollectionId;

// Phase 2 code (after server migration)
const parentId = collection.parentCollectionId ||
                 collection.pubMagicMetadata?.parentCollectionId;
// Fallback ensures backward compatibility!
```

---

## Critical Design Decisions

### Why parentCollectionId is THE Key

1. **Single Source of Truth**: One field defines the entire hierarchy
2. **Database Ready**: Exactly what we'll use in the database later
3. **No Ambiguity**: Unlike paths which can have duplicates
4. **Efficient**: Direct parent lookup is O(1)
5. **Conflict-Free**: Collection IDs are globally unique

### Path-Based Operations for Web Watcher

While `parentCollectionId` defines relationships, we still need path-based operations for the watcher:

```typescript
class PathToHierarchyResolver {
    // This maps file system paths to collection hierarchy
    private folderToCollectionCache: Map<string, number> = new Map();

    async resolvePathToCollection(
        fsPath: string,  // e.g., "D:/Photos/2017/Birthday"
        watchRoot: string // e.g., "D:/Photos"
    ): Promise<number> {
        const relativePath = path.relative(watchRoot, fsPath);
        const components = relativePath.split(path.sep);

        let parentId: number | undefined;
        let currentPath = '';

        for (const folderName of components) {
            currentPath = currentPath ? `${currentPath}/${folderName}` : folderName;

            // Check if we already know this folder->collection mapping
            const cacheKey = `${watchRoot}:${currentPath}`;
            if (this.folderToCollectionCache.has(cacheKey)) {
                parentId = this.folderToCollectionCache.get(cacheKey)!;
                continue;
            }

            // Find or create collection with this name under parent
            const collection = await this.findOrCreateCollection(
                folderName,
                parentId  // This is the key - using parentId relationship!
            );

            parentId = collection.id;
            this.folderToCollectionCache.set(cacheKey, parentId);
        }

        return parentId!;
    }

    private async findOrCreateCollection(
        name: string,
        parentId: number | undefined
    ): Promise<Collection> {
        // First, check if collection exists with this name and parent
        const existing = await this.findByNameAndParent(name, parentId);
        if (existing) return existing;

        // Create new collection with parent relationship
        return await createCollection({
            name,
            type: 'folder',
            pubMagicMetadata: {
                parentCollectionId: parentId  // THE critical field
            }
        });
    }
}
```

### Handling Edge Cases

#### 1. Multiple Folders with Same Name
```
Photos/
├── 2017/
│   └── Vacation/
└── 2018/
    └── Vacation/  <-- Different collection despite same name
```

Solution: `parentCollectionId` naturally handles this - each Vacation has a different parent.

#### 2. Moving Collections
```typescript
async function moveCollection(collectionId: number, newParentId: number) {
    // Phase 1: Update metadata
    await updatePubMagicMetadata(collectionId, {
        parentCollectionId: newParentId
    });

    // Phase 2: Same operation, just different field
    await updateCollection(collectionId, {
        parentCollectionId: newParentId
    });
}
```

#### 3. Circular Reference Prevention
```typescript
function validateMove(collectionId: number, newParentId: number): boolean {
    // Get all descendants
    const descendants = getDescendants(collectionId);

    // Can't move to own descendant
    if (descendants.includes(newParentId)) {
        return false;
    }

    return true;
}
```

---

## Implementation Timeline

### Week 1-2: Core Infrastructure
- [ ] Implement NestedCollectionService with parentCollectionId
- [ ] Add parent-child indices
- [ ] Create path resolution logic

### Week 2-3: Web Watcher Integration
- [ ] Modify watcher to support nested mode
- [ ] Implement folder-to-collection mapping
- [ ] Handle file additions to nested structure

### Week 3-4: UI Components
- [ ] Tree view component for web
- [ ] Breadcrumb navigation
- [ ] Drag-and-drop for moving collections

### Future: Server Migration (When Needed)
- [ ] Add parent_collection_id column
- [ ] Migrate data from metadata
- [ ] Update API endpoints
- [ ] Client fallback for compatibility

---

## Summary

The key insight is using `parentCollectionId` in PubMagicMetadata from the start, which gives us:

1. **True parent-child relationships** - Not just path-based matching
2. **Easy migration path** - Just move the field to database
3. **Consistent behavior** - Same logic works before and after migration
4. **Full nested album support** - Can build complete tree structures
5. **Optimal for watcher** - Efficient path-to-hierarchy resolution

This approach gives you the flexibility of client-side implementation with the structure needed for future server-side migration, ensuring your nested albums feature can grow from a simple folder watcher enhancement to a full-fledged nested album system.
interface NestedAlbumMetadata {
  // Existing fields
  asc?: boolean;
  coverID?: number;
  layout?: string;

  // New nested album fields
  parentId?: number;           // Parent collection ID
  childIds?: number[];         // Direct children IDs
  pathComponents?: string[];   // ["Root", "2017", "Album1"]
  fullPath?: string;           // "/Root/2017/Album1"
  depth?: number;              // 0 for root, 1 for first level, etc.
  sortOrder?: number;          // For ordering siblings
}
```

### Server Changes (Minimal)

#### 1. Add Helper Endpoints (Optional)
```go
// Simple query helpers, no schema changes
// GET /collections/nested/tree - Build tree from metadata
// POST /collections/nested/validate - Validate hierarchy consistency
```

### Web Implementation

#### 1. Nested Collection Service
```typescript
// web/packages/media/nested-collections.ts
export class NestedCollectionService {
    private collections: Map<number, Collection>;
    private pathIndex: Map<string, number>;
    private parentIndex: Map<number, number[]>; // parent -> children

    constructor() {
        this.rebuildIndices();
    }

    private rebuildIndices() {
        this.pathIndex.clear();
        this.parentIndex.clear();

        for (const collection of this.collections.values()) {
            const metadata = collection.pubMagicMetadata?.data as NestedAlbumMetadata;

            if (metadata?.fullPath) {
                this.pathIndex.set(metadata.fullPath, collection.id);
            }

            if (metadata?.parentId) {
                if (!this.parentIndex.has(metadata.parentId)) {
                    this.parentIndex.set(metadata.parentId, []);
                }
                this.parentIndex.get(metadata.parentId)!.push(collection.id);
            }
        }
    }

    async findOrCreateByPath(
        folderPath: string,
        createIfMissing: boolean = true
    ): Promise<number> {
        // Check if exact path exists
        if (this.pathIndex.has(folderPath)) {
            return this.pathIndex.get(folderPath)!;
        }

        if (!createIfMissing) {
            return null;
        }

        // Build path components
        const components = folderPath.split('/').filter(Boolean);
        let currentPath = '';
        let parentId: number | undefined;

        for (let i = 0; i < components.length; i++) {
            const component = components[i];
            currentPath = currentPath ? `${currentPath}/${component}` : `/${component}`;

            if (this.pathIndex.has(currentPath)) {
                parentId = this.pathIndex.get(currentPath)!;
                continue;
            }

            // Create new collection with nested metadata
            const newCollection = await this.createNestedCollection({
                name: component,
                type: "folder",
                pubMagicMetadata: {
                    parentId,
                    pathComponents: components.slice(0, i + 1),
                    fullPath: currentPath,
                    depth: i,
                    childIds: []
                }
            });

            // Update parent's children
            if (parentId) {
                await this.addChildToParent(parentId, newCollection.id);
            }

            this.collections.set(newCollection.id, newCollection);
            this.pathIndex.set(currentPath, newCollection.id);
            parentId = newCollection.id;
        }

        return parentId!;
    }

    private async addChildToParent(parentId: number, childId: number) {
        const parent = this.collections.get(parentId);
        if (!parent) return;

        const metadata = parent.pubMagicMetadata?.data as NestedAlbumMetadata;
        const childIds = metadata?.childIds || [];

        if (!childIds.includes(childId)) {
            childIds.push(childId);

            await updateCollectionMagicMetadata({
                id: parentId,
                pubMagicMetadata: {
                    ...metadata,
                    childIds
                }
            });
        }
    }

    // Optimize for web watcher
    async processWatchedFolder(
        folderPath: string,
        files: UploadItem[]
    ): Promise<Map<number, UploadItem[]>> {
        const collectionFiles = new Map<number, UploadItem[]>();

        for (const file of files) {
            const filePath = getFilePath(file);
            const relativePath = path.relative(folderPath, filePath);
            const collectionPath = path.dirname(relativePath);

            const collectionId = await this.findOrCreateByPath(
                `/${path.basename(folderPath)}${collectionPath ? `/${collectionPath}` : ''}`
            );

            if (!collectionFiles.has(collectionId)) {
                collectionFiles.set(collectionId, []);
            }
            collectionFiles.get(collectionId)!.push(file);
        }

        return collectionFiles;
    }

    // Build tree structure for UI
    buildCollectionTree(): CollectionNode[] {
        const roots: CollectionNode[] = [];
        const nodeMap = new Map<number, CollectionNode>();

        // First pass: create all nodes
        for (const collection of this.collections.values()) {
            const metadata = collection.pubMagicMetadata?.data as NestedAlbumMetadata;
            nodeMap.set(collection.id, {
                id: collection.id,
                name: collection.name,
                parentId: metadata?.parentId || null,
                children: [],
                path: metadata?.fullPath || `/${collection.name}`,
                collection
            });
        }

        // Second pass: build tree
        for (const node of nodeMap.values()) {
            if (node.parentId) {
                const parent = nodeMap.get(node.parentId);
                if (parent) {
                    parent.children.push(node);
                }
            } else {
                roots.push(node);
            }
        }

        // Sort children
        const sortNodes = (nodes: CollectionNode[]) => {
            nodes.sort((a, b) => {
                const aMeta = a.collection.pubMagicMetadata?.data as NestedAlbumMetadata;
                const bMeta = b.collection.pubMagicMetadata?.data as NestedAlbumMetadata;
                if (aMeta?.sortOrder && bMeta?.sortOrder) {
                    return aMeta.sortOrder - bMeta.sortOrder;
                }
                return a.name.localeCompare(b.name);
            });
            nodes.forEach(node => sortNodes(node.children));
        };

        sortNodes(roots);
        return roots;
    }
}
```

#### 2. Web Watcher Integration
```typescript
// web/packages/gallery/services/upload/watcher.ts
export class EnhancedFolderWatcher {
    private nestedService: NestedCollectionService;

    async watchFolder(
        folderPath: string,
        mapping: "root" | "parent" | "nested"
    ) {
        if (mapping === "nested") {
            await this.handleNestedWatch(folderPath);
        } else {
            // Existing logic for root/parent
            await this.handleLegacyWatch(folderPath, mapping);
        }
    }

    private async handleNestedWatch(folderPath: string) {
        const watcher = chokidar.watch(folderPath, {
            persistent: true,
            ignoreInitial: false
        });

        watcher.on('add', async (filePath) => {
            const relativePath = path.relative(folderPath, filePath);
            const dirPath = path.dirname(relativePath);
            const fullCollectionPath = `/${path.basename(folderPath)}${
                dirPath !== '.' ? `/${dirPath}` : ''
            }`;

            const collectionId = await this.nestedService.findOrCreateByPath(
                fullCollectionPath
            );

            await this.uploadFileToCollection(filePath, collectionId);
        });
    }
}
```

### Mobile Implementation

#### 1. Nested Collection Manager
```dart
// mobile/apps/photos/lib/services/nested_collections_service.dart
class NestedCollectionsService {
  final Map<int, Collection> _collections = {};
  final Map<String, int> _pathIndex = {};
  final Map<int, List<int>> _parentIndex = {};

  void rebuildIndices(List<Collection> collections) {
    _pathIndex.clear();
    _parentIndex.clear();

    for (final collection in collections) {
      _collections[collection.id] = collection;

      final metadata = collection.pubMagicMetadata;
      if (metadata.fullPath != null) {
        _pathIndex[metadata.fullPath!] = collection.id;
      }

      if (metadata.parentId != null) {
        _parentIndex.putIfAbsent(metadata.parentId!, () => []);
        _parentIndex[metadata.parentId!]!.add(collection.id);
      }
    }
  }

  List<CollectionNode> buildTree() {
    final roots = <CollectionNode>[];
    final nodeMap = <int, CollectionNode>{};

    // Create nodes
    for (final collection in _collections.values) {
      nodeMap[collection.id] = CollectionNode(
        collection: collection,
        children: [],
      );
    }

    // Build tree
    for (final node in nodeMap.values) {
      final parentId = node.collection.pubMagicMetadata.parentId;
      if (parentId != null && nodeMap.containsKey(parentId)) {
        nodeMap[parentId]!.children.add(node);
      } else {
        roots.add(node);
      }
    }

    return roots;
  }

  Future<int> findOrCreateByPath(String path) async {
    if (_pathIndex.containsKey(path)) {
      return _pathIndex[path]!;
    }

    final components = path.split('/').where((c) => c.isNotEmpty).toList();
    String currentPath = '';
    int? parentId;

    for (int i = 0; i < components.length; i++) {
      currentPath = currentPath.isEmpty
        ? '/${components[i]}'
        : '$currentPath/${components[i]}';

      if (_pathIndex.containsKey(currentPath)) {
        parentId = _pathIndex[currentPath];
        continue;
      }

      // Create new collection
      final newCollection = await CollectionsService.instance.createCollection(
        components[i],
        type: CollectionType.folder,
        pubMagicMetadata: CollectionPubMagicMetadata(
          parentId: parentId,
          fullPath: currentPath,
          pathComponents: components.take(i + 1).toList(),
          depth: i,
        ),
      );

      _collections[newCollection.id] = newCollection;
      _pathIndex[currentPath] = newCollection.id;
      parentId = newCollection.id;
    }

    return parentId!;
  }
}
```

#### 2. UI Components
```dart
// mobile/apps/photos/lib/ui/viewer/gallery/nested_album_page.dart
class NestedAlbumPage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CollectionNode>>(
      stream: NestedCollectionsService.instance.treeStream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const EnteLoadingWidget();
        }

        return CustomScrollView(
          slivers: [
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTreeItem(
                  snapshot.data![index],
                  0,
                ),
                childCount: snapshot.data!.length,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTreeItem(CollectionNode node, int depth) {
    return Column(
      children: [
        InkWell(
          onTap: () => _navigateToCollection(node.collection),
          child: Padding(
            padding: EdgeInsets.only(left: depth * 16.0),
            child: CollectionItem(
              collection: node.collection,
              showArrow: node.children.isNotEmpty,
            ),
          ),
        ),
        if (node.isExpanded)
          ...node.children.map(
            (child) => _buildTreeItem(child, depth + 1),
          ),
      ],
    );
  }
}
```

### Optimization Strategies

#### 1. Path Caching System
```typescript
class PathCache {
    private cache: Map<string, number> = new Map();
    private reverseCache: Map<number, string> = new Map();

    // Use prefix tree for efficient path matching
    private trie: PathTrie = new PathTrie();

    set(path: string, collectionId: number) {
        this.cache.set(path, collectionId);
        this.reverseCache.set(collectionId, path);
        this.trie.insert(path, collectionId);
    }

    findByPrefix(prefix: string): Array<[string, number]> {
        return this.trie.findByPrefix(prefix);
    }

    findClosestParent(path: string): number | null {
        const parts = path.split('/');
        for (let i = parts.length - 1; i > 0; i--) {
            const parentPath = parts.slice(0, i).join('/');
            if (this.cache.has(parentPath)) {
                return this.cache.get(parentPath)!;
            }
        }
        return null;
    }
}
```

#### 2. Batch Operations
```typescript
class BatchNestedOperations {
    async createMultipleNested(
        paths: string[]
    ): Promise<Map<string, number>> {
        // Sort by depth to create parents first
        const sorted = paths.sort((a, b) =>
            a.split('/').length - b.split('/').length
        );

        const results = new Map<string, number>();
        const batches = this.groupByDepth(sorted);

        for (const batch of batches) {
            const creations = await Promise.all(
                batch.map(path => this.createIfNotExists(path))
            );
            creations.forEach((id, index) => {
                results.set(batch[index], id);
            });
        }

        return results;
    }
}
```

### Advantages
- **No server changes**: Works with existing infrastructure
- **Backward compatible**: Old clients continue to work
- **Flexible**: Easy to iterate and modify
- **Rollback friendly**: Can disable feature without data migration
- **Gradual rollout**: Can be feature-flagged per user

### Disadvantages
- **Client complexity**: Each client implements tree logic
- **Consistency risks**: Metadata might get out of sync
- **Performance**: Clients need to build tree from flat list
- **Limited queries**: Can't use SQL for tree operations
- **Validation**: Harder to ensure hierarchy integrity

---

## Implementation Recommendations

### Phase 1: MVP with Client-Side (Plan B)
1. Implement using PubMagicMetadata (2-3 weeks)
2. Test with limited users
3. Gather feedback on UX and performance
4. Identify edge cases and limitations

### Phase 2: Evaluate & Decide
1. Measure performance impact
2. Analyze consistency issues
3. Determine if server-side is needed
4. Plan migration if necessary

### Phase 3: Server-Side Migration (if needed)
1. Implement server-side in parallel
2. Migrate metadata to database relationships
3. Maintain backward compatibility
4. Gradual rollout with feature flags

### Key Considerations for Web Watcher

#### Duplicate Detection Algorithm
```typescript
class DuplicateResolver {
    private pathSignatures: Map<string, string> = new Map();

    generateSignature(collectionPath: string): string {
        // Create unique signature for path
        return `${collectionPath.toLowerCase().replace(/[^a-z0-9]/g, '_')}`;
    }

    async findExistingCollection(
        name: string,
        parentPath: string
    ): Promise<number | null> {
        const signature = this.generateSignature(`${parentPath}/${name}`);

        // Check exact match first
        const exactMatch = await this.findByExactPath(`${parentPath}/${name}`);
        if (exactMatch) return exactMatch;

        // Check similar names in same parent
        const candidates = await this.findByParentAndNamePattern(
            parentPath,
            name
        );

        for (const candidate of candidates) {
            if (this.isSameCollection(candidate, name, parentPath)) {
                return candidate.id;
            }
        }

        return null;
    }
}
```

### Performance Optimizations

1. **Lazy Loading**: Load children only when expanded
2. **Virtual Scrolling**: For large hierarchies
3. **Incremental Sync**: Sync nested metadata separately
4. **Path Indexing**: Build path index on startup
5. **Batch Operations**: Group creates/updates

### Edge Cases to Handle

1. **Circular References**: Validate parent-child relationships
2. **Orphaned Collections**: Handle deleted parents
3. **Name Conflicts**: Same name at same level
4. **Deep Nesting**: Limit depth (e.g., 10 levels)
5. **Large Hierarchies**: Pagination for children
6. **Move Operations**: Update all descendant paths
7. **Shared Collections**: Handle nested shared albums
8. **Cross-User Nesting**: Prevent or handle specially

## Conclusion

Both approaches are viable:
- **Plan A** (Server-Side) is cleaner but requires significant changes
- **Plan B** (Client-Side) is faster to implement but has limitations

Recommendation: Start with Plan B for quick iteration and validation, then migrate to Plan A if the feature proves valuable and limitations become problematic.