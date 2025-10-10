# Nested Albums Research

## 1. Current Architecture Snapshot (Oct 1, 2025)

### Server (`server/`)
- **Collections remain flat.** `ente.Collection` has no parent pointer; `CollectionAttributes` only carries (encrypted) path metadata for device linking.
- **Valid types:** `album`, `folder`, `favorites`, `uncategorized`. Special types have custom deletion/sharing rules (`AllowDelete`, `AllowSharing`).
- **Sync model:** `/collections` (and `/collections/v2/diff`) return all collections the user owns or that are shared with them. Diff APIs operate per collection ID; clients merge results locally.
- **Magic metadata:** separate private/public/sharee blobs store visibility (hidden/archive), ordering, cover, quick-links state. No hierarchical hints today.
- **Sharing:** Owner decides which collection IDs are shared. Public links wrap a single collection. There is no concept of sharing a subtree.
- **Trash/archive:** Controllers ensure only owners can delete, move or archive collections; cascades are client-driven (server merely enqueues delete / moves files to trash collections per request).

### Web & Desktop (`web/`, `desktop/`)
- **Collection model:** `web/packages/media/collection.ts` mirrors server fields; hierarchy inferred client-side via name/path only.
- **Uploads:** `upload-manager.ts` funnels drag-and-drop, file picker, and takeout imports. Folder uploads currently present two options:
  - `Single album` – everything lands in one collection.
  - `Separate albums` – create sibling albums per leaf folder; hierarchy is flattened at upload.
- **Watch folders:** Desktop watcher maintains `FolderWatch` entries with `collectionMapping` of `"root"` or `"parent"`. No support for deeper nesting; events resolved based on root folder basename or immediate parent folder name.
- **Exports:** CLI/desktop exports mirror today’s flat album list (folders named after collection display names). JSON sidecars store metadata for re-import but do not encode ancestor relationships beyond folder names.
- **State caching:** Collections cached in IndexedDB/local storage keyed by ID; no persistent `path -> id` map besides watch-folder bookkeeping (per-machine).

### Mobile (`mobile/apps/photos/`)
- **CollectionsService** caches decrypted names and device paths using `CollectionAttributes`. Device albums map to Ente collections when the collection type is `folder` and the user is the owner.
- **Sync:** Diff fetcher pulls `/collections/v2/diff` and `/collections/{id}/v2/diff`. The app expects a flat list; grouping, sorting, and search results use derived hierarchies (e.g., `HierarchicalSearchUtil`) but are cosmetic.
- **Uploader:** Device albums (Camera, Screenshots) sync into dedicated Ente collections. Nested device folders are flattened because only the leaf folder name is used while linking.
- **Magic metadata consumers:** Hidden/archive/auto-add rely on metadata per collection; favorites & uncategorized are special-case collections.

### CLI / Infra
- CLI export/import expects flat album IDs; uses the same REST APIs as other clients and currently lacks hierarchy semantics beyond folder names embedded in metadata JSON.

## 2. Goals & Constraints
- Introduce true hierarchical albums (arbitrary depth, deterministic ordering) without breaking existing clients or forcing immediate updates.
- Maintain end-to-end encryption guarantees; avoid re-encrypting entire subtrees on rename/move.
- Support all existing flows (manual upload, watch folders, device backups, sharing, public links, export/import, hidden/archive/trash) under the new model.
- Backward compatibility: legacy clients must continue to operate (treat nested collections as flat) until upgraded.
- Avoid non-scalable operations (e.g., rewrapping every descendant key on every move).

## 3. Scenario & Edge Case Matrix

### 3.1 Creation & Organization
- **Manual creation (web/mobile):** Create root and nested albums, optionally in one action (dragging a nested folder). Need deterministic parent resolution when multiple threads/clients create simultaneously.
- **Rename / move:** Updating parent or name should propagate to children’s computed display path. Must avoid key churn—only update metadata references.
- **Deletion:** Options: block if children exist, cascade delete, or auto-reparent. Needs consistent UX rules plus safeguards for shared descendants.
- **Pinning & sorting:** Magic metadata for pin/order remains per collection. Nested UI likely needs parent-aware sort (e.g., pinned parent floats entire subtree).

### 3.2 Import & Watch Flows
- **Drag-and-drop folder (web/desktop):** Today we offer `single` vs `separate` albums. New flow must add `preserve hierarchy`, mapping each directory depth to nested collections.
- **Watch folders (desktop):** Watcher must map filesystem paths to nested album chains. Requires storing `path -> collectionID` per depth and listening to move/delete/rename events producing collection move/update operations. Need conflict policy when two watch roots create same nested path.
- **Local device backup (mobile):** iOS/Android album sync uses `CollectionAttributes.encryptedPath`. Need deterministic encoding for nested relative paths (e.g., `Photos/Trips/2024`). Also consider OS album reparenting or duplicates.
- **Re-import from export (CLI/desktop):** Exporter should emit hierarchy metadata (JSON map). Re-import must recreate tree even if some nodes already exist, handling dedupe vs rename collisions.

