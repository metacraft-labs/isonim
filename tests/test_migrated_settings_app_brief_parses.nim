## REV-M10 — verify the migrated render.settings-app brief parses
## cleanly via REV-M1's ``parseBrief``.

import std/[unittest, os, strutils]

import isonim/editor/design_review/brief_format
import isonim/editor/types

const MigratedBrief =
  currentSourcePath().parentDir().parentDir().parentDir() /
    "isonim-examples" / "briefs" / "render" / "settings-app.md"

suite "REV-M10 migrated settings-app brief":
  test "test_migrated_settings_app_brief_parses":
    check fileExists(MigratedBrief)
    let b = parseBrief(MigratedBrief)

    check b.briefId == "render.settings-app"
    check b.schemaVersion == 1
    check b.kind == bkRender
    check b.title.len > 0

    # The Preferences page covers all 7 backends.
    check b.coversPreviews.len == 1
    let cov = b.coversPreviews[0]
    check cov.storyRef.group == "Settings App / Pages"
    check cov.storyRef.name == "Preferences"
    check cov.storyRef.kind == skPage
    check cov.backends.len == 7

    var seen: set[PreviewBackend]
    for backend in cov.backends:
      seen.incl backend
    check seen == {pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid, pbIos}

    var sum = 0.0
    for d in b.scoringDimensions:
      sum += d.weight
    check abs(sum - 1.0) < 1e-6

    check b.captureViewports.len >= 1
    check "Settings App" in b.bodyMarkdown or "Reviewing" in b.bodyMarkdown
