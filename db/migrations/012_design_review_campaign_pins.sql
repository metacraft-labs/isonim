-- REV-M5 follow-up (2026-10-10) — campaigns are pinned like captures:
-- a workspace pin for the campaign's start and one for every round.
--
-- Until this migration ``campaigns.manifest_hash`` held whatever the client
-- sent; the CLI always sent the placeholder ``'local'``, so no campaign ever
-- recorded the source state it ran against.  From here on:
--
--   * ``start_campaign`` only accepts a *recorded* workspace pin
--     (``wslock-v1:sha256:<hex>``, stored by ``record_workspace_pin`` —
--     migration 011).  That pin becomes ``campaigns.manifest_hash`` when the
--     row is created: the campaign's start pin.  Reopening a terminal row
--     (migration 009) leaves the start pin alone.
--   * Every round — every ``POST /api/campaign/start`` turn, the first one
--     included — is opened with ``begin_campaign_round``, which stores the
--     round's own pin in ``design_review.campaign_rounds`` and appends a
--     ``round_started`` event.  The first round's pin is the start pin.
--   * The pins are taken exactly as a capture takes its pin
--     (``isonim-review`` CLI: clean-tree gate + ``captureWorkspacePin`` over
--     the same reprobuild observation), so they only ever name published
--     revisions.  A workspace that cannot be pinned refuses the campaign
--     start / the round; nothing records an "unpinned" round.
--
-- Existing rows are NOT rewritten.  A pre-012 ``manifest_hash`` ('local'
-- or a test string) stays as it is and reads as *legacy, unpinned*
-- (``campaign_pin.campaignPinState``); its rounds have no
-- ``campaign_rounds`` rows.  Such a campaign still loads, lists, fetches,
-- transitions and restarts; a round started after this migration is
-- pinned and numbered after the rounds the legacy campaign already
-- completed.  No CHECK is added to ``campaigns.manifest_hash``: a CHECK
-- would be re-evaluated on every UPDATE of a legacy row and break its
-- status transitions.

\set ON_ERROR_STOP on

-- ==========================================================================
-- design_review.campaign_rounds — one row per campaign round, with the
-- round's workspace pin.  The FK to workspace_pins makes it impossible to
-- reference a pin whose record was never stored.
-- ==========================================================================
CREATE TABLE design_review.campaign_rounds (
  campaign_id    UUID NOT NULL REFERENCES design_review.campaigns(campaign_id),
  round          INT  NOT NULL CHECK (round > 0),
  workspace_pin  TEXT NOT NULL REFERENCES design_review.workspace_pins(pin),
  started_by     TEXT NOT NULL,
  started_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY (campaign_id, round)
);

GRANT ALL PRIVILEGES ON TABLE design_review.campaign_rounds TO design_review_migrator;

-- ==========================================================================
-- start_campaign — migration 009's routine plus the pin guard.
-- ==========================================================================
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
  IF p_manifest_hash !~ '^wslock-v1:sha256:[0-9a-f]{64}$' THEN
    RAISE EXCEPTION
      'start_campaign: p_manifest_hash must be a workspace pin (wslock-v1:sha256:<hex>), got %',
      p_manifest_hash;
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM design_review.workspace_pins WHERE pin = p_manifest_hash)
  THEN
    RAISE EXCEPTION
      'start_campaign: workspace pin % is not recorded (call record_workspace_pin first)',
      p_manifest_hash;
  END IF;
  IF p_agent_backend IS NULL OR p_agent_backend = '' THEN
    RAISE EXCEPTION 'start_campaign: p_agent_backend must be a non-empty string';
  END IF;
  IF p_started_by IS NULL OR p_started_by = '' THEN
    RAISE EXCEPTION 'start_campaign: p_started_by must be a non-empty string';
  END IF;

  SELECT campaign_id, status
    INTO v_campaign_id, v_previous_status
    FROM design_review.campaigns
    WHERE doc_path = p_doc_path AND doc_sha = p_doc_sha
    FOR UPDATE;

  IF v_campaign_id IS NULL THEN
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
    -- Reopen for a fresh turn (migration 009).  ``manifest_hash`` is the
    -- campaign's start pin and is never overwritten; the new turn's pin is
    -- recorded by ``begin_campaign_round``.
    UPDATE design_review.campaigns
      SET status         = 'active',
          status_reason  = NULL,
          finished_at    = NULL,
          agent_backend  = p_agent_backend,
          agent_model    = p_agent_model
      WHERE campaign_id = v_campaign_id;
    v_was_terminal := TRUE;
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

