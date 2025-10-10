# Nested Albums Final Blueprint

This blueprint captures two implementation paths for nested albums. Option A builds first-class hierarchy support in the backend (schema + APIs). Option B keeps the database flat and encodes hierarchy using existing public magic metadata plus richer client logic. Both options include explicit handling for watch folders, manual uploads, mobile sync, shared collections, and encryption.

The document is structured as:

1. Common goals & constraints
2. Option A – Server-native hierarchy
   - Data model updates
   - API contract changes
   - Encryption & key handling
   - Client implementation steps (web/desktop, watch folder, mobile, shared collections)
   - Migration & backfill plan
   - Edge cases & acceptance tests
3. Option B – Metadata-driven hierarchy
   - Metadata schema additions
   - Client orchestration (uploads, watch folder, shared collections)
   - Encryption handling
   - Migration & background repair
   - Edge cases & acceptance tests
4. Comparison & rollout guidance

---

## 1. Common Goals & Constraints

- Support arbitrarily deep album hierarchies while keeping duplicate folder names safe.
- Watch folder ingestion must deterministically map each on-disk directory to the correct album chain, even when multiple folders share the same name.
- Manual uploads (web/desktop/mobile) should offer three behaviors: single album, parent-per-folder, nested hierarchy.
- Shared collections: recipients may only receive the root album initially; the design must allow them to discover authorized descendants and decrypt their keys without leaking hidden branches.
- Encryption: every collection key is end-to-end encrypted. Any hierarchy solution must ensure a device with access to a parent can obtain or request the child keys it is authorized to view.
- Clients must work offline with cached hierarchy metadata and re-sync safely when changes arrive.
- Existing collection types (favorites, uncategorized, quick links) remain compatible.

---

## 2. Option A – Server-Native Hierarchy

### 2.1 Data Model Updates

1. **Collections table (new columns)**
   - `parent_collection_id BIGINT NULL` — FK to `collections.collection_id`, NULL for roots.
   - `root_collection_id BIGINT NOT NULL` — cache of the root ancestor for fast filtering.
   - `path_cache INT[] NOT NULL DEFAULT '{}'` — ordered list of ancestor IDs.
   - `tree_discriminator UUID NULL` — optional logical tree identifier for multi-root shares.
   - Add unique index `(owner_id, parent_collection_id, lower(name))` (NULL parent treated as root).
   - Add index on `(root_collection_id, path_cache)` and `(owner_id, path_cache)` for subtree queries.
2. **Triggers / repository invariants**
   - On insert/update: populate `root_collection_id` and `path_cache` based on parent.
   - Prevent cycles (raise if parent resolves into descendant).
   - Keep `tree_discriminator` = root collection UUID for fast grouping (set when root created).
3. **Collection DTOs & models**
   - Update Go structs (`ente/collection.go`, `server/pkg/repo/collection.go`, `server/pkg/service/collection`) to include the new fields.
   - Carry `childCount` (computed) and `hasChildren` booleans to avoid extra queries.

### 2.2 API Contract Changes

| Endpoint | Change | Notes |
|---|---|---|
| `POST /collections` | Accept optional `parentCollectionID` | Validate ownership, share equality, depth limit. Return new fields. |
| `PATCH /collections/{id}` | Allow parent change, rename, metadata updates | When reparenting, recompute caches + key chains. |
| `GET /collections/sync` | Add query params `root`, `includeDescendants`, `includeKeys` | Default returns flat list of user's collections; when `includeDescendants=true`, payload grouped by root with `childrenSummary` arrays and `descendantKeyChain`. |
| `GET /collections/{id}` | Support `?include=descendants,shareTree` | Used by share recipients to fetch only authorized sub-tree. |
| `POST /collections/{id}/share` | Extend request to optionally include descendant IDs | Owner chooses which child branches to share. |
| `POST /collections/{id}/watch` (desktop IPC) | Accept new mapping `"nested"` | Returns canonical path mapping and collection IDs. |

### 2.3 Encryption & Key Handling

- API responses that include hierarchy data must pair it with key tuples so a client can derive child keys. Standard tuple: `{ collectionID, encryptedKey, keyDecryptionNonce, keyVersion, parentCollectionID }`.
- New response blocks:
  - `descendantKeyChain`: ordered list for the requested subtree (owner or share recipient).
  - `createdDescendants`: returned from create/move endpoints so initiator caches keys immediately.
  - `updatedKeyChain`: returned when parent or share context changes, instructing clients to refresh key caches.
- Sharing behavior:
  - When owner shares root with collaborator, server records which descendants are included. `GET /collections/{root}?include=shareTree` returns only those nodes with keys wrapped for the share.
  - Collaborators who later get additional branches receive an incremental `updatedKeyChain` on next sync.

