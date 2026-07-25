# CHRM-M1 — Editor Chrome Audit

Read-only inventory of the editor's chrome-bar clusters, the in-pane
Preview/Brief tab strip, and other axis-like switches across the editor
views. This document is the starting brief for CHRM-M2 / CHRM-M3 /
CHRM-M4.

Anchor commit: `c7bc22b` (TBAR-M3 — top-bar Preview/Spec switch +
chevron viewport selector) — established the four-cluster
`[backend, surface, viewport, mode]` chrome-bar invariant the
`test_editor_chrome_layout.nim` assertion now defends.

Primary source file for the chrome bar:
`/Users/zahary/metacraft/isonim/src/isonim/editor/views/shell.nim` — the
`renderPreviewChromeBar*[R, E](r: R; vm: EditorVM): E` proc starts at
line 2082 and runs to line 2315; it is invoked by
`renderEditorShell*[R, E]` at line 2350.

---

## Chrome-bar clusters

All four clusters live inside one wrapping `tdiv` flagged
`data-preview-chrome-bar="true"` (shell.nim:2106–2117). They are
visually separated by 1-px `clusterDivider()` rules (shell.nim:2122–2127)
and appended in the documented `[backend, surface, viewport, mode]`
order.

### Cluster backend

- **Location:** `src/isonim/editor/views/shell.nim:2152-2176`
  (`renderCompactChoiceColumn[R, E]` + `tiltHorizontal(...)` +
  `appendChild(toolbar, backendCol.root)`).
- **Widget:** **raw `<button>` row** — `renderCompactChoiceColumn`
  (from `views/choice_row.nim`) emits ad-hoc `tdiv role="button"` chips
  built around `CompactChoiceOption`. Each chip is then post-styled
  imperatively by `bindBackendChip` (shell.nim:1066–1137) via
  `r.setStyle(chip, ...)` calls inside a `createRenderEffect`. This is
  **not** the `ChoiceGroup` widget family — the `ui:` DSL idiomatic
  segmented mount is `mountSegmentedChoice` / `mountChevronChoice`
  (`views/widgets/choice_group.nim:142, 252`), neither of which the
  backend cluster uses today.
- **Signal driven:** `vm.platform: Signal[Platform]`
  (viewmodels.nim:191).
- **Signal mirrored:** the same `vm.platform` (drives
  `aria-pressed`/styling) plus
  `vm.streamingPreview.availableBackends.val` (drives the disabled
  styling in `bindBackendChip`).
- **Downstream on click:** `platformHandler(vm, captured)` →
  `selectBackend(vm.streamingPreview, captured)` (when the streaming
  preview hook exists) + `vm.changePlatform(captured)`
  (shell.nim:256–262 + viewmodels.nim:2188). The chip strip also
  reactively rebuilds via the M58 thunk
  `buildBackendOptions(capturedVm)` (shell.nim:1230–1259).
- **Options + labels:** `backendsForLeftEdge()` returns the seven
  `[pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid, pbIos]` enum
  values; `backendShortLabelsForLeftEdge()` returns
  `["Web", "TUI", "GPUI", "Freya", "Cocoa", "Android", "iOS"]`
  (shell.nim:1224–1228).

### Cluster surface

- **Location:** `src/isonim/editor/views/shell.nim:2178-2206`.
- **Widget:** **`ChoiceGroup` segmented** — built via
  `createSegmentedChoiceVM(@["Preview", "Spec"], ...)` and mounted with
  `r.mountSegmentedChoice(surfaceWrapper, surfaceVm, ...)` (the
  canonical TBAR-M2 widget at
  `views/widgets/choice_group.nim:75 (createSegmentedChoiceVM)` and
  `views/widgets/choice_group.nim:142 (mountSegmentedChoice)`).
- **Signal driven:** `vm.surfaceSig: Signal[Surface]`
  (viewmodels.nim:184) — the segmented mount's `onChange` calls
  `capturedVm.setSurface(if i == 0: sPreview else: sSpec)`
  (shell.nim:2191; viewmodels.nim:2212).
- **Signal mirrored:** `vm.surfaceSig` — a `createRenderEffect` at
  shell.nim:2199–2204 reads `capturedVm.surfaceSig.val` and calls
  `syncVm.activate(target)` so external writes to `surfaceSig` flip the
  segmented index. The effect intentionally reads `.value` instead of
  `.val` to avoid feedback-looping the mount's own click handler
  (documented inline at shell.nim:2192–2198).
