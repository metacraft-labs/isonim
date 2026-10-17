## REV-M5 follow-up (2026-10-10) — a campaign's provenance: the workspace
## pin of its start and the pin of every round.
##
## A campaign is pinned the way a capture run is pinned
## (``workspace_gate.pinCleanWorkspace``: the clean-tree gate, then the
## canonical ``reprobuild.workspace.lock.v1`` record of the same
## observation, stored by ``record_workspace_pin``):
##
##   * ``campaign start`` (the CLI) pins the workspace before it contacts
##     the daemon and sends the pin — value *and* record — as
##     ``workspacePin`` (``workspacePinJson``).
##   * The daemon re-verifies the record against the pin
##     (``parseWorkspacePinJson``), stores it, and opens the round
##     (``campaign_db.openCampaignRound``).  The first round's pin becomes
##     the campaign's start pin (``campaigns.manifest_hash``); every later
##     round — every later ``campaign start`` turn against the same row —
##     records its own pin in ``design_review.campaign_rounds`` and never
##     touches the start pin.
##   * A workspace that cannot be pinned refuses the start or the round.
##     There is no "unpinned" round.
##
## Rows written before migration 012 carry whatever the client sent —
## always the placeholder ``"local"`` from the CLI — and no round rows.
## They read as *legacy, unpinned* (``cpsLegacyUnpinned``); nothing here
## raises on them.

import std/[json, strutils]

import ./workspace_pin

type
  CampaignPinState* = enum
    cpsPinned          ## a ``wslock-v1:`` workspace pin
    cpsLegacyUnpinned  ## written before campaigns were pinned ("local", ...)

  CampaignRoundPin* = object
    round*: int
    pin*: string
    lockRecord*: string   ## advisory published lock record, or ""
    startedBy*: string
    startedAt*: string

  CampaignProvenance* = object
    startPin*: string
    startState*: CampaignPinState
    rounds*: seq[CampaignRoundPin]   ## recorded rounds, oldest first
    roundsCompleted*: int            ## ``round_complete`` events

const LegacyUnpinnedNote* =
  "legacy, unpinned: recorded before campaigns were pinned; " &
  "no workspace state to replay"

proc campaignPinState*(value: string): CampaignPinState =
  ## How a stored campaign / round pin value reads.
  if classifyPin(value) == pkWorkspaceLock: cpsPinned
  else: cpsLegacyUnpinned

# ---------------------------------------------------------------------------
# Wire format: the ``workspacePin`` member of ``POST /api/campaign/start``.
# ---------------------------------------------------------------------------

proc workspacePinJson*(pin: WorkspacePin): JsonNode =
  %*{"pin": pin.pin, "lockToml": pin.lockToml, "lockRecord": pin.lockRecord}

proc parseWorkspacePinJson*(node: JsonNode): WorkspacePin =
  ## The pin a client sent, verified: ``lockToml`` must be the canonical
  ## record ``pin`` names (``resolvePin``) and must cover one reprobuild
  ## project.  Raises ``WorkspacePinError`` for a missing member, a
  ## placeholder such as ``"local"``, or a record that does not hash to
  ## the pin.
  if node == nil or node.kind != JObject:
    raise newException(WorkspacePinError,
      "workspace lock: a workspace pin {pin, lockToml} is required")
  let pin = node{"pin"}.getStr("")
  let lockToml = node{"lockToml"}.getStr("")
  let lock = resolvePin(pin, lockToml)
  if lock.scope != ProjectScope:
    raise newException(WorkspacePinError,
      "workspace lock: pin scope is '" & lock.scope & "', want '" &
      ProjectScope & "'")
  WorkspacePin(pin: pin, lockToml: lockToml,
               lockRecord: node{"lockRecord"}.getStr(""))

# ---------------------------------------------------------------------------
# Provenance of a fetched campaign (``design_review.fetch_campaign``).
# ---------------------------------------------------------------------------

proc strField(node: JsonNode; key: string): string =
  if node != nil and node.kind == JObject and node.hasKey(key):
    let v = node[key]
    case v.kind
    of JString: v.getStr
    of JNull: ""
    else: $v
  else: ""

proc intField(node: JsonNode; key: string): int =
  if node != nil and node.kind == JObject and node.hasKey(key):
    let v = node[key]
    case v.kind
    of JInt: v.getInt
    of JFloat: int(v.getFloat)
    of JString:
      try: parseInt(v.getStr) except ValueError: 0
    else: 0
  else: 0

proc parseCampaignProvenance*(campaign: JsonNode): CampaignProvenance =
  ## The provenance carried by a ``fetch_campaign`` document.  Never
  ## raises: a legacy row (``manifest_hash = "local"``, no ``rounds``) and
  ## a document from a pre-012 database (no ``rounds`` member at all)
  ## both yield a legacy-unpinned start and no round pins.
  result.startPin = campaign.strField("manifest_hash")
  result.startState = campaignPinState(result.startPin)
  result.roundsCompleted = campaign.intField("rounds_completed")
  if campaign != nil and campaign.kind == JObject and
      campaign.hasKey("rounds") and campaign["rounds"].kind == JArray:
    for r in campaign["rounds"]:
      if r.kind != JObject: continue
      result.rounds.add CampaignRoundPin(
        round: r.intField("round"),
        pin: r.strField("workspace_pin"),
        lockRecord: r.strField("lock_record"),
        startedBy: r.strField("started_by"),
        startedAt: r.strField("started_at"))

proc unpinnedRounds*(p: CampaignProvenance): int =
  ## Rounds the campaign ran before rounds were pinned: those numbered
  ## below its first recorded round, or every completed round when none
  ## is recorded.
  if p.rounds.len > 0: max(0, p.rounds[0].round - 1)
  else: p.roundsCompleted

proc describePin(value: string): string =
  case campaignPinState(value)
  of cpsPinned: value
  of cpsLegacyUnpinned:
    (if value.len > 0: value & " " else: "") & "(" & LegacyUnpinnedNote & ")"

proc renderCampaignProvenance*(p: CampaignProvenance): seq[string] =
  ## The provenance block of ``isonim-review campaign show``.
  result.add "start_pin:      " & describePin(p.startPin)
  if p.rounds.len == 0 and p.unpinnedRounds == 0:
    result.add "round_pins:     (no rounds yet)"
    return
  result.add "round_pins:"
  let legacy = p.unpinnedRounds
  if legacy > 0:
    result.add "  " & (if legacy == 1: "round 1" else: "rounds 1-" & $legacy) &
      ": (" & LegacyUnpinnedNote & ")"
  for r in p.rounds:
    var line = "  round " & $r.round & ": " & describePin(r.pin)
    var extra: seq[string]
    if r.startedAt.len > 0: extra.add r.startedAt
    if r.startedBy.len > 0: extra.add "by " & r.startedBy
    if r.lockRecord.len > 0: extra.add "lock record " & r.lockRecord
    if extra.len > 0: line.add "  [" & extra.join(", ") & "]"
    result.add line
