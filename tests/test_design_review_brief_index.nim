## REV-M1: Tests for ``isonim/editor/design_review/brief_index``.
##
## Test names match REV-M1's Verification block verbatim.

import std/[unittest, os, tables, sequtils, strutils, algorithm, times]
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index

const FixtureDir = currentSourcePath().parentDir() / "fixtures" / "design_review"
const ValidDir = FixtureDir / "briefs_valid"

# --- Helpers --- #

proc makeBrief(path: string; briefId, kind, title: string;
               coversPreviews: string;
               extraScoring: string = ""): void =
  ## Write a fresh brief file at ``path`` with the supplied frontmatter
  ## fragments.  The ``coversPreviews`` argument is dropped verbatim
  ## (already indented).
  let scoring =
    if extraScoring.len == 0:
      "  - { id: chrome, label: \"Chrome\", weight: 1.0, scale: { min: 1, max: 10 } }"
    else:
      extraScoring
  createDir(parentDir(path))
  writeFile(path, """---
briefId: """ & briefId & """

schemaVersion: 1
kind: """ & kind & """

title: """ & title & """

coversPreviews:
""" & coversPreviews & """

captureViewports:
  - { width: 800, height: 600, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
""" & scoring & """

---

# """ & title & """

Body.
""")

proc tmpDir(label: string): string =
  let t = getTempDir() / ("isonim_revm1_" & label & "_" & $epochTime().int)
  removeDir(t)
  createDir(t)
  t

# --- Tests --- #

