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
    /* Discreet scrollbars, editor-wide.
     *
     * The platform default is a 15px light-grey bar that reads as chrome in
     * its own right -- in a dark tool it is the brightest thing on screen,
     * and the editor stacks several scroll regions, so the defaults compete
     * with the content for attention.
     *
     * Overlay-style: thin, transparent track, thumb only, and only visibly
     * darker on hover. Firefox gets `scrollbar-width` / `scrollbar-color`,
     * which is the whole of what it offers.
     */
    * {
      scrollbar-width: thin;
      scrollbar-color: rgba(255, 255, 255, 0.16) transparent;
    }
    ::-webkit-scrollbar { width: 8px; height: 8px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-corner { background: transparent; }
    ::-webkit-scrollbar-thumb {
      background-color: rgba(255, 255, 255, 0.14);
      border-radius: 4px;
      /* Inset with a transparent border so the thumb reads as 4px of colour
       * inside an 8px track rather than a slab against the content. */
      border: 2px solid transparent;
      background-clip: padding-box;
    }
    ::-webkit-scrollbar-thumb:hover {
      background-color: rgba(255, 255, 255, 0.28);
    }

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
  of emSpec: "spec"
  of emView: "view"
  of emComment: "comment"
  of emEdit: "edit"

func editModeFromSlug(slug: string; fallback: EditMode): EditMode =
  case slug.normalize
  of "spec", "specification": emSpec
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
        if (tag === 'input' || tag === 'textarea' || target.isContentEditable) {
          return true;
        }
        // EPP-M7. When the preview canvas owns keyboard focus, the
        // JS shim in streaming_preview.nim toggles
        // ``data-isonim-canvas-focused="true"`` on the body. Treat
        // a focused canvas like any other text-input surface so the
        // chrome bar's window-level shortcuts (cmd-\ sidebar, cmd-/
        // inspector, e / c / v mode toggles, etc.) don't compete
        // with the launcher's per-key handlers. The chrome bar
        // shortcuts come back as soon as the user presses Esc to
        // release canvas focus.
        if (tag === 'canvas') {
          try {
            if (document.body &&
                document.body.getAttribute(
                  'data-isonim-canvas-focused') === 'true') {
              return true;
            }
          } catch (_) {}
        }
        return false;
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
        // Save is exempt from the editable-target early return. Every other
        // shortcut here would fight the field the user is typing in; this one
        // is the thing they reach for immediately AFTER typing a value, and
        // returning early made it dead in exactly that moment.
        if (mod && lower === 's') {
          event.preventDefault();
          save();
          return;
        }
        if (editable) return;
        if (mod && (key === '\\' || key === 'Backslash' || code === 'Backslash')) {
          event.preventDefault();
          toggleSidebar();
        } else if (mod && (key === '/' || key === 'Slash' || code === 'Slash')) {
          event.preventDefault();
          toggleInspector();
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
    # Phase I (2026-05-28): the mode strip now carries four options —
    # Spec / View / Comment / Edit. Index 0 is Spec; the prior
    # 0/1/2 → View/Comment/Edit mapping shifts to 1/2/3. Out-of-range
    # values fall back to emView (the historical default).
    let mode =
      case modeIndex
      of 0: emSpec
      of 1: emView
      of 2: emComment
      of 3: emEdit
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
  # Saving, and saying what happened. Every other exposure returns `true`
  # unconditionally because the e2e tests only check truthiness -- which is
  # exactly wrong for a command that writes files, where "it ran" and "it
  # worked" are different answers and the interesting one is WHY NOT.
  #
  # Needed because `Mod+S` is unreachable from a test that has just typed
  # into a field: the keydown handler returns early for an editable target,
  # so the shortcut a person uses after typing a value is the one path a
  # browser test cannot exercise.
  let cbSave = proc(): cstring =
    let state = vm.runEditorCommand(eckSave)
    if state.diagnostic.len > 0: state.diagnostic.cstring
    else: "".cstring
  let cbPending = proc(): int =
    vm.inspector.pendingSourceEdits.val.len

  # ---- Source changed on disk: rebuild arrived, redraw ------------------ #
  #
  # The dev server watches the project, rebuilds when anything changes and
  # broadcasts over the same SSE channel isonim's HMR uses
  # (`/__isonim/hmr`, `update` / `error`). This is the client half.
  #
  # **This loads the new bundle. It does not reload the page.** The first
  # version did reload, and it was wrong for the case that matters most: the
  # editor writes files itself, so every property you changed in the inspector
  # rebuilt the bundle, broadcast an update, and reloaded the editor out from
  # under you. An editor that restarts each time you nudge a value is not
  # usable, and no amount of session-snapshotting makes it feel otherwise --
  # the reload also threw away the undo stacks, the focused input and every
  # piece of state nobody had thought to snapshot.
  #
  # What replaces it is isonim's own mechanism, which `hmr_livereload.nim`
  # already routes every JS change through: append a `<script>` for the fresh
  # bundle and let it re-run the project's entry point. `mountEditor` sees a
  # live editor and calls `loadProjectData` on it instead of mounting a second
  # one, so the new bundle's project procs replace the old ones inside the
  # running editor and the reactive graph recomputes what depended on them.
  # Nothing is torn down, so nothing needs restoring.
  #
  # The old bundle's code stays resident -- this is a dev-mode swap, not a
  # module system -- and its closures are simply no longer reachable from the
  # VM once `loadProjectData` has replaced them. What makes that safe is that
  # Nim's JS backend compiles top-level vars to globals, so the reactive
  # graph's `Owner` / `Listener` / `Effects` / `Updates` are shared by name
  # between the two bundles rather than duplicated; see `liveEditorVM`.
  when defined(js):
    let buildFailed = proc(message: cstring) =
      vm.workspaceEditStage.val = wesFailed
      vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(
        kind: wedCompileFailed,
        message: "The project failed to rebuild: " & $message)]
    let buildRecovered = proc() =
      # A failed build leaves the status bar saying so. Clear it on the next
      # success, or the editor keeps reporting a compile error that has been
      # fixed -- which teaches people to ignore the status bar.
      if vm.workspaceEditStage.val == wesFailed:
        vm.workspaceEditStage.val = wesClean
        vm.workspaceEditDiagnostics.val = @[]
    {.emit: ["""
      (function (buildFailed, buildRecovered) {
        let applying = false;
        let queued = null;

        function applyBundle(url) {
          // One swap at a time. A burst of saves can deliver several updates
          // while a script is still evaluating, and two bundles evaluating
          // concurrently would race on the globals they share. The last URL
          // wins, because it is the only one whose bytes match the tree.
          if (applying) { queued = url; return; }
          applying = true;
          const script = document.createElement('script');
          // Cache-bust: the server already varies the URL per build, but a
          // client that reconnected and replayed an older URL would otherwise
          // be served from cache.
          script.src = url + (url.indexOf('?') < 0 ? '?' : '&') +
            'hot=' + Date.now();
          script.async = false;
          script.onload = function () {
            // The bundle has re-run the project entry point by now, which
            // means `mountEditor` has already adopted the live VM.
            script.remove();
            applying = false;
            buildRecovered();
            const next = queued;
            queued = null;
            if (next) applyBundle(next);
          };
          script.onerror = function () {
            script.remove();
            applying = false;
            buildFailed('the rebuilt bundle could not be loaded from ' + url);
          };
          document.head.appendChild(script);
        }

        let source = null;
        function connect() {
          try {
            source = new EventSource('/__isonim/hmr');
          } catch (e) {
            return;
          }
          source.addEventListener('update', function (event) {
            // Per isonim/web/hmr_sse.nim the payload IS the bundle URL.
            const url = (event && event.data) ? String(event.data) : '';
            if (url) applyBundle(url);
          });
          source.addEventListener('error', function (event) {
            // A Nim error is the single most useful thing a person can see
            // here. Swallowing it makes a broken build look like a hung
            // editor -- the change lands, nothing moves, nothing says why.
            const text = (event && event.data) ? String(event.data) : '';
            if (text) buildFailed(text);
          });
        }
        connect();
      })(""", buildFailed, ", ", buildRecovered, ");"].}

  # Auto-save. The VM bumps a generation when a commit stages an edit; the
  # debounce lives here because the VM has no timer and should not grow one
  # -- a commit that wrote immediately would write once per keystroke in a
  # numeric field.
  #
  # There is no manual mode. `Mod+S` still works and still saves NOW rather
  # than in 900ms, because a person who reaches for it is telling you they
  # do not want to wait.
  #
  # 900ms: long enough to type "1", "12", "120" as one edit, short enough
  # that looking away and back finds the file already written.
  when defined(js):
    var lastAutoSaveGeneration = 0
    let runAutoSave = proc() =
      if vm.inspector.pendingSourceEdits.val.len > 0:
        discard vm.runEditorCommand(eckSave)
    createRenderEffect proc() =
      let generation = vm.autoSaveGeneration.val
      if generation == lastAutoSaveGeneration:
        return
      lastAutoSaveGeneration = generation
      let fire = runAutoSave
      {.emit: ["""
        (function (fire) {
          if (window.__isonimAutoSaveTimer) {
            clearTimeout(window.__isonimAutoSaveTimer);
          }
          window.__isonimAutoSaveTimer = setTimeout(function () {
            window.__isonimAutoSaveTimer = null;
            fire();
          }, 900);
        })(""", fire, ");"].}
  {.emit: ["""
    (function () {
      const fn = """, cb, """;
      const fnMode = """, cbMode, """;
      const fnLeftW = """, cbLeftWidth, """;
      const fnRightW = """, cbRightWidth, """;
      const fnSave = """, cbSave, """;
      const fnPending = """, cbPending, """;
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
      // Returns "" when the save succeeded, or the refusal. Not a boolean:
      // "this workspace is read-only" and "no adapter is ready" are
      // different problems with different fixes.
      window.__isonimEditor.save = function () { return String(fnSave()); };
      // How many source edits are staged and waiting for a save.
      window.__isonimEditor.pendingSourceEdits = function () {
        return fnPending() | 0;
      };

    })();
  """].}

proc liveEditorVM(): EditorVM =
  ## The VM of an editor already mounted in this document, or nil.
  ##
  ## Stashed on `globalThis` rather than in a module-level `var` on purpose: a
  ## hot bundle swap re-runs the whole bundle, which re-initialises every
  ## module-level var, so a module-level handle would always read nil and every
  ## swap would mount a second editor. `globalThis` is the one place both the
  ## old and the new bundle can see.
  ##
  ## Reading a VM built by the PREVIOUS bundle and then driving it with THIS
  ## bundle's code is sound for the same reason the rest of isonim's HMR is:
  ## the JS backend compiles field names deterministically from the source, so
  ## two builds of the same declarations agree on them, and it compiles
  ## top-level vars to globals, so `Owner`, `Listener`, `Effects` and `Updates`
  ## are shared by name rather than duplicated. The reactive graph the old
  ## bundle built is the graph this bundle writes to. If the editor's own type
  ## declarations change, that assumption breaks -- and so does every other
  ## HMR swap, which is why a changed editor needs a real reload.
  when defined(js):
    {.emit: [result, " = globalThis.__isonimEditorVm || null;"].}
  else:
    nil

proc rememberLiveEditorVM(vm: EditorVM) =
  when defined(js):
    {.emit: ["globalThis.__isonimEditorVm = ", vm, ";"].}
  else:
    discard vm

proc clearPreviewStyleOverrides() =
  ## Forget the optimistic preview overrides, without touching the frame that
  ## is currently on screen.
  ##
  ## The overrides bridge the gap between making an edit and the rebuild that
  ## makes it real -- see `applyPreviewStyle` in widgets/property_commit.nim.
  ## Once the rebuilt source carries the value they are not merely redundant:
  ## they are applied inline with `!important`, so they outrank the stylesheet,
  ## and an override that outlives its rebuild makes the editor show a value
  ## the saved source does not produce.
  ##
  ## **Only the store is cleared.** An earlier version also removed the inline
  ## styles from the live frame, and that was visibly wrong: the swap replaces
  ## the preview document asynchronously, so for the few hundred milliseconds
  ## between clearing and the new frame painting, the OLD frame was on screen
  ## with the override gone and the old stylesheet still compiled in. The value
  ## flickered back to what it had been before the edit and then forward again
  ## -- measured at 434ms of showing the user the number they had just replaced.
  ##
  ## Clearing the store alone is enough, because the store exists to re-apply
  ## overrides to a NEW frame. The frame being replaced keeps its inline styles
  ## for the rest of its short life, and the frame that replaces it is built
  ## from source that already has the value.
  when defined(js):
    {.emit: """
      window.__isonimPreviewOverrides = {};
      // `__isonimPreviewStylesheet` deliberately SURVIVES the bundle swap.
      //
      // It looks redundant here -- the rebuilt bundle carries the same CSS --
      // and clearing it is wrong for the same reason clearing the overrides
      // here is right. Rebuilds lag edits: the bundle arriving now was
      // compiled from an EARLIER edit, so a later edit's stylesheet is still
      // the only record of what the file actually says. Dropping it made the
      // preview flash back to the previous value.
      //
      // It is a single value that each save replaces, so nothing accumulates,
      // and adopting it is idempotent -- once the compiled CSS matches, the
      // adopt is a no-op.
    """.}

proc mountEditor*(workspace: EditorWorkspace;
                  root: Element = document.body;
                  useHashRoute = true;
                  injectStyles = true): EditorVM =
  ## Mount the editor shell into a DOM element and return the live VM.
  ##
  ## The returned VM is useful for tests and host-app integrations that need to
  ## drive the editor after mount.
  ##
  ## **Called a second time in the same document, this does not mount a second
  ## editor.** That is not a defensive nicety, it is the hot-reload path. When
  ## a source file changes, the dev server rebuilds the bundle and the client
  ## loads it with a script tag, which re-runs the project's entry point --
  ## `newGripEditorWorkspace()` and then this proc. The project's entry point
  ## needs to know nothing about any of that: building a workspace and handing
  ## it to `mountEditor` is the same code path on a first load and on the
  ## thousandth rebuild. Only the outcome differs.
  ##
  ## On a swap the editor keeps its VM and takes only the PROJECT's data from
  ## the new bundle, via `loadProjectData`. Nothing is torn down, so there is
  ## nothing to restore: the selection, the scroll positions, the expanded
  ## sections, the undo stacks and the focused input are all still where they
  ## were, because they were never destroyed. That is the difference between
  ## this and the `location.reload()` it replaced -- a reload could put the
  ## user's place back approximately, from a sessionStorage snapshot, and only
  ## the parts somebody had remembered to snapshot.
  when defined(js):
    let live = liveEditorVM()
    if live != nil:
      # Before `loadProjectData`, which bumps `preview.sourceGeneration` and so
      # rebuilds the preview: the overrides must be gone by the time the new
      # frame asks for them, or the frame-start re-apply puts them straight
      # back on top of the source that now carries the same values.
      clearPreviewStyleOverrides()
      live.loadProjectData(workspace)
      return live

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
    # Last thing on the first-mount path: from here on a re-run of this bundle
    # is a swap, and `liveEditorVM` above is how it finds out.
    rememberLiveEditorVM(vm)
  mounted