- **Downstream on click:**
  - `EditorVM.setSurface` writes `surfaceSig.val` (viewmodels.nim:2212);
  - shell-level reactive effect at shell.nim:2480–2505 toggles
    `display: flex|none` on
    `storyboardEl / componentDetailEl / componentEditEl / pagePreviewEl / foundationsEl / vectorEditorEl / specPaneEl`
    based on `surface == sPreview`;
  - shell-level reactive effect at shell.nim:2562–2584 physically
    `appendChild`/`removeChild`s the right-side property/AI chat panel
    (`chatEl`) into/out of the shell row based on the surface.

### Cluster viewport

- **Location:** `src/isonim/editor/views/shell.nim:2208-2286`.
- **Widget:** **`ChoiceGroup` chevron-popup** — built via
  `createChevronChoiceVM(viewportLabelList(initialBackend), ...)` and
  mounted with
  `r.mountChevronChoice(viewportChevronWrapper, viewportChevronVm, ...)`
  (TBAR-M2 widget at
  `views/widgets/choice_group.nim:88 (createChevronChoiceVM)` and
  `views/widgets/choice_group.nim:252 (mountChevronChoice)`). This is
  the only chevron-variant cluster in the chrome bar today.
- **Signal driven:** `vm.viewport: Signal[PreviewViewport]` —
  `mountChevronChoice`'s `onChange` calls
  `capturedVm.changeViewport(viewportChoices[i])` (shell.nim:2243–2246
  and again at the rebuild path 2274–2277; downstream proc at
  viewmodels.nim:2205).
- **Signal mirrored:** `vm.platform` *and* `vm.viewport` — a single
  `createRenderEffect` at shell.nim:2256–2284 rebuilds the chevron VM +
  remounts when the per-backend viewport list (pinned + popup) churns
  on backend change, otherwise calls `viewportChevronVm.activate(i)` to
  reflect external `viewport` writes.  Same `.value`-not-`.val`
  feedback-loop precaution as the surface cluster (documented inline at
  shell.nim:2247–2255).
- **Option list:** `viewportOptionList(backend)` = union of
  `pinnedViewports(backend)` + `popupViewports(backend)`
  (shell.nim:2215–2220).

### Cluster mode

- **Location:** `src/isonim/editor/views/shell.nim:2288-2306`.
- **Widget:** **raw `<button>` row** — same shape as the backend
  cluster: `renderCompactChoiceColumn` emits the three
  `View / Comment / Edit` chips, then `bindModeChip`
  (shell.nim:1171–1222) wires each chip's reactive styling + click
  handler imperatively via `setStyle` calls inside a
  `createRenderEffect`.  Not a `ChoiceGroup` widget.
- **Signal driven:** `vm.editMode: Signal[EditMode]`
  (viewmodels.nim:183) — chip click goes through
  `editModeHandler(vm, captured)` which routes to
  `vm.runEditorCommand(eckInspect | eckComment | eckEdit)`
  (shell.nim:280–289).
- **Signal mirrored:** `vm.editMode` (drives `aria-pressed`/styling)
  plus per-mode availability via `vm.evaluateCommand(capturedCommand)`
  (drives the disabled affordance, shell.nim:1189–1218).
- **Downstream on click:** beyond the `editMode` write, a reactive
  effect at shell.nim:2457–2470 mirrors `editMode` onto
  `SpecPaneVM.mode` (`emView → spmView`, `emComment → spmComment`,
  `emEdit → spmEdit`) when `surfaceSig.val == sSpec`. The chat-panel
  visibility predicate at shell.nim:2566–2576 also reads
  `vm.editMode.val` (the manual-edit-mode carve-out hides the AI panel
  during component-edit Edit mode).
- **Options + labels:** `modes = [emView, emComment, emEdit]`,
  `modeLabels = ["View", "Comment", "Edit"]`,
  `modeShorts = ["View", "Comment", "Edit"]` (shell.nim:1329–1334).

### Plus the trailing 🕘 history button

