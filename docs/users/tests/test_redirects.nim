## ../isonim/docs/users -- real content/ dir alias-redirect check
## (C-target only).
##
## Moved here from isonim-docs' own `tests/docs/test_redirects_renderroute.nim`
## (M1 corrective deliverable 4): proves this site's own real `content/`
## dir and `docsRouteManifest()` have no broken references, aliases
## included.

import std/[unittest, os]
import core/routes
import core/references

suite "docs references -- the real content/ dir corpus's aliases (Tier 3, C-target)":
  test "the real content/ dir and site manifest have no broken references, aliases included":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    validateContentGraph(repoRoot / "content", docsRouteManifest())
