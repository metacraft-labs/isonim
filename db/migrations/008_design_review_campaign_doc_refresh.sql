-- CMP-M4 — campaign doc-refresh routine.
--
-- The operator-intervention surface lets the user (or AI Assistant) edit a
-- campaign doc on disk between rounds; the daemon picks up the new content
-- at the next tick boundary.  This migration adds the SECURITY-DEFINER
-- routine ``design_review.update_campaign_doc_sha`` so the app role can
-- write the new content hash without direct UPDATE rights on the base
-- table.
--
-- The routine deliberately does NOT mutate ``doc_path`` — once a campaign
-- is rooted at a path that path is its operating contract.  Only the
-- hashed-content fingerprint moves.

\set ON_ERROR_STOP on

-- ===========================================================================
-- update_campaign_doc_sha — bump the recorded doc_sha for ``p_campaign_id``.
-- Returns the previous ``doc_sha`` so callers (the /refresh-doc handler in
-- particular) can decide whether to emit a ``doc_refreshed`` event.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.update_campaign_doc_sha(
  p_campaign_id UUID,
  p_new_sha     TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_old_sha TEXT;
  v_exists  BOOLEAN;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'update_campaign_doc_sha: p_campaign_id must not be NULL';
  END IF;
  IF p_new_sha IS NULL OR p_new_sha = '' THEN
    RAISE EXCEPTION 'update_campaign_doc_sha: p_new_sha must be a non-empty string';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM design_review.campaigns WHERE campaign_id = p_campaign_id
  ) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'update_campaign_doc_sha: campaign % does not exist', p_campaign_id;
  END IF;

  SELECT doc_sha INTO v_old_sha
    FROM design_review.campaigns
    WHERE campaign_id = p_campaign_id
    FOR UPDATE;

  UPDATE design_review.campaigns
    SET doc_sha = p_new_sha
    WHERE campaign_id = p_campaign_id;

  RETURN v_old_sha;
END;
$$;

GRANT EXECUTE ON FUNCTION
  design_review.update_campaign_doc_sha(UUID, TEXT)
  TO design_review_app;
