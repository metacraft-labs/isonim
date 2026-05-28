## Browser runtime helpers for embedding the IsoNim Editor.
##
## Project entry points can import this module, construct an EditorWorkspace,
## and mount it into any DOM element.

when not defined(js):
  {.error: "isonim/editor/browser must be compiled with `nim js`".}

import std/[dom, strutils]

import isonim/core/[computation, owner, signals]
import isonim/editor/dom_renderer
import isonim/editor/streaming_preview
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/views/shell
import isonim/editor/design_review/editor_agent_adapter

var
  routeSyncScheduled = false
  routeHistoryInitialized = false
  applyingRoute = false
  lastSyncedRoute = ""

proc injectEditorStyles*() =
  ## Inject base responsive styles required by the editor shell.
  let style = document.createElement("style")
  style.textContent = cstring"""
    .editor-tabbar::-webkit-scrollbar { display: none; }
    /* Inspector tabbar: fade the right edge so overflow reads as scrollable. */
    .editor-manual-inspector .editor-tabbar {
      mask-image: linear-gradient(to right, black calc(100% - 24px), transparent 100%);
      -webkit-mask-image: linear-gradient(to right, black calc(100% - 24px), transparent 100%);
    }
    .editor-sidebar,
    .editor-chat,
    .editor-manual-inspector {
      scrollbar-width: thin;
    }
    .editor-sidebar::-webkit-resizer {
      background: #334155;
    }
    .editor-statusbar [role="button"]:hover,
    .editor-tabbar [role="tab"]:hover {
      background: #1E293B !important;
    }
    .editor-manual-inspector details {
      border-top: 1px solid #1E293B;
      padding-top: 2px;
    }
    .editor-manual-inspector details:not([open]) > *:not(summary) {
      display: none !important;
    }
    /* Per-row "More" disclosure: hidden by default, revealed on row hover. */
    [data-inspector-control] > details > summary {
      display: none;
    }
    [data-inspector-control]:hover > details > summary,
    [data-inspector-control] > details[open] > summary,
    [data-inspector-control]:focus-within > details > summary {
      display: block;
    }
    [data-inspector-control] > details {
      border-top: none;
      padding-top: 0;
    }
    /* Segmented-strip rows: strip replaces value/unit/scope cells inline. */
    [data-inspector-control] {
      position: relative;
    }
    [data-inspector-control]:has(> [data-segmented-strip])
      [data-inspector-row-slot="value-field"],
    [data-inspector-control]:has(> [data-segmented-strip])
      [data-inspector-row-slot="unit-picker"] {
      visibility: hidden;
    }
    [data-inspector-control] > [data-segmented-strip] {
      position: absolute;
      top: 0;
      left: 139px;
      right: 87px;
      height: 22px;
      margin: 0;
      max-width: none;
      display: flex !important;
    }
    /* Scope chip: monospace + uppercase so abbreviations align column-wise. */
    [data-inspector-scope-selector="true"] [role="button"] {
      font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
      letter-spacing: 0.4px;
      text-transform: uppercase;
    }
    @media (max-width: 768px) {
      .editor-sidebar { width: 100% !important; min-width: 100% !important; }
      .editor-preview { display: none !important; }
      .editor-inspector { display: none !important; }
      .editor-chat { display: none !important; }
      .editor-mobile-toggle { display: flex !important; }
      /* CHRM-M7 — at narrow widths the chrome-bar history button is
         unreachable (lives inside .editor-preview which is hidden).
         The sidebar mirrors the affordance so the gallery stays
         summonable. The slot is display:none at wide/laptop widths
         so the duplicate button doesn't render twice; at narrow we
         flip it to inline-flex so the 🕘 button surfaces alongside
         the search input. */
      .editor-sidebar-history-narrow { display: inline-flex !important; }
    }
    .editor-mobile-toggle { display: none; }
    /* CHRM-M7 — hide the sidebar history slot at wide / laptop widths
       so the chrome-bar button stays the sole affordance there. */
    .editor-sidebar-history-narrow { display: none; }
    @media (max-width: 1024px) and (min-width: 769px) {
      .editor-sidebar { width: 220px !important; min-width: 220px !important; }
      .editor-inspector,
      .editor-chat,
      .editor-manual-inspector { width: min(320px, 38vw) !important; min-width: min(320px, 38vw) !important; max-width: min(320px, 38vw) !important; }
      .editor-tabbar > div { padding: 0 6px !important; font-size: 10px !important; }
    }
    .editor-input::placeholder { color: #475569; }
    .editor-input:focus { border-color: #3B82F6 !important; }

    /* ---- Phase H — Property row visual polish (2026-05-28) ---- */

    /* Hover-revealed affordances. The bind and more buttons sit
       quietly until the row is hovered or focused — Figma's pattern. */
    [data-property-row] [data-property-row-slot="bind"],
    [data-property-row] [data-property-row-slot="more"] {
      opacity: 0;
      transition: opacity 120ms ease-out;
    }
    [data-property-row]:hover [data-property-row-slot="bind"],
    [data-property-row]:hover [data-property-row-slot="more"],
    [data-property-row]:focus-within [data-property-row-slot="bind"],
    [data-property-row]:focus-within [data-property-row-slot="more"] {
      opacity: 1;
    }
    /* Linked rows keep their bind affordance visible (it carries the
       chip's swap chevron). */
    [data-property-row][data-property-row-linked="true"]
      [data-property-row-slot="bind"] {
      opacity: 1;
    }
    /* Hover state on the input pill — subtle border so the user
       sees the click target without a permanent 1px line. */
    [data-property-row-pill="true"] {
      transition: border-color 120ms ease-out,
                  background-color 120ms ease-out;
    }
    [data-property-row]:hover [data-property-row-pill="true"],
    [data-property-row]:focus-within [data-property-row-pill="true"] {
      border-color: #2A2C3A !important;
    }
    /* The inspector chrome itself — hover affordances on selection
       header icons + section header. */
    [data-inspector-selection-action]:hover {
      background-color: #1F212C !important;
      color: #ECEDF3 !important;
    }
    [data-inspector-section-header]:hover [data-inspector-section-title] {
      color: #FFFFFF !important;
    }
    [data-inspector-section-action="add"]:hover {
      background-color: #1F212C !important;
      color: #ECEDF3 !important;
    }

    /* Soften the segmented-choice active pill INSIDE inspector
       property rows — the shared widget paints the active state in
       indigo (#7c7aed), which competes with the variable-binding
       accent elsewhere. Inspector rows want a quiet raised inset
       instead, matching the Layout mode strip's Phase H treatment. */
    [data-property-row] [data-choice-group="segmented"]
      [data-choice-group-pill][aria-pressed="true"] {
      background-color: #262838 !important;
      border-color: #2A2C3A !important;
      color: #F1F5F9 !important;
    }
  """
  document.head.appendChild(style)