- **Location:** `src/isonim/editor/views/shell.nim:2308-2313` — calls
  `design_review_mount_view.mountHistoryButtonForEditor` (the affordance
  itself is defined at
  `src/isonim/editor/views/preview_chrome.nim:43-96`).
- **Shape:** a single ad-hoc `tdiv role="button"` button (not part of
  any cluster, not a `ChoiceGroup`). Visibility gated by
  `briefHasHistory` so it is hidden on fresh projects. Out of scope
  for the four-cluster invariant but worth knowing CHRM-M2/M3 will see
  it at the trailing edge of the chrome bar.

---

## In-pane Preview/Brief row

**Confirmed present.** It is *not* in `preview_pane.nim`'s legacy
inner toolbar (that one was removed by M-EVP-7) — instead REV-M2
mounted a freshly added tab-strip *below* the view stack via
`preview_pane_view.mountBriefTabIntoPreviewPane`.

### File / line range

- **Mount site (called from):**
  `src/isonim/editor/views/shell.nim:2519-2521` — gated by
  `if not builtInBriefIndex().empty()` (so a build with zero baked
  briefs still has no row). Mounted into `centerColumn`, between the
  shared chrome bar and the view stack.
- **Row body (the tab strip itself):**
  `src/isonim/editor/views/preview_pane.nim:103-193` —
  `mountBriefTabIntoPreviewPane` proc. Built with the `ui:` DSL inside
  one `stripContainer` (preview_pane.nim:117–160).
- **State + VM:** `src/isonim/editor/views/preview_pane.nim:27-92` —
  `PreviewPaneTabKind = enum pptPreview, pptBrief` + a per-EditorVM
  cached `PreviewPaneState` carrying `activeTab: Signal[PreviewPaneTabKind]`.
- **Brief renderer it drives:**
  `src/isonim/editor/views/brief_tab.nim` (whole file, 531 lines).
  The mount entry point is `mountBriefTab` at brief_tab.nim:266–531.

### Buttons in the row

Two tab buttons, side by side, inside a `role="tablist"` wrapper:

1. **Preview** — `previewTabNode`
   (`preview_pane.nim:131-143`, `data-preview-pane-tab="preview"`).
2. **Brief** — `briefTabNode`
   (`preview_pane.nim:144-156`, `data-preview-pane-tab="brief"`).

The third "??" the brief asks about is not a third top-level button —
but the brief tab body itself contains a **sub-tab strip** for the case
where multiple briefs cover the active preview (brief_tab.nim:302–309
`subTabsHost`, populated by `syncSubTabs()` at
brief_tab.nim:411–444). Those sub-tabs are per-brief selectors, not a
parallel surface switch.

### Action each button performs

Both handlers are tiny — they only flip the
`PreviewPaneState.activeTab` signal:

- Preview tab: `selectPreview()` sets `capturedActiveTab.val =
pptPreview` (preview_pane.nim:169).
- Brief tab: `selectBrief()` sets `capturedActiveTab.val = pptBrief`
  (preview_pane.nim:170).

A `createRenderEffect` at preview_pane.nim:176–192 then:

- updates `data-active-tab` on the stripContainer,
- updates `aria-selected` on each tab,
- updates `data-brief-tab-coverage` on the brief tab (set to
  "covered" or "uncovered" via `briefVm.briefTabVisible.val`),
- toggles the brief host's `display` between `flex` (when
  `tab == pptBrief and briefVisible`) and `none`.

No surface switch, no backend switch — clicking these tabs does **not**
flip `vm.surfaceSig`. It only changes which body the row's host
displays. When the user wants the brief body visible they click the
**Brief** tab here; when they want to flip the centre column to the
TipTap-rendered spec view they click the chrome-bar's **Spec** segment.
Today both paths surface markdown but through different code (see
"Brief-rendering pipeline" below).

### Brief-rendering pipeline (verified different from TBAR-M4)

This is the key audit finding — the in-pane brief tab and the chrome-bar
Spec surface render markdown through **two independent pipelines**:

1. **In-pane Brief tab** (`brief_tab.nim`):
   - markdown comes from `Brief.bodyMarkdown` (via
     `availableBriefsFor(index, story, backend)` in
     brief_tab.nim:82–94);
   - rendered to HTML by **`renderMarkdown`** from
     `src/isonim/editor/design_review/markdown.nim` — a minimal,
     hand-written renderer described in its own doc-comment as
     supporting "ATX headings, paragraphs, fenced code blocks, inline
     code, links" only. **No tables, no lists, no setext headings, no
     blockquotes, no emphasis** (markdown.nim:1–17);
   - injected into the body host via
     `r.setInnerHtml(bodyHost, capturedVm.rendered.val)` at
     brief_tab.nim:481–482.

