## REV-M10 — verify the migrated render.task-app brief parses cleanly
## via the REV-M1 ``parseBrief`` and exposes the expected covers/backends.
##
## The migrated brief lives at
## ``isonim-examples/briefs/render/task-app.md``.  We resolve that path
## relative to this test file so the test works regardless of the
## checkout layout.

import std/[unittest, os, strutils]

import isonim/editor/design_review/brief_format
import isonim/editor/types

const MigratedBrief =
  currentSourcePath().parentDir().parentDir().parentDir() /
    "isonim-examples" / "briefs" / "render" / "task-app.md"

suite "REV-M10 migrated task-app brief":
  test "test_migrated_task_app_brief_parses":
    check fileExists(MigratedBrief)
    let b = parseBrief(MigratedBrief)

    check b.briefId == "render.task-app"
    check b.schemaVersion == 1
    check b.kind == bkRender
    check b.title.len > 0

    # Exactly one covered preview (the Inbox page), but covering all
    # 7 backends — so the canonical-preview-id projection yields 7
    # entries.
    check b.coversPreviews.len == 1
    let cov = b.coversPreviews[0]
    check cov.storyRef.group == "Task App / Pages"
    check cov.storyRef.name == "Inbox"
    check cov.storyRef.kind == skPage
    check cov.backends.len == 7

    # Verify all 7 backends are present.
    var seen: set[PreviewBackend]
    for backend in cov.backends:
      seen.incl backend
    check seen == {pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid, pbIos}

    # Scoring dimensions must sum to 1.0 (the parser enforces this,
    # but assert the shape too).
    check b.scoringDimensions.len == 2
    var sum = 0.0
    for d in b.scoringDimensions:
      sum += d.weight
    check abs(sum - 1.0) < 1e-6

    # captureViewports must be non-empty.
    check b.captureViewports.len >= 1

    # Body markdown is preserved verbatim (the legacy brief's body
    # was a multi-section markdown document).
    check "Visual Review Brief" in b.bodyMarkdown or
          "Reviewing" in b.bodyMarkdown or
          "What" in b.bodyMarkdown
