-- REV-M5 follow-up (2026-10-02) — workspace pins are reprobuild workspace
-- locks, stored with their content.
--
-- ``runs.manifest_hash`` and ``campaigns.manifest_hash`` used to hold the
-- sha256 of a canonicalised ``repo manifest -r`` (Google ``repo``).  That
-- tooling is retired in favour of reprobuild, and a bare hash was never
-- resolvable anyway: the manifest it named was not stored, so replay had
-- to hope the current workspace still pinned the same revisions.
--
-- From this migration on, capture stores in ``manifest_hash`` a *workspace
-- pin*:
--
--     wslock-v1:sha256:<64 lowercase hex>
--
-- the sha256 of a canonical ``reprobuild.workspace.lock.v1`` record (every
-- repo's name / path / remote / published revision — see
-- ``src/isonim/editor/design_review/workspace_pin.nim``), and stores that
-- record here.  A pin is therefore resolvable from the database alone,
-- and the CHECK below makes it impossible to store a record under a pin
-- it does not hash to.
--
-- The column type stays ``TEXT NOT NULL``; only the value form changes.
--
-- Existing rows are NOT rewritten (``runs`` is append-only by design;
-- migration 001).  Their values stay recognisable by shape, and the Nim
-- side (``workspace_pin.classifyPin``) refuses to replay them as a
-- workspace lock:
--
--   * 64 lowercase hex, no prefix  -> retired ``repo manifest`` hash; no
--                                     content exists; not replayable.
--   * ``seeded:<tag>``             -> ``isonim-review seed-run`` sentinel
--                                     (working-tree brief fallback).
--   * anything else ("local", ...) -> unrecognised; not replayable.
--
-- A new value with the ``wslock-v1:`` prefix can only enter ``runs``
-- through ``start_run`` once its record is in ``workspace_pins`` (the
-- guard added to ``start_run`` below), so a run can never point at a pin
-- whose content was lost.

\set ON_ERROR_STOP on

-- ==========================================================================
-- design_review.workspace_pins — content-addressed pin records.
-- ==========================================================================
CREATE TABLE design_review.workspace_pins (
  pin          TEXT PRIMARY KEY
               CHECK (pin ~ '^wslock-v1:sha256:[0-9a-f]{64}$'),
  lock_toml    TEXT NOT NULL,
  lock_record  TEXT,
    -- ``<project>/<repo>@<sha>`` of a published reprobuild lock record in
    -- the workspace's record store that pinned the same revisions at
    -- capture time; NULL when there was none.  Advisory cross-reference,
    -- not part of the pin's identity.
  recorded_by  TEXT NOT NULL,
  recorded_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ('wslock-v1:sha256:' ||
         encode(sha256(convert_to(lock_toml, 'UTF8')), 'hex') = pin)
);

GRANT ALL PRIVILEGES ON TABLE design_review.workspace_pins TO design_review_migrator;

-- ==========================================================================
-- record_workspace_pin — idempotent on ``pin``.  A later capture of the
-- same state may supply a published ``lock_record`` the first one lacked;
-- it is filled in, never overwritten.
-- Audit kind: 'workspace_pin.recorded' (first insert only).
-- ==========================================================================
CREATE OR REPLACE FUNCTION design_review.record_workspace_pin(
  p_pin         TEXT,
  p_lock_toml   TEXT,
  p_lock_record TEXT,
  p_recorded_by TEXT
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_inserted BOOLEAN := FALSE;
BEGIN
  IF p_pin IS NULL OR p_pin = '' THEN
    RAISE EXCEPTION 'record_workspace_pin: p_pin must be a non-empty string';
  END IF;
  IF p_lock_toml IS NULL OR p_lock_toml = '' THEN
    RAISE EXCEPTION 'record_workspace_pin: p_lock_toml must be a non-empty string';
  END IF;
  IF p_recorded_by IS NULL OR p_recorded_by = '' THEN
    RAISE EXCEPTION 'record_workspace_pin: p_recorded_by must be a non-empty string';
  END IF;
  IF 'wslock-v1:sha256:' ||
     encode(sha256(convert_to(p_lock_toml, 'UTF8')), 'hex') <> p_pin THEN
    RAISE EXCEPTION 'record_workspace_pin: record does not hash to %', p_pin;
  END IF;

  INSERT INTO design_review.workspace_pins (pin, lock_toml, lock_record, recorded_by)
  VALUES (p_pin, p_lock_toml, NULLIF(p_lock_record, ''), p_recorded_by)
  ON CONFLICT (pin) DO NOTHING;
  v_inserted := FOUND;

  IF v_inserted THEN
    PERFORM design_review.audit_event_insert(
      p_recorded_by, 'workspace_pin.recorded', NULL, NULL, NULL,
      jsonb_build_object('pin', p_pin,
                         'lock_record', NULLIF(p_lock_record, '')));
  ELSIF NULLIF(p_lock_record, '') IS NOT NULL THEN
    UPDATE design_review.workspace_pins
       SET lock_record = p_lock_record
     WHERE pin = p_pin AND lock_record IS NULL;
  END IF;
  RETURN p_pin;
END;
$$;

-- ==========================================================================
-- fetch_workspace_pin — the stored record for a pin, or an exception.
-- ==========================================================================
CREATE OR REPLACE FUNCTION design_review.fetch_workspace_pin(
  p_pin TEXT
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_pin IS NULL OR p_pin = '' THEN
    RAISE EXCEPTION 'fetch_workspace_pin: p_pin must be a non-empty string';
  END IF;
  SELECT jsonb_build_object(
    'pin',         w.pin,
    'lock_toml',   w.lock_toml,
    'lock_record', w.lock_record,
    'recorded_by', w.recorded_by,
    'recorded_at', w.recorded_at
  ) INTO v_result
  FROM design_review.workspace_pins w
  WHERE w.pin = p_pin;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'fetch_workspace_pin: pin % does not exist', p_pin;
  END IF;
  RETURN v_result;
END;
$$;

-- ==========================================================================
-- start_run — unchanged from migration 002 except for the pin guard: a
-- ``wslock-v1:`` value must name a recorded pin.
-- ==========================================================================
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
  IF p_manifest_hash LIKE 'wslock-v1:%' AND NOT EXISTS (
       SELECT 1 FROM design_review.workspace_pins WHERE pin = p_manifest_hash)
  THEN
    RAISE EXCEPTION
      'start_run: workspace pin % is not recorded (call record_workspace_pin first)',
      p_manifest_hash;
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

GRANT EXECUTE ON FUNCTION design_review.record_workspace_pin(TEXT, TEXT, TEXT, TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.fetch_workspace_pin(TEXT)
  TO design_review_app;
GRANT EXECUTE ON FUNCTION design_review.start_run(TEXT, TEXT, TEXT)
  TO design_review_app;
