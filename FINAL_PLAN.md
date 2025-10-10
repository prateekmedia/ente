# FINAL PLAN — Nested Albums (Production-Ready)

## 1) Context & Goals
- Replace flat albums with a robust nested album experience.
- Preserve backward compatibility and end‑to‑end encryption (E2EE).
- Minimize server impact initially; add server support only if justified.
- Support all features that touch albums: Hide, Archive, Trash, Share (incl. subtree), Add/Move Sub‑albums, Add/Move files, Watch Folder, Import/Export, Desktop parity, Sync, Conflict handling.

## 2) Final Architecture Decision
Client‑first hierarchy with E2EE public magic metadata.
  - Store only `parentID` inside the child album’s public magic metadata.
  - “Public” here means: visible to album participants; still encrypted at rest/in transit with the album key. Server cannot read it.
  - Build the tree entirely on clients; no server schema or endpoint changes.

## 3) Data Model
- Client (local model):
  - Maintain computed tree in memory from `savedCollections()`.
  - No new local tables required; memoize for performance.
- Remote (Phase 1):
  - Child album’s public magic metadata contains:
    - `parentID: number` (0 or absent = root)
  - All fields encrypted with child album’s key; server stores opaque blob.
- Optional (for nested public links only): parent album’s public magic metadata contains an E2EE “nested link manifest” (v1) with child entries `{ collectionID, publicToken, childKeyBase58, options }`. Present only when a user creates a nested public link for that parent.
- Remote (Phase 3, optional):
  - Add `parent_id` BIGINT (nullable) to `collections`.

## 4) Feature Coverage (Phase 1)
- Sub‑album creation
  - Create album with existing API; then set `parentID` via public magic metadata update.
- Move album
  - Update child’s `parentID`; validate cycle/depth/ownership/collection type before write.
- Add/Move files
  - Use existing `/collections/add-files` and `/collections/move-files`. Destination picker supports nested tree with breadcrumbs and search.
- Hide/Archive
  - Per‑album as today (owner private or sharee private). Provide cascade options: apply to descendants with batched updates and progress.
- Trash
  - Default: reparent children to root, then delete selected album.
  - Option: delete subtree (deepest‑first, progress + undo window).
- Share
  - Per‑album sharing as today.
  - New “Include sub‑albums” toggle in the Share dialog to apply sharing across a subtree. The client seals each descendant album key to the sharee and performs batched share calls with progress/rollback. Optional “Remove from descendants” on unshare.
  - Atomicity scope: subtree sharing consists of many per‑album updates and is therefore not strictly ACID across all sharees in Phase 1. We guarantee durability and exactly‑once semantics via a persisted, idempotent job queue and optimistic retries. If strict atomicity is required, enable Phase 2 batch endpoints to wrap a batch in a single server transaction.
- Public links
  - Default (unchanged): album‑scoped links.
  - New (optional): “Include sub‑albums” for public link. The client composes a nested public experience by creating (or reusing) child links and storing their tokens + keys inside the parent’s encrypted public metadata (nested link manifest). The public viewer reads this manifest (if present) to render a nested tree and switch albums seamlessly. Older viewers that don’t support the manifest will show only the parent (back‑compatible).
- Watch Folder / Import
  - New “tree” mapping: create chain of albums matching nested folders, setting `parentID` level by level; idempotent; handles renames as reparent.
- Export
  - Default exports nested directory tree based on breadcrumbs; flatten option preserved.
- Desktop parity
  - Web/desktop share codepaths; Electron watch integrates “tree” mapping.

### Nested Public Link Manifest Maintenance (consistency)
- When a parent album has an active nested public link, any change to its immediate children (add/remove/move into/out of the parent) triggers a background job that refreshes the parent’s encrypted “nested link manifest”.
- Refresh algorithm (ACID at the manifest level):
  1. Snapshot the intended child set (direct children only) and their current public‑link state.
  2. Ensure each child in the snapshot has a valid public link (create/reuse as needed, backoff/retry on errors).
  3. Build the new manifest from the snapshot (child collectionID, token, childKey, options).
  4. Atomically write the new manifest by updating the parent’s public magic metadata using CAS on metadata version. Until this succeeds, the viewer continues using the previous manifest (no partial updates surface).
  5. Clean‑up (optional): disable links for children that were removed from the snapshot (best‑effort, happens after a successful manifest write to keep viewer consistency).