suite "REV-M1 brief index":
  test "test_brief_index_walks_tree_deterministic":
    ## Walk a fixture dir with 5 briefs whose filesystem-listing order
    ## is non-alphabetical (created via touch in reverse order);
    ## ``idx.byBriefId.keys.toSeq`` comes out alphabetically sorted by
    ## briefId across 10 successive walks.
    let dir = tmpDir("deterministic")
    let ids = ["render.zeta", "render.yankee", "render.echo",
               "render.bravo", "render.alpha"]
    # Create in non-alphabetical order; filesystem listing order
    # often mirrors creation order on darwin's APFS.
    for i, id in ids:
      let path = dir / "render" / (id & ".md")
      makeBrief(path, id, "render", id,
                "  - storyRef: { group: \"G\", name: \"N" & $i &
                "\", kind: page, index: 0 }\n    backends: [web]")
      # Touch each with a later mtime so creation order is captured.
      let now = epochTime() + i.float
      discard execShellCmd("touch -t $1 \"$2\"" %
        [getDateStr().replace("-", "") & "0000.0" & $i, path])
      discard now

    # Run the walker 10 times; every run must yield the same
    # alphabetical key order.
    let expected = sorted(ids)
    for run in 0 ..< 10:
      let idx = buildBriefIndex(dir)
      let keys = toSeq(idx.byBriefId.keys)
      check keys == expected
    removeDir(dir)

  test "test_brief_index_inverts_coverspreviews_correctly":
    ## One brief covering 3 previews populates ``byPreview`` with
    ## exactly 3 entries; each entry's ``briefIds`` sequence contains
    ## the originating briefId exactly once.
    let dir = tmpDir("inverts")
    makeBrief(dir / "render" / "multi.md", "render.multi", "render",
              "Multi Cover",
              "  - storyRef: { group: \"G\", name: \"A\", kind: page, index: 0 }\n" &
              "    backends: [web]\n" &
              "  - storyRef: { group: \"G\", name: \"B\", kind: page, index: 0 }\n" &
              "    backends: [web]\n" &
              "  - storyRef: { group: \"G\", name: \"C\", kind: page, index: 0 }\n" &
              "    backends: [web]")
    let idx = buildBriefIndex(dir)
    check idx.byBriefId.len == 1
    check idx.byPreview.len == 3
    for previewId, briefIds in idx.byPreview.pairs:
      check briefIds.count("render.multi") == 1
      check briefIds.len == 1
    removeDir(dir)

  test "test_brief_index_handles_one_preview_covered_by_two_briefs":
    ## Two valid briefs both name the same preview
    ## ``Task App/Inbox#0@web`` in their ``coversPreviews``;
    ## ``byPreview["Task App/Inbox:page#0@web"].len == 2``; ordering is
    ## alphabetical by briefId.
    let dir = tmpDir("shared")
    let covers =
      "  - storyRef: { group: \"Task App\", name: \"Inbox\", kind: page, index: 0 }\n" &
      "    backends: [web]"
    makeBrief(dir / "render" / "zebra.md", "render.zebra", "render", "Zebra", covers)
    makeBrief(dir / "render" / "alpha.md", "render.alpha", "render", "Alpha", covers)
    let idx = buildBriefIndex(dir)
    check idx.byBriefId.len == 2
    let previewId = canonicalPreviewId(
      StoryRef(group: "Task App", name: "Inbox", kind: skPage, index: 0),
      pbWeb)
    check previewId in idx.byPreview
    check idx.byPreview[previewId].len == 2
    # Alphabetical ordering — alpha before zebra.
    check idx.byPreview[previewId] == @["render.alpha", "render.zebra"]
    removeDir(dir)

  test "test_brief_index_reports_duplicate_briefid":
    ## Two briefs declaring ``briefId: render.task-app`` excluded from
    ## ``byBriefId``; ``idx.errors.len == 1`` (one error message naming
    ## both paths, recorded against each duplicate path);
    ## error message names both file paths.
    let dir = tmpDir("dup")
    let pathA = dir / "render" / "a.md"
    let pathB = dir / "render" / "b.md"
    makeBrief(pathA, "render.task-app", "render", "Task App A",
              "  - storyRef: { group: \"G\", name: \"N\", kind: page, index: 0 }\n    backends: [web]")
    makeBrief(pathB, "render.task-app", "render", "Task App B",
              "  - storyRef: { group: \"G\", name: \"N\", kind: page, index: 1 }\n    backends: [web]")
    let idx = buildBriefIndex(dir)
    check "render.task-app" notin idx.byBriefId
    # At least one error; messages must name both file paths.
    check idx.errors.len >= 1
    var foundCombined = false
    for e in idx.errors:
      if "a.md" in e.message and "b.md" in e.message:
        foundCombined = true
    check foundCombined
    removeDir(dir)

  test "test_brief_index_records_parse_errors_without_raising":
    ## One valid brief + one broken brief in the same dir;
    ## ``buildBriefIndex`` returns a populated index with
    ## ``byBriefId.len == 1`` and ``errors.len == 1``; no exception
    ## bubbles.
    let dir = tmpDir("mixed")
    # Valid brief.
    makeBrief(dir / "render" / "good.md", "render.good", "render", "Good",
              "  - storyRef: { group: \"G\", name: \"N\", kind: page, index: 0 }\n    backends: [web]")
    # Broken brief — missing briefId.
    createDir(dir / "render")
    writeFile(dir / "render" / "broken.md", """---
schemaVersion: 1
kind: render
title: Broken
coversPreviews:
  - storyRef: { group: "G", name: "N", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 800, height: 600, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome, label: "Chrome", weight: 1.0, scale: { min: 1, max: 10 } }
---

Body.
""")
    var raised = false
    var idx: BriefIndex
    try:
      idx = buildBriefIndex(dir)
    except CatchableError:
      raised = true
    check not raised
    check idx.byBriefId.len == 1
    check idx.errors.len == 1
    removeDir(dir)

  test "buildBriefIndex_on_valid_fixtures_indexes_three_briefs":
    ## Helper sanity check on the canonical valid fixtures.
    let idx = buildBriefIndex(ValidDir)
    check idx.byBriefId.len == 3
    check idx.errors.len == 0
    let keys = toSeq(idx.byBriefId.keys)
    check keys == @["chrome.editor-sidebar", "interaction.task-add-flow",
                    "render.task-app"]

  test "empty_proc_is_true_for_index_with_no_briefs":
    let dir = tmpDir("empty")
    let idx = buildBriefIndex(dir)
    check idx.empty()
    removeDir(dir)