proc hashEditorView*(): EditorView =
  ## Read URL hash to choose an initial screenshot/deep-link view.
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "component-detail" in h:
    evComponentDetail
  elif "component-edit" in h:
    evComponentEdit
  elif "page-preview" in h:
    evPagePreview
  elif "foundations" in h:
    evFoundationsPage
  elif "vector-editor" in h:
    evVectorEditor
  else:
    evStoryboard

proc hasEditorRouteOverride*(): bool =
  ## Only override workspace initial state when the URL explicitly asks for a
  ## view. A bare mount should honor the consumer workspace defaults.
  var hash: cstring
  var search: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  {.emit: [search, " = window.location.search || ''"].}
  ($hash).len > 0 or "view=" in $search

proc hashInspectorSection*(): InspectorSection =
  ## Read URL hash for inspector section deep links.
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "layout" in h:
    isLayout
  elif "fill" in h:
    isFill
  elif "effects" in h:
    isEffects
  elif "stroke" in h:
    isStroke
  elif "transitions" in h:
    isTransitions
  else:
    isSpacing

proc routeParam(name: string): string =
  var value: cstring
  let key = name.cstring
  {.emit: [value, " = (new URLSearchParams(window.location.search)).get(", key,
      ") || ''"].}
  $value

proc currentRouteUrl(): string =
  var value: cstring
  {.emit: [value, " = window.location.pathname + window.location.search"].}
  $value

