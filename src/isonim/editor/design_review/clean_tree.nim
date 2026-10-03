## REV-M5 — workspace clean-tree gate.
##
## A design-review run is only worth keeping if it can be replayed
## against the exact source it was captured from, so capture refuses to
## start unless every repo in the workspace is in a state the workspace
## pin (``workspace_pin.nim``) can describe *and* somebody else can
## obtain.  Each materialized repo of the design review's reprobuild
## project (``isonim`` by default — its ``projects/isonim.toml`` members,
## not the whole active project set, so an unrelated project's state can
## never block a capture) is checked for:
##
##   1. Uncommitted changes — the pinned revision would not reproduce
##      what was captured.
##   2. Untracked files — same reason; an untracked brief or asset
##      changes the render without changing any revision.
##   3. A HEAD that is not on the repo's *declared* remote — the pin would
##      name a commit only this machine (or some fork) has.  This is
##      reprobuild's own publication rule (the pre-push gate's
##      ``unpublished`` stage: every member's HEAD must be reachable from
##      a remote-tracking ref), applied for the same reason — a recorded
##      pin must only refer to source states other people can actually
##      obtain — and narrowed to the remote the manifest declares, since
##      that is where anybody replaying the pin will fetch from
##      (``workspace_observation.checkDeclaredRemotePublication``).
##
## Membership and per-repo state come from reprobuild
## (``workspace_observation.nim``); this module only turns them into a
## verdict.  Declared repos with no checkout are not dirty — they are
## not part of what was captured, and the pin records them as
## unmaterialized, exactly as a reprobuild lock record does.
##
## *Never raises* — a workspace reprobuild cannot observe surfaces as a
## ``drWorkspaceUnreadable`` report, so callers can tell "could not look"
## from "looked, and it is clean".

import std/[os, strutils]

import ./workspace_observation

export workspace_observation

type
  DirtyRepoReason* = enum
    drUncommitted         ## modified / staged / conflicted paths
    drUntracked           ## files present but not under version control
    drUnpublishedHead     ## HEAD is on no remote-tracking ref of the declared remote
    drWorkspaceUnreadable ## reprobuild could not observe the workspace or repo

  DirtyRepoReport* = object
    repoPath*: string
      ## Absolute checkout path; the workspace root for a
      ## workspace-level ``drWorkspaceUnreadable``.
    reason*: DirtyRepoReason
    files*: seq[string]
      ## Populated for ``drUncommitted`` and ``drUntracked``.  One
      ## entry per path (relative to ``repoPath``).
    headSha*: string
      ## Populated for ``drUnpublishedHead`` — the unpublished HEAD.
    detail*: string
      ## Populated for ``drWorkspaceUnreadable`` — what went wrong — and,
      ## when known, for ``drUnpublishedHead`` (e.g. no git remote points
      ## at the declared remote).

  CleanTreeStatus* = object
    ok*: bool
    dirty*: seq[DirtyRepoReport]
    observation*: WorkspaceObservation
      ## What reprobuild reported.  Capture derives the pin from this
      ## same observation, so the gate and the pin can never disagree
      ## about the state they describe.

proc checkCleanTree*(obs: WorkspaceObservation): CleanTreeStatus =
  ## Gate verdict for an existing observation.
  result = CleanTreeStatus(ok: true, observation: obs)
  template flag(report: DirtyRepoReport) =
    result.dirty.add report
    result.ok = false
  var materialized = 0
  for repo in obs.repos:
    if not repo.materialized: continue
    inc materialized
    let absPath = obs.workspaceRoot / repo.path
    if repo.headSha.len == 0:
      flag DirtyRepoReport(repoPath: absPath, reason: drWorkspaceUnreadable,
        detail: "reprobuild could not read HEAD" &
          (if repo.diagnostic.len > 0: ": " & repo.diagnostic else: ""))
      continue
    if repo.uncommitted.len > 0:
      flag DirtyRepoReport(repoPath: absPath, reason: drUncommitted,
                           files: repo.uncommitted)
    if repo.untracked.len > 0:
      flag DirtyRepoReport(repoPath: absPath, reason: drUntracked,
                           files: repo.untracked)
    if not repo.isPublished:
      flag DirtyRepoReport(repoPath: absPath, reason: drUnpublishedHead,
                           headSha: repo.headSha,
                           detail: repo.publicationDetail)
  if materialized == 0:
    flag DirtyRepoReport(repoPath: obs.workspaceRoot,
      reason: drWorkspaceUnreadable,
      detail: "reprobuild reports no checked-out repo in project '" &
        obs.project & "'; there is nothing to pin")

proc checkCleanTree*(workspaceRoot: string;
                     project = DesignReviewProject): CleanTreeStatus =
  ## Observe ``project`` in the workspace at ``workspaceRoot`` through
  ## reprobuild and gate it.  Returns ``ok: true`` only when every
  ## materialized repo of the project is clean, has no untracked files,
  ## and has a published HEAD.  Never raises.
  try:
    result = checkCleanTree(observeWorkspace(workspaceRoot, project))
  except CatchableError as e:
    result = CleanTreeStatus(ok: false, dirty: @[DirtyRepoReport(
      repoPath: workspaceRoot, reason: drWorkspaceUnreadable,
      detail: e.msg.strip())])
