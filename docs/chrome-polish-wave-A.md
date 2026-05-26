# CHRM-M3 Wave A — Defect List + Fixes

Round 1 of the CHRM-M3 visual-polish iteration. Captured 11 screenshots
across 4 views (shell, spec-pane-view, spec-pane-comment, spec-pane-edit)
at 3 viewports (wide / laptop / narrow). Reviewer-style critique done
inline (no sub-agent dispatch available in the orchestrating
environment); per-screen scores recorded below the defects.

## Defects identified (round 1)

### CRITICAL — spec-pane height collapse (all spec-pane-\* views)

**Symptom**: the TipTap host gets only ~50% of the centre column's
vertical budget. On a 1920×1080 capture the spec pane's
`rootClientHeight` is 505 px (probed live via Playwright) instead of
the ~980 px we should see after subtracting the chrome bar.

**Root cause**: when `surface == sSpec` the existing reactive effect in
`shell.nim::renderEditorShell` sets every CHILD of the `viewStack` to
`display: none`, but the **viewStack itself** keeps `display: flex`
and its `flex: 1`. The centre column then has two flex:1 children
(empty viewStack + specPaneEl) competing for the vertical budget.

**Fix**: extend the existing reactive effect with a single
`r.setStyle(viewStack, "display", if preview: "flex" else: "none")`
call. No new createRenderEffect introduced; no new setStyle outside
a render effect. Verified: the spec pane now occupies the full centre
column.

### CRITICAL — flat typographic hierarchy in the TipTap render (all spec-pane-\* views)

**Symptom**: H1, H2, H3, and body all render at near-identical size and
weight. The reader cannot tell sections apart from paragraphs.

**Root cause**: TipTap's StarterKit ships intentionally style-light
defaults (the library expects each consumer to apply its own design
tokens). The spec pane mounted ProseMirror with no scoped CSS rules.

**Fix**: add a scoped `<style>` block in
`isonim-examples/editor/index.html` (and the upstream
`isonim/src/isonim/editor/index.html` so the wanderlust editor shares
the polish) that targets
`[data-spec-pane-tiptap-host="true"] .ProseMirror …`. Type ramp:

- H1 = 28 px / 700 / -0.01em letter-spacing
- H2 = 20 px / 600 / -0.005em
- H3 = 16 px / 600
- body = 14 px / line-height 1.65
- inline code = 0.88em monospace on `#1D1D28` background, 1 px border
- code blocks = 12.5 px monospace, `#14141C` background, border + radius
- blockquote = 3 px left-border accent (`#4B4B6A`), muted italic body
- horizontal rule = 1 px `#2A2B36`, 24 px vertical margin

### HIGH — uncontrolled line length in the prose (spec-pane-view + edit)

**Symptom**: prose stretched the full width of the centre column
(~1500 px at the wide viewport). Reading-comfort target is 60-80ch.

**Fix**: set `max-width: 760px; margin: 0 auto` on
`.ProseMirror`. 760 px ≈ 60-80ch at 14 px body.

### MEDIUM — bare `<p>` margins (spec-pane-\* views)

**Symptom**: paragraphs and sibling blocks have no vertical rhythm.

**Fix**: `.ProseMirror > * + * { margin-top: 12px; }` plus per-element
overrides for headings (24-28 px above H1/H2, 20 px above H3).

### LOW — scrollbar treatment (spec-pane-\* views)

**Symptom**: default OS scrollbar in the spec-pane wrapper looks like
a leftover from a prototype.

**Fix**: custom webkit-scrollbar selectors on
`[data-spec-pane-tiptap="true"]`: 10 px wide, 6 px-radius thumb in
`#2A2B36`, hover `#3A3B46`.

### Comment popover — already in good shape

The popover positioning, chrome (1 px border + drop shadow), textarea
sizing, and Submit/Cancel buttons all read OK in the captured
spec-pane-comment screenshots. Defer further polish to a later wave
unless other issues surface there.

### Shell — already in good shape at wide / laptop

The four-cluster CHRM-M2 layout reads clean. Trailing-edge Review +
🕘 history buttons sit cleanly together. No obvious defects at this
round.

### Narrow viewport — known tolerance per shell-narrow.md brief

At 375 × 812 the sidebar fills the viewport (centre column pushed
off-screen) and the chrome bar wraps onto multiple rows. This is
tolerable per the existing narrow brief; the spec pane in narrow
mode does render but the H1 wraps one-letter-per-line in the tiny
column. We don't fix this in Wave A — the narrow brief's "tolerance
8/10 even if collapsed" calibration applies.

## Round-1 scores (before Wave A fixes)

| Screen                   | Score | Notes                                                                |
| ------------------------ | ----- | -------------------------------------------------------------------- |
| shell-wide               | 8     | Four-cluster chrome reads clean                                      |
| shell-laptop             | 8     | Same as wide, slightly tighter density                               |
| shell-narrow             | 7     | Chrome wraps multi-row, sidebar fills viewport — tolerable per brief |
| spec-pane-view-wide      | 4     | Flat typography + full-width prose + half-height pane                |
| spec-pane-view-laptop    | 4     | Same defects                                                         |
| spec-pane-view-narrow    | 4     | Same defects + narrow squeeze                                        |
| spec-pane-comment-wide   | 5     | Half-height pane underneath; popover OK                              |
| spec-pane-comment-laptop | 5     | Same                                                                 |
| spec-pane-edit-wide      | 4     | Toolbar mid-pane (half-height bug), flat typography                  |
| spec-pane-edit-laptop    | 4     | Same                                                                 |
| spec-pane-edit-narrow    | 3     | Toolbar at the very bottom of the squeezed pane                      |

## Wave A fixes shipped

1. shell.nim viewStack `display: none` when surface = sSpec — recovers
   full vertical budget for the spec pane.
2. Index.html scoped TipTap typography (both isonim-examples + upstream
   isonim) — H1/H2/H3/body hierarchy + max-width 760px prose + scoped
   inline-code + code-block + blockquote + list + scrollbar styling.

## Expected round-2 score gains

- spec-pane-\* wide / laptop: 4 → 8 (typography + height fixes are the
  load-bearing defects).
- shell-\*: unchanged 7-8.
- spec-pane-\* narrow: 3-4 → 5-6 (still tolerable per the narrow brief).