### 3.3 Export & Backup
- **Desktop continuous export:** Expect nested directory structure matching Ente hierarchy. Must avoid infinite loops when exporting to a watched folder.
- **CLI incremental export:** Need to ensure path changes propagate (renamed parents should update export folder, or we maintain stable IDs with symlinks/redirect map).
- **Archive/offline copies:** Ensure hidden/archive state preserved per node even when nested.

### 3.4 Sync & Conflict Resolution
- **Diff comprehension:** Current per-collection diff lacks ancestor context. Clients need efficient way to detect hierarchy changes (parent switch, path rename, subtree moved). Options: parent version counters, `nestedPath` strings with version, or dedicated hierarchy diff feed.
- **Concurrent edits:** Guard against two clients reparenting the same node differently. Potential strategy: optimistic concurrency with path version numbers or compare-and-swap tokens supplied in patch requests.
- **Offline mode:** Clients must cache enough hierarchy metadata locally to queue operations and reconcile once online.
- **Locking during destructive ops:** When hiding/archive/trash operations run, need to prevent other clients from reintroducing children. Solutions include server-side operation intents (short-lived locks), or sequence numbers per collection to detect stale updates.

### 3.5 Sharing & Collaboration
- **User-to-user share:** Owner can share entire subtree or specific branches. Collaborators require access to relevant descendant keys. Need to avoid leaking paths for hidden branches.
- **Role-based permissions:** Collaborators may create children; viewers cannot. Ensure parent’s sharing policy propagates appropriately, or provide per-node overrides.
- **Partial share updates:** When owner adds/removes descendants from a share, sharees need incremental updates without resyncing everything.
- **Public links:** Public album links should optionally expose nested navigation. Need consistent URL structure and zipped exports matching tree.

### 3.6 Magic Metadata Features
- **Hidden & archive:** Operations may apply to individual collection or entire subtree. Decide whether hiding parent hides children by default. Ensure sharees’ private metadata stays independent.
- **Favorites & quick links:** Special collections remain top-level; should not accept children.
- **Smart/AI albums:** Generated collections (faces, locations) remain virtual; ensure nested real albums do not conflict with virtual grouping.

### 3.7 Search, Browse, UX
- **Navigation:** Web/mobile galleries need tree-aware filtering, breadcrumbs, and offline caching of expanded nodes.
- **Duplicate names:** Allow same leaf name under different parents. Need canonical internal path (e.g., encode full ancestry) to avoid collisions for watch/import/export.
- **Sorting & filters:** Keep existing sort (manual, name, date) while respecting parent grouping.

### 3.8 Backward Compatibility
- **Old clients (no nested support):** Must continue to list albums flat. Server can expose `parentID` only to upgraded clients (feature flag) and treat parentless view for others.
- **API gating:** Add versioned endpoints or opt-in flags (e.g., `includeHierarchy=true`). Legacy clients ignore unknown fields, but avoid breaking JSON schema (do not remove required fields).
- **Deferred upgrade:** Mixed-device households will run old and new builds concurrently. Ensure operations by old clients (e.g., rename) do not corrupt hierarchy; may restrict them from editing nested nodes or auto-flatten changes.

### 3.9 Migration & Integrity
- **Initial migration:** Need script to assign parent/root IDs or metadata for existing collections. Options: treat current list as roots, or infer parent from watch metadata (likely default to root until user reorganizes).
- **Backfill race conditions:** Ensure background jobs do not conflict with user-driven restructure.
- **Integrity checks:** Detect cycles, orphaned nodes, duplicate paths. Provide repair tools (server job + client prompts).

### 3.10 Security & Privacy
- **Key handling:** Child collections retain existing keys. Reparenting should only update metadata; keys remain valid. When granting new share access to child, wrap child key with sharee’s public key without touching descendants unless needed.
- **Metadata exposure:** If using plaintext parent IDs on server, ensure encrypted names remain; avoid leaking hierarchy to unauthorized sharees (tie exposure to authorization checks).

## 4. Approaches

### 4.1 Option A – Server-Native Hierarchy
**Concept:** Extend database schema with `parent_collection_id`, cached `root_collection_id`, and ancestry array. Server enforces tree invariants; APIs return hierarchy metadata.

