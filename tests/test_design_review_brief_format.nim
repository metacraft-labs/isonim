## REV-M1: Tests for ``isonim/editor/design_review/brief_format``.
##
## Test names match those listed in REV-M1's Verification block of
## ``codetracer-specs/Front-Ends/IsoNim/Design-Review-Database.milestones.org``
## verbatim.

import std/[unittest, os, tables, strutils]
import isonim/editor/design_review/brief_format
import isonim/editor/types

const FixtureDir = currentSourcePath().parentDir() / "fixtures" / "design_review"
const ValidDir = FixtureDir / "briefs_valid"
const InvalidDir = FixtureDir / "briefs_invalid"

suite "REV-M1 brief format":
  test "test_brief_parser_round_trips_minimal_frontmatter":
    ## A minimal valid brief (one preview, one viewport, one scoring
    ## dimension at weight 1.0) parses; re-serialising the resulting
    ## ``Brief`` via ``$`` produces byte-identical YAML for the
    ## round-tripped fields.
    let tmp = getTempDir() / "isonim_rev_m1_minimal.md"
    writeFile(tmp, """---
briefId: render.minimal
schemaVersion: 1
kind: render
title: Minimal Brief
coversPreviews:
  - storyRef: { group: "Minimal", name: "Solo", kind: page, index: 0 }
    backends: [web]
captureViewports:
  - { width: 800, height: 600, label: "tablet" }
reviewerSchemaVersion: 1
scoringDimensions:
  - { id: chrome, label: "Editor Chrome", weight: 1.0, scale: { min: 1, max: 10 } }
---

# Minimal
""")
    let b1 = parseBrief(tmp)
    check b1.briefId == "render.minimal"
    check b1.kind == bkRender

    # Re-serialise, re-parse, re-serialise — second projection must
    # equal first (idempotent canonical form).
    let s1 = $b1

    # Wrap in frontmatter delimiters and re-parse.
    let tmp2 = getTempDir() / "isonim_rev_m1_minimal_roundtrip.md"
    writeFile(tmp2, "---\n" & s1 & "---\n\n# Minimal\n")
    let b2 = parseBrief(tmp2)
    check $b1 == $b2
    check b1.briefId == b2.briefId
    check b1.kind == b2.kind
    check b1.coversPreviews == b2.coversPreviews
    check b1.captureViewports == b2.captureViewports
    check b1.scoringDimensions.len == b2.scoringDimensions.len
    for i in 0 ..< b1.scoringDimensions.len:
      check b1.scoringDimensions[i].id == b2.scoringDimensions[i].id
      check b1.scoringDimensions[i].weight == b2.scoringDimensions[i].weight
    removeFile(tmp)
    removeFile(tmp2)

  test "test_brief_parser_rejects_missing_briefid":
    let path = InvalidDir / "render" / "missing-briefid.md"
    var raised = false
    try:
      discard parseBrief(path)
    except MissingRequiredFieldError as e:
      raised = true
      check e.field == "briefId"
      check e.path == path
    check raised

  test "test_brief_parser_rejects_missing_coverspreviews":
    let path = InvalidDir / "render" / "missing-coverspreviews.md"
    var raised = false
    try:
      discard parseBrief(path)
    except MissingRequiredFieldError as e:
      raised = true
      check e.field == "coversPreviews"
      check e.path == path
    check raised

  test "test_brief_parser_rejects_mismatched_kind_and_path":
    let path = InvalidDir / "render" / "mismatched-kind.md"
    var raised = false
    try:
      discard parseBrief(path)
    except BriefKindMismatchError as e:
      raised = true
      # Error message must name both the filename and the declared kind.
      check "mismatched-kind.md" in e.msg
      check "interaction" in e.msg
    check raised

  test "test_brief_parser_rejects_unknown_backend":
    let path = InvalidDir / "render" / "unknown-backend.md"
    var raised = false
    try:
      discard parseBrief(path)
    except UnknownBackendError as e:
      raised = true
      check e.field == "backends"
    check raised

  test "test_brief_parser_rejects_scoring_weights_not_summing_to_one":
    let path = InvalidDir / "render" / "bad-weights.md"
    var raised = false
    try:
      discard parseBrief(path)
    except ScoringWeightSumError as e:
      raised = true
      # weights are 0.4 + 0.55 = 0.95 (±1e-6)
      check abs(e.actualSum - 0.95) < 1e-6
    check raised

  test "test_brief_parser_accepts_unknown_optional_fields":
    ## Unknown frontmatter keys (e.g. ``owner: foo``) preserved verbatim
    ## in ``Brief.extra["owner"] == "foo"``. Forward-compat invariant.
    let chromePath = ValidDir / "chrome" / "editor-sidebar.md"
    let b = parseBrief(chromePath)
    check "owner" in b.extra
    check b.extra["owner"] == "design-systems"

  test "test_canonical_preview_id_round_trip":
    ## For all ``(StoryRef, PreviewBackend)`` pairs in a 30-entry
    ## fixture (covers ASCII names, names with ``/``, ``@``, ``#``,
    ## unicode, ``index`` up to 999), ``decodePreviewId(
    ## canonicalPreviewId(s, b)) == (s, b)`` bytewise.
    let groups = ["Task App", "Path/With/Slash", "At@Email", "Hash#Tag",
                  "Plain", "Yōkai", "Mix/@#"]
    let names = ["Inbox", "Completed/Page", "User@Detail", "Step#1",
                 "Normal", "ünicode", "Combo/#@"]
    let kinds = [skPage, skComponent, skFlow, skPattern, skFoundation,
                 skGuideline, skVectorSymbol]
    let indices = [0, 1, 5, 42, 999]
    let backends = [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid, pbIos]

    var n = 0
    var failed = 0
    var i = 0
    while n < 30:
      let sref = StoryRef(
        group: groups[i mod groups.len],
        name:  names[(i div 3) mod names.len],
        kind:  kinds[(i div 5) mod kinds.len],
        index: indices[(i div 7) mod indices.len]
      )
      let be = backends[i mod backends.len]
      let s = canonicalPreviewId(sref, be)
      let decoded = decodePreviewId(s)
      if decoded.storyRef != sref or decoded.backend != be:
        echo "FAIL: ", s, " decoded=", decoded, " expected=(", sref, ", ", be, ")"
        inc failed
      inc n
      inc i
    check failed == 0
