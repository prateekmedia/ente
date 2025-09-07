-- Rollback nested collections support
-- Removes parent-child relationships and hierarchy paths from collections

-- Remove scope column from collection_shares
ALTER TABLE collection_shares DROP CONSTRAINT IF EXISTS chk_collection_share_scope;
ALTER TABLE collection_shares DROP COLUMN IF EXISTS scope;

-- Remove foreign key constraint and columns from collections
ALTER TABLE collections DROP CONSTRAINT IF EXISTS fk_parent;
DROP INDEX IF EXISTS idx_collections_parent;
DROP INDEX IF EXISTS idx_collections_path;
ALTER TABLE collections DROP COLUMN IF EXISTS parent_collection_id;
ALTER TABLE collections DROP COLUMN IF EXISTS hierarchy_path;