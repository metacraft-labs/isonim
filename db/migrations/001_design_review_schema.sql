-- REV-M3 — design_review schema, tables, indexes, and role grants.
--
-- Source of truth for the DDL: codetracer-specs/Front-Ends/IsoNim/isonim-editor.md
-- § "Design Briefs & Review Database" → "Tables".  Keep the column lists
-- and CHECK constraints byte-identical to that spec; if a mismatch is
-- ever introduced, fix the migration, not the spec.

CREATE SCHEMA IF NOT EXISTS design_review;

-- ``pgcrypto`` provides ``gen_random_uuid()``.  Some Postgres builds also
-- ship this through ``uuid-ossp`` but ``pgcrypto`` is what the spec relies
-- on.  Created in the public schema so both base tables and audit rows can
-- reach it without a search-path tweak.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ==========================================================================
-- design_review.runs — one capture-and-review cycle.
-- Append-only: brief_id / manifest_hash never change; only the status
-- columns advance through the lifecycle (capturing → capture_complete →
-- review_pending → reviewed → complete, with capture_failed / review_failed
-- terminal failure states).
-- ==========================================================================
CREATE TABLE design_review.runs (
  run_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  brief_id          TEXT NOT NULL,
  manifest_hash     TEXT NOT NULL,
  status            TEXT NOT NULL,
  status_reason     TEXT,
  started_by        TEXT NOT NULL,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at       TIMESTAMPTZ
);

CREATE INDEX idx_runs_brief_started ON design_review.runs (brief_id, started_at DESC);
CREATE INDEX idx_runs_status        ON design_review.runs (status);

-- ==========================================================================
-- design_review.captures — one captured preview per (run, preview, viewport).
-- PNG bytes live in the content-addressed store on disk; this row references
-- them.  Idempotency is enforced at the UNIQUE constraint and again at the
-- ``record_capture`` routine boundary (ON CONFLICT DO NOTHING).
-- ==========================================================================
CREATE TABLE design_review.captures (
  capture_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id            UUID NOT NULL REFERENCES design_review.runs(run_id),
  preview_id        TEXT NOT NULL,
  backend           TEXT NOT NULL,
  viewport_label    TEXT NOT NULL,
  png_sha256        TEXT NOT NULL,
  png_path          TEXT NOT NULL,
  width             INT  NOT NULL CHECK (width  > 0),
  height            INT  NOT NULL CHECK (height > 0),
  captured_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (run_id, preview_id, viewport_label)
);

CREATE INDEX idx_captures_sha256 ON design_review.captures (png_sha256);
CREATE INDEX idx_captures_run    ON design_review.captures (run_id);

-- ==========================================================================
-- design_review.agent_reports — one report per (run, agent_name, agent_version).
-- ``parsed_scores`` is the typed JSONB projection of the reviewer-output
-- markdown frontmatter.  ``raw_output_path`` references the .md file in the
-- on-disk review store.
-- ==========================================================================
CREATE TABLE design_review.agent_reports (
  report_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id            UUID NOT NULL REFERENCES design_review.runs(run_id),
  agent_name        TEXT NOT NULL,
  agent_version     TEXT NOT NULL,
  raw_output_path   TEXT NOT NULL,
  parsed_scores     JSONB NOT NULL,
  status            TEXT NOT NULL,
  started_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  finished_at       TIMESTAMPTZ,
  UNIQUE (run_id, agent_name, agent_version)
);

CREATE INDEX idx_reports_run ON design_review.agent_reports (run_id);

-- ==========================================================================
-- design_review.gallery_layouts — persisted gallery arrangements.
-- Scope = 'user' (owned by a person) or 'workspace' (shared).  Optimistic
-- concurrency via ``version``; ``save_gallery_layout`` bumps it on every
-- accepted write and rejects writes whose expected_version is stale.
-- ==========================================================================
CREATE TABLE design_review.gallery_layouts (
  layout_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  brief_id          TEXT NOT NULL,
  scope             TEXT NOT NULL,
  owner_user_id     TEXT,
  name              TEXT NOT NULL,
  layout            JSONB NOT NULL,
  version           INT  NOT NULL DEFAULT 1,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CHECK ((scope = 'user'      AND owner_user_id IS NOT NULL) OR
      (scope = 'workspace' AND owner_user_id IS NULL))
);

CREATE INDEX idx_layouts_brief       ON design_review.gallery_layouts (brief_id);
CREATE INDEX idx_layouts_brief_owner ON design_review.gallery_layouts (brief_id, owner_user_id);

-- ==========================================================================
-- design_review.audit_events — append-only audit log.  Every routine that
-- mutates state appends one row in the same transaction as the mutation
-- (see ``design_review.audit_event_insert`` in migration 002).
-- ==========================================================================
CREATE TABLE design_review.audit_events (
  event_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  occurred_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  actor             TEXT NOT NULL,
  event_kind        TEXT NOT NULL,
  run_id            UUID REFERENCES design_review.runs(run_id),
  report_id         UUID REFERENCES design_review.agent_reports(report_id),
  layout_id         UUID REFERENCES design_review.gallery_layouts(layout_id),
  payload           JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX idx_audit_kind_time ON design_review.audit_events (event_kind, occurred_at DESC);

-- ==========================================================================
-- Role grants.
--
--   ``design_review_migrator``  — DDL + DML on every base table; used only
--                                 by migrations and admin tools.
--
--   ``design_review_app``       — USAGE on the schema and (via migration
--                                 002) EXECUTE on every routine.  No direct
--                                 INSERT/UPDATE/DELETE/SELECT on base
--                                 tables; all writes flow through routines,
--                                 all reads through projection views (none
--                                 in this milestone — added in REV-M7+).
--
-- This is the stored-procedure boundary required by the database-design
-- guidelines.  Tests in ``test_design_review_pg_roles.nim`` enforce that
-- the app role cannot bypass the boundary.
-- ==========================================================================
GRANT ALL PRIVILEGES ON SCHEMA design_review TO design_review_migrator;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA design_review TO design_review_migrator;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA design_review TO design_review_migrator;

GRANT USAGE ON SCHEMA design_review TO design_review_app;
-- Intentionally: NO ``GRANT SELECT/INSERT/UPDATE/DELETE`` to design_review_app
-- on the base tables.  EXECUTE grants are issued by migration 002 per-routine.

-- Make ``gen_random_uuid()`` etc. reachable from SECURITY DEFINER routines
-- without depending on the caller's search_path.
GRANT USAGE ON SCHEMA public TO design_review_app, design_review_migrator;