**Key Changes**
- Add columns and indexes to `collections` table; migration fills defaults (all roots).
- Extend REST:
  - `POST /collections` accepts `parentCollectionID`.
  - `PATCH /collections/{id}` handles rename, reparent, move, ordering.
  - `GET /collections` supports `includeHierarchy=true` returning `childrenSummary` + `descendantKeyChain`.
  - Share endpoints accept descendant lists; new `GET /collections/{id}?include=descendants` for share recipients.
- Expose `parentCollectionID`, `rootCollectionID`, and `pathVersion` to clients. Server increments `pathVersion` on hierarchy mutations.

**Pros**
- Single source of truth; deterministic behavior across clients.
- Server can efficiently serve subtree exports, partial shares, search (future).
- Simplifies conflict detection—server rejects cycles, duplicate siblings, unauthorized moves.
- Easier to build admin tooling, integrity checks, telemetry.

**Cons**
- Requires non-trivial schema migration, API versioning, and backfill.
- GO + SQL changes touch critical path (collections table heavy use). Needs careful rollout, zero downtime migration.
- Legacy clients must be audited; may need read-only fallbacks when encountering nested parents.

**Implementation Hints**
- Use transactional triggers to set `root_collection_id`/`path_cache`. Validate depth limit (optional).
- Provide `pathFingerprint` (hash of ancestry IDs) for quick comparisons and to aid watch folder mapping.
- For compatibility, default `GET /collections` to flat list unless `includeHierarchy` requested.
- Feature flag create/move endpoints; keep old clients creating root-only until upgrade.

**Migration Strategy**
1. Deploy schema with nullable parent columns (default null).
2. Roll out server returning new fields behind feature flag.
3. Update clients to ignore/understand fields.
4. Enable nested creation in clients after majority adoption.
5. Optional: run background job to populate `path_cache` for data integrity.

### 4.2 Option B – Client-Orchestrated Metadata Hierarchy
**Concept:** Keep DB flat. Encode hierarchy in `CollectionPublicMagicMetadata` (owner-shared) and private metadata (owner-only). Clients interpret `nestedPath`, `parentHint`, etc., to build tree. Server remains unaware.

**Key Changes**
- Define metadata schema with fields: `nestedPath`, `nestedParentId`, `rootId`, `depth`, `pathVersion`.
- On upload/move, client updates metadata for affected nodes (owner writes to private/public metadata; sharees receive updates via metadata diffs).
- Watch folders maintain local map `path -> collectionID` stored in client DB. Conflicts resolved via deterministic naming (append suffix).
- Share recipients fetch `shareDescendants` metadata via new lightweight endpoint or metadata fetch.

**Pros**
- No schema changes; lower risk to production database.
- Faster to prototype; iteration confined to clients + metadata plumbing.
- Allows gradual rollout per client without server deployment dependency.

**Cons**
- Consistency relies on clients behaving correctly; difficult to guarantee cross-device sync, especially with legacy clients ignoring metadata.
- Conflict resolution complex (two clients editing same subtree). Without server enforcement, divergent `nestedPath` states possible.
- Sharing semantics harder—need custom payloads to share metadata securely without leaking unauthorized branches.
- Server-side features (export, search, CLI) still see flat list; require duplicating client logic in each consumer or building bespoke metadata interpreters.

**Mitigations**
- Introduce validation service (periodic server job) to read metadata and detect duplicates/loops.
- Use `pathVersion` incremental integers; operations require sending previous version and server rejects mismatched updates (lightweight CAS semantics).
- Provide fallback to auto-flatten if inconsistencies detected.

### 4.3 Option C – Hybrid: Server Validates, Clients Store Paths
**Concept:** Continue storing hierarchy primarily in metadata but add lightweight server columns for validation (e.g., `parent_hint`, `path_hash`, not authoritative). Server exposes helper APIs to translate between `nestedPath` and IDs, enabling CLI/export/service use without full schema change.

**Pros**
- Reduces migration blast radius while giving server leverage to detect cycles/conflicts.
- CLI/export can query server for resolved hierarchy map even if DB remains flat.
- Could serve as transitional step toward full server-native approach.

**Cons**
- Two sources of truth risk; eventual move to Option A still needed for long-term maintainability.
- Added complexity without the full benefits of Option A.

## 5. Handling Key Flows Across Approaches