2. **Chrome-bar Spec surface** (`spec_pane.nim`):
   - markdown comes from the same `Brief.bodyMarkdown` source (the
     reactive effect at shell.nim:2421–2451 looks up the brief by id
     and prepends an H1 title);
   - rendered by **TipTap** + the vendored
     **`@tiptap/extension-markdown`** through the bundle entry
     `nix/entry-tiptap.mjs` — see `spec_pane.nim:42-44` imports of
     `vendor/tiptap`, `vendor/tiptap_starter_kit`, and
     `vendor/tiptap_markdown`, and the bootstrap at
     spec_pane.nim:382-437 calling
     `tiptap_lib.newEditor(tiptap_lib.TipTap, opts)` with
     `StarterKit + Markdown` extensions;
   - covers the full CommonMark surface (StarterKit ships headings,
     paragraphs, lists, code, blockquote, hr, hard-break + the marks
     `bold/italic/strike/code`) — strictly a superset of the brief-tab
     renderer's coverage.

**CHRM-M2 implication:** the in-pane row's brief renderer can be
deleted along with the row. Nothing else in the editor depends on
`design_review/markdown.nim` for live rendering (the file is only
imported by `views/brief_tab.nim`).

### Sub-features that would be lost without an explicit migration plan

The brief-tab body (`brief_tab.nim`) carries more than "render the
markdown" — these are the things CHRM-M2 must consciously delete vs.
preserve elsewhere:

1. **Per-brief sub-tabs** (`brief_tab.nim`:302–309 `subTabsHost`,
   populated at 411–444). When more than one brief covers the active
   `(story, backend)`, the user gets one chip per brief and can swap
   between them. *Delete with the row* — the chrome-bar Spec surface
   today shows exactly one brief at a time (driven by the single
   `resolveBriefId(story, backend)` call at shell.nim:2424) and there
   is no top-bar affordance to pick one of several. If multi-brief
   coverage matters the spec pane needs its own brief picker — out of
   scope for CHRM-M2 per the milestone brief.

2. **Frontmatter chip strip** (`brief_tab.nim`:310–315 `chipStripHost`,
   populated at 447–478). Colour-coded chips for `kind`, coverage
   count, capture viewports, scoring dimensions + weights. This is
   *metadata*, not a markdown rendering; the TipTap-backed spec pane
   does not display it. *Delete with the row* — its consumers (the
   review-this-preview workflow) read the same data from the brief
   file directly, no UI surface depends on the chips.

3. **"Review this preview" button + agent dispatcher**
   (`brief_tab.nim`:327–347 + 508–513 + 247–264 `submitReviewPrompt`).
   Wired by `preview_pane.nim:60-79` to the editor's AI chat
   (`vm.chat.inputText` + `vm.sendAgentPrompt`). Composes a
   context-loaded prompt from brief body + storyRef + scoring rubric.
   **This one is load-bearing** — the user-facing review campaign
   workflow ends here. *Preserve* by surfacing the button elsewhere
   if CHRM-M2 deletes the row. Options: (a) move it into the
   chrome bar as a new affordance next to the 🕘 history button, or
   (b) move it into the TipTap pane's Edit-mode toolbar in CHRM-M4.
   The milestone brief flags this exact concern: "Any features in the
   in-pane row that the audit surfaced (e.g. a different markdown
   pipeline) should be deleted as part of this commit … the TipTap-
   based renderer from TBAR-M4 is the canonical brief viewer", which
   resolves the renderer question but leaves the review button as the
   audit's call to surface. **Recommendation:** preserve as a
   chrome-bar trailing-edge button (group with 🕘 history), since the
   review action is brief-agnostic and shouldn't require entering
   Edit mode to trigger.

