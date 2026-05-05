## Browser runtime helpers for embedding the IsoNim Editor.
##
## Project entry points can import this module, construct an EditorWorkspace,
## and mount it into any DOM element.

when not defined(js):
  {.error: "isonim/editor/browser must be compiled with `nim js`".}

import std/[dom, strutils]

import isonim/core/[computation, owner, signals]
import isonim/editor/dom_renderer
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/views/shell

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
    .editor-sidebar,
    .editor-chat,
    .editor-manual-inspector {
      scrollbar-width: thin;
    }
    .editor-sidebar::-webkit-resizer,
    .editor-chat::-webkit-resizer,
    .editor-manual-inspector::-webkit-resizer {
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
    @media (max-width: 768px) {
      .editor-sidebar { width: 100% !important; min-width: 100% !important; }
      .editor-preview { display: none !important; }
      .editor-inspector { display: none !important; }
      .editor-chat { display: none !important; }
      .editor-mobile-toggle { display: flex !important; }
    }
    .editor-mobile-toggle { display: none; }
    @media (max-width: 1024px) and (min-width: 769px) {
      .editor-sidebar { width: 220px !important; min-width: 220px !important; }
      .editor-inspector,
      .editor-chat,
      .editor-manual-inspector { width: min(320px, 38vw) !important; min-width: min(320px, 38vw) !important; max-width: min(320px, 38vw) !important; }
      .editor-tabbar > div { padding: 0 6px !important; font-size: 10px !important; }
    }
    .editor-input::placeholder { color: #475569; }
    .editor-input:focus { border-color: #3B82F6 !important; }
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
  of evVectorEditor: "vector"

func viewFromSlug(slug: string; fallback: EditorView): EditorView =
  case slug.normalize
  of "flow", "storyboard": evStoryboard
  of "detail", "component-detail": evComponentDetail
  of "edit", "component-edit": evComponentEdit
  of "page", "page-preview": evPagePreview
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

func storyKindFromSlug(slug: string; fallback: StoryKind): StoryKind =
  case slug.normalize
  of "foundation": skFoundation
  of "component": skComponent
  of "pattern": skPattern
  of "page": skPage
  of "flow": skFlow
  of "guideline": skGuideline
  else: fallback

func viewportSlug(viewport: PreviewViewport): string =
  case viewport
  of pvDesktop: "desktop"
  of pvTablet: "tablet"
  of pvMobile: "mobile"

func viewportFromSlug(slug: string; fallback: PreviewViewport): PreviewViewport =
  case slug.normalize
  of "desktop": pvDesktop
  of "tablet": pvTablet
  of "mobile": pvMobile
  else: fallback

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
    mounted = vm
    if useHashRoute:
      installEditorHistorySync(vm)

    let r = DomRenderer()
    let shell = renderEditorShell[DomRenderer, DomElement](r, vm)
    {.emit: [shell, ".style.position='fixed'"].}
    {.emit: [shell, ".style.inset='0'"].}
    {.emit: [shell, ".style.overflow='hidden'"].}
    root.appendChild(shell)
  mounted