proc currentPathname(): string =
  var value: cstring
  {.emit: [value, " = window.location.pathname"].}
  $value

proc encodeParam(value: string): string =
  var encoded: cstring
  let raw = value.cstring
  {.emit: [encoded, " = encodeURIComponent(", raw, ")"].}
  $encoded

proc writeRouteUrl(url: string; replace: bool) =
  let next = url.cstring
  if replace:
    {.emit: ["window.history.replaceState({ isonimEditor: true }, '', ", next,
        ")"].}
  else:
    {.emit: ["window.history.pushState({ isonimEditor: true }, '', ", next, ")"].}

proc deferRouteWrite(cb: proc()) =
  {.emit: ["setTimeout(", cb, ", 0)"].}

proc addPopstateListener(handler: proc()) =
  {.emit: ["window.addEventListener('popstate', ", handler, ")"].}

proc removePopstateListener(handler: proc()) =
  {.emit: ["window.removeEventListener('popstate', ", handler, ")"].}

func viewSlug(view: EditorView): string =
  case view
  of evStoryboard: "flow"
  of evComponentDetail: "detail"
  of evComponentEdit: "edit"
  of evPagePreview: "page"
  of evFoundationsPage: "foundations"
  of evVectorEditor: "vector"

func viewFromSlug(slug: string; fallback: EditorView): EditorView =
  case slug.normalize
  of "flow", "storyboard": evStoryboard
  of "detail", "component-detail": evComponentDetail
  of "edit", "component-edit": evComponentEdit
  of "page", "page-preview": evPagePreview
  of "foundations", "foundations-page", "foundation": evFoundationsPage
  of "vector", "vector-editor": evVectorEditor
  else: fallback

func storyKindSlug(kind: StoryKind): string =
  case kind
  of skFoundation: "foundation"
  of skComponent: "component"
  of skPattern: "pattern"
  of skPage: "page"
  of skFlow: "flow"
  of skGuideline: "guideline"
  of skVectorSymbol: "vector-symbol"

func storyKindFromSlug(slug: string; fallback: StoryKind): StoryKind =
  case slug.normalize
  of "foundation": skFoundation
  of "component": skComponent
  of "pattern": skPattern
  of "page": skPage
  of "flow": skFlow
  of "guideline": skGuideline
  of "vectorsymbol": skVectorSymbol
  else: fallback

func viewportSlug(viewport: PreviewViewport): string =
  previewViewportSlug(viewport)

func viewportFromSlug(slug: string; fallback: PreviewViewport): PreviewViewport =
  ## Resolve a route param back to a `PreviewViewport`. Recognises both
  ## built-in slugs and the `custom-<w>x<h>(c?)` form produced by
  ## `makeCustomViewport`. Falls back to the supplied default.
  let norm = slug.normalize
  if norm.startsWith("custom-"):
    let body = norm[7 .. ^1]
    let isCells = body.endsWith("c")
    let extentPart = if isCells: body[0 .. ^2] else: body
    let xIdx = extentPart.find('x')
    if xIdx > 0:
      try:
        let w = parseInt(extentPart[0 ..< xIdx])
        let h = parseInt(extentPart[xIdx + 1 .. ^1])
        return makeCustomViewport(w, h, isCells = isCells)
      except ValueError:
        discard
  for vp in allBuiltinViewports():
    if vp.slug == norm:
      return vp
  fallback

func editModeSlug(mode: EditMode): string =
  case mode
  of emView: "view"
  of emComment: "comment"
  of emEdit: "edit"

func editModeFromSlug(slug: string; fallback: EditMode): EditMode =
  case slug.normalize
  of "view": emView
  of "comment", "comments", "review": emComment
  of "edit": emEdit
  else: fallback

func inspectorSectionSlug(section: InspectorSection): string =
  case section
  of isLayout: "layout"
  of isSize: "size"
  of isSpacing: "spacing"
  of isPosition: "position"
  of isFill: "fill"
  of isStroke: "stroke"
  of isTypography: "typography"
  of isEffects: "effects"
  of isTransitions: "transitions"
  of isFilters: "filters"
  of isState: "state"
  of isSource: "source"
  of isAppearance: "appearance"
  of isSelectionColors: "selection-colors"
  of isComponentProps: "component-properties"
  of isExport: "export"