- Idempotency: per‑parent idempotency key for the refresh; safe to retry.
- Conflict handling: if CAS fails (another client updated), re‑read, recompute with the latest children set, and retry.

## 5) Validation & Guards (Client)
- Cycle prevention: block if `newParent` is a descendant.
- Ownership: only owner can reparent; respect collection type constraints (`favorites`, `uncategorized` cannot be parent/child).
- Share constraints: warn if reparenting across differing visibility; offer cascade updates for descendants as needed.
- Public nested links: warn for large subtrees and restrictive settings (device/expiry limits are per‑album link). Offer “disable all child links” or “rotate nested link” flows.

## 6) Sync, Conflict Handling, Diff Limits
- Optimistic concurrency: read current magic metadata version; on mismatch show banner “Moved on another device” with Reapply/Accept.
- Chunking: limit hierarchy edits to ≤1,000 updates per wave; perform remote pull between waves; exponential backoff on 429/5xx.
- Job queue: persisted, resumable; per‑album serialization; progress, pause/resume, partial‑failure summary.
  - Crash recovery: jobs are durably stored (IndexedDB/SQLite). On restart, a single worker resumes pending jobs using idempotency keys so repeated steps are safe. Multiple devices can cooperate safely because server endpoints are idempotent (upsert semantics) and manifest writes use CAS.

## 7) Performance & UX
- Virtualized lists for album bar/tree and large galleries.
- Optimistic UI for small reparent; background reflow for large batches.
- Breadcrumbs throughout; keyboard and DnD support on web/desktop.

## 8) Telemetry, Rollout, Rollback
- Telemetry: success/error by operation, retries, conflicts, average wave time, cancels, subtree share time.
- Feature flag: remotely gate nested UI. If disabled, render flat view while leaving metadata intact. Provide “Flatten tree” tool.

 

## 11) Acceptance Criteria
- Scale: 10k albums / 50k files library — snappy tree render; bulk reparent completes with progress; no UI stalls.
- Consistency: two devices converge within one pull; conflict banner functions as intended.
- Watch folder: rename recognized as reparent; no duplicate album creation.
- Subtree share: completes for 1k descendants with resumability and correct ACLs.
- Public nested link: the viewer renders a nested tree using the manifest and can navigate to children; revocation/rotation flows update visibility as expected. Older viewers display the parent album only.

## 12) Test Plan
- Unit: tree builder, cycle detection, breadcrumbs, batching utilities, conflict decisions.
- Integration: create/move/un‑nest; cascade hide/archive/trash; watch‑folder chain; export breadcrumbs; subtree share.
- E2E/load: simulate 10k/50k; verify chunking, backoff, progress, resumability.
- Public viewer: manifest decrypt/parse, nested navigation, child switch, device‑limit/expiry behavior, backward compatibility (manifest ignored).
- Recovery: interrupt long jobs; ensure resume works and final state matches intent.

## 13) Risks & Mitigations
- Partial failure in long batches → resumable queue, per‑wave commit, clear summary and retry.
- User confusion on delete semantics → clear default (reparent to root), confirm cascade, undo window.
- Collaborator visibility mismatch → pre‑flight warning, optional cascade visibility updates.
- Unexpected server rate limits → backoff + smaller waves; telemetry alerting.
- Nested public links across large subtrees → warn about device limits, allow depth limits, provide “disable all child links” bulk toggle and resumable rotation.

## 14) Timeline & Ownership
- Phase 1 (4–6 weeks)
  - Week 1–2: Tree selectors, setParent helper, validators, basic move/create UI, job queue + progress.
  - Week 3–4: Cascade actions, watch/import tree, export breadcrumbs, subtree share wizard.
  - Week 5–6: Load/E2E hardening, telemetry, feature flag, docs.

## 15) Conclusion
We will ship nested albums now via a client‑first, E2EE design that stores only `parentID` in public magic metadata and builds the tree on clients. This satisfies full feature coverage, keeps server untouched, and scales with chunked updates and resumable jobs. This path balances privacy, simplicity, performance, and maintainability.
