-- CMP-M2 — campaign storage routines.
--
-- Stored-procedure layer for design_review.campaigns + campaign_events.
-- Mirrors the REV-M3 boundary: every state-mutating routine is
-- SECURITY DEFINER, validates non-null / non-empty inputs, and inserts a
-- ``campaign_events`` row in the same transaction as the state change.
--
-- Read-only routines (list, fetch, recent_events) are also SECURITY
-- DEFINER so the app role doesn't need direct SELECT on the base tables.
--
-- Idempotency: ``start_campaign`` is idempotent on (doc_path, doc_sha) —
-- two CLI invocations against the same unchanged campaign doc return the
-- same row (and do NOT emit a second 'started' event).

\set ON_ERROR_STOP on

-- ===========================================================================
-- 1. start_campaign — INSERT a campaign row + 'started' event.
-- Idempotent on (doc_path, doc_sha).  Returns the campaign_id.
-- ===========================================================================
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
  v_campaign_id UUID;
  v_inserted    BOOLEAN := FALSE;
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

  INSERT INTO design_review.campaigns (
    doc_path, doc_sha, brief_refs, target_score, max_iterations,
    manifest_hash, status, agent_backend, agent_model, started_by
  ) VALUES (
    p_doc_path, p_doc_sha, p_brief_refs, p_target_score, p_max_iterations,
    p_manifest_hash, 'active', p_agent_backend, p_agent_model, p_started_by
  )
  ON CONFLICT (doc_path, doc_sha) DO NOTHING
  RETURNING campaign_id INTO v_campaign_id;

  IF v_campaign_id IS NOT NULL THEN
    v_inserted := TRUE;
  ELSE
    SELECT campaign_id INTO v_campaign_id
    FROM design_review.campaigns
    WHERE doc_path = p_doc_path AND doc_sha = p_doc_sha;
  END IF;

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
  END IF;

  RETURN v_campaign_id;
END;
$$;

