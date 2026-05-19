-- REV-M7 — small helper routine: fetch a single capture row by id.
--
-- The REV-M7 gallery backend's ``GET /api/design-review/get-capture-png``
-- endpoint needs to translate a ``capture_id`` (URL param) into the
-- store path / sha so it can stream the bytes back to the browser.
--
-- We could resolve via ``fetch_run`` on the parent run, but that's a
-- two-routine hop (run_id lookup + fetch_run scan) and the app role
-- has no direct SELECT grant on ``design_review.captures``.  A small
-- SECURITY DEFINER routine that returns one row by primary key keeps
-- the trust boundary intact without making the API handler walk every
-- capture in a run to find the one it already knows the id of.

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION design_review.fetch_capture(
  p_capture_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_capture_id IS NULL THEN
    RAISE EXCEPTION 'fetch_capture: p_capture_id must not be NULL';
  END IF;
  SELECT jsonb_build_object(
    'capture_id',     c.capture_id,
    'run_id',         c.run_id,
    'preview_id',     c.preview_id,
    'backend',        c.backend,
    'viewport_label', c.viewport_label,
    'png_sha256',     c.png_sha256,
    'png_path',       c.png_path,
    'width',          c.width,
    'height',         c.height,
    'captured_at',    c.captured_at
  ) INTO v_result
  FROM design_review.captures c
  WHERE c.capture_id = p_capture_id;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'fetch_capture: capture % does not exist', p_capture_id;
  END IF;
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION design_review.fetch_capture(UUID)
  TO design_review_app;
