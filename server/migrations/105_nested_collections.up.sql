-- Add nested collections support
-- Adds parent-child relationships and hierarchy paths to collections

-- Add parent_collection_id and hierarchy_path columns to collections table
ALTER TABLE collections ADD COLUMN parent_collection_id BIGINT;
ALTER TABLE collections ADD COLUMN hierarchy_path TEXT;

-- Performance indexes for nested collections
CREATE INDEX idx_collections_parent ON collections(parent_collection_id);
CREATE INDEX idx_collections_path ON collections(hierarchy_path);

-- Foreign key constraint for parent collections
-- Using SET NULL to make orphans become root-level when parent is deleted
ALTER TABLE collections ADD CONSTRAINT fk_parent 
  FOREIGN KEY (parent_collection_id) REFERENCES collections(collection_id) 
  ON DELETE SET NULL;

-- Add scope column to collection_shares for granular sharing
ALTER TABLE collection_shares ADD COLUMN scope VARCHAR(20) DEFAULT 'direct_only';

-- Add a check constraint for valid scope values
ALTER TABLE collection_shares ADD CONSTRAINT chk_collection_share_scope 
  CHECK (scope IN ('direct_only', 'include_sub_collections'));