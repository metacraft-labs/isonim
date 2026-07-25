## ../isonim/docs/users -- real content/ dir auto-discovery check
## (C-target only).
##
## Moved here from isonim-docs' own
## `tests/docs/test_manifest_from_content_renderroute.nim` (M1 corrective
## deliverable 4): proves `buildManifestFromContent` walks this site's
## own real `content/` dir without crashing and binds every file.

import std/[unittest, os]
import core/content
import core/routes

suite "buildManifestFromContent -- the real content/ dir (Tier 3-ish, C-target)":
  test "walks the real, checked-in content/ directory without crashing and binds every file":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let manifest = buildManifestFromContent(repoRoot / "content")
    let realEntries = loadContentEntries(repoRoot / "content")
    check manifest.entries.len == realEntries.len
