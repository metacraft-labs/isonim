## CHRM-M2 — Pure helper that composes the "Review this preview" prompt.
##
## Originally shipped in ``views/brief_tab.nim`` as
## ``buildReviewPrompt`` / ``submitReviewPrompt``. CHRM-M2 deleted the
## in-pane brief tab (the chrome-bar Surface switch + TipTap spec pane
## already cover the brief-viewing affordance) but the
## "Review this preview" button itself is preserved by moving it to a
## chrome-bar trailing-edge slot. The prompt-composition logic lives in
## this module so its VM-level tests can target the pure helper
## independent of the renderer.

import std/[strutils]

import isonim/editor/types
import isonim/editor/design_review/brief_format

proc stripFrontmatterBody*(b: Brief): string =
  ## ``Brief.bodyMarkdown`` excludes the ``---`` delimiters already; we
  ## still trim leading/trailing whitespace so the composed prompt
  ## doesn't carry an empty leading paragraph.
  result = b.bodyMarkdown.strip()

proc buildReviewPrompt*(b: Brief; story: StoryRef;
                        backend: PreviewBackend;
                        latestCaptureSha = ""): string =
  ## Compose the context-loaded prompt for the
  ## "Review this preview" button. Shape matches the spec:
  ##
  ##   "Review the preview I'm currently looking at.
  ##    Brief: <bodyMarkdown>.
  ##    Story: <storyRef>.
  ##    Captured at: <sha>.
  ##    Score per the rubric in the brief."
  let storyRef = canonicalPreviewId(story, backend)
  let body = stripFrontmatterBody(b)
  var rubric = ""
  for d in b.scoringDimensions:
    rubric.add("- " & d.label & " (weight " &
               formatFloat(d.weight, ffDecimal, 2) & ")\n")
  result = "Review the preview I'm currently looking at."
  result.add "\n\n## Brief\n\n"
  result.add body
  result.add "\n\n## Story\n\n"
  result.add storyRef
  if latestCaptureSha.len > 0:
    result.add "\n\n## Captured at\n\n"
    result.add latestCaptureSha
  result.add "\n\n## Scoring\n\n"
  if rubric.len > 0:
    result.add rubric
  else:
    result.add "Score per the rubric in the brief.\n"
  result.add "\nScore per the rubric in the brief."
