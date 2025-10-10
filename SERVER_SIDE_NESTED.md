# Server-Side Nested Albums Implementation Plan (Lean Production)

## Overview
Implements nested albums with minimal server changes using a single `parent_id` column. Provides server-side validation for consistency while keeping the implementation lean. Supports all production features including Hide, Archive, Trash, Share, and sub-album operations.

## Core Design Principles
1. **Minimal Server Changes**: Single parent_id column, simple APIs
2. **Server Validation**: Prevent cycles and enforce constraints
3. **Production Features**: Full support for all operations
4. **Backward Compatible**: Old clients continue working
5. **Privacy Trade-off Accepted**: Hierarchy structure visible to server
6. **Performance Conscious**: Simple queries, no complex caching

## Privacy Consideration
**Important**: This approach reveals the hierarchy structure (parent-child relationships) to the server as metadata. Album names and contents remain encrypted, but the tree structure is visible. If absolute structural privacy is required, use the client-side approach instead.

## Database Schema Changes

### Single Column Addition
```sql
-- Migration 96_add_parent_id.up.sql
BEGIN;

-- Add parent_id column
ALTER TABLE collections
  ADD COLUMN parent_id BIGINT DEFAULT NULL;

-- Add foreign key for referential integrity
ALTER TABLE collections
  ADD CONSTRAINT fk_collections_parent_id
  FOREIGN KEY (parent_id)
  REFERENCES collections(collection_id)
  ON DELETE SET NULL;

-- Index for performance
CREATE INDEX idx_collections_parent_id
  ON collections(parent_id)
  WHERE is_deleted = false;

-- Prevent special collections from having parents
ALTER TABLE collections
  ADD CONSTRAINT check_special_no_parent
  CHECK (
    (type NOT IN ('favorites', 'uncategorized')) OR
    (parent_id IS NULL)
  );

COMMIT;
```

### Rollback Migration
```sql
-- Migration 96_add_parent_id.down.sql
BEGIN;

ALTER TABLE collections
  DROP CONSTRAINT IF EXISTS check_special_no_parent,
  DROP CONSTRAINT IF EXISTS fk_collections_parent_id,
  DROP COLUMN IF EXISTS parent_id;

DROP INDEX IF EXISTS idx_collections_parent_id;

COMMIT;
```

## API Changes

### 1. Create Collection with Parent
```http
POST /collections
{
  "encryptedKey": "...",
  "keyDecryptionNonce": "...",
  "encryptedName": "...",
  "nameDecryptionNonce": "...",
  "type": "album",
  "parentID": 123  // NEW: optional field
}

Response: 200 OK
{
  "collection": {
    "id": 456,
    "parentID": 123,  // NEW field
    // ... existing fields
  }
}
```

### 2. Move Collection (Reparent)
```http
PATCH /collections/{id}/parent
{
  "parentID": 789,  // null to move to root
  "expectedUpdationTime": 1234567890  // Optional CAS
}

Response: 200 OK
{
  "collection": {
    "id": 456,
    "parentID": 789,
    "updationTime": 1234567891
  }
}

Errors:
- 400: Would create cycle
- 400: Depth exceeds 10
- 403: Not authorized
- 409: Concurrent modification (if CAS used)
```

### 3. Batch Operations (For Features)
```http
POST /collections/batch-operation
{
  "operation": "trash" | "archive" | "hide" | "share",
  "targetIds": [123, 456, 789],
  "options": {
    "strategy": "cascade" | "reparent",  // For trash
    "visibility": 0 | 1 | 2,              // For archive/hide
    "email": "user@example.com",          // For share
    "role": "VIEWER" | "COLLABORATOR"     // For share
  }
}

Response: 200 OK
{
  "processed": 3,
  "failed": 0
}
```

### 4. Get Collections (Enhanced)
```http
GET /collections/v2?sinceTime=0

Response includes parentID in each collection:
{
  "collections": [
    {
      "id": 123,
      "parentID": null,  // NEW field
      // ... existing fields
    },
    {
      "id": 456,
      "parentID": 123,   // NEW field
      // ... existing fields
    }
  ]
}
```

## Server Implementation

### Model Changes
```go
// server/ente/collection.go
type Collection struct {
    ID                  int64
    ParentID           *int64 `json:"parentID,omitempty"`  // NEW
    // ... existing fields
}
```

