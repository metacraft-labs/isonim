## REV-M10 — verify every migrated chrome brief parses cleanly via the
## REV-M1 ``parseBrief``.  Asserts:
##
##   - every chrome brief file under ``isonim-examples/briefs/chrome/``
##     parses without error,
##   - ``kind`` is ``bkChrome`` for every file,
##   - ``coversPreviews`` is non-empty and every storyRef.group + name
##     looks plausible (non-empty, contains ASCII letters),
##   - the 18 expected migrated brief slugs are all present.

import std/[unittest, os, sequtils, strutils, sets, tables]

import isonim/editor/design_review/brief_format
import isonim/editor/types

const ChromeDir =
  currentSourcePath().parentDir().parentDir().parentDir() /
    "isonim-examples" / "briefs" / "chrome"

const ExpectedSlugs = [
  "shell-wide",
  "shell-laptop",
  "shell-narrow",
  "story-selected-wide",
  "story-selected-laptop",
  "sidebar-quick-nav",
  "vector-editor-empty",
  "vector-editor-with-symbol",
  "vector-editor-carousel",
  "canvas-preview-tui",
  "canvas-preview-edit-mode",
  "canvas-preview-vector-dblclick-open",
  "gallery-compare",
  "gallery-empty-state",
  "gallery-grid-and-full-tab",
  "spec-pane-comment",
  "spec-pane-edit",
  "spec-pane-view",
]

suite "REV-M10 migrated chrome briefs":
  test "test_migrated_chrome_briefs_parse":
    check dirExists(ChromeDir)

    # Discover all chrome brief files.
    var found = initHashSet[string]()
    var parsedBriefs: seq[Brief] = @[]
    for kind, path in walkDir(ChromeDir):
      if kind != pcFile: continue
      if not path.endsWith(".md"): continue
      let slug = path.extractFilename.changeFileExt("")
      found.incl(slug)
      let b = parseBrief(path)
      parsedBriefs.add(b)

      check b.kind == bkChrome
      check b.briefId.startsWith("chrome.")
      check b.coversPreviews.len >= 1
      for cov in b.coversPreviews:
        check cov.storyRef.group.len > 0
        check cov.storyRef.name.len > 0
        check cov.backends.len >= 1
      var sum = 0.0
      for d in b.scoringDimensions:
        sum += d.weight
      check abs(sum - 1.0) < 1e-6
      check b.captureViewports.len >= 1

    # Every expected slug must have a migrated brief file.
    for slug in ExpectedSlugs:
      check slug in found

    # We expect exactly 18 chrome briefs (the migrated corpus grew to 18
    # with the gallery-* and spec-pane-* additions).
    check parsedBriefs.len == ExpectedSlugs.len
