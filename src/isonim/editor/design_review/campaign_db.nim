## REV-M5 follow-up (2026-10-10) — opening a campaign round against its
## workspace pin (migration 012).
##
## ``openCampaignRound`` is what ``POST /api/campaign/start`` does with the
## pin the CLI sent: store the record (``record_workspace_pin``), then, in
## one statement, ``start_campaign`` (whose start pin is that pin when the
## row is new) and ``begin_campaign_round`` (the round's own pin).  One
## statement is one transaction, so a campaign row can never be created
## without its first round, and a round can never be numbered without its
## pin.

import std/strutils

import db_connector/db_postgres

import ./db
import ./pin_db
import ./workspace_pin

type
  CampaignStart* = object
    docPath*, docSha*: string
    briefRefs*: seq[string]
    targetScore*: float
    hasTargetScore*: bool
    maxIterations*: int
    agentBackend*, agentModel*, startedBy*: string

  CampaignRound* = object
    campaignId*: string
    round*: int

proc esc(s: string): string = s.replace("'", "''")

proc openCampaignRound*(db: ReviewDb; start: CampaignStart;
                        pin: WorkspacePin): CampaignRound =
  ## Record ``pin``, create or reopen the campaign for ``start`` and begin
  ## its next round against ``pin``.  Raises ``DbError`` when the database
  ## refuses (e.g. a pin that is not a recorded ``wslock-v1:`` value).
  db.asApp()
  recordWorkspacePin(db, pin, start.startedBy)
  var arrLit = "ARRAY["
  for i, b in start.briefRefs:
    if i > 0: arrLit.add ", "
    arrLit.add "'" & esc(b) & "'"
  arrLit.add "]::text[]"
  let scoreLit =
    if start.hasTargetScore: $start.targetScore & "::real" else: "NULL::real"
  let modelLit =
    if start.agentModel.len == 0: "NULL" else: "'" & esc(start.agentModel) & "'"
  # ``start_campaign`` is VOLATILE, so the CTE is evaluated exactly once
  # and ``begin_campaign_round`` sees the row it created.
  let stmt =
    "WITH c AS (SELECT design_review.start_campaign(" &
      "'" & esc(start.docPath) & "', " &
      "'" & esc(start.docSha) & "', " &
      arrLit & ", " &
      scoreLit & ", " &
      $start.maxIterations & ", " &
      "'" & esc(pin.pin) & "', " &
      "'" & esc(start.agentBackend) & "', " &
      modelLit & ", " &
      "'" & esc(start.startedBy) & "') AS id) " &
    "SELECT c.id::text, design_review.begin_campaign_round(c.id, '" &
      esc(pin.pin) & "', '" & esc(start.startedBy) & "')::text FROM c"
  let row = db.conn.getRow(sql(stmt))
  if row.len < 2 or row[0].len == 0 or row[1].len == 0:
    raise newException(DbError,
      "openCampaignRound: start_campaign / begin_campaign_round returned nothing")
  CampaignRound(campaignId: row[0], round: parseInt(row[1]))