4. **Empty-state "no brief covers this preview"** with the storyRef +
   Copy button (`brief_tab.nim`:348–394). This is a discoverability
   affordance for brief authors — when a story has no brief yet the
   pane shows the canonical previewId and a one-click copy so the
   user can paste it into a new `coversPreviews:` field. _Delete
   with the row_ — the chrome-bar Spec surface today renders
   `"# Spec\n\nNo brief available for the selected story."` as its
   own empty state (shell.nim:2436); that already covers the "no
   brief" case, just without the copy affordance. If the copy
   affordance matters it can be added to the chrome-bar trailing
   slot in a future polish wave.

5. **Per-VM caching of brief state** (`preview_pane.nim`:42–86 — the
   `previewPaneStates` threadvar + `statefor` proc). Builds a
   `BriefTabVM` once per `EditorVM` instance and reuses it across
   re-mounts. *Delete with the row* — the spec pane lookup uses a
   simpler `resolveBriefId(story, backend)` per render-effect run
   (shell.nim:2421–2451) and the per-VM caching is not needed for
   that path.

---

## Other axis-like switches

Beyond the chrome bar, the editor has several toggle rows that today
are *not* `ChoiceGroup`-backed but follow the same "pick one of N"
pattern. CHRM-M2's scope is the chrome bar, but this list is the
source for any follow-on consolidation:

1. **Inspector section tab strip** —
   `src/isonim/editor/views/shell.nim:1583-1610`. Six-or-so tabs
   (built from `inspectorSectionNames` + `inspectorSections` arrays).
   Each tab is a `tdiv role="tab"` styled inline + bound via
   `r.bindInspectorTabState` (shell.nim:1610). Drives
   `vm.isActiveInspectorSection(section)` /
   `vm.switchInspectorSection(captured)` (shell.nim:268–270). A
   natural fit for `mountSegmentedChoice` (scrollable variant) or a
   chevron when narrow.

2. **CSS inspector — Display mode** —
   `src/isonim/editor/views/inspector_sections.nim:47-61`. Four
   options `["Block", "Flex", "Grid", "None"]` rendered as an inline
   `for i, mode in [...]` loop with hand-rolled active-state styling.
   No signal binding today (it is a static demo of the Figma-grade
   layout panel, not yet wired to a VM). Fits `mountSegmentedChoice`.

3. **CSS inspector — Flex direction** —
   `src/isonim/editor/views/inspector_sections.nim:64-78`. Four arrow
   glyphs `→ ↓ ← ↑`. Same hand-rolled shape, same demo state. Fits
   the segmented variant (icon-only mode would be a useful CHRM-M2
   ChoiceGroup extension).

4. **CSS inspector — Align items** —
   `src/isonim/editor/views/inspector_sections.nim:81-95`. Five
   alignment glyphs. Same shape.

5. **CSS inspector — Justify content** —
   `src/isonim/editor/views/inspector_sections.nim:98-113`. Five
   alignment glyphs. Same shape.

6. **CSS inspector — Wrap** —
   `src/isonim/editor/views/inspector_sections.nim:115-130`. Two
   options `["No wrap", "Wrap"]`. Same shape.

7. **Stroke section — Border style** —
   `src/isonim/editor/views/inspector_sections.nim:225-239`. Four
   options `["Solid", "Dashed", "Dotted", "None"]`. Same shape.

8. **Per-component property chooser** —
   `src/isonim/editor/views/component_detail.nim:293-325` (the
   `renderComponentPropertyInput` proc). Uses
   `renderCompactChoiceRow` (the same widget the chrome-bar backend +
   mode clusters use today) when the property has a discrete option
   list. Drives `vm.editComponentProperty(...)`. Same "should it be
   a ChoiceGroup" question as the chrome-bar backend cluster — both
   would benefit from a single migration.

9. **Per-component state chooser** —
   `src/isonim/editor/views/component_detail.nim:385-416` (the
   `renderComponentStateButton` proc). Uses `renderCompactChoiceRow`
   when the state has a discrete option list. Drives
   `vm.editComponentStateControl(...)`. Same shape as #8.

10. **Gallery view-mode chip strip** —
    `src/isonim/editor/views/gallery_overlay.nim:406-449` (the four
    mode chips Grid / Full tab / Full screen / Compare in the
    REV-M8 gallery overlay). Each chip is a raw `tdiv role="button"`;
    click handlers at gallery_overlay.nim:531–542 call `setMode(...)`
    which writes `capturedVm.mode.val`. Compare is permanently
    disabled ("not-allowed") in the current UI. A textbook
    segmented-choice fit.

