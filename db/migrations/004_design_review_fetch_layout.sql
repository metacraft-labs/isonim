-- REV-M8 — small helper routine: fetch a single layout row by id.
--
-- The REV-M8 ``POST /api/design-review/promote-layout`` endpoint needs
-- to return the newly-inserted workspace row so the editor can swap
-- to it without a follow-up roundtrip.  ``list_layouts`` is the only
-- app-role-visible read of ``design_review.gallery_layouts``, but it
-- requires a ``brief_id`` parameter — and after ``promote_layout``
-- returns just the new UUID we'd need an extra lookup to translate
-- ``layout_id → brief_id`` so we can call ``list_layouts``.
--
-- This routine keeps the trust boundary intact (no direct SELECT grant
-- on the base table) while letting the handler resolve a layout row
-- by primary key in one call.  The conflict path also benefits — when
-- ``save_gallery_layout`` raises the version-conflict SQLSTATE, the
-- handler can surface the current row via ``fetch_layout`` without
-- having to scan ``list_layouts``' SETOF result.

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION design_review.fetch_layout(
  p_layout_id UUID
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_result JSONB;
BEGIN
  IF p_layout_id IS NULL THEN
    RAISE EXCEPTION 'fetch_layout: p_layout_id must not be NULL';
  END IF;
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
  ) INTO v_result
  FROM design_review.gallery_layouts l
  WHERE l.layout_id = p_layout_id;
  IF v_result IS NULL THEN
    RAISE EXCEPTION 'fetch_layout: layout % does not exist', p_layout_id;
  END IF;
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION design_review.fetch_layout(UUID)
  TO design_review_app;