### Controller Implementation
```go
// server/pkg/controller/collections/collection.go

func (c *CollectionController) Create(collection ente.Collection, ownerID int64) (ente.Collection, error) {
    // Existing validation...

    // NEW: Validate parent if specified
    if collection.ParentID != nil {
        if err := c.validateParent(*collection.ParentID, ownerID); err != nil {
            return ente.Collection{}, err
        }

        // Check depth
        depth := c.getDepth(*collection.ParentID)
        if depth >= 10 {
            return ente.Collection{}, ente.ErrMaxDepthExceeded
        }
    }

    // Continue with existing creation...
}

func (c *CollectionController) UpdateParent(ctx *gin.Context, collectionID int64, newParentID *int64) error {
    userID := auth.GetUserID(ctx.Request.Header)

    // Verify ownership
    collection, err := c.CollectionRepo.Get(collectionID)
    if err != nil {
        return err
    }

    if collection.Owner.ID != userID {
        return ente.ErrPermissionDenied
    }

    // Validate new parent
    if newParentID != nil {
        // Prevent self-parent
        if *newParentID == collectionID {
            return ente.ErrInvalidParent
        }

        // Check for cycles
        if c.wouldCreateCycle(collectionID, *newParentID) {
            return ente.ErrCircularReference
        }

        // Check depth
        depth := c.getDepth(*newParentID)
        if depth >= 10 {
            return ente.ErrMaxDepthExceeded
        }
    }

    // Update with optional CAS
    expectedTime := ctx.Query("expectedUpdationTime")
    if expectedTime != "" {
        // CAS update
        err = c.CollectionRepo.UpdateParentCAS(collectionID, newParentID, expectedTime)
        if err == sql.ErrNoRows {
            return ente.ErrConcurrentModification
        }
    } else {
        // Simple update
        err = c.CollectionRepo.UpdateParent(collectionID, newParentID)
    }

    return err
}

func (c *CollectionController) wouldCreateCycle(collectionID int64, newParentID int64) bool {
    current := newParentID

    for i := 0; i < 11; i++ {  // Max depth + 1
        if current == collectionID {
            return true
        }

        parent, err := c.CollectionRepo.Get(current)
        if err != nil || parent.ParentID == nil {
            break
        }

        current = *parent.ParentID
    }

    return false
}

func (c *CollectionController) getDepth(collectionID int64) int {
    depth := 0
    current := &collectionID

    for current != nil && depth < 11 {
        collection, err := c.CollectionRepo.Get(*current)
        if err != nil {
            break
        }

        current = collection.ParentID
        depth++
    }

    return depth
}
```

### Batch Operations for Features
```go
func (c *CollectionController) BatchOperation(ctx *gin.Context, req BatchOperationRequest) (*BatchOperationResponse, error) {
    userID := auth.GetUserID(ctx.Request.Header)

    switch req.Operation {
    case "trash":
        return c.batchTrash(userID, req.TargetIDs, req.Options.Strategy)

    case "archive", "hide":
        return c.batchVisibility(userID, req.TargetIDs, req.Options.Visibility)

    case "share":
        return c.batchShare(userID, req.TargetIDs, req.Options.Email, req.Options.Role)

    default:
        return nil, ente.ErrInvalidOperation
    }
}

func (c *CollectionController) batchTrash(userID int64, ids []int64, strategy string) (*BatchOperationResponse, error) {
    tx, err := c.DB.Begin()
    if err != nil {
        return nil, err
    }
    defer tx.Rollback()

    processed := 0

    for _, id := range ids {
        collection, err := c.CollectionRepo.GetWithTx(tx, id)
        if err != nil {
            continue
        }

        if collection.Owner.ID != userID {
            continue
        }

        if strategy == "cascade" {
            // Get descendants
            descendants := c.getDescendantsSimple(tx, id)

            // Trash all descendants first (deepest first)
            for i := len(descendants) - 1; i >= 0; i-- {
                c.TrashRepo.TrashCollectionWithTx(tx, descendants[i])
                processed++
            }
        } else if strategy == "reparent" {
            // Move children to parent
            children := c.getChildrenSimple(tx, id)
            for _, childID := range children {
                c.CollectionRepo.UpdateParentWithTx(tx, childID, collection.ParentID)
            }
        }

        // Trash the collection itself
        c.TrashRepo.TrashCollectionWithTx(tx, id)
        processed++
    }

    tx.Commit()

    return &BatchOperationResponse{
        Processed: processed,
        Failed:    len(ids) - processed,
    }, nil
}

// Simple recursive function without complex caching
func (c *CollectionController) getDescendantsSimple(tx *sql.Tx, parentID int64) []int64 {
    var descendants []int64

    rows, err := tx.Query(`
        SELECT collection_id FROM collections
        WHERE parent_id = $1 AND is_deleted = false
    `, parentID)

    if err != nil {
        return descendants
    }
    defer rows.Close()

    for rows.Next() {
        var childID int64
        if err := rows.Scan(&childID); err == nil {
            descendants = append(descendants, childID)
            // Recursively get children
            descendants = append(descendants, c.getDescendantsSimple(tx, childID)...)
        }
    }

    return descendants
}
```

