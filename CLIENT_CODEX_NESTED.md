# Nested Albums — Client-First Plan (minimal server impact)

## Summary
Production-grade nested albums as a client-owned hierarchy overlay on top of today’s flat collections. The parent→child relationship is stored inside the child album’s public magic metadata (E2EE – encrypted with the child album’s key). This keeps the hierarchy consistent and visible to all legitimate viewers/collaborators of that album while remaining opaque to the server. No new DB columns, no new endpoints.

Scope is full feature parity: Hide, Archive, Trash, Share (incl. subtree tooling), Add Sub‑album, Move Album, Add/Move Files, Watch Folder, Import/Export, Desktop parity, and robust sync across devices.

Key decisions
- End‑to‑end encryption: hierarchy lives in public magic metadata, encrypted with the album key; server cannot read it. “Public” here means “visible to album participants,” not server‑readable.
- No HKDF/re‑derivation; each album keeps its own key. Sharing remains per‑album.
- No server changes; use existing create/rename/magic‑metadata endpoints.
- Backward compatible: old clients ignore the new fields and keep a flat list.


## Current State (code map)
- Server collections API and storage
  - Model: `server/ente/collection.go` (`Collection`, `MagicMetadata`), update entry points: `server/pkg/api/collection.go`.
  - Create supports both `magic_metadata` and `pub_magic_metadata` in DB via `repo.CollectionRepository.Create` but web/mobile currently only send `magicMetadata` on create.
  - Update endpoints exist for magic metadata: `PUT /collections/magic` (private) and `PUT /collections/public-magic` (public).
- Web types/services/UX
  - Collections model and magic-metadata plumbing: `web/packages/media/collection.ts`, `web/packages/media/magic-metadata.ts`.
  - Collections fetch/diff: `web/packages/new/photos/services/collection.ts`.
  - Collection summaries/bar/gallery: `web/packages/new/photos/services/collection-summary.ts`, `web/apps/photos/src/pages/gallery.tsx`.
  - Upload, import, watch folder: `web/apps/photos/src/components/Upload.tsx`, `web/apps/photos/src/services/watch.ts`, `web/packages/base/types/ipc.ts`.
- Mobile (Photos app)
  - Collections service: `mobile/apps/photos/lib/services/collections_service.dart`.
  - Models (incl. magic metadata): `mobile/apps/photos/lib/models/collection/collection.dart` and `models/api/metadata.dart`.


- Only one hierarchy field inside the child album’s public magic metadata (encrypted with the child’s key):
  - `parentID: number` — parent collection ID (0 or absent = root).
- Rationale
  - Public magic metadata is readable by every participant of that album, so the tree is consistent for all who can see that album.
  - No server parsing required; server stores opaque blob and bumps version atomically.

Semantics
- Tree = union of all albums; an album appears under its `parentID` if set and that parent exists and is not deleted; otherwise render at root.
- No key derivation; sharing does not propagate implicitly. A user only sees children they can decrypt (i.e., albums actually shared with them).
- Special albums (`favorites`, `uncategorized`) never accept a parent; ignore requests to set `parentID` on them.

Security note
- Public magic metadata remains encrypted at rest and in transit. The server cannot inspect `parentID`; only album participants with the album key can decrypt and render nested placement.


## Operations (feature‑complete; existing APIs)
- Create sub‑album
  1) Create album (existing flow) via `POST /collections` from:
     - Web: `web/packages/new/photos/services/collection.ts:createCollection` (extend to optionally send `pubMagicMetadata` on create); or
     - Mobile: `CollectionsService.createAlbum` then set `parentID` via public magic metadata update.
  2) Set `pubMagicMetadata.data.parentID = <parentID>` using `PUT /collections/public-magic`.

- Move album under another album / Un-nest
  - Update target child’s `pubMagicMetadata` with new `parentID` (or `0` for root). Use the last known `version` when calling update; server increments it.