-- ===========================================================================
-- 2. record_campaign_event — append one row to campaign_events.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.record_campaign_event(
  p_campaign_id  UUID,
  p_event_kind   TEXT,
  p_payload      JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_event_id UUID;
  v_exists   BOOLEAN;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'record_campaign_event: p_campaign_id must not be NULL';
  END IF;
  IF p_event_kind IS NULL OR p_event_kind = '' THEN
    RAISE EXCEPTION 'record_campaign_event: p_event_kind must be a non-empty string';
  END IF;
  SELECT EXISTS (SELECT 1 FROM design_review.campaigns WHERE campaign_id = p_campaign_id)
    INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'record_campaign_event: campaign % does not exist', p_campaign_id;
  END IF;

  INSERT INTO design_review.campaign_events (campaign_id, event_kind, payload)
  VALUES (p_campaign_id, p_event_kind, COALESCE(p_payload, '{}'::jsonb))
  RETURNING event_id INTO v_event_id;
  RETURN v_event_id;
END;
$$;

-- ===========================================================================
-- 3. update_campaign_session — bind the ACP session id post-startup.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.update_campaign_session(
  p_campaign_id    UUID,
  p_acp_session_id TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_exists BOOLEAN;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'update_campaign_session: p_campaign_id must not be NULL';
  END IF;
  IF p_acp_session_id IS NULL OR p_acp_session_id = '' THEN
    RAISE EXCEPTION 'update_campaign_session: p_acp_session_id must be a non-empty string';
  END IF;
  SELECT EXISTS (SELECT 1 FROM design_review.campaigns WHERE campaign_id = p_campaign_id)
    INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'update_campaign_session: campaign % does not exist', p_campaign_id;
  END IF;
  UPDATE design_review.campaigns
    SET acp_session_id = p_acp_session_id
    WHERE campaign_id = p_campaign_id;
END;
$$;

-- ===========================================================================
-- 4. transition_campaign — drive the status enum forward.
-- Allowed transitions:
--     pending   → active | stopped | failed
--     active    → converged | escalated | stopped | failed
-- Terminal states (converged / escalated / stopped / failed) are sticky.
-- Sets finished_at on terminal transitions.  Records 'stopped' / 'finished'
-- / 'escalation' events as appropriate.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.transition_campaign(
  p_campaign_id UUID,
  p_new_status  TEXT,
  p_reason      TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_current_status TEXT;
  v_terminal       BOOLEAN := FALSE;
  v_event_kind     TEXT;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'transition_campaign: p_campaign_id must not be NULL';
  END IF;
  IF p_new_status IS NULL OR p_new_status = '' THEN
    RAISE EXCEPTION 'transition_campaign: p_new_status must be a non-empty string';
  END IF;
  IF p_new_status NOT IN
        ('pending', 'active', 'converged', 'escalated', 'stopped', 'failed') THEN
    RAISE EXCEPTION 'transition_campaign: unknown status %', p_new_status;
  END IF;

  SELECT status INTO v_current_status
    FROM design_review.campaigns
    WHERE campaign_id = p_campaign_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'transition_campaign: campaign % does not exist', p_campaign_id;
  END IF;

  IF v_current_status IN ('converged', 'escalated', 'stopped', 'failed') THEN
    RAISE EXCEPTION 'transition_campaign: campaign % is in terminal status %',
      p_campaign_id, v_current_status;
  END IF;

  IF p_new_status IN ('converged', 'escalated', 'stopped', 'failed') THEN
    v_terminal := TRUE;
  END IF;

  UPDATE design_review.campaigns
    SET status        = p_new_status,
        status_reason = COALESCE(p_reason, status_reason),
        finished_at   = CASE WHEN v_terminal THEN NOW() ELSE finished_at END
    WHERE campaign_id = p_campaign_id;

  -- Mirror the transition into the event log so the audit trail captures
  -- every status change without the caller having to issue two routine
  -- invocations.
  v_event_kind := CASE p_new_status
    WHEN 'stopped'   THEN 'stopped'
    WHEN 'escalated' THEN 'escalation'
    WHEN 'converged' THEN 'finished'
    WHEN 'failed'    THEN 'finished'
    ELSE 'note'
  END;
  INSERT INTO design_review.campaign_events (campaign_id, event_kind, payload)
  VALUES (
    p_campaign_id, v_event_kind,
    jsonb_build_object('status', p_new_status, 'reason', p_reason)
  );
END;
$$;

-- ===========================================================================
-- 5. list_campaigns — paginated, optionally status-filtered.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.list_campaigns(
  p_status TEXT,
  p_limit  INT,
  p_offset INT
) RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_limit  INT := COALESCE(p_limit, 50);
  v_offset INT := COALESCE(p_offset, 0);
BEGIN
  IF v_limit < 0 OR v_limit > 1000 THEN
    RAISE EXCEPTION 'list_campaigns: p_limit out of range (0..1000)';
  END IF;
  IF v_offset < 0 THEN
    RAISE EXCEPTION 'list_campaigns: p_offset must be non-negative';
  END IF;

  RETURN QUERY
    SELECT jsonb_build_object(
      'campaign_id',     c.campaign_id,
      'doc_path',        c.doc_path,
      'doc_sha',         c.doc_sha,
      'brief_refs',      to_jsonb(c.brief_refs),
      'target_score',    c.target_score,
      'max_iterations',  c.max_iterations,
      'manifest_hash',   c.manifest_hash,
      'status',          c.status,
      'status_reason',   c.status_reason,
      'acp_session_id',  c.acp_session_id,
      'agent_backend',   c.agent_backend,
      'agent_model',     c.agent_model,
      'started_by',      c.started_by,
      'started_at',      c.started_at,
      'finished_at',     c.finished_at
    )
    FROM design_review.campaigns c
    WHERE (p_status IS NULL OR p_status = '' OR c.status = p_status)
    ORDER BY c.started_at DESC
    LIMIT v_limit OFFSET v_offset;
END;
$$;

-- ===========================================================================
-- 6. fetch_campaign — full row + the most recent K events.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.fetch_campaign(
  p_campaign_id UUID,
  p_event_limit INT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_limit  INT := COALESCE(p_event_limit, 20);
  v_result JSONB;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'fetch_campaign: p_campaign_id must not be NULL';
  END IF;
  IF v_limit < 0 OR v_limit > 1000 THEN
    RAISE EXCEPTION 'fetch_campaign: p_event_limit out of range (0..1000)';
  END IF;

  SELECT jsonb_build_object(
    'campaign_id',     c.campaign_id,
    'doc_path',        c.doc_path,
    'doc_sha',         c.doc_sha,
    'brief_refs',      to_jsonb(c.brief_refs),
    'target_score',    c.target_score,
    'max_iterations',  c.max_iterations,
    'manifest_hash',   c.manifest_hash,
    'status',          c.status,
    'status_reason',   c.status_reason,
    'acp_session_id',  c.acp_session_id,
    'agent_backend',   c.agent_backend,
    'agent_model',     c.agent_model,
    'started_by',      c.started_by,
    'started_at',      c.started_at,
    'finished_at',     c.finished_at,
    'events', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'event_id',     e.event_id,
        'occurred_at',  e.occurred_at,
        'event_kind',   e.event_kind,
        'payload',      e.payload,
        'acknowledged', e.acknowledged
      ) ORDER BY e.occurred_at DESC)
      FROM (
        SELECT *
        FROM design_review.campaign_events
        WHERE campaign_id = c.campaign_id
        ORDER BY occurred_at DESC
        LIMIT v_limit
      ) e
    ), '[]'::jsonb)
  ) INTO v_result
  FROM design_review.campaigns c
  WHERE c.campaign_id = p_campaign_id;

  IF v_result IS NULL THEN
    RAISE EXCEPTION 'fetch_campaign: campaign % does not exist', p_campaign_id;
  END IF;
  RETURN v_result;
