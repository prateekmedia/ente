# Nested Albums — Server-Centric Plan (schema + APIs)

## Summary
Add a lean, first‑class hierarchy to collections so parent/child relationships are durable and validated centrally, with minimal server impact. Introduce a single nullable `parent_id` column and a simple reparent API. Keep E2EE for names/metadata and avoid key re‑derivation; sharing remains per‑album. Provide optional batch and delete strategies only if needed after usage validation.

Goals
- Preserve backward compatibility for legacy clients.
- Keep parameter proliferation low; prefer a single `parent_id` column and reuse existing `updation_time` where reasonable.
- Avoid HKDF/re‑derivation. Keys remain independent per album.

Privacy note
- This plan intentionally makes the fact of hierarchy (parent pointers) visible to the server (metadata only). If strict “server must not learn structure” is a hard requirement, use the client plan (hierarchy in E2EE magic metadata) instead.


## Schema Changes (PostgreSQL)
- Table: `collections`
  - Add nullable `parent_id BIGINT` referencing `collections(collection_id)` with `ON DELETE SET NULL`.
  - Add index `collections_parent_id_index` on `(parent_id)`.
- No additional path/closure tables for MVP. Enforce a soft depth limit (e.g., 10) in application code; add a validator job to guard cycles.

Migration sketch
- Add column + index in `server/migrations/`:
  - `ALTER TABLE collections ADD COLUMN parent_id BIGINT NULL;`
  - `CREATE INDEX IF NOT EXISTS collections_parent_id_index ON collections(parent_id);`
  - `ALTER TABLE collections ADD CONSTRAINT fk_collections_parent_id FOREIGN KEY(parent_id) REFERENCES collections(collection_id) ON DELETE SET NULL;`

Notes
- Do not duplicate hierarchy in magic metadata on server path (avoid redundancy and drift).
- Keep `attributes` JSONB unchanged.


## API Changes

### Create collection with a parent
- Request: `POST /collections`
  - Body (add optional field): `{ ..., parentID?: number }`
- Handler: `server/pkg/api/collection.go:Create`
  - Bind `parentID` into `ente.Collection` (extend struct) and pass through.
- Repo: `server/pkg/repo/collection.go:Create`
  - Insert `parent_id`.
- Constraints: reject parent pointing to a non‑existent or deleted collection; disallow `favorites/uncategorized` as parent or child.

### Move (reparent) an album
- Request: `PATCH /collections/{id}/parent`
  - Body: `{ parentID: number | 0, expectedUpdationTime?: number }`
- Controller: new method `CollectionController.UpdateParent`
  - Verify ownership; optional optimistic check against `updation_time` if provided.
  - Validate:
    - Not self parent.
    - Depth ≤ 10 (walk ancestors).
    - No cycle (walk ancestors until root; abort if `{id}` seen).
    - Parent cannot be `favorites/uncategorized`.
  - Repo update: `UPDATE collections SET parent_id=$1, updation_time=$2 WHERE collection_id=$3` (+ conditional `AND updation_time=$expected` for CAS). Return 409 on CAS failure.

### List tree (read)
- Option A (minimal): extend existing responses to include `parentID` and let clients build trees.
  - `GET /collections/v2`: include `parentID` in `ente.Collection` JSON for owned collections; for shared, include child’s `parentID` as is. Update:
    - `server/ente/collection.go` to add `ParentID *int64 `json:"parentID,omitempty"``.
    - `server/pkg/repo/collection.go:Get, GetCollectionsOwnedByUserV2, GetCollectionsSharedWithUser` to select `parent_id` and populate.
- Option B (nice to have): `GET /collections/tree?root=<id>&depth=<n>` returns a typed subtree for export/desktop. Can be added later.