func inspectorSectionFromSlug(slug: string;
    fallback: InspectorSection): InspectorSection =
  case slug.normalize
  of "layout": isLayout
  of "size": isSize
  of "spacing", "space": isSpacing
  of "position", "pos": isPosition
  of "fill": isFill
  of "stroke": isStroke
  of "typography", "type": isTypography
  of "effects", "fx": isEffects
  of "transitions", "transition": isTransitions
  of "filters", "filter": isFilters
  of "state": isState
  of "source": isSource
  of "appearance": isAppearance
  of "selectioncolors": isSelectionColors
  of "componentproperties", "componentprops": isComponentProps
  of "export": isExport
  else: fallback

func boolSlug(value: bool): string =
  if value: "1" else: "0"

func boolFromSlug(slug: string; fallback: bool): bool =
  case slug.normalize
  of "1", "true", "yes", "on": true
  of "0", "false", "no", "off": false
  else: fallback

func parseRouteIndex(value: string; fallback: int): int =
  if value.len == 0:
    return fallback
  try:
    parseInt(value)
  except ValueError:
    fallback

proc editorDebugEnabled(): bool =
  var value: cstring
  {.emit: [value, " = (new URLSearchParams(window.location.search)).get('debug') || window.localStorage.getItem('isonim-editor-debug') || ''"].}
  ($value).normalize in ["1", "true", "yes", "on"]

