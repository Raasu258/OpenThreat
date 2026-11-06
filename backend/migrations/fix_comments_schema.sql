-- Migration: Fix comments table schema to match model
-- Issue: Model expects cve_id (string) but database has vulnerability_id (integer)
-- Date: 2025-10-19
--
-- Only applies to legacy databases that still have comments.vulnerability_id.
-- Databases created via Alembic (007_add_comments_tables) already have the
-- target schema, and running the steps there fails (no vulnerability_id,
-- no "edited" column). The guard makes this file a no-op in that case.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'comments' AND column_name = 'vulnerability_id'
    ) THEN
        RAISE NOTICE 'fix_comments_schema: comments already uses cve_id, skipping';
        RETURN;
    END IF;

    -- Step 1: Add the cve_id column
    ALTER TABLE comments ADD COLUMN IF NOT EXISTS cve_id VARCHAR(50);

    -- Step 2: Populate cve_id from vulnerability_id
    UPDATE comments c
    SET cve_id = v.cve_id
    FROM vulnerabilities v
    WHERE c.vulnerability_id = v.id;

    -- Step 3: Make cve_id NOT NULL after data migration
    ALTER TABLE comments ALTER COLUMN cve_id SET NOT NULL;

    -- Step 4: Add foreign key constraint
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'comments_cve_id_fkey'
    ) THEN
        ALTER TABLE comments
        ADD CONSTRAINT comments_cve_id_fkey
        FOREIGN KEY (cve_id) REFERENCES vulnerabilities(cve_id);
    END IF;

    -- Step 5: Indexes on cve_id
    CREATE INDEX IF NOT EXISTS idx_comments_cve_id ON comments(cve_id);
    CREATE INDEX IF NOT EXISTS idx_comments_cve_created ON comments(cve_id, created_at);

    -- Step 6: Drop old indexes and constraints related to vulnerability_id
    DROP INDEX IF EXISTS idx_comments_vulnerability_created;
    DROP INDEX IF EXISTS ix_comments_vulnerability_id;
    ALTER TABLE comments DROP CONSTRAINT IF EXISTS comments_vulnerability_id_fkey;

    -- Step 7: Rename columns to match model
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'comments' AND column_name = 'edited'
    ) THEN
        ALTER TABLE comments RENAME COLUMN edited TO is_edited;
    END IF;

    -- Step 8: Add missing columns
    ALTER TABLE comments ADD COLUMN IF NOT EXISTS upvotes INTEGER DEFAULT 0 NOT NULL;
    ALTER TABLE comments ADD COLUMN IF NOT EXISTS downvotes INTEGER DEFAULT 0 NOT NULL;

    -- Step 9: Make vulnerability_id nullable (cve_id is used now)
    ALTER TABLE comments ALTER COLUMN vulnerability_id DROP NOT NULL;

    -- Step 10: comment_votes.updated_at
    ALTER TABLE comment_votes
        ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL;

    -- Step 11: comment_votes.vote_type VARCHAR -> INTEGER
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'comment_votes' AND column_name = 'vote_type'
          AND data_type <> 'integer'
    ) THEN
        ALTER TABLE comment_votes
        ALTER COLUMN vote_type TYPE INTEGER
        USING CASE
            WHEN vote_type = 'upvote' THEN 1
            WHEN vote_type = 'downvote' THEN -1
            ELSE vote_type::INTEGER
        END;
    END IF;
END $$;

-- Note: vulnerability_id is kept as a backup on legacy databases.
-- It can be dropped in a future migration after verifying everything works.