11. **Vector editor — tool palette** —
    `src/isonim/editor/views/vector_editor.nim:229-251`.  N tool
    buttons in a vertical column, driven by
    `vm.isActiveVectorTool(...) / vectorToolHandler(vm, toolKind)`.
    Each is a raw `tdiv role="button"`.  Same shape — could move to a
    vertical `mountSegmentedChoice` (CHRM-M2 ChoiceGroup orientation
    extension).

12. **Vector editor — Grid + Snap toggles** —
    `src/isonim/editor/views/vector_editor.nim:260-303`. Two
    independent boolean toggles (each its own `tdiv role="button"`
    with `aria-pressed`).  These are *not* axis-like (each is a
    single bool, not a "pick one of N"), so they are not a
    `ChoiceGroup` candidate — flagged here only because they sit in
    the same toolbar and might be visually unified with whatever
    ChoiceGroup affordance the vector tool palette adopts.

13. **Vector editor — Layer list** —
    `src/isonim/editor/views/vector_editor.nim:410-435`. N rows,
    pick one via `vm.isSelectedVectorLayer(i) / vectorLayerHandler`.
    Behaves like a list-selector more than an axis switch (variable
    N at runtime, each row has its own per-row affordances), so this
    is a chevron candidate at narrow widths but probably stays as a
    list at wide widths.

14. **Foundation token list** —
    `src/isonim/editor/views/foundations_page.nim:351-393`. N rows,
    pick one via `vm.foundations.selectedTokenKey.val`. Same
    list-selector shape as #13 — not a clean ChoiceGroup fit because
    of the per-row preview swatch + label hierarchy.

---

## CHRM-M2 plan summary

CHRM-M2's job is to leave the four chrome-bar clusters using one
consistent widget family (`ChoiceGroup`) and to delete the in-pane
Preview/Brief tab strip + its renderer. Below is the concrete
breakdown the milestone brief asked for.

### Migrate to ChoiceGroup

- **Backend cluster** (chrome bar) — swap
  `renderCompactChoiceColumn` + `bindBackendChip` + `tiltHorizontal`
  for `mountSegmentedChoice` (wide) with a `mountChevronChoice`
  fallback at narrow widths (the existing density branch in
  `viewportVisibleLimitThunk`-style logic was for the per-backend
  pinned-viewport-count rebuild, not for backend density — backend is
  always 7 items so narrow-width chevron fallback is genuinely useful).
  Preserve the visible short labels
  `["Web", "TUI", "GPUI", "Freya", "Cocoa", "Android", "iOS"]`. Wire
  to the same `vm.platform`/`platformHandler` path; do not bypass the
  `vm.streamingPreview.availableBackends` availability check
  (`ChoiceGroup` will need a per-option `disabled` parameter — extend
  the widget rather than branching).

- **Mode cluster** (chrome bar) — swap
  `renderCompactChoiceColumn` + `bindModeChip` + `tiltHorizontal` for
  `mountSegmentedChoice(["View", "Comment", "Edit"])` wired to
  `vm.editMode`.  Preserve the per-mode availability gate
  (`vm.evaluateCommand(eckInspect|eckComment|eckEdit)`).  The
  reactive mirror that drives `SpecPaneVM.mode` from
  `editMode + surface == sSpec` (shell.nim:2457–2470) stays as-is.

- **`ChoiceGroup` widget extensions implied by the above:**
  1. Per-option `disabled` flag with `aria-disabled` + reduced-opacity
     styling + `not-allowed` cursor — replicates today's `bindBackendChip`
     / `bindModeChip` availability behaviour.
  2. Optional "icon-only compact" mode so the M-EVP-14 pill-without-
     filled-bar aesthetic the chrome bar uses today is reproducible.
     (Audit observation: the chrome-bar clusters today strip the
     widget's container background + border via `tiltHorizontal`;
     ChoiceGroup needs a `variant = "transparent" | "filled"` knob so
     the chrome-bar clusters can pick "transparent" without imperative
     setStyle.)
  3. Optional narrow-width auto-fallback from segmented to chevron
     (keyed off a width threshold or an explicit container-query-style
     prop). Could be deferred to a CHRM-M3 polish wave if CHRM-M2
     keeps two explicit mounts (one wide, one narrow) gated by a CSS
     media query, but a single auto-fallback is cleaner.

