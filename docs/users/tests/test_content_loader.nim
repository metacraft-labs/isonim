## ../isonim/docs/users -- real content/ dir content-loader check
## (C-target only).
##
## Moved here from isonim-docs' own `tests/docs/test_content_loader.nim`
## (M1 corrective deliverable 4): proves `loadContentEntries` works
## unchanged against this site's own real, checked-in `content/` dir.

import std/[unittest, os, sequtils]
import core/content

suite "docs content loader -- the real content/ dir (Tier 3-ish, C-target)":
  test "loadContentEntries loads the real, checked-in content/ directory":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let entries = loadContentEntries(repoRoot / "content")
    check entries.len == 12
    for entry in entries:
      check entry.page.title.len > 0
      check entry.source.path.len > 0
    check entries.anyIt(it.slug == "index" and it.routePath == "/")
    check entries.anyIt(it.slug == "getting-started")