proc installEditorKeyboardShortcuts(vm: EditorVM) =
  let openPalette = proc() =
    discard vm.runEditorCommand(eckOpenCommandPalette)
  let closePalette = proc() =
    vm.closeCommandPalette()
  let editMode = proc() =
    discard vm.runEditorCommand(eckEdit)
    vm.recordEditorTiming(epbkModeSwitch, 1, "keyboard:edit")
  let commentMode = proc() =
    discard vm.runEditorCommand(eckComment)
    vm.recordEditorTiming(epbkModeSwitch, 1, "keyboard:comment")
  let viewMode = proc() =
    discard vm.runEditorCommand(eckInspect)
    vm.recordEditorTiming(epbkModeSwitch, 1, "keyboard:view")
  let toggleSidebar = proc() =
    discard vm.runEditorCommand(eckToggleSidebar)
  let toggleInspector = proc() =
    discard vm.runEditorCommand(eckToggleInspector)
  let focusInspector = proc() =
    discard vm.runEditorCommand(eckFocusInspector)
  let previousElement = proc() =
    discard vm.runEditorCommand(eckSelectPrevious)
    vm.recordEditorTiming(epbkElementSelection, 1, "keyboard:previous")
  let nextElement = proc() =
    discard vm.runEditorCommand(eckSelectNext)
    vm.recordEditorTiming(epbkElementSelection, 1, "keyboard:next")
  let parentElement = proc() =
    discard vm.runEditorCommand(eckSelectParent)
    vm.recordEditorTiming(epbkElementSelection, 1, "keyboard:parent")
  let childElement = proc() =
    discard vm.runEditorCommand(eckSelectChild)
    vm.recordEditorTiming(epbkElementSelection, 1, "keyboard:child")
  let save = proc() =
    discard vm.runEditorCommand(eckSave)
    vm.recordEditorTiming(epbkSaveReload, 1, "keyboard:save")
  let undo = proc() =
    discard vm.runEditorCommand(eckUndo)
  let redo = proc() =
    discard vm.runEditorCommand(eckRedo)
  {.emit: ["""
    (function () {
      const openPalette = """, openPalette, """;
      const closePalette = """, closePalette, """;
      const editMode = """, editMode, """;
      const commentMode = """, commentMode, """;
      const viewMode = """, viewMode, """;
      const toggleSidebar = """, toggleSidebar, """;
      const toggleInspector = """, toggleInspector, """;
      const focusInspector = """, focusInspector, """;
      const previousElement = """, previousElement, """;
      const nextElement = """, nextElement, """;
      const parentElement = """, parentElement, """;
      const childElement = """, childElement, """;
      const save = """, save, """;
      const undo = """, undo, """;
      const redo = """, redo, """;
      let returnFocus = null;
      const isEditable = (target) => {
        if (!target) return false;
        const tag = String(target.tagName || '').toLowerCase();
        return tag === 'input' || tag === 'textarea' || target.isContentEditable;
      };
      const paletteOpen = () => {
        const palette = document.querySelector('[data-editor-command-palette="true"]');
        return palette && palette.getAttribute('aria-hidden') === 'false';
      };
      window.addEventListener('keydown', function (event) {
        const key = event.key;
        const code = event.code;
        const lower = String(key || '').toLowerCase();
        const mod = event.metaKey || event.ctrlKey;
        const editable = isEditable(event.target);
        if (mod && lower === 'k') {
          returnFocus = document.activeElement;
          event.preventDefault();
          openPalette();
          const palette = document.querySelector('[data-editor-command-palette="true"]');
          if (palette) palette.__isonimReturnFocus = returnFocus;
          setTimeout(() => {
            const input = document.querySelector('[aria-label="Search editor commands"]');
            if (input && input.focus) input.focus({ preventScroll: true });
          }, 0);
          return;
        }
        if (key === 'Escape' && paletteOpen()) {
          event.preventDefault();
          closePalette();
          if (returnFocus && returnFocus.focus) {
            setTimeout(() => returnFocus.focus({ preventScroll: true }), 0);
          }
          return;
        }
        if (editable) return;
        if (mod && (key === '\\' || key === 'Backslash' || code === 'Backslash')) {
          event.preventDefault();
          toggleSidebar();
        } else if (mod && (key === '/' || key === 'Slash' || code === 'Slash')) {
          event.preventDefault();
          toggleInspector();
        } else if (mod && lower === 's') {
          event.preventDefault();
          save();
        } else if (mod && event.shiftKey && lower === 'z') {
          event.preventDefault();
          redo();
        } else if (mod && lower === 'z') {
          event.preventDefault();
          undo();
        } else if (event.altKey && key === 'ArrowUp') {
          event.preventDefault();
          previousElement();
        } else if (event.altKey && key === 'ArrowDown') {
          event.preventDefault();
          nextElement();
        } else if (event.altKey && key === 'ArrowLeft') {
          event.preventDefault();
          parentElement();
        } else if (event.altKey && key === 'ArrowRight') {
          event.preventDefault();
          childElement();
        } else if (lower === 'e') {
          event.preventDefault();
          editMode();
        } else if (lower === 'c') {
          event.preventDefault();
          commentMode();
        } else if (lower === 'v') {
          event.preventDefault();
          viewMode();
        } else if (lower === 'i') {
          event.preventDefault();
          focusInspector();
          setTimeout(() => {
            const input = document.querySelector('[data-isonim-focus-id="section-search"]');
            if (input && input.focus) input.focus({ preventScroll: true });
          }, 0);
        }
      });
    })();
  """].}

proc editorRouteUrl(vm: EditorVM): string =
  var parts = @[
    "view=" & encodeParam(viewSlug(vm.activeView.val)),
    "viewport=" & encodeParam(viewportSlug(vm.viewport.val)),
    "mode=" & encodeParam(editModeSlug(vm.editMode.val)),
    "sidebar=" & boolSlug(vm.panels.val.sidebar),
    "inspector=" & boolSlug(vm.panels.val.inspector),
    "section=" & encodeParam(inspectorSectionSlug(
        vm.inspector.activeSection.val))
  ]
  if routeParam("writeBridge") == "0":
    parts.add "writeBridge=0"

  let story = vm.selectedStory.val
  if story.group.len > 0 and story.name.len > 0:
    parts.add "storyGroup=" & encodeParam(story.group)
    parts.add "story=" & encodeParam(story.name)
    parts.add "kind=" & encodeParam(storyKindSlug(story.kind))
    parts.add "index=" & $story.index

  currentPathname() & "?" & parts.join("&")

proc syncEditorRouteNow(vm: EditorVM; replace: bool) =
  let next = editorRouteUrl(vm)
  let current = currentRouteUrl()
  if next == current or next == lastSyncedRoute:
    lastSyncedRoute = current
    return

  writeRouteUrl(next, replace)
  lastSyncedRoute = next