- **Surface + Viewport clusters** — already `ChoiceGroup`-backed (the
  segmented + chevron variants respectively). No widget swap needed.
  Style consistency in CHRM-M3.

### Delete

- **In-pane Preview/Brief tab strip mount + state**:
  - the `if not builtInBriefIndex().empty():` block at
    `shell.nim:2519-2521`,
  - `src/isonim/editor/views/preview_pane.nim` in its entirety
    (PreviewPaneTabKind, `statefor`, `briefTabVMFor`,
    `previewPaneActiveTabFor`, `mountBriefTabIntoPreviewPane`),
  - `src/isonim/editor/views/brief_tab.nim` in its entirety (the
    minimal-markdown renderer is then orphaned).
- **Minimal-markdown renderer**:
  `src/isonim/editor/design_review/markdown.nim` — last consumer was
  `brief_tab.nim`'s `renderMarkdown` import; with the row gone the
  module has no callers and should be deleted to keep the canonical
  TipTap path single-sourced.  (Verify:
  `grep -rn "design_review/markdown" src/` should return zero hits
  after the deletion.)
- **`buildBackendOptions` / `buildModeOptions` thunks +
  `bindBackendChip` / `bindModeChip`** in shell.nim (lines 1066–1137,
  1171–1222, 1230–1259, 1325–1355) — these are the compact-choice-row
  binders that the chrome bar uses today; after the ChoiceGroup
  migration they are dead. `bindViewportChip` (shell.nim:1139–1169)
  is already dead in the chrome bar (TBAR-M3 swapped viewport to the
  chevron mount) — confirm no other caller before deleting.
- **`tiltHorizontal` helper** in `renderPreviewChromeBar`
  (shell.nim:2141–2150) — exists only to repurpose the column variant
  for horizontal flow; obsolete once both backend + mode use
  ChoiceGroup directly.

### Preserve

- **The "Review this preview" button + agent-dispatch wiring**
  (brief_tab.nim:247–264 `submitReviewPrompt`, brief_tab.nim:327–347
  the button DOM, brief_tab.nim:508–513 the click handler,
  preview_pane.nim:60–79 the dispatcher hook + connection-state
  reactivity). Recommendation: surface as a single chrome-bar
  trailing-edge button grouped with the 🕘 history button. Keep the
  dispatcher wiring intact and rebuild only the DOM affordance.
  Required predicates kept:
  - "no active brief → button hidden"
    (brief_tab.nim:517–522);
  - "daemon unavailable → button disabled with tooltip"
    (preview_pane.nim:71–79).

- **The chrome-bar four-cluster invariant**
  (`[backend, surface, viewport, mode]`) — keep cluster count at 4
  and order unchanged. `test_editor_chrome_layout.nim` defends this;
  CHRM-M2's assertion update is "every cluster's root now exposes
  `data-choice-group="true"`" (or the equivalent stable
  ChoiceGroup-emitted attribute), not a count or order change.

- **The reactive mode-mirror** that flips `SpecPaneVM.mode` from
  `editMode + surface == sSpec` (shell.nim:2457–2470) — unchanged.

- **The reactive chat-panel mount/unmount predicate**
  (shell.nim:2562–2584) — unchanged. It already correctly handles
  the surface flip + the manual-edit-mode carve-out + the
  spec-comment carve-out.

- **The 🕘 history button** + its `briefHasHistory` polling path
  (mounted at shell.nim:2308–2313 inside the chrome bar). Stays
  where it is — out of the four-cluster invariant but inside the
  toolbar.

### Out of scope for CHRM-M2 (track for CHRM-M3 / CHRM-M4)

- Migrating the eight inspector / CSS-inspector toggle rows
  (items 1–7 + the component property/state rows in the "Other
  axis-like switches" list) to `ChoiceGroup`. Mentioned in the
  milestone brief as "watch for", scoped here for visibility, but
  the CHRM-M2 brief explicitly scopes the migration to the chrome
  bar.
- Gallery view-mode chips, vector tool palette — same.
- CHRM-M3 visual polish on the unified clusters.
- CHRM-M4 TipTap formatting toolbar in spec-pane Edit mode.
