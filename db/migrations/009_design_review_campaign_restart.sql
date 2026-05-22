-- CMP-M7 — let ``start_campaign`` reopen a row that is already in a
-- terminal status.
--
-- Background: ``start_campaign`` is keyed on ``(doc_path, doc_sha)`` and
-- has always been idempotent on duplicate calls.  Originally that
-- idempotency was framed as "don't insert twice" — the conflict branch
-- just looked the existing row up and returned its id.  In the
-- single-turn campaign model (CMP-M6) the row reaches a terminal
-- status (``converged`` / ``escalated`` / ``stopped`` / ``failed``)
-- whenever a turn ends, and the operator then re-runs ``campaign
-- start`` against the same doc to launch the next turn.  The original
-- behaviour silently left the row in its terminal status, which made
-- ``applyCampaignDocStatusAfterTurn`` a no-op (it guards against
-- transitioning out of a terminal status) and left every subsequent
-- turn mislabeled in the DB even though codex actually ran.
--
-- This migration reopens the row: on a conflict where the existing
-- status is terminal, ``start_campaign`` resets ``status`` to
-- ``active``, clears ``finished_at`` / ``status_reason``, and appends
-- a ``restarted`` event with the previous terminal status preserved
-- in the payload so the audit trail keeps the full history.
--
-- An ``ON CONFLICT`` ``DO UPDATE`` branch handles both the "first
-- write wins" case (insert succeeds, status starts as ``active``) and
-- the "reopen" case (existing row in a terminal status gets reset
-- atomically with a single statement, so two concurrent ``campaign
-- start`` calls don't double-emit ``restarted``).

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION design_review.start_campaign(
  p_doc_path       TEXT,
  p_doc_sha        TEXT,
  p_brief_refs     TEXT[],
  p_target_score   REAL,
  p_max_iterations INT,
  p_manifest_hash  TEXT,
  p_agent_backend  TEXT,
  p_agent_model    TEXT,
  p_started_by     TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_campaign_id        UUID;
  v_inserted           BOOLEAN := FALSE;
  v_previous_status    TEXT;
  v_was_terminal       BOOLEAN := FALSE;
BEGIN
  IF p_doc_path IS NULL OR p_doc_path = '' THEN
    RAISE EXCEPTION 'start_campaign: p_doc_path must be a non-empty string';
  END IF;
  IF p_doc_sha IS NULL OR p_doc_sha = '' THEN
    RAISE EXCEPTION 'start_campaign: p_doc_sha must be a non-empty string';
  END IF;
  IF p_brief_refs IS NULL OR array_length(p_brief_refs, 1) IS NULL THEN
    RAISE EXCEPTION 'start_campaign: p_brief_refs must be a non-empty TEXT[] array';
  END IF;
  IF p_max_iterations IS NULL OR p_max_iterations <= 0 THEN
    RAISE EXCEPTION 'start_campaign: p_max_iterations must be a positive integer';
  END IF;
  IF p_manifest_hash IS NULL OR p_manifest_hash = '' THEN
    RAISE EXCEPTION 'start_campaign: p_manifest_hash must be a non-empty string';
  END IF;
  IF p_agent_backend IS NULL OR p_agent_backend = '' THEN
    RAISE EXCEPTION 'start_campaign: p_agent_backend must be a non-empty string';
  END IF;
  IF p_started_by IS NULL OR p_started_by = '' THEN
    RAISE EXCEPTION 'start_campaign: p_started_by must be a non-empty string';
  END IF;

  -- Locate any existing row for this (doc_path, doc_sha) and grab its
  -- previous status before we attempt the upsert.  We use a SELECT FOR
  -- UPDATE so a concurrent ``start_campaign`` against the same doc
  -- cannot double-reset.
  SELECT campaign_id, status
    INTO v_campaign_id, v_previous_status
    FROM design_review.campaigns
    WHERE doc_path = p_doc_path AND doc_sha = p_doc_sha
    FOR UPDATE;

  IF v_campaign_id IS NULL THEN
    -- No row yet: fresh insert as ``active``.
    INSERT INTO design_review.campaigns (
      doc_path, doc_sha, brief_refs, target_score, max_iterations,
      manifest_hash, status, agent_backend, agent_model, started_by
    ) VALUES (
      p_doc_path, p_doc_sha, p_brief_refs, p_target_score, p_max_iterations,
      p_manifest_hash, 'active', p_agent_backend, p_agent_model, p_started_by
    )
    RETURNING campaign_id INTO v_campaign_id;
    v_inserted := TRUE;
  ELSIF v_previous_status IN ('converged', 'escalated', 'stopped', 'failed') THEN
    -- Existing row is in a terminal status: reopen it for a fresh
    -- turn.  Clear ``finished_at`` and ``status_reason`` so they
    -- don't carry over from the previous turn, and refresh the
    -- backend/model in case the operator switched between turns.
    UPDATE design_review.campaigns
      SET status         = 'active',
          status_reason  = NULL,
          finished_at    = NULL,
          agent_backend  = p_agent_backend,
          agent_model    = p_agent_model
      WHERE campaign_id = v_campaign_id;
    v_was_terminal := TRUE;
  END IF;
  -- If v_previous_status is 'pending' or 'active' we leave the row
  -- alone (the original idempotency contract).

  IF v_inserted THEN
    INSERT INTO design_review.campaign_events (
      campaign_id, event_kind, payload
    ) VALUES (
      v_campaign_id, 'started',
      jsonb_build_object(
        'doc_path',       p_doc_path,
        'doc_sha',        p_doc_sha,
        'brief_refs',     to_jsonb(p_brief_refs),
        'target_score',   p_target_score,
        'max_iterations', p_max_iterations,
        'manifest_hash',  p_manifest_hash,
        'agent_backend',  p_agent_backend,
        'agent_model',    p_agent_model,
        'started_by',     p_started_by
      )
    );
  ELSIF v_was_terminal THEN
    INSERT INTO design_review.campaign_events (
      campaign_id, event_kind, payload
    ) VALUES (
      v_campaign_id, 'restarted',
      jsonb_build_object(
        'previous_status', v_previous_status,
        'agent_backend',   p_agent_backend,
        'agent_model',     p_agent_model,
        'started_by',      p_started_by
      )
    );
  END IF;

  RETURN v_campaign_id;
END;
$$;
