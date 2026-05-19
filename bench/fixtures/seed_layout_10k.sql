-- REV-M9 fixture: one user-scope gallery layout with ~10 KB of JSONB.
--
-- Drives the ``save_gallery_layout`` *update path* benchmark.  We need
-- an existing row so the benchmark's hot loop hits the UPDATE branch
-- (which serialises ``p_layout`` into the row, bumps ``version``, and
-- writes one audit event).  A 10 KB payload is the upper bound the
-- editor's drag-rearrange UI is expected to produce for a brief with
-- dozens of tiles + per-tile annotations.
--
-- Idempotent: re-running re-creates the row only when absent.  The
-- ``version`` is *not* reset across re-seeds — that's the harness's
-- problem, since the bench loop must use the current version to avoid
-- ``layout_version_conflict``.
--
-- The fixture key is ``brief_id = 'render.bench-fixture' AND name =
-- 'bench-layout' AND scope = 'user' AND owner_user_id = 'bench-user'``,
-- which lets the harness re-discover the layout id.

DO $$
DECLARE
  v_layout_id UUID;
  v_payload   JSONB;
  v_chunk     TEXT;
  v_tile      JSONB;
  v_tiles     JSONB[] := '{}';
BEGIN
  -- Build a deterministic ~10 KB JSONB payload.  We use 40 tile objects
  -- of ~250 bytes each; ``pg_column_size`` on the resulting JSONB
  -- typically lands between 8 and 12 KB depending on compression.
  FOR i IN 1..40 LOOP
    v_chunk := lpad(i::text, 4, '0');
    v_tile := jsonb_build_object(
      'capture_id',    'bench-capture-' || v_chunk,
      'preview_id',    'bench/preview:' || v_chunk,
      'backend',       'web',
      'viewport',      'wide',
      'x',             (i * 17) % 1920,
      'y',             (i * 23) % 1080,
      'w',             320,
      'h',             240,
      'rotation',      0,
      'z_index',       i,
      'annotation',    'tile-' || v_chunk || '-annotation-text-for-padding',
      'tags',          to_jsonb(ARRAY['bench', 'fixture', v_chunk])
    );
    v_tiles := array_append(v_tiles, v_tile);
  END LOOP;
  v_payload := jsonb_build_object(
    'schema_version', 1,
    'name',           'bench-layout',
    'tiles',          to_jsonb(v_tiles)
  );

  SELECT layout_id INTO v_layout_id
    FROM design_review.gallery_layouts
    WHERE brief_id = 'render.bench-fixture'
      AND scope = 'user'
      AND owner_user_id = 'bench-user'
      AND name = 'bench-layout'
    LIMIT 1;

  IF v_layout_id IS NULL THEN
    INSERT INTO design_review.gallery_layouts
      (brief_id, scope, owner_user_id, name, layout, version)
    VALUES
      ('render.bench-fixture', 'user', 'bench-user',
        'bench-layout', v_payload, 1)
    RETURNING layout_id INTO v_layout_id;
    RAISE NOTICE 'seed_layout_10k: inserted layout %', v_layout_id;
  ELSE
    RAISE NOTICE 'seed_layout_10k: layout % already present', v_layout_id;
  END IF;
END
$$ LANGUAGE plpgsql;
