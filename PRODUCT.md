# Nested Albums – Product Spec (Short)

## Overview
We are adding “Nested Albums” so users can organize albums in a hierarchy (e.g., 2025 → 12 → 25 → Christmas). This is a full product feature (not an MVP) and works consistently across Web, Desktop, and Mobile with end‑to‑end encryption preserved.

Key goals
- Intuitive hierarchy and navigation
- Consistent behavior across platforms and sharing scenarios
- Backward compatible with older clients
- Minimal server changes initially; evolve only if needed


## What’s Changing
- Album structure: Albums can have a parent album. Users can create sub‑albums and move albums under another album.
- Navigation & UI: We introduce a collapsible album list, breadcrumbs, and “Move to…” pickers that understand the tree.
- Bulk actions: Hide/Archive/Trash/Share support subtree operations.
- Import/Watch/Export: Users can mirror filesystem folder trees into nested albums and export albums into nested folders.


## Data Model (Minimal Additions)
- New encrypted album metadata field (client‑side, E2EE)
  - `parentID` (number): ID of the parent album. Omitted or 0 means “root”.
- No other new fields in Phase 1. Old clients ignore this field and continue to show a flat list.


## APIs
- Phase 1: No new server APIs. We reuse existing album/file APIs and the existing “magic metadata” update flow.
  - Share with users: reuse share/unshare endpoints to apply share across a subtree when the user enables “Include sub‑albums”.
  - Public albums (links): reuse create/update/disable public link endpoint per album; a parent’s link can reference child links client‑side (see “Public Albums” below).
- Phase 2 (optional, future): Add small batch endpoints for atomic multi‑reparent and subtree share if telemetry shows it’s needed.
  - `PATCH /collections/parent:batch` (atomic optional, CAS)
  - `POST /collections/share:batch` (per‑album sealed keys)
  - `POST /collections/ops:batch` (atomic multi‑operation) to bundle “create child + update child’s parentID + ensure child public link + refresh parent manifest” (or analogous move/delete flows) as a single transaction. Gated by feature flag; clients fall back to Phase 1 resumable jobs when disabled.
- Phase 3 (optional, future): Minimal server validation (single `parent_id` and a simple `PATCH /collections/{id}/parent` with CAS), only if consistency issues appear at scale.


## Backward Compatibility
- Old apps: See a flat album list. No data loss. They’ll keep working as before.
- Feature flag: We can switch off nested UI remotely and fall back to a flat view without changing data at rest.
- Public links: Links remain album‑scoped and do not automatically expose child albums.


## UX & Behavior (Highlights)
- Create sub‑album
  - Context menu action “New sub‑album…” on any album.
  - Uses current album as parent.
- Move album
  - Drag & drop, or “Move album…” action opens a tree chooser.
  - Validations: prevents cycles, depth beyond a safe cap (10), and disallows special albums (Favorites/Uncategorized) as parent/child.
- Add/Move files to sub‑album
  - “Add to album…” and “Move to album…” selectors support nested destinations with breadcrumbs.
- Hide / Archive
  - Per‑album, same semantics as today.
  - New option “Apply to sub‑albums” runs a safe, batched update with progress.
- Trash / Delete
  - Default: Reparent children to root, then delete selected album (safer, fewer surprises).
  - Option: “Delete subtree” (deepest‑first, with confirmation and undo window).
- Share
  - Share a single album as today.
  - New “Include sub‑albums” toggle to apply sharing to a whole subtree. The client seals each child’s album key to the sharee and calls existing share API per child with progress + rollback.
  - Optional: “Remove share from descendants” when unsharing.
  - Reliability: subtree share runs as a resumable background job. If the app is closed or crashes, it resumes on next launch and continues safely (idempotent calls). For organizations requiring strict atomicity across many shares, enabling the Phase 2 atomic endpoints runs the whole bundle in one server transaction.
- Navigation
  - Collapsible album tree (desktop/web), nested stacks (mobile), and breadcrumbs at the top of album views.
- Import / Watch folders
  - New “Tree” mode to map nested directories to nested albums. Creates parent chains automatically. Renames on disk map to reparent in Ente.
- Export
  - Default export creates nested folders based on the album breadcrumbs. Optional “flatten” keeps current behavior.

### Public Albums (Public Links)
- “Include sub‑albums” option when creating a public link for an album.
- Behavior: the client creates/uses a normal public link for the parent and for each included child album. The parent album’s encrypted public metadata stores a list of its child link tokens + child keys (a “nested link manifest”). The public viewer (albums app) reads this manifest (when present) and renders a nested tree in the sidebar.
- Revocation & rotation: “Disable nested link” disables parent link and optionally all child links; “Rotate nested link” regenerates tokens for the selected scope.
- Limits & notes: device/expiry settings apply per album link; we warn when the subtree is large or settings are restrictive.

Auto‑refresh (when children change)
- If the parent has a nested public link, changes to its immediate children (add/remove/move) automatically refresh the manifest in the background.
- Consistency: refresh is atomic at the manifest level—viewers either see the previous manifest or the new one, never a partial mix. Child link enable/disable happens around the manifest write to keep the viewer consistent. If the app is closed mid‑refresh, no partial change is visible; the refresh resumes on next launch.
 - Strict atomicity (optional): with Phase 2 atomic endpoints, “create child + ensure child link + refresh parent manifest” can be executed as a single transaction for an all‑or‑nothing outcome.


## Reliability & Scale
- Large changes (e.g., reorganizing hundreds of albums) run as a resumable job with progress and pause/resume.
- Chunking and backoff protect against server limits; users always see progress and a partial‑summary if something needs a retry.
- Conflict handling: If an album was moved on another device, we show a small banner with “Reapply” or “Accept remote”.


## Edge Cases & Rules
- Special albums: Favorites and Uncategorized cannot be a parent or child.
- Sharing: Parent does not imply access to children—only explicitly shared albums appear for sharees. “Share descendants…” is a convenience, not an implicit rule.
- Public links: Always album‑scoped; children need their own links if desired.
  - With the nested option, the parent’s link references children client‑side; older viewers that don’t understand the nested list will still display the parent album only (backward compatible).


## Success Measures
- Organization actions complete successfully at scale (10k albums) with high success rate.
- Users report better discoverability and fewer albums at root.
- No increase in data loss or support tickets for sharing/archiving/trashing.


## Timeline (High‑level)
- Phase 1 (4–6 weeks): Client‑first nested albums (full coverage, no server changes).
- Phase 2 (2–3 weeks, optional): Minimal batch endpoints for atomicity if metrics justify.
- Phase 3 (2–3 weeks, optional): Minimal server validation only if needed.


## Summary
We are shipping nested albums by storing a single encrypted `parentID` in album metadata and building the tree on clients. This keeps the experience fast, private, and consistent across platforms and sharing. We avoid server changes initially and add targeted APIs later only if telemetry shows they are needed.
