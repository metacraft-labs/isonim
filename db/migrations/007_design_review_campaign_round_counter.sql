-- CMP-M2.1 — campaign round counter routine.
--
-- The CMP-M2 experiment surfaced a defect: the daemon's tick handler
-- counted ``round_started`` events to derive the next round number,
-- but on the very first tick of a fresh campaign the count was 0 so the
-- tick reused ``round=1`` (already claimed by ``handleStart``'s implicit
-- round-1).  Both rounds therefore got tagged with ``round=1`` in
-- ``campaign_events.payload``, defeating the audit trail's primary
-- ordering signal.
--
-- This migration adds ``design_review.next_campaign_round`` which
-- returns the next round number to assign by counting completed
-- ``round_complete`` events.  ``handleStart``'s baseline round uses
-- 1 (returned when no ``round_complete`` event exists yet);
-- ``handleTick`` uses the routine's return value as the round it is
-- about to start.

\set ON_ERROR_STOP on

-- ===========================================================================
-- next_campaign_round — return the round number to assign for the next
-- ``round_started`` event for ``p_campaign_id``.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.next_campaign_round(
  p_campaign_id UUID
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_completed INT;
  v_exists    BOOLEAN;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'next_campaign_round: p_campaign_id must not be NULL';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM design_review.campaigns WHERE campaign_id = p_campaign_id
  ) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'next_campaign_round: campaign % does not exist', p_campaign_id;
  END IF;
  SELECT count(*) INTO v_completed
    FROM design_review.campaign_events
    WHERE campaign_id = p_campaign_id
      AND event_kind = 'round_complete';
  RETURN v_completed + 1;
END;
$$;

GRANT EXECUTE ON FUNCTION
  design_review.next_campaign_round(UUID)
  TO design_review_app;

-- ===========================================================================
-- count_campaign_round_complete — return the number of completed rounds
-- for ``p_campaign_id``.  The auto-tick path uses this to bound itself
-- against ``campaigns.max_iterations`` without granting the app role
-- direct SELECT on the base table.
-- ===========================================================================
CREATE OR REPLACE FUNCTION design_review.count_campaign_round_complete(
  p_campaign_id UUID
) RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = design_review, public, pg_temp
AS $$
DECLARE
  v_count  INT;
  v_exists BOOLEAN;
BEGIN
  IF p_campaign_id IS NULL THEN
    RAISE EXCEPTION 'count_campaign_round_complete: p_campaign_id must not be NULL';
  END IF;
  SELECT EXISTS (
    SELECT 1 FROM design_review.campaigns WHERE campaign_id = p_campaign_id
  ) INTO v_exists;
  IF NOT v_exists THEN
    RAISE EXCEPTION 'count_campaign_round_complete: campaign % does not exist', p_campaign_id;
  END IF;
  SELECT count(*) INTO v_count
    FROM design_review.campaign_events
    WHERE campaign_id = p_campaign_id
      AND event_kind = 'round_complete';
  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION
  design_review.count_campaign_round_complete(UUID)
  TO design_review_app;