proc scheduleEditorRouteSync(vm: EditorVM) =
  if applyingRoute or routeSyncScheduled:
    return

  routeSyncScheduled = true
  deferRouteWrite proc() =
    routeSyncScheduled = false
    if not applyingRoute:
      syncEditorRouteNow(vm, replace = not routeHistoryInitialized)
      routeHistoryInitialized = true

proc applyEditorRoute(vm: EditorVM) =
  let viewParam = routeParam("view")
  if viewParam.len > 0:
    vm.activeView.val = viewFromSlug(viewParam, vm.activeView.val)
  elif hasEditorRouteOverride():
    vm.activeView.val = hashEditorView()

  let sectionParam = routeParam("section")
  if sectionParam.len > 0:
    vm.inspector.activeSection.val = inspectorSectionFromSlug(sectionParam,
      vm.inspector.activeSection.val)
  elif hasEditorRouteOverride():
    vm.inspector.activeSection.val = hashInspectorSection()

  let viewportParam = routeParam("viewport")
  if viewportParam.len > 0:
    vm.changeViewport(viewportFromSlug(viewportParam, vm.viewport.val))

  let modeParam = routeParam("mode")
  if modeParam.len > 0:
    vm.setEditMode(editModeFromSlug(modeParam, vm.editMode.val))

  let panels = vm.panels.val
  let sidebarParam = routeParam("sidebar")
  let inspectorParam = routeParam("inspector")
  if sidebarParam.len > 0 or inspectorParam.len > 0:
    vm.panels.val = PanelVisibility(
      sidebar: boolFromSlug(sidebarParam, panels.sidebar),
      inspector: boolFromSlug(inspectorParam, panels.inspector))

  let storyGroup = routeParam("storyGroup")
  let storyName = routeParam("story")
  if storyGroup.len > 0 and storyName.len > 0:
    let story = StoryRef(
      group: storyGroup,
      name: storyName,
      kind: storyKindFromSlug(routeParam("kind"), vm.selectedStory.val.kind),
      index: parseRouteIndex(routeParam("index"), 0))
    discard vm.selectStory(story)
    if viewParam.len > 0:
      vm.activeView.val = viewFromSlug(viewParam, vm.activeView.val)

proc installEditorHistorySync(vm: EditorVM) =
  routeSyncScheduled = false
  routeHistoryInitialized = false
  lastSyncedRoute = ""
  applyingRoute = true
  if hasEditorRouteOverride():
    applyEditorRoute(vm)
  applyingRoute = false
  syncEditorRouteNow(vm, replace = true)
  routeHistoryInitialized = true

  createRenderEffect proc() =
    discard vm.activeView.val
    discard vm.selectedStory.val
    discard vm.viewport.val
    discard vm.editMode.val
    discard vm.panels.val
    discard vm.inspector.activeSection.val
    scheduleEditorRouteSync(vm)

  let onPopstate = proc() =
    applyingRoute = true
    applyEditorRoute(vm)
    lastSyncedRoute = currentRouteUrl()
    applyingRoute = false

  addPopstateListener(onPopstate)
  onCleanup proc() =
    removePopstateListener(onPopstate)