| Flow | Option A | Option B | Hybrid Notes |
| --- | --- | --- | --- |
| **Creation** | Single POST can create child via `parentCollectionID`; server enforces uniqueness. | Client creates root (existing API), then updates metadata to link parent; race handling manual. | Provide helper API `POST /collections/resolve-parent` for deterministic ID creation. |
| **Rename / Move** | `PATCH` updates parent & name atomically; server increments `pathVersion`. | Client recomputes `nestedPath` for subtree, updates metadata sequentially; risk of partial updates if crash mid-way. | Server tracks `path_hash` and rejects conflicting updates. |
| **Watch folders** | Desktop stores `path -> collectionID`, calls server to ensure parent tree exists; watch events send create/move requests referencing IDs. | Desktop updates metadata itself; must ensure order (create parents before children). | Use server helper to upsert chain in one call but still store metadata. |
| **Export** | Server/CLI query subtree via `root_collection_id`; deliver zipped hierarchy cheaply. | CLI reconstructs tree by parsing metadata; heavy on client. | Introduce `/collections/tree` endpoint reading metadata to respond. |
| **Sharing** | Server handles share tree; can grant partial subtree and send `descendantKeyChain`. | Owner’s client pushes metadata to share recipients; recipients must trust metadata. | Server caches share metadata but still reads from metadata fields. |
| **Diff sync** | New diff endpoint returns hierarchy mutations (e.g., `collectionHierarchyDiff`). | Clients compare metadata versions; large updates potentially heavy. | Server-supplied validation tokens reduce reconciliation cost. |
| **Back compat** | Server hides parent fields unless flag set; legacy clients continue to see flat list. | Harder: metadata updates may confuse legacy clients (they might overwrite/clear new fields). Need gating to prevent old clients from editing nested nodes. | Provide server guard that rejects metadata writes from old app versions to nested nodes. |

## 6. Recommendation
- **Preferred:** **Option A (Server-Native Hierarchy)** for long-term maintainability, deterministic behavior, and better support for enterprise/mobile multi-device scenarios. It simplifies sharing, exports, and future features (server-side search by folder, subtree permissions).
- **Short-term fallback:** If timeline or risk prevents immediate schema change, Option B can deliver MVP nested navigation quickly but should be considered temporary. In that case, bake in telemetry and server-side validators to monitor drift, and plan migration path to Option A.
- **Hybrid** can act as bridge if we want immediate watch-folder improvements while designing full migration.

## 7. Backward Compatibility Strategy (for Option A)
1. **Feature flag gating:** New fields returned only when client sends `X-Ente-Nested: 1` header.
2. **Legacy operation policy:** Old clients can continue to create/rename root-level albums. Server rejects attempts to modify nested nodes when request lacks nested header, preventing corruption.
3. **Client rollout order:**
   - Update desktop/web to understand hierarchy (hidden UI toggle).
   - Update mobile to ignore unseen parents but respect `parentCollectionID` when present.
   - Update CLI/export to consume new tree endpoint.
4. **Migration:** Start with every existing collection as root. Offer UI flow for users to reorganize. Optionally import existing watch-folder folder structures as suggestions.
5. **Telemetry:** Track hierarchy adoption, failed operations, conflicting updates, share tree depth, etc.

## 8. Edge Case Mitigations & Open Questions
- **Simultaneous watch + manual moves:** Introduce per-collection `pathVersion` CAS token; watch operations supply last seen version and retry on conflict.
- **Hide/archive concurrency:** Provide server API to mark collection state transitions with transactional diff (e.g., `PATCH /collections/{id}/visibility`), optionally locking subtree during operation or rejecting if other writes occurred since last version.
- **Public link scoping:** Decide whether a public link exposes entire subtree by default or only direct children. Might need ability to generate scoped public links per nested node.
- **Cycle prevention:** Server must reject `parentCollectionID` pointing to descendant. Add integrity cron to verify.
- **Deleted parents:** Define behavior when parent trashed—auto-trash children or auto-promote to root.
- **Search indexing:** Update search services to index `nestedPath` for faster folder search.
- **Quota accounting:** No change (files still count once), but ensure exports correctly duplicate files in multiple nested branches.
- **Watch folder rename detection:** Need reliable detection of directory renames to trigger hierarchical move rather than delete+upload.
- **CLI compatibility:** Provide `--flatten` flag for legacy exports; default to hierarchical output once feature stable.
- **API docs & SDKs:** Update public docs, regenerate TypeScript/Swift/Kotlin API bindings.

## 9. Suggested Next Steps
1. Align with product & infra on choosing Option A vs Option B timeline.
2. Design server schema/migration (Option A) or metadata contract (Option B) with security review.
3. Draft detailed client integration plan per platform (watch folder behavior, UI/UX changes, offline storage).
4. Prototype watch-folder nested upload on staging to validate path-version and conflict handling.
5. Define telemetry & alerting for hierarchy inconsistencies.
6. Prepare user comms (docs updates, migration tips) before public rollout.

