## ../isonim/docs/users -- completeness matrix suite (C-target only).
##
## Moved here from isonim-docs' own `tests/docs/test_completeness_renderroute.nim`
## + the `isonimCompletenessMatrix` suite of `test_completeness_vm.nim`
## (M1 corrective deliverable 4): `isonimCompletenessMatrix()` is this
## site's own data, not framework fixture data, so its coverage moved
## with it rather than staying pinned to a real content/ dir the
## framework no longer carries.

import std/[unittest, os]
import core/content
import core/routes
import core/completeness
import ../src/docs_config

suite "completeness -- isonimCompletenessMatrix names every M4 deliverable-2 topic exactly once (Tier 1)":
  test "the matrix has one entry per named deliverable-2 topic, each with its own route and non-empty heading/word requirements":
    let matrix = isonimCompletenessMatrix()
    check matrix.len == 8
    var seenTopics: seq[string] = @[]
    var seenRoutes: seq[string] = @[]
    for req in matrix:
      check req.topic notin seenTopics
      check req.routePath notin seenRoutes
      check req.requiredHeadings.len >= 2
      check req.minWordCount > 0
      seenTopics.add req.topic
      seenRoutes.add req.routePath

suite "completeness -- the real content/ dir satisfies every M4 deliverable-2 topic (Tier 3, C-target)":
  test "checkCompleteness against the real content/ dir and the real site manifest reports no issues":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let manifest = docsRouteManifest()
    let issues = checkCompleteness(isonimCompletenessMatrix(), manifest,
      proc(contentPath: string): ContentEntry = loadContentEntry(contentDir, contentPath))
    check issues.len == 0
    for issue in issues:
      echo "completeness issue: ", issue
