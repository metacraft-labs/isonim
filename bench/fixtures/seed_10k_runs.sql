-- REV-M9 fixture: 10 000 ``runs`` rows for one brief.
--
-- Drives the ``list_history`` benchmark.  We want ``list_history`` to
-- index-scan a *large* table and still pay only for the ``LIMIT`` slice;
-- the benchmark target (p50 < 20 ms, p95 < 50 ms) is realistic only when
-- the table has enough rows that a sequential scan would blow the budget
-- by orders of magnitude.
--
-- Idempotent: re-running tops the row count back up to 10 000.  Re-runs
-- only insert the missing tail rather than duplicating, so the benchmark
-- harness can call this between iterations without unbounded growth.
--
-- Brief id: ``render.bench-fixture`` — reserved for the benchmark.  Real
-- briefs live under ``isonim-examples/briefs/`` and never collide with
-- this namespace.
--
-- Bypasses the ``start_run`` SECURITY DEFINER routine — we issue a
-- single bulk INSERT under the migrator role for speed; audit rows are
-- *not* emitted by this seeder.  That's a deliberate departure from
-- production: the benchmark cares about hot-path read perf, not write
-- audit trail.

DO $$
DECLARE
  v_existing INT;
  v_missing  INT;
  v_target   INT := 10000;
  v_brief    TEXT := 'render.bench-fixture';
BEGIN
  SELECT COUNT(*) INTO v_existing
    FROM design_review.runs
    WHERE brief_id = v_brief;

  v_missing := v_target - v_existing;
  IF v_missing <= 0 THEN
    RAISE NOTICE 'seed_10k_runs: % rows already present for brief %; nothing to do',
      v_existing, v_brief;
    RETURN;
  END IF;

  -- Spread ``started_at`` across the last 90 days so the
  -- ``idx_runs_brief_started`` index has a realistic key distribution
  -- (a single timestamp on every row would degenerate into a hash
  -- collision storm under ORDER BY started_at DESC).
  INSERT INTO design_review.runs
    (brief_id, manifest_hash, status, started_by, started_at, finished_at)
  SELECT
    v_brief,
    'bench-manifest-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 7 = 0 THEN 'review_pending'
        WHEN g % 7 = 1 THEN 'reviewed'
        WHEN g % 7 = 2 THEN 'capture_failed'
        ELSE 'complete' END,
    'bench-fixture',
    NOW() - (g * INTERVAL '12 minutes'),
    NOW() - (g * INTERVAL '12 minutes') + INTERVAL '4 minutes'
  FROM generate_series(v_existing + 1, v_target) AS g;

  RAISE NOTICE 'seed_10k_runs: inserted % rows for brief % (now at %)',
    v_missing, v_brief, v_target;
END
$$ LANGUAGE plpgsql;
