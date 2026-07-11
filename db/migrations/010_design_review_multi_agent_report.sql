-- REV-M6 follow-up — let a second reviewer attach its report to a run
-- that a concurrent reviewer has already driven to ``complete``.
--
-- Background: the design-review pipeline supports MULTIPLE agents
-- reviewing one capture run (the natural key on ``agent_reports`` is
-- ``(run_id, agent_name, agent_version)``, and ``record_agent_report``
-- already accepts ``review_pending`` / ``reviewed`` so a later reviewer
-- can add its row after an earlier one moved the run past
-- ``capture_complete``).  But the guard set stopped at ``reviewed`` and
-- did NOT include the terminal ``complete`` status.
--
-- That gap is a genuine race for two concurrent ``run-review`` processes
-- with different ``--agent-version`` values against the same run
-- (the ``e2e_concurrent_two_agent_reports_one_run`` scenario): whichever
-- process finishes first calls ``finish_run`` and advances the run to
-- ``complete``; the second process' ``record_agent_report`` then hit
-- ``guard_run_status: ... in status complete not in allowed set`` and
-- was rejected, so only ONE of the two reports persisted.  The dispatcher
-- documented an idempotency short-circuit for this, but that only covers
-- a re-run under the SAME agent key, not a distinct concurrent reviewer.
--
-- Fix: add ``complete`` to ``record_agent_report``'s allowed-status set.
-- A report can now be recorded against an already-complete run.  This is
-- purely additive to the state machine — ``complete`` stays terminal and
-- no status transition happens on this path (the ``capture_complete ->
-- review_pending`` transition still fires only from ``capture_complete``),
-- so the run's terminal status is untouched; the second report simply
-- lands with its own ``report.recorded`` audit event.  Idempotency and
-- every other invariant are unchanged (``ON CONFLICT DO NOTHING`` on the
-- natural key; audit emitted only on a genuine insert).

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION design_review.record_agent_report(
  p_run_id          UUID,
  p_agent_name      TEXT,
  p_agent_version   TEXT,
  p_raw_output_path TEXT,
  p_parsed_scores   JSONB
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_report_id UUID;
  v_inserted  BOOLEAN := FALSE;
  v_status    TEXT;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'record_agent_report: p_run_id must not be NULL';
  END IF;
  IF p_agent_name IS NULL OR p_agent_name = '' THEN
    RAISE EXCEPTION 'record_agent_report: p_agent_name must be a non-empty string';
  END IF;
  IF p_agent_version IS NULL OR p_agent_version = '' THEN
    RAISE EXCEPTION 'record_agent_report: p_agent_version must be a non-empty string';
  END IF;
  IF p_raw_output_path IS NULL OR p_raw_output_path = '' THEN
    RAISE EXCEPTION 'record_agent_report: p_raw_output_path must be a non-empty string';
  END IF;
  IF p_parsed_scores IS NULL THEN
    RAISE EXCEPTION 'record_agent_report: p_parsed_scores must not be NULL';
  END IF;

  -- ``complete`` is included so a second concurrent reviewer can still
  -- record its report after another reviewer finished the run.
  v_status := design_review.guard_run_status(
    p_run_id, ARRAY['capture_complete', 'review_pending', 'reviewed', 'complete']);

  INSERT INTO design_review.agent_reports (
    run_id, agent_name, agent_version, raw_output_path, parsed_scores, status
  )
  VALUES (
    p_run_id, p_agent_name, p_agent_version, p_raw_output_path,
    p_parsed_scores, 'complete'
  )
  ON CONFLICT (run_id, agent_name, agent_version) DO NOTHING
  RETURNING report_id INTO v_report_id;

  IF v_report_id IS NOT NULL THEN
    v_inserted := TRUE;
  ELSE
    SELECT report_id INTO v_report_id
    FROM design_review.agent_reports
    WHERE run_id = p_run_id
      AND agent_name = p_agent_name
      AND agent_version = p_agent_version;
  END IF;

  IF v_inserted THEN
    -- Transition capture_complete → review_pending on first acceptance.
    -- A run already in review_pending / reviewed / complete keeps its
    -- status (complete stays terminal).
    IF v_status = 'capture_complete' THEN
      UPDATE design_review.runs
        SET status = 'review_pending'
        WHERE run_id = p_run_id;
    END IF;
    PERFORM design_review.audit_event_insert(
      p_agent_name,
      'report.recorded',
      p_run_id, v_report_id, NULL,
      jsonb_build_object(
        'agent_name', p_agent_name,
        'agent_version', p_agent_version,
        'raw_output_path', p_raw_output_path
      )
    );
  END IF;
  RETURN v_report_id;
END;
$$;