proc exposeWindowEditorHandle*(vm: EditorVM) =
  ## REV-M2: install a small ``window.__isonimEditor`` helper that the
  ## design-review e2e tests use to drive story selection.  The handle
  ## exposes ``selectStoryByName(group, name)`` (constructs a synthetic
  ## ``StoryRef`` and feeds it through ``EditorVM.selectedStory``) and
  ## AIVS-NSO ``setEditMode(modeIndex)`` (drives ``vm.setEditMode``
  ## directly so the no-story overlay e2e can exercise the mode-specific
  ## copy paths even when the mode chip's dispatcher is gated by the
  ## "select a story first" guard).  No other public surface is
  ## exposed; production consumers must use the regular sidebar /
  ## chrome-bar affordances.
  let capturedVm = vm
  proc selectByName(group, name: cstring) =
    let story = StoryRef(
      group: $group,
      name: $name,
      kind: skPage,
      index: 0)
    capturedVm.selectedStory.val = story
  proc setEditModeByIndex(modeIndex: int) =
    let mode =
      case modeIndex
      of 0: emView
      of 1: emComment
      of 2: emEdit
      else: emView
    capturedVm.setEditMode(mode)
  # 2026-05-28: drag-resize handles for the left sidebar and the right
  # panel call into these closures so the JS-side mousemove handler
  # can push the new width back through the VM (which clamps).
  proc setLeftSidebar(width: int) =
    capturedVm.setLeftSidebarWidth(width)
  proc setRightPanel(width: int) =
    capturedVm.setRightPanelWidth(width)
  # Expose as a window-level handle. We install the helper inside an
  # IIFE so the closures (``selectByName`` / ``setEditModeByIndex``)
  # are captured by reference and so the wrapper returns ``true``
  # regardless of the closure's internal return value — the e2e tests
  # only check for truthiness.
  let cb = selectByName
  let cbMode = setEditModeByIndex
  let cbLeftWidth = setLeftSidebar
  let cbRightWidth = setRightPanel
  {.emit: ["""
    (function () {
      const fn = """, cb, """;
      const fnMode = """, cbMode, """;
      const fnLeftW = """, cbLeftWidth, """;
      const fnRightW = """, cbRightWidth, """;
      window.__isonimEditor = window.__isonimEditor || {};
      window.__isonimEditor.selectStoryByName = function (group, name) {
        fn(group, name);
        return true;
      };
      window.__isonimEditor.setEditMode = function (modeIndex) {
        fnMode(modeIndex | 0);
        return true;
      };
      window.__isonimEditor.setLeftSidebarWidth = function (width) {
        fnLeftW(width | 0);
        return true;
      };
      window.__isonimEditor.setRightPanelWidth = function (width) {
        fnRightW(width | 0);
        return true;
      };
    })();
  """].}

proc mountEditor*(workspace: EditorWorkspace;
                  root: Element = document.body;
                  useHashRoute = true;
                  injectStyles = true): EditorVM =
  ## Mount the editor shell into a DOM element and return the live VM.
  ##
  ## The returned VM is useful for tests and host-app integrations that need to
  ## drive the editor after mount.
  if injectStyles:
    injectEditorStyles()

  var mounted: EditorVM
  createRoot proc(dispose: proc()) =
    let vm = createEditorVM(workspace)
    when defined(js):
      # RS-M11 Pattern A: the JS bundle needs the streaming-preview
      # VM so the non-Web canvas can route F/M/I packets and surface
      # manifest selections back to the sidebar. createEditorVM
      # leaves the field nil per the M57 headless contract; the
      # JS mount path opts in here.  Web stays the default backend;
      # the chip click flips `vm.platform` AND
      # `streamingPreview.selectedBackend`.
      vm.streamingPreview = newStreamingPreviewVM(initial = pbWeb,
        available = @[pbWeb, pbTui, pbGpui, pbFreya, pbCocoa,
                      pbAndroid, pbIos])
    mounted = vm
    # Phase C: install the daemon-driven agent adapter on top of any
    # workspace-supplied placeholder.  The chat panel and the brief
    # tab's "Review this preview" button both drive the daemon's
    # ``/api/agent/*`` routes via the resolved base URL.  This is the
    # production wiring; VM tests inject a fake client via
    # ``configureAgentAdaptersWithClient`` instead.
    discard configureDaemonAgentAdapters(vm.chat)
    vm.setTelemetryOverlayVisible(editorDebugEnabled())
    if useHashRoute:
      installEditorHistorySync(vm)
    installEditorKeyboardShortcuts(vm)

    let r = DomRenderer()
    let shell = renderEditorShell[DomRenderer, DomElement](r, vm)
    {.emit: [shell, ".style.position='fixed'"].}
    {.emit: [shell, ".style.inset='0'"].}
    {.emit: [shell, ".style.overflow='hidden'"].}
    root.appendChild(shell)
    # REV-M2: expose a tiny window-level handle so Playwright e2e
    # tests can drive story selection without having to scrape the
    # sidebar DOM (which omits stories that aren't part of the demo
    # workspace).  The handle is intentionally minimal — production
    # consumers should not rely on it.
    exposeWindowEditorHandle(vm)
  mounted