- Move files to a sub‑album
  - Use existing add/move APIs (`/collections/add-files` and `/collections/move-files`). No change.

- Delete/Trash album with children
  - Default strategy: Reparent children to root, then delete the selected album (prevents accidental bulk loss; consistent with “least surprise”).
  - Alternate strategy (UI option): “Also delete N sub‑albums” – client traverses children deepest‑first and deletes them; progress + undo within grace window.
  - Alternate strategy (UI option): “Block if children exist” – safe‑guard for users who prefer explicitness.

- Archive/Hide
  - Archive/Hide are per-album properties (owner private or sharee‑private as today). Provide a bulk action panel:
    - “Apply to this album only” (default)
    - “Apply to descendants” – client iterates descendants and updates respective metadata fields in batches (see Diff handling).

- Share
  - Unchanged primitives: `/collections/share`, `/collections/unshare`, public links.
  - Add “Share descendants…” action (owner‑only): wizard lets user pick subtree scope; client obtains sharee’s public key and seals each descendant album key; performs batched share calls with progress/rollback.

- Add/Move files to sub‑album
  - Unchanged primitives: `/collections/add-files` and `/collections/move-files`; new UI affordances expose nested destinations with breadcrumbs and search.


## Client Changes (by surface)

### Web
- Types
  - Add a typed helper for the new public MM key in `web/packages/media/collection.ts`:
    - Extend `CollectionPublicMagicMetadataData` type to include optional `parentID` (the Zod schema already accepts loose unknown keys, but adding the field improves ergonomics).
- Services
  - Creation: allow `createCollection` to optionally accept `pubMagicMetadata` and include it in `postCollections` body (`web/packages/new/photos/services/collection.ts`).
  - Tree building: new selector util that folds `savedCollections()` into a tree (computed state, no extra local DB schema):
    - Build `id → children[]` using each album’s `pubMagicMetadata.data.parentID`.
    - Detect/repair cycles locally (see “Validation”). Provide a non‑destructive fixer that clears invalid `parentID` to 0 and surfaces a toast with “Undo”.
    - Expose derived helpers: `roots()`, `children(id)`, `ancestors(id)`, `breadcrumbs(id)`.
  - Watch folder/import:
    - Add a new mapping option `"tree"` in `web/packages/base/types/ipc.ts:CollectionMapping`.
    - Update `web/apps/photos/src/services/watch.ts` to compute relative path from the chosen root and ensure the parent chain exists:
      - Resolve or create chain: root album → subfolders as child albums.
      - When creating each child, set its `parentID` via public MM (or pass at creation).
    - Update `Upload.tsx` import flow: if user selects “folders with nested subfolders”, create chain and set parents.
- UI/UX
  - Album bar and lists (`web/packages/new/photos/services/collection-summary.ts`, gallery):
    - Support rendering a nested list with expand/collapse, breadcrumbs at the top of an album view, and DnD album tile onto album tile to reparent (fires update public MM).
  - Context menus:
    - “New sub‑album” on an album tile (create + parent).
    - “Move album…” (shows a chooser restricted to valid destinations).
  - Performance: virtualization for album trees and large lists; incremental loading of descendants; optimistic UI for small reparent; background reflow for bulk moves.

### Mobile (Flutter)
- Parse/Use parent
  - `Collection.pubMagicMetadata` already deserializes into a JSON string; add a getter for `parentID` in `mobile/apps/photos/lib/models/collection/collection.dart`.
  - For navigation, build the same `id → children[]` map in `CollectionsService`.
- Creation/move
  - Keep `createAlbum` as-is then call `PUT /collections/public-magic` to set `parentID`. Add helpers: `setParent(collectionID, parentID)` with validation + retries; background sync with progress toasts.
- Watch device folders
  - Existing device folder ↔ collection path mapping remains unchanged for `folder` type collections. For “mirror device hierarchy to Ente”, implement optional “mirror tree” mode that creates/uses nested albums and sets `parentID` links.

