## REV-M6 — reviewer-output parser tests.
##
## Pure unit tests against the in-memory parser; no DB, no subprocess.
## Each test writes a fixture markdown to a tmpdir, constructs a
## ``Brief`` value directly, and exercises the parser's validation
## paths.

import std/[json, os, strutils, times, unittest]

import isonim/editor/design_review/brief_format
import isonim/editor/design_review/reviewer_output
import isonim/editor/types

# --------------------------------------------------------------------------- #
#  Brief fixture (shared across tests).
# --------------------------------------------------------------------------- #

proc fixtureBrief(): Brief =
  result.briefId       = "render.task-app"
  result.schemaVersion = 1
  result.kind          = bkRender
  result.title         = "Task App"
  result.coversPreviews = @[
    BriefPreviewCoverage(
      storyRef: StoryRef(group: "Task App", name: "Inbox",
                         kind: skPage, index: 0),
      backends: @[pbWeb, pbAndroid]),
  ]
  result.captureViewports = @[
    BriefViewport(width: 1080, height: 720, label: "tablet"),
  ]
  result.reviewerSchemaVersion = 1
  result.scoringDimensions = @[
    BriefScoringDimension(id: "chrome", label: "Chrome",
                          weight: 0.5, scaleMin: 1, scaleMax: 10),
    BriefScoringDimension(id: "rendering", label: "Rendering",
                          weight: 0.5, scaleMin: 1, scaleMax: 10),
  ]

proc previewIdWeb(brief: Brief): string =
  canonicalPreviewId(brief.coversPreviews[0].storyRef, pbWeb)
proc previewIdAndroid(brief: Brief): string =
  canonicalPreviewId(brief.coversPreviews[0].storyRef, pbAndroid)

proc tmpFile(name, contents: string): string =
  result = getTempDir() / ("isonim_rev_out_" & $epochTime().int & "_" & name)
  writeFile(result, contents)

# --------------------------------------------------------------------------- #
#  Fixture builder.  We assemble the markdown bytewise so the YAML keys
#  for ``previews.<canonical-preview-id>`` can be quoted to survive the
#  brief-format YAML parser's bareword key handling — the canonical
#  preview id contains ``:`` and ``#`` which would otherwise split the
#  key prematurely.
# --------------------------------------------------------------------------- #

proc previewBlock(previewId, scores, status: string;
                  defects: string = "[]"): string =
  result = "  \"" & previewId & "\":\n"
  result.add "    scores: " & scores & "\n"
  result.add "    status: " & status & "\n"
  if defects == "[]":
    result.add "    defects: []\n"
  else:
    result.add "    defects:\n"
    result.add defects

proc frontmatter(overall, previewsBlock: string;
                 notes = ""): string =
  result = "---\n"
  result.add "reviewerSchemaVersion: 1\n"
  result.add "briefId: render.task-app\n"
  result.add "runId: 0192f3a6-0000-0000-0000-000000000000\n"
  result.add "agentName: claude-opus-4-7\n"
  result.add "agentVersion: review-prompt-v3\n"
  result.add "manifestHash: 7c1e9aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"
  result.add "capturedAt: 2026-05-19T11:32:04Z\n"
  if overall.len > 0:
    result.add overall
  result.add "previews:\n"
  result.add previewsBlock
  if notes.len > 0:
    result.add notes
  result.add "---\n"
  result.add "\n# Round review\n\nWeb is clean.  Android is broken.\n"

# --------------------------------------------------------------------------- #
#  Tests.
# --------------------------------------------------------------------------- #