**Server row example**

| collection_id | owner_id | parent_collection_id | root_collection_id | path_cache | name | encrypted_key | key_decryption_nonce | key_version |
|---|---|---|---|---|---|---|---|---|
| 42 | 7 | NULL | 42 | `{}` | Trips | ENC[k_trips] | nonce_42 | 3 |
| 84 | 7 | 42 | 42 | `{42}` | 2024 | ENC[k_2024] | nonce_84 | 1 |
| 126 | 7 | 84 | 42 | `{42,84}` | Day 1 | ENC[k_day1] | nonce_126 | 1 |

A collaborator fetching `42` with `include=shareTree` receives `childrenSummary=[84]`, `descendantKeyChain=[(84,...),(126,...)]` (only if Day 1 is shared). Keys are double-wrapped with the share key.

### 2.4 Client Implementation Steps

#### Web/Desktop (React + Electron)

1. **Shared Types**: extend `CollectionMapping` enum with `"nested"` and update IPC types (`web/packages/base/types/ipc.ts`, `desktop/src/types/ipc.ts`).
2. **Watcher Service (`web/apps/photos/src/services/watch.ts`)**
   - Accept nested mapping parameter.
   - For each file event, compute relative path from watch root, split into components.
   - Maintain `Map<relativePath, CollectionInfo>` cached from server-provided tree to avoid redundant queries.
   - On unknown path, call new API `PUT /collections/tree/resolve` to create or fetch hierarchy (returns `createdDescendants`).
3. **Upload Flow (`web/apps/photos/src/components/Upload.tsx`)**
   - Offer third option "Nested" that uses relative path depth to group.
   - When grouping, request `resolveHierarchy` to ensure parents exist prior to upload.
   - After upload, persist collection chain in pending uploads so restarts resume correctly.
4. **Shared Collections UI**
   - Update gallery navigation to render tree using `childrenSummary` + `hasChildren` fields.
   - Lazy-load descendants via `GET /collections/{id}?include=descendants&includeKeys=false` when user expands a node; request keys only when decryption required.
5. **Key Cache**
   - Store tuples keyed by `(collectionID, keyVersion)` in IndexedDB (web) / local storage (desktop) to support offline decrypt + watch operations.

#### Desktop Watcher (Node layer)

- Update `desktop/src/main/services/watch.ts` to persist nested mapping information in watch store.
- When scanning disk, send `relativePath` plus top-level folder to renderer.
- Ensure chokidar handles duplicate names by scoping watchers per absolute path.

#### Mobile Apps

1. **Collection Models**: extend Dart/Kotlin classes with `parentCollectionID`, `rootCollectionID`, `pathCache`, `childCount`.
2. **Sync Service**: on diff, insert/update rows using new fields; maintain adjacency list for fast tree rendering.
3. **Uploads**: allow nested creation during takeout import; call `resolveHierarchy` before uploading.
4. **Shared Collections**: ensure share flow requests descendants as described, caching key ladder locally.

### 2.5 Migration & Backfill

1. **Schema migration**: add columns with defaults, rebuild indexes.
2. **Backfill job**:
   - Determine root sets (system collections stay roots).
   - Use heuristics (existing folder attributes, encrypted paths) to infer parent relationships; default ambiguous albums to roots.
   - Populate `parent_collection_id`, `root_collection_id`, `path_cache`, `tree_discriminator`.
   - Log unresolved items for manual review.
3. **Key regeneration**: not required—existing encrypted keys remain valid. Only metadata is enriched.
4. **Feature flags**: keep read/write guarded until all clients support new attributes.

### 2.6 Edge Cases & Acceptance Tests

- Duplicate folder names under different parents.
- Watch folder rename event (file moved between siblings) should move media between collections.
- Album deletion with children: either prevent deletion until children reparented or cascade deletion (decide policy; default to block).
- Share partial subtree: ensure unauthorized children not visible and keys not returned.
- Offline upload resumes after reconnection, using cached hierarchy.
- Key rotation for root rewraps descendant keys; clients reconcile via `updatedKeyChain`.
- Migration fallback: verify no cycles created; run integrity check so every row’s `path_cache` matches actual parent chain.

---

## 3. Option B – Metadata-Driven Hierarchy (No schema change)

### 3.1 Metadata Schema Additions

Augment `CollectionPublicMagicMetadataData` (web + mobile) with:

- `nestedPath: string` — POSIX path-like string (e.g., `Trips/2024/Day 1`).
- `nestedParentId: number | null` — optional direct parent ID hint.
- `nestedRootId: number` — root collection ID.
- `nestedDepth: number` — cache depth for quick sorting.
- `nestedKeyVersion: number` — bumps when key rotates or share data updates.

