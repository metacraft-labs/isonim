## REV-M5 follow-up (2026-10-10) — campaign start and round pins.
##
## A campaign pins its start, and every round pins its own state, with the
## very step a capture run uses (``workspace_gate.pinCleanWorkspace``).
## Pure tests cover the wire format the CLI sends the daemon and the
## provenance ``campaign show`` prints — including campaigns written before
## migration 012, whose start "pin" is the placeholder ``"local"``.  The
## pinning tests build hermetic reprobuild workspaces
## (``helpers/repro_workspace_fixture``) and read them through ``repro``;
## they never touch the developer's workspace or any record store.

import std/[json, os, strutils, unittest]

import isonim/editor/design_review/campaign_pin
import isonim/editor/design_review/workspace_gate

import helpers/repro_workspace_fixture

const ShaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const ShaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

proc lockOf(revision: string; scope = ProjectScope): WorkspaceLock =
  WorkspaceLock(project: "isonim", scope: scope, repos: @[
    LockedRepo(name: "isonim", path: "isonim", remote: "origin",
               revision: revision)])

proc pinOfLock(lock: WorkspaceLock; lockRecord = ""): WorkspacePin =
  let toml = renderCanonicalLock(lock)
  WorkspacePin(pin: pinOf(toml), lockToml: toml, lockRecord: lockRecord)

proc pinnedCampaign(): JsonNode =
  let a = pinOfLock(lockOf(ShaA))
  let b = pinOfLock(lockOf(ShaB), "isonim/isonim@" & ShaB)
  %*{
    "campaign_id": "00000000-0000-0000-0000-000000000001",
    "manifest_hash": a.pin,
    "status": "active",
    "rounds_completed": 1,
    "rounds": [
      {"round": 1, "workspace_pin": a.pin, "lock_record": nil,
       "started_by": "alice", "started_at": "2026-10-10T10:00:00+00:00"},
      {"round": 2, "workspace_pin": b.pin, "lock_record": b.lockRecord,
       "started_by": "alice", "started_at": "2026-10-10T11:00:00+00:00"}],
  }

suite "campaign pins — wire format":

  test "test_workspace_pin_json_round_trips_and_is_verified":
    let pin = pinOfLock(lockOf(ShaA), "isonim/isonim@" & ShaA)
    let back = parseWorkspacePinJson(workspacePinJson(pin))
    check back.pin == pin.pin
    check back.lockToml == pin.lockToml
    check back.lockRecord == pin.lockRecord

  test "test_workspace_pin_json_refuses_placeholders_and_forgeries":
    let good = pinOfLock(lockOf(ShaA))
    let other = pinOfLock(lockOf(ShaB))
    let wrongScope = pinOfLock(lockOf(ShaA, scope = "workspace"))
    let bad = @[
      newJNull(),
      newJObject(),
      # The pre-012 placeholder, alone and with a real record.
      %*{"pin": "local"},
      %*{"pin": "local", "lockToml": good.lockToml},
      # A record that is not the one the pin names.
      %*{"pin": good.pin, "lockToml": other.lockToml},
      # A record edited after it was hashed.
      %*{"pin": good.pin,
         "lockToml": good.lockToml.replace(ShaA, ShaB)},
      # A record not in canonical form (CRLF).
      %*{"pin": pinOf(good.lockToml.replace("\n", "\r\n")),
         "lockToml": good.lockToml.replace("\n", "\r\n")},
      # A pin that does not cover one reprobuild project.
      workspacePinJson(wrongScope)]
    for node in bad:
      expect WorkspacePinError:
        discard parseWorkspacePinJson(node)