-- ==========================================================================
-- begin_campaign_round — open the next round of a campaign against a
-- recorded workspace pin.  Returns the round number: one past the highest
-- round already recorded *or* already completed (``round_complete``
-- events), so a legacy campaign whose earlier rounds have no pins keeps
-- counting where it left off.  Audit: a ``round_started`` campaign event.
-- ==========================================================================
CREATE OR REPLACE FUNCTION design_review.begin_campaign_round(
  p_campaign_id   UUID,
  p_workspace_pin TEXT,
  p_started_by    TEXT
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_round INT;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'begin_campaign_round: p_campaign_id must not be NULL';
  END IF;
  IF p_workspace_pin IS NULL OR p_workspace_pin = '' THEN
    RAISE EXCEPTION 'begin_campaign_round: p_workspace_pin must be a non-empty string';
  END IF;
  IF p_started_by IS NULL OR p_started_by = '' THEN
    RAISE EXCEPTION 'begin_campaign_round: p_started_by must be a non-empty string';
  END IF;
  -- Serialise rounds of one campaign so two turns cannot take one number.
  PERFORM 1 FROM design_review.campaigns
    WHERE campaign_id = p_campaign_id
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'begin_campaign_round: campaign % does not exist', p_campaign_id;
  END IF;
  IF NOT EXISTS (
       SELECT 1 FROM design_review.workspace_pins WHERE pin = p_workspace_pin)
  THEN
    RAISE EXCEPTION
      'begin_campaign_round: workspace pin % is not recorded (call record_workspace_pin first)',
      p_workspace_pin;
  END IF;

  SELECT GREATEST(
           COALESCE((SELECT max(r.round) FROM design_review.campaign_rounds r
                     WHERE r.campaign_id = p_campaign_id), 0),
           (SELECT count(*) FROM design_review.campaign_events e
             WHERE e.campaign_id = p_campaign_id
               AND e.event_kind = 'round_complete')::INT
         ) + 1
    INTO v_round;

  INSERT INTO design_review.campaign_rounds (
    campaign_id, round, workspace_pin, started_by
  ) VALUES (
    p_campaign_id, v_round, p_workspace_pin, p_started_by
  );
  INSERT INTO design_review.campaign_events (campaign_id, event_kind, payload)
  VALUES (
    p_campaign_id, 'round_started',
    jsonb_build_object('round',         v_round,
                       'workspace_pin', p_workspace_pin,
                       'started_by',    p_started_by)
  );
  RETURN v_round;
END;
$$;

-- ==========================================================================
-- fetch_campaign — migration 006's routine plus the campaign's provenance:
-- ``rounds`` (every recorded round with its pin, oldest first) and
-- ``rounds_completed`` (``round_complete`` events, pinned or not).  A
-- legacy campaign returns its stored ``manifest_hash`` and ``rounds: []``.
-- ==========================================================================
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
    'rounds', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'round',         r.round,
        'workspace_pin', r.workspace_pin,
        'lock_record',   w.lock_record,
        'started_by',    r.started_by,
        'started_at',    r.started_at
      ) ORDER BY r.round)
      FROM design_review.campaign_rounds r
      JOIN design_review.workspace_pins w ON w.pin = r.workspace_pin
      WHERE r.campaign_id = c.campaign_id
    ), '[]'::jsonb),
    'rounds_completed', (
      SELECT count(*) FROM design_review.campaign_events e
      WHERE e.campaign_id = c.campaign_id AND e.event_kind = 'round_complete'
    ),
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

GRANT EXECUTE ON FUNCTION
  design_review.begin_campaign_round(UUID, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.start_campaign(TEXT, TEXT, TEXT[], REAL, INT, TEXT, TEXT, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION
  design_review.fetch_campaign(UUID, INT)
  TO design_review_app;