### Batch cascade share (no re‑derivation) — optional
- Endpoint: `POST /collections/share-tree`
  - Body: `{ rootID: number, toEmail: string, role: "VIEWER"|"COLLABORATOR", encryptedKeys: { [collectionID: number]: string /* sealed with sharee’s pk */ } }`
  - Controller verifies `encryptedKeys` cover only descendants owned by caller and writes rows in one transaction using existing share mechanics. Clients still seal keys; endpoint reduces API round‑trips.

### Guard adding files to deleted collections (hygiene)
- Tighten `AddFiles` path to verify `collections.is_deleted = false` (small safety hardening). File path: `server/pkg/repo/file.go:AddFiles`.


## Server Code Touch Points
- Model
  - Add `ParentID *int64` to `ente.Collection` (`server/ente/collection.go`).
- API
  - `server/pkg/api/collection.go`: accept/emit `parentID`; add `Parent` PATCH route.
- Controller
  - `server/pkg/controller/collections/collection.go`: implement `UpdateParent`; reuse `verifyOwnership`.
  - Add helper `validateHierarchy(collectionID, newParentID)` with ancestor walk.
- Repo
  - `server/pkg/repo/collection.go`: CRUD to include `parent_id` column.
- Migrations
  - New migration files as above.


## Client Changes (to use server-native hierarchy)
- Web & Mobile
  - Update JSON types to read `parentID` from `Collection`.
  - On create sub‑album or move: call `POST /collections` with `parentID` or `PATCH /collections/{id}/parent`.
  - Tree rendering remains client-side but built from server field; remove reliance on public magic metadata for parent.
- Desktop watch
  - When mirroring a directory tree, first ensure the chain by repeated `POST /collections` with `parentID`.

Backward compatibility
- Return `parentID` only to upgraded clients initially if needed: gate on a request header (e.g., `X-Ente-Nested: 1`).
- Legacy clients continue to function (see a flat list; create root-only albums). Server rejects legacy writes that would break the tree if we choose to gate writes by header.


## Sharing Semantics
- No automatic inheritance of access. Parent/child access is independent.
- Cascade share is optional via `POST /collections/share-tree` and client-provided sealed keys.
- Public links remain album-scoped.


## Validation Rules
- `parentID == id` → reject.
- `parentID` points to deleted/missing → reject.
- Parent/child cannot be `favorites/uncategorized`.
- Depth ≤ 10. Controller computes depth by walking ancestors.
- Cycle detection: walk ancestors; nightly integrity cron that traverses graph and logs anomalies.


## Concurrency & Sync
- CAS via `expectedUpdationTime` avoids blind overwrites on reparent.
- Reparent updates bump `updation_time` so diff sync picks them up.
- Clients should chunk large reparent batches (≤1,000 per wave) to respect CollectionDiffLimit and apply backoff on rate limits.


## Trade‑offs vs Client‑First
Pros
- Single source of truth; simpler clients; server can validate invariants.
- Enables server features (e.g., subtree queries for export/analytics later).

Cons
- Reveals hierarchy to server (metadata); if this is unacceptable, prefer the client plan.
- Requires migration + API changes across all clients.


## Rollout Plan
1) Ship read-only: add `parentID` to responses; clients ignore if absent.
2) Add `PATCH /collections/{id}/parent` behind feature flag; dogfood with desktop.
3) Mobile/Web adopt create-with-parent + move UI.
4) Enable `POST /collections/share-tree` for batched shares.
5) Remove flag, document APIs.


## Test Plan
- Unit: controller validation (depth/cycle), repo CRUD parent, share-tree batch path.
- Integration: create/move/un-nest, delete parent with children (validate `SET NULL`), diff flow delivers updates.
- Migration: forward/backward migrations on staging with real data.


## Files to change (initial list)
- `server/ente/collection.go`
- `server/pkg/api/collection.go`
- `server/pkg/controller/collections/collection.go`
- `server/pkg/repo/collection.go`
- `server/migrations/XX_collections_add_parent_id.up.sql`
- `server/migrations/XX_collections_add_parent_id.down.sql`
