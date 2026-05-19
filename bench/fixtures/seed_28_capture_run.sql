-- REV-M9 fixture: one run with 28 captures + 2 reports.
--
-- Drives the ``fetch_run`` benchmark.  28 captures = 7 backends × 4
-- viewports, matching the projected per-brief working set documented in
-- =isonim-editor.md='s "Design Briefs & Review Database" section.  Two
-- reports cover the canned + claude-code agent backends.
--
-- Idempotent on ``brief_id = 'render.fetch-bench'``: re-running this
-- file is safe.  A single sentinel run is created (or reused), then we
-- insert any missing captures / reports up to the target counts.
--
-- The ``run_id`` is *not* well-known across re-seeds — we expose it via
-- a notice + via the manifest_hash slot so the benchmark harness can
-- locate it deterministically with ``SELECT run_id FROM
-- design_review.runs WHERE brief_id = 'render.fetch-bench' LIMIT 1``.

DO $$
DECLARE
  v_run_id        UUID;
  v_capture_count INT;
  v_report_count  INT;
  v_target_caps   INT := 28;
  v_target_reps   INT := 2;
  v_backends      TEXT[] := ARRAY['solid', 'react', 'svelte', 'vue', 'qwik', 'web', 'angular'];
  v_viewports     TEXT[] := ARRAY['wide', 'laptop', 'tablet', 'narrow'];
BEGIN
  -- Reuse the sentinel run if it already exists.
  SELECT run_id INTO v_run_id
    FROM design_review.runs
    WHERE brief_id = 'render.fetch-bench'
    LIMIT 1;

  IF v_run_id IS NULL THEN
    INSERT INTO design_review.runs
      (brief_id, manifest_hash, status, started_by, started_at, finished_at)
    VALUES
      ('render.fetch-bench', 'bench-fetch-manifest', 'reviewed',
        'bench-fixture', NOW() - INTERVAL '1 hour',
        NOW() - INTERVAL '50 minutes')
    RETURNING run_id INTO v_run_id;
  END IF;

  SELECT COUNT(*) INTO v_capture_count
    FROM design_review.captures
    WHERE run_id = v_run_id;

  IF v_capture_count < v_target_caps THEN
    INSERT INTO design_review.captures
      (run_id, preview_id, backend, viewport_label,
        png_sha256, png_path, width, height, captured_at)
    SELECT
      v_run_id,
      'bench/preview/' || b || ':' || v,
      b,
      v,
      'sha256:' || md5(b || ':' || v),
      '/bench/store/' || b || '/' || v || '.png',
      1280,
      720,
      NOW() - INTERVAL '55 minutes'
    FROM unnest(v_backends) AS b,
      unnest(v_viewports) AS v
    ON CONFLICT (run_id, preview_id, viewport_label) DO NOTHING;
  END IF;

  SELECT COUNT(*) INTO v_report_count
    FROM design_review.agent_reports
    WHERE run_id = v_run_id;

  IF v_report_count < v_target_reps THEN
    INSERT INTO design_review.agent_reports
      (run_id, agent_name, agent_version,
        raw_output_path, parsed_scores, status, started_at, finished_at)
    VALUES
      (v_run_id, 'canned', 'v1',
        '/bench/reviews/canned.md', '{"score": 0.7}'::jsonb,
        'completed', NOW() - INTERVAL '55 minutes',
        NOW() - INTERVAL '53 minutes'),
      (v_run_id, 'claude-code', 'v1',
        '/bench/reviews/claude.md', '{"score": 0.82}'::jsonb,
        'completed', NOW() - INTERVAL '52 minutes',
        NOW() - INTERVAL '50 minutes')
    ON CONFLICT (run_id, agent_name, agent_version) DO NOTHING;
  END IF;

  RAISE NOTICE 'seed_28_capture_run: run % has % captures, % reports',
    v_run_id, v_target_caps, v_target_reps;
END
$$ LANGUAGE plpgsql;