END;
$$;

-- ===========================================================================
-- 7. recent_campaign_events — paginated event-log read.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.recent_campaign_events(
  p_campaign_id UUID,
  p_since       TIMESTAMPTZ,
  p_limit       INT
) RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_limit INT := COALESCE(p_limit, 100);
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'recent_campaign_events: p_campaign_id must not be NULL';
  END IF;
  IF v_limit < 0 OR v_limit > 5000 THEN
    RAISE EXCEPTION 'recent_campaign_events: p_limit out of range (0..5000)';
  END IF;

  RETURN QUERY
    SELECT jsonb_build_object(
      'event_id',     e.event_id,
      'campaign_id',  e.campaign_id,
      'occurred_at',  e.occurred_at,
      'event_kind',   e.event_kind,
      'payload',      e.payload,
      'acknowledged', e.acknowledged
    )
    FROM design_review.campaign_events e
    WHERE e.campaign_id = p_campaign_id
      AND (p_since IS NULL OR e.occurred_at > p_since)
    ORDER BY e.occurred_at ASC
    LIMIT v_limit;
END;
$$;

-- ===========================================================================
-- 8. acknowledge_campaign_events — mark all events ≤ p_upto_event_id as ack.
-- Returns the number of rows updated.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.acknowledge_campaign_events(
  p_campaign_id     UUID,
  p_upto_event_id   UUID
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_anchor_ts TIMESTAMPTZ;
  v_count     INT := 0;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'acknowledge_campaign_events: p_campaign_id must not be NULL';
  END IF;
  IF p_upto_event_id IS NULL THEN
    RAISE EXCEPTION 'acknowledge_campaign_events: p_upto_event_id must not be NULL';
  END IF;
  SELECT occurred_at INTO v_anchor_ts
    FROM design_review.campaign_events
    WHERE event_id = p_upto_event_id AND campaign_id = p_campaign_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'acknowledge_campaign_events: anchor event % not found for campaign %',
      p_upto_event_id, p_campaign_id;
  END IF;
  WITH updated AS (
    UPDATE design_review.campaign_events
      SET acknowledged = TRUE
      WHERE campaign_id = p_campaign_id
        AND occurred_at <= v_anchor_ts
        AND acknowledged = FALSE
      RETURNING event_id
  )
  SELECT count(*) INTO v_count FROM updated;
  RETURN v_count;
END;
$$;

-- ---------------------------------------------------------------------------
-- EXECUTE grants — every top-level routine is callable by the app role.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
  design_review.start_campaign(TEXT, TEXT, TEXT[], REAL, INT, TEXT, TEXT, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.record_campaign_event(UUID, TEXT, JSONB)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.update_campaign_session(UUID, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.transition_campaign(UUID, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.list_campaigns(TEXT, INT, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.fetch_campaign(UUID, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.recent_campaign_events(UUID, TIMESTAMPTZ, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.acknowledge_campaign_events(UUID, UUID)
  TO design_review_app;
