-- REV-M3 — design_review stored-procedure layer.
--
-- All twelve routines documented in
-- codetracer-specs/Front-Ends/IsoNim/isonim-editor.md
-- § "Design Briefs & Review Database" → "Routines".
--
-- Contract for every routine:
--   * validate non-null / non-empty inputs and ``RAISE EXCEPTION`` with a
--     meaningful message on failure (validation at the DB boundary);
--   * perform the row write under ``SECURITY DEFINER`` so the app role can
--     mutate rows it has no direct INSERT/UPDATE/DELETE privilege on;
--   * insert a matching ``audit_events`` row in the same transaction;
--   * enforce idempotency on the documented natural key where applicable;
--   * grant EXECUTE to ``design_review_app``.
--
-- Helper functions (``audit_event_insert``, ``guard_run_status``) come
-- from ``lib.sql`` which is ``\i``-included by the migrate driver — but
-- to support hand-running this file with ``psql -f`` from any working
-- directory we also inline the helpers here when ``\i`` is unavailable.
-- We chose to keep them in lib.sql AND ``\i`` it; if you re-run this
-- migration manually outside the harness, apply ``lib.sql`` first.

\set ON_ERROR_STOP on

\i lib.sql

-- ===========================================================================
-- 1. start_run — opens a new design-review run.
-- Audit kind: 'run.started'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.start_run(
  p_brief_id      TEXT,
  p_manifest_hash TEXT,
  p_started_by    TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_run_id UUID;
BEGIN
  IF p_brief_id IS NULL OR p_brief_id = '' THEN
    RAISE EXCEPTION 'start_run: p_brief_id must be a non-empty string';
  END IF;
  IF p_manifest_hash IS NULL OR p_manifest_hash = '' THEN
    RAISE EXCEPTION 'start_run: p_manifest_hash must be a non-empty string';
  END IF;
  IF p_started_by IS NULL OR p_started_by = '' THEN
    RAISE EXCEPTION 'start_run: p_started_by must be a non-empty string';
  END IF;

  INSERT INTO design_review.runs (brief_id, manifest_hash, status, started_by)
  VALUES (p_brief_id, p_manifest_hash, 'capturing', p_started_by)
  RETURNING run_id INTO v_run_id;

  PERFORM design_review.audit_event_insert(
    p_started_by,
    'run.started',
    v_run_id, NULL, NULL,
    jsonb_build_object('brief_id', p_brief_id, 'manifest_hash', p_manifest_hash)
  );
  RETURN v_run_id;
END;
$$;

-- ===========================================================================
-- 2. record_capture — idempotent on (run_id, preview_id, viewport_label).
-- Validates run is in 'capturing'.  Audit kind: 'capture.recorded'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.record_capture(
  p_run_id         UUID,
  p_preview_id     TEXT,
  p_backend        TEXT,
  p_viewport_label TEXT,
  p_png_sha256     TEXT,
  p_png_path       TEXT,
  p_width          INT,
  p_height         INT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_capture_id UUID;
  v_inserted   BOOLEAN := FALSE;
  v_status     TEXT;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'record_capture: p_run_id must not be NULL';
  END IF;
  IF p_preview_id IS NULL OR p_preview_id = '' THEN
    RAISE EXCEPTION 'record_capture: p_preview_id must be a non-empty string';
  END IF;
  IF p_backend IS NULL OR p_backend = '' THEN
    RAISE EXCEPTION 'record_capture: p_backend must be a non-empty string';
  END IF;
  IF p_viewport_label IS NULL OR p_viewport_label = '' THEN
    RAISE EXCEPTION 'record_capture: p_viewport_label must be a non-empty string';
  END IF;
  IF p_png_sha256 IS NULL OR p_png_sha256 = '' THEN
    RAISE EXCEPTION 'record_capture: p_png_sha256 must be a non-empty string';
  END IF;
  IF p_png_path IS NULL OR p_png_path = '' THEN
    RAISE EXCEPTION 'record_capture: p_png_path must be a non-empty string';
  END IF;
  IF p_width IS NULL OR p_width <= 0 THEN
    RAISE EXCEPTION 'record_capture: p_width must be a positive integer';
  END IF;
  IF p_height IS NULL OR p_height <= 0 THEN
    RAISE EXCEPTION 'record_capture: p_height must be a positive integer';
  END IF;

  v_status := design_review.guard_run_status(p_run_id, ARRAY['capturing']);

  INSERT INTO design_review.captures (
    run_id, preview_id, backend, viewport_label,
    png_sha256, png_path, width, height
  )
  VALUES (
    p_run_id, p_preview_id, p_backend, p_viewport_label,
    p_png_sha256, p_png_path, p_width, p_height
  )
  ON CONFLICT (run_id, preview_id, viewport_label) DO NOTHING
  RETURNING capture_id INTO v_capture_id;

  IF v_capture_id IS NOT NULL THEN
    v_inserted := TRUE;
  ELSE
    SELECT capture_id INTO v_capture_id
    FROM design_review.captures
    WHERE run_id = p_run_id
      AND preview_id = p_preview_id
      AND viewport_label = p_viewport_label;
  END IF;

  IF v_inserted THEN
    -- Audit event only for the first (idempotent) insert; replays do not
    -- generate noisy duplicate audit rows.
    PERFORM design_review.audit_event_insert(
      'system',
      'capture.recorded',
      p_run_id, NULL, NULL,
      jsonb_build_object(
        'capture_id', v_capture_id,
        'preview_id', p_preview_id,
        'backend',    p_backend,
        'viewport_label', p_viewport_label,
        'png_sha256', p_png_sha256,
        'width',      p_width,
        'height',     p_height
      )
    );
  END IF;
  RETURN v_capture_id;
END;
$$;

-- ===========================================================================
-- 3. finish_captures — capturing → capture_complete.  Audit: 'run.captures_finished'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.finish_captures(
  p_run_id UUID
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
BEGIN
  PERFORM design_review.guard_run_status(p_run_id, ARRAY['capturing']);
  UPDATE design_review.runs
    SET status = 'capture_complete'
    WHERE run_id = p_run_id;
  PERFORM design_review.audit_event_insert(
    'system',
    'run.captures_finished',
    p_run_id, NULL, NULL,
    '{}'::jsonb
  );
END;
$$;

-- ===========================================================================
-- 4. fail_run_capture — terminal capture_failed.  Audit: 'run.capture_failed'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.fail_run_capture(
  p_run_id UUID,
  p_reason TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
BEGIN
  IF p_reason IS NULL OR p_reason = '' THEN
    RAISE EXCEPTION 'fail_run_capture: p_reason must be a non-empty string';
  END IF;
  PERFORM design_review.guard_run_status(p_run_id,
    ARRAY['capturing', 'capture_complete']);
  UPDATE design_review.runs
    SET status        = 'capture_failed',
      status_reason = p_reason,
      finished_at   = NOW()
    WHERE run_id = p_run_id;
  PERFORM design_review.audit_event_insert(
    'system',
    'run.capture_failed',
    p_run_id, NULL, NULL,
    jsonb_build_object('reason', p_reason)
  );
END;
$$;

-- ===========================================================================
-- 5. record_agent_report — idempotent on (run_id, agent_name, agent_version).
-- Transitions capture_complete → review_pending on first call.  Audit:
-- 'report.recorded'.
-- ===========================================================================
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

  v_status := design_review.guard_run_status(
    p_run_id, ARRAY['capture_complete', 'review_pending', 'reviewed']);

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

-- ===========================================================================
-- 6. finish_run — review_pending → reviewed → complete.  Audit:
-- 'run.completed'.  Terminal.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.finish_run(
  p_run_id UUID
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
BEGIN
  PERFORM design_review.guard_run_status(
    p_run_id, ARRAY['review_pending', 'reviewed']);
  UPDATE design_review.runs
    SET status      = 'complete',
      finished_at = NOW()
    WHERE run_id = p_run_id;
  PERFORM design_review.audit_event_insert(
    'system',
    'run.completed',
    p_run_id, NULL, NULL,
    '{}'::jsonb
  );
END;
$$;

-- ===========================================================================
-- 7. fail_run_review — terminal review_failed.  Audit: 'run.review_failed'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.fail_run_review(
  p_run_id UUID,
  p_reason TEXT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
BEGIN
  IF p_reason IS NULL OR p_reason = '' THEN
    RAISE EXCEPTION 'fail_run_review: p_reason must be a non-empty string';
  END IF;
  PERFORM design_review.guard_run_status(p_run_id,
    ARRAY['capture_complete', 'review_pending', 'reviewed']);
  UPDATE design_review.runs
    SET status        = 'review_failed',
      status_reason = p_reason,
      finished_at   = NOW()
    WHERE run_id = p_run_id;
  PERFORM design_review.audit_event_insert(
    'system',
    'run.review_failed',
    p_run_id, NULL, NULL,
    jsonb_build_object('reason', p_reason)
  );
END;
$$;

-- ===========================================================================
-- 8. list_history — hot path; index hit on idx_runs_brief_started.
-- Returns the N most recent runs for a brief with their reports summary.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.list_history(
  p_brief_id TEXT,
  p_limit    INT,
  p_offset   INT
) RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_limit  INT := COALESCE(p_limit, 50);
  v_offset INT := COALESCE(p_offset, 0);
BEGIN
  IF p_brief_id IS NULL OR p_brief_id = '' THEN
    RAISE EXCEPTION 'list_history: p_brief_id must be a non-empty string';
  END IF;
  IF v_limit < 0 OR v_limit > 1000 THEN
    RAISE EXCEPTION 'list_history: p_limit out of range (0..1000)';
  END IF;
  IF v_offset < 0 THEN
    RAISE EXCEPTION 'list_history: p_offset must be non-negative';
  END IF;

  RETURN QUERY
    SELECT jsonb_build_object(
      'run_id',         r.run_id,
      'brief_id',       r.brief_id,
      'manifest_hash',  r.manifest_hash,
      'status',         r.status,
      'status_reason',  r.status_reason,
      'started_by',     r.started_by,
      'started_at',     r.started_at,
      'finished_at',    r.finished_at,
      'capture_count',  (SELECT count(*) FROM design_review.captures c
        WHERE c.run_id = r.run_id),
      'report_count',   (SELECT count(*) FROM design_review.agent_reports g
        WHERE g.run_id = r.run_id)
    )
    FROM design_review.runs r
    WHERE r.brief_id = p_brief_id
    ORDER BY r.started_at DESC
    LIMIT v_limit
    OFFSET v_offset;
END;
$$;

-- ===========================================================================
-- 9. fetch_run — assemble one run + captures + reports into a single JSONB.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.fetch_run(
  p_run_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_run_id IS NULL THEN
    RAISE EXCEPTION 'fetch_run: p_run_id must not be NULL';
  END IF;
  SELECT jsonb_build_object(
    'run_id',        r.run_id,
    'brief_id',      r.brief_id,
    'manifest_hash', r.manifest_hash,
    'status',        r.status,
    'status_reason', r.status_reason,
    'started_by',    r.started_by,
    'started_at',    r.started_at,
    'finished_at',   r.finished_at,
    'captures', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'capture_id',     c.capture_id,
        'preview_id',     c.preview_id,
        'backend',        c.backend,
        'viewport_label', c.viewport_label,
        'png_sha256',     c.png_sha256,
        'png_path',       c.png_path,
        'width',          c.width,
        'height',         c.height,
        'captured_at',    c.captured_at
      ) ORDER BY c.captured_at)
      FROM design_review.captures c WHERE c.run_id = r.run_id
    ), '[]'::jsonb),
    'reports', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'report_id',       g.report_id,
        'agent_name',      g.agent_name,
        'agent_version',   g.agent_version,
        'raw_output_path', g.raw_output_path,
        'parsed_scores',   g.parsed_scores,
        'status',          g.status,
        'started_at',      g.started_at,
        'finished_at',     g.finished_at
      ) ORDER BY g.started_at)
      FROM design_review.agent_reports g WHERE g.run_id = r.run_id
    ), '[]'::jsonb)
  ) INTO v_result
  FROM design_review.runs r
  WHERE r.run_id = p_run_id;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'fetch_run: run % does not exist', p_run_id;
  END IF;
  RETURN v_result;