suite "REV-M6 reviewer output parser":

  test "test_reviewer_output_parser_accepts_valid_frontmatter":
    let brief = fixtureBrief()
    let webId = previewIdWeb(brief)
    let androidId = previewIdAndroid(brief)
    let defects =
      "      - id: stretched-aspect\n" &
      "        summary: Phone framebuffer rendered at landscape aspect.\n" &
      "        severity: blocker\n" &
      "        evidence: \"task-app android png 0 0 1080 720\"\n"
    let body =
      previewBlock(webId, "{ chrome: 8, rendering: 9 }", "pass") &
      previewBlock(androidId, "{ chrome: 8, rendering: 6 }", "warn",
                   defects)
    let overall = "overall:\n  score: 7.6\n  status: warn\n"
    let notes = "notes: \"Cross-backend consistency held except Android.\"\n"
    let raw = frontmatter(overall, body, notes)
    let path = tmpFile("valid.md", raw)
    defer: removeFile(path)
    let parsed = parseReviewerOutput(path, brief)
    check parsed.reviewerSchemaVersion == 1
    check parsed.briefId == "render.task-app"
    check parsed.runId == "0192f3a6-0000-0000-0000-000000000000"
    check parsed.agentName == "claude-opus-4-7"
    check parsed.agentVersion == "review-prompt-v3"
    check parsed.overall.score == 7.6
    check parsed.overall.status == "warn"
    check parsed.previews.len == 2
    check parsed.bodyMarkdown.contains("Web is clean")
    check parsed.notes.contains("Cross-backend")

    # JSONB projection — verify the shape matches the documented contract.
    let jsonb = toParsedScoresJsonb(parsed)
    check jsonb["schemaVersion"].getInt == 1
    check jsonb["overall"]["score"].getFloat == 7.6
    check jsonb["overall"]["status"].getStr == "warn"
    check jsonb["previews"][webId]["status"].getStr == "pass"
    check jsonb["previews"][webId]["scores"]["chrome"].getInt == 8
    check jsonb["previews"][webId]["scores"]["rendering"].getInt == 9
    check jsonb["previews"][webId]["defects"].len == 0
    check jsonb["previews"][androidId]["status"].getStr == "warn"
    check jsonb["previews"][androidId]["defects"].len == 1
    check jsonb["previews"][androidId]["defects"][0]["id"].getStr == "stretched-aspect"
    check jsonb["previews"][androidId]["defects"][0]["severity"].getStr == "blocker"

  test "test_reviewer_output_parser_rejects_missing_overall":
    let brief = fixtureBrief()
    let webId = previewIdWeb(brief)
    let androidId = previewIdAndroid(brief)
    let body =
      previewBlock(webId, "{ chrome: 8, rendering: 9 }", "pass") &
      previewBlock(androidId, "{ chrome: 8, rendering: 6 }", "warn")
    let raw = frontmatter("", body)
    let path = tmpFile("nooverall.md", raw)
    defer: removeFile(path)
    expect MissingScoreError:
      discard parseReviewerOutput(path, brief)
    try:
      discard parseReviewerOutput(path, brief)
    except MissingScoreError as e:
      check "overall" in e.msg

  test "test_reviewer_output_parser_rejects_score_outside_scale":
    let brief = fixtureBrief()
    let webId = previewIdWeb(brief)
    let androidId = previewIdAndroid(brief)
    let body =
      previewBlock(webId, "{ chrome: 12, rendering: 9 }", "pass") &
      previewBlock(androidId, "{ chrome: 8, rendering: 6 }", "warn")
    let overall = "overall:\n  score: 9.0\n  status: pass\n"
    let raw = frontmatter(overall, body)
    let path = tmpFile("outofscale.md", raw)
    defer: removeFile(path)
    expect ScoreOutOfRangeError:
      discard parseReviewerOutput(path, brief)
    try:
      discard parseReviewerOutput(path, brief)
    except ScoreOutOfRangeError as e:
      check "chrome" in e.msg
      check "actualValue=12" in e.msg

  test "test_reviewer_output_parser_rejects_unknown_preview_id":
    let brief = fixtureBrief()
    let webId = previewIdWeb(brief)
    # iOS preview is NOT covered by the brief.
    let iosBogus = canonicalPreviewId(brief.coversPreviews[0].storyRef, pbIos)
    let body =
      previewBlock(webId, "{ chrome: 8, rendering: 9 }", "pass") &
      previewBlock(iosBogus, "{ chrome: 7, rendering: 7 }", "warn")
    let overall = "overall:\n  score: 9.0\n  status: pass\n"
    let raw = frontmatter(overall, body)
    let path = tmpFile("unknownpreview.md", raw)
    defer: removeFile(path)
    expect UnknownPreviewError:
      discard parseReviewerOutput(path, brief)
    try:
      discard parseReviewerOutput(path, brief)
    except UnknownPreviewError as e:
      check iosBogus in e.msg

  test "test_reviewer_output_parser_normalises_defect_severity":
    let brief = fixtureBrief()
    let webId = previewIdWeb(brief)
    let androidId = previewIdAndroid(brief)
    let defects =
      "      - id: aspect\n" &
      "        summary: Aspect ratio incorrect.\n" &
      "        severity: BLOCKER\n" &
      "        evidence: x\n"
    let body =
      previewBlock(webId, "{ chrome: 8, rendering: 9 }", "pass") &
      previewBlock(androidId, "{ chrome: 5, rendering: 4 }", "warn", defects)
    let overall = "overall:\n  score: 6.0\n  status: warn\n"
    let raw = frontmatter(overall, body)
    let path = tmpFile("severity.md", raw)
    defer: removeFile(path)
    let parsed = parseReviewerOutput(path, brief)
    var sawBlocker = false
    for p in parsed.previews:
      for d in p.defects:
        if d.id == "aspect":
          check d.severity == "blocker"
          sawBlocker = true
    check sawBlocker

    let bad = raw.replace("severity: BLOCKER", "severity: meh")
    let badPath = tmpFile("severity-bad.md", bad)
    defer: removeFile(badPath)
    expect ReviewerOutputError:
      discard parseReviewerOutput(badPath, brief)