All fields live inside the existing `pub_magic_metadata` blob. Increment schema version to signal new format; older clients ignore unknown keys.

### 3.2 Client Orchestration

1. **Hierarchy Cache**
   - At sync, build `Map<nestedPath, CollectionID>`, `Map<CollectionID, { nestedPath, parentID, encryptedKey, keyNonce, keyVersion }>`.
   - Persist caches in IndexedDB/SQLite so watch folder and visualization logic can resolve paths offline.
2. **Uploads & Watch Folder**
   - For nested uploads, compute relative path and look up `nestedPath`. If missing, create new collection via existing API and immediately write metadata with new `nestedPath`.
   - Watch folder uses same cache to map events. If creation required, generate chain locally by creating parents first, updating their metadata, then recursively proceeding.
3. **Shared Collections**
   - Owner sets `nestedPath` for children they intend to share and ensures share payload lists each child with encrypted key.
   - Share recipients fetch `shareDescendants` record (new lightweight endpoint or extension of `/collections/{id}`) returning `{ nestedPath, encryptedKey, keyNonce, keyVersion }` for authorized children.
   - Recipients merge this into local cache; unauthorized children never appear.
4. **Conflict Handling**
   - On rename or move, owner client updates `nestedPath` for target collection and all descendants, bumping `nestedKeyVersion` to signal watchers/cache invalidation.
   - Collaborators detect mismatches via version check and pull latest metadata.
5. **Key Cache**
   - Store `encryptedKey`, `keyDecryptionNonce`, `keyVersion` alongside `nestedPath` so decrypt steps mirror Option A’s ladder.

### 3.3 Encryption Handling

- Creation: new sub-album key encrypted with owner’s account key; for sharees, use existing share re-encryption path.
- Metadata update: anytime a key rotates, increment `nestedKeyVersion` and push new encrypted key tuple within existing `collection update` payload.
- Shared fetch: recipients use share API to obtain list of authorized descendants with re-wrapped keys.

### 3.4 Migration & Background Repair

1. **Initial backfill**
   - On first launch with feature flag, compute `nestedPath` for all existing collections (derive from folder attributes when present, otherwise default to root). Write metadata via `PATCH /collections/{id}/magic-metadata`.
2. **Repair task**
   - Periodic job verifies caches: if a collection lacks `nestedPath`, recompute and queue metadata update.
   - If duplicate `nestedPath` detected, prompt user or auto-resolve by appending suffix.
3. **Watch folder bootstrap**
   - When user enables nested mode, client ensures the watch root collection has `nestedPath` and caches resolved descendant map before starting watcher.

### 3.5 Edge Cases & Acceptance Tests

- Double folders with same name at same level (prevent by append numeric dedupe in metadata creation).
- Lost metadata (e.g., offline client with stale cache): server remains flat; client should rebuild tree from stored metadata on next sync.
- Collaborator receiving only root: ensure `shareDescendants` returns empty list; UI hides expand caret.
- Shared branch removed: owner clears metadata and share; collaborators receive diff removing entries.
- Key rotation without metadata update: version mismatch triggers fail-safe re-fetch.
- Export/import flows (zip uploads) must include metadata JSON with desired `nestedPath` to avoid re-deriving.

---

## 4. Comparison & Rollout Guidance

| Aspect | Option A (Server) | Option B (Metadata) |
|---|---|---|
| Schema changes | Requires new columns, indexes, migrations | None |
| Determinism | Enforced by backend; clients simple | Depends on metadata consistency |
| Shared collections | Authoritative tree returned by API | Relies on owner-maintained metadata |
| Watch folder performance | Single lookup per new path via API | Client caches; may be faster offline |
| Migration complexity | Heavy (backfill, cycle detection) | Moderate (metadata backfill per client) |
| Future features (move subtree, server search) | Easier — server understands tree | Harder — server still flat |

**Suggested path**

- If long-term roadmap includes server-side hierarchical queries, move semantics, or search by folder, adopt Option A.
- If timeline is short and schema changes risky, Option B provides incremental value but requires disciplined metadata maintenance.
- Regardless of option, release order: backend (if needed) → desktop/web → mobile → enable feature flag → expand to collaborators.

**Next steps**

1. Decide between Option A and B with product/infra.
2. Prototype watch folder upload with nested mapping on staging.
3. Draft API docs or metadata contract doc for review.
4. Prepare migration/backfill scripts and dry-run on staging dataset.
5. Define telemetry (e.g., unresolved path matches, key-chain failures, share mismatches) to monitor once rolled out.

