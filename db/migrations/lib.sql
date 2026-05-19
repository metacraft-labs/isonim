-- REV-M3 — shared routine helpers.  Applied as part of migration 002 via
-- ``\i lib.sql`` (NOT its own numbered migration so schema_migrations
-- stays clean).  Helpers live inside the ``design_review`` schema.

-- ---------------------------------------------------------------------------
-- design_review.audit_event_insert — every state-mutating routine calls
-- this so the audit row lives in the same transaction as the mutation it
-- describes.  Caller passes the actor identity, the event kind (e.g.
-- 'run.started'), and the contextual FKs.  ``payload`` is JSONB so
-- routine-specific extension data can ride along without schema churn.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION design_review.audit_event_insert(
  p_actor      TEXT,
  p_event_kind TEXT,
  p_run_id     UUID,
  p_report_id  UUID,
  p_layout_id  UUID,
  p_payload    JSONB
) RETURNS UUID
LANGUAGE plpgsql
AS $$
DECLARE
  v_event_id UUID;
BEGIN
  IF p_actor IS NULL OR p_actor = '' THEN
    RAISE EXCEPTION 'audit_event_insert: p_actor must be a non-empty string';
  END IF;
  IF p_event_kind IS NULL OR p_event_kind = '' THEN
    RAISE EXCEPTION 'audit_event_insert: p_event_kind must be a non-empty string';
  END IF;
  INSERT INTO design_review.audit_events (
    actor, event_kind, run_id, report_id, layout_id, payload
  ) VALUES (
    p_actor, p_event_kind, p_run_id, p_report_id, p_layout_id,
    COALESCE(p_payload, '{}'::jsonb)
  )
  RETURNING event_id INTO v_event_id;
  RETURN v_event_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- design_review.guard_run_status — assert ``runs.run_id`` exists and is in
-- one of ``p_allowed_statuses``.  Used by every routine that mutates a run
-- to make the lifecycle invariants explicit (capturing → capture_complete
-- only via finish_captures, etc.).  Returns the row's current status so
-- callers can branch on it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION design_review.guard_run_status(
  p_run_id           UUID,
  p_allowed_statuses TEXT[]
) RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  v_status TEXT;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'guard_run_status: p_run_id must not be NULL';
  END IF;
  SELECT status INTO v_status
  FROM design_review.runs
  WHERE run_id = p_run_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'guard_run_status: run % does not exist', p_run_id;
  END IF;
  IF p_allowed_statuses IS NOT NULL AND array_length(p_allowed_statuses, 1) IS NOT NULL THEN
    IF NOT (v_status = ANY (p_allowed_statuses)) THEN
      RAISE EXCEPTION
        'guard_run_status: run % in status % not in allowed set %',
        p_run_id, v_status, p_allowed_statuses;
    END IF;
  END IF;
  RETURN v_status;
END;
$$;