### Repository Layer
```go
// server/pkg/repo/collection.go

func (repo *CollectionRepository) Create(c ente.Collection) (ente.Collection, error) {
    // Modified query to include parent_id
    err := repo.DB.QueryRow(`
        INSERT INTO collections(
            owner_id, encrypted_key, key_decryption_nonce,
            name, encrypted_name, name_decryption_nonce,
            type, attributes, updation_time,
            magic_metadata, pub_magic_metadata, app,
            parent_id  -- NEW
        )
        VALUES($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        RETURNING collection_id
    `, c.Owner.ID, c.EncryptedKey, c.KeyDecryptionNonce,
       c.Name, c.EncryptedName, c.NameDecryptionNonce,
       c.Type, c.Attributes, c.UpdationTime,
       c.MagicMetadata, c.PublicMagicMetadata, c.App,
       c.ParentID)  // NEW
    .Scan(&c.ID)

    return c, stacktrace.Propagate(err, "")
}

func (repo *CollectionRepository) Get(collectionID int64) (ente.Collection, error) {
    // Modified query to include parent_id
    row := repo.DB.QueryRow(`
        SELECT collection_id, app, owner_id,
               encrypted_key, key_decryption_nonce,
               name, encrypted_name, name_decryption_nonce,
               type, attributes, updation_time, is_deleted,
               magic_metadata, pub_magic_metadata,
               parent_id  -- NEW
        FROM collections
        WHERE collection_id = $1
    `, collectionID)

    var c ente.Collection
    // ... existing scan fields ...
    err := row.Scan(
        // ... existing fields ...
        &c.ParentID,  // NEW
    )

    return c, err
}

func (repo *CollectionRepository) UpdateParent(collectionID int64, parentID *int64) error {
    _, err := repo.DB.Exec(`
        UPDATE collections
        SET parent_id = $1, updation_time = $2
        WHERE collection_id = $3
    `, parentID, time.Microseconds(), collectionID)

    return err
}

func (repo *CollectionRepository) UpdateParentCAS(collectionID int64, parentID *int64, expectedTime string) error {
    result, err := repo.DB.Exec(`
        UPDATE collections
        SET parent_id = $1, updation_time = $2
        WHERE collection_id = $3 AND updation_time = $4
    `, parentID, time.Microseconds(), collectionID, expectedTime)

    if err != nil {
        return err
    }

    rows, _ := result.RowsAffected()
    if rows == 0 {
        return sql.ErrNoRows
    }

    return nil
}
```

## Client Implementation

### Web Client
```typescript
// Use server-provided parentID
interface Collection {
  id: number;
  parentID: number | null;  // From server
  // ... existing fields
}

// Build hierarchy client-side
class CollectionHierarchy {
  private collections: Map<number, Collection>;

  buildTree(): TreeNode[] {
    const roots: TreeNode[] = [];
    const nodeMap = new Map<number, TreeNode>();

    // First pass: create nodes
    for (const collection of this.collections.values()) {
      nodeMap.set(collection.id, {
        collection,
        children: []
      });
    }

    // Second pass: build tree
    for (const node of nodeMap.values()) {
      if (node.collection.parentID) {
        const parent = nodeMap.get(node.collection.parentID);
        if (parent) {
          parent.children.push(node);
        } else {
          roots.push(node);  // Orphaned
        }
      } else {
        roots.push(node);
      }
    }

    return roots;
  }

  async moveToParent(collectionId: number, newParentId: number | null) {
    const response = await fetch(`/collections/${collectionId}/parent`, {
      method: 'PATCH',
      body: JSON.stringify({ parentID: newParentId })
    });

    if (!response.ok) {
      throw new Error('Failed to move collection');
    }

    // Update local state
    const collection = this.collections.get(collectionId);
    if (collection) {
      collection.parentID = newParentId;
    }
  }
}
```

### Mobile Client
```dart
// Collection model with parentID
class Collection {
  final int id;
  final int? parentId;  // From server
  // ... existing fields
}

// Hierarchy service
extension NestedCollectionService on CollectionsService {
  Future<bool> moveToParent(int collectionId, int? newParentId) async {
    final response = await dio.patch(
      '/collections/$collectionId/parent',
      data: {'parentID': newParentId},
    );

    if (response.statusCode == 200) {
      await sync();  // Refresh collections
      return true;
    }

    return false;
  }

  List<Collection> getChildren(int parentId) {
    return collectionIDToCollections.values
      .where((c) => c.parentId == parentId && !c.isDeleted)
      .toList();
  }

  List<Collection> getDescendants(int parentId) {
    final descendants = <Collection>[];
    final children = getChildren(parentId);

    for (final child in children) {
      descendants.add(child);
      descendants.addAll(getDescendants(child.id));
    }

    return descendants;
  }
}
```

## Feature Implementation

### Trash with Descendants
```typescript
async function trashWithDescendants(
  collectionId: number,
  includeDescendants: boolean
): Promise<void> {
  if (includeDescendants) {
    const descendants = getDescendants(collectionId);
    const ids = [collectionId, ...descendants.map(d => d.id)];

    await fetch('/collections/batch-operation', {
      method: 'POST',
      body: JSON.stringify({
        operation: 'trash',
        targetIds: ids,
        options: { strategy: 'cascade' }
      })
    });
  } else {
    // Simple trash
    await trashCollection(collectionId);
  }
}
```

### Archive/Hide with Descendants
```typescript
async function setVisibilityWithDescendants(
  collectionId: number,
  visibility: 'archive' | 'hide' | 'visible',
  includeDescendants: boolean
): Promise<void> {
  const ids = includeDescendants
    ? [collectionId, ...getDescendants(collectionId).map(d => d.id)]
    : [collectionId];

  // Split into batches if needed
  const batches = chunk(ids, 1000);

  for (const batch of batches) {
    await fetch('/collections/batch-operation', {
      method: 'POST',
      body: JSON.stringify({
        operation: visibility === 'archive' ? 'archive' : 'hide',
        targetIds: batch,
        options: {
          visibility: visibility === 'visible' ? 0 :
                     visibility === 'archive' ? 1 : 2
        }
      })
    });

    if (batches.length > 1) {
      await sleep(1000);  // Rate limit
    }
  }
}
```

### Share with Descendants
```typescript
async function shareWithDescendants(
  collectionId: number,
  email: string,
  role: 'VIEWER' | 'COLLABORATOR',
  includeDescendants: boolean
): Promise<void> {
  const ids = includeDescendants
    ? [collectionId, ...getDescendants(collectionId).map(d => d.id)]
    : [collectionId];

  // Get recipient's public key
  const recipientKey = await getPublicKey(email);

  // Prepare sealed keys
  const encryptedKeys: Record<number, string> = {};
  for (const id of ids) {
    const collection = await getCollection(id);
    const key = await decryptCollectionKey(collection);
    encryptedKeys[id] = await boxSeal(key, recipientKey);
  }

  // Batch share
  await fetch('/collections/batch-operation', {
    method: 'POST',
    body: JSON.stringify({
      operation: 'share',
      targetIds: ids,
      options: {
        email,
        role,
        encryptedKeys
      }
    })
  });
}
```

## Sync & Conflict Resolution

```typescript
class SyncManager {
  async syncCollections(): Promise<void> {
    const lastSync = await getLastSyncTime();
    let sinceTime = lastSync;
    let hasMore = true;

    while (hasMore) {
      // Respect CollectionDiffLimit
      const response = await fetch(`/collections/v2?sinceTime=${sinceTime}&limit=2000`);
      const data = await response.json();

      // Process collections with parentID
      for (const collection of data.collections) {
        this.processCollection(collection);
      }

      hasMore = data.collections.length >= 2000;
      if (hasMore) {
        sinceTime = data.collections[data.collections.length - 1].updationTime;
        await sleep(1000);  // Rate limit
      }
    }
  }

  processCollection(collection: RemoteCollection): void {
    // Check for orphans
    if (collection.parentID && !this.collections.has(collection.parentID)) {
      // Parent doesn't exist - move to root
      collection.parentID = null;
    }

    // Check for cycles (shouldn't happen with server validation)
    if (collection.parentID && this.wouldCreateCycle(collection.id, collection.parentID)) {
      collection.parentID = null;
    }

    // Update local state
    this.collections.set(collection.id, collection);
  }
}
```

## Testing Strategy

### Server Tests
```go
func TestPreventCycles(t *testing.T) {
    // Create A -> B -> C
    A := createCollection("A", nil)
    B := createCollection("B", &A.ID)
    C := createCollection("C", &B.ID)

    // Try to make A -> C (would create cycle)
    err := controller.UpdateParent(ctx, A.ID, &C.ID)

    assert.Equal(t, ente.ErrCircularReference, err)
}

func TestDepthLimit(t *testing.T) {
    var parent *int64

    for i := 0; i < 10; i++ {
        c := createCollection(fmt.Sprintf("Level%d", i), parent)
        parent = &c.ID
    }

    // Try to create 11th level
    _, err := createCollection("Level10", parent)

    assert.Equal(t, ente.ErrMaxDepthExceeded, err)
}

func TestBatchOperations(t *testing.T) {
    // Create hierarchy
    root := createCollection("Root", nil)
    child1 := createCollection("Child1", &root.ID)
    child2 := createCollection("Child2", &root.ID)
    grandchild := createCollection("Grandchild", &child1.ID)

    // Trash with cascade
    response, err := controller.BatchOperation(ctx, BatchOperationRequest{
        Operation: "trash",
        TargetIDs: []int64{root.ID},
        Options: BatchOptions{Strategy: "cascade"},
    })

    assert.NoError(t, err)
    assert.Equal(t, 4, response.Processed)
}
```

### Client Tests
```typescript
describe('Hierarchy', () => {
  it('handles orphaned collections', () => {
    const collection = {
      id: 123,
      parentID: 999,  // Non-existent
      // ...
    };

    const tree = hierarchy.buildTree([collection]);
    expect(tree[0].collection.id).toBe(123);  // At root
  });

  it('respects CollectionDiffLimit', async () => {
    const collections = createManyCollections(3000);

    await syncManager.syncCollections();

    expect(fetchSpy).toHaveBeenCalledTimes(2);  // 2000 + 1000
  });
});
```

## Migration Strategy

### Phase 1: Database & API (Week 1)
- Deploy schema migration
- Add new endpoints
- Keep behind feature flag

### Phase 2: Client Support (Week 2-3)
- Update clients to read parentID
- Add UI for nested display
- Test with internal users

### Phase 3: Rollout (Week 4-5)
- Enable for 10% users
- Monitor performance
- Fix issues

### Phase 4: Full Launch (Week 6)
- Enable for all users
- Documentation
- Migration tools for existing albums

## Performance Considerations

- Simple parent_id column with index is fast
- No complex triggers or materialized views
- Recursive queries limited by depth (max 10)
- Client-side tree building is O(n)
- Batch operations chunked to respect limits

## Rollback Plan

If issues arise:
1. Disable feature flag (UI reverts to flat)
2. Keep parent_id column (no data loss)
3. Fix issues
4. Re-enable when ready

## Success Metrics
- Hierarchy adoption: > 40% of users
- Performance: < 50ms for tree operations
- Sync reliability: > 99.9%
- Zero data loss incidents

## Timeline
- Week 1: Database & API
- Week 2-3: Client implementation
- Week 4-5: Testing & rollout
- Week 6: Full launch
- Total: 6 weeks

## Trade-offs

### Pros
✅ Server validation prevents inconsistencies
✅ Simple implementation
✅ Good performance
✅ All features supported

### Cons
❌ Hierarchy visible to server (privacy trade-off)
❌ Requires database migration
❌ All clients need updates