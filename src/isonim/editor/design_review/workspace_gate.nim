## The clean-tree gate and the workspace pin as one step.
##
## Everything the design review records against a source state — a
## capture run (``capture.nim``), a campaign's start and each of its
## rounds (``isonim-review campaign start``) — obtains its pin here, so
## they all refuse the same states and pin the same way:
##
##   1. ``checkCleanTree`` observes the reprobuild project through
##      ``repro workspace status`` / ``list`` and refuses uncommitted
##      paths, untracked files, HEADs that are not on the declared remote,
##      and workspaces reprobuild cannot read.
##   2. ``captureWorkspacePin`` renders *that same observation* as the
##      canonical lock record and hashes it, refusing unpublished state a
##      second time.
##
## A state that cannot be pinned is refused, never recorded as
## "unpinned": a stored pin must replay on any machine that can fetch the
## repos.  Nothing is locked or published as a side effect.

import std/strutils

import ./clean_tree
import ./workspace_pin

export clean_tree, workspace_pin

type
  WorkspaceNotPinnableError* = object of CatchableError
    dirty*: seq[DirtyRepoReport]
      ## What the clean-tree gate refused.  Empty when the gate passed
      ## but the pin itself was refused (the message says why).

proc pinCleanWorkspace*(workspaceRoot: string;
                        project = DesignReviewProject): WorkspacePin =
  ## Gate ``project`` in the workspace at ``workspaceRoot`` and pin the
  ## observation the gate accepted.  Raises ``WorkspaceNotPinnableError``.
  let status = checkCleanTree(workspaceRoot, project)
  if not status.ok:
    var err = newException(WorkspaceNotPinnableError, "workspace is not clean")
    err.dirty = status.dirty
    raise err
  # Pin the very observation the gate accepted: a second look at the
  # workspace could see a different state than the one just gated.
  try:
    captureWorkspacePin(status.observation)
  except WorkspacePinError as e:
    raise newException(WorkspaceNotPinnableError,
      "cannot pin the workspace: " & e.msg)

proc dirtyReasonLabel*(r: DirtyRepoReason): string =
  case r
  of drUncommitted: "uncommitted changes"
  of drUntracked:   "untracked files"
  of drUnpublishedHead: "HEAD is not on the declared remote"
  of drWorkspaceUnreadable: "workspace unreadable"

proc formatDirtyReport*(report: DirtyRepoReport; pinOwner = "run"): string =
  ## One line per refused repo, naming every offending path, for the CLI.
  ## ``pinOwner`` names what the pin belongs to ("run", "campaign").
  result = report.repoPath & ": " & dirtyReasonLabel(report.reason)
  if report.files.len > 0:
    result.add " ("
    result.add report.files.join(", ")
    result.add ")"
  case report.reason
  of drUnpublishedHead:
    result.add " [HEAD=" & report.headSha & "; push it so the " & pinOwner &
               "'s pin can be replayed elsewhere"
    if report.detail.len > 0: result.add "; " & report.detail
    result.add "]"
  of drWorkspaceUnreadable:
    result.add " [" & report.detail & "]"
  else: discard