suite "campaign pins — provenance":

  test "test_pinned_campaign_shows_start_pin_and_every_round_pin":
    let p = parseCampaignProvenance(pinnedCampaign())
    let a = pinOfLock(lockOf(ShaA))
    let b = pinOfLock(lockOf(ShaB))
    check p.startPin == a.pin
    check p.startState == cpsPinned
    check p.rounds.len == 2
    check p.rounds[0].round == 1 and p.rounds[0].pin == a.pin
    check p.rounds[1].round == 2 and p.rounds[1].pin == b.pin
    check p.rounds[1].lockRecord == "isonim/isonim@" & ShaB
    check p.unpinnedRounds == 0
    let text = renderCampaignProvenance(p).join("\n")
    check ("start_pin:      " & a.pin) in text
    check ("  round 1: " & a.pin) in text
    check ("  round 2: " & b.pin) in text
    check ("lock record isonim/isonim@" & ShaB) in text
    check "legacy" notin text

  test "test_legacy_local_campaign_loads_as_legacy_unpinned":
    # A row written before migration 012: the CLI sent "local", and a
    # pre-012 ``fetch_campaign`` has no ``rounds`` / ``rounds_completed``.
    let legacy = %*{"campaign_id": "00000000-0000-0000-0000-000000000002",
                    "manifest_hash": "local", "status": "failed"}
    let p = parseCampaignProvenance(legacy)
    check p.startPin == "local"
    check p.startState == cpsLegacyUnpinned
    check p.rounds.len == 0
    check p.unpinnedRounds == 0
    let text = renderCampaignProvenance(p).join("\n")
    check ("start_pin:      local (" & LegacyUnpinnedNote & ")") in text
    check "round_pins:     (no rounds yet)" in text
    # The same row through a post-012 ``fetch_campaign``.
    legacy["rounds"] = newJArray()
    legacy["rounds_completed"] = %2
    let q = parseCampaignProvenance(legacy)
    check q.startState == cpsLegacyUnpinned
    check q.unpinnedRounds == 2
    check ("  rounds 1-2: (" & LegacyUnpinnedNote & ")") in
      renderCampaignProvenance(q).join("\n")

  test "test_legacy_campaign_rounds_after_migration_are_pinned":
    # A legacy campaign restarted after 012: rounds 1-2 ran unpinned, round
    # 3 has a pin; the start stays legacy (start pins are never rewritten).
    let a = pinOfLock(lockOf(ShaA))
    let node = %*{"manifest_hash": "local", "rounds_completed": 3,
                  "rounds": [{"round": 3, "workspace_pin": a.pin}]}
    let p = parseCampaignProvenance(node)
    check p.startState == cpsLegacyUnpinned
    check p.unpinnedRounds == 2
    let lines = renderCampaignProvenance(p)
    check lines[0] == "start_pin:      local (" & LegacyUnpinnedNote & ")"
    check lines[1] == "round_pins:"
    check lines[2] == "  rounds 1-2: (" & LegacyUnpinnedNote & ")"
    check lines[3] == "  round 3: " & a.pin

  test "test_provenance_never_raises_on_odd_documents":
    for node in [JsonNode(nil), newJNull(), newJArray(), newJObject(),
                 %*{"manifest_hash": 7, "rounds": "x",
                    "rounds_completed": "two"},
                 %*{"manifest_hash": nil,
                    "rounds": [1, nil, {"round": "4", "workspace_pin": 5}]}]:
      let p = parseCampaignProvenance(node)
      check p.startState == cpsLegacyUnpinned
      check renderCampaignProvenance(p).len >= 2

  test "test_only_workspace_locks_count_as_pinned":
    check campaignPinState(pinOfLock(lockOf(ShaA)).pin) == cpsPinned
    for v in ["", "local", "test:fixture", "seeded:x", ShaA & ShaA[0 ..< 24],
              WorkspacePinPrefix & "XYZ"]:
      check campaignPinState(v) == cpsLegacyUnpinned

suite "campaign pins — pinning the workspace (reprobuild fixture)":

  test "test_campaign_pin_is_the_capture_pin_of_a_clean_workspace":
    let ws = newReproWorkspace("cpin_clean", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    let pin = pinCleanWorkspace(ws.root)
    check campaignPinState(pin.pin) == cpsPinned
    # The same step capture takes: same observation, same record.
    check pin.pin == captureWorkspacePin(ws.root).pin
    let lock = resolvePin(pin.pin, pin.lockToml)
    check lock.project == DesignReviewProject
    check lock.repos.len == 2
    check lock.repos[0].revision == ws.headSha("repo-a")
    check parseWorkspacePinJson(workspacePinJson(pin)).pin == pin.pin

  test "test_campaign_start_refuses_a_dirty_workspace":
    let ws = newReproWorkspace("cpin_dirty", ["repo-a"])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / "README.md", "edited\n")
    writeFile(ws.repoDir("repo-a") / "new.txt", "untracked\n")
    var refused = false
    try:
      discard pinCleanWorkspace(ws.root)
    except WorkspaceNotPinnableError as e:
      refused = true
      var reasons: seq[DirtyRepoReason]
      for r in e.dirty: reasons.add r.reason
      check drUncommitted in reasons
      check drUntracked in reasons
      var text = ""
      for r in e.dirty: text.add formatDirtyReport(r, pinOwner = "campaign")
      check "README.md" in text
      check "new.txt" in text
    check refused

  test "test_campaign_round_refuses_an_unpublished_head":
    let ws = newReproWorkspace("cpin_unpub", ["repo-a"])
    defer: ws.cleanup()
    let local = ws.commit("repo-a", "not pushed", [("x.txt", "x\n")])
    var refused = false
    try:
      discard pinCleanWorkspace(ws.root)
    except WorkspaceNotPinnableError as e:
      refused = true
      check e.dirty.len == 1
      check e.dirty[0].reason == drUnpublishedHead
      check e.dirty[0].headSha == local
      check "push it so the campaign's pin can be replayed elsewhere" in
        formatDirtyReport(e.dirty[0], pinOwner = "campaign")
    check refused
    # Once pushed, the same state pins.
    ws.publish("repo-a")
    let pin = pinCleanWorkspace(ws.root)
    check resolvePin(pin.pin, pin.lockToml).repos[0].revision == local

  test "test_each_round_pins_the_state_it_starts_from":
    let ws = newReproWorkspace("cpin_rounds", ["repo-a"])
    defer: ws.cleanup()
    let start = pinCleanWorkspace(ws.root)
    let next = ws.commitAndPublish("repo-a", "round 1 fix", [("fix.txt", "1\n")])
    let round2 = pinCleanWorkspace(ws.root)
    check start.pin != round2.pin
    check resolvePin(round2.pin, round2.lockToml).repos[0].revision == next
    check resolvePin(start.pin, start.lockToml).repos[0].revision != next
