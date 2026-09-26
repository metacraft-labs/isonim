## `complianceManifest` over a real `EditorWorkspace`.
##
## Separate from `compliance_manifest.nim` on purpose, and the separation is
## the point rather than tidiness. This module imports `isonim/editor/workspace`,
## which transitively pulls the streaming-preview runtime and its native
## adapters; a project that cannot compile that — because the check must run in
## seconds, or because the editor bundle is built with `nim js` and the emitter
## is native — uses the piecewise form instead and keeps this file out of its
## import graph.
##
## Prefer THIS form when it compiles. The piecewise form has to be TOLD whether
## an edit adapter exists, and D7 exists to catch exactly the case where what a
## project says about its edit contract and what it does are different things.
## Here the adapter is read off the workspace, so the question cannot be
## answered wrongly.

import std/json
import isonim/editor/types
import isonim/editor/workspace
import isonim/editor/compliance_manifest

export compliance_manifest

proc complianceManifestOf*(ws: EditorWorkspace): JsonNode =
  ## The manifest for an assembled workspace.
  ##
  ## `ws.editAdapter` is a `ref object`, so `isNil` is the whole test: the
  ## framework treats a nil adapter as "no edits can land", which is precisely
  ## what D7 compares against `permissions.writeSource`.
  complianceManifest(
    id = ws.id,
    title = ws.title,
    storyGroups = ws.storyGroups,
    foundationTokens = ws.foundationTokens,
    componentVariants = ws.componentVariants,
    schema = (if ws.editAdapter.isNil: @[] else: ws.editAdapter.schema),
    permissions = ws.permissions,
    hasEditAdapter = not ws.editAdapter.isNil,
    platform = ws.platform,
    allowedPlatforms = ws.allowedPlatforms)
