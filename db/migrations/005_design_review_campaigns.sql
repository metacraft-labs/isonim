-- CMP-M2 — design_review campaigns + campaign_events tables.
--
-- Implements the storage layer described in the campaign-system task plan
-- (mandatory reading: codetracer-specs/Front-Ends/IsoNim/isonim-editor.md
-- § "AI Assistant & Design Campaigns").  This is the CMP-M2 schema —
-- forward-references in that spec lead here.
--
-- Two tables:
--
--   * design_review.campaigns        — one row per campaign.  The campaign
--                                      doc on disk is the source of truth
--                                      for prose; this row is the indexable
--                                      projection the orchestrator + CLI +
--                                      Gallery overlay query.
--   * design_review.campaign_events  — append-only audit log of orchestrator
--                                      decisions, sub-agent dispatches,
--                                      verifications, injects, escalations.
--                                      The campaign doc's ## History is the
--                                      human-readable mirror; this table is
--                                      the byte-level record.
--
-- App-role boundary: the ``design_review_app`` role gets USAGE on the
-- schema (already granted in migration 001) but no direct INSERT/UPDATE/
-- DELETE on either table.  Routines defined in migration 006 are the only
-- callable surface.
--
-- This migration intentionally diverges from the early forward-reference
-- DDL inlined at isonim-editor.md § "Storage (forward-reference: CMP-M2)"
-- where the implementation surfaced concrete requirements not yet
-- considered in the spec draft:
--
--   * ``doc_sha`` instead of ``doc_sha256`` — generic enough that we can
--     swap the hash algorithm without renaming the column.
--   * ``manifest_hash`` (workspace pin) is added so a campaign can be
--     replayed against the exact workspace state it ran against.
--   * ``acp_session_id`` is added so the daemon can bind the long-lived
--     orchestrator ACP session to the row at start time.
--   * ``agent_backend`` / ``agent_model`` are added so the audit trail
--     records which backend drove this campaign.
--   * ``status_reason`` mirrors the same field on ``runs``.
--   * No ``campaign_slug`` UNIQUE — idempotency is keyed on (doc_path,
--     doc_sha) instead, matching the CLI's ``isonim-review campaign
--     start --doc <path>`` contract.  Two campaigns referencing the same
--     doc with the same bytes resolve to the same row.

\set ON_ERROR_STOP on

-- ==========================================================================
-- design_review.campaigns
-- ==========================================================================
CREATE TABLE design_review.campaigns (
  campaign_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  doc_path         TEXT NOT NULL,
  doc_sha          TEXT NOT NULL,
  brief_refs       TEXT[] NOT NULL,
  target_score     REAL,
  max_iterations   INT NOT NULL DEFAULT 30,
  manifest_hash    TEXT NOT NULL,
  status           TEXT NOT NULL,
  status_reason    TEXT,
  acp_session_id   TEXT,
  agent_backend    TEXT NOT NULL,
  agent_model      TEXT,
  started_by       TEXT NOT NULL,
  started_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at      TIMESTAMPTZ,
  UNIQUE (doc_path, doc_sha)
);

CREATE INDEX idx_campaigns_status        ON design_review.campaigns (status);
CREATE INDEX idx_campaigns_brief_started ON design_review.campaigns USING GIN (brief_refs);

-- ==========================================================================
-- design_review.campaign_events
-- ==========================================================================
CREATE TABLE design_review.campaign_events (
  event_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  campaign_id   UUID NOT NULL REFERENCES design_review.campaigns(campaign_id),
  occurred_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  event_kind    TEXT NOT NULL,
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  acknowledged  BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_campaign_events_kind_time
  ON design_review.campaign_events (campaign_id, occurred_at DESC);
CREATE INDEX idx_campaign_events_unacked
  ON design_review.campaign_events (campaign_id) WHERE acknowledged = FALSE;

-- ==========================================================================
-- Grants.  USAGE on the schema was issued by migration 001; we deliberately
-- do NOT grant direct DML on the new tables — the routines in migration
-- 006 are the app role's only entry point.
-- ==========================================================================
GRANT ALL PRIVILEGES ON TABLE design_review.campaigns        TO design_review_migrator;
GRANT ALL PRIVILEGES ON TABLE design_review.campaign_events  TO design_review_migrator;