END;
$$;

-- ===========================================================================
-- 10. save_gallery_layout — optimistic concurrency.
-- p_layout_id NULL → INSERT (version=1, p_expected_version ignored).
-- p_layout_id non-null + current.version = p_expected_version → UPDATE (++ version).
-- Otherwise RAISE SQLSTATE 'D5101', MESSAGE 'layout_version_conflict'.
-- Audit kinds: 'layout.created' / 'layout.updated'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.save_gallery_layout(
  p_layout_id        UUID,
  p_brief_id         TEXT,
  p_scope            TEXT,
  p_owner_user_id    TEXT,
  p_name             TEXT,
  p_layout           JSONB,
  p_expected_version INT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_layout_id      UUID;
  v_version        INT;
  v_actor          TEXT;
  v_audit_kind     TEXT;
  v_current_version INT;
BEGIN
  IF p_brief_id IS NULL OR p_brief_id = '' THEN
    RAISE EXCEPTION 'save_gallery_layout: p_brief_id must be a non-empty string';
  END IF;
  IF p_scope IS NULL OR p_scope NOT IN ('user', 'workspace') THEN
    RAISE EXCEPTION 'save_gallery_layout: p_scope must be ''user'' or ''workspace''';
  END IF;
  IF p_name IS NULL OR p_name = '' THEN
    RAISE EXCEPTION 'save_gallery_layout: p_name must be a non-empty string';
  END IF;
  IF p_layout IS NULL THEN
    RAISE EXCEPTION 'save_gallery_layout: p_layout must not be NULL';
  END IF;
  IF p_scope = 'user' AND (p_owner_user_id IS NULL OR p_owner_user_id = '') THEN
    RAISE EXCEPTION 'save_gallery_layout: scope=''user'' requires non-empty p_owner_user_id';
  END IF;
  IF p_scope = 'workspace' AND p_owner_user_id IS NOT NULL THEN
    RAISE EXCEPTION 'save_gallery_layout: scope=''workspace'' must have NULL p_owner_user_id';
  END IF;

  IF p_layout_id IS NULL THEN
    INSERT INTO design_review.gallery_layouts (
      brief_id, scope, owner_user_id, name, layout, version
    ) VALUES (
      p_brief_id, p_scope, p_owner_user_id, p_name, p_layout, 1
    )
    RETURNING layout_id, version INTO v_layout_id, v_version;
    v_audit_kind := 'layout.created';
    v_actor      := COALESCE(p_owner_user_id, 'workspace');
  ELSE
    SELECT version INTO v_current_version
      FROM design_review.gallery_layouts
      WHERE layout_id = p_layout_id
      FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'save_gallery_layout: layout % does not exist', p_layout_id;
    END IF;
    IF v_current_version IS DISTINCT FROM p_expected_version THEN
      RAISE EXCEPTION 'layout_version_conflict'
        USING ERRCODE = 'D5101';
    END IF;
    UPDATE design_review.gallery_layouts
      SET brief_id      = p_brief_id,
        scope         = p_scope,
        owner_user_id = p_owner_user_id,
        name          = p_name,
        layout        = p_layout,
        version       = version + 1,
        updated_at    = NOW()
      WHERE layout_id = p_layout_id
      RETURNING layout_id, version INTO v_layout_id, v_version;
    v_audit_kind := 'layout.updated';
    v_actor      := COALESCE(p_owner_user_id, 'workspace');
  END IF;

  PERFORM design_review.audit_event_insert(
    v_actor, v_audit_kind, NULL, NULL, v_layout_id,
    jsonb_build_object('brief_id', p_brief_id, 'scope', p_scope,
      'version', v_version, 'name', p_name)
  );

  RETURN jsonb_build_object(
    'layout_id',     v_layout_id,
    'brief_id',      p_brief_id,
    'scope',         p_scope,
    'owner_user_id', p_owner_user_id,
    'name',          p_name,
    'layout',        p_layout,
    'version',       v_version
  );
END;
$$;

-- ===========================================================================
-- 11. promote_layout — copies a user-scope layout to a new workspace-scope row.
-- Source unchanged.  Audit kinds: 'layout.promoted'.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.promote_layout(
  p_layout_id UUID,
  p_actor     TEXT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_new_id  UUID;
  v_brief   TEXT;
  v_name    TEXT;
  v_layout  JSONB;
  v_scope   TEXT;
BEGIN
  IF p_layout_id IS NULL THEN
    RAISE EXCEPTION 'promote_layout: p_layout_id must not be NULL';
  END IF;
  IF p_actor IS NULL OR p_actor = '' THEN
    RAISE EXCEPTION 'promote_layout: p_actor must be a non-empty string';
  END IF;
  SELECT brief_id, name, layout, scope
    INTO v_brief, v_name, v_layout, v_scope
    FROM design_review.gallery_layouts
    WHERE layout_id = p_layout_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'promote_layout: layout % does not exist', p_layout_id;
  END IF;
  IF v_scope <> 'user' THEN
    RAISE EXCEPTION 'promote_layout: source layout % is not scope=user (got %)',
      p_layout_id, v_scope;
  END IF;
  INSERT INTO design_review.gallery_layouts (
    brief_id, scope, owner_user_id, name, layout, version
  ) VALUES (
    v_brief, 'workspace', NULL, v_name, v_layout, 1
  )
  RETURNING layout_id INTO v_new_id;

  PERFORM design_review.audit_event_insert(
    p_actor, 'layout.promoted', NULL, NULL, v_new_id,
    jsonb_build_object('source_layout_id', p_layout_id, 'brief_id', v_brief)
  );
  RETURN v_new_id;
END;
$$;

-- ===========================================================================
-- 12. list_layouts — workspace-scope + user-scope layouts visible to p_user_id.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.list_layouts(
  p_brief_id TEXT,
  p_user_id  TEXT
) RETURNS SETOF JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
BEGIN
  IF p_brief_id IS NULL OR p_brief_id = '' THEN
    RAISE EXCEPTION 'list_layouts: p_brief_id must be a non-empty string';
  END IF;
  -- p_user_id may be NULL to list only workspace-scope rows.

  RETURN QUERY
    SELECT jsonb_build_object(
      'layout_id',     l.layout_id,
      'brief_id',      l.brief_id,
      'scope',         l.scope,
      'owner_user_id', l.owner_user_id,
      'name',          l.name,
      'layout',        l.layout,
      'version',       l.version,
      'created_at',    l.created_at,
      'updated_at',    l.updated_at
    )
    FROM design_review.gallery_layouts l
    WHERE l.brief_id = p_brief_id
      AND (l.scope = 'workspace'
        OR (l.scope = 'user' AND l.owner_user_id = p_user_id))
    ORDER BY l.scope ASC, l.updated_at DESC;
END;
$$;

-- ---------------------------------------------------------------------------
-- EXECUTE grants.  The app role can call each routine but cannot touch the
-- base tables directly.  ``audit_event_insert`` and ``guard_run_status`` are
-- internal helpers — they are NOT granted to ``design_review_app``; only
-- top-level routines are.
-- ---------------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION design_review.start_run(TEXT, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.record_capture(UUID, TEXT, TEXT, TEXT, TEXT, TEXT, INT, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.finish_captures(UUID)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.fail_run_capture(UUID, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.record_agent_report(UUID, TEXT, TEXT, TEXT, JSONB)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.finish_run(UUID)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.fail_run_review(UUID, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.list_history(TEXT, INT, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.fetch_run(UUID)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.save_gallery_layout(UUID, TEXT, TEXT, TEXT, TEXT, JSONB, INT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.promote_layout(UUID, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.list_layouts(TEXT, TEXT)
  TO design_review_app;