### Desktop (Electron)
- Mirror the web changes (UI is shared).
- Extend IPC “watch” to accept and persist mapping `"tree"` and cache `path → collectionID` chain for faster restarts.


## Validation & Guards (client‑only)
- Cycle prevention: before setting a child’s `parentID`, compute `ancestors(newParent)` and block if it contains the child.
- Depth limit: enforce a soft cap (e.g., 10). Warn beyond that; still allow if product OK.
- Ownership: only owners can reparent; server already checks ownership for magic‑metadata updates.
- Special types: reject nesting for `favorites`/`uncategorized`.
- Missing parent: if `parentID` points to a deleted/missing album, render child at root; owner’s client can offer “Fix parent” quick action that clears `parentID` (set to 0).

Share constraints
- Prevent reparenting an album owned by user under a parent that the user does not own.
- If album has sharees and new parent is hidden/archived, prompt with consequences (visibility might differ for sharees) and allow continuing with bulk updates to sharee metadata if requested.


## Sync, Concurrency & Diff Limits
- Server does not CAS collection magic metadata; we implement optimistic concurrency with conflict detection:
  - Read latest magic metadata version; compute update; if post‑pull shows a different parent than expected, surface a “Was moved on another device” banner with a one‑click reconcile (reapply or accept remote).
  - For local bulk actions, serialize writes per album; queue per‑album updates.
- CollectionDiffLimit (2,500):
  - Chunk hierarchy updates into ≤1,000 updates per wave; wait for the next pull to confirm; proceed to next wave; show progress and support pause/resume.
  - Apply exponential backoff on 429/5xx.


## Sharing Semantics (no key derivation)
- Parent does not imply access to children; users see only albums explicitly shared with them.
- Provide an optional owner‑only action: “Share descendants with …” which iterates children and calls existing share endpoints to add sharees to selected descendants.
- Public links remain album‑scoped. Future enhancement: “Create links for subtree” (client batch).


## Import/Export
- Export: by default export as nested folders using the computed tree; add a setting to “flatten by album”. Update `web/packages/new/photos/services/export.ts` to create directories by `breadcrumbs(id)`.
- Import: add an option to map nested folders to nested albums (tree mode); reuse the watch-folder chain creation logic.


## Backward Compatibility
- Old clients ignore the new `parentID` field in public MM. They continue to show a flat list.
- No server schema change; diff endpoints already propagate `updationTime` for these updates.

Rollback & Feature flag
- A remote config flag gates nested‑album UI. If disabled, we keep writing/reading parentID but render a flat list (safe rollback). Provide “Flatten tree” tool for recovery.


## Testing Plan
- Unit: tree builder, cycle detection, breadcrumb, watchers’ path→chain creation.
- Integration: create/move/un-nest; concurrent move from two devices; delete parent while moving child.
- E2E: watch‑folder tree upload; import/export roundtrip; sharing a parent + selective child share.
 - Load: simulate 10k albums, 50k files; measure latency for tree build, bulk reparent, and diff pulls; verify chunking respects limits.


## Deliverables (PR checklist)
- Web
  - Extend types and `createCollection` to accept `pubMagicMetadata` (optional).
  - Tree state + selectors and bar rendering updates.
  - DnD/context menus for new/move sub‑album.
  - Watch/import “tree” mapping and chain‑create helper.
  - Export nested directory structure.
- Mobile
  - `parentID` accessors, tree builder.
  - Helpers to set/clear parent; UI to create/move sub‑album.
- Desktop
  - IPC mapping addition and persistence for `"tree"`.


## Notes & Non‑Goals
- No automatic share propagation and no derived keys.
- Server‑side subtree queries, server‑enforced hierarchy constraints, and subtree links are out of scope for this plan (covered in SERVER_CODEX_NESTED.md alternative).
