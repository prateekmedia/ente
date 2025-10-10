# Nested Albums Feature Documentation

## Overview

The Nested Albums feature allows users to organize their photo collections in a hierarchical tree structure, similar to a file system with folders and subfolders. This provides better organization for users with large photo libraries and complex organizational needs.

**Version**: 1.0
**Status**: Implementation Complete, Feature Flagged
**Target Release**: TBD

---

## Table of Contents

1. [Feature Description](#feature-description)
2. [Architecture](#architecture)
3. [User-Facing Functionality](#user-facing-functionality)
4. [Technical Implementation](#technical-implementation)
5. [API Reference](#api-reference)
6. [Deployment Guide](#deployment-guide)
7. [Known Limitations](#known-limitations)
8. [Future Enhancements](#future-enhancements)

---

## Feature Description

### What is Nested Albums?

Nested Albums extends Ente's existing album functionality to support parent-child relationships between albums, enabling:

- **Hierarchical Organization**: Albums can be nested within other albums up to 10 levels deep
- **Breadcrumb Navigation**: Visual breadcrumb trails show the path from root to current album
- **Tree Operations**: Move, delete, share, and export operations cascade through album hierarchies
- **Folder-Structure Exports**: Export albums maintaining their hierarchical folder structure

### Key Benefits

- **Better Organization**: Users can organize hundreds of albums into logical hierarchies
- **Batch Operations**: Perform actions on entire subtrees (e.g., share all vacation photos)
- **Familiar Paradigm**: Works like folders in a file system - intuitive for all users
- **Privacy Maintained**: All hierarchy data is end-to-end encrypted like other metadata

---

## Architecture

### Data Model

#### Collection Metadata

Nested album information is stored in the collection's public magic metadata:

```dart
class CollectionPubMagicMetadata {
  final int? parentID;  // ID of parent collection, null/0 for root-level albums

  // Other existing fields...
}
```

**Key Points**:
- `parentID == null` or `parentID == 0`: Root-level album
- `parentID > 0`: Child album with specified parent
- End-to-end encrypted as part of `magicMetadata`
- Stored on server, synced across devices

#### Tree Data Structure

```dart
class CollectionTree {
  final List<CollectionTreeNode> roots;
  final Map<int, CollectionTreeNode> nodeMap;

  List<Collection>? getPath(int collectionID);
  List<String> getBreadcrumbs(int collectionID);
  int getDepth(int collectionID);
}

class CollectionTreeNode {
  final Collection collection;
  final CollectionTreeNode? parent;
  final List<CollectionTreeNode> children;
  final int depth;

  bool get isRoot => parent == null;
  bool get isLeaf => children.isEmpty;
}
```

### Service Layer

#### Collections Tree Service

**Location**: `lib/services/collections_tree_service.dart`

**Responsibilities**:
- Build and cache collection tree from flat collection list
- Provide tree traversal operations (children, descendants, ancestors, breadcrumbs)
- Validate tree operations (cycle detection, depth limits, ownership)
- Manage tree cache invalidation

**Key Methods**:
```dart
CollectionTree getTree({bool forceRefresh = false});
Future<ValidationResult> moveCollection({required Collection child, required int? newParentID});
List<Collection> getChildren(int collectionID);
List<Collection> getDescendants(int collectionID);
List<String> getBreadcrumbs(int collectionID);
int getDepth(int collectionID);
```

#### Collections Job Service

**Location**: `lib/services/collections_job_service.dart`

**Responsibilities**:
- Execute long-running cascade operations asynchronously
- Persist job queue to SharedPreferences for resume after app restart
- Provide progress tracking and cancellation
- Handle batch processing with error recovery

**Supported Job Types**:
- `move`: Move album to new parent
- `subtreeShare` / `subtreeUnshare`: Share/unshare entire album hierarchy
- `cascadeHide` / `cascadeArchive`: Hide/archive album and all descendants
- `subtreeDelete`: Delete album and all descendants

### Validation Rules

**Implemented in**: `lib/utils/collection_validation_util.dart`

1. **Cycle Prevention**: Cannot set parent to self or any descendant
2. **Depth Limit**: Maximum tree depth of 10 levels
3. **Ownership**: Can only create parent-child relationships for owned albums
4. **Shared Album Restrictions**: Limited nesting operations on shared albums
5. **Root Integrity**: Cannot delete root albums with children without handling descendants

---

## User-Facing Functionality

### 1. Move Album (Reparent)

**Access**: Gallery view → ⋮ menu → "Move album"

**Behavior**:
- Shows tree selector dialog with expand/collapse navigation
- Validates move before execution (prevents cycles, depth violations)
- Shows warning if moving would exceed depth limit
- Updates parent immediately for single album
- Queues job for moving multiple albums

**Edge Cases**:
- Moving to root: Select "Root" option or set parent to null
- Moving shared album: Limited to same owner's albums
- Circular reference: Prevented by validation

### 2. Delete Nested Album

**Access**: Gallery view → ⋮ menu → Delete

**Behavior**:
- If album has no children: Deletes normally
- If album has children: Shows dialog with options:
  1. **Keep sub-albums**: Reparents children to root, deletes only this album
  2. **Delete all**: Deletes entire subtree (all descendants)
- Option to keep or delete photos remains unchanged

**Implementation**: `lib/ui/components/delete_nested_album_dialog.dart`

### 3. Share/Unshare Subtree

**Access**:
- Share: Gallery view → Share → Add participant
- Unshare: Album participants → Remove participant

**Behavior**:
- When sharing album with descendants: Shows dialog asking to include sub-albums
- If included: Creates job to share entire subtree with selected participant
- Shows progress: "Sharing X albums..."
- Same for unsharing

**Implementation**: `lib/ui/components/subtree_share_dialog.dart`

### 4. Cascade Hide/Archive

**Access**: Gallery view → ⋮ menu → Hide / Archive

**Behavior**:
- Shows dialog: "Album has X sub-albums. Include them?"
- Options:
  1. **Only this album**: Hides/archives only selected album
  2. **Include sub-albums**: Creates cascade job
- Job processes album + all descendants

**Implementation**: `lib/ui/components/cascade_visibility_dialog.dart`

### 5. Export with Folder Structure

**Access**: Gallery view → ⋮ menu → "Export with folder structure"

**Behavior**:
- Asks: "Include sub-albums in export?"
- Creates temporary directory with nested folders based on breadcrumb paths
- Example structure:
  ```
  ente_export_<timestamp>/
  ├── Vacation 2024/
  │   ├── Europe/
  │   │   ├── Paris/
  │   │   │   ├── photo1.jpg
  │   │   │   └── photo2.jpg
  │   │   └── Rome/
  │   │       └── photo3.jpg
  │   └── Asia/
  │       └── photo4.jpg
  ```
- Shares via system share sheet

**Implementation**: `lib/utils/collection_export_util.dart`

### 6. Tree View Display

**UI Components**:
- **`NestedAlbumGridWidget`**: Grid view with folder indicators
- **`NestedAlbumListWidget`**: List view with indentation and expand/collapse
- **`CollectionTreeSelector`**: Tree picker for move/select operations
- **`CollectionBreadcrumbsWidget`**: Breadcrumb trail display

**Visual Indicators**:
- Folder icon overlay on parent albums
- Indentation shows depth level
- Expand/collapse chevrons for navigation
- Breadcrumbs show: Root > Parent > Child

---

## Technical Implementation

### Creating a Nested Album

```dart
// Create child album under parent
final parentID = 123; // Existing album ID
await CollectionsService.instance.createAlbum(
  "My Child Album",
  parentID: parentID,
);

// Or use dialog
await showCreateNestedAlbumDialog(
  context,
  defaultParent: parentCollection,
);
```

### Moving an Album

```dart
final child = /* existing collection */;
final newParentID = 456; // Or null/0 for root

final result = await CollectionsTreeService.instance.moveCollection(
  child: child,
  newParentID: newParentID,
);

if (result.isValid) {
  // Success
} else {
  // Show error: result.errorMessage
}
```

### Getting Tree Information

```dart
final treeService = CollectionsTreeService.instance;

// Get breadcrumbs
final breadcrumbs = treeService.getBreadcrumbs(collectionID);
// Returns: ["Vacation 2024", "Europe", "Paris"]

// Get all children
final children = treeService.getChildren(collectionID);

// Get all descendants (recursive)
final descendants = treeService.getDescendants(collectionID);

// Get depth
final depth = treeService.getDepth(collectionID);
```

### Cascade Operations

```dart
// Hide entire subtree
await showCascadeVisibilityDialog(
  context,
  collection: myCollection,
  newVisibility: hiddenVisibility,
  isArchive: false,
);

// Share subtree
await showSubtreeShareDialog(
  context,
  collection: myCollection,
  email: "user@example.com",
  publicKey: publicKey,
  role: CollectionParticipantRole.viewer,
);
```

### Job Monitoring

```dart
final jobService = CollectionsJobService.instance;

// Get active jobs
final activeJobs = await jobService.getActiveJobs();

// Listen to job updates
jobService.jobUpdateStream.listen((job) {
  print("Job ${job.id} status: ${job.status}");
  print("Progress: ${job.progress * 100}%");
});

// Cancel a job
await jobService.cancelJob(jobId);
```

---

## API Reference

### Server API Endpoints

#### Set Parent
```http
PATCH /collections/{collectionID}/parent
Content-Type: application/json
Authorization: Bearer <token>

{
  "parentID": 123  // Or 0 for root
}
```

**Response**: Updated collection with new `pubMagicMetadata`

#### Get Collections
```http
GET /collections
Authorization: Bearer <token>
```

**Response**: Array of collections, each with `pubMagicMetadata.parentID`

### Client-Side Services

#### CollectionsTreeService

```dart
class CollectionsTreeService {
  static CollectionsTreeService get instance;

  // Tree building
  CollectionTree getTree({bool forceRefresh = false});
  void clearCache();

  // Tree traversal
  List<Collection> getChildren(int collectionID);
  List<Collection> getDescendants(int collectionID);
  List<Collection> getAncestors(int collectionID);
  List<String> getBreadcrumbs(int collectionID);

  // Tree queries
  int getDepth(int collectionID);
  bool hasChildren(int collectionID);
  int countDescendants(int collectionID);

  // Tree operations
  Future<ValidationResult> moveCollection({
    required Collection child,
    required int? newParentID,
  });
}
```

#### CollectionsJobService

```dart
class CollectionsJobService {
  static CollectionsJobService get instance;

  // Job management
  Future<void> enqueueJob(CollectionJob job);
  Future<void> cancelJob(String jobId);
  Future<List<CollectionJob>> getActiveJobs();
  Future<List<CollectionJob>> getAllJobs();

  // Job monitoring
  Stream<CollectionJob> get jobUpdateStream;
}
```

---

## Deployment Guide

### Feature Flag Configuration

The nested albums feature is gated behind the `enableNestedAlbums` feature flag.

#### 1. Enable for Internal Users (Testing)

**Default behavior**: Auto-enabled in debug mode for internal users

```dart
// In ente_feature_flag plugin
bool get enableNestedAlbums => flags.enableNestedAlbums || internalUser;
```

No configuration needed - works automatically in debug builds.

#### 2. Enable for Beta Users

Update server's `/remote-store/feature-flags` endpoint response:

```json
{
  "enableNestedAlbums": true,
  "betaUser": true,
  ...
}
```

Users with `betaUser: true` will see the feature.

#### 3. Gradual Public Rollout

**Server-side implementation required**:

```python
# Example Python endpoint
@app.get("/remote-store/feature-flags")
def get_feature_flags(user_id: int):
    # Percentage rollout
    rollout_percentage = 10  # 10% of users
    enable_for_user = (hash(user_id) % 100) < rollout_percentage

    return {
        "enableNestedAlbums": enable_for_user,
        ...
    }
```

#### 4. Full Rollout

Update server default response:

```json
{
  "enableNestedAlbums": true,
  ...
}
```

### Migration Considerations

**No migration required!** Existing albums without parents automatically appear at root level.

**Backward Compatibility**:
- Old clients ignore `parentID` field - see albums flat
- New clients respect `parentID` - see albums in tree
- Graceful degradation: feature is additive, not breaking

### Monitoring

**Key Metrics to Track** (via local logs):

```dart
// Log these events (already implemented)
"Moving album: id=X, old_parent=Y, new_parent=Z, current_depth=N"
"Album moved successfully: id=X, new_depth=N"
"Export started: collection_id=X, include_sub_albums=true/false"
"Export completed: total_files=X, total_collections=Y, duration_ms=Z"
```

**Access logs**: Settings → Advanced → View Logs

**What to monitor**:
- Move operation success rate
- Depth distribution (how deep users nest)
- Export usage (with vs without descendants)
- Job completion times
- Validation failure reasons

---

## Error Handling & Recovery

### Job Notifications

The system provides comprehensive user feedback for all collection operations:

- **Completion Notifications**: Success messages with item counts
- **Partial Success Tracking**: Shows X/Y items completed when some fail
- **Failure Notifications**: Clear error messages with retry options
- **Details Dialog**: View detailed job status and error information

### Rollback Mechanism

Critical operations support rollback to previous state:

- **Move Operations**: Can restore album to previous parent
- **Cascade Operations**: Can revert visibility changes (hide/archive)
- **Rollback Data**: Previous state captured automatically before changes
- **Safe Execution**: Rollback only available for completed jobs with stored state

### Implementation

```dart
// Initialize notification service in app startup
CollectionsJobNotificationService.instance.init(context);

// Rollback a completed operation
await CollectionsJobService.instance.rollbackJob(jobId);
```

### Recovery Patterns

1. **Network Failures**: Jobs automatically retry with exponential backoff
2. **Partial Failures**: Failed items tracked separately, rest of job continues
3. **App Restart**: Pending jobs resume automatically from SharedPreferences
4. **Cancellation**: Jobs can be cancelled mid-execution with partial state preserved

---

## Known Limitations

### Current Limitations

1. **Maximum Depth**: 10 levels
   - **Reason**: Prevents performance issues, UI complexity
   - **Mitigation**: Validation prevents exceeding limit

2. **Shared Album Nesting**: Limited for shared albums
   - **Reason**: Ownership complexity, permission model
   - **Behavior**: Can nest within owner's albums only

3. **Flat View on Old Clients**: Clients without update see albums flat
   - **Reason**: Backward compatibility
   - **Mitigation**: Graceful degradation, no data loss

4. **No Undo for Cascade Operations**: Subtree delete is permanent
   - **Reason**: Complexity of reversing cascaded operations
   - **Mitigation**: Warning dialogs, confirmation required

5. **Export Limitations**:
   - No zip file creation (share folder via OS share sheet)
   - Large exports may timeout or fill temp storage
   - File count limits based on device memory

6. **Job Queue Not Persisted Across Reinstalls**: Stored in SharedPreferences
   - **Reason**: Simple persistence mechanism
   - **Impact**: Unfinished jobs lost on app reinstall

### Performance Considerations

- **Tree Cache**: Rebuilds on collection changes, cached for reads
- **Large Hierarchies**: ~1000 albums tested, performs well
- **Deep Nesting**: Depth 10 limit prevents exponential complexity
- **Cascade Operations**: Batch processed (50 items/batch) to avoid blocking

---

## Future Enhancements

### Planned Features

1. **Bulk Move**: Select multiple albums and move together
2. **Drag-and-Drop**: Visual drag-and-drop for rearranging tree
3. **Quick Filters**: Filter tree view by date, size, shared status
4. **Tree Statistics**: Show total files, size at each tree node
5. **Keyboard Navigation**: Arrow keys for tree navigation
6. **Search in Tree**: Search within specific subtree only

### Under Consideration

1. **Zip Export**: Create actual zip file instead of folder share
2. **Watch Folder Tree Mapping**: Map device folders 1:1 to nested albums
3. **Customizable Depth Limit**: Per-user or per-plan depth limits
4. **Undo/Redo**: Transaction log for reversing operations
5. **Tree Templates**: Pre-defined organization templates
6. **AI-Suggested Organization**: ML-based album hierarchy suggestions

---

## Troubleshooting

### Common Issues

#### "Cannot move album: Would create a cycle"

**Cause**: Trying to move parent under its child
**Solution**: Choose different parent outside current subtree

#### "Cannot move album: Would exceed maximum depth"

**Cause**: Move would create tree deeper than 10 levels
**Solution**: Move to shallower location or flatten some levels

#### "Move failed: Parent album not found"

**Cause**: Parent album was deleted or not synced
**Solution**: Refresh collections, try different parent

#### "Export failed: Not enough storage space"

**Cause**: Insufficient temp storage for export
**Solution**: Free up device storage, export fewer albums

#### Jobs stuck in "running" state

**Cause**: App closed during job execution
**Solution**: Cancel stuck job, retry operation

### Debug Mode

Enable debug logging:

```dart
// Set log level in main.dart
Logger.root.level = Level.FINE;

// View logs in app
Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => LogViewerPage()),
);
```

---

## Code Examples

### Example 1: Create Nested Album Structure

```dart
// Create: Vacation 2024 > Europe > Paris
final vacation = await collectionsService.createAlbum("Vacation 2024");
final europe = await collectionsService.createAlbum(
  "Europe",
  parentID: vacation.id,
);
final paris = await collectionsService.createAlbum(
  "Paris",
  parentID: europe.id,
);

// Verify structure
final breadcrumbs = treeService.getBreadcrumbs(paris.id);
print(breadcrumbs); // ["Vacation 2024", "Europe", "Paris"]
```

### Example 2: Move Album

```dart
// Move "Rome" from Europe to Asia
final rome = collectionsService.getCollectionByID(romeID);
final asia = collectionsService.getCollectionByID(asiaID);

final result = await treeService.moveCollection(
  child: rome!,
  newParentID: asia!.id,
);

if (!result.isValid) {
  showErrorDialog(context, "Cannot Move", result.errorMessage);
}
```

### Example 3: Share Entire Vacation

```dart
// Share "Vacation 2024" and all sub-albums
final shouldCascade = await showSubtreeShareDialog(
  context,
  collection: vacation,
  email: "friend@example.com",
  publicKey: friendPublicKey,
  role: CollectionParticipantRole.viewer,
);

if (shouldCascade) {
  // Job queued, will process in background
  showShortToast(context, "Sharing vacation albums...");
}
```

### Example 4: Export with Folder Structure

```dart
await exportCollectionWithStructure(
  context,
  vacation, // Root album
  includeSubAlbums: true,
  onProgress: (completed, total) {
    print("Exported $completed / $total files");
  },
);
```

---

## Testing Checklist

### Unit Tests

- [ ] Tree building from flat collections
- [ ] Cycle detection in validation
- [ ] Depth calculation
- [ ] Breadcrumb generation
- [ ] Ancestor/descendant queries

### Integration Tests

- [ ] Create nested album via API
- [ ] Move album updates tree correctly
- [ ] Delete cascades to children when selected
- [ ] Share propagates to subtree
- [ ] Export maintains folder structure

### UI Tests

- [ ] Tree selector shows hierarchy
- [ ] Move dialog prevents invalid moves
- [ ] Delete dialog shows correct options
- [ ] Breadcrumbs update on navigation
- [ ] Expand/collapse works correctly

### Edge Case Tests

- [ ] Maximum depth (10 levels) enforced
- [ ] Moving to root works
- [ ] Deleting root with children shows options
- [ ] Large hierarchies (1000+ albums) perform well
- [ ] Concurrent job execution doesn't corrupt state
- [ ] App restart resumes pending jobs

---

## Support

### Documentation

- **Code**: `lib/services/collections_tree_service.dart`
- **UI Components**: `lib/ui/components/` (move_album_dialog, delete_nested_album_dialog, etc.)
- **Feature Flag**: `plugins/ente_feature_flag/`

### Contact

- **Issues**: GitHub Issues
- **Discussions**: GitHub Discussions
- **Email**: support@ente.io

---

## Changelog

### Version 1.0 (2025-10-03)

**Features**:
- ✅ Hierarchical album organization (up to 10 levels)
- ✅ Move album dialog with tree picker
- ✅ Delete with reparent or cascade options
- ✅ Share/unshare subtree
- ✅ Cascade hide/archive
- ✅ Export with folder structure
- ✅ Breadcrumb navigation
- ✅ Tree view display (grid and list)
- ✅ Feature flag control
- ✅ Logging for operations

**Known Issues**:
- Export creates folder structure but not zip file (OS share limitation)
- Job failures not shown in UI (tracked, logged only)
- No undo for cascade operations

---

## License

Copyright © 2024 Ente Technologies, Inc.
Licensed under AGPLv3 - see LICENSE file for details.
