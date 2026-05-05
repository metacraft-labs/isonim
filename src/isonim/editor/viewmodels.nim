## IsoNim Editor — all ViewModel types.
##
## Pure state machines using IsoNim reactive primitives.
## No CSS, no colors, no rendering — only signals, memos, and enums.
## Created via withViewModel inside createRoot.

import std/[algorithm, json, math, sequtils, strutils]
import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim/editor/types

export types

# ===========================================================================
# All ViewModel types (single type block for forward references)
# ===========================================================================

type
  SidebarVM* = ref object of ViewModel
    groups*: Signal[seq[StoryGroup]]
    sections*: Signal[SidebarSectionExpansion]
    searchFilter*: Signal[string]
    filteredItems*: Memo[seq[StoryGroup]]

  StoryboardVM* = ref object of ViewModel
    ## Canvas showing screen thumbnails connected by flow arrows.
    canvasItems*: Signal[seq[CanvasItem]]
    connections*: Signal[seq[FlowConnection]]
    zoom*: Signal[float]        ## Canvas zoom level (0.25..4.0)
    panX*, panY*: Signal[float] ## Canvas pan offset
    selectedItem*: Signal[int]  ## Index into canvasItems (-1 = none)
    hoveredItem*: Signal[int]

  InspectorVM* = ref object of ViewModel
    selectedElement*: Signal[ElementRef]
    layers*: Signal[seq[ElementLayerRow]]
    layerSearch*: Signal[string]
    sectionSearch*: Signal[string]
    expandedSections*: Signal[seq[InspectorSection]]
    focusedControlId*: Signal[string]
    commandPaletteHooksReady*: Signal[bool]
    expandedLayerIds*: Signal[seq[string]]
    hoveredElementId*: Signal[string]
    activeSection*: Signal[InspectorSection]
    editDiagnostics*: Signal[seq[PropertyEditDiagnostic]]
    pendingSourceEdits*: Signal[seq[SourceEditPlan]]
    sourcePreviews*: Signal[seq[CSSSourcePreview]]
    conflicts*: Signal[seq[CSSSourceConflict]]
    undoStack*: Signal[seq[CSSPropertyEditTransaction]]
    redoStack*: Signal[seq[CSSPropertyEditTransaction]]
    hasElement*: Memo[bool]
    properties*: Memo[seq[PropertyInfo]]
    filteredLayers*: Memo[seq[ElementLayerRow]]
    visibleSections*: Memo[seq[InspectorSection]]
    propertyEditors*: Memo[seq[CSSPropertyEditorVM]]
    denseRowContract*: Memo[InspectorDenseRowContract]
    largeControlContracts*: Memo[seq[InspectorLargeControlContract]]
    isDirty*: Memo[bool]
    ## CSS-specific state
    displayMode*: Signal[DisplayMode]
    flexDirection*: Signal[FlexDirection]

  VectorEditorVM* = ref object of ViewModel
    ## Embedded vector editor for SVG symbols.
    activeTool*: Signal[VectorTool]
    symbols*: Signal[seq[VectorSymbol]]
    document*: Signal[VectorDocument]
    adapter*: Signal[VectorAdapterContract]
    diagnostics*: Signal[seq[VectorDiagnostic]]
    undoStack*: Signal[seq[VectorEditTransaction]]
    redoStack*: Signal[seq[VectorEditTransaction]]
    searchFilter*: Signal[string]
    filteredSymbols*: Memo[seq[VectorSymbol]]
    selectedSymbol*: Signal[int] ## Index into symbols (-1 = none)
    isEditing*: Memo[bool]
    isDirty*: Memo[bool]
    zoom*: Signal[float]
    panX*, panY*: Signal[float]
    showGrid*: Signal[bool]
    snapToGrid*: Signal[bool]
    gridSize*: Signal[float]

  FoundationEditorVM* = ref object of ViewModel
    tokens*: Signal[seq[FoundationTokenEntry]]
    selectedCategory*: Signal[FoundationTokenKind]
    selectedTokenKey*: Signal[string]
    searchFilter*: Signal[string]
    impacts*: Signal[seq[FoundationTokenImpact]]
    diagnostics*: Signal[seq[FoundationEditDiagnostic]]
    undoStack*: Signal[seq[FoundationEditHistoryEntry]]
    redoStack*: Signal[seq[FoundationEditHistoryEntry]]
    availableCategories*: Memo[seq[FoundationTokenKind]]
    filteredTokens*: Memo[seq[FoundationTokenEntry]]
    selectedToken*: Memo[FoundationTokenEntry]
    isDirty*: Memo[bool]
    hasDiagnostics*: Memo[bool]

  ComponentVariantEditorVM* = ref object of ViewModel
    variants*: Signal[seq[ComponentVariantDefinition]]
    diagnostics*: Signal[seq[ComponentVariantDiagnostic]]
    stateDiagnostics*: Signal[seq[ComponentStateCoverageDiagnostic]]
    selectedVariant*: Signal[int]
    variantMatrix*: Memo[seq[ComponentVariantMatrixCell]]
    hasDiagnostics*: Memo[bool]

  AgentChatVM* = ref object of ViewModel
    messages*: Signal[seq[ChatMessage]]
    sessionStatus*: Signal[AsyncState]
    accumulatedEdits*: Signal[seq[EditRecord]]
    inputText*: Signal[string]
    connectionState*: Signal[string]
    planEntries*: Signal[seq[string]]
    toolCalls*: Signal[seq[string]]
    proposedEdits*: Signal[seq[AgentEditProposal]]
    permissionRequests*: Signal[seq[AgentPermissionRequest]]
    lastPromptContext*: Signal[AgentPromptContext]
    promptIncludesScreenshots*: Signal[bool]
    promptIncludesDomSnapshots*: Signal[bool]
    designSystemConstraints*: Signal[seq[string]]
    backend*: Signal[AgentBackendSelection]
    stopReason*: Signal[string]
    messageCount*: Memo[int]
    promptAdapter*: AgentPromptAdapter
    cancelAdapter*: AgentCancelAdapter

  ReviewResultsVM* = ref object of ViewModel
    violations*: Signal[seq[Violation]]
    annotations*: Signal[seq[ReviewAnnotation]]
    errorCount*: Memo[int]
    warningCount*: Memo[int]
    hasIssues*: Memo[bool]

  ProjectPreviewVM* = ref object of ViewModel
    hook*: ProjectPreviewHook
    current*: Memo[ProjectPreview]

  FlowPlayerVM* = ref object of ViewModel
    steps*: Signal[seq[FlowStep]]
    currentStep*: Signal[int]
    playState*: Signal[PlayState]
    totalSteps*: Memo[int]
    isFirstStep*: Memo[bool]
    isLastStep*: Memo[bool]
    currentAction*: Memo[string]

  EditorVM* = ref object of ViewModel
    activeView*: Signal[EditorView]
    selectedStory*: Signal[StoryRef]
    editMode*: Signal[EditMode]
    panels*: Signal[PanelVisibility]
    rightPanelWidth*: Signal[int]
    platform*: Signal[Platform]
    viewport*: Signal[PreviewViewport]
    workspacePermissions*: Signal[EditorWorkspacePermissions]
    sourceAdapterReady*: Signal[bool]
    workspaceEditStage*: Signal[WorkspaceEditStage]
    workspaceEditDiagnostics*: Signal[seq[WorkspaceEditDiagnostic]]
    workspaceEditPatches*: Signal[seq[WorkspaceFilePatch]]
    workspaceEditAffectedStories*: Signal[seq[StoryRef]]
    workspaceEditFullReload*: Signal[bool]
    workspaceEditGeneratedArtifacts*: Signal[seq[string]]
    workspaceEditRequiredTestCommands*: Signal[seq[string]]
    workspaceEditReviewDiagnostics*: Signal[seq[WorkspaceEditDiagnostic]]
    livePreviewReloadGeneration*: Signal[int]
    commandStates*: Signal[seq[EditorCommandState]]
    commandPaletteOpen*: Signal[bool]
    performanceBudgets*: Signal[seq[EditorPerformanceBudget]]
    telemetryEvents*: Signal[seq[EditorTelemetryEvent]]
    telemetryOverlayVisible*: Signal[bool]
    designSystemSchema*: Signal[DesignSystemSchema]
    workspaceEditAdapter*: WorkspaceEditAdapter
    sidebar*: SidebarVM
    storyboard*: StoryboardVM
    inspector*: InspectorVM
    vectorEditor*: VectorEditorVM
    foundations*: FoundationEditorVM
    variants*: ComponentVariantEditorVM
    chat*: AgentChatVM
    review*: ReviewResultsVM
    preview*: ProjectPreviewVM
    flowPlayer*: FlowPlayerVM
    hasSelection*: Memo[bool]

func isEmptyStory(story: StoryRef): bool =
  story.group.len == 0 and story.name.len == 0

func defaultWorkspacePermissions*(): EditorWorkspacePermissions =
  EditorWorkspacePermissions(
    readSource: true,
    writeSource: false,
    createStory: false,
    createVariant: false,
    duplicate: false,
    delete: false)

func vectorDocumentFromSymbol*(symbol: VectorSymbol): VectorDocument
func validateVectorAccessibility*(doc: VectorDocument): seq[VectorDiagnostic]
proc ensureComponentPropertySchemaForSelectedStory*(editor: EditorVM): bool
proc setSectionExpanded*(inspector: InspectorVM; section: InspectorSection;
    expanded: bool)
proc recordEditorTiming*(editor: EditorVM; kind: EditorPerformanceBudgetKind;
    durationMs: int; detail: string)

func commandLabel*(kind: EditorCommandKind): string =
  case kind
  of eckEdit: "Edit"
  of eckComment: "Comment"
  of eckInspect: "View"
  of eckApply: "Apply"
  of eckRevert: "Revert"
  of eckSave: "Save"
  of eckDiscard: "Discard"
  of eckDuplicate: "Duplicate"
  of eckDelete: "Delete"
  of eckCreateVariant: "Create variant"
  of eckCreateStory: "Create story"
  of eckOpenSource: "Open source"
  of eckSelectPrevious: "Select previous element"
  of eckSelectNext: "Select next element"
  of eckSelectParent: "Select parent element"
  of eckSelectChild: "Select child element"
  of eckFocusInspector: "Focus inspector"
  of eckIncrementProperty: "Increment property"
  of eckDecrementProperty: "Decrement property"
  of eckUndo: "Undo"
  of eckRedo: "Redo"
  of eckToggleSidebar: "Toggle sidebar"
  of eckToggleInspector: "Toggle inspector"
  of eckOpenCommandPalette: "Open command palette"
  of eckNavigateLayersUp: "Navigate layers up"
  of eckNavigateLayersDown: "Navigate layers down"

func allEditorCommandKinds*(): seq[EditorCommandKind] =
  @[
    eckEdit,
    eckComment,
    eckInspect,
    eckApply,
    eckRevert,
    eckSave,
    eckDiscard,
    eckDuplicate,
    eckDelete,
    eckCreateVariant,
    eckCreateStory,
    eckOpenSource,
    eckSelectPrevious,
    eckSelectNext,
    eckSelectParent,
    eckSelectChild,
    eckFocusInspector,
    eckIncrementProperty,
    eckDecrementProperty,
    eckUndo,
    eckRedo,
    eckToggleSidebar,
    eckToggleInspector,
    eckOpenCommandPalette,
    eckNavigateLayersUp,
    eckNavigateLayersDown
  ]

func commandShortcut*(kind: EditorCommandKind): string =
  case kind
  of eckEdit: "E"
  of eckComment: "C"
  of eckInspect: "V"
  of eckApply: "Mod+Enter"
  of eckRevert: "Shift+R"
  of eckSave: "Mod+S"
  of eckDiscard: "Shift+Escape"
  of eckDuplicate: "Mod+D"
  of eckDelete: "Backspace"
  of eckCreateVariant: "Shift+V"
  of eckCreateStory: "Shift+S"
  of eckOpenSource: "O"
  of eckSelectPrevious: "Alt+ArrowUp"
  of eckSelectNext: "Alt+ArrowDown"
  of eckSelectParent: "Alt+ArrowLeft"
  of eckSelectChild: "Alt+ArrowRight"
  of eckFocusInspector: "I"
  of eckIncrementProperty: "Shift+ArrowUp"
  of eckDecrementProperty: "Shift+ArrowDown"
  of eckUndo: "Mod+Z"
  of eckRedo: "Mod+Shift+Z"
  of eckToggleSidebar: "Mod+\\"
  of eckToggleInspector: "Mod+/"
  of eckOpenCommandPalette: "Mod+K"
  of eckNavigateLayersUp: "ArrowUp"
  of eckNavigateLayersDown: "ArrowDown"

func commandScope*(kind: EditorCommandKind): string =
  case kind
  of eckNavigateLayersUp, eckNavigateLayersDown:
    "layers"
  of eckIncrementProperty, eckDecrementProperty:
    "inspector"
  of eckSelectPrevious, eckSelectNext, eckSelectParent, eckSelectChild:
    "selection"
  of eckToggleSidebar, eckToggleInspector, eckOpenCommandPalette,
      eckFocusInspector:
    "chrome"
  else:
    "editor"

func commandDescription*(kind: EditorCommandKind): string =
  case kind
  of eckEdit: "Switch the selected story into edit mode."
  of eckComment: "Switch the selected story into comment mode."
  of eckInspect: "Return the selected story to view mode."
  of eckApply: "Apply staged inspector edits to the live preview."
  of eckRevert: "Revert staged source edits."
  of eckSave: "Save staged source edits through the workspace adapter."
  of eckDiscard: "Discard staged source and agent edits."
  of eckDuplicate: "Duplicate the selected source-backed element."
  of eckDelete: "Delete the selected source-backed element."
  of eckCreateVariant: "Create a variant from the selected element."
  of eckCreateStory: "Create a story from the selected element."
  of eckOpenSource: "Open the source location for the current selection."
  of eckSelectPrevious: "Move selection to the previous visible element."
  of eckSelectNext: "Move selection to the next visible element."
  of eckSelectParent: "Move selection to the parent element."
  of eckSelectChild: "Move selection to the first child element."
  of eckFocusInspector: "Move focus to the inspector section search."
  of eckIncrementProperty: "Increase the first numeric selected property."
  of eckDecrementProperty: "Decrease the first numeric selected property."
  of eckUndo: "Undo the last inspector or vector edit."
  of eckRedo: "Redo the last inspector or vector edit."
  of eckToggleSidebar: "Show or hide the left sidebar."
  of eckToggleInspector: "Show or hide the right inspector or chat panel."
  of eckOpenCommandPalette: "Open the command palette."
  of eckNavigateLayersUp: "Move upward in the visible layer tree."
  of eckNavigateLayersDown: "Move downward in the visible layer tree."

func allEditorShortcutBindings*(): seq[EditorShortcutBinding] =
  for kind in allEditorCommandKinds():
    result.add EditorShortcutBinding(
      kind: kind,
      shortcut: commandShortcut(kind),
      scope: commandScope(kind),
      description: commandDescription(kind))

func duplicateEditorShortcuts*(bindings: seq[EditorShortcutBinding]): seq[string] =
  var seen: seq[string] = @[]
  for binding in bindings:
    let key = binding.scope & ":" & binding.shortcut
    if key in seen and key notin result:
      result.add key
    else:
      seen.add key

func performanceBudgetLabel*(kind: EditorPerformanceBudgetKind): string =
  case kind
  of epbkStorySelection: "story selection"
  of epbkElementSelection: "element selection"
  of epbkModeSwitch: "mode switch"
  of epbkPropertyEditPreview: "property edit preview"
  of epbkSaveReload: "save and reload"
  of epbkLargeSidebarSearch: "large sidebar search"

func defaultEditorPerformanceBudgets*(): seq[EditorPerformanceBudget] =
  @[
    EditorPerformanceBudget(kind: epbkStorySelection,
      label: performanceBudgetLabel(epbkStorySelection), maxMs: 120),
    EditorPerformanceBudget(kind: epbkElementSelection,
      label: performanceBudgetLabel(epbkElementSelection), maxMs: 100),
    EditorPerformanceBudget(kind: epbkModeSwitch,
      label: performanceBudgetLabel(epbkModeSwitch), maxMs: 120),
    EditorPerformanceBudget(kind: epbkPropertyEditPreview,
      label: performanceBudgetLabel(epbkPropertyEditPreview), maxMs: 120),
    EditorPerformanceBudget(kind: epbkSaveReload,
      label: performanceBudgetLabel(epbkSaveReload), maxMs: 1000),
    EditorPerformanceBudget(kind: epbkLargeSidebarSearch,
      label: performanceBudgetLabel(epbkLargeSidebarSearch), maxMs: 160)
  ]

func sameStory(a, b: StoryRef): bool =
  a.group == b.group and a.name == b.name and a.kind == b.kind

func isEmptyStoryRef(story: StoryRef): bool =
  story.group.len == 0 and story.name.len == 0

func workspaceDiagnostic(kind: WorkspaceEditDiagnosticKind; message: string;
    file = ""; schemaKey = ""; property = ""): WorkspaceEditDiagnostic =
  WorkspaceEditDiagnostic(
    kind: kind,
    message: message,
    file: file,
    schemaKey: schemaKey,
    property: property)

func viewForStory(story: StoryRef): EditorView =
  case story.kind
  of skFlow:
    evPagePreview
  of skPage:
    evPagePreview
  of skFoundation:
    evFoundationsPage
  of skComponent, skPattern, skGuideline:
    evComponentDetail

func platformForViewport*(viewport: PreviewViewport): Platform =
  case viewport
  of pvDesktop:
    pfWeb
  of pvTablet:
    pfIOS
  of pvMobile:
    pfAndroid

func viewportForPlatform*(platform: Platform): PreviewViewport =
  case platform
  of pfWeb:
    pvDesktop
  of pfIOS:
    pvTablet
  of pfAndroid:
    pvMobile

func previewViewportLabel*(viewport: PreviewViewport): string =
  case viewport
  of pvDesktop:
    "Desktop"
  of pvTablet:
    "Tablet"
  of pvMobile:
    "Mobile"

func previewViewportWidth*(viewport: PreviewViewport): int =
  case viewport
  of pvDesktop:
    1280
  of pvTablet:
    834
  of pvMobile:
    390

func previewViewportHeight*(viewport: PreviewViewport): int =
  case viewport
  of pvDesktop:
    900
  of pvTablet:
    1112
  of pvMobile:
    844

func isShared(prop: PropertyInfo): bool =
  prop.sharedCount > 0

func isViewModelSource(file: string): bool =
  "viewmodel" in file.toLowerAscii()

func isTokenDrift(prop: PropertyInfo; newValue: string): bool =
  prop.origin == poThemeToken and newValue.strip.startsWith("#")

func isEmptyA11yEdit(prop: PropertyInfo; newValue: string): bool =
  (prop.name == "aria-label" or prop.name == "alt") and newValue.strip.len == 0

func normalizedCssName(name: string): string =
  name.strip.toLowerAscii()

func cssPropertyCategory*(property: string): CSSPropertyCategory =
  let prop = property.normalizedCssName()
  if prop in ["display", "visibility"]:
    cpcLayout
  elif prop in ["flex", "flex" & "-direction", "flex" & "-wrap",
      "flex" & "-grow", "flex" & "-shrink",
      "flex" & "-basis", "order", "align" & "-self",
      "align-items", "align-content", "justify-content",
      "justify-items", "place-items", "place-content", "place-self",
      "gap", "row-gap", "column-gap", "grid-template-columns",
      "grid-template-rows", "grid-template-areas", "grid-auto-flow",
      "grid-auto-columns", "grid-auto-rows", "grid-column", "grid-row",
      "grid-column-start", "grid-column-end", "grid-row-start",
      "grid-row-end", "grid-area"]:
    cpcFlexGrid
  elif prop in ["width", "height", "min-width", "min-height", "max-width",
      "max-height", "aspect-ratio"]:
    cpcSize
  elif prop in ["margin", "margin-top", "margin-right", "margin-bottom",
      "margin-left", "padding", "padding-top", "padding-right",
      "padding-bottom", "padding-left"]:
    cpcSpacing
  elif prop in ["position", "inset", "top", "right", "bottom", "left",
      "z-index"]:
    cpcPosition
  elif prop in ["font", "font-family", "font-size", "font-weight",
      "line-height", "letter-spacing", "text" & "-align",
      "text" & "-decoration", "text" & "-transform", "white-space"]:
    cpcTypography
  elif prop in ["color", "background", "background-color", "background-image",
      "fill", "stroke"]:
    cpcColor
  elif prop in ["border", "border-width", "border-color", "border-style",
      "border-radius", "border-top-width", "border-right-width",
      "border-bottom-width", "border-left-width", "border-top-color",
      "border-right-color", "border-bottom-color", "border-left-color",
      "border-top-style", "border-right-style", "border-bottom-style",
      "border-left-style", "outline", "outline-offset"]:
    cpcBorder
  elif prop in ["box-shadow", "text" & "-shadow", "filter", "backdrop-filter",
      "mix-blend-mode"]:
    cpcEffects
  elif prop.endsWith("filter") or prop in ["brightness", "contrast",
      "grayscale", "saturate", "sepia", "hue-rotate"]:
    cpcFilters
  elif prop in ["transition", "transition-property", "transition-duration",
      "transition-timing-function", "transition-delay", "animation"]:
    cpcTransitions
  elif prop in ["transform", "transform-origin", "translate", "scale",
      "rotate"]:
    cpcTransforms
  elif prop in ["overflow", "overflow-x", "overflow-y", "overscroll-behavior"]:
    cpcOverflow
  elif prop in ["cursor", "pointer-events", "user-select", "touch-action"]:
    cpcInteractionState
  else:
    cpcAccessibilityVisual

func allowedValueKinds*(category: CSSPropertyCategory): seq[CSSValueKind] =
  case category
  of cpcLayout, cpcFlexGrid:
    @[cvkKeyword, cvkLength, cvkPercentage, cvkLengthPercentage,
      cvkTokenReference]
  of cpcSize, cpcSpacing, cpcPosition:
    @[cvkKeyword, cvkLength, cvkPercentage, cvkLengthPercentage, cvkZIndex,
      cvkTokenReference]
  of cpcTypography:
    @[cvkKeyword, cvkLength, cvkPercentage, cvkFontStack, cvkTokenReference]
  of cpcColor:
    @[cvkColor, cvkGradient, cvkTokenReference]
  of cpcBorder:
    @[cvkKeyword, cvkLength, cvkColor, cvkTokenReference]
  of cpcEffects:
    @[cvkShadow, cvkFilter, cvkTransform, cvkTokenReference]
  of cpcFilters:
    @[cvkFilter, cvkPercentage, cvkTokenReference]
  of cpcTransitions:
    @[cvkTransition, cvkTimingFunction, cvkLength, cvkTokenReference]
  of cpcTransforms:
    @[cvkTransform, cvkLength, cvkPercentage, cvkTokenReference]
  of cpcOverflow:
    @[cvkOverflow, cvkKeyword]
  of cpcInteractionState:
    @[cvkKeyword, cvkTokenReference]
  of cpcAccessibilityVisual:
    @[cvkAccessibility, cvkKeyword, cvkColor, cvkTokenReference]

func cssSourcePlanKind*(prop: PropertyInfo; request: PropertyEditRequest;
    normalized: CSSPropertyValue): CSSSourcePlanKind =
  if request.newValue.strip.len == 0:
    return cspPropertyRemoval
  if prop.value.strip.len == 0:
    return cspPropertyAddition
  if prop.variantKey.len > 0 or prop.schemaKey.len > 0:
    if prop.origin == poThemeToken or normalized.kind == cvkTokenReference or
        prop.tokenName.len > 0:
      return cspTokenUpdate
    return cspStructuredSchemaUpdate
  if request.scope == pesShared or prop.origin == poThemeToken or
      normalized.kind == cvkTokenReference or prop.tokenName.len > 0:
    return cspTokenUpdate
  case prop.origin
  of poTailwindClass:
    cspTailwindClassReplacement
  of poSetStyle:
    cspInlineStyleUpdate
  of poThemeToken:
    cspTokenUpdate
  of poConstant:
    if prop.directStyleAllowed: cspInlineStyleUpdate else: cspStructuredSchemaUpdate
  of poInherited:
    cspPropertyAddition

proc tryParseFloatValue(raw: string; value: var float): bool =
  try:
    value = raw.parseFloat()
    true
  except ValueError:
    false

func hasUnsupportedNumericUnit(raw: string): bool =
  let text = raw.strip()
  if text.len == 0 or text.startsWith("calc("):
    return false

  var index = 0
  if text[index] in {'-', '+'}:
    inc index
  var sawDigit = false
  while index < text.len and (text[index].isDigit or text[index] == '.'):
    if text[index].isDigit:
      sawDigit = true
    inc index
  if not sawDigit or index >= text.len:
    return false

  let suffix = text[index .. ^1].toLowerAscii()
  if suffix in ["px", "rem", "em", "vw", "vh", "ch", "%", "ms", "s"]:
    return false
  suffix.allIt(it.isAlphaAscii)

func tokenNameFromRaw(raw: string): string =
  let text = raw.strip()
  if text.startsWith("token(") and text.endsWith(")"):
    return text[6 ..< text.len - 1].strip()
  if text.startsWith("$") and text.len > 1:
    return text[1 .. ^1].strip()
  if text.startsWith("var(--") and text.endsWith(")"):
    return text[6 ..< text.len - 1].strip()
  ""

proc parseCssPropertyValue*(property, raw: string;
    variant = crvBase): CSSPropertyValue =
  let text = raw.strip()
  let prop = property.normalizedCssName()
  result = CSSPropertyValue(raw: raw, canonical: text, variant: variant)

  let token = tokenNameFromRaw(text)
  if token.len > 0:
    result.kind = cvkTokenReference
    result.tokenName = token
    result.canonical = "token(" & token & ")"
    return

  if text.startsWith("calc(") and text.endsWith(")"):
    result.kind = cvkLengthPercentage
    return
  if text.contains("gradient("):
    result.kind = cvkGradient
    return
  if prop.contains("shadow"):
    result.kind = cvkShadow
    return
  if prop == "font-family":
    result.kind = cvkFontStack
    result.canonical = text.split(',').mapIt(it.strip()).join(", ")
    return
  if prop == "z-index":
    result.kind = cvkZIndex
    discard tryParseFloatValue(text, result.numeric)
    return
  if prop == "opacity":
    result.kind = cvkOpacity
    if text.endsWith("%"):
      var parsed = 0.0
      if tryParseFloatValue(text[0 ..< text.len - 1], parsed):
        result.numeric = parsed / 100.0
        result.canonical = $result.numeric
    else:
      discard tryParseFloatValue(text, result.numeric)
    return
  if prop in ["transition-duration", "transition-delay", "animation-duration",
      "animation-delay"]:
    for unit in ["ms", "s"]:
      if text.endsWith(unit):
        result.kind = cvkLength
        result.unit = unit
        discard tryParseFloatValue(text[0 ..< text.len - unit.len],
          result.numeric)
        return
  if prop.contains("timing-function") or text.startsWith("cubic-bezier("):
    result.kind = cvkTimingFunction
    return
  if prop.startsWith("transition"):
    result.kind = cvkTransition
    return
  if prop in ["transform", "translate", "scale", "rotate"]:
    result.kind = cvkTransform
    return
  if prop.contains("filter"):
    result.kind = cvkFilter
    return
  if prop.startsWith("overflow"):
    result.kind = cvkOverflow
    return
  if text.startsWith("#") or text.startsWith("rgb(") or
      text.startsWith("rgba(") or text.startsWith("hsl(") or
      text.startsWith("hsla("):
    result.kind = cvkColor
    result.canonical = text.toLowerAscii()
    return
  if text.endsWith("%"):
    result.kind = cvkPercentage
    result.unit = "%"
    discard tryParseFloatValue(text[0 ..< text.len - 1], result.numeric)
    return
  for unit in ["px", "rem", "em", "vw", "vh", "ch", "ms", "s"]:
    if text.endsWith(unit):
      result.kind = cvkLength
      result.unit = unit
      discard tryParseFloatValue(text[0 ..< text.len - unit.len], result.numeric)
      return
  if text in ["auto", "none", "inherit", "initial", "unset", "block", "flex",
      "grid", "inline", "inline-block", "visible", "hidden", "clip", "scroll",
      "auto", "relative", "absolute", "fixed", "sticky", "solid", "dashed",
      "dotted", "pointer", "default", "not-allowed"]:
    result.kind = cvkKeyword
    return
  result.kind = cvkKeyword

func cssDiagnostic(kind: PropertyEditDiagnosticKind; prop: PropertyInfo;
    message: string): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name)

proc validateCssPropertyValue*(prop: PropertyInfo; request: PropertyEditRequest;
    normalized: CSSPropertyValue): seq[PropertyEditDiagnostic] =
  if request.newValue.strip.len == 0:
    return @[]

  let category = cssPropertyCategory(prop.name)
  let allowed = allowedValueKinds(category)
  let propName = prop.name.normalizedCssName()
  let raw = normalized.raw.strip()
  if normalized.kind notin allowed and not (
      propName == "opacity" and normalized.kind == cvkOpacity):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "This property does not accept " & $normalized.kind & " values.")

  if hasUnsupportedNumericUnit(raw):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Unsupported CSS unit in '" & raw & "'.")
  if normalized.kind == cvkLength and normalized.unit notin ["px", "rem", "em",
      "vw", "vh", "ch", "ms", "s"]:
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Unsupported CSS length unit '" & normalized.unit & "'.")
  if normalized.kind == cvkLength:
    var parsed = 0.0
    if not tryParseFloatValue(raw[0 ..< raw.len - normalized.unit.len], parsed):
      result.add cssDiagnostic(pedInvalidCssValue, prop,
        "CSS length values must use a numeric amount.")
  if normalized.kind == cvkPercentage:
    var parsed = 0.0
    if raw.len <= 1 or not tryParseFloatValue(raw[0 ..< raw.len - 1], parsed):
      result.add cssDiagnostic(pedInvalidCssValue, prop,
        "CSS percentage values must use a numeric amount.")
  if normalized.kind in {cvkLength, cvkPercentage} and
      propName notin ["z-index", "rotate"] and
      normalized.numeric < 0 and propName.startsWith("padding"):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Padding values cannot be negative.")
  if propName in ["transition-duration", "transition-delay", "animation-duration",
      "animation-delay"] and normalized.kind == cvkLength and
      normalized.numeric < 0:
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Motion timing values cannot be negative.")
  if normalized.kind == cvkOpacity and (normalized.numeric < 0 or
      normalized.numeric > 1):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Opacity must be between 0 and 1.")
  if normalized.kind == cvkOpacity:
    var parsed = 0.0
    let opacityText = if raw.endsWith("%"): raw[0 ..< raw.len - 1] else: raw
    if not tryParseFloatValue(opacityText, parsed):
      result.add cssDiagnostic(pedInvalidCssValue, prop,
        "Opacity must be numeric.")
  if normalized.kind == cvkZIndex:
    var parsed = 0.0
    if normalized.canonical.contains(".") or
        not tryParseFloatValue(normalized.canonical, parsed):
      result.add cssDiagnostic(pedInvalidCssValue, prop,
        "z-index must be an integer.")
  if normalized.kind == cvkColor and raw.startsWith("#"):
    let hex = raw[1 .. ^1]
    if hex.len notin [3, 4, 6, 8] or
        not hex.allIt(it.isDigit or it.toLowerAscii() in {'a'..'f'}):
      result.add cssDiagnostic(pedInvalidCssValue, prop,
        "Hex colors must use 3, 4, 6, or 8 hexadecimal digits.")
  if normalized.kind == cvkGradient and not raw.endsWith(")"):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Gradient values must be complete function calls.")
  if normalized.kind == cvkTimingFunction and raw notin ["ease", "linear",
      "ease-in", "ease-out", "ease-in-out", "step-start", "step-end"] and
      not raw.startsWith("cubic-bezier(") and not raw.startsWith("steps("):
    result.add cssDiagnostic(pedInvalidCssValue, prop,
      "Timing functions must use a known keyword or function.")
  if normalized.kind == cvkTokenReference and normalized.tokenName.len == 0:
    result.add cssDiagnostic(pedInvalidTokenReference, prop,
      "Token references must name a token.")
  if normalized.kind == cvkTokenReference and normalized.tokenName == "missing":
    result.add cssDiagnostic(pedInvalidTokenReference, prop,
      "Unknown design token '" & normalized.tokenName & "'.")
  if propName == "display" and
      normalized.canonical == "contents" and prop.sharedCount > 0:
    result.add cssDiagnostic(pedInvalidPropertyCombination, prop,
      "Shared display: contents edits are not allowed because descendants lose layout ownership.")
  if prop.origin == poSetStyle and not prop.directStyleAllowed:
    result.add cssDiagnostic(pedSchemaViolation, prop,
      "Direct style edits are blocked unless the project source map explicitly allows them.")

func diagnostic(kind: PropertyEditDiagnosticKind; prop: PropertyInfo;
    message: string): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name)

func diagnostic(kind: PropertyEditDiagnosticKind; element: ElementRef;
    property, message: string): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: element.sourceFile,
    line: element.sourceLine,
    property: property)

proc editRecord(prop: PropertyInfo; request: PropertyEditRequest): EditRecord =
  let normalized = parseCssPropertyValue(prop.name, request.newValue)
  EditRecord(
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name,
    oldValue: prop.value,
    newValue: request.newValue,
    origin: prop.origin,
    originDetail: prop.originDetail,
    scope: request.scope,
    isShared: request.scope == pesShared,
    editOrigin: request.origin,
    sourcePlanKind: prop.cssSourcePlanKind(request, normalized))

proc sourcePlan(prop: PropertyInfo; request: PropertyEditRequest): SourceEditPlan =
  let normalized = parseCssPropertyValue(prop.name, request.newValue)
  let planKind = prop.cssSourcePlanKind(request, normalized)
  let before = prop.originDetail & " " & prop.name & ": " & prop.value
  let after = prop.originDetail & " " & prop.name & ": " & normalized.canonical
  let expectedOld =
    if prop.originDetail.startsWith("iframe-dom:"): ""
    else: prop.value
  let variantSuffix =
    if prop.variantKey.len > 0: ":" & prop.variantKey else: ""
  SourceEditPlan(
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name,
    oldValue: prop.value,
    newValue: normalized.canonical,
    originDetail: prop.originDetail,
    scope: request.scope,
    planKind: planKind,
    schemaKey: prop.schemaKey,
    tokenName: if normalized.tokenName.len > 0: normalized.tokenName else: prop.tokenName,
    variantKey: prop.variantKey,
    reversible: true,
    previewBefore: before,
    previewAfter: after,
    formatterHook: "format-css-source-plan",
    regeneratorHook:
      if planKind in {cspStructuredSchemaUpdate, cspTokenUpdate}:
        "regenerate-design-system"
      else:
        "",
    conflictKey: prop.sourceFile & ":" & $prop.sourceLine & ":" & prop.name &
      variantSuffix,
    expectedOldValue: expectedOld)

func primitiveUnitFromText(raw: string): string =
  let text = raw.strip()
  if text.len == 0:
    return ""
  var i = text.len - 1
  while i >= 0 and (text[i].isAlphaAscii or text[i] == '%'):
    dec i
  if i < text.len - 1:
    text[i + 1 .. ^1]
  else:
    ""

proc evalNumericExpression(raw: string; value: var float): bool =
  let text = raw.strip()
  if text.len == 0:
    return false
  var i = 0

  proc skipSpaces() =
    while i < text.len and text[i].isSpaceAscii:
      inc i

  proc parseFactor(v: var float): bool =
    skipSpaces()
    if i >= text.len:
      return false
    var sign = 1.0
    if text[i] == '+':
      inc i
    elif text[i] == '-':
      sign = -1.0
      inc i
    skipSpaces()
    let start = i
    var sawDigit = false
    while i < text.len and (text[i].isDigit or text[i] == '.'):
      if text[i].isDigit:
        sawDigit = true
      inc i
    if not sawDigit:
      return false
    try:
      v = sign * text[start ..< i].parseFloat()
      true
    except ValueError:
      false

  proc parseTerm(v: var float): bool =
    if not parseFactor(v):
      return false
    while true:
      skipSpaces()
      if i >= text.len or text[i] notin {'*', '/'}:
        return true
      let op = text[i]
      inc i
      var rhs = 0.0
      if not parseFactor(rhs):
        return false
      if op == '*':
        v *= rhs
      else:
        if abs(rhs) < 0.000001:
          return false
        v /= rhs

  proc parseExpr(v: var float): bool =
    if not parseTerm(v):
      return false
    while true:
      skipSpaces()
      if i >= text.len or text[i] notin {'+', '-'}:
        return true
      let op = text[i]
      inc i
      var rhs = 0.0
      if not parseTerm(rhs):
        return false
      if op == '+':
        v += rhs
      else:
        v -= rhs

  if not parseExpr(value):
    return false
  skipSpaces()
  i == text.len

func renderPrimitiveNumber(value: float): string =
  if abs(value - round(value)) < 0.000001:
    $int(round(value))
  else:
    var rendered = formatFloat(value, ffDecimal, 4)
    while rendered.endsWith("0"):
      rendered = rendered[0 ..< rendered.len - 1]
    if rendered.endsWith("."):
      rendered = rendered[0 ..< rendered.len - 1]
    rendered

proc normalizePrimitiveInputValue*(property, raw: string): string =
  ## Normalize direct primitive input before it becomes a source plan.
  let text = raw.strip()
  if text.len == 0:
    return ""
  if text.startsWith("token(") or text.startsWith("var(") or
      text.startsWith("rgb") or text.startsWith("hsl") or text.contains("gradient("):
    return text
  let unit = primitiveUnitFromText(text)
  let expr =
    if unit.len > 0: text[0 ..< text.len - unit.len].strip()
    else: text
  if not expr.anyIt(it in {'+', '-', '*', '/'}):
    return text
  var computed = 0.0
  if evalNumericExpression(expr, computed):
    return renderPrimitiveNumber(computed) & unit
  text

proc cyclePrimitiveUnit*(property, raw: string): string =
  let text = normalizePrimitiveInputValue(property, raw)
  let parsed = parseCssPropertyValue(property, text)
  if parsed.kind notin {cvkLength, cvkPercentage}:
    return text
  let units = @["px", "rem", "em", "%", "vw", "vh"]
  var index = units.find(if parsed.unit.len > 0: parsed.unit else: "px")
  if index < 0:
    index = 0
  let nextUnit = units[(index + 1) mod units.len]
  renderPrimitiveNumber(parsed.numeric) & nextUnit

func primitiveFamilyFor(property: string; normalized: CSSPropertyValue): PrimitiveControlFamily =
  let prop = property.normalizedCssName()
  if normalized.kind == cvkGradient or prop in ["background-image", "background"]:
    pcfGradient
  elif normalized.kind == cvkColor or prop in ["color", "background-color",
      "border-color", "outline-color", "fill", "stroke"]:
    pcfColor
  elif prop.contains("shadow"):
    pcfShadow
  elif prop.startsWith("font") or prop in ["line-height", "letter-spacing",
      "text" & "-align", "text" & "-decoration", "text" & "-transform",
      "white-space", "text" & "-overflow"]:
    pcfTypography
  elif prop.startsWith("border") or prop.startsWith("outline"):
    pcfBorderRadiusStroke
  elif prop.startsWith("transition") or prop.startsWith("animation"):
    pcfMotion
  else:
    pcfNumeric

func primitiveCapabilities(family: PrimitiveControlFamily): seq[
    PrimitiveControlCapability] =
  result = @[pccReset, pccTokenBinding, pccUndoJournal, pccLivePreview,
    pccSourceCommit]
  case family
  of pcfNumeric:
    result.add @[pccSelectAllFocus, pccLabelScrub, pccPrecisionModifiers,
      pccArrowIncrement, pccUnitCycle, pccMathExpression, pccMinMaxValidation]
  of pcfColor:
    result.add @[pccSwatches, pccVariableMode, pccColorFormats, pccOpacity,
      pccEyedropper, pccCopyPaste, pccContrastPreview]
  of pcfGradient:
    result.add @[pccGradientStops, pccGradientAngle, pccGradientType,
      pccColorFormats]
  of pcfShadow:
    result.add @[pccShadowLayers, pccShadowCrosshair, pccLabelScrub,
      pccInsetShadow, pccElevationToken]
  of pcfTypography:
    result.add @[pccTypographyStyle, pccResponsiveText, pccTruncateWrap,
      pccArrowIncrement, pccUnitCycle]
  of pcfBorderRadiusStroke:
    result.add @[pccLinkedCorners, pccSideSpecificStroke, pccCanvasHandle,
      pccArrowIncrement, pccUnitCycle]
  of pcfMotion:
    result.add @[pccBezierCurve, pccMotionPreset, pccReducedMotionDiagnostic,
      pccArrowIncrement, pccUnitCycle, pccMinMaxValidation]

proc primitiveControlModel*(prop: PropertyInfo; raw = ""): PrimitiveControlModel =
  let proposed =
    if raw.len > 0: normalizePrimitiveInputValue(prop.name, raw)
    else: normalizePrimitiveInputValue(prop.name, prop.value)
  let normalized = parseCssPropertyValue(prop.name, proposed)
  let request = PropertyEditRequest(property: prop.name, newValue: proposed,
    kind: if cssPropertyCategory(prop.name) in {cpcLayout, cpcFlexGrid}: pekLayout else: pekCss,
    scope: if prop.sharedCount > 0: pesShared else: pesLocal,
    origin: peoInspector)
  let diagnostics = prop.validateCssPropertyValue(request, normalized)
  let family = primitiveFamilyFor(prop.name, normalized)
  result = PrimitiveControlModel(
    family: family,
    property: prop.name,
    raw: if raw.len > 0: raw else: prop.value,
    canonical: normalized.canonical,
    unit: normalized.unit,
    numeric: normalized.numeric,
    tokenName: if normalized.tokenName.len > 0: normalized.tokenName else: prop.tokenName,
    sourcePlanKind: prop.cssSourcePlanKind(request, normalized),
    sourceSerialized: normalized.canonical,
    livePreviewValue: normalized.canonical,
    minValue: -1000000000.0,
    maxValue: 1000000000.0,
    valid: diagnostics.len == 0,
    capabilities: primitiveCapabilities(family),
    diagnostics: diagnostics)
  let propName = prop.name.normalizedCssName()
  if propName == "opacity":
    result.minValue = 0
    result.maxValue = 1
  elif propName.startsWith("padding") or propName in ["transition-duration",
      "transition-delay", "animation-duration", "animation-delay"]:
    result.minValue = 0
  if family == pcfMotion and proposed.contains("prefers-reduced-motion: none"):
    result.reducedMotionDiagnostic =
      "Reduced-motion diagnostics expect a fallback for motion-sensitive users."

func withStatus(status: PropertyEditStatus;
    diagnostics: seq[PropertyEditDiagnostic] = @[]): PropertyEditResult =
  PropertyEditResult(status: status, diagnostics: diagnostics)

func emptyPreview(story: StoryRef): ProjectPreview =
  let status =
    if story.isEmptyStory: ppsMissingSelection else: ppsUnsupportedStory
  ProjectPreview(status: status, story: story)

proc defaultPreviewHook*(story: StoryRef;
                        platform: Platform): ProjectPreview =
  emptyPreview(story)

proc findCanvasItem(vm: EditorVM; story: StoryRef): int =
  result = -1
  let items = vm.storyboard.canvasItems.val
  for i, item in items:
    if sameStory(item.storyRef, story):
      return i

proc hasStory(vm: EditorVM; story: StoryRef): bool =
  if isEmptyStory(story):
    return false

  for group in vm.sidebar.groups.val:
    for item in group.items:
      if item.group == story.group and item.name == story.name and
          item.kind == story.kind:
        return true

proc syncFlowStep(vm: EditorVM; story: StoryRef) =
  let steps = vm.flowPlayer.steps.val
  for i, step in steps:
    if sameStory(step.screenRef, story):
      vm.flowPlayer.currentStep.val = i
      return

proc selectFlowStep*(editor: EditorVM; index: int): bool {.discardable.} =
  ## Select a flow step and synchronize the story, canvas item, and action.
  let steps = editor.flowPlayer.steps.val
  if index < 0 or index >= steps.len:
    return false

  let story = steps[index].screenRef
  if not editor.hasStory(story):
    return false

  editor.flowPlayer.currentStep.val = index
  editor.selectedStory.val = story
  editor.activeView.val = evStoryboard
  editor.storyboard.selectedItem.val = editor.findCanvasItem(story)
  true

# ===========================================================================
# EditorVM headless actions
# ===========================================================================

proc selectStory*(editor: EditorVM; story: StoryRef): bool {.discardable.} =
  ## Select a story and move the shell to the view that owns that story kind.
  if not editor.hasStory(story):
    return false

  editor.selectedStory.val = story
  editor.activeView.val = viewForStory(story)
  discard editor.ensureComponentPropertySchemaForSelectedStory()
  editor.storyboard.selectedItem.val = editor.findCanvasItem(story)
  editor.syncFlowStep(story)
  editor.recordEditorTiming(epbkStorySelection, 1,
    "story-selection:" & story.group & "/" & story.name)
  true

proc selectCanvasItem*(editor: EditorVM; index: int): bool {.discardable.} =
  ## Select a storyboard canvas item by index. Invalid indices are no-ops.
  let items = editor.storyboard.canvasItems.val
  if index < 0 or index >= items.len:
    return false

  if not editor.hasStory(items[index].storyRef):
    return false

  editor.storyboard.selectedItem.val = index
  discard editor.selectStory(items[index].storyRef)
  editor.storyboard.selectedItem.val = index
  if items[index].storyRef.kind == skFlow:
    editor.activeView.val = evStoryboard
  true

proc nextFlowStep*(editor: EditorVM): bool {.discardable.} =
  ## Advance the flow through the editor so selection stays synchronized.
  let total = editor.flowPlayer.totalSteps.val
  if total == 0:
    return false
  let nextIndex =
    if editor.flowPlayer.currentStep.val + 1 >= total: 0
    else: editor.flowPlayer.currentStep.val + 1
  editor.selectFlowStep(nextIndex)

proc prevFlowStep*(editor: EditorVM): bool {.discardable.} =
  ## Move backward in the flow through the editor selection contract.
  let total = editor.flowPlayer.totalSteps.val
  if total == 0:
    return false
  let prevIndex =
    if editor.flowPlayer.currentStep.val <= 0: total - 1
    else: editor.flowPlayer.currentStep.val - 1
  editor.selectFlowStep(prevIndex)

proc stopFlow*(editor: EditorVM): bool {.discardable.} =
  editor.flowPlayer.playState.val = psStopped
  editor.selectFlowStep(0)

proc setActiveView*(editor: EditorVM; view: EditorView) =
  editor.activeView.val = view

proc togglePanel*(editor: EditorVM; panel: EditorPanel) =
  let current = editor.panels.val
  case panel
  of epSidebar:
    editor.panels.val = PanelVisibility(sidebar: not current.sidebar,
                                        inspector: current.inspector)
  of epInspector:
    editor.panels.val = PanelVisibility(sidebar: current.sidebar,
                                        inspector: not current.inspector)

func clampRightPanelWidth*(width: int): int =
  max(260, min(520, width))

proc setRightPanelWidth*(editor: EditorVM; width: int) =
  editor.rightPanelWidth.val = clampRightPanelWidth(width)

proc adjustRightPanelWidth*(editor: EditorVM; delta: int) =
  editor.setRightPanelWidth(editor.rightPanelWidth.val + delta)

proc switchInspectorSection*(editor: EditorVM; section: InspectorSection) =
  editor.inspector.activeSection.val = section
  editor.inspector.setSectionExpanded(section, true)

func fallbackElementId(element: ElementRef): string =
  if element.id.len > 0:
    return element.id
  if element.sourceKey.len > 0:
    return element.sourceKey
  if element.schemaKey.len > 0:
    return element.schemaKey
  if element.domPath.len > 0:
    return element.sourceFile & ":" & $element.sourceLine & ":" & element.domPath
  if element.sourceFile.len > 0 and element.sourceLine > 0:
    return element.sourceFile & ":" & $element.sourceLine & ":" & element.tag
  element.tag

func rowFromElement(element: ElementRef): ElementLayerRow =
  let id = element.fallbackElementId()
  ElementLayerRow(
    id: id,
    label: if element.tag.len > 0: element.tag else: "element",
    tag: if element.tag.len > 0: element.tag else: "element",
    sourceKey: if element.sourceKey.len > 0: element.sourceKey else: id,
    schemaKey: element.schemaKey,
    domPath: element.domPath,
    sourceFile: element.sourceFile,
    sourceLine: element.sourceLine,
    depth: max(0, element.depth),
    childCount: element.children.len,
    expanded: true,
    selected: true)

func rowToElement(row: ElementLayerRow; previous: ElementRef): ElementRef =
  var props: seq[PropertyInfo] = @[]
  if previous.fallbackElementId() == row.id:
    props = previous.properties
  ElementRef(
    id: row.id,
    sourceKey: if row.sourceKey.len > 0: row.sourceKey else: row.id,
    domPath: row.domPath,
    schemaKey: row.schemaKey,
    tag: if row.tag.len > 0: row.tag else: row.label,
    sourceFile: row.sourceFile,
    sourceLine: row.sourceLine,
    sourceColumn: 1,
    properties: props,
    ancestors: @[row.label],
    ancestorIds: @[row.id],
    depth: row.depth)

proc parseLayerTreeRows(raw: string; selectedId, hoveredId: string;
    expandedIds: seq[string]): seq[ElementLayerRow] =
  if raw.strip.len == 0:
    return @[]
  let parsed =
    try:
      parseJson(raw)
    except JsonParsingError:
      return @[]
  if parsed.kind != JArray:
    return @[]
  for item in parsed.elems:
    if item.kind != JObject:
      continue
    let id = item{"id"}.getStr()
    if id.len == 0:
      continue
    let childCount = item{"childCount"}.getInt(0)
    result.add ElementLayerRow(
      id: id,
      parentId: item{"parentId"}.getStr(),
      label: item{"label"}.getStr(item{"tag"}.getStr("element")),
      tag: item{"tag"}.getStr("element"),
      sourceKey: item{"sourceKey"}.getStr(id),
      schemaKey: item{"schemaKey"}.getStr(),
      domPath: item{"domPath"}.getStr(),
      sourceFile: item{"sourceFile"}.getStr(),
      sourceLine: item{"sourceLine"}.getInt(0),
      depth: item{"depth"}.getInt(0),
      childCount: childCount,
      expanded: childCount > 0 and (id in expandedIds or item{"expanded"}.getBool(true)),
      selected: id == selectedId,
      hovered: id == hoveredId,
      hidden: item{"hidden"}.getBool(false),
      locked: item{"locked"}.getBool(false))

func withLayerSelection(rows: seq[ElementLayerRow]; selectedId,
    hoveredId: string; expandedIds: seq[string]): seq[ElementLayerRow] =
  for row in rows:
    var copy = row
    copy.selected = copy.id == selectedId
    copy.hovered = copy.id == hoveredId
    if copy.childCount > 0:
      copy.expanded = copy.id in expandedIds or row.expanded
    result.add copy

proc setSelectionTree*(inspector: InspectorVM; rows: seq[ElementLayerRow]) =
  let selectedId = inspector.selectedElement.val.fallbackElementId()
  inspector.layers.val = rows.withLayerSelection(selectedId,
    inspector.hoveredElementId.val, inspector.expandedLayerIds.val)

proc refreshLayerFlags(inspector: InspectorVM) =
  inspector.layers.val = inspector.layers.val.withLayerSelection(
    inspector.selectedElement.val.fallbackElementId(),
    inspector.hoveredElementId.val,
    inspector.expandedLayerIds.val)

proc selectInspectorElement*(editor: EditorVM;
    element: ElementRef): bool {.discardable.} =
  if element.tag.len == 0:
    editor.inspector.selectedElement.val = ElementRef()
    editor.inspector.editDiagnostics.val = @[]
    editor.inspector.refreshLayerFlags()
    return false

  var next = element
  if next.id.len == 0:
    next.id = next.fallbackElementId()
  if next.sourceKey.len == 0:
    next.sourceKey = next.id
  if next.schemaKey.len == 0:
    next.schemaKey =
      if next.properties.len > 0: next.properties[0].schemaKey
      else: next.sourceKey
  if next.ancestorIds.len == 0:
    next.ancestorIds = @[next.id]
  editor.inspector.selectedElement.val = next
  editor.inspector.editDiagnostics.val = @[]
  if editor.inspector.layers.val.len == 0:
    editor.inspector.layers.val = @[next.rowFromElement()]
  else:
    editor.inspector.refreshLayerFlags()
  editor.recordEditorTiming(epbkElementSelection, 1,
    "element-selection:" & next.id)
  true

func previewDomElementRef*(metadata: StoryRenderMetadata; tag, testId,
    className, role, elementPath, ancestry, sourceFile: string;
    sourceLine: int; display, position, backgroundColor, color, padding,
    margin, width, height, borderRadius, borderWidth, borderStyle, borderColor,
    fontSize, fontWeight, lineHeight, boxShadow, opacity, rectWidth,
    rectHeight, textContent, elementId, sourceKey, schemaKey, ancestorIds,
    layerTreeJson: string): ElementRef =
  ## Build the generic inspector selection produced by the browser iframe DOM
  ## bridge. Projects own the preview HTML/source metadata; the editor owns the
  ## normalized ElementRef and editable property model.
  let file =
    if sourceFile.len > 0: sourceFile
    else: metadata.sourceFile
  let line =
    if sourceLine > 0: sourceLine
    elif metadata.sourceLine > 0: metadata.sourceLine
    else: 1
  let schemaPrefix =
    if schemaKey.len > 0: schemaKey
    elif testId.len > 0: "dom." & testId
    elif className.len > 0: "dom." & className.splitWhitespace().join(".")
    else: "dom." & tag
  let identity =
    if elementId.len > 0: elementId
    elif sourceKey.len > 0: sourceKey
    elif testId.len > 0: file & ":" & $line & ":testid:" & testId
    elif elementPath.len > 0: file & ":" & $line & ":" & elementPath
    else: file & ":" & $line & ":" & tag

  func domProp(name, value: string): PropertyInfo =
    PropertyInfo(
      name: name,
      value: value,
      origin: poInherited,
      originDetail: "iframe-dom:" & schemaPrefix & ":" & name,
      sourceFile: file,
      sourceLine: line,
      schemaKey: schemaPrefix & "." & name,
      directStyleAllowed: true)

  var props: seq[PropertyInfo] = @[]
  if display.len > 0:
    props.add domProp("display", display)
  if position.len > 0:
    props.add domProp("position", position)
  if backgroundColor.len > 0 and backgroundColor != "rgba(0, 0, 0, 0)" and
      backgroundColor != "transparent":
    props.add domProp("background-color", backgroundColor)
  if color.len > 0:
    props.add domProp("color", color)
  if padding.len > 0:
    props.add domProp("padding", padding)
  if margin.len > 0:
    props.add domProp("margin", margin)
  if width.len > 0:
    props.add domProp("width", width)
  if height.len > 0:
    props.add domProp("height", height)
  if borderRadius.len > 0:
    props.add domProp("border-radius", borderRadius)
  if borderWidth.len > 0:
    props.add domProp("border-width", borderWidth)
  if borderStyle.len > 0:
    props.add domProp("border-style", borderStyle)
  if borderColor.len > 0:
    props.add domProp("border-color", borderColor)
  if fontSize.len > 0:
    props.add domProp("font-size", fontSize)
  if fontWeight.len > 0:
    props.add domProp("font-weight", fontWeight)
  if lineHeight.len > 0:
    props.add domProp("line-height", lineHeight)
  if boxShadow.len > 0 and boxShadow != "none":
    props.add domProp("box-shadow", boxShadow)
  if opacity.len > 0:
    props.add domProp("opacity", opacity)
  if textContent.len > 0:
    props.add PropertyInfo(
      name: "text",
      value: textContent,
      origin: poConstant,
      originDetail: "iframe-dom:" & schemaPrefix & ":text",
      sourceFile: file,
      sourceLine: line,
      schemaKey: schemaPrefix & ".text",
      directStyleAllowed: true)

  let children = @[
    if testId.len > 0: "data-testid=" & testId else: "",
    if className.len > 0: "class=" & className else: "",
    if role.len > 0: "role=" & role else: "",
    if elementPath.len > 0: "path=" & elementPath else: "",
    if ancestry.len > 0: "ancestry=" & ancestry else: "",
    if rectWidth.len > 0 and rectHeight.len > 0:
      "box=" & rectWidth & "x" & rectHeight
    else:
      ""
  ].filterIt(it.len > 0)
  let ancestors =
    if ancestry.len > 0: ancestry.split(" > ")
    else: @[if tag.len > 0: tag else: "element"]
  let parsedAncestorIds =
    if ancestorIds.len > 0: ancestorIds.split(" > ").filterIt(it.len > 0)
    else: @[identity]

  ElementRef(
    id: identity,
    sourceKey: if sourceKey.len > 0: sourceKey else: identity,
    domPath: elementPath,
    schemaKey: schemaPrefix,
    tag: (if tag.len > 0: tag else: "element"),
    sourceFile: file,
    sourceLine: line,
    sourceColumn: 1,
    depth: max(0, ancestors.len - 1),
    properties: props,
    children: children,
    ancestors: ancestors,
    ancestorIds: parsedAncestorIds)

func previewDomElementRef*(metadata: StoryRenderMetadata; tag, testId,
    className, sourceFile: string; sourceLine: int; backgroundColor, color,
    padding, width, height: string): ElementRef =
  previewDomElementRef(metadata, tag, testId, className, "", "", "",
    sourceFile, sourceLine, "", "", backgroundColor, color, padding, "",
    width, height, "", "", "", "", "", "", "", "", "", "", "", "", "", "",
    "", "", "")

proc previewDomLayerRows*(raw: string; selectedId = ""; hoveredId = "";
    expandedIds: seq[string] = @[]): seq[ElementLayerRow] =
  parseLayerTreeRows(raw, selectedId, hoveredId, expandedIds)

proc selectInspectorElementById*(editor: EditorVM; id: string): bool {.discardable.} =
  for row in editor.inspector.layers.val:
    if row.id == id:
      editor.inspector.selectedElement.val = row.rowToElement(
        editor.inspector.selectedElement.val)
      editor.inspector.editDiagnostics.val = @[]
      editor.inspector.refreshLayerFlags()
      return true
  false

proc selectParentInspectorElement*(editor: EditorVM): bool {.discardable.} =
  let id = editor.inspector.selectedElement.val.fallbackElementId()
  for row in editor.inspector.layers.val:
    if row.id == id and row.parentId.len > 0:
      return editor.selectInspectorElementById(row.parentId)
  false

proc selectChildInspectorElement*(editor: EditorVM): bool {.discardable.} =
  let id = editor.inspector.selectedElement.val.fallbackElementId()
  for row in editor.inspector.layers.val:
    if row.parentId == id:
      return editor.selectInspectorElementById(row.id)
  false

proc selectNextInspectorElement*(editor: EditorVM): bool {.discardable.} =
  let rows = editor.inspector.filteredLayers.val
  if rows.len == 0:
    return false
  var index = -1
  let id = editor.inspector.selectedElement.val.fallbackElementId()
  for i, row in rows:
    if row.id == id:
      index = i
      break
  if index < 0:
    return editor.selectInspectorElementById(rows[0].id)
  editor.selectInspectorElementById(rows[min(rows.high, index + 1)].id)

proc selectPreviousInspectorElement*(editor: EditorVM): bool {.discardable.} =
  let rows = editor.inspector.filteredLayers.val
  if rows.len == 0:
    return false
  var index = -1
  let id = editor.inspector.selectedElement.val.fallbackElementId()
  for i, row in rows:
    if row.id == id:
      index = i
      break
  if index < 0:
    return editor.selectInspectorElementById(rows[rows.high].id)
  editor.selectInspectorElementById(rows[max(0, index - 1)].id)

proc clearInspectorSelection*(editor: EditorVM) =
  editor.inspector.selectedElement.val = ElementRef()
  editor.inspector.editDiagnostics.val = @[]
  editor.inspector.refreshLayerFlags()

proc changePlatform*(editor: EditorVM; platform: Platform) =
  editor.platform.val = platform
  editor.viewport.val = viewportForPlatform(platform)

proc changeViewport*(editor: EditorVM; viewport: PreviewViewport) =
  editor.viewport.val = viewport
  editor.platform.val = platformForViewport(viewport)

func importVectorDocumentSvg*(symbol: VectorSymbol; svg: string): VectorDocument
func diagnoseUnsupportedVectorSvgFeatures*(svg: string;
    schemaKey = ""): seq[VectorDiagnostic]
func diagnoseUnsupportedVectorPathEditing*(doc: VectorDocument): seq[VectorDiagnostic]

proc selectVectorSymbol*(editor: EditorVM; index: int): bool {.discardable.} =
  let symbols = editor.vectorEditor.symbols.val
  if index < 0 or index >= symbols.len:
    return false

  editor.vectorEditor.selectedSymbol.val = index
  let doc = importVectorDocumentSvg(symbols[index], symbols[index].svgContent)
  editor.vectorEditor.document.val = doc
  editor.vectorEditor.diagnostics.val =
    doc.validateVectorAccessibility() &
    symbols[index].svgContent.diagnoseUnsupportedVectorSvgFeatures(
      doc.source.schemaKey) &
    doc.diagnoseUnsupportedVectorPathEditing()
  editor.vectorEditor.undoStack.val = @[]
  editor.vectorEditor.redoStack.val = @[]
  true

proc setAgentState*(editor: EditorVM; state: AsyncState) =
  editor.chat.sessionStatus.val = state

func hasSource(element: ElementRef): bool =
  element.sourceFile.len > 0 and element.sourceLine > 0

func hasSource(prop: PropertyInfo): bool =
  prop.sourceFile.len > 0 and prop.sourceLine > 0

proc selectedSourceContext(editor: EditorVM): tuple[file: string, line: int] =
  let element = editor.inspector.selectedElement.val
  if element.hasSource:
    return (element.sourceFile, element.sourceLine)
  for prop in element.properties:
    if prop.hasSource:
      return (prop.sourceFile, prop.sourceLine)
  let preview = editor.preview.current.val
  if preview.metadata.sourceFile.len > 0 and preview.metadata.sourceLine > 0:
    return (preview.metadata.sourceFile, preview.metadata.sourceLine)
  ("", 0)

func sourceChangingCommand(kind: EditorCommandKind): bool =
  kind in {eckApply, eckSave, eckDuplicate, eckDelete, eckCreateVariant,
    eckCreateStory}

func selectionCommand(kind: EditorCommandKind): bool =
  kind in {eckSelectPrevious, eckSelectNext, eckSelectParent, eckSelectChild,
    eckNavigateLayersUp, eckNavigateLayersDown}

func numericProperty(value: string): tuple[ok: bool, number: int, suffix: string] =
  var digits = ""
  var suffixStart = 0
  for i, ch in value:
    if (ch >= '0' and ch <= '9') or (i == 0 and ch == '-'):
      digits.add ch
      suffixStart = i + 1
    else:
      break
  if digits.len == 0 or digits == "-":
    return (false, 0, "")
  try:
    (true, parseInt(digits),
      if suffixStart < value.len: value[suffixStart .. ^1] else: "")
  except ValueError:
    (false, 0, "")

proc undoCssPropertyEdit*(inspector: InspectorVM): bool {.discardable.}
proc redoCssPropertyEdit*(inspector: InspectorVM): bool {.discardable.}
proc undoVectorEdit*(editor: EditorVM): bool {.discardable.}
proc redoVectorEdit*(editor: EditorVM): bool {.discardable.}
proc undoFoundationTokenEdit*(editor: EditorVM): bool {.discardable.}
proc redoFoundationTokenEdit*(editor: EditorVM): bool {.discardable.}
proc evaluateCommand*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState

proc nudgeFirstNumericProperty(editor: EditorVM; delta: int): bool =
  var element = editor.inspector.selectedElement.val
  for i, prop in element.properties:
    let parsed = numericProperty(prop.value)
    if parsed.ok:
      element.properties[i].value = $(parsed.number + delta) & parsed.suffix
      editor.inspector.selectedElement.val = element
      return true
  false

proc toggleCommandPalette*(editor: EditorVM) =
  editor.commandPaletteOpen.val = not editor.commandPaletteOpen.val

proc closeCommandPalette*(editor: EditorVM) =
  editor.commandPaletteOpen.val = false

proc openCommandPalette*(editor: EditorVM) =
  editor.commandPaletteOpen.val = true

proc setTelemetryOverlayVisible*(editor: EditorVM; visible: bool) =
  editor.telemetryOverlayVisible.val = visible

func budgetFor(budgets: seq[EditorPerformanceBudget];
    kind: EditorPerformanceBudgetKind): EditorPerformanceBudget =
  for budget in budgets:
    if budget.kind == kind:
      return budget
  EditorPerformanceBudget(kind: kind, label: performanceBudgetLabel(kind),
    maxMs: 0)

proc recordEditorTiming*(editor: EditorVM; kind: EditorPerformanceBudgetKind;
    durationMs: int; detail: string) =
  let budget = editor.performanceBudgets.val.budgetFor(kind)
  let event = EditorTelemetryEvent(
    name: budget.label,
    durationMs: durationMs,
    budgetKind: kind,
    withinBudget: budget.maxMs == 0 or durationMs <= budget.maxMs,
    detail: detail)
  editor.telemetryEvents.update proc(prev: seq[EditorTelemetryEvent]): seq[
      EditorTelemetryEvent] =
    result = prev
    result.add event
    if result.len > 12:
      result = result[result.len - 12 .. ^1]

func performanceBudgetsPass*(events: seq[EditorTelemetryEvent]): bool =
  events.allIt(it.withinBudget)

proc commandPaletteEntries*(editor: EditorVM): seq[EditorCommandPaletteEntry] =
  for kind in allEditorCommandKinds():
    let state = editor.evaluateCommand(kind)
    result.add EditorCommandPaletteEntry(
      kind: kind,
      label: state.label,
      shortcut: commandShortcut(kind),
      section: commandScope(kind),
      status: state.status,
      diagnostic: state.diagnostic)

proc commandRequirementFailure(editor: EditorVM;
    kind: EditorCommandKind): string =
  let story = editor.selectedStory.val
  let element = editor.inspector.selectedElement.val
  let permissions = editor.workspacePermissions.val
  let source = editor.selectedSourceContext()

  if kind in {eckOpenCommandPalette, eckToggleSidebar, eckToggleInspector,
      eckFocusInspector}:
    return ""

  if kind.selectionCommand:
    if editor.inspector.filteredLayers.val.len == 0:
      return "No layer tree is available for keyboard selection."
    return ""

  if kind in {eckIncrementProperty, eckDecrementProperty}:
    if element.tag.len == 0:
      return "Select an element before nudging a property."
    if not element.properties.anyIt(numericProperty(it.value).ok):
      return "The selected element has no numeric property to nudge."
    return ""

  if kind == eckUndo:
    if editor.inspector.undoStack.val.len == 0 and
        editor.vectorEditor.undoStack.val.len == 0 and
        editor.foundations.undoStack.val.len == 0:
      return "There is no edit to undo."
    return ""

  if kind == eckRedo:
    if editor.inspector.redoStack.val.len == 0 and
        editor.vectorEditor.redoStack.val.len == 0 and
        editor.foundations.redoStack.val.len == 0:
      return "There is no edit to redo."
    return ""

  if kind in {eckApply, eckSave} and
      editor.inspector.pendingSourceEdits.val.len > 0:
    if not permissions.writeSource:
      return "This workspace is read-only for source changes."
    if not editor.sourceAdapterReady.val:
      return "No source edit adapter is ready."
    return ""

  if kind in {eckRevert, eckDiscard} and
      (editor.inspector.pendingSourceEdits.val.len > 0 or
        editor.chat.accumulatedEdits.val.len > 0 or
        editor.foundations.undoStack.val.len > 0):
    return ""

  if story.isEmptyStory:
    return "Select a story before using " & commandLabel(kind) & "."

  if kind.sourceChangingCommand:
    if element.tag.len == 0:
      return "Select an element before using " & commandLabel(kind) & "."
    if source.file.len == 0:
      return "No source metadata is available for the selected element."
    if not permissions.writeSource:
      return "This workspace is read-only for source changes."
    if not editor.sourceAdapterReady.val:
      return "No source edit adapter is ready."

  case kind
  of eckEdit:
    ""
  of eckComment:
    ""
  of eckInspect:
    ""
  of eckOpenSource:
    if not permissions.readSource:
      "This workspace does not allow source reads."
    elif source.file.len == 0:
      "No source metadata is available for the current selection."
    else:
      ""
  of eckApply, eckSave:
    if editor.inspector.pendingSourceEdits.val.len == 0:
      "There are no pending source edits."
    else:
      ""
  of eckRevert, eckDiscard:
    if editor.inspector.pendingSourceEdits.val.len == 0 and
        editor.chat.accumulatedEdits.val.len == 0 and
        editor.foundations.undoStack.val.len == 0:
      "There are no edits to discard."
    else:
      ""
  of eckDuplicate:
    if not permissions.duplicate:
      "This workspace does not allow duplicate operations."
    else:
      ""
  of eckDelete:
    if not permissions.delete:
      "This workspace does not allow delete operations."
    else:
      ""
  of eckCreateVariant:
    if not permissions.createVariant:
      "This workspace does not allow variant creation."
    else:
      ""
  of eckCreateStory:
    if not permissions.createStory:
      "This workspace does not allow story creation."
    else:
      ""
  of eckSelectPrevious, eckSelectNext, eckSelectParent, eckSelectChild,
      eckFocusInspector, eckIncrementProperty, eckDecrementProperty, eckUndo,
      eckRedo, eckToggleSidebar, eckToggleInspector, eckOpenCommandPalette,
      eckNavigateLayersUp, eckNavigateLayersDown:
    ""

proc evaluateCommand*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState =
  let failure = editor.commandRequirementFailure(kind)
  let source = editor.selectedSourceContext()
  EditorCommandState(
    kind: kind,
    label: commandLabel(kind),
    status: if failure.len == 0: ecsAvailable else: ecsDisabled,
    diagnostic: failure,
    sourceFile: source.file,
    sourceLine: source.line)

proc commandState*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState =
  for state in editor.commandStates.val:
    if state.kind == kind:
      return state
  editor.evaluateCommand(kind)

proc commandAvailable*(editor: EditorVM; kind: EditorCommandKind): bool =
  editor.evaluateCommand(kind).status == ecsAvailable

proc setCommandState(editor: EditorVM; state: EditorCommandState) =
  editor.commandStates.update proc(prev: seq[EditorCommandState]): seq[
      EditorCommandState] =
    result = prev
    for i in 0 ..< result.len:
      if result[i].kind == state.kind:
        result[i] = state
        return
    result.add state

proc refreshCommandStates*(editor: EditorVM) =
  var states: seq[EditorCommandState] = @[]
  for kind in allEditorCommandKinds():
    states.add editor.evaluateCommand(kind)
  editor.commandStates.val = states

proc failCommand(editor: EditorVM; kind: EditorCommandKind;
    diagnostic: string): EditorCommandState =
  let source = editor.selectedSourceContext()
  result = EditorCommandState(
    kind: kind,
    label: commandLabel(kind),
    status: ecsFailed,
    diagnostic: diagnostic,
    sourceFile: source.file,
    sourceLine: source.line)
  editor.setCommandState(result)

proc applyWorkspaceFileEdits*(editor: EditorVM): WorkspaceEditResult {.discardable.}
proc sendAgentPrompt*(editor: EditorVM): bool {.discardable.}

proc setEditMode*(editor: EditorVM; mode: EditMode) =
  editor.editMode.val = mode
  if mode in {emComment, emEdit} and editor.activeView.val in {evComponentDetail,
      evPagePreview}:
    editor.activeView.val = evComponentEdit

proc setVectorTool*(editor: EditorVM; tool: VectorTool) =
  editor.vectorEditor.activeTool.val = tool

proc setVectorZoom*(editor: EditorVM; zoom: float) =
  editor.vectorEditor.zoom.val = max(0.1, min(8.0, zoom))

proc panVectorCanvas*(editor: EditorVM; dx, dy: float) =
  editor.vectorEditor.panX.val = editor.vectorEditor.panX.val + dx
  editor.vectorEditor.panY.val = editor.vectorEditor.panY.val + dy

proc runEditorCommand*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState {.discardable.} =
  ## Dispatch a framework-owned editor command with deterministic state.
  let available = editor.evaluateCommand(kind)
  if available.status == ecsDisabled:
    return editor.failCommand(kind, available.diagnostic)

  var running = available
  running.status = ecsRunning
  editor.setCommandState(running)

  case kind
  of eckEdit:
    editor.setEditMode(emEdit)
    editor.recordEditorTiming(epbkModeSwitch, 1, "command:edit")
  of eckComment:
    editor.setEditMode(emComment)
    editor.recordEditorTiming(epbkModeSwitch, 1, "command:comment")
  of eckInspect:
    editor.setEditMode(emView)
    editor.recordEditorTiming(epbkModeSwitch, 1, "command:view")
  of eckApply:
    discard
  of eckRevert, eckDiscard:
    let stack = editor.inspector.undoStack.val
    if stack.len > 0:
      editor.inspector.selectedElement.val = stack[0].beforeElement
    let foundationStack = editor.foundations.undoStack.val
    if foundationStack.len > 0:
      var updatedTokens = editor.foundations.tokens.val
      for historyIndex in countdown(foundationStack.len - 1, 0):
        let history = foundationStack[historyIndex]
        for i, token in updatedTokens:
          if token.key.toLowerAscii() == history.key.toLowerAscii():
            updatedTokens[i] = history.beforeToken
            break
      editor.foundations.tokens.val = updatedTokens
      editor.foundations.selectedTokenKey.val = foundationStack[0].key
    let vectorStack = editor.vectorEditor.undoStack.val
    if vectorStack.len > 0:
      editor.vectorEditor.document.val = vectorStack[0].beforeDocument
    editor.inspector.pendingSourceEdits.val = @[]
    editor.inspector.sourcePreviews.val = @[]
    editor.inspector.undoStack.val = @[]
    editor.inspector.redoStack.val = @[]
    editor.foundations.undoStack.val = @[]
    editor.foundations.redoStack.val = @[]
    editor.foundations.impacts.val = @[]
    editor.foundations.diagnostics.val = @[]
    editor.vectorEditor.undoStack.val = @[]
    editor.vectorEditor.redoStack.val = @[]
    editor.inspector.conflicts.val = @[]
    editor.inspector.editDiagnostics.val = @[]
    editor.chat.accumulatedEdits.val = @[]
    editor.workspaceEditStage.val = wesClean
    editor.workspaceEditDiagnostics.val = @[]
    editor.workspaceEditGeneratedArtifacts.val = @[]
    editor.workspaceEditRequiredTestCommands.val = @[]
    editor.workspaceEditReviewDiagnostics.val = @[]
  of eckSave:
    let saveResult = editor.applyWorkspaceFileEdits()
    if not saveResult.ok:
      return editor.failCommand(kind,
        if saveResult.diagnostics.len > 0: saveResult.diagnostics[0].message
        else: "Workspace edit transaction failed.")
  of eckDuplicate, eckDelete, eckCreateVariant, eckCreateStory:
    discard
  of eckOpenSource:
    discard
  of eckSelectPrevious, eckNavigateLayersUp:
    discard editor.selectPreviousInspectorElement()
  of eckSelectNext, eckNavigateLayersDown:
    discard editor.selectNextInspectorElement()
  of eckSelectParent:
    discard editor.selectParentInspectorElement()
  of eckSelectChild:
    discard editor.selectChildInspectorElement()
  of eckFocusInspector:
    let current = editor.panels.val
    editor.panels.val = PanelVisibility(sidebar: current.sidebar,
      inspector: true)
    editor.inspector.focusedControlId.val = "section-search"
  of eckIncrementProperty:
    discard editor.nudgeFirstNumericProperty(1)
  of eckDecrementProperty:
    discard editor.nudgeFirstNumericProperty(-1)
  of eckUndo:
    if not editor.inspector.undoCssPropertyEdit():
      if not editor.undoVectorEdit():
        discard editor.undoFoundationTokenEdit()
  of eckRedo:
    if not editor.inspector.redoCssPropertyEdit():
      if not editor.redoVectorEdit():
        discard editor.redoFoundationTokenEdit()
  of eckToggleSidebar:
    editor.togglePanel(epSidebar)
  of eckToggleInspector:
    editor.togglePanel(epInspector)
  of eckOpenCommandPalette:
    editor.openCommandPalette()

  result = editor.evaluateCommand(kind)
  result.status = ecsSucceeded
  result.diagnostic = ""
  editor.setCommandState(result)

# ===========================================================================
# SidebarVM actions
# ===========================================================================

proc selectStory*(sidebar: SidebarVM; editor: EditorVM;
    story: StoryRef): bool {.discardable.} =
  editor.selectStory(story)

func defaultSidebarSections*(): SidebarSectionExpansion =
  SidebarSectionExpansion(
    userJourneys: true,
    pages: true,
    components: true,
    foundations: true,
    guidelines: false)

func isExpanded*(state: SidebarSectionExpansion;
    section: SidebarSection): bool =
  case section
  of ssUserJourneys:
    state.userJourneys
  of ssPages:
    state.pages
  of ssComponents:
    state.components
  of ssFoundations:
    state.foundations
  of ssGuidelines:
    state.guidelines

func withToggled(state: SidebarSectionExpansion;
    section: SidebarSection): SidebarSectionExpansion =
  result = state
  case section
  of ssUserJourneys:
    result.userJourneys = not result.userJourneys
  of ssPages:
    result.pages = not result.pages
  of ssComponents:
    result.components = not result.components
  of ssFoundations:
    result.foundations = not result.foundations
  of ssGuidelines:
    result.guidelines = not result.guidelines

func withExpanded(state: SidebarSectionExpansion; section: SidebarSection;
    expanded: bool): SidebarSectionExpansion =
  result = state
  case section
  of ssUserJourneys:
    result.userJourneys = expanded
  of ssPages:
    result.pages = expanded
  of ssComponents:
    result.components = expanded
  of ssFoundations:
    result.foundations = expanded
  of ssGuidelines:
    result.guidelines = expanded

proc toggleSection*(sidebar: SidebarVM; section: SidebarSection) =
  sidebar.sections.update proc(prev: SidebarSectionExpansion): SidebarSectionExpansion =
    prev.withToggled(section)

proc setSectionExpanded*(sidebar: SidebarVM; section: SidebarSection;
    expanded: bool) =
  sidebar.sections.update proc(prev: SidebarSectionExpansion): SidebarSectionExpansion =
    prev.withExpanded(section, expanded)

proc toggleGroup*(sidebar: SidebarVM; groupName: string) =
  sidebar.groups.update proc(prev: seq[StoryGroup]): seq[StoryGroup] =
    result = prev
    for i in 0 ..< result.len:
      if result[i].name == groupName:
        result[i].expanded = not result[i].expanded

proc setSearch*(sidebar: SidebarVM; query: string) =
  sidebar.searchFilter.val = query

# ===========================================================================
# InspectorVM actions
# ===========================================================================

proc selectElement*(inspector: InspectorVM; element: ElementRef) =
  var next = element
  if next.id.len == 0:
    next.id = next.fallbackElementId()
  if next.sourceKey.len == 0:
    next.sourceKey = next.id
  if next.ancestorIds.len == 0:
    next.ancestorIds = @[next.id]
  inspector.selectedElement.val = next
  inspector.editDiagnostics.val = @[]
  inspector.refreshLayerFlags()

proc setSection*(inspector: InspectorVM; section: InspectorSection) =
  inspector.activeSection.val = section

proc setSectionSearch*(inspector: InspectorVM; query: string) =
  inspector.sectionSearch.val = query

proc setSectionExpanded*(inspector: InspectorVM; section: InspectorSection;
    expanded: bool) =
  var next = inspector.expandedSections.val
  if expanded:
    if section notin next:
      next.add section
  else:
    next = next.filterIt(it != section)
  inspector.expandedSections.val = next

proc toggleSectionExpanded*(inspector: InspectorVM; section: InspectorSection) =
  inspector.setSectionExpanded(section, section notin inspector.expandedSections.val)

proc collapseAllSections*(inspector: InspectorVM) =
  inspector.expandedSections.val = @[]

proc expandRelevantSections*(inspector: InspectorVM) =
  var next: seq[InspectorSection] = @[]
  for section in inspector.visibleSections.val:
    next.add section
  if next.len == 0:
    next.add inspector.activeSection.val
  inspector.expandedSections.val = next

proc rememberInspectorFocus*(inspector: InspectorVM; id: string) =
  inspector.focusedControlId.val = id

proc clearSelection*(inspector: InspectorVM) =
  inspector.selectedElement.val = ElementRef()
  inspector.editDiagnostics.val = @[]
  inspector.refreshLayerFlags()

func rowIndex(rows: seq[ElementLayerRow]; id: string): int =
  for i, row in rows:
    if row.id == id:
      return i
  -1

func parentRow(rows: seq[ElementLayerRow]; row: ElementLayerRow): ElementLayerRow =
  for candidate in rows:
    if candidate.id == row.parentId:
      return candidate
  ElementLayerRow()

func rowAncestry(rows: seq[ElementLayerRow]; row: ElementLayerRow): tuple[
    labels: seq[string], ids: seq[string]] =
  var stack = @[row]
  var current = row
  while current.parentId.len > 0:
    let parent = rows.parentRow(current)
    if parent.id.len == 0:
      break
    stack.add parent
    current = parent
  for i in countdown(stack.high, 0):
    result.labels.add stack[i].label
    result.ids.add stack[i].id

proc elementFromRow(inspector: InspectorVM; row: ElementLayerRow): ElementRef =
  let previous = inspector.selectedElement.val
  result = row.rowToElement(previous)
  let ancestry = inspector.layers.val.rowAncestry(row)
  result.ancestors = ancestry.labels
  result.ancestorIds = ancestry.ids
  result.depth = max(0, ancestry.ids.len - 1)

proc selectElementById*(inspector: InspectorVM; id: string): bool {.discardable.} =
  if id.len == 0:
    return false
  for row in inspector.layers.val:
    if row.id == id:
      inspector.selectedElement.val = inspector.elementFromRow(row)
      inspector.editDiagnostics.val = @[]
      inspector.refreshLayerFlags()
      return true
  false

proc setLayerSearch*(inspector: InspectorVM; query: string) =
  inspector.layerSearch.val = query

proc toggleLayerExpanded*(inspector: InspectorVM; id: string) =
  if id.len == 0:
    return
  var shouldExpand = true
  var rows = inspector.layers.val
  for i in 0 ..< rows.len:
    if rows[i].id == id:
      shouldExpand = not rows[i].expanded
      rows[i].expanded = shouldExpand
      break
  var next = inspector.expandedLayerIds.val
  if not shouldExpand:
    next = next.filterIt(it != id)
  elif id notin next:
    next.add id
  inspector.expandedLayerIds.val = next
  inspector.layers.val = rows.withLayerSelection(
    inspector.selectedElement.val.fallbackElementId(),
    inspector.hoveredElementId.val, inspector.expandedLayerIds.val)

proc setLayerHover*(inspector: InspectorVM; id: string) =
  inspector.hoveredElementId.val = id
  inspector.refreshLayerFlags()

proc selectParentElement*(inspector: InspectorVM): bool {.discardable.} =
  let id = inspector.selectedElement.val.fallbackElementId()
  let index = inspector.layers.val.rowIndex(id)
  if index < 0:
    return false
  let parent = inspector.layers.val.parentRow(inspector.layers.val[index])
  if parent.id.len == 0:
    return false
  inspector.selectElementById(parent.id)

proc selectFirstChildElement*(inspector: InspectorVM): bool {.discardable.} =
  let id = inspector.selectedElement.val.fallbackElementId()
  for row in inspector.layers.val:
    if row.parentId == id:
      return inspector.selectElementById(row.id)
  false

proc selectNextElement*(inspector: InspectorVM): bool {.discardable.} =
  let rows = inspector.filteredLayers.val
  if rows.len == 0:
    return false
  let id = inspector.selectedElement.val.fallbackElementId()
  let index = rows.rowIndex(id)
  if index < 0:
    return inspector.selectElementById(rows[0].id)
  inspector.selectElementById(rows[min(rows.high, index + 1)].id)

proc selectPreviousElement*(inspector: InspectorVM): bool {.discardable.} =
  let rows = inspector.filteredLayers.val
  if rows.len == 0:
    return false
  let id = inspector.selectedElement.val.fallbackElementId()
  let index = rows.rowIndex(id)
  if index < 0:
    return inspector.selectElementById(rows[rows.high].id)
  inspector.selectElementById(rows[max(0, index - 1)].id)

proc editProperty*(inspector: InspectorVM;
    request: PropertyEditRequest): PropertyEditResult {.discardable.} =
  ## Update the selected element and produce source-aware edit data.
  var normalizedRequest = request
  normalizedRequest.newValue = normalizePrimitiveInputValue(
    request.property, request.newValue)
  let element = inspector.selectedElement.val
  if element.tag.len == 0:
    result = withStatus(pesRejected, @[
      diagnostic(pedMissingSelection, element, normalizedRequest.property,
        "Select an element before editing inspector properties.")
    ])
    inspector.editDiagnostics.val = result.diagnostics
    return

  var propIndex = -1
  var prop = PropertyInfo()
  for i, candidate in element.properties:
    if candidate.name == normalizedRequest.property:
      propIndex = i
      prop = candidate
      break

  if propIndex < 0:
    if normalizedRequest.newValue.strip.len == 0 or element.sourceFile.len == 0:
      result = withStatus(pesRejected, @[
        diagnostic(pedUnknownProperty, element, normalizedRequest.property,
          "The selected element does not expose this property.")
      ])
      inspector.editDiagnostics.val = result.diagnostics
      return
    prop = PropertyInfo(
      name: normalizedRequest.property,
      value: "",
      origin: poInherited,
      originDetail: "property-addition",
      sourceFile: element.sourceFile,
      sourceLine: element.sourceLine,
      directStyleAllowed: true)

  var diagnostics: seq[PropertyEditDiagnostic] = @[]
  if prop.isShared and normalizedRequest.scope == pesUnspecified:
    diagnostics.add diagnostic(pedSharedScopeRequired, prop,
      "Shared properties require an explicit local or shared scope.")
    result = withStatus(pesNeedsScope, diagnostics)
    inspector.editDiagnostics.val = diagnostics
    return

  if prop.origin == poSetStyle and not prop.directStyleAllowed:
    diagnostics.add diagnostic(pedUnsupportedDirectStyle, prop,
      "Direct setStyle origins are review-only; move the style into classes or tokens before editing.")

  if (request.kind == pekCss or request.kind == pekLayout) and
      prop.sourceFile.isViewModelSource:
    diagnostics.add diagnostic(pedViewModelBoundary, prop,
      "CSS and layout edits cannot be applied from ViewModel-owned source.")

  if prop.isTokenDrift(normalizedRequest.newValue):
    diagnostics.add diagnostic(pedTokenDrift, prop,
      "Theme-token properties must stay on token values instead of literal colors.")

  if prop.isEmptyA11yEdit(normalizedRequest.newValue):
    diagnostics.add diagnostic(pedAccessibility, prop,
      "Accessibility text properties cannot be blank.")

  let normalized = parseCssPropertyValue(prop.name, normalizedRequest.newValue)
  diagnostics.add prop.validateCssPropertyValue(normalizedRequest, normalized)

  if diagnostics.len > 0:
    result = withStatus(pesRejected, diagnostics)
    inspector.editDiagnostics.val = diagnostics
    return

  var updated = element
  if propIndex >= 0:
    updated.properties[propIndex].value = normalized.canonical
  else:
    var added = prop
    added.value = normalized.canonical
    updated.properties.add added
  inspector.selectedElement.val = updated
  inspector.editDiagnostics.val = @[]

  let record = prop.editRecord(normalizedRequest)
  let plan = prop.sourcePlan(normalizedRequest)
  inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = @[]
    for existing in prev:
      if existing.conflictKey != plan.conflictKey:
        result.add existing
    result.add plan
  inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = @[]
    for existing in prev:
      if existing.plan.conflictKey != plan.conflictKey:
        result.add existing
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  inspector.undoStack.update proc(prev: seq[CSSPropertyEditTransaction]): seq[
      CSSPropertyEditTransaction] =
    result = prev
    result.add CSSPropertyEditTransaction(
      record: record,
      sourceEdit: plan,
      beforeElement: element,
      afterElement: updated)
  inspector.redoStack.val = @[]

  PropertyEditResult(status: pesAccepted, record: record, sourceEdit: plan)

proc editInspectorProperty*(editor: EditorVM;
    request: PropertyEditRequest): PropertyEditResult {.discardable.} =
  result = editor.inspector.editProperty(request)
  if result.status == pesAccepted:
    editor.workspaceEditStage.val = wesDirty
    editor.workspaceEditDiagnostics.val = @[]
    editor.recordEditorTiming(epbkPropertyEditPreview, 1,
      "source-plan:" & result.sourceEdit.property)
    let acceptedRecord = result.record
    editor.chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
      result = prev
      result.add acceptedRecord
    let changedPlan = result.sourceEdit
    editor.chat.proposedEdits.update proc(prev: seq[AgentEditProposal]): seq[
        AgentEditProposal] =
      result = prev
      for proposal in result.mitems:
        if proposal.status == aepsProposed:
          for plan in proposal.sourceEdits:
            if (plan.conflictKey.len > 0 and plan.conflictKey ==
                changedPlan.conflictKey) or
                (plan.file.len > 0 and plan.file == changedPlan.file and
                plan.schemaKey == changedPlan.schemaKey):
              proposal.validity = aepvNeedsRebase
              proposal.validityDiagnostics.add AgentDiagnosticSnapshot(
                source: "manual-edit",
                severity: "warning",
                category: "proposal-rebase",
                message: "Manual edits changed the same source ownership scope after this AI proposal was created.",
                file: changedPlan.file,
                line: changedPlan.line,
                property: changedPlan.property)
              break
  elif result.diagnostics.len > 0:
    let editDiagnostics = result.diagnostics
    editor.review.violations.update proc(prev: seq[Violation]): seq[Violation] =
      result = prev
      for d in editDiagnostics:
        let category =
          case d.kind
          of pedUnsupportedDirectStyle: vcDirectStyle
          of pedViewModelBoundary: vcViewModelBoundary
          of pedTokenDrift: vcDryTokens
          of pedAccessibility: vcAccessibility
          of pedSharedScopeRequired, pedMissingSelection, pedUnknownProperty:
            vcMockCompleteness
          of pedInvalidCssValue, pedInvalidPropertyCombination,
              pedSchemaViolation, pedSourceConflict:
            vcDirectStyle
          of pedInvalidTokenReference:
            vcDryTokens
        result.add Violation(
          severity: if d.kind in {pedSharedScopeRequired, pedMissingSelection,
              pedUnknownProperty}: vsWarning else: vsError,
          category: category,
          message: d.message,
          file: d.file,
          line: d.line,
          autoFixable: d.kind in {pedUnsupportedDirectStyle, pedTokenDrift,
              pedAccessibility})

proc editCssProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekCss, scope: scope,
    origin: origin))

proc editLayoutProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekLayout, scope: scope,
    origin: origin))

proc editStateProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekState, scope: scope,
    origin: origin))

proc applyPendingSourceEdits*(inspector: InspectorVM;
    adapter: SourceEditAdapter): int =
  ## Apply pending plans through a project-owned adapter. No file IO is owned here.
  var remaining: seq[SourceEditPlan] = @[]
  for plan in inspector.pendingSourceEdits.val:
    if adapter(plan):
      inc result
    else:
      remaining.add plan
  inspector.pendingSourceEdits.val = remaining
  if remaining.len == 0:
    inspector.sourcePreviews.val = @[]

proc undoCssPropertyEdit*(inspector: InspectorVM): bool {.discardable.} =
  let stack = inspector.undoStack.val
  if stack.len == 0:
    return false

  let txn = stack[^1]
  inspector.selectedElement.val = txn.beforeElement
  inspector.undoStack.val = stack[0 ..< stack.len - 1]
  inspector.redoStack.update proc(prev: seq[CSSPropertyEditTransaction]): seq[
      CSSPropertyEditTransaction] =
    result = prev
    result.add txn
  inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = @[]
    for plan in prev:
      if plan.conflictKey != txn.sourceEdit.conflictKey:
        result.add plan
  inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = @[]
    for preview in prev:
      if preview.plan.conflictKey != txn.sourceEdit.conflictKey:
        result.add preview
  true

proc redoCssPropertyEdit*(inspector: InspectorVM): bool {.discardable.} =
  let stack = inspector.redoStack.val
  if stack.len == 0:
    return false

  let txn = stack[^1]
  inspector.selectedElement.val = txn.afterElement
  inspector.redoStack.val = stack[0 ..< stack.len - 1]
  inspector.undoStack.update proc(prev: seq[CSSPropertyEditTransaction]): seq[
      CSSPropertyEditTransaction] =
    result = prev
    result.add txn
  inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add txn.sourceEdit
  inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(
      plan: txn.sourceEdit,
      beforeText: txn.sourceEdit.previewBefore,
      afterText: txn.sourceEdit.previewAfter)
  true

proc discardCssPropertyEdits*(inspector: InspectorVM) =
  let stack = inspector.undoStack.val
  if stack.len > 0:
    inspector.selectedElement.val = stack[0].beforeElement
  inspector.pendingSourceEdits.val = @[]
  inspector.sourcePreviews.val = @[]
  inspector.undoStack.val = @[]
  inspector.redoStack.val = @[]
  inspector.conflicts.val = @[]
  inspector.editDiagnostics.val = @[]

proc markCssPropertyEditsSaved*(inspector: InspectorVM) =
  inspector.pendingSourceEdits.val = @[]
  inspector.sourcePreviews.val = @[]
  inspector.undoStack.val = @[]
  inspector.redoStack.val = @[]
  inspector.conflicts.val = @[]
  inspector.editDiagnostics.val = @[]

proc detectCssSourceConflicts*(inspector: InspectorVM;
    actualValues: seq[CSSSourceConflict]): seq[CSSSourceConflict] =
  ## Accepts project-owned current source values and reports mismatches.
  ## The actualValue field carries the value read from disk.
  var conflicts: seq[CSSSourceConflict] = @[]
  for plan in inspector.pendingSourceEdits.val:
    for actual in actualValues:
      if actual.file == plan.file and actual.property == plan.property and
          actual.actualValue != plan.expectedOldValue:
        conflicts.add CSSSourceConflict(
          file: plan.file,
          property: plan.property,
          expectedOldValue: plan.expectedOldValue,
          actualValue: actual.actualValue,
          message: "Source changed before the pending CSS edit could be saved.")
  inspector.conflicts.val = conflicts
  if conflicts.len > 0:
    inspector.editDiagnostics.val = conflicts.mapIt(PropertyEditDiagnostic(
      kind: pedSourceConflict,
      message: it.message,
      file: it.file,
      line: 0,
      property: it.property))
  conflicts

proc saveCssPropertyEdits*(inspector: InspectorVM;
    adapter: SourceEditAdapter): bool {.discardable.} =
  if inspector.conflicts.val.len > 0:
    return false
  let total = inspector.pendingSourceEdits.val.len
  if total == 0:
    return true
  result = inspector.applyPendingSourceEdits(adapter) == total
  if result:
    inspector.markCssPropertyEditsSaved()

# ===========================================================================
# Foundation and component variant editor actions
# ===========================================================================

func sameTokenKey(a, b: string): bool =
  a.toLowerAscii() == b.toLowerAscii()

proc addStoryOnce(stories: var seq[StoryRef]; story: StoryRef) =
  if story.isEmptyStoryRef:
    return
  for existing in stories:
    if sameStory(existing, story):
      return
  stories.add story

proc parseHexChannel(hex: string; start: int): int =
  try:
    parseHexInt(hex[start .. start + 1])
  except ValueError:
    0

proc hexColorChannels(raw: string): tuple[ok: bool, r, g, b: int] =
  let text = raw.strip()
  if not text.startsWith("#"):
    return
  let hex = text[1 .. ^1]
  if hex.len == 3 and hex.allIt(it.isDigit or it.toLowerAscii() in {'a'..'f'}):
    return (true,
      parseHexInt($hex[0] & $hex[0]),
      parseHexInt($hex[1] & $hex[1]),
      parseHexInt($hex[2] & $hex[2]))
  if hex.len == 6 and hex.allIt(it.isDigit or it.toLowerAscii() in {'a'..'f'}):
    return (true, hex.parseHexChannel(0), hex.parseHexChannel(2),
      hex.parseHexChannel(4))

proc linearChannel(channel: int): float =
  let c = channel.float / 255.0
  if c <= 0.03928:
    c / 12.92
  else:
    pow((c + 0.055) / 1.055, 2.4)

proc relativeLuminance(raw: string): tuple[ok: bool, value: float] =
  let rgb = hexColorChannels(raw)
  if not rgb.ok:
    return
  (true, 0.2126 * linearChannel(rgb.r) + 0.7152 * linearChannel(rgb.g) +
    0.0722 * linearChannel(rgb.b))

proc contrastRatio(foreground, background: string): float =
  let fg = relativeLuminance(foreground)
  let bg = relativeLuminance(background)
  if not fg.ok or not bg.ok:
    return 0.0
  let lighter = max(fg.value, bg.value)
  let darker = min(fg.value, bg.value)
  (lighter + 0.05) / (darker + 0.05)

func hasSource(span: SourceSpan): bool =
  span.file.len > 0 and span.line > 0

func designDiagnostic(kind: DesignSchemaDiagnosticKind; message: string;
    file = ""; line = 0; property = ""; schemaKey = ""): DesignSchemaDiagnostic =
  DesignSchemaDiagnostic(
    kind: kind,
    message: message,
    file: file,
    line: line,
    property: property,
    schemaKey: schemaKey)

func findDesignNode(schema: DesignSystemSchema;
    key: string): tuple[ok: bool, node: DesignSchemaNode] =
  for node in schema.nodes:
    if node.key == key:
      return (true, node)

func sourceOwnershipPlanKind(ownership: DesignSourceOwnership;
    node: DesignSchemaNode): CSSSourcePlanKind =
  if ownership.fallbackAllowed:
    return cspInlineStyleUpdate
  if ownership.tailwindUtilities.len > 0:
    return cspTailwindClassReplacement
  case node.kind
  of dsnFoundation, dsnSemanticToken, dsnComponentToken:
    cspTokenUpdate
  of dsnClassDefinition, dsnStyleDefinition, dsnStoryFixture,
      dsnComponentVariant, dsnComponentState, dsnDensityMode,
      dsnResponsiveMode:
    cspStructuredSchemaUpdate

func ownershipMatches(ownership: DesignSourceOwnership; element: ElementRef;
    prop: PropertyInfo): bool =
  if ownership.property != prop.name:
    return false
  if ownership.elementSourceKey.len > 0 and
      ownership.elementSourceKey notin [element.sourceKey, element.id]:
    return false
  if ownership.domPath.len > 0 and element.domPath.len > 0 and
      ownership.domPath != element.domPath:
    return false
  if ownership.schemaKey.len > 0 and ownership.schemaKey in [
      prop.schemaKey, prop.tokenName, prop.variantKey, element.schemaKey]:
    return true
  if ownership.nodeKey.len > 0 and ownership.nodeKey in [
      prop.schemaKey, prop.tokenName, prop.variantKey, element.schemaKey]:
    return true
  ownership.elementSourceKey.len > 0 or ownership.domPath.len > 0

func validateDesignSystemSchema*(schema: DesignSystemSchema): seq[
    DesignSchemaDiagnostic] =
  if schema.schemaVersion <= 0 or schema.schemaVersion > 1:
    result.add designDiagnostic(dsdUnsupportedSchemaVersion,
      "Design-system schema version must be 1 for this framework contract.")
  if schema.projectId.len == 0 or schema.ownerPackage.len == 0:
    result.add designDiagnostic(dsdMissingProjectOwner,
      "Design-system schema must identify the project-owned package.")

  for node in schema.nodes:
    if node.key.len == 0:
      result.add designDiagnostic(dsdMissingSourceOwnership,
        "Design-system schema nodes require stable keys.",
        node.sourceSpan.file, node.sourceSpan.line, node.property, node.key)
    if not node.sourceSpan.hasSource:
      result.add designDiagnostic(dsdMissingSourceSpan,
        "Design-system schema node needs a project-owned source span.",
        node.sourceSpan.file, node.sourceSpan.line, node.property, node.key)
    for mode in node.modeValues:
      if not mode.sourceSpan.hasSource:
        result.add designDiagnostic(dsdMissingModeSource,
          "Token mode '" & mode.name & "' needs a project-owned source span.",
          mode.sourceSpan.file, mode.sourceSpan.line, node.property, node.key)

  for ownership in schema.sourceOwnership:
    if ownership.property.len == 0 or
        (ownership.schemaKey.len == 0 and ownership.nodeKey.len == 0):
      result.add designDiagnostic(dsdMissingSourceOwnership,
        "Source ownership entries require a property and schema node.",
        ownership.sourceSpan.file, ownership.sourceSpan.line,
        ownership.property, ownership.schemaKey)
    if ownership.unstructuredViewCode:
      result.add designDiagnostic(dsdUnstructuredViewCode,
        "Property is buried in unstructured view code and needs migration before precise editing.",
        if ownership.generatedViewFile.len > 0: ownership.generatedViewFile
        else: ownership.sourceSpan.file,
        if ownership.generatedViewLine > 0: ownership.generatedViewLine
        else: ownership.sourceSpan.line,
        ownership.property,
        if ownership.nodeKey.len > 0: ownership.nodeKey else: ownership.schemaKey)

func resolveDesignSourceOwnership*(schema: DesignSystemSchema;
    element: ElementRef; property: string): DesignSourceOwnershipReport =
  result.property = property
  var prop = PropertyInfo()
  var foundProperty = false
  for candidate in element.properties:
    if candidate.name == property:
      prop = candidate
      foundProperty = true
      break

  if not foundProperty:
    result.diagnostics.add designDiagnostic(dsdMissingSourceOwnership,
      "Selected element does not expose property '" & property & "'.",
      element.sourceFile, element.sourceLine, property, element.schemaKey)
    return

  for ownership in schema.sourceOwnership:
    if not ownership.ownershipMatches(element, prop):
      continue
    let key = if ownership.nodeKey.len > 0: ownership.nodeKey
      else: ownership.schemaKey
    let found = schema.findDesignNode(key)
    if not found.ok:
      result.diagnostics.add designDiagnostic(dsdMissingSourceOwnership,
        "Source ownership points at an unknown design schema node.",
        ownership.sourceSpan.file, ownership.sourceSpan.line,
        ownership.property, key)
      return
    result.ok = not ownership.unstructuredViewCode
    result.nodeKey = found.node.key
    result.schemaNode = found.node
    result.ownership = ownership
    result.planKind = ownership.sourceOwnershipPlanKind(found.node)
    if ownership.unstructuredViewCode:
      result.diagnostics.add designDiagnostic(dsdUnstructuredViewCode,
        "Property is buried in unstructured view code and needs migration before precise editing.",
        if ownership.generatedViewFile.len > 0: ownership.generatedViewFile
        else: ownership.sourceSpan.file,
        if ownership.generatedViewLine > 0: ownership.generatedViewLine
        else: ownership.sourceSpan.line,
        property, found.node.key)
    return

  result.diagnostics.add designDiagnostic(dsdMissingSourceOwnership,
    "No source ownership edge maps property '" & property & "' to the project schema.",
    prop.sourceFile, prop.sourceLine, property, prop.schemaKey)

proc resolveDesignSourceOwnership*(editor: EditorVM;
    property: string): DesignSourceOwnershipReport =
  resolveDesignSourceOwnership(editor.designSystemSchema.val,
    editor.inspector.selectedElement.val, property)

func layoutControlCapabilities*(family: LayoutControlFamily): seq[
    LayoutControlCapability] =
  result = @[lccSourceRoutedPlan]
  case family
  of lcfFlexAutoLayout:
    result.add @[
      lccFlexDirection, lccFlexWrap, lccGap, lccPadding, lccAlign,
      lccJustify, lccDistribution, lccHugFillFixedSizing, lccChildOrder,
      lccPerChildAlignment]
  of lcfGrid:
    result.add @[
      lccGridTemplateTracks, lccGridGap, lccGridPlacement,
      lccGridAutoFlow, lccGridNamedAreas]
  of lcfConstraints:
    result.add @[
      lccConstraints, lccMinMax, lccIntrinsicContentSizing, lccAspectRatio,
      lccOverflowStrategy]
  of lcfResponsiveOverride:
    result.add @[lccBreakpointScopedOverride, lccProjectDefinedMode]
  of lcfCanvasGuide:
    result.add @[
      lccSpacingMeasurement, lccGapOverlay, lccAlignHandle, lccResizeHandle,
      lccSnapLine, lccLayoutDiagnostic]

func responsiveEditModes*(schema: DesignSystemSchema): seq[ResponsiveEditMode] =
  result = @[
    ResponsiveEditMode(key: "desktop", label: "Desktop", kind: rmkDesktop),
    ResponsiveEditMode(key: "tablet", label: "Tablet", kind: rmkTablet),
    ResponsiveEditMode(key: "mobile", label: "Mobile", kind: rmkMobile)
  ]
  for node in schema.nodes:
    if node.kind == dsnResponsiveMode:
      let key =
        if node.key.len > 0: node.key
        elif node.value.len > 0: node.value
        else: node.name
      if key.len > 0 and not result.anyIt(it.key == key):
        result.add ResponsiveEditMode(key: key, label: node.name,
          kind: rmkProjectDefined, sourceSpan: node.sourceSpan)

func layoutModeKey*(viewport: PreviewViewport): string =
  case viewport
  of pvDesktop: "desktop"
  of pvTablet: "tablet"
  of pvMobile: "mobile"

func layoutCommand*(family: LayoutControlFamily; property, value: string;
    scope = pesLocal; modeKey = ""; childSourceKey = "";
    sourceBackedOnly = true): LayoutControlCommand =
  LayoutControlCommand(
    family: family,
    property: property,
    value: value,
    scope: scope,
    modeKey: modeKey,
    childSourceKey: childSourceKey,
    sourceBackedOnly: sourceBackedOnly)

func propertyDiagnosticFromDesign(kind: PropertyEditDiagnosticKind;
    message: string; design: DesignSchemaDiagnostic): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: design.file,
    line: design.line,
    property: design.property)

proc planLayoutControlEdit*(schema: DesignSystemSchema; element: ElementRef;
    command: LayoutControlCommand): LayoutControlPlan =
  result.command = command
  result.capabilities = layoutControlCapabilities(command.family)
  if command.family == lcfResponsiveOverride:
    result.capabilities.add layoutControlCapabilities(lcfFlexAutoLayout)
  var ownership = resolveDesignSourceOwnership(schema, element,
    command.property)
  if command.modeKey.len > 0:
    for candidate in schema.sourceOwnership:
      if candidate.property != command.property:
        continue
      if candidate.elementSourceKey.len > 0 and
          candidate.elementSourceKey notin [element.sourceKey, element.id]:
        continue
      let key = if candidate.nodeKey.len > 0: candidate.nodeKey
        else: candidate.schemaKey
      if command.modeKey notin key:
        continue
      let found = schema.findDesignNode(key)
      if found.ok:
        ownership = DesignSourceOwnershipReport(ok: not candidate.unstructuredViewCode,
          property: command.property,
          nodeKey: found.node.key,
          schemaNode: found.node,
          ownership: candidate,
          planKind: candidate.sourceOwnershipPlanKind(found.node))
      break
  result.ownership = ownership
  if command.sourceBackedOnly and not ownership.ok:
    for d in ownership.diagnostics:
      result.diagnostics.add propertyDiagnosticFromDesign(
        pedSchemaViolation,
        if d.message.len > 0: d.message
        else: "Layout control requires a source-backed schema owner.",
        d)
    if result.diagnostics.len == 0:
      result.diagnostics.add PropertyEditDiagnostic(
        kind: pedSchemaViolation,
        message: "Layout control requires a source-backed schema owner.",
        file: element.sourceFile,
        line: element.sourceLine,
        property: command.property)
    return

  var prop = PropertyInfo()
  var foundProperty = false
  if command.modeKey.len > 0:
    for candidate in element.properties:
      if candidate.name == command.property and
          candidate.variantKey == command.modeKey:
        prop = candidate
        foundProperty = true
        break
    if not foundProperty:
      for candidate in element.properties:
        if candidate.name == command.property and candidate.variantKey.len == 0:
          prop = candidate
          foundProperty = true
          break
  else:
    for candidate in element.properties:
      if candidate.name == command.property:
        prop = candidate
        foundProperty = true
        break
  if not foundProperty:
    prop = PropertyInfo(
      name: command.property,
      value: "",
      origin: poInherited,
      originDetail: "layout-control-addition",
      sourceFile: element.sourceFile,
      sourceLine: element.sourceLine,
      schemaKey: if ownership.nodeKey.len > 0: ownership.nodeKey else: element.schemaKey,
      variantKey: command.modeKey,
      directStyleAllowed: not command.sourceBackedOnly)

  var routedProp = prop
  if ownership.ok:
    routedProp.sourceFile =
      if ownership.ownership.sourceSpan.file.len > 0:
        ownership.ownership.sourceSpan.file
      else:
        prop.sourceFile
    routedProp.sourceLine =
      if ownership.ownership.sourceSpan.line > 0:
        ownership.ownership.sourceSpan.line
      else:
        prop.sourceLine
    routedProp.schemaKey = ownership.nodeKey
    routedProp.originDetail =
      case ownership.schemaNode.kind
      of dsnFoundation, dsnSemanticToken, dsnComponentToken:
        "layout-token:" & ownership.nodeKey
      of dsnClassDefinition:
        "layout-class:" & ownership.ownership.cssModuleClass
      of dsnStyleDefinition:
        "layout-style:" & ownership.nodeKey
      of dsnStoryFixture:
        "layout-fixture:" & ownership.nodeKey
      of dsnResponsiveMode:
        "layout-responsive:" & ownership.nodeKey
      else:
        "layout-schema:" & ownership.nodeKey
    if command.modeKey.len > 0:
      routedProp.variantKey = command.modeKey

  let request = PropertyEditRequest(property: command.property,
    newValue: command.value, kind: pekLayout, scope: command.scope,
    origin: peoInspector)
  let normalized = parseCssPropertyValue(command.property, command.value)
  let diagnostics = routedProp.validateCssPropertyValue(request, normalized)
  if diagnostics.len > 0:
    result.diagnostics = diagnostics
    return

  var plan = routedProp.sourcePlan(request)
  if ownership.ok:
    plan.planKind = ownership.planKind
    plan.schemaKey = ownership.nodeKey
    plan.tokenName =
      if ownership.schemaNode.kind in {dsnFoundation, dsnSemanticToken,
          dsnComponentToken}: ownership.nodeKey
      else:
        routedProp.tokenName
    plan.file = routedProp.sourceFile
    plan.line = routedProp.sourceLine
    plan.originDetail = routedProp.originDetail
    plan.regeneratorHook =
      if plan.planKind in {cspStructuredSchemaUpdate, cspTokenUpdate}:
        "regenerate-layout-source"
      else:
        ""
  if command.modeKey.len > 0:
    plan.variantKey = command.modeKey
    plan.conflictKey = plan.file & ":" & $plan.line & ":" & plan.property &
      ":" & command.modeKey
  result.ok = true
  result.sourceEdit = plan

proc planLayoutControlEdit*(editor: EditorVM;
    command: LayoutControlCommand): LayoutControlPlan =
  planLayoutControlEdit(editor.designSystemSchema.val,
    editor.inspector.selectedElement.val, command)

proc planResponsiveLayoutOverride*(editor: EditorVM; modeKey, property,
    value: string; family = lcfResponsiveOverride): LayoutControlPlan =
  editor.planLayoutControlEdit(layoutCommand(family, property, value,
    pesLocal, modeKey = modeKey, sourceBackedOnly = true))

proc applyResponsiveLayoutOverride*(editor: EditorVM; modeKey, property,
    value: string; family = lcfResponsiveOverride): LayoutControlPlan {.discardable.} =
  result = editor.planResponsiveLayoutOverride(modeKey, property, value, family)
  if not result.ok:
    editor.inspector.editDiagnostics.val = result.diagnostics
    return

  var element = editor.inspector.selectedElement.val
  var index = -1
  for i, prop in element.properties:
    if prop.name == property and prop.variantKey == modeKey:
      index = i
      break
  if index >= 0:
    element.properties[index].value = result.sourceEdit.newValue
  else:
    element.properties.add PropertyInfo(
      name: property,
      value: result.sourceEdit.newValue,
      origin: poConstant,
      originDetail: result.sourceEdit.originDetail,
      sourceFile: result.sourceEdit.file,
      sourceLine: result.sourceEdit.line,
      schemaKey: result.sourceEdit.schemaKey,
      variantKey: modeKey)
  editor.inspector.selectedElement.val = element
  let sourceEdit = result.sourceEdit
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = @[]
    for existing in prev:
      if existing.conflictKey != sourceEdit.conflictKey:
        result.add existing
    result.add sourceEdit
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: sourceEdit,
      beforeText: sourceEdit.previewBefore,
      afterText: sourceEdit.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  editor.inspector.editDiagnostics.val = @[]

func directCanvasFamily(kind: DirectCanvasOperationKind;
    property: string): LayoutControlFamily =
  let prop = property.normalizedCssName()
  case kind
  of dcokResize:
    if prop in ["width", "height", "min-width", "min-height", "max-width",
        "max-height", "aspect-ratio", "flex" & "-basis"]:
      lcfConstraints
    else:
      lcfCanvasGuide
  of dcokSpacing, dcokReorder:
    lcfFlexAutoLayout
  of dcokInlineText, dcokContextCommand:
    lcfCanvasGuide

func directCanvasPropertyFor(command: DirectCanvasContextCommand): string =
  case command
  of dcccCopyStyles, dcccPasteStyles:
    "style"
  of dcccReset:
    "reset"
  of dcccDetach:
    "class"
  of dcccPromote:
    "style"
  of dcccCreateVariant:
    "variant"
  of dcccWrap:
    "wrapper"
  of dcccDuplicate:
    "duplicate"
  of dcccDelete:
    "delete"
  of dcccOpenSource:
    "source"
  of dcccAskAi:
    "ai-selection"

func firstProperty(element: ElementRef): PropertyInfo =
  if element.properties.len > 0:
    element.properties[0]
  else:
    PropertyInfo(name: "selection", value: "", origin: poInherited,
      originDetail: "direct-canvas-selection", sourceFile: element.sourceFile,
      sourceLine: element.sourceLine, schemaKey: element.schemaKey,
      directStyleAllowed: true)

func propertyOrDefault(element: ElementRef; property, fallback: string): PropertyInfo =
  for prop in element.properties:
    if prop.name == property:
      return prop
  PropertyInfo(name: property, value: fallback, origin: poInherited,
    originDetail: "direct-canvas:" & property, sourceFile: element.sourceFile,
    sourceLine: element.sourceLine, schemaKey: element.schemaKey & "." & property,
    directStyleAllowed: true)

proc stageDirectCanvasPlan(editor: EditorVM; operation: DirectCanvasOperation;
    beforeElement, afterElement: ElementRef; prop: PropertyInfo;
    plan: SourceEditPlan): DirectCanvasOperationResult =
  let record = EditRecord(
    file: plan.file,
    line: plan.line,
    property: plan.property,
    oldValue: plan.oldValue,
    newValue: plan.newValue,
    origin: prop.origin,
    originDetail: plan.originDetail,
    scope: plan.scope,
    isShared: plan.scope == pesShared,
    editOrigin: peoInspector,
    sourcePlanKind: plan.planKind)
  editor.inspector.selectedElement.val = afterElement
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = @[]
    for existing in prev:
      if existing.conflictKey != plan.conflictKey:
        result.add existing
    result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = @[]
    for existing in prev:
      if existing.plan.conflictKey != plan.conflictKey:
        result.add existing
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  editor.inspector.undoStack.update proc(prev: seq[CSSPropertyEditTransaction]): seq[
      CSSPropertyEditTransaction] =
    result = prev
    result.add CSSPropertyEditTransaction(record: record,
      sourceEdit: plan, beforeElement: beforeElement,
      afterElement: afterElement)
  editor.inspector.redoStack.val = @[]
  editor.inspector.editDiagnostics.val = @[]
  editor.workspaceEditStage.val = wesDirty
  editor.workspaceEditDiagnostics.val = @[]
  editor.chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
    result = prev
    result.add record
  DirectCanvasOperationResult(ok: true, operation: operation,
    sourceEdit: plan, measurement: operation.measurement)

proc planOwnedDirectSourceEdit(editor: EditorVM; operation: DirectCanvasOperation;
    prop: PropertyInfo): tuple[ok: bool, plan: SourceEditPlan,
      diagnostics: seq[PropertyEditDiagnostic]] =
  let ownership = editor.resolveDesignSourceOwnership(operation.property)
  if not ownership.ok:
    for d in ownership.diagnostics:
      result.diagnostics.add propertyDiagnosticFromDesign(pedSchemaViolation,
        if d.message.len > 0: d.message
        else: "Direct canvas operation requires source ownership.", d)
    return
  let file =
    if ownership.ownership.sourceSpan.file.len > 0:
      ownership.ownership.sourceSpan.file
    else:
      prop.sourceFile
  let line =
    if ownership.ownership.sourceSpan.line > 0:
      ownership.ownership.sourceSpan.line
    else:
      prop.sourceLine
  let oldValue =
    if operation.oldValue.len > 0: operation.oldValue
    elif prop.value.len > 0: prop.value
    else: ownership.schemaNode.value
  let prefix =
    case operation.kind
    of dcokInlineText:
      "direct-inline-text:"
    of dcokReorder:
      "direct-reorder:"
    of dcokContextCommand:
      "direct-context:"
    of dcokResize:
      "direct-resize:"
    of dcokSpacing:
      "direct-spacing:"
  let planKind =
    if ownership.schemaNode.kind in {dsnFoundation, dsnSemanticToken,
        dsnComponentToken}: cspTokenUpdate
    else:
      ownership.planKind
  result.plan = SourceEditPlan(
    file: file,
    line: line,
    property: operation.property,
    oldValue: oldValue,
    newValue: operation.value.strip(),
    originDetail: prefix & ownership.nodeKey,
    scope: pesShared,
    planKind: planKind,
    schemaKey: ownership.nodeKey,
    tokenName: if planKind == cspTokenUpdate: ownership.nodeKey else: prop.tokenName,
    variantKey: prop.variantKey,
    reversible: true,
    previewBefore: operation.property & ": " & oldValue,
    previewAfter: operation.property & ": " & operation.value.strip(),
    formatterHook: "format-direct-canvas-edit",
    regeneratorHook:
      if planKind in {cspStructuredSchemaUpdate, cspTokenUpdate}:
        "regenerate-direct-canvas-source"
      else:
        "",
    conflictKey: file & ":" & $line & ":" & operation.property & ":" &
      $operation.kind,
    expectedOldValue:
      if prop.originDetail.startsWith("iframe-dom:"): "" else: oldValue)
  result.ok = true

proc applyDirectCanvasOperation*(editor: EditorVM;
    operation: DirectCanvasOperation): DirectCanvasOperationResult {.discardable.} =
  ## Route iframe direct manipulation into the same source-backed journal used
  ## by inspector edits. Schema ownership wins; DOM-style fallback is used only
  ## for consumer previews that expose a generic source-map adapter.
  let beforeElement = editor.inspector.selectedElement.val
  if beforeElement.tag.len == 0:
    result = DirectCanvasOperationResult(ok: false, operation: operation,
      diagnostics: @[PropertyEditDiagnostic(kind: pedMissingSelection,
        message: "Select an element before using direct canvas editing.",
        file: beforeElement.sourceFile, line: beforeElement.sourceLine,
        property: operation.property)])
    editor.inspector.editDiagnostics.val = result.diagnostics
    return

  var op = operation
  if op.property.len == 0 and op.kind == dcokContextCommand:
    op.property = op.command.directCanvasPropertyFor()
  if op.property.len == 0:
    op.property = "style"

  case op.kind
  of dcokResize, dcokSpacing, dcokReorder:
    let family = directCanvasFamily(op.kind, op.property)
    let planned = editor.planLayoutControlEdit(layoutCommand(family,
      op.property, op.value, pesLocal,
      childSourceKey = op.sourceKey, sourceBackedOnly = true))
    if planned.ok:
      var afterElement = beforeElement
      var index = -1
      for i, candidate in afterElement.properties:
        if candidate.name == op.property:
          index = i
          break
      var prop = beforeElement.propertyOrDefault(op.property,
        planned.sourceEdit.oldValue)
      prop.sourceFile = planned.sourceEdit.file
      prop.sourceLine = planned.sourceEdit.line
      prop.schemaKey = planned.sourceEdit.schemaKey
      prop.originDetail = planned.sourceEdit.originDetail
      prop.value = planned.sourceEdit.newValue
      if index >= 0:
        afterElement.properties[index] = prop
      else:
        afterElement.properties.add prop
      return editor.stageDirectCanvasPlan(op, beforeElement, afterElement, prop,
        planned.sourceEdit)

    if editor.designSystemSchema.val.sourceOwnership.len > 0:
      result = DirectCanvasOperationResult(ok: false, operation: op,
        diagnostics: planned.diagnostics)
      editor.inspector.editDiagnostics.val = planned.diagnostics
      return

    let fallback = editor.editInspectorProperty(PropertyEditRequest(
      property: op.property, newValue: op.value, kind: pekLayout,
      scope: pesLocal, origin: peoInspector))
    return DirectCanvasOperationResult(
      ok: fallback.status == pesAccepted,
      operation: op,
      sourceEdit: fallback.sourceEdit,
      diagnostics: fallback.diagnostics,
      measurement: op.measurement)

  of dcokInlineText:
    let prop = beforeElement.propertyOrDefault(op.property, op.oldValue)
    let owned = editor.planOwnedDirectSourceEdit(op, prop)
    if not owned.ok:
      if editor.designSystemSchema.val.sourceOwnership.len > 0:
        result = DirectCanvasOperationResult(ok: false, operation: op,
          diagnostics: owned.diagnostics)
        editor.inspector.editDiagnostics.val = owned.diagnostics
        return
      let fallback = editor.editInspectorProperty(PropertyEditRequest(
        property: op.property, newValue: op.value, kind: pekState,
        scope: pesLocal, origin: peoInspector))
      return DirectCanvasOperationResult(
        ok: fallback.status == pesAccepted,
        operation: op,
        sourceEdit: fallback.sourceEdit,
        diagnostics: fallback.diagnostics,
        measurement: op.measurement)
    var afterElement = beforeElement
    var index = -1
    for i, candidate in afterElement.properties:
      if candidate.name == op.property:
        index = i
        break
    var routedProp = prop
    routedProp.value = owned.plan.newValue
    routedProp.sourceFile = owned.plan.file
    routedProp.sourceLine = owned.plan.line
    routedProp.schemaKey = owned.plan.schemaKey
    routedProp.originDetail = owned.plan.originDetail
    if index >= 0:
      afterElement.properties[index] = routedProp
    else:
      afterElement.properties.add routedProp
    result = editor.stageDirectCanvasPlan(op, beforeElement, afterElement, routedProp,
      owned.plan)

  of dcokContextCommand:
    case op.command
    of dcccOpenSource:
      let state = editor.runEditorCommand(eckOpenSource)
      result = DirectCanvasOperationResult(ok: state.status == ecsSucceeded,
        operation: op, commandState: state)
    of dcccCreateVariant:
      let state = editor.runEditorCommand(eckCreateVariant)
      result = DirectCanvasOperationResult(ok: state.status == ecsSucceeded,
        operation: op, commandState: state)
    of dcccDuplicate:
      let state = editor.runEditorCommand(eckDuplicate)
      result = DirectCanvasOperationResult(ok: state.status == ecsSucceeded,
        operation: op, commandState: state)
    of dcccDelete:
      let state = editor.runEditorCommand(eckDelete)
      result = DirectCanvasOperationResult(ok: state.status == ecsSucceeded,
        operation: op, commandState: state)
    of dcccAskAi:
      let target =
        if beforeElement.ancestors.len > 0: beforeElement.ancestors.join(" > ")
        else: beforeElement.tag
      editor.chat.inputText.val =
        (if editor.chat.inputText.val.strip.len > 0:
          editor.chat.inputText.val.strip & "\n"
        else:
          "") & "Ask AI about selection: " & target
      editor.editMode.val = emComment
      result = DirectCanvasOperationResult(ok: true, operation: op)
    of dcccCopyStyles:
      let prop = beforeElement.firstProperty()
      result = DirectCanvasOperationResult(ok: true, operation: DirectCanvasOperation(
        kind: dcokContextCommand, command: dcccCopyStyles,
        property: prop.name, value: prop.value,
        sourceKey: beforeElement.sourceKey))
    of dcccPasteStyles, dcccReset, dcccDetach, dcccPromote, dcccWrap:
      var property = op.property
      if property in ["", "style", "reset", "class", "wrapper"]:
        property = beforeElement.firstProperty().name
      var value = op.value
      if op.command == dcccReset and value.len == 0:
        value = op.oldValue
      if value.len == 0:
        value = beforeElement.firstProperty().value
      let prop = beforeElement.propertyOrDefault(property, op.oldValue)
      let owned = editor.planOwnedDirectSourceEdit(DirectCanvasOperation(
        kind: dcokContextCommand, command: op.command, property: property,
        value: value, oldValue: prop.value, sourceKey: op.sourceKey,
        measurement: op.measurement), prop)
      if owned.ok:
        var afterElement = beforeElement
        for i, candidate in afterElement.properties:
          if candidate.name == property:
            afterElement.properties[i].value = owned.plan.newValue
            afterElement.properties[i].originDetail = owned.plan.originDetail
            afterElement.properties[i].schemaKey = owned.plan.schemaKey
        return editor.stageDirectCanvasPlan(op, beforeElement, afterElement,
          prop, owned.plan)
      if editor.designSystemSchema.val.sourceOwnership.len > 0:
        result = DirectCanvasOperationResult(ok: false, operation: op,
          diagnostics: owned.diagnostics)
        editor.inspector.editDiagnostics.val = owned.diagnostics
        return
      let fallback = editor.editInspectorProperty(PropertyEditRequest(
        property: property, newValue: value,
        kind: if cssPropertyCategory(property) in {cpcLayout, cpcFlexGrid}: pekLayout else: pekCss,
        scope: pesLocal, origin: peoInspector))
      result = DirectCanvasOperationResult(ok: fallback.status == pesAccepted,
        operation: op, sourceEdit: fallback.sourceEdit,
        diagnostics: fallback.diagnostics)

proc applyDirectCanvasResize*(editor: EditorVM; property,
    value: string): DirectCanvasOperationResult {.discardable.} =
  editor.applyDirectCanvasOperation(DirectCanvasOperation(kind: dcokResize,
    property: property, value: value))

proc applyDirectCanvasSpacing*(editor: EditorVM; property,
    value: string): DirectCanvasOperationResult {.discardable.} =
  editor.applyDirectCanvasOperation(DirectCanvasOperation(kind: dcokSpacing,
    property: property, value: value))

proc applyDirectCanvasInlineText*(editor: EditorVM;
    value: string): DirectCanvasOperationResult {.discardable.} =
  editor.applyDirectCanvasOperation(DirectCanvasOperation(kind: dcokInlineText,
    property: "text", value: value))

func designReviewRank(level: DesignSchemaReviewLevel): int =
  case level
  of dsrlNone: 0
  of dsrlLocal: 1
  of dsrlShared: 2
  of dsrlAccessibility: 3
  of dsrlDesignSystem: 4

func strongestReviewLevel(a, b: DesignSchemaReviewLevel): DesignSchemaReviewLevel =
  if b.designReviewRank > a.designReviewRank: b else: a

proc designSchemaImpact*(schema: DesignSystemSchema;
    schemaKey: string): DesignSchemaImpact =
  let found = schema.findDesignNode(schemaKey)
  result.schemaKey = schemaKey
  if not found.ok:
    result.diagnostics.add designDiagnostic(dsdMissingSourceOwnership,
      "Unknown design schema node '" & schemaKey & "'.", schemaKey = schemaKey)
    return

  let node = found.node
  result.affectedStories = node.stories
  result.affectedComponents = node.components
  result.affectedPages = node.pages
  result.modes = node.modeValues
  result.minContrast = node.minContrast
  result.accessibilityImpact = node.accessibilityImpact
  result.reviewLevel = node.reviewLevel

  for ownership in schema.sourceOwnership:
    if ownership.nodeKey == schemaKey or ownership.schemaKey == schemaKey:
      inc result.usageCount

  result.usageCount = max(result.usageCount, node.usageCount)

  if result.usageCount > 1:
    result.reviewLevel = result.reviewLevel.strongestReviewLevel(dsrlShared)

  if node.foreground.len > 0 and node.background.len > 0:
    result.contrastRatio = contrastRatio(node.foreground, node.background)
    if node.minContrast > 0 and result.contrastRatio > 0 and
        result.contrastRatio < node.minContrast:
      result.accessibilityImpact = dsaiContrast
      result.reviewLevel =
        result.reviewLevel.strongestReviewLevel(dsrlAccessibility)
      result.diagnostics.add designDiagnostic(dsdContrastImpact,
        "Shared edit may reduce contrast below the required threshold.",
        node.sourceSpan.file, node.sourceSpan.line, node.property, node.key)

  if result.modes.len > 0:
    result.reviewLevel =
      result.reviewLevel.strongestReviewLevel(dsrlDesignSystem)

proc designSchemaImpact*(editor: EditorVM;
    schemaKey: string): DesignSchemaImpact =
  designSchemaImpact(editor.designSystemSchema.val, schemaKey)

proc validateFoundationTokenEdit(editor: EditorVM; token: FoundationTokenEntry;
    newValue: string): seq[FoundationEditDiagnostic]

func styleScopeChoiceLabel*(kind: StyleScopeChoiceKind): string =
  case kind
  of sscLocalInstance: "Local instance"
  of sscStoryFixture: "Story fixture"
  of sscComponentSchema: "Component schema"
  of sscComponentToken: "Component token"
  of sscSharedClass: "Shared class"
  of sscSemanticToken: "Semantic token"
  of sscGlobalPrimitiveToken: "Global primitive token"

func styleCascadeLayerLabel*(kind: StyleCascadeLayerKind): string =
  case kind
  of sclFinalValue: "Final value"
  of sclLocalOverride: "Local override"
  of sclStoryFixture: "Story fixture"
  of sclComponentSchema: "Component schema"
  of sclComponentToken: "Component token"
  of sclSharedClass: "Shared class"
  of sclSemanticToken: "Semantic token"
  of sclGlobalPrimitiveToken: "Global primitive token"
  of sclInheritedValue: "Inherited value"
  of sclGeneratedFallback: "Generated fallback"

func tokenKindForNode(node: DesignSchemaNode): FoundationTokenKind =
  case node.kind
  of dsnFoundation:
    ftkColorPalette
  of dsnSemanticToken:
    if cssPropertyCategory(node.property) == cpcColor:
      ftkSemanticColor
    else:
      ftkSpacingScale
  of dsnComponentToken:
    if cssPropertyCategory(node.property) == cpcColor:
      ftkSemanticColor
    else:
      ftkSpacingScale
  else:
    ftkAccessibilityConstraint

func classNameFromOriginDetail(detail: string): string =
  let text = detail.strip()
  if text.startsWith("class:"):
    result = text[6 .. ^1].strip()
  elif text.startsWith("layout-class:"):
    result = text["layout-class:".len .. ^1].strip()
  if result.startsWith("."):
    result = result[1 .. ^1]
  if result.contains(" "):
    result = result.splitWhitespace()[0]

func classNameFromNode(node: DesignSchemaNode): string =
  if node.name.len > 0:
    result = node.name
  elif node.key.startsWith("classes."):
    result = node.key["classes.".len .. ^1]
  else:
    result = node.key
  result = result.strip()
  if result.startsWith("."):
    result = result[1 .. ^1]

func schemaScopeForNode(kind: DesignSchemaNodeKind): StyleScopeChoiceKind =
  case kind
  of dsnStoryFixture:
    sscStoryFixture
  of dsnComponentVariant, dsnComponentState, dsnDensityMode, dsnResponsiveMode,
      dsnStyleDefinition:
    sscComponentSchema
  of dsnComponentToken:
    sscComponentToken
  of dsnClassDefinition:
    sscSharedClass
  of dsnSemanticToken:
    sscSemanticToken
  of dsnFoundation:
    sscGlobalPrimitiveToken

func layerKindForProperty(prop: PropertyInfo;
    node: DesignSchemaNode = DesignSchemaNode()): StyleCascadeLayerKind =
  if node.key.len > 0:
    case node.kind
    of dsnStoryFixture:
      return sclStoryFixture
    of dsnComponentVariant, dsnComponentState, dsnDensityMode,
        dsnResponsiveMode, dsnStyleDefinition:
      return sclComponentSchema
    of dsnComponentToken:
      return sclComponentToken
    of dsnClassDefinition:
      return sclSharedClass
    of dsnSemanticToken:
      return sclSemanticToken
    of dsnFoundation:
      return sclGlobalPrimitiveToken
  case prop.origin
  of poTailwindClass:
    sclSharedClass
  of poSetStyle:
    sclLocalOverride
  of poThemeToken:
    sclSemanticToken
  of poConstant:
    if prop.sharedCount > 0: sclComponentSchema else: sclLocalOverride
  of poInherited:
    sclInheritedValue

func colorEquals(a, b: string): bool =
  a.strip().toLowerAscii() == b.strip().toLowerAscii()

func literalTokenCandidate(prop: PropertyInfo): bool =
  let value = prop.value.strip()
  if value.startsWith("token(") or value.startsWith("var("):
    return false
  let category = cssPropertyCategory(prop.name)
  if category == cpcColor:
    return value.startsWith("#") or value.startsWith("rgb(") or
      value.startsWith("hsl(")
  category in {cpcSpacing, cpcSize, cpcBorder, cpcTypography} and
    parseCssPropertyValue(prop.name, value).kind in {cvkLength, cvkPercentage}

func matchesTokenValue(prop: PropertyInfo; node: DesignSchemaNode): bool =
  node.value.len > 0 and prop.value.colorEquals(node.value) and
    cssPropertyCategory(prop.name) == cssPropertyCategory(node.property)

proc tokenChain*(editor: EditorVM; tokenOrValue: string): seq[string] =
  var current = tokenNameFromRaw(tokenOrValue)
  if current.len == 0:
    current = tokenOrValue
  if current.len == 0:
    return @[]
  var seen: seq[string] = @[]
  while current.len > 0 and current.toLowerAscii() notin seen:
    result.add current
    seen.add current.toLowerAscii()
    var next = ""
    for token in editor.foundations.tokens.val:
      if token.key.sameTokenKey(current):
        if token.aliasOf.len > 0:
          next = token.aliasOf
        else:
          next = tokenNameFromRaw(token.value)
        break
    if next.len == 0:
      for node in editor.designSystemSchema.val.nodes:
        if node.key.sameTokenKey(current):
          next = tokenNameFromRaw(node.value)
          break
    current = next

func classEntryFromNode(node: DesignSchemaNode): StyleClassEntry =
  StyleClassEntry(
    className: node.classNameFromNode(),
    properties: @[PropertyInfo(name: node.property, value: node.value,
      origin: poConstant, originDetail: "class:" & node.classNameFromNode(),
      sourceFile: node.sourceSpan.file, sourceLine: node.sourceSpan.line,
      sharedCount: node.usageCount, schemaKey: node.key)],
    sourceFile: node.sourceSpan.file,
    sourceLine: node.sourceSpan.line,
    schemaKey: node.key,
    sharedCount: node.usageCount,
    editable: node.sourceSpan.hasSource)

proc reusableStyleClasses*(editor: EditorVM; query = ""): seq[StyleClassEntry] =
  let needle = query.toLowerAscii().strip()
  for node in editor.designSystemSchema.val.nodes:
    if node.kind != dsnClassDefinition:
      continue
    let entry = node.classEntryFromNode()
    if needle.len == 0 or needle in entry.className.toLowerAscii() or
        needle in node.property.toLowerAscii() or needle in node.value.toLowerAscii():
      result.add entry

proc selectedStyleProperty(editor: EditorVM; property: string): PropertyInfo =
  let element = editor.inspector.selectedElement.val
  for prop in element.properties:
    if prop.name == property:
      return prop
  if property.len == 0 and element.properties.len > 0:
    return element.properties[0]
  PropertyInfo(name: property, value: "", origin: poInherited,
    originDetail: "generated-fallback", sourceFile: element.sourceFile,
    sourceLine: element.sourceLine, schemaKey: element.schemaKey,
    directStyleAllowed: true)

proc styleScopeChoices*(editor: EditorVM; prop: PropertyInfo): seq[
    StyleScopeChoice] =
  let schema = editor.designSystemSchema.val
  proc makeChoice(kind: StyleScopeChoiceKind; file = ""; line = 0;
      schemaKey = ""; editable = false; reason = ""): StyleScopeChoice =
    StyleScopeChoice(kind: kind, label: kind.styleScopeChoiceLabel(),
      sourceFile: file, sourceLine: line, schemaKey: schemaKey,
      editable: editable, impact: editor.designSchemaImpact(schemaKey),
      reason: reason)

  let element = editor.inspector.selectedElement.val
  result.add makeChoice(sscLocalInstance, element.sourceFile,
    element.sourceLine, element.schemaKey,
    element.sourceFile.len > 0 or prop.directStyleAllowed,
    "Edits only the selected rendered element.")

  for kind in [sscStoryFixture, sscComponentSchema, sscComponentToken,
      sscSharedClass, sscSemanticToken, sscGlobalPrimitiveToken]:
    var best = DesignSchemaNode()
    for node in schema.nodes:
      if node.property != prop.name:
        continue
      if node.kind.schemaScopeForNode() == kind:
        best = node
        break
    if best.key.len > 0:
      result.add makeChoice(kind, best.sourceSpan.file, best.sourceSpan.line, best.key,
        best.sourceSpan.hasSource, "Source-backed " & kind.styleScopeChoiceLabel().toLowerAscii())
    else:
      result.add makeChoice(kind, "", 0, "", false,
        "No project schema owner is currently mapped for this scope.")

proc styleCascadeLayers*(editor: EditorVM; prop: PropertyInfo): seq[
    StyleCascadeLayer] =
  let element = editor.inspector.selectedElement.val
  let tokenChain =
    if prop.tokenName.len > 0: editor.tokenChain(prop.tokenName)
    else: editor.tokenChain(prop.value)
  let inherited =
    if prop.origin == poInherited: prop.value else: ""
  result.add StyleCascadeLayer(kind: sclFinalValue, property: prop.name,
    value: prop.value, finalValue: prop.value, inheritedValue: inherited,
    tokenChain: tokenChain, sourceFile: prop.sourceFile,
    sourceLine: prop.sourceLine, schemaKey: prop.schemaKey,
    editable: false, editScope: sscLocalInstance)

  let ownership = editor.resolveDesignSourceOwnership(prop.name)
  if ownership.ok:
    result.add StyleCascadeLayer(
      kind: prop.layerKindForProperty(ownership.schemaNode),
      property: prop.name,
      value: if ownership.schemaNode.value.len > 0: ownership.schemaNode.value else: prop.value,
      finalValue: prop.value,
      inheritedValue: inherited,
      overridden: ownership.schemaNode.value.len > 0 and
        ownership.schemaNode.value != prop.value,
      tokenChain: tokenChain,
      className: ownership.ownership.cssModuleClass,
      sourceFile: ownership.ownership.sourceSpan.file,
      sourceLine: ownership.ownership.sourceSpan.line,
      schemaKey: ownership.nodeKey,
      editable: ownership.ownership.sourceSpan.hasSource,
      editScope: ownership.schemaNode.kind.schemaScopeForNode())
  else:
    result.add StyleCascadeLayer(kind: prop.layerKindForProperty(),
      property: prop.name, value: prop.value, finalValue: prop.value,
      inheritedValue: inherited, tokenChain: tokenChain,
      className: prop.originDetail.classNameFromOriginDetail(),
      sourceFile: prop.sourceFile, sourceLine: prop.sourceLine,
      schemaKey: prop.schemaKey, editable: prop.hasSource or prop.directStyleAllowed,
      editScope: if prop.sharedCount > 0: sscSharedClass else: sscLocalInstance)

  for candidate in element.properties:
    if candidate.name == prop.name and candidate.origin == poInherited and
        candidate.value != prop.value:
      result.add StyleCascadeLayer(kind: sclInheritedValue,
        property: prop.name, value: candidate.value, finalValue: prop.value,
        inheritedValue: candidate.value, overridden: true,
        sourceFile: candidate.sourceFile, sourceLine: candidate.sourceLine,
        schemaKey: candidate.schemaKey, editable: false,
        editScope: sscLocalInstance)

  if result.len == 1:
    result.add StyleCascadeLayer(kind: sclGeneratedFallback,
      property: prop.name, value: prop.value, finalValue: prop.value,
      inheritedValue: inherited, overridden: false,
      sourceFile: prop.sourceFile, sourceLine: prop.sourceLine,
      schemaKey: prop.schemaKey, editable: prop.directStyleAllowed,
      editScope: sscLocalInstance)

proc tokenManagerItems*(editor: EditorVM; query = ""): seq[TokenManagerItem] =
  let needle = query.toLowerAscii().strip()
  for token in editor.foundations.tokens.val:
    if needle.len > 0 and needle notin token.key.toLowerAscii() and
        needle notin token.value.toLowerAscii():
      continue
    var schemaNode = DesignSchemaNode()
    for node in editor.designSystemSchema.val.nodes:
      if node.key.sameTokenKey(token.key):
        schemaNode = node
        break
    let schemaKey =
      if token.schemaKey.len > 0: token.schemaKey
      elif schemaNode.key.len > 0: schemaNode.key
      else: token.key
    let sourceFile =
      if token.sourceFile.len > 0: token.sourceFile else: schemaNode.sourceSpan.file
    let sourceLine =
      if token.sourceLine > 0: token.sourceLine else: schemaNode.sourceSpan.line
    var mergedToken = token
    if mergedToken.foreground.len == 0:
      mergedToken.foreground = schemaNode.foreground
    if mergedToken.background.len == 0:
      mergedToken.background = schemaNode.background
    if mergedToken.minContrast <= 0:
      mergedToken.minContrast = schemaNode.minContrast
    var item = TokenManagerItem(key: token.key, value: token.value,
      aliasOf: token.aliasOf, kind: token.kind, modes: schemaNode.modeValues,
      sourceFile: sourceFile, sourceLine: sourceLine, schemaKey: schemaKey,
      editable: sourceFile.len > 0 and schemaKey.len > 0,
      dependentStories: token.affectedStories,
      impact: editor.designSchemaImpact(schemaKey))
    for story in schemaNode.stories:
      item.dependentStories.addStoryOnce story
    item.contrastRatio = contrastRatio(
      if mergedToken.foreground.len > 0: mergedToken.foreground else: token.value,
      mergedToken.background)
    item.minContrast = mergedToken.minContrast
    for prop in editor.inspector.selectedElement.val.properties:
      if prop.tokenName.sameTokenKey(token.key) or
          prop.value.tokenNameFromRaw.sameTokenKey(token.key):
        item.usages.add prop
    item.diagnostics = editor.validateFoundationTokenEdit(mergedToken, token.value)
    result.add item

  for node in editor.designSystemSchema.val.nodes:
    if node.kind notin {dsnFoundation, dsnSemanticToken, dsnComponentToken}:
      continue
    if editor.foundations.tokens.val.anyIt(it.key.sameTokenKey(node.key)):
      continue
    if needle.len > 0 and needle notin node.key.toLowerAscii() and
        needle notin node.value.toLowerAscii():
      continue
    var item = TokenManagerItem(key: node.key, value: node.value,
      aliasOf: tokenNameFromRaw(node.value), kind: node.tokenKindForNode(),
      modes: node.modeValues, impact: editor.designSchemaImpact(node.key),
      contrastRatio: contrastRatio(node.foreground, node.background),
      minContrast: node.minContrast, dependentStories: node.stories,
      sourceFile: node.sourceSpan.file, sourceLine: node.sourceSpan.line,
      schemaKey: node.key, editable: node.sourceSpan.hasSource)
    if item.impact.diagnostics.anyIt(it.kind == dsdContrastImpact):
      item.diagnostics.add FoundationEditDiagnostic(
        kind: fedContrastViolation,
        message: "Token contrast ratio is below the required threshold.",
        key: node.key,
        file: node.sourceSpan.file,
        line: node.sourceSpan.line)
    result.add item

func stylePlan(operation: StyleClassOperationKind; file: string; line: int;
    property = ""; oldValue = ""; newValue = ""; originDetail = "";
    schemaKey = ""; tokenName = "";
    planKind = cspStructuredSchemaUpdate): SourceEditPlan =
  SourceEditPlan(
    file: file,
    line: line,
    property: property,
    oldValue: oldValue,
    newValue: newValue,
    originDetail: originDetail,
    scope: if operation in {scokPromoteLocalOverride, scokTokenizeValue}: pesShared else: pesLocal,
    planKind: planKind,
    schemaKey: schemaKey,
    tokenName: tokenName,
    reversible: true,
    previewBefore: originDetail & " " & property & ": " & oldValue,
    previewAfter: originDetail & " " & property & ": " & newValue,
    formatterHook: "format-style-manager",
    regeneratorHook:
      if planKind in {cspStructuredSchemaUpdate, cspTokenUpdate}:
        "regenerate-design-system"
      else:
        "",
    conflictKey: file & ":" & $line & ":" & property & ":" & $operation,
    expectedOldValue: oldValue)

proc styleDiagnostics*(editor: EditorVM; prop: PropertyInfo): seq[
    StyleDiagnostic] =
  let schema = editor.designSystemSchema.val
  for node in schema.nodes:
    if node.kind in {dsnFoundation, dsnSemanticToken, dsnComponentToken} and
        prop.literalTokenCandidate() and prop.matchesTokenValue(node):
      let plan = stylePlan(scokTokenizeValue, prop.sourceFile, prop.sourceLine,
        prop.name, prop.value, "token(" & node.key & ")",
        "style-tokenize:" & node.key, node.key, node.key, cspTokenUpdate)
      result.add StyleDiagnostic(kind: sdkHardcodedColorMatchingToken,
        message: "Hardcoded value matches token " & node.key & ".",
        property: prop.name, value: prop.value, tokenKey: node.key,
        file: prop.sourceFile, line: prop.sourceLine, sourceBackedFix: plan)
      if prop.sharedCount == 0:
        result.add StyleDiagnostic(kind: sdkOneOffValueShouldBeToken,
          message: "One-off value should be promoted to a reusable token.",
          property: prop.name, value: prop.value, tokenKey: node.key,
          file: prop.sourceFile, line: prop.sourceLine, sourceBackedFix: plan)

  var classNames: seq[string] = @[]
  for node in schema.nodes:
    if node.kind == dsnClassDefinition:
      let className = node.classNameFromNode().toLowerAscii()
      if className in classNames:
        result.add StyleDiagnostic(kind: sdkDuplicateClass,
          message: "Duplicate class definition for " & node.classNameFromNode() & ".",
          property: node.property, value: node.value,
          className: node.classNameFromNode(), file: node.sourceSpan.file,
          line: node.sourceSpan.line,
          sourceBackedFix: stylePlan(scokRenameClass, node.sourceSpan.file,
            node.sourceSpan.line, "class", node.classNameFromNode(),
            node.classNameFromNode() & "-copy", "style-class:rename",
            node.key))
      else:
        classNames.add className

  if prop.sharedCount > 1 or prop.origin == poTailwindClass:
    result.add StyleDiagnostic(kind: sdkUnsafeDetachment,
      message: "Detaching this class affects shared style ownership; use a source-backed local override.",
      property: prop.name, value: prop.value,
      className: prop.originDetail.classNameFromOriginDetail(),
      file: prop.sourceFile, line: prop.sourceLine,
      sourceBackedFix: stylePlan(scokDetachClass, prop.sourceFile,
        prop.sourceLine, prop.name, prop.value, prop.value,
        "style-class:detach", prop.schemaKey, planKind = cspInlineStyleUpdate))

proc styleManagerSnapshot*(editor: EditorVM; property: string;
    search = ""): StyleManagerSnapshot =
  let prop = editor.selectedStyleProperty(property)
  result.property = prop.name
  result.finalValue = prop.value
  result.inheritedValue = if prop.origin == poInherited: prop.value else: ""
  result.reusableStyles = editor.reusableStyleClasses(search)
  result.cascadeLayers = editor.styleCascadeLayers(prop)
  result.scopeChoices = editor.styleScopeChoices(prop)
  result.tokenItems = editor.tokenManagerItems(search)
  result.diagnostics = editor.styleDiagnostics(prop)

  let currentClass = prop.originDetail.classNameFromOriginDetail()
  if currentClass.len > 0:
    result.currentClassStack.add StyleClassEntry(className: currentClass,
      properties: @[prop], sourceFile: prop.sourceFile,
      sourceLine: prop.sourceLine, schemaKey: prop.schemaKey,
      sharedCount: prop.sharedCount, editable: prop.hasSource)
  for layer in result.cascadeLayers:
    if layer.className.len > 0 and
        not result.currentClassStack.anyIt(it.className == layer.className):
      result.currentClassStack.add StyleClassEntry(className: layer.className,
        sourceFile: layer.sourceFile, sourceLine: layer.sourceLine,
        schemaKey: layer.schemaKey, sharedCount: prop.sharedCount,
        editable: layer.editable)

proc stageStyleOperation(editor: EditorVM; operation: StyleClassOperationKind;
    classEntry: StyleClassEntry; plan: SourceEditPlan): StyleOperationResult =
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  StyleOperationResult(status: pesAccepted, operation: operation,
    classEntry: classEntry, sourceEdit: plan)

proc createStyleClass*(editor: EditorVM; className, property,
    value: string): StyleOperationResult {.discardable.} =
  let element = editor.inspector.selectedElement.val
  let file = if element.sourceFile.len > 0: element.sourceFile else: "style-manager.css"
  let line = if element.sourceLine > 0: element.sourceLine else: 1
  let schemaKey = "classes." & className
  let entry = StyleClassEntry(className: className,
    properties: @[PropertyInfo(name: property, value: value,
      origin: poConstant, originDetail: "class:" & className,
      sourceFile: file, sourceLine: line, schemaKey: schemaKey)],
    sourceFile: file, sourceLine: line, schemaKey: schemaKey,
    sharedCount: 1, editable: true)
  let plan = stylePlan(scokCreateClass, file, line, property,
    "/* style-manager:" & className & " */",
    "." & className & " { " & property & ": " & value & "; }",
    "style-class:create:" & className, schemaKey)
  editor.stageStyleOperation(scokCreateClass, entry, plan)

proc renameStyleClass*(editor: EditorVM; oldClassName,
    newClassName: string): StyleOperationResult {.discardable.} =
  var entry = StyleClassEntry(className: oldClassName)
  for candidate in editor.reusableStyleClasses():
    if candidate.className == oldClassName:
      entry = candidate
      break
  if entry.sourceFile.len == 0:
    entry.sourceFile = editor.inspector.selectedElement.val.sourceFile
    entry.sourceLine = editor.inspector.selectedElement.val.sourceLine
    entry.schemaKey = "classes." & oldClassName
  let plan = stylePlan(scokRenameClass, entry.sourceFile, max(1, entry.sourceLine),
    "class", oldClassName, newClassName, "style-class:rename",
    entry.schemaKey)
  entry.className = newClassName
  editor.stageStyleOperation(scokRenameClass, entry, plan)

proc duplicateStyleClass*(editor: EditorVM; className,
    newClassName: string): StyleOperationResult {.discardable.} =
  var entry = StyleClassEntry(className: className)
  for candidate in editor.reusableStyleClasses():
    if candidate.className == className:
      entry = candidate
      break
  if entry.sourceFile.len == 0:
    entry.sourceFile = editor.inspector.selectedElement.val.sourceFile
    entry.sourceLine = editor.inspector.selectedElement.val.sourceLine
    entry.schemaKey = "classes." & className
  let oldText = "." & className
  let newText = "." & className & "\n." & newClassName
  let plan = stylePlan(scokDuplicateClass, entry.sourceFile,
    max(1, entry.sourceLine), "class", oldText, newText,
    "style-class:duplicate", "classes." & newClassName)
  entry.className = newClassName
  entry.schemaKey = "classes." & newClassName
  editor.stageStyleOperation(scokDuplicateClass, entry, plan)

proc detachStyleClass*(editor: EditorVM; property: string): StyleOperationResult {.discardable.} =
  let prop = editor.selectedStyleProperty(property)
  let className = prop.originDetail.classNameFromOriginDetail()
  let entry = StyleClassEntry(className: className, properties: @[prop],
    sourceFile: prop.sourceFile, sourceLine: prop.sourceLine,
    schemaKey: prop.schemaKey, sharedCount: prop.sharedCount,
    editable: prop.hasSource or prop.directStyleAllowed)
  let plan = stylePlan(scokDetachClass, prop.sourceFile, prop.sourceLine,
    prop.name, prop.value, prop.value, "style-class:detach:" & className,
    prop.schemaKey, planKind = cspInlineStyleUpdate)
  editor.stageStyleOperation(scokDetachClass, entry, plan)

proc promoteLocalOverride*(editor: EditorVM; property: string;
    scope: StyleScopeChoiceKind; targetKey = ""): StyleOperationResult {.discardable.} =
  let prop = editor.selectedStyleProperty(property)
  let key =
    if targetKey.len > 0: targetKey
    elif prop.schemaKey.len > 0: prop.schemaKey
    else:
      case scope
      of sscSharedClass: "classes." & prop.name
      of sscSemanticToken: "semantic." & prop.name
      of sscGlobalPrimitiveToken: "primitive." & prop.name
      of sscComponentToken: "component." & prop.name
      of sscStoryFixture: "fixture." & prop.name
      of sscComponentSchema: "schema." & prop.name
      of sscLocalInstance: "local." & prop.name
  let planKind =
    if scope in {sscComponentToken, sscSemanticToken, sscGlobalPrimitiveToken}:
      cspTokenUpdate
    elif scope == sscSharedClass:
      cspStructuredSchemaUpdate
    else:
      cspStructuredSchemaUpdate
  let plan = stylePlan(scokPromoteLocalOverride, prop.sourceFile,
    prop.sourceLine, prop.name, prop.value, prop.value,
    "style-promote:" & scope.styleScopeChoiceLabel(), key,
    if planKind == cspTokenUpdate: key else: "", planKind)
  editor.stageStyleOperation(scokPromoteLocalOverride,
    StyleClassEntry(className: prop.originDetail.classNameFromOriginDetail(),
      properties: @[prop], sourceFile: prop.sourceFile,
      sourceLine: prop.sourceLine, schemaKey: key, editable: true),
    plan)

proc tokenizeStyleValue*(editor: EditorVM; property,
    tokenKey: string): StyleOperationResult {.discardable.} =
  let prop = editor.selectedStyleProperty(property)
  let newValue = "token(" & tokenKey & ")"
  let plan = stylePlan(scokTokenizeValue, prop.sourceFile, prop.sourceLine,
    prop.name, prop.value, newValue, "style-tokenize:" & tokenKey,
    tokenKey, tokenKey, cspTokenUpdate)
  editor.stageStyleOperation(scokTokenizeValue,
    StyleClassEntry(properties: @[prop], sourceFile: prop.sourceFile,
      sourceLine: prop.sourceLine, schemaKey: tokenKey, editable: true),
    plan)

proc foundationDiagnostic(kind: FoundationEditDiagnosticKind;
    token: FoundationTokenEntry; message: string): FoundationEditDiagnostic =
  FoundationEditDiagnostic(
    kind: kind,
    message: message,
    key: token.key,
    file: token.sourceFile,
    line: token.sourceLine)

func sourcePlan(token: FoundationTokenEntry; newValue: string): SourceEditPlan =
  SourceEditPlan(
    file: token.sourceFile,
    line: token.sourceLine,
    property: token.property,
    oldValue: token.value,
    newValue: newValue.strip(),
    originDetail: "schema:" & token.schemaKey,
    scope: pesShared,
    planKind: cspTokenUpdate,
    schemaKey: token.schemaKey,
    tokenName: token.key,
    reversible: true,
    previewBefore: token.property & ": " & token.value,
    previewAfter: token.property & ": " & newValue.strip(),
    formatterHook: "format-foundation-token",
    regeneratorHook: "regenerate-design-system",
    conflictKey: token.sourceFile & ":" & $token.sourceLine & ":" & token.property,
    expectedOldValue: token.value)

func foundationTokenKindLabel*(kind: FoundationTokenKind): string =
  case kind
  of ftkColorPalette: "Color"
  of ftkSemanticColor: "Semantic aliases"
  of ftkTypographyScale: "Typography"
  of ftkSpacingScale: "Spacing"
  of ftkRadiusScale: "Radius"
  of ftkShadow: "Shadow"
  of ftkMotion: "Motion"
  of ftkBreakpoint: "Breakpoints"
  of ftkDensity: "Density"
  of ftkAccessibilityConstraint: "Accessibility"

func foundationTokenKindSlug*(kind: FoundationTokenKind): string =
  case kind
  of ftkColorPalette: "color"
  of ftkSemanticColor: "semantic"
  of ftkTypographyScale: "typography"
  of ftkSpacingScale: "spacing"
  of ftkRadiusScale: "radius"
  of ftkShadow: "shadow"
  of ftkMotion: "motion"
  of ftkBreakpoint: "breakpoint"
  of ftkDensity: "density"
  of ftkAccessibilityConstraint: "accessibility"

func allFoundationTokenKinds*(): seq[FoundationTokenKind] =
  @[
    ftkColorPalette,
    ftkSemanticColor,
    ftkTypographyScale,
    ftkSpacingScale,
    ftkRadiusScale,
    ftkShadow,
    ftkMotion,
    ftkBreakpoint,
    ftkDensity,
    ftkAccessibilityConstraint
  ]

func isTokenAliasValue(value: string): bool =
  value.startsWith("token(") or value.startsWith("$")

func validCssLength(value: string): bool =
  let normalized = value.strip().toLowerAscii()
  if normalized == "0":
    return true
  for suffix in ["px", "rem", "em", "%", "vh", "vw"]:
    if normalized.endsWith(suffix):
      let number = normalized[0 ..< normalized.len - suffix.len]
      try:
        discard parseFloat(number)
        return true
      except ValueError:
        return false
  false

func tokenMatchesSearch(token: FoundationTokenEntry; query: string): bool =
  if query.len == 0:
    return true
  let q = query.toLowerAscii()
  q in token.key.toLowerAscii() or q in token.value.toLowerAscii() or
    q in token.aliasOf.toLowerAscii() or q in token.property.toLowerAscii() or
    q in token.schemaKey.toLowerAscii()

proc aliasTarget(tokens: seq[FoundationTokenEntry]; key: string): string =
  for token in tokens:
    if token.key.sameTokenKey(key):
      if token.aliasOf.len > 0:
        return token.aliasOf
      return token.value
  ""

proc hasAliasCycle(tokens: seq[FoundationTokenEntry]; startKey,
    newAlias: string): bool =
  var seen: seq[string] = @[startKey.toLowerAscii()]
  var current = newAlias
  while current.len > 0:
    let lowered = current.toLowerAscii()
    if lowered in seen:
      return true
    seen.add lowered
    current = tokens.aliasTarget(current)

proc foundationImpact*(editor: EditorVM; tokenKey: string): FoundationTokenImpact =
  result.tokenKey = tokenKey
  for prop in editor.inspector.selectedElement.val.properties:
    if prop.tokenName.sameTokenKey(tokenKey) or
        prop.value.tokenNameFromRaw.sameTokenKey(tokenKey):
      result.affectedProperties.add prop
  for token in editor.foundations.tokens.val:
    if token.key.sameTokenKey(tokenKey):
      for story in token.affectedStories:
        result.affectedStories.addStoryOnce story
  result.message = $result.affectedProperties.len & " properties and " &
    $result.affectedStories.len & " stories depend on " & tokenKey & "."

proc validateFoundationTokenEdit(editor: EditorVM; token: FoundationTokenEntry;
    newValue: string): seq[FoundationEditDiagnostic] =
  let value = newValue.strip()
  if token.schemaKey.len == 0 or token.sourceFile.len == 0:
    result.add foundationDiagnostic(fedMissingTokenSchema, token,
      "Foundation token edits require a project schema entry.")
  if value.len == 0:
    result.add foundationDiagnostic(fedInvalidTokenValue, token,
      "Foundation token values cannot be blank.")
  if token.kind in {ftkColorPalette, ftkSemanticColor}:
    let parsed = hexColorChannels(value)
    let aliasLike = value.isTokenAliasValue
    if not parsed.ok and not aliasLike:
      result.add foundationDiagnostic(fedInvalidTokenValue, token,
        "Color tokens must use a hex color or token alias.")
  if token.kind == ftkSemanticColor and
      value.isTokenAliasValue:
    let target = tokenNameFromRaw(value)
    if editor.foundations.tokens.val.hasAliasCycle(token.key, target):
      result.add foundationDiagnostic(fedAliasCycle, token,
        "Semantic token aliases cannot form a cycle.")
  if token.kind in {ftkSpacingScale, ftkRadiusScale, ftkBreakpoint} and
      not value.validCssLength and not value.isTokenAliasValue:
    result.add foundationDiagnostic(fedInvalidTokenValue, token,
      foundationTokenKindLabel(token.kind) &
      " tokens must use a CSS length or token alias.")
  if token.kind == ftkTypographyScale and not value.validCssLength and
      not value.isTokenAliasValue and "font" notin token.property.toLowerAscii():
    result.add foundationDiagnostic(fedInvalidTokenValue, token,
      "Typography size tokens must use a CSS length or token alias.")
  if token.kind == ftkShadow and not value.isTokenAliasValue and
      (not value.contains(" ") or not value.contains("#")):
    result.add foundationDiagnostic(fedInvalidTokenValue, token,
      "Shadow tokens must include offsets and a color or use a token alias.")
  if token.kind == ftkMotion and not value.isTokenAliasValue:
    let lowered = value.toLowerAscii()
    if not (lowered.endsWith("ms") or lowered.endsWith("s") or
        "ease" in lowered or "cubic-bezier" in lowered):
      result.add foundationDiagnostic(fedInvalidTokenValue, token,
        "Motion tokens must use a duration or timing-function value.")
  if token.minContrast > 0:
    let foreground =
      if token.kind == ftkAccessibilityConstraint: value
      elif token.foreground.len > 0: token.foreground
      else: value
    let ratio = contrastRatio(foreground, token.background)
    if ratio > 0 and ratio < token.minContrast:
      result.add foundationDiagnostic(fedContrastViolation, token,
        "Token contrast ratio " & $ratio & " is below " & $token.minContrast & ".")

proc setFoundationCategory*(editor: EditorVM;
    kind: FoundationTokenKind): bool {.discardable.} =
  editor.foundations.selectedCategory.val = kind
  for token in editor.foundations.tokens.val:
    if token.kind == kind and token.tokenMatchesSearch(
        editor.foundations.searchFilter.val):
      editor.foundations.selectedTokenKey.val = token.key
      return true
  editor.foundations.selectedTokenKey.val = ""
  false

proc setFoundationSearch*(editor: EditorVM; query: string) =
  editor.foundations.searchFilter.val = query
  let current = editor.foundations.selectedTokenKey.val
  for token in editor.foundations.tokens.val:
    if token.kind == editor.foundations.selectedCategory.val and
        token.tokenMatchesSearch(query):
      if token.key.sameTokenKey(current):
        return
  discard editor.setFoundationCategory(editor.foundations.selectedCategory.val)

proc selectFoundationToken*(editor: EditorVM; key: string): bool {.discardable.} =
  for token in editor.foundations.tokens.val:
    if token.key.sameTokenKey(key):
      editor.foundations.selectedCategory.val = token.kind
      editor.foundations.selectedTokenKey.val = token.key
      return true
  false

proc removePendingFoundationEdit(editor: EditorVM; edit: SourceEditPlan) =
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = @[]
    for plan in prev:
      if plan.conflictKey != edit.conflictKey:
        result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = @[]
    for preview in prev:
      if preview.plan.conflictKey != edit.conflictKey:
        result.add preview
  editor.workspaceEditStage.val =
    if editor.inspector.pendingSourceEdits.val.len == 0: wesClean else: wesDirty

proc undoFoundationTokenEdit*(editor: EditorVM): bool {.discardable.} =
  let stack = editor.foundations.undoStack.val
  if stack.len == 0:
    return false
  let entry = stack[^1]
  var updated = editor.foundations.tokens.val
  for i, token in updated:
    if token.key.sameTokenKey(entry.key):
      updated[i] = entry.beforeToken
      break
  editor.foundations.tokens.val = updated
  editor.foundations.selectedTokenKey.val = entry.key
  editor.foundations.undoStack.val = stack[0 ..< stack.len - 1]
  editor.foundations.redoStack.update proc(prev: seq[FoundationEditHistoryEntry]): seq[
      FoundationEditHistoryEntry] =
    result = prev
    result.add entry
  editor.removePendingFoundationEdit(entry.sourceEdit)
  true

proc redoFoundationTokenEdit*(editor: EditorVM): bool {.discardable.} =
  let stack = editor.foundations.redoStack.val
  if stack.len == 0:
    return false
  let entry = stack[^1]
  var updated = editor.foundations.tokens.val
  for i, token in updated:
    if token.key.sameTokenKey(entry.key):
      updated[i] = entry.afterToken
      break
  editor.foundations.tokens.val = updated
  editor.foundations.selectedTokenKey.val = entry.key
  editor.foundations.redoStack.val = stack[0 ..< stack.len - 1]
  editor.foundations.undoStack.update proc(prev: seq[FoundationEditHistoryEntry]): seq[
      FoundationEditHistoryEntry] =
    result = prev
    result.add entry
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add entry.sourceEdit
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: entry.sourceEdit,
      beforeText: entry.sourceEdit.previewBefore,
      afterText: entry.sourceEdit.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  true

proc editFoundationToken*(editor: EditorVM; key, newValue: string): FoundationEditResult {.discardable.} =
  var tokenIndex = -1
  var token = FoundationTokenEntry()
  for i, candidate in editor.foundations.tokens.val:
    if candidate.key.sameTokenKey(key):
      tokenIndex = i
      token = candidate
      break
  if tokenIndex < 0:
    let diagnostic = FoundationEditDiagnostic(
      kind: fedMissingTokenSchema,
      message: "Unknown foundation token '" & key & "'.",
      key: key)
    editor.foundations.diagnostics.val = @[diagnostic]
    return FoundationEditResult(status: pesRejected,
      diagnostics: @[diagnostic])

  let diagnostics = editor.validateFoundationTokenEdit(token, newValue)
  if diagnostics.len > 0:
    editor.foundations.diagnostics.val = diagnostics
    return FoundationEditResult(status: pesRejected, diagnostics: diagnostics)

  let plan = token.sourcePlan(newValue)
  var updatedTokens = editor.foundations.tokens.val
  updatedTokens[tokenIndex].value = newValue.strip()
  if newValue.strip().isTokenAliasValue:
    updatedTokens[tokenIndex].aliasOf = tokenNameFromRaw(newValue)
  else:
    updatedTokens[tokenIndex].aliasOf = ""
  let afterToken = updatedTokens[tokenIndex]
  editor.foundations.tokens.val = updatedTokens

  let impact = editor.foundationImpact(key)
  editor.foundations.impacts.val = @[impact]
  editor.foundations.diagnostics.val = @[]
  editor.foundations.selectedCategory.val = afterToken.kind
  editor.foundations.selectedTokenKey.val = afterToken.key
  editor.foundations.undoStack.update proc(prev: seq[FoundationEditHistoryEntry]): seq[
      FoundationEditHistoryEntry] =
    result = prev
    result.add FoundationEditHistoryEntry(
      key: token.key,
      beforeToken: token,
      afterToken: afterToken,
      sourceEdit: plan)
  editor.foundations.redoStack.val = @[]
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  FoundationEditResult(status: pesAccepted, sourceEdit: plan, impacts: @[impact])

proc variantDiagnostic(kind: ComponentVariantDiagnosticKind;
    variant: ComponentVariantDefinition; field: ComponentVariantField;
    message: string): ComponentVariantDiagnostic =
  ComponentVariantDiagnostic(
    kind: kind,
    message: message,
    component: variant.component,
    variantKey: variant.variantKey,
    field: field.name,
    file: field.sourceFile,
    line: field.sourceLine)

func componentPropertyKindLabel*(kind: ComponentPropertyKind): string =
  case kind
  of cpkEnum: "enum"
  of cpkBoolean: "boolean"
  of cpkText: "text"
  of cpkIcon: "icon"
  of cpkSlotContent: "slot/content"
  of cpkDataFixture: "data fixture"
  of cpkDensity: "density"
  of cpkPlatform: "platform"
  of cpkAccessibilityLabel: "accessibility label"

func componentStateKindLabel*(kind: ComponentStateKind): string =
  case kind
  of cskSize: "size"
  of cskEmphasis: "emphasis"
  of cskTone: "tone"
  of cskSelected: "selected"
  of cskDisabled: "disabled"
  of cskHover: "hover"
  of cskFocus: "focus"
  of cskPressed: "pressed"
  of cskLoading: "loading"
  of cskEmpty: "empty"
  of cskError: "error"
  of cskSuccess: "success"
  of cskProjectSpecific: "project-specific"

func requiredComponentStateKinds*(): seq[ComponentStateKind] =
  @[
    cskSize,
    cskEmphasis,
    cskTone,
    cskSelected,
    cskDisabled,
    cskHover,
    cskFocus,
    cskPressed,
    cskLoading,
    cskEmpty,
    cskError,
    cskSuccess
  ]

func requiredComponentStateKeys*(): seq[string] =
  for kind in requiredComponentStateKinds():
    result.add componentStateKindLabel(kind)

proc componentVariantsForComponent*(editor: EditorVM;
    component: string): seq[ComponentVariantDefinition] =
  for variant in editor.variants.variants.val:
    if variant.component == component:
      result.add variant

func stateCommand(component, variantKey, stateKey: string): string =
  "create-story:" & component & ":" & variantKey & ":" & stateKey

func stateCoverageDiagnostics*(variants: seq[ComponentVariantDefinition];
    component: string): seq[ComponentStateCoverageDiagnostic] =
  var coveredKeys: seq[string] = @[]
  var seen: seq[string] = @[]
  for variant in variants:
    if variant.component != component:
      continue
    for state in variant.stateControls:
      let identity = variant.variantKey & ":" & state.key
      if identity in seen:
        result.add ComponentStateCoverageDiagnostic(
          kind: cscdDuplicateState,
          message: "State '" & state.key & "' is declared more than once for " &
            variant.variantKey & ".",
          component: component,
          variantKey: variant.variantKey,
          stateKey: state.key,
          suggestion: "Keep one canonical state control and move examples into stories.",
          command: stateCommand(component, variant.variantKey, state.key),
          file: state.sourceFile,
          line: state.sourceLine)
      else:
        seen.add identity
      if state.key notin coveredKeys:
        coveredKeys.add state.key
      if state.value.strip.len == 0:
        result.add ComponentStateCoverageDiagnostic(
          kind: cscdInvalidStateValue,
          message: "State '" & state.key & "' has no value.",
          component: component,
          variantKey: variant.variantKey,
          stateKey: state.key,
          suggestion: "Set an explicit schema value before generating a preview.",
          command: stateCommand(component, variant.variantKey, state.key),
          file: state.sourceFile,
          line: state.sourceLine)
      if state.fixtureName.len == 0:
        result.add ComponentStateCoverageDiagnostic(
          kind: cscdMissingFixture,
          message: "State '" & state.key & "' is missing a story fixture.",
          component: component,
          variantKey: variant.variantKey,
          stateKey: state.key,
          suggestion: "Attach or generate a fixture for this state.",
          command: stateCommand(component, variant.variantKey, state.key),
          file: state.sourceFile,
          line: state.sourceLine)
      if state.story.isEmptyStory:
        result.add ComponentStateCoverageDiagnostic(
          kind: cscdMissingStory,
          message: "State '" & state.key & "' is missing a story.",
          component: component,
          variantKey: variant.variantKey,
          stateKey: state.key,
          suggestion: "Create a story fixture for the " & state.key & " state.",
          command: stateCommand(component, variant.variantKey, state.key),
          file: state.sourceFile,
          line: state.sourceLine)
  for key in requiredComponentStateKeys():
    if key notin coveredKeys:
      result.add ComponentStateCoverageDiagnostic(
        kind: cscdMissingStory,
        message: "Required component state '" & key & "' has no preview story.",
        component: component,
        variantKey: "default",
        stateKey: key,
        suggestion: "Add a state control and story fixture for '" & key & "'.",
        command: stateCommand(component, "default", key))

proc stateCoverageDiagnostics*(editor: EditorVM;
    component: string): seq[ComponentStateCoverageDiagnostic] =
  stateCoverageDiagnostics(editor.variants.variants.val, component)

func variantMatrixPreviews*(variants: seq[ComponentVariantDefinition];
    component: string): seq[ComponentVariantMatrixCell] =
  for variant in variants:
    if variant.component != component:
      continue
    for state in variant.stateControls:
      let covered = state.fixtureName.len > 0 and not state.story.isEmptyStory
      result.add ComponentVariantMatrixCell(
        component: component,
        variantKey: variant.variantKey,
        stateKey: state.key,
        label: variant.variantKey & " / " & state.label,
        story: state.story,
        fixtureName: state.fixtureName,
        covered: covered,
        missingStorySuggestion:
          if covered: ""
          else: "Create story for " & variant.variantKey & " " & state.key,
        createStoryCommand: stateCommand(component, variant.variantKey, state.key))

proc variantMatrixPreviews*(editor: EditorVM;
    component: string): seq[ComponentVariantMatrixCell] =
  variantMatrixPreviews(editor.variants.variants.val, component)

proc ensureComponentPropertySchemaForSelectedStory*(editor: EditorVM): bool {.
    discardable.} =
  ## Browser consumers may initially expose only real story metadata. Build a
  ## source-backed runtime schema for the selected story so property/state
  ## controls still route through structured source plans and the pending
  ## journal instead of mutating preview DOM.
  let story = editor.selectedStory.val
  if story.kind notin {skComponent, skPattern} or story.group.len == 0:
    return false
  if editor.componentVariantsForComponent(story.group).len > 0:
    return false
  let preview = editor.preview.current.val
  let metadata = preview.metadata
  if preview.documentHtml.len == 0 and metadata.sourceFile.len == 0:
    return false
  let file =
    if metadata.sourceFile.len > 0: metadata.sourceFile
    elif preview.metadata.sourceFile.len > 0: preview.metadata.sourceFile
    else: "components/" & story.group.toLowerAscii() & ".schema"
  let line =
    if metadata.sourceLine > 0: metadata.sourceLine else: 1
  let componentKey = story.group.toLowerAscii().replace(" ", "-")
  let variantKey = story.name.toLowerAscii().replace(" ", "-")
  proc prop(name: string; kind: ComponentPropertyKind; value: string;
      options: seq[string] = @[]; offset = 0): ComponentPropertyDefinition =
    ComponentPropertyDefinition(
      name: name,
      kind: kind,
      value: value,
      options: options,
      sourceFile: file,
      sourceLine: line + offset,
      schemaKey: "components." & componentKey & ".properties." & name,
      fixtureKey:
        if kind == cpkDataFixture:
          "fixtures." & componentKey & "." & name
        else:
          "",
      constructor:
        if kind == cpkDataFixture: "story-fixture-constructor"
        else: "component-source-constructor",
      documentation: componentPropertyKindLabel(kind) & " property for " &
        story.group & ".",
      usageGuidance: "Use schema-owned " & name &
        " changes so stories and constructors stay in sync.")
  proc state(key: string; kind: ComponentStateKind; value: string;
      options: seq[string] = @["false", "true"]; offset = 0): ComponentStateControl =
    ComponentStateControl(
      key: key,
      kind: kind,
      label: componentStateKindLabel(kind),
      value: value,
      options: options,
      story:
        if key in ["size", "tone", "success"]:
          story
        else:
          StoryRef(),
      fixtureName:
        if key in ["size", "tone", "success"]:
          metadata.fixtureName
        else:
          "",
      sourceFile: file,
      sourceLine: line + offset,
      schemaKey: "components." & componentKey & ".states." & key,
      projectSpecific: kind == cskProjectSpecific)
  var controls: seq[ComponentStateControl] = @[]
  controls.add state("size", cskSize, "md", @["sm", "md", "lg"], 20)
  controls.add state("emphasis", cskEmphasis, "regular",
    @["subtle", "regular", "strong"], 21)
  controls.add state("tone", cskTone, "neutral",
    @["neutral", "success", "warning", "error"], 22)
  controls.add state("selected", cskSelected, "false", @["false", "true"], 23)
  controls.add state("disabled", cskDisabled, "false", @["false", "true"], 24)
  controls.add state("hover", cskHover, "false", @["false", "true"], 25)
  controls.add state("focus", cskFocus, "false", @["false", "true"], 26)
  controls.add state("pressed", cskPressed, "false", @["false", "true"], 27)
  controls.add state("loading", cskLoading, "false", @["false", "true"], 28)
  controls.add state("empty", cskEmpty, "false", @["false", "true"], 29)
  controls.add state("error", cskError, "false", @["false", "true"], 30)
  controls.add state("success", cskSuccess, "false", @["false", "true"], 31)
  controls.add state("settlement-ready", cskProjectSpecific, "false",
    @["false", "true"], 32)
  var all = editor.variants.variants.val
  all.add ComponentVariantDefinition(
    component: story.group,
    variantKey: variantKey,
    story: story,
    fixtureName: metadata.fixtureName,
    metadataName: story.name,
    fields: @[
      ComponentVariantField(name: "story", kind: cvfkStoryMetadata,
        value: story.name, sourceFile: file, sourceLine: line,
        schemaKey: "stories." & componentKey & "." & variantKey)
    ],
    properties: @[
      prop("size", cpkEnum, "md", @["sm", "md", "lg"], 1),
      prop("selected", cpkBoolean, "false", @["false", "true"], 2),
      prop("label", cpkText, story.name, @[], 3),
      prop("leadingIcon", cpkIcon, "none", @["none", "search", "status"], 4),
      prop("content", cpkSlotContent, story.name, @[], 5),
      prop("fixture", cpkDataFixture, metadata.fixtureName, @[], 6),
      prop("density", cpkDensity, "comfortable",
        @["compact", "comfortable"], 7),
      prop("platform", cpkPlatform, $editor.platform.val,
        @["pfWeb", "pfIOS", "pfAndroid"], 8),
      prop("ariaLabel", cpkAccessibilityLabel,
        story.group & " " & story.name, @[], 9)
    ],
    stateControls: controls,
    usageExamples: @[
      UsageExample(
        description: "Prefer schema properties and fixtures over detached DOM edits.",
        isDo: true)
    ])
  editor.variants.variants.val = all
  editor.variants.selectedVariant.val = all.high
  editor.variants.stateDiagnostics.val =
    stateCoverageDiagnostics(all, story.group)
  true

func propertySourceKey(prop: ComponentPropertyDefinition): string =
  if prop.fixtureKey.len > 0 and prop.kind == cpkDataFixture: prop.fixtureKey
  else: prop.schemaKey

func sourcePlan(variant: ComponentVariantDefinition;
    prop: ComponentPropertyDefinition; newValue: string;
    mode: ComponentPropertyEditMode): SourceEditPlan =
  let key = prop.propertySourceKey
  let modeLabel = if mode == cpemAi: "ai" else: "manual"
  let constructor =
    if prop.constructor.len > 0: prop.constructor
    elif prop.kind == cpkDataFixture: "story-fixture-constructor"
    else: "component-schema-constructor"
  SourceEditPlan(
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name,
    oldValue: prop.value,
    newValue: newValue.strip(),
    originDetail: "component-property:" & modeLabel & ":" & constructor,
    scope: pesShared,
    planKind: cspStructuredSchemaUpdate,
    schemaKey: key,
    variantKey: variant.variantKey,
    reversible: true,
    previewBefore: prop.name & ": " & prop.value,
    previewAfter: prop.name & ": " & newValue.strip(),
    formatterHook: "format-component-property",
    regeneratorHook: constructor,
    conflictKey: prop.sourceFile & ":" & $prop.sourceLine & ":" &
      variant.component & ":" & variant.variantKey & ":" & prop.name,
    expectedOldValue:
      if constructor in ["component-source-constructor",
          "story-fixture-constructor"]:
        ""
      else:
        prop.value)

func sourcePlan(variant: ComponentVariantDefinition;
    state: ComponentStateControl; newValue: string;
    mode: ComponentPropertyEditMode): SourceEditPlan =
  let modeLabel = if mode == cpemAi: "ai" else: "manual"
  SourceEditPlan(
    file: state.sourceFile,
    line: state.sourceLine,
    property: "state." & state.key,
    oldValue: state.value,
    newValue: newValue.strip(),
    originDetail: "component-state:" & modeLabel & ":state-constructor",
    scope: pesShared,
    planKind: cspStructuredSchemaUpdate,
    schemaKey: state.schemaKey,
    variantKey: variant.variantKey,
    reversible: true,
    previewBefore: state.key & ": " & state.value,
    previewAfter: state.key & ": " & newValue.strip(),
    formatterHook: "format-component-state",
    regeneratorHook: "component-state-constructor",
    conflictKey: state.sourceFile & ":" & $state.sourceLine & ":" &
      variant.component & ":" & variant.variantKey & ":" & state.key,
    expectedOldValue: state.value)

func validateComponentPropertyEdit(variant: ComponentVariantDefinition;
    prop: ComponentPropertyDefinition; newValue: string): seq[
        ComponentVariantDiagnostic] =
  let key = prop.propertySourceKey
  let field = ComponentVariantField(name: prop.name, kind: cvfkProp,
    value: prop.value, sourceFile: prop.sourceFile,
    sourceLine: prop.sourceLine, schemaKey: key)
  if key.len == 0 or prop.sourceFile.len == 0:
    result.add variantDiagnostic(cvdMissingVariantSchema, variant, field,
      "Component property edits require a project schema or fixture entry.")
  if newValue.strip.len == 0:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component property values cannot be blank.")
  if prop.kind == cpkEnum and prop.options.len > 0 and
      newValue.strip notin prop.options:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component enum property must use one of: " & prop.options.join(", ") & ".")
  if prop.kind == cpkBoolean and newValue.strip notin ["true", "false"]:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component boolean properties must be true or false.")
  if prop.kind == cpkDataFixture and prop.fixtureKey.len == 0:
    result.add variantDiagnostic(cvdMissingVariantFixture, variant, field,
      "Data fixture properties require a fixture schema key.")

func validateComponentStateEdit(variant: ComponentVariantDefinition;
    state: ComponentStateControl; newValue: string): seq[
        ComponentVariantDiagnostic] =
  let field = ComponentVariantField(name: "state." & state.key, kind: cvfkState,
    value: state.value, sourceFile: state.sourceFile,
    sourceLine: state.sourceLine, schemaKey: state.schemaKey)
  if state.schemaKey.len == 0 or state.sourceFile.len == 0:
    result.add variantDiagnostic(cvdMissingVariantSchema, variant, field,
      "Component state edits require a project schema entry.")
  if newValue.strip.len == 0:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component state values cannot be blank.")
  if state.options.len > 0 and newValue.strip notin state.options:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component state must use one of: " & state.options.join(", ") & ".")

proc addPendingComponentPlan(editor: EditorVM; plan: SourceEditPlan) =
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  editor.workspaceEditDiagnostics.val = @[]
  editor.chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[
      EditRecord] =
    result = prev
    result.add EditRecord(
      file: plan.file,
      line: plan.line,
      property: plan.property,
      oldValue: plan.oldValue,
      newValue: plan.newValue,
      origin: poConstant,
      originDetail: plan.originDetail,
      scope: pesShared,
      isShared: true,
      editOrigin:
        if plan.originDetail.contains(":ai:"): peoAgent else: peoInspector,
      sourcePlanKind: plan.planKind)

func sourcePlan(variant: ComponentVariantDefinition;
    field: ComponentVariantField; newValue: string): SourceEditPlan =
  SourceEditPlan(
    file: field.sourceFile,
    line: field.sourceLine,
    property: field.name,
    oldValue: field.value,
    newValue: newValue.strip(),
    originDetail: "schema:" & field.schemaKey,
    scope: pesShared,
    planKind:
      if field.kind in {cvfkSampleData, cvfkStoryMetadata}: cspStructuredSchemaUpdate
      else: cspStructuredSchemaUpdate,
    schemaKey: field.schemaKey,
    variantKey: variant.variantKey,
    reversible: true,
    previewBefore: field.name & ": " & field.value,
    previewAfter: field.name & ": " & newValue.strip(),
    formatterHook: "format-component-variant",
    regeneratorHook: "regenerate-design-system",
    conflictKey: field.sourceFile & ":" & $field.sourceLine & ":" & field.name,
    expectedOldValue: field.value)

proc validateComponentVariantEdit(variant: ComponentVariantDefinition;
    field: ComponentVariantField; newValue: string): seq[ComponentVariantDiagnostic] =
  if field.schemaKey.len == 0 or field.sourceFile.len == 0:
    result.add variantDiagnostic(cvdMissingVariantSchema, variant, field,
      "Component variant edits require a project schema entry.")
  if newValue.strip.len == 0:
    result.add variantDiagnostic(cvdInvalidVariantValue, variant, field,
      "Component variant values cannot be blank.")
  if field.kind == cvfkSampleData and variant.fixtureName.len == 0:
    result.add variantDiagnostic(cvdMissingVariantFixture, variant, field,
      "Variant sample data edits require a fixture name.")
  if field.kind == cvfkStoryMetadata and variant.metadataName.len > 0 and
      variant.metadataName != variant.story.name:
    result.add variantDiagnostic(cvdInconsistentStoryMetadata, variant, field,
      "Variant story metadata must match the selected story.")

proc editComponentVariantField*(editor: EditorVM; component, variantKey, fieldName,
    newValue: string): ComponentVariantEditResult {.discardable.} =
  var variantIndex = -1
  var fieldIndex = -1
  var variant = ComponentVariantDefinition()
  var field = ComponentVariantField()
  for i, candidate in editor.variants.variants.val:
    if candidate.component == component and candidate.variantKey == variantKey:
      variantIndex = i
      variant = candidate
      for j, f in candidate.fields:
        if f.name == fieldName:
          fieldIndex = j
          field = f
          break
      break
  if variantIndex < 0 or fieldIndex < 0:
    let diagnostic = ComponentVariantDiagnostic(
      kind: cvdMissingVariantSchema,
      message: "Unknown component variant field.",
      component: component,
      variantKey: variantKey,
      field: fieldName)
    editor.variants.diagnostics.val = @[diagnostic]
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: @[diagnostic])

  let diagnostics = validateComponentVariantEdit(variant, field, newValue)
  if diagnostics.len > 0:
    editor.variants.diagnostics.val = diagnostics
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: diagnostics, affectedStory: variant.story)

  let plan = variant.sourcePlan(field, newValue)
  var updated = editor.variants.variants.val
  updated[variantIndex].fields[fieldIndex].value = newValue.strip()
  editor.variants.variants.val = updated
  editor.variants.selectedVariant.val = variantIndex
  editor.variants.diagnostics.val = @[]
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
    result.add CSSSourcePreview(plan: plan, beforeText: plan.previewBefore,
      afterText: plan.previewAfter)
  editor.workspaceEditStage.val = wesDirty
  ComponentVariantEditResult(status: pesAccepted, sourceEdit: plan,
    affectedStory: variant.story)

proc editComponentProperty*(editor: EditorVM; component, variantKey,
    propertyName, newValue: string; mode = cpemManual): ComponentVariantEditResult {.
        discardable.} =
  var variantIndex = -1
  var propIndex = -1
  var variant = ComponentVariantDefinition()
  var prop = ComponentPropertyDefinition()
  for i, candidate in editor.variants.variants.val:
    if candidate.component == component and candidate.variantKey == variantKey:
      variantIndex = i
      variant = candidate
      for j, p in candidate.properties:
        if p.name == propertyName:
          propIndex = j
          prop = p
          break
      break
  if variantIndex < 0 or propIndex < 0:
    let diagnostic = ComponentVariantDiagnostic(
      kind: cvdMissingVariantSchema,
      message: "Unknown component property.",
      component: component,
      variantKey: variantKey,
      field: propertyName)
    editor.variants.diagnostics.val = @[diagnostic]
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: @[diagnostic])

  let diagnostics = validateComponentPropertyEdit(variant, prop, newValue)
  if diagnostics.len > 0:
    editor.variants.diagnostics.val = diagnostics
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: diagnostics, affectedStory: variant.story)

  let plan = variant.sourcePlan(prop, newValue, mode)
  var updated = editor.variants.variants.val
  updated[variantIndex].properties[propIndex].value = newValue.strip()
  editor.variants.variants.val = updated
  editor.variants.selectedVariant.val = variantIndex
  editor.variants.diagnostics.val = @[]
  editor.addPendingComponentPlan(plan)
  ComponentVariantEditResult(status: pesAccepted, sourceEdit: plan,
    affectedStory: variant.story)

proc editComponentStateControl*(editor: EditorVM; component, variantKey,
    stateKey, newValue: string; mode = cpemManual): ComponentVariantEditResult {.
        discardable.} =
  var variantIndex = -1
  var stateIndex = -1
  var variant = ComponentVariantDefinition()
  var state = ComponentStateControl()
  for i, candidate in editor.variants.variants.val:
    if candidate.component == component and candidate.variantKey == variantKey:
      variantIndex = i
      variant = candidate
      for j, s in candidate.stateControls:
        if s.key == stateKey:
          stateIndex = j
          state = s
          break
      break
  if variantIndex < 0 or stateIndex < 0:
    let diagnostic = ComponentVariantDiagnostic(
      kind: cvdMissingVariantSchema,
      message: "Unknown component state control.",
      component: component,
      variantKey: variantKey,
      field: stateKey)
    editor.variants.diagnostics.val = @[diagnostic]
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: @[diagnostic])

  let diagnostics = validateComponentStateEdit(variant, state, newValue)
  if diagnostics.len > 0:
    editor.variants.diagnostics.val = diagnostics
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: diagnostics, affectedStory: variant.story)

  let plan = variant.sourcePlan(state, newValue, mode)
  var updated = editor.variants.variants.val
  updated[variantIndex].stateControls[stateIndex].value = newValue.strip()
  editor.variants.variants.val = updated
  editor.variants.selectedVariant.val = variantIndex
  editor.variants.diagnostics.val = @[]
  editor.variants.stateDiagnostics.val =
    stateCoverageDiagnostics(updated, component)
  editor.addPendingComponentPlan(plan)
  ComponentVariantEditResult(status: pesAccepted, sourceEdit: plan,
    affectedStory: variant.story)

proc createStoryForComponentState*(editor: EditorVM; component, variantKey,
    stateKey: string): ComponentVariantEditResult {.discardable.} =
  var variantIndex = -1
  var stateIndex = -1
  var variant = ComponentVariantDefinition()
  var state = ComponentStateControl()
  for i, candidate in editor.variants.variants.val:
    if candidate.component == component and candidate.variantKey == variantKey:
      variantIndex = i
      variant = candidate
      for j, s in candidate.stateControls:
        if s.key == stateKey:
          stateIndex = j
          state = s
          break
      break
  if variantIndex < 0 or stateIndex < 0:
    let diagnostic = ComponentVariantDiagnostic(
      kind: cvdMissingVariantSchema,
      message: "Unknown state for create-story command.",
      component: component,
      variantKey: variantKey,
      field: stateKey)
    editor.variants.diagnostics.val = @[diagnostic]
    return ComponentVariantEditResult(status: pesRejected,
      diagnostics: @[diagnostic])
  let story = StoryRef(
    group: component,
    name: variantKey & " " & stateKey,
    kind: skComponent,
    index: 0)
  let sourceFile =
    if state.sourceFile.len > 0: state.sourceFile
    elif variant.fields.len > 0: variant.fields[0].sourceFile
    else: ""
  let sourceLine =
    if state.sourceLine > 0: state.sourceLine
    elif variant.fields.len > 0: variant.fields[0].sourceLine
    else: 1
  let schemaKey =
    if state.schemaKey.len > 0: state.schemaKey & ".story"
    else: "stories." & component.toLowerAscii() & "." &
      variantKey.toLowerAscii() & "." & stateKey.toLowerAscii()
  let plan = SourceEditPlan(
    file: sourceFile,
    line: sourceLine,
    property: "story." & stateKey,
    oldValue: "",
    newValue: story.name,
    originDetail: "component-state:manual:create-story",
    scope: pesShared,
    planKind: cspStructuredSchemaUpdate,
    schemaKey: schemaKey,
    variantKey: variantKey,
    reversible: true,
    previewBefore: "missing story for " & stateKey,
    previewAfter: "create story " & story.name,
    formatterHook: "format-component-story",
    regeneratorHook: "component-story-constructor",
    conflictKey: sourceFile & ":" & $sourceLine & ":" & component & ":" &
      variantKey & ":" & stateKey & ":story")
  var updated = editor.variants.variants.val
  for i, control in updated[variantIndex].stateControls:
    if control.key == stateKey:
      updated[variantIndex].stateControls[i].story = story
      if updated[variantIndex].stateControls[i].fixtureName.len == 0:
        updated[variantIndex].stateControls[i].fixtureName =
          component.toLowerAscii() & "." & variantKey.toLowerAscii() & "." &
          stateKey.toLowerAscii()
  editor.variants.variants.val = updated
  editor.variants.selectedVariant.val = variantIndex
  editor.variants.diagnostics.val = @[]
  editor.variants.stateDiagnostics.val =
    stateCoverageDiagnostics(updated, component)
  editor.addPendingComponentPlan(plan)
  ComponentVariantEditResult(status: pesAccepted, sourceEdit: plan,
    affectedStory: story)

func workspacePlanKeys(plan: SourceEditPlan): seq[string] =
  if plan.schemaKey.len > 0:
    result.add plan.schemaKey
    result.add "schema:" & plan.schemaKey
  if plan.tokenName.len > 0:
    result.add plan.tokenName
    result.add "token:" & plan.tokenName
  if plan.variantKey.len > 0:
    result.add plan.variantKey
    result.add "variant:" & plan.variantKey
  if plan.conflictKey.len > 0:
    result.add plan.conflictKey
    result.add "source:" & plan.conflictKey
  if plan.originDetail.len > 0:
    result.add plan.originDetail

func resolveWorkspaceSchema(adapter: WorkspaceEditAdapter;
    plan: SourceEditPlan): tuple[ok: bool, entry: WorkspaceEditableSchemaEntry] =
  if adapter.isNil:
    return
  let keys = workspacePlanKeys(plan)
  for key in keys:
    for entry in adapter.schema:
      if entry.key == key:
        return (true, entry)
  for entry in adapter.schema:
    if entry.file == plan.file and
        (entry.property == plan.property or entry.property.len == 0):
      return (true, entry)

func workspaceOpFailed(op: WorkspaceOperationResult): bool =
  not op.ok

proc addUniqueFile(files: var seq[string]; file: string) =
  if file.len == 0:
    return
  if file notin files:
    files.add file

proc addUniqueStory(stories: var seq[StoryRef]; story: StoryRef) =
  if story.isEmptyStoryRef:
    return
  for existing in stories:
    if sameStory(existing, story):
      return
  stories.add story

type WorkspaceFileDraft = object
  file: string
  beforeContent: string
  currentContent: string

proc draftIndex(drafts: seq[WorkspaceFileDraft]; file: string): int =
  for i, draft in drafts:
    if draft.file == file:
      return i
  -1

proc patchForFile(patches: seq[WorkspaceFilePatch];
    file: string): WorkspaceFilePatch =
  for patch in patches:
    if patch.file == file:
      return patch

proc failWorkspaceEdit(editor: EditorVM; diagnostics: seq[WorkspaceEditDiagnostic];
    patches: seq[WorkspaceFilePatch] = @[];
    stage = wesFailed): WorkspaceEditResult =
  let detail =
    if diagnostics.len > 0: "bridge-error:" & diagnostics[0].message
    else: "bridge-error:workspace edit failed"
  editor.recordEditorTiming(epbkSaveReload, 1, detail)
  editor.workspaceEditStage.val = stage
  editor.workspaceEditDiagnostics.val = diagnostics
  WorkspaceEditResult(
    ok: false,
    stage: stage,
    diagnostics: diagnostics,
    patches: patches,
    generatedArtifacts: editor.workspaceEditGeneratedArtifacts.val,
    requiredTestCommands: editor.workspaceEditRequiredTestCommands.val,
    reviewDiagnostics: editor.workspaceEditReviewDiagnostics.val)

proc operationDiagnostics(kind: WorkspaceEditDiagnosticKind;
    op: WorkspaceOperationResult; fallback: string): seq[WorkspaceEditDiagnostic] =
  if op.diagnostics.len > 0:
    return op.diagnostics
  @[workspaceDiagnostic(kind, if op.message.len > 0: op.message else: fallback)]

proc rollbackWorkspaceWrites(editor: EditorVM; adapter: WorkspaceEditAdapter;
    originals: seq[WorkspaceFilePatch]): seq[WorkspaceEditDiagnostic] =
  if originals.len == 0:
    return @[]
  for patch in countdown(originals.high, 0):
    let current = originals[patch]
    let op = adapter.writeFile(current.file, current.beforeContent)
    if not op.ok:
      if op.diagnostics.len > 0:
        result.add op.diagnostics
      else:
        result.add workspaceDiagnostic(wedRollbackFailed,
          "Rollback failed while restoring " & current.file & ".",
          file = current.file,
          schemaKey = current.schema.key,
          property = current.plan.property)

proc requireWorkspaceAdapter(editor: EditorVM): tuple[ok: bool,
    adapter: WorkspaceEditAdapter, diagnostics: seq[WorkspaceEditDiagnostic]] =
  result.adapter = editor.workspaceEditAdapter
  if result.adapter.isNil:
    result.diagnostics = @[workspaceDiagnostic(wedMissingAdapter,
      "No workspace edit adapter is configured.")]
    return
  if result.adapter.readFile.isNil:
    result.diagnostics = @[workspaceDiagnostic(wedMissingOperation,
      "Workspace edit adapter is missing readFile.")]
    return
  if result.adapter.writeFile.isNil:
    result.diagnostics = @[workspaceDiagnostic(wedMissingOperation,
      "Workspace edit adapter is missing writeFile.")]
    return
  if result.adapter.patchFile.isNil:
    result.diagnostics = @[workspaceDiagnostic(wedMissingOperation,
      "Workspace edit adapter is missing patchFile.")]
    return
  result.ok = true

proc applyWorkspaceFileEdits*(editor: EditorVM): WorkspaceEditResult {.discardable.} =
  ## Apply pending source plans through a project-owned adapter transaction.
  ## Files are read and patched before writes begin; failed post-write operations
  ## roll written files back to their original content.
  let pending = editor.inspector.pendingSourceEdits.val
  if pending.len == 0:
    editor.workspaceEditStage.val = wesClean
    editor.workspaceEditDiagnostics.val = @[]
    return WorkspaceEditResult(ok: true, stage: wesClean)

  let adapterReq = editor.requireWorkspaceAdapter()
  if not adapterReq.ok:
    return editor.failWorkspaceEdit(adapterReq.diagnostics)
  let adapter = adapterReq.adapter

  editor.workspaceEditStage.val = wesApplying
  editor.workspaceEditDiagnostics.val = @[]
  editor.workspaceEditPatches.val = @[]
  editor.workspaceEditAffectedStories.val = @[]
  editor.workspaceEditFullReload.val = false
  editor.workspaceEditGeneratedArtifacts.val = @[]
  editor.workspaceEditRequiredTestCommands.val = @[]
  editor.workspaceEditReviewDiagnostics.val = @[]

  var patches: seq[WorkspaceFilePatch] = @[]
  var diagnostics: seq[WorkspaceEditDiagnostic] = @[]
  var files: seq[string] = @[]
  var schemaKeys: seq[string] = @[]
  var affectedStories: seq[StoryRef] = @[]
  var generatedArtifacts: seq[string] = @[]
  var requiredTestCommands: seq[string] = @[]
  var reviewDiagnostics: seq[WorkspaceEditDiagnostic] = @[]
  var drafts: seq[WorkspaceFileDraft] = @[]
  var fullReload = false

  for plan in pending:
    let resolved = adapter.resolveWorkspaceSchema(plan)
    if not resolved.ok:
      diagnostics.add workspaceDiagnostic(wedMissingSchema,
        "No project schema or source map entry can safely represent this edit.",
        file = plan.file,
        schemaKey = if plan.schemaKey.len > 0: plan.schemaKey else: plan.conflictKey,
        property = plan.property)
      continue

    if resolved.entry.file.len > 0 and plan.file.len > 0 and
        resolved.entry.file != plan.file:
      diagnostics.add workspaceDiagnostic(wedUnsafeSourceMap,
        "The source plan file does not match the resolved project schema file.",
        file = plan.file,
        schemaKey = resolved.entry.key,
        property = plan.property)
      continue

    let targetFile =
      if plan.file.len > 0: plan.file
      else: resolved.entry.file
    var draftPos = drafts.draftIndex(targetFile)
    if draftPos < 0:
      let read = adapter.readFile(targetFile)
      if not read.ok:
        if read.diagnostics.len > 0:
          diagnostics.add read.diagnostics
        else:
          diagnostics.add workspaceDiagnostic(wedReadFailed,
            "Could not read " & targetFile & ".", file = targetFile,
            schemaKey = resolved.entry.key, property = plan.property)
        continue
      drafts.add WorkspaceFileDraft(file: targetFile,
        beforeContent: read.content,
        currentContent: read.content)
      draftPos = drafts.high

    if plan.expectedOldValue.len > 0 and
        not adapter.allowMissingExpectedOldValue and
        plan.expectedOldValue notin drafts[draftPos].currentContent:
      diagnostics.add workspaceDiagnostic(wedSourceConflict,
        "Source changed before the pending edit could be applied.",
        file = targetFile,
        schemaKey = resolved.entry.key,
        property = plan.property)
      continue

    let patchResult = adapter.patchFile(plan, drafts[draftPos].currentContent,
      resolved.entry)
    if not patchResult.ok:
      if patchResult.diagnostics.len > 0:
        diagnostics.add patchResult.diagnostics
      else:
        diagnostics.add workspaceDiagnostic(wedPatchFailed,
          "Could not create a patch for " & plan.property & ".",
          file = plan.file,
          schemaKey = resolved.entry.key,
          property = plan.property)
      continue

    var patch = patchResult.patch
    if patch.file.len == 0:
      patch.file = targetFile
    patch.plan = plan
    patch.schema = resolved.entry
    patch.beforeContent = drafts[draftPos].currentContent
    if patch.affectedStory.isEmptyStoryRef:
      patch.affectedStory = resolved.entry.story
    if patch.afterContent.len == 0 and drafts[draftPos].currentContent.len > 0:
      diagnostics.add workspaceDiagnostic(wedPatchFailed,
        "Project adapter returned an empty patched source.",
        file = targetFile,
        schemaKey = resolved.entry.key,
        property = plan.property)
      continue

    drafts[draftPos].currentContent = patch.afterContent
    patches.add patch
    files.addUniqueFile patch.file
    if resolved.entry.key.len > 0 and resolved.entry.key notin schemaKeys:
      schemaKeys.add resolved.entry.key
    affectedStories.addUniqueStory patch.affectedStory
    fullReload = fullReload or patch.fullReload

  if diagnostics.len > 0:
    return editor.failWorkspaceEdit(diagnostics, patches)

  if adapter.review != nil:
    editor.workspaceEditStage.val = wesReviewing
    let review = adapter.review(patches)
    editor.review.violations.val = review.violations
    reviewDiagnostics = review.diagnostics
    if not review.ok:
      diagnostics = review.diagnostics
      if diagnostics.len == 0:
        diagnostics.add workspaceDiagnostic(wedReviewFailed,
          "Workspace review rejected the pending edit transaction.")
      return editor.failWorkspaceEdit(diagnostics, patches)

  var writePatches: seq[WorkspaceFilePatch] = @[]
  for draft in drafts:
    var writePatch = patches.patchForFile(draft.file)
    writePatch.file = draft.file
    writePatch.beforeContent = draft.beforeContent
    writePatch.afterContent = draft.currentContent
    writePatches.add writePatch

  var written: seq[WorkspaceFilePatch] = @[]
  for patch in writePatches:
    let write = adapter.writeFile(patch.file, patch.afterContent)
    if write.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedWriteFailed, write,
        "Could not write " & patch.file & ".")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
    generatedArtifacts.add write.generatedArtifacts
    requiredTestCommands.add write.requiredTestCommands
    reviewDiagnostics.add write.reviewDiagnostics
    for story in write.affectedStories:
      affectedStories.addUniqueStory story
    fullReload = fullReload or write.fullReload
    written.add patch

  if adapter.formatFiles != nil:
    editor.workspaceEditStage.val = wesFormatting
    let formatted = adapter.formatFiles(files)
    if formatted.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedFormatFailed, formatted,
        "Workspace formatting failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
    generatedArtifacts.add formatted.generatedArtifacts
    requiredTestCommands.add formatted.requiredTestCommands
    reviewDiagnostics.add formatted.reviewDiagnostics

  if adapter.regenerate != nil:
    editor.workspaceEditStage.val = wesRegenerating
    let regenerated = adapter.regenerate(schemaKeys)
    if regenerated.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedRegenerateFailed, regenerated,
        "Workspace regeneration failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
    generatedArtifacts.add regenerated.generatedArtifacts
    requiredTestCommands.add regenerated.requiredTestCommands
    reviewDiagnostics.add regenerated.reviewDiagnostics
    for story in regenerated.affectedStories:
      affectedStories.addUniqueStory story
    fullReload = fullReload or regenerated.fullReload

  if adapter.compile != nil:
    editor.workspaceEditStage.val = wesCompiling
    let compiled = adapter.compile(affectedStories)
    if compiled.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedCompileFailed, compiled,
        "Workspace compilation failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
    generatedArtifacts.add compiled.generatedArtifacts
    requiredTestCommands.add compiled.requiredTestCommands
    reviewDiagnostics.add compiled.reviewDiagnostics

  if adapter.reloadPreview != nil:
    editor.workspaceEditStage.val = wesReloading
    let reloaded = adapter.reloadPreview(affectedStories, fullReload)
    if reloaded.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedReloadFailed, reloaded,
        "Workspace preview reload failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
    generatedArtifacts.add reloaded.generatedArtifacts
    requiredTestCommands.add reloaded.requiredTestCommands
    reviewDiagnostics.add reloaded.reviewDiagnostics

  editor.inspector.markCssPropertyEditsSaved()
  editor.vectorEditor.undoStack.val = @[]
  editor.vectorEditor.redoStack.val = @[]
  editor.foundations.undoStack.val = @[]
  editor.foundations.redoStack.val = @[]
  editor.chat.accumulatedEdits.val = @[]
  editor.workspaceEditStage.val = wesClean
  editor.workspaceEditDiagnostics.val = @[]
  editor.workspaceEditPatches.val = patches
  editor.workspaceEditAffectedStories.val = affectedStories
  editor.workspaceEditFullReload.val = fullReload
  editor.workspaceEditGeneratedArtifacts.val = generatedArtifacts
  editor.workspaceEditRequiredTestCommands.val = requiredTestCommands
  editor.workspaceEditReviewDiagnostics.val = reviewDiagnostics
  if not adapter.stagingOnly:
    editor.livePreviewReloadGeneration.val = editor.livePreviewReloadGeneration.val + 1
  editor.recordEditorTiming(epbkSaveReload, 1,
    if fullReload: "preview-reload:full" else: "preview-reload:affected")
  WorkspaceEditResult(
    ok: true,
    stage: wesClean,
    patches: patches,
    affectedStories: affectedStories,
    fullReload: fullReload,
    generatedArtifacts: generatedArtifacts,
    requiredTestCommands: requiredTestCommands,
    reviewDiagnostics: reviewDiagnostics)

# ===========================================================================
# AgentChatVM actions
# ===========================================================================

func agentProposalId(count: int): string =
  "agent-proposal-" & $(count + 1)

func sourceMapEntries(element: ElementRef;
    pending: seq[SourceEditPlan]): seq[AgentSourceMapEntry] =
  for prop in element.properties:
    result.add AgentSourceMapEntry(
      elementTag: element.tag,
      property: prop.name,
      file: prop.sourceFile,
      line: prop.sourceLine,
      originDetail: prop.originDetail,
      schemaKey: prop.schemaKey,
      tokenName: prop.tokenName,
      variantKey: prop.variantKey)
  for plan in pending:
    result.add AgentSourceMapEntry(
      elementTag: element.tag,
      property: plan.property,
      file: plan.file,
      line: plan.line,
      originDetail: plan.originDetail,
      schemaKey: plan.schemaKey,
      tokenName: plan.tokenName,
      variantKey: plan.variantKey)

func schemaSnapshot(adapter: WorkspaceEditAdapter): seq[AgentDesignSystemSchemaEntry] =
  if adapter.isNil:
    return @[]
  for entry in adapter.schema:
    result.add AgentDesignSystemSchemaEntry(
      key: entry.key,
      kind: $entry.kind,
      file: entry.file,
      path: entry.path,
      property: entry.property)

func designSystemSchemaSnapshot(
    schema: DesignSystemSchema): seq[AgentDesignSystemSchemaEntry] =
  for node in schema.nodes:
    result.add AgentDesignSystemSchemaEntry(
      key: node.key,
      kind: $node.kind,
      file: node.sourceSpan.file,
      path: node.component & "." & node.property,
      property: node.property)

func componentVariantSchemaSnapshot(
    variants: seq[ComponentVariantDefinition]): seq[AgentDesignSystemSchemaEntry] =
  for variant in variants:
    for prop in variant.properties:
      let key = prop.propertySourceKey
      if key.len > 0:
        result.add AgentDesignSystemSchemaEntry(
          key: key,
          kind: $prop.kind,
          file: prop.sourceFile,
          path: variant.component & "." & variant.variantKey & "." & prop.name,
          property: prop.name)
    for state in variant.stateControls:
      if state.schemaKey.len > 0:
        result.add AgentDesignSystemSchemaEntry(
          key: state.schemaKey,
          kind: $state.kind,
          file: state.sourceFile,
          path: variant.component & "." & variant.variantKey & ".state." &
            state.key,
          property: "state." & state.key)

func propertyDiagnosticSnapshot(
    diagnostics: seq[PropertyEditDiagnostic]): seq[AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "inspector",
      severity: "warning",
      category: $diagnostic.kind,
      message: diagnostic.message,
      file: diagnostic.file,
      line: diagnostic.line,
      property: diagnostic.property)

func workspaceDiagnosticSnapshot(
    diagnostics: seq[WorkspaceEditDiagnostic]): seq[AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "workspace",
      severity: "error",
      category: $diagnostic.kind,
      message: diagnostic.message,
      file: diagnostic.file,
      property: diagnostic.property)

func reviewDiagnosticSnapshot(
    violations: seq[Violation]): seq[AgentDiagnosticSnapshot] =
  for violation in violations:
    result.add AgentDiagnosticSnapshot(
      source: "review",
      severity: $violation.severity,
      category: $violation.category,
      message: violation.message,
      file: violation.file,
      line: violation.line)

func vectorDiagnosticSnapshot(
    diagnostics: seq[VectorDiagnostic]): seq[AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "vector",
      severity: "warning",
      category: $diagnostic.kind,
      message: diagnostic.message,
      file: diagnostic.schemaKey,
      property: diagnostic.objectId)

func foundationDiagnosticSnapshot(
    diagnostics: seq[FoundationEditDiagnostic]): seq[AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "foundation",
      severity: "warning",
      category: $diagnostic.kind,
      message: diagnostic.message,
      file: diagnostic.file,
      line: diagnostic.line,
      property: diagnostic.key)

func variantDiagnosticSnapshot(
    diagnostics: seq[ComponentVariantDiagnostic]): seq[AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "variant",
      severity: "warning",
      category: $diagnostic.kind,
      message: diagnostic.message,
      file: diagnostic.file,
      line: diagnostic.line,
      property: diagnostic.variantKey & "." & diagnostic.field)

func stateCoverageDiagnosticSnapshot(
    diagnostics: seq[ComponentStateCoverageDiagnostic]): seq[
        AgentDiagnosticSnapshot] =
  for diagnostic in diagnostics:
    result.add AgentDiagnosticSnapshot(
      source: "component-state",
      severity: "warning",
      category: $diagnostic.kind,
      message: diagnostic.message & " " & diagnostic.suggestion,
      file: diagnostic.file,
      line: diagnostic.line,
      property: diagnostic.variantKey & "." & diagnostic.stateKey)

func sourcePreviewDiffs(previews: seq[CSSSourcePreview]): seq[AgentFileDiff] =
  for preview in previews:
    result.add AgentFileDiff(
      file: preview.plan.file,
      beforeText: preview.beforeText,
      afterText: preview.afterText,
      summary: preview.plan.property & ": " & preview.plan.oldValue &
        " -> " & preview.plan.newValue)

func workspacePatchDiffs(patches: seq[WorkspaceFilePatch]): seq[AgentFileDiff] =
  for patch in patches:
    result.add AgentFileDiff(
      file: patch.file,
      beforeText: patch.beforeContent,
      afterText: patch.afterContent,
      summary: patch.plan.property & ": " & patch.plan.oldValue &
        " -> " & patch.plan.newValue)

func reviewAnnotationId(count: int): string =
  "review-annotation-" & $(count + 1)

func ownershipContext(schema: DesignSystemSchema;
    element: ElementRef): ReviewSourceOwnershipContext =
  result = ReviewSourceOwnershipContext(
    ownerPackage: schema.ownerPackage,
    sourceFile: element.sourceFile,
    sourceLine: element.sourceLine,
    schemaKey: if element.schemaKey.len > 0: element.schemaKey else: element.sourceKey)
  for owner in schema.sourceOwnership:
    let matchesElement =
      (element.sourceKey.len > 0 and owner.elementSourceKey == element.sourceKey) or
      (element.domPath.len > 0 and owner.domPath == element.domPath) or
      (element.schemaKey.len > 0 and owner.schemaKey == element.schemaKey)
    if matchesElement:
      result.sourceFile =
        if owner.sourceSpan.file.len > 0: owner.sourceSpan.file
        else: result.sourceFile
      result.sourceLine =
        if owner.sourceSpan.line > 0: owner.sourceSpan.line
        else: result.sourceLine
      result.schemaKey = owner.schemaKey
      result.nodeKey = owner.nodeKey
      result.generatedViewFile = owner.generatedViewFile
      result.generatedViewLine = owner.generatedViewLine
      result.cssModuleFile = owner.cssModuleFile
      result.cssModuleClass = owner.cssModuleClass
      result.tailwindUtilities = owner.tailwindUtilities
      result.fallbackAllowed = owner.fallbackAllowed
      result.unstructuredViewCode = owner.unstructuredViewCode
      return

func openPromptAnnotations(annotations: seq[ReviewAnnotation]): seq[ReviewAnnotation] =
  for annotation in annotations:
    if annotation.state == ransOpen and annotation.includedInPrompt:
      result.add annotation

func selectedSchemaSnapshot(context: AgentPromptContext): seq[
    AgentDesignSystemSchemaEntry] =
  let selected = context.selectedElement
  for entry in context.designSystemSchema:
    if entry.key.len == 0:
      continue
    if entry.key == selected.schemaKey or entry.key == selected.sourceKey:
      result.add entry
      continue
    for prop in selected.properties:
      if entry.key == prop.schemaKey or entry.key == prop.tokenName or
          entry.key == prop.variantKey:
        result.add entry
        break

func tokenContext(element: ElementRef;
    schema: seq[AgentDesignSystemSchemaEntry]): seq[string] =
  for prop in element.properties:
    if prop.tokenName.len > 0:
      let line = prop.name & "=" & prop.value & " token=" & prop.tokenName
      if line notin result:
        result.add line
  for entry in schema:
    if entry.kind.contains("Token") and entry.key.len > 0:
      let line = entry.key & " property=" & entry.property & " file=" & entry.file
      if line notin result:
        result.add line

func componentVariantContext(variants: seq[ComponentVariantDefinition];
    story: StoryRef; element: ElementRef): seq[string] =
  for variant in variants:
    if (story.group.len > 0 and variant.component.normalize ==
        story.group.normalize) or (element.schemaKey.len > 0 and
        variant.properties.anyIt(it.schemaKey == element.schemaKey)):
      result.add variant.component & "/" & variant.variantKey &
        " fixture=" & variant.fixtureName & " story=" & variant.story.name
      for prop in variant.properties:
        if prop.schemaKey.len > 0:
          result.add "property " & prop.name & "=" & prop.value &
            " schema=" & prop.schemaKey
      for state in variant.stateControls:
        if state.schemaKey.len > 0:
          result.add "state " & state.key & "=" & state.value &
            " schema=" & state.schemaKey

proc buildAgentPromptContext*(editor: EditorVM): AgentPromptContext =
  let schemaEntries = designSystemSchemaSnapshot(editor.designSystemSchema.val) &
    schemaSnapshot(editor.workspaceEditAdapter) &
    componentVariantSchemaSnapshot(editor.variants.variants.val)
  var annotations = editor.review.annotations.val.openPromptAnnotations()
  var screenshotRefs: seq[string] = @[]
  var domSnapshots: seq[string] = @[]
  for annotation in annotations:
    if editor.chat.promptIncludesScreenshots.val and annotation.screenshotRef.len > 0:
      screenshotRefs.add annotation.screenshotRef
    if editor.chat.promptIncludesDomSnapshots.val and annotation.domSnapshot.len > 0:
      domSnapshots.add annotation.domSnapshot
  result = AgentPromptContext(
    selectedStory: editor.selectedStory.val,
    selectedElement: editor.inspector.selectedElement.val,
    accumulatedEdits: editor.chat.accumulatedEdits.val,
    pendingSourceEdits: editor.inspector.pendingSourceEdits.val,
    sourceMap: sourceMapEntries(editor.inspector.selectedElement.val,
      editor.inspector.pendingSourceEdits.val),
    designSystemSchema: schemaEntries,
    reviewAnnotations: annotations,
    screenshotRefs: screenshotRefs,
    domSnapshots: domSnapshots,
    designSystemConstraints: editor.chat.designSystemConstraints.val,
    diagnostics:
      propertyDiagnosticSnapshot(editor.inspector.editDiagnostics.val) &
      workspaceDiagnosticSnapshot(editor.workspaceEditDiagnostics.val) &
      reviewDiagnosticSnapshot(editor.review.violations.val) &
      vectorDiagnosticSnapshot(editor.vectorEditor.diagnostics.val) &
      foundationDiagnosticSnapshot(editor.foundations.diagnostics.val) &
      variantDiagnosticSnapshot(editor.variants.diagnostics.val) &
      stateCoverageDiagnosticSnapshot(editor.variants.stateDiagnostics.val),
    currentFileDiffs:
      sourcePreviewDiffs(editor.inspector.sourcePreviews.val) &
      workspacePatchDiffs(editor.workspaceEditPatches.val),
    platform: editor.platform.val,
    backend: editor.chat.backend.val)
  result.selectedSchemaNodes = result.selectedSchemaSnapshot()
  result.tokenContext = tokenContext(result.selectedElement, schemaEntries)
  result.componentVariantContext = componentVariantContext(
    editor.variants.variants.val, result.selectedStory, result.selectedElement)

proc addUserMessage*(chat: AgentChatVM; text: string) =
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkUser, text: text, timestamp: 0.0)
  chat.inputText.val = ""

proc addAgentResponse*(chat: AgentChatVM; text: string) =
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkAgent, text: text, timestamp: 0.0)

proc recordEdit*(chat: AgentChatVM; edit: EditRecord) =
  chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
    result = prev
    result.add edit

proc clearAccumulatedEdits*(chat: AgentChatVM) =
  chat.accumulatedEdits.val = @[]

proc configureAgentPromptContext*(chat: AgentChatVM; includeScreenshots = false;
    includeDomSnapshots = false; constraints: seq[string] = @[]) =
  chat.promptIncludesScreenshots.val = includeScreenshots
  chat.promptIncludesDomSnapshots.val = includeDomSnapshots
  if constraints.len > 0:
    chat.designSystemConstraints.val = constraints

proc configureAgentAdapters*(chat: AgentChatVM;
    promptAdapter: AgentPromptAdapter = nil;
    cancelAdapter: AgentCancelAdapter = nil;
    backend = absUnconfigured) =
  chat.promptAdapter = promptAdapter
  chat.cancelAdapter = cancelAdapter
  chat.backend.val = backend

proc addReviewAnnotation*(editor: EditorVM; text: string;
    selector = ""; ancestry = ""; domSnapshot = ""; screenshotRef = "";
    severity = rasInfo; suggestedScope = pesLocal; source = "user"): string {.
    discardable.} =
  let trimmed = text.strip()
  if trimmed.len == 0:
    return ""
  let element = editor.inspector.selectedElement.val
  var annotation = ReviewAnnotation(
    id: reviewAnnotationId(editor.review.annotations.val.len),
    text: trimmed,
    selectedElement: element,
    elementId: element.fallbackElementId(),
    elementSourceKey: element.sourceKey,
    domPath: element.domPath,
    selector: selector,
    ancestry: ancestry,
    screenshotRef: screenshotRef,
    domSnapshot: domSnapshot,
    viewport: ReviewViewportContext(
      platform: editor.platform.val,
      viewport: editor.viewport.val,
      width: previewViewportWidth(editor.viewport.val),
      height: previewViewportHeight(editor.viewport.val),
      zoom: 1.0),
    ownership: ownershipContext(editor.designSystemSchema.val, element),
    source: source,
    severity: severity,
    suggestedScope: suggestedScope,
    includedInPrompt: true,
    state: ransOpen)
  if annotation.elementId.len == 0:
    annotation.elementId = selector
  if annotation.elementSourceKey.len == 0:
    annotation.elementSourceKey = annotation.ownership.schemaKey
  editor.review.annotations.update proc(prev: seq[ReviewAnnotation]): seq[
      ReviewAnnotation] =
    result = prev
    result.add annotation
  annotation.id

proc setReviewAnnotationPromptIncluded*(review: ReviewResultsVM; id: string;
    included: bool): bool {.discardable.} =
  var found = false
  review.annotations.update proc(prev: seq[ReviewAnnotation]): seq[
      ReviewAnnotation] =
    result = prev
    for annotation in result.mitems:
      if annotation.id == id:
        annotation.includedInPrompt = included
        found = true
  found

proc setReviewAnnotationState*(review: ReviewResultsVM; id: string;
    state: ReviewAnnotationState): bool {.discardable.} =
  var found = false
  review.annotations.update proc(prev: seq[ReviewAnnotation]): seq[
      ReviewAnnotation] =
    result = prev
    for annotation in result.mitems:
      if annotation.id == id:
        annotation.state = state
        found = true
  found

proc resolveReviewAnnotation*(review: ReviewResultsVM; id: string): bool {.
    discardable.} =
  review.setReviewAnnotationState(id, ransResolved)

proc dismissReviewAnnotation*(review: ReviewResultsVM; id: string): bool {.
    discardable.} =
  review.setReviewAnnotationState(id, ransDismissed)

proc addAgentEditProposal*(chat: AgentChatVM; proposal: AgentEditProposal): string =
  var next = proposal
  if next.id.len == 0:
    next.id = agentProposalId(chat.proposedEdits.val.len)
  if next.status notin {aepsAccepted, aepsPartiallyAccepted, aepsRejected,
      aepsReverted, aepsFailed}:
    next.status = aepsProposed
  if next.validity notin {aepvNeedsRebase, aepvStale}:
    next.validity = aepvCurrent
  if next.basePendingEditCount == 0:
    next.basePendingEditCount = chat.accumulatedEdits.val.len
  if next.targetScopes.len == 0:
    for plan in next.sourceEdits:
      if plan.scope notin next.targetScopes:
        next.targetScopes.add plan.scope
  if next.affectedStories.len == 0 and next.impact.affectedStories.len > 0:
    next.affectedStories = next.impact.affectedStories
  if next.impact.summary.len == 0:
    next.impact.summary = next.summary
  if next.tests.len == 0:
    next.tests = @["source adapter review", "affected story compile/reload"]
  for plan in next.sourceEdits:
    if plan.scope == pesUnspecified:
      next.validity = aepvNeedsRebase
      next.validityDiagnostics.add AgentDiagnosticSnapshot(
        source: "proposal",
        severity: "warning",
        category: "missing-source-scope",
        message: "Agent proposal must target an explicit manual-edit source ownership scope.",
        file: plan.file,
        line: plan.line,
        property: plan.property)
  if next.selectedEditIndexes.len == 0:
    for i in 0 ..< next.sourceEdits.len:
      next.selectedEditIndexes.add i
  chat.proposedEdits.update proc(prev: seq[AgentEditProposal]): seq[
      AgentEditProposal] =
    result = prev
    result.add next
  next.id

proc addAgentPermissionRequest*(chat: AgentChatVM;
    request: AgentPermissionRequest): string =
  var next = request
  if next.id.len == 0:
    next.id = "agent-permission-" & $(chat.permissionRequests.val.len + 1)
  if next.status notin {apsGranted, apsDenied, apsCancelled}:
    next.status = apsPending
  chat.permissionRequests.update proc(prev: seq[AgentPermissionRequest]): seq[
      AgentPermissionRequest] =
    result = prev
    result.add next
  next.id

proc setAgentPermissionStatus*(chat: AgentChatVM; id: string;
    status: AgentPermissionStatus): bool {.discardable.} =
  var found = false
  chat.permissionRequests.update proc(prev: seq[AgentPermissionRequest]): seq[
      AgentPermissionRequest] =
    result = prev
    for request in result.mitems:
      if request.id == id:
        request.status = status
        found = true
  found

proc setAgentProposalStatus(chat: AgentChatVM; id: string;
    status: AgentEditProposalStatus; patches: seq[WorkspaceFilePatch] = @[]): bool =
  var found = false
  chat.proposedEdits.update proc(prev: seq[AgentEditProposal]): seq[
      AgentEditProposal] =
    result = prev
    for proposal in result.mitems:
      if proposal.id == id:
        proposal.status = status
        if patches.len > 0:
          proposal.appliedPatches = patches
        found = true
  found

proc rejectAgentProposedEdit*(editor: EditorVM; id: string): bool {.discardable.} =
  editor.chat.setAgentProposalStatus(id, aepsRejected)

proc acceptAgentProposedEdit*(editor: EditorVM; id: string;
    editIndexes: seq[int] = @[]): WorkspaceEditResult {.discardable.} =
  var proposal = AgentEditProposal()
  var found = false
  for candidate in editor.chat.proposedEdits.val:
    if candidate.id == id:
      proposal = candidate
      found = true
      break
  if not found:
    return WorkspaceEditResult(ok: false, stage: wesFailed,
      diagnostics: @[workspaceDiagnostic(wedMissingSchema,
        "Agent edit proposal was not found.")])
  if proposal.validity in {aepvNeedsRebase, aepvStale}:
    return WorkspaceEditResult(ok: false, stage: wesFailed,
      diagnostics: @[workspaceDiagnostic(wedSourceConflict,
        "Agent edit proposal must be rebased or re-run before acceptance.")])

  var selected: seq[int] =
    if editIndexes.len > 0: editIndexes else: proposal.selectedEditIndexes
  if selected.len == 0:
    for i in 0 ..< proposal.sourceEdits.len:
      selected.add i
  var accepted: seq[SourceEditPlan] = @[]
  for index in selected:
    if index >= 0 and index < proposal.sourceEdits.len:
      accepted.add proposal.sourceEdits[index]
  if accepted.len == 0:
    return WorkspaceEditResult(ok: false, stage: wesFailed,
      diagnostics: @[workspaceDiagnostic(wedMissingSchema,
        "Agent edit proposal does not contain selected source edits.")])

  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add accepted
  editor.workspaceEditStage.val = wesDirty
  result = editor.applyWorkspaceFileEdits()
  if result.ok:
    let status =
      if accepted.len == proposal.sourceEdits.len: aepsAccepted
      else: aepsPartiallyAccepted
    discard editor.chat.setAgentProposalStatus(id, status, result.patches)
  else:
    discard editor.chat.setAgentProposalStatus(id, aepsFailed)

proc revertAgentProposedEdit*(editor: EditorVM; id: string): WorkspaceEditResult {.
    discardable.} =
  var proposal = AgentEditProposal()
  var found = false
  for candidate in editor.chat.proposedEdits.val:
    if candidate.id == id:
      proposal = candidate
      found = true
      break
  if not found:
    return WorkspaceEditResult(ok: false, stage: wesFailed,
      diagnostics: @[workspaceDiagnostic(wedMissingSchema,
        "Agent edit proposal was not found.")])
  var reversals: seq[SourceEditPlan] = @[]
  for patch in proposal.appliedPatches:
    var reverse = patch.plan
    swap(reverse.oldValue, reverse.newValue)
    reverse.expectedOldValue = reverse.oldValue
    reverse.previewBefore = patch.afterContent
    reverse.previewAfter = patch.beforeContent
    reversals.add reverse
  if reversals.len == 0:
    for plan in proposal.sourceEdits:
      if plan.reversible:
        var reverse = plan
        swap(reverse.oldValue, reverse.newValue)
        reverse.expectedOldValue = reverse.oldValue
        reverse.previewBefore = plan.previewAfter
        reverse.previewAfter = plan.previewBefore
        reversals.add reverse
  if reversals.len == 0:
    return WorkspaceEditResult(ok: false, stage: wesFailed,
      diagnostics: @[workspaceDiagnostic(wedPatchFailed,
        "Agent edit proposal has no reversible source edits.")])
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add reversals
  editor.workspaceEditStage.val = wesDirty
  result = editor.applyWorkspaceFileEdits()
  if result.ok:
    discard editor.chat.setAgentProposalStatus(id, aepsReverted, result.patches)
  else:
    discard editor.chat.setAgentProposalStatus(id, aepsFailed)

proc rerunAgentProposedEdit*(editor: EditorVM; id: string): bool {.discardable.} =
  for proposal in editor.chat.proposedEdits.val:
    if proposal.id == id:
      editor.chat.inputText.val = "Re-run proposed edit: " & proposal.summary
      return editor.sendAgentPrompt()
  false

proc rebaseAgentProposedEdit*(editor: EditorVM; id: string): bool {.discardable.} =
  for proposal in editor.chat.proposedEdits.val:
    if proposal.id == id:
      editor.chat.inputText.val = "Rebase proposed edit against current pending manual edits: " &
        proposal.summary
      return editor.sendAgentPrompt()
  false

proc sendAgentPrompt*(editor: EditorVM): bool {.discardable.} =
  let prompt = editor.chat.inputText.val.strip()
  if prompt.len == 0:
    return false

  editor.chat.addUserMessage(prompt)
  editor.chat.sessionStatus.val = asLoading
  editor.chat.connectionState.val = "streaming"

  if editor.chat.promptAdapter == nil:
    editor.chat.sessionStatus.val = asError
    editor.chat.connectionState.val = "adapter-missing"
    editor.chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
      result = prev
      result.add ChatMessage(kind: cmkError,
        text: "No agent adapter configured.", timestamp: 0.0)
    return false

  let context = editor.buildAgentPromptContext()
  editor.chat.lastPromptContext.val = context
  if editor.chat.promptAdapter(prompt, context):
    if editor.chat.sessionStatus.val == asLoading:
      editor.chat.sessionStatus.val = asReady
    if editor.chat.connectionState.val == "streaming":
      editor.chat.connectionState.val = "ready"
    return true

  editor.chat.sessionStatus.val = asError
  editor.chat.connectionState.val = "error"
  false

proc cancelAgentPrompt*(editor: EditorVM): bool {.discardable.} =
  if editor.chat.cancelAdapter == nil:
    return false
  result = editor.chat.cancelAdapter()
  if result:
    editor.chat.sessionStatus.val = asIdle
    editor.chat.connectionState.val = "cancelled"
    editor.chat.stopReason.val = "cancelled"

# ===========================================================================
# ReviewResultsVM actions
# ===========================================================================

func containsLiteralColor(line: string): bool =
  let stripped = line.strip()
  if stripped.startsWith("#") or stripped.startsWith("##"):
    return false
  for i in 0 ..< stripped.len:
    if stripped[i] == '#' and i + 3 < stripped.len:
      return true

func reviewViolation(severity: ViolationSeverity; category: ViolationCategory;
    message, file: string; line: int; autoFixable: bool): Violation =
  Violation(
    severity: severity,
    category: category,
    message: message,
    file: file,
    line: line,
    autoFixable: autoFixable)

proc reviewIsoNimSources*(review: ReviewResultsVM;
    snapshots: seq[SourceSnapshot]) =
  ## Run headless source diagnostics supplied by a project adapter.
  var found: seq[Violation] = @[]
  for snapshot in snapshots:
    let lowerFile = snapshot.file.toLowerAscii()
    let vmFile = lowerFile.contains("viewmodel")
    for index, line in pairs(snapshot.content.splitLines):
      let lineNo = index + 1
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#") or stripped.startsWith("##"):
        continue

      if stripped.contains("showIf(") or stripped.contains("forIn("):
        found.add reviewViolation(
          vsWarning,
          vcDeprecatedDsl,
          "Deprecated DSL forms should be replaced with natural Nim control flow.",
          snapshot.file,
          lineNo,
          true)

      if stripped.contains("buildHtml") or stripped.contains("writeBody(\"<") or
          stripped.contains("result.add \"<") or stripped.contains("result &= \"<"):
        found.add reviewViolation(
          vsWarning,
          vcHtmlBuilder,
          "Ad hoc HTML builders bypass the IsoNim DSL rendering contract.",
          snapshot.file,
          lineNo,
          false)

      if stripped.contains("setStyle(") or stripped.contains("setStyle ="):
        found.add reviewViolation(
          vsError,
          vcDirectStyle,
          "Direct setStyle edits are unsupported by the inspector edit engine.",
          snapshot.file,
          lineNo,
          true)

      let classAssignment = "class" & " ="
      if vmFile and (stripped.contains(classAssignment) or
          stripped.contains("setStyle(") or stripped.contains("setStyle =") or
          stripped.contains("background_color") or stripped.contains(
              "border_radius") or
          stripped.contains("font_size")):
        found.add reviewViolation(
          vsError,
          vcViewModelBoundary,
          "ViewModel source must not own CSS classes or style properties.",
          snapshot.file,
          lineNo,
          true)

      if stripped.containsLiteralColor:
        found.add reviewViolation(
          vsWarning,
          vcDryTokens,
          "Literal colors should stay behind theme tokens.",
          snapshot.file,
          lineNo,
          true)

      if (stripped.contains("<img") or stripped.contains("img(")) and
          not stripped.contains("alt"):
        found.add reviewViolation(
          vsWarning,
          vcAccessibility,
          "Images need accessible alt text.",
          snapshot.file,
          lineNo,
          true)

  review.violations.val = found

# ===========================================================================
# FlowPlayerVM actions
# ===========================================================================

proc nextStep*(player: FlowPlayerVM) =
  let total = player.totalSteps.val
  if total > 0:
    player.currentStep.update proc(prev: int): int =
      if prev + 1 >= total: 0 else: prev + 1

proc prevStep*(player: FlowPlayerVM) =
  let total = player.totalSteps.val
  if total > 0:
    player.currentStep.update proc(prev: int): int =
      if prev <= 0: total - 1 else: prev - 1

proc play*(player: FlowPlayerVM) =
  player.playState.val = psPlaying

proc pause*(player: FlowPlayerVM) =
  player.playState.val = psPaused

proc stop*(player: FlowPlayerVM) =
  player.playState.val = psStopped
  player.currentStep.val = 0

# ===========================================================================
# Factory: create all ViewModels with proper reactive wiring
# ===========================================================================

proc createSidebarVM*(): SidebarVM =
  let groups = createSignal[seq[StoryGroup]](@[])
  let sections = createSignal(defaultSidebarSections())
  let searchFilter = createSignal("")

  let filteredItems = createMemo[seq[StoryGroup]](proc(): seq[StoryGroup] =
    let query = searchFilter.val.toLowerAscii()
    let allGroups = groups.val
    if query.len == 0:
      return allGroups
    result = @[]
    for g in allGroups:
      var filtered = StoryGroup(
        name: g.name,
        kind: g.kind,
        description: g.description,
        expanded: g.expanded)
      for item in g.items:
        if query in item.name.toLowerAscii() or
            query in item.description.toLowerAscii():
          filtered.items.add item
      if filtered.items.len > 0:
        result.add filtered
  )

  SidebarVM(
    groups: groups,
    sections: sections,
    searchFilter: searchFilter,
    filteredItems: filteredItems)

proc createStoryboardVM*(): StoryboardVM =
  let canvasItems = createSignal[seq[CanvasItem]](@[])
  let connections = createSignal[seq[FlowConnection]](@[])
  let zoom = createSignal(1.0)
  let panX = createSignal(0.0)
  let panY = createSignal(0.0)
  let selectedItem = createSignal(-1)
  let hoveredItem = createSignal(-1)

  StoryboardVM(
    canvasItems: canvasItems,
    connections: connections,
    zoom: zoom,
    panX: panX,
    panY: panY,
    selectedItem: selectedItem,
    hoveredItem: hoveredItem)

proc createInspectorVM*(): InspectorVM =
  let selectedElement = createSignal(ElementRef())
  let layers = createSignal[seq[ElementLayerRow]](@[])
  let layerSearch = createSignal("")
  let sectionSearch = createSignal("")
  let expandedSections = createSignal[seq[InspectorSection]](@[
    isLayout, isSpacing, isFill
  ])
  let focusedControlId = createSignal("")
  let commandPaletteHooksReady = createSignal(true)
  let expandedLayerIds = createSignal[seq[string]](@[])
  let hoveredElementId = createSignal("")
  let activeSection = createSignal(isLayout)
  let editDiagnostics = createSignal[seq[PropertyEditDiagnostic]](@[])
  let pendingSourceEdits = createSignal[seq[SourceEditPlan]](@[])
  let sourcePreviews = createSignal[seq[CSSSourcePreview]](@[])
  let conflicts = createSignal[seq[CSSSourceConflict]](@[])
  let undoStack = createSignal[seq[CSSPropertyEditTransaction]](@[])
  let redoStack = createSignal[seq[CSSPropertyEditTransaction]](@[])

  let hasElement = createMemo[bool](proc(): bool =
    selectedElement.val.tag.len > 0
  )

  let properties = createMemo[seq[PropertyInfo]](proc(): seq[PropertyInfo] =
    selectedElement.val.properties
  )

  let filteredLayers = createMemo[seq[ElementLayerRow]](proc(): seq[
      ElementLayerRow] =
    let query = layerSearch.val.strip.toLowerAscii()
    let allRows = layers.val

    func matches(row: ElementLayerRow): bool =
      if query.len == 0:
        return true
      row.label.toLowerAscii().contains(query) or
        row.tag.toLowerAscii().contains(query) or
        row.sourceFile.toLowerAscii().contains(query) or
        row.schemaKey.toLowerAscii().contains(query)

    func parentExpanded(row: ElementLayerRow): bool =
      if query.len > 0:
        return true
      var parentId = row.parentId
      while parentId.len > 0:
        var found = false
        for parent in allRows:
          if parent.id == parentId:
            if not parent.expanded:
              return false
            parentId = parent.parentId
            found = true
            break
        if not found:
          return true
      true

    for row in allRows:
      if row.matches() and row.parentExpanded():
        result.add row
  )

  let visibleSections = createMemo[seq[InspectorSection]](proc(): seq[
      InspectorSection] =
    let query = sectionSearch.val.strip.toLowerAscii()
    for section in [
      isLayout, isSize, isSpacing, isPosition, isFill, isStroke, isTypography,
      isEffects, isTransitions, isFilters, isState
    ]:
      let label = case section
        of isLayout: "layout display flex grid overflow"
        of isSize: "size width height min max flex"
        of isSpacing: "spacing space padding margin box model"
        of isPosition: "position top right bottom left z-index"
        of isFill: "fill background color gradient opacity"
        of isStroke: "stroke border radius outline"
        of isTypography: "typography type font line text"
        of isEffects: "effects shadow blur transform blend"
        of isTransitions: "transitions animation duration curve"
        of isFilters: "filters brightness contrast saturate blur"
        of isState: "state viewmodel signals"
      if query.len == 0 or label.contains(query):
        result.add section
  )

  let propertyEditors = createMemo[seq[CSSPropertyEditorVM]](proc(): seq[
      CSSPropertyEditorVM] =
    result = @[]
    for prop in selectedElement.val.properties:
      let value = parseCssPropertyValue(prop.name, prop.value)
      let category = cssPropertyCategory(prop.name)
      result.add CSSPropertyEditorVM(
        property: prop.name,
        category: category,
        value: value,
        allowedValueKinds: allowedValueKinds(category),
        origin: prop.origin,
        sourcePlanKind: prop.cssSourcePlanKind(PropertyEditRequest(
          property: prop.name,
          newValue: prop.value,
          kind: if category in {cpcLayout, cpcFlexGrid}: pekLayout else: pekCss,
          scope: if prop.sharedCount > 0: pesShared else: pesLocal,
          origin: peoInspector), value),
        sharedCount: prop.sharedCount,
        supportsLocalScope: true,
        supportsSharedScope: prop.sharedCount > 0 or prop.tokenName.len > 0 or
          prop.variantKey.len > 0 or prop.origin == poThemeToken,
        diagnostics: prop.validateCssPropertyValue(PropertyEditRequest(
          property: prop.name,
          newValue: prop.value,
          kind: pekCss,
          scope: if prop.sharedCount > 0: pesShared else: pesLocal,
          origin: peoInspector), value))
  )

  let isDirty = createMemo[bool](proc(): bool =
    pendingSourceEdits.val.len > 0 or undoStack.val.len > 0
  )

  let denseRowContract = createMemo[InspectorDenseRowContract](
    proc(): InspectorDenseRowContract =
      InspectorDenseRowContract(
        maxHeightPx: 30,
        slots: @[
          icsLabel,
          icsScrubValue,
          icsUnitSelector,
          icsBindingIndicator,
          icsScopeIndicator,
          icsReset,
          icsMoreMenu
        ],
        rejectsDebugFormLayout: true)
  )

  let largeControlContracts = createMemo[seq[InspectorLargeControlContract]](
    proc(): seq[InspectorLargeControlContract] =
      for kind in [
        ilcColorPlane, ilcBoxModel, ilcShadow, ilcGradient,
        ilcTypographyDetail, ilcTransitionCurve, ilcRawCss, ilcSourceCascade
      ]:
        result.add InspectorLargeControlContract(
          kind: kind,
          container: if kind == ilcSourceCascade: "popover" else: "accordion",
          inlineInDenseRow: false)
  )

  let displayMode = createSignal(dmFlex)
  let flexDirection = createSignal(fdRow)

  InspectorVM(
    selectedElement: selectedElement,
    layers: layers,
    layerSearch: layerSearch,
    sectionSearch: sectionSearch,
    expandedSections: expandedSections,
    focusedControlId: focusedControlId,
    commandPaletteHooksReady: commandPaletteHooksReady,
    expandedLayerIds: expandedLayerIds,
    hoveredElementId: hoveredElementId,
    activeSection: activeSection,
    editDiagnostics: editDiagnostics,
    pendingSourceEdits: pendingSourceEdits,
    sourcePreviews: sourcePreviews,
    conflicts: conflicts,
    undoStack: undoStack,
    redoStack: redoStack,
    hasElement: hasElement,
    properties: properties,
    filteredLayers: filteredLayers,
    visibleSections: visibleSections,
    propertyEditors: propertyEditors,
    denseRowContract: denseRowContract,
    largeControlContracts: largeControlContracts,
    isDirty: isDirty,
    displayMode: displayMode,
    flexDirection: flexDirection)

func hasCapability*(adapter: VectorAdapterContract;
    capability: VectorAdapterCapability): bool =
  capability in adapter.capabilities

func vectorLibrarySpike*(): seq[VectorLibraryCandidate] =
  ## Current M29 selection record. Browser editing uses Fabric for mature
  ## interaction primitives and SVGO for optimization in tooling/browser paths.
  @[
    VectorLibraryCandidate(
      name: "Fabric.js",
      version: "7.3.1",
      license: "MIT",
      backend: vbFabric,
      capabilities: @[
        vacSelection, vacHitTesting, vacTransformControls, vacDrawingTools,
        vacTextEditing, vacGrouping, vacLayerOrdering, vacSerialization,
        vacSvgImport, vacSvgExport
      ],
      runtimeNotes: "Canvas-backed browser object model with built-in selection, transforms, grouping, drawing tools, SVG import/export, and serialization.",
      interopNotes: "Loaded as a local UMD browser bundle and isolated behind isonim/editor/browser_vector_adapter.",
    selected: true,
    selectionReason: "Best coverage of interaction primitives without hand-rolled pointer geometry."),
    VectorLibraryCandidate(
      name: "Paper.js",
      version: "0.12.18",
      license: "MIT",
      backend: vbPaperJs,
      capabilities: @[vacPathEditing, vacPathBooleanOps, vacPathDataEditing,
        vacSerialization, vacSvgImport, vacSvgExport],
      runtimeNotes: "Supplemental path engine with official PathItem boolean operations and segment/pathData APIs.",
      interopNotes: "Loaded as a local browser bundle and used only through the supplemental path backend boundary; Fabric remains the canvas interaction backend.",
      selected: true,
      selectionReason: "Mature boolean/path-data operations without hand-rolled boolean algorithms or path geometry."),
    VectorLibraryCandidate(
      name: "SVGO",
      version: "4.0.1",
      license: "MIT",
      backend: vbFabric,
      capabilities: @[vacOptimization, vacSerialization],
      runtimeNotes: "Optimization library paired with Fabric export/import.",
      interopNotes: "Copied as a browser-capable bundle for future direct browser optimization; headless VM currently uses deterministic safe normalization.",
      selected: true,
      selectionReason: "Mature optimizer for SVG source cleanup."),
    VectorLibraryCandidate(
      name: "SVG.js plus plugins",
      version: "3.2.5",
      license: "MIT",
      backend: vbSvgJsPlugins,
      capabilities: @[vacSerialization, vacSvgImport, vacSvgExport],
      runtimeNotes: "DOM-native SVG manipulation is useful, but core package does not provide complete editor-grade selection, transform controls, drawing, grouping, and pointer geometry.",
      interopNotes: "Rejected as sole backend for M29; can remain a future supplemental DOM layer if needed.",
      selected: false,
      selectionReason: "Insufficient by itself for a mature full editor interaction stack."),
    VectorLibraryCandidate(
      name: "Method Draw / SVG-Edit family",
      version: "maintained forks vary",
      license: "MIT-compatible in common forks",
      backend: vbMethodDraw,
      capabilities: @[vacSelection, vacHitTesting, vacTransformControls,
        vacDrawingTools, vacPathEditing, vacTextEditing, vacGrouping,
        vacLayerOrdering, vacSvgImport, vacSvgExport],
      runtimeNotes: "Complete editor lineage, but harder to integrate as a small typed adapter and less aligned with the current Nim-generated shell.",
      interopNotes: "Credible future replacement if path-node editing becomes the dominant requirement.",
      selected: false,
      selectionReason: "Larger embedded app surface than needed for IsoNim's framework-owned VM contract.")
  ]

func selectedVectorAdapter*(): VectorAdapterContract =
  VectorAdapterContract(
    backend: vbFabric,
    libraryName: "Fabric.js",
    libraryVersion: "7.3.1",
    adapterModule: "isonim/editor/browser_vector_adapter",
    browserGlobal: "fabric",
    license: "MIT",
    capabilities: @[
      vacSelection, vacHitTesting, vacTransformControls, vacDrawingTools,
      vacTextEditing, vacGrouping, vacLayerOrdering, vacSerialization,
      vacSvgImport, vacSvgExport, vacAccessibilityMetadata, vacOptimization,
      vacPathEditing, vacPathDataEditing
    ],
    usesThirdPartyInteraction: true,
    unsupportedAdvancedOperations: @[
      "Arbitrary SVG clipping, masks, filters, and patterns are diagnosed before source commits until a mature adapter path preserves them.",
      "Boolean/path operations outside unite/subtract/intersect/exclude remain disabled until backed by Paper.js or another mature supplemental path library."
    ])

func selectedVectorPathBackend*(): VectorPathBackendContract =
  VectorPathBackendContract(
    backend: vbPaperJs,
    libraryName: "Paper.js",
    libraryVersion: "0.12.18",
    browserGlobal: "paper",
    license: "MIT",
    operations: @[vpboUnite, vpboSubtract, vpboIntersect, vpboExclude,
      vpboMoveSegment],
    adapterModule: "isonim/editor/browser_vector_adapter",
    sourceBacked: true)

func symbolSchemaKey(symbol: VectorSymbol): string =
  "symbols." & symbol.name.normalize & ".svg"

func sourceFor(symbol: VectorSymbol): VectorSourceOrigin =
  VectorSourceOrigin(
    symbolKey: symbol.name,
    schemaKey: symbol.symbolSchemaKey,
    sourceMapKey: symbol.symbolSchemaKey)

func defaultVectorA11y(symbol: VectorSymbol): VectorAccessibilityMeta =
  VectorAccessibilityMeta(
    title: symbol.name,
    desc: symbol.category & " vector symbol",
    ariaLabel: symbol.name,
    role: varSemantic,
    focusable: false)

func vectorAttr(source, name: string): string =
  let key = name & "=\""
  var cursor = 0
  while true:
    let start = source.find(key, cursor)
    if start < 0:
      return ""
    let boundaryOk = start == 0 or source[start - 1] in {' ', '<', '\t', '\n',
        '\r'}
    if boundaryOk:
      let valueStart = start + key.len
      let valueEnd = source.find("\"", valueStart)
      if valueEnd < 0:
        return ""
      return source[valueStart ..< valueEnd]
    cursor = start + key.len

func vectorFloatAttr(source, name: string; fallback: float): float =
  let raw = source.vectorAttr(name)
  if raw.len == 0:
    return fallback
  try:
    raw.parseFloat
  except ValueError:
    fallback

func strokeCapFromString(value: string): StrokeCapStyle =
  case value.toLowerAscii
  of "round": scRound
  of "square": scSquare
  else: scButt

func strokeJoinFromString(value: string): StrokeJoinStyle =
  case value.toLowerAscii
  of "round": sjRound
  of "bevel": sjBevel
  else: sjMiter

func rotationFromTransform(value: string): float =
  let lower = value.toLowerAscii.strip
  if not lower.startsWith("rotate("):
    return 0
  let start = lower.find("(")
  let stop = lower.find(")", start + 1)
  if start < 0 or stop < 0:
    return 0
  let parts = lower[start + 1 ..< stop].splitWhitespace
  if parts.len == 0:
    return 0
  try:
    parts[0].parseFloat
  except ValueError:
    0

func strokeCapName(value: StrokeCapStyle): string =
  case value
  of scRound: "round"
  of scSquare: "square"
  else: "butt"

func strokeJoinName(value: StrokeJoinStyle): string =
  case value
  of sjRound: "round"
  of sjBevel: "bevel"
  else: "miter"

func vectorObjectBase(id, name: string; kind: VectorShapeKind;
    source: VectorSourceOrigin; a11y: VectorAccessibilityMeta): VectorObject =
  VectorObject(id: id, name: name, kind: kind, layerId: "base",
    fill: "none", stroke: "currentColor", strokeWidth: 1, opacity: 1,
    strokeCap: scButt, strokeJoin: sjMiter, source: source, a11y: a11y)

func vectorNodeId(index: int): string =
  "node-" & $index

func defaultCheckPathNodes*(): seq[VectorPathNode] =
  @[
    VectorPathNode(id: "node-0", x: 4, y: 12, nodeType: ntCorner),
    VectorPathNode(id: "node-1", x: 9, y: 17, nodeType: ntCorner),
    VectorPathNode(id: "node-2", x: 20, y: 6, nodeType: ntCorner)
  ]

func pathTokens(pathData: string): seq[string] =
  var i = 0
  while i < pathData.len:
    let ch = pathData[i]
    if ch.isAlphaAscii:
      result.add $ch
      inc i
    elif ch in {' ', '\t', '\n', '\r', ','}:
      inc i
    elif ch in {'+', '-', '.', '0' .. '9'}:
      let start = i
      inc i
      while i < pathData.len:
        let next = pathData[i]
        if next in {'0' .. '9', '.'}:
          inc i
        elif next in {'e', 'E'}:
          inc i
          if i < pathData.len and pathData[i] in {'+', '-'}:
            inc i
        else:
          break
      result.add pathData[start ..< i]
    else:
      return @[]

func isPathCommand(token: string): bool =
  token.len == 1 and token[0].isAlphaAscii

func parsePathNumber(token: string; value: var float): bool =
  try:
    value = token.parseFloat
    true
  except ValueError:
    false

func pathNodesFromPathData*(pathData: string): seq[VectorPathNode] =
  ## Parse the subset the headless ViewModel can edit without losing fidelity.
  ## Unsupported SVG path syntax leaves pathNodes empty, preserving pathData.
  let tokens = pathData.pathTokens
  if tokens.len == 0:
    return @[]

  var pos = 0
  var command = '\0'
  var currentX = 0.0
  var currentY = 0.0
  var started = false
  var seenMove = false
  var nodes: seq[VectorPathNode] = @[]

  func atCommand(): bool =
    pos < tokens.len and tokens[pos].isPathCommand

  proc readNumber(value: var float): bool =
    if pos >= tokens.len or tokens[pos].isPathCommand:
      return false
    result = tokens[pos].parsePathNumber(value)
    inc pos

  proc addCorner(x, y: float) =
    nodes.add VectorPathNode(id: vectorNodeId(nodes.len), x: x, y: y,
      inX: x, inY: y, outX: x, outY: y, nodeType: ntCorner)
    currentX = x
    currentY = y
    started = true

  while pos < tokens.len:
    if tokens[pos].isPathCommand:
      command = tokens[pos][0]
      inc pos
    if command == '\0':
      return @[]

    case command
    of 'M', 'm':
      if seenMove:
        return @[]
      var x, y: float
      if not readNumber(x) or not readNumber(y):
        return @[]
      if command == 'm' and started:
        x += currentX
        y += currentY
      addCorner(x, y)
      seenMove = true
      command = if command == 'm': 'l' else: 'L'
    of 'L', 'l':
      while pos < tokens.len and not atCommand():
        var x, y: float
        if not readNumber(x) or not readNumber(y):
          return @[]
        if command == 'l':
          x += currentX
          y += currentY
        addCorner(x, y)
    of 'H', 'h':
      while pos < tokens.len and not atCommand():
        var x: float
        if not readNumber(x):
          return @[]
        if command == 'h':
          x += currentX
        addCorner(x, currentY)
    of 'V', 'v':
      while pos < tokens.len and not atCommand():
        var y: float
        if not readNumber(y):
          return @[]
        if command == 'v':
          y += currentY
        addCorner(currentX, y)
    of 'C', 'c':
      if not started or nodes.len == 0:
        return @[]
      while pos < tokens.len and not atCommand():
        var x1, y1, x2, y2, x, y: float
        if not readNumber(x1) or not readNumber(y1) or
            not readNumber(x2) or not readNumber(y2) or
            not readNumber(x) or not readNumber(y):
          return @[]
        if command == 'c':
          x1 += currentX
          y1 += currentY
          x2 += currentX
          y2 += currentY
          x += currentX
          y += currentY
        nodes[^1].outX = x1
        nodes[^1].outY = y1
        nodes[^1].nodeType = ntAsymmetric
        nodes.add VectorPathNode(id: vectorNodeId(nodes.len), x: x, y: y,
          inX: x2, inY: y2, outX: x, outY: y, nodeType: ntAsymmetric)
        currentX = x
        currentY = y
    else:
      return @[]

  if nodes.len < 2:
    return @[]
  nodes

func pathDataFromNodes*(nodes: seq[VectorPathNode]): string =
  if nodes.len == 0:
    return ""
  result = "M" & $nodes[0].x & " " & $nodes[0].y
  for i in 1 ..< nodes.len:
    let prev = nodes[i - 1]
    let node = nodes[i]
    if node.nodeType in {ntSmooth, ntAsymmetric} or
        prev.nodeType in {ntSmooth, ntAsymmetric}:
      result.add "C" & $prev.outX & " " & $prev.outY & " " &
        $node.inX & " " & $node.inY & " " & $node.x & " " & $node.y
    else:
      result.add "L" & $node.x & " " & $node.y

func pathDataForObject(obj: VectorObject): string =
  obj.pathData

func vectorDocumentFromSymbol*(symbol: VectorSymbol): VectorDocument =
  let source = sourceFor(symbol)
  let width = if symbol.width > 0: symbol.width else: 24.0
  let height = if symbol.height > 0: symbol.height else: 24.0
  VectorDocument(
    id: symbol.name.normalize,
    name: symbol.name,
    viewBox: "0 0 " & $width & " " & $height,
    width: width,
    height: height,
    layers: @[VectorLayer(id: "base", name: "Base", visible: true,
      locked: false, objectIds: @["path-1"])],
    objects: @[VectorObject(
      id: "path-1",
      name: symbol.name & " path",
      kind: vskPath,
      layerId: "base",
      x: 0,
      y: 0,
      width: width,
      height: height,
      pathData: "M4 12l5 5L20 6",
      pathNodes: defaultCheckPathNodes(),
      fill: "none",
      stroke: "currentColor",
      strokeWidth: 2,
      strokeCap: scRound,
      strokeJoin: sjRound,
      opacity: 1,
      source: source,
      a11y: defaultVectorA11y(symbol))],
    symbols: @[VectorSymbolDefinition(id: symbol.name.normalize,
      name: symbol.name,
      svgContent: symbol.svgContent,
      source: source,
      a11y: defaultVectorA11y(symbol))],
    selectedIds: @[],
    source: source,
    a11y: defaultVectorA11y(symbol))

func objectIndex(doc: VectorDocument; id: string): int =
  for i, item in doc.objects:
    if item.id == id:
      return i
  -1

func layerIndex(doc: VectorDocument; id: string): int =
  for i, layer in doc.layers:
    if layer.id == id:
      return i
  -1

func escapeSvg(value: string): string =
  value.replace("&", "&amp;").replace("\"", "&quot;").replace("<", "&lt;").
    replace(">", "&gt;")

func renderVectorObject(obj: VectorObject): string =
  let transform =
    if obj.rotation != 0:
      " transform=\"rotate(" & $obj.rotation & " " & $(obj.x + obj.width / 2) &
        " " & $(obj.y + obj.height / 2) & ")\""
    else:
      ""
  let commonPaint = " fill=\"" & obj.fill.escapeSvg & "\" stroke=\"" &
    obj.stroke.escapeSvg & "\" stroke-width=\"" & $obj.strokeWidth &
    "\" stroke-linecap=\"" & obj.strokeCap.strokeCapName &
    "\" stroke-linejoin=\"" & obj.strokeJoin.strokeJoinName &
    "\" opacity=\"" & $obj.opacity & "\""
  let dash =
    if obj.dashArray.len > 0: " stroke-dasharray=\"" &
        obj.dashArray.escapeSvg & "\""
    else: ""
  let blend =
    if obj.blendMode.len > 0: " style=\"mix-blend-mode:" &
        obj.blendMode.escapeSvg & "\""
    else: ""
  case obj.kind
  of vskRect:
    "<rect id=\"" & obj.id.escapeSvg & "\" x=\"" & $obj.x & "\" y=\"" & $obj.y &
      "\" width=\"" & $obj.width & "\" height=\"" & $obj.height &
      "\"" & commonPaint & dash & transform & blend & " />"
  of vskEllipse:
    "<ellipse id=\"" & obj.id.escapeSvg & "\" cx=\"" & $(obj.x + obj.width / 2) &
      "\" cy=\"" & $(obj.y + obj.height / 2) & "\" rx=\"" & $(obj.width / 2) &
      "\" ry=\"" & $(obj.height / 2) & "\"" & commonPaint & dash & transform &
      blend & " />"
  of vskLine:
    "<line id=\"" & obj.id.escapeSvg & "\" x1=\"" & $obj.x & "\" y1=\"" & $obj.y &
      "\" x2=\"" & $(obj.x + obj.width) & "\" y2=\"" & $(obj.y + obj.height) &
      "\" fill=\"none\" stroke=\"" & obj.stroke.escapeSvg &
      "\" stroke-width=\"" & $obj.strokeWidth & "\" stroke-linecap=\"" &
      obj.strokeCap.strokeCapName & "\" stroke-linejoin=\"" &
      obj.strokeJoin.strokeJoinName & "\"" & dash & transform & blend & " />"
  of vskPolygon, vskStar:
    "<path id=\"" & obj.id.escapeSvg & "\" d=\"" & obj.pathDataForObject.escapeSvg &
      "\"" & commonPaint & dash & transform & blend & " />"
  of vskText:
    "<text id=\"" & obj.id.escapeSvg & "\" x=\"" & $obj.x & "\" y=\"" & $obj.y &
      "\" fill=\"" & obj.fill.escapeSvg & "\"" & transform & ">" &
      obj.text.escapeSvg & "</text>"
  of vskGroup:
    "<g id=\"" & obj.id.escapeSvg & "\"" & transform & "></g>"
  of vskSymbolUse:
    "<use id=\"" & obj.id.escapeSvg & "\" href=\"#" & obj.symbolRef.escapeSvg &
      "\" x=\"" & $obj.x & "\" y=\"" & $obj.y & "\"" & transform & " />"
  of vskPath:
    "<path id=\"" & obj.id.escapeSvg & "\" d=\"" & obj.pathDataForObject.escapeSvg &
      "\"" & commonPaint & dash & transform & blend & " />"

func renderVectorDefs(doc: VectorDocument): string =
  var defs = ""
  for obj in doc.objects:
    if obj.gradient.len > 0 and defs.find("id=\"" & obj.gradient.escapeSvg & "\"") < 0:
      defs.add "<linearGradient id=\"" & obj.gradient.escapeSvg &
        "\" x1=\"0%\" y1=\"0%\" x2=\"100%\" y2=\"100%\">" &
        "<stop offset=\"0%\" stop-color=\"#60A5FA\" />" &
        "<stop offset=\"100%\" stop-color=\"#1D4ED8\" />" &
        "</linearGradient>"
  if defs.len == 0:
    return ""
  "<defs>" & defs & "</defs>"

func exportVectorDocumentSvg*(doc: VectorDocument): string =
  var body = ""
  if doc.a11y.title.len > 0:
    body.add "<title>" & doc.a11y.title.escapeSvg & "</title>"
  if doc.a11y.desc.len > 0:
    body.add "<desc>" & doc.a11y.desc.escapeSvg & "</desc>"
  body.add doc.renderVectorDefs
  for symbol in doc.symbols:
    if symbol.svgContent.len > 0:
      body.add "<symbol id=\"" & symbol.id.escapeSvg & "\">" &
        symbol.svgContent & "</symbol>"
  for layer in doc.layers:
    if not layer.visible:
      continue
    body.add "<g id=\"" & layer.id.escapeSvg & "\" data-layer=\"" &
      layer.name.escapeSvg & "\">"
    for objectId in layer.objectIds:
      let idx = doc.objectIndex(objectId)
      if idx >= 0:
        body.add renderVectorObject(doc.objects[idx])
    body.add "</g>"
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"" & doc.viewBox.escapeSvg &
    "\" width=\"" & $doc.width & "\" height=\"" & $doc.height &
    "\" role=\"" & (if doc.a11y.role == varDecorative: "presentation" else: "img") &
    "\" aria-label=\"" & doc.a11y.ariaLabel.escapeSvg & "\">" & body & "</svg>"

func optimizeVectorSvg*(svg: string): string =
  svg.replace("\n", "").replace("  ", " ").replace("> <", "><").strip()

func importedObjectFromTag(tag: string; index: int; source: VectorSourceOrigin;
    a11y: VectorAccessibilityMeta): VectorObject =
  let id = if tag.vectorAttr("id").len > 0: tag.vectorAttr("id") else: "import-" & $index
  var obj = vectorObjectBase(id, id, vskPath, source, a11y)
  obj.fill = tag.vectorAttr("fill")
  if obj.fill.len == 0:
    obj.fill = "none"
  obj.stroke = tag.vectorAttr("stroke")
  if obj.stroke.len == 0:
    obj.stroke = "currentColor"
  obj.strokeWidth = tag.vectorFloatAttr("stroke-width", 1)
  obj.opacity = tag.vectorFloatAttr("opacity", 1)
  obj.dashArray = tag.vectorAttr("stroke-dasharray")
  obj.strokeCap = tag.vectorAttr("stroke-linecap").strokeCapFromString
  obj.strokeJoin = tag.vectorAttr("stroke-linejoin").strokeJoinFromString
  obj.blendMode = tag.vectorAttr("mix-blend-mode")
  obj.rotation = tag.vectorAttr("transform").rotationFromTransform
  if tag.startsWith("<rect"):
    obj.kind = vskRect
    obj.x = tag.vectorFloatAttr("x", 0)
    obj.y = tag.vectorFloatAttr("y", 0)
    obj.width = tag.vectorFloatAttr("width", 0)
    obj.height = tag.vectorFloatAttr("height", 0)
  elif tag.startsWith("<circle"):
    let r = tag.vectorFloatAttr("r", 0)
    obj.kind = vskEllipse
    obj.x = tag.vectorFloatAttr("cx", r) - r
    obj.y = tag.vectorFloatAttr("cy", r) - r
    obj.width = r * 2
    obj.height = r * 2
  elif tag.startsWith("<ellipse"):
    let rx = tag.vectorFloatAttr("rx", 0)
    let ry = tag.vectorFloatAttr("ry", 0)
    obj.kind = vskEllipse
    obj.x = tag.vectorFloatAttr("cx", rx) - rx
    obj.y = tag.vectorFloatAttr("cy", ry) - ry
    obj.width = rx * 2
    obj.height = ry * 2
  elif tag.startsWith("<line"):
    let x1 = tag.vectorFloatAttr("x1", 0)
    let y1 = tag.vectorFloatAttr("y1", 0)
    obj.kind = vskLine
    obj.x = x1
    obj.y = y1
    obj.width = tag.vectorFloatAttr("x2", x1) - x1
    obj.height = tag.vectorFloatAttr("y2", y1) - y1
  else:
    obj.kind = vskPath
    obj.pathData = tag.vectorAttr("d")
    if obj.pathData.len > 0:
      obj.pathNodes = obj.pathData.pathNodesFromPathData
  obj

func importVectorDocumentSvg*(symbol: VectorSymbol; svg: string): VectorDocument =
  let base = symbol.vectorDocumentFromSymbol
  if "<svg" notin svg and "<path" notin svg and "<rect" notin svg and
      "<circle" notin svg and "<ellipse" notin svg and "<line" notin svg:
    return base
  let sourceSvg =
    if "<svg" in svg:
      svg
    else:
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 " &
        $base.width & " " & $base.height & "\">" & svg & "</svg>"
  var doc = base
  doc.objects = @[]
  doc.layers = @[VectorLayer(id: "base", name: "Base", visible: true,
    locked: false, objectIds: @[])]
  doc.symbols = @[VectorSymbolDefinition(id: symbol.name.normalize,
    name: symbol.name, svgContent: svg, source: doc.source, a11y: doc.a11y)]
  let svgOpenEnd = sourceSvg.find(">")
  if svgOpenEnd >= 0:
    let openTag = sourceSvg[0 .. svgOpenEnd]
    let importedViewBox = openTag.vectorAttr("viewBox")
    if importedViewBox.len > 0:
      doc.viewBox = importedViewBox
    doc.width = openTag.vectorFloatAttr("width", doc.width)
    doc.height = openTag.vectorFloatAttr("height", doc.height)
  var index = 0
  for tagName in ["rect", "circle", "ellipse", "line", "path"]:
    var cursor = 0
    while true:
      let start = sourceSvg.find("<" & tagName, cursor)
      if start < 0:
        break
      let stop = sourceSvg.find(">", start)
      if stop < 0:
        break
      inc index
      let tag = sourceSvg[start .. stop]
      let obj = importedObjectFromTag(tag, index, doc.source, doc.a11y)
      doc.objects.add obj
      doc.layers[0].objectIds.add obj.id
      cursor = stop + 1
  if doc.objects.len == 0:
    doc.objects = base.objects
    doc.layers = base.layers
  doc.selectedIds = if doc.objects.len > 0: @[doc.objects[0].id] else: @[]
  doc

func vectorSourcePlan(doc: VectorDocument; beforeSvg, afterSvg: string;
    expectedOldValue = beforeSvg): SourceEditPlan =
  SourceEditPlan(
    file: doc.source.file,
    property: "svgContent",
    oldValue: beforeSvg,
    newValue: afterSvg,
    originDetail: "vector-symbol:" & doc.name,
    scope: pesShared,
    planKind: cspStructuredSchemaUpdate,
    schemaKey: doc.source.schemaKey,
    reversible: true,
    previewBefore: beforeSvg,
    previewAfter: afterSvg,
    formatterHook: "svgo",
    regeneratorHook: "vector-symbol",
    conflictKey: doc.source.schemaKey,
    expectedOldValue: expectedOldValue)

func validateVectorAccessibility*(doc: VectorDocument): seq[VectorDiagnostic] =
  if doc.a11y.role != varDecorative:
    if doc.a11y.title.len == 0:
      result.add VectorDiagnostic(kind: vdkMissingTitle,
        message: "Semantic SVG symbols need a title.",
        schemaKey: doc.source.schemaKey)
    if doc.a11y.desc.len == 0:
      result.add VectorDiagnostic(kind: vdkMissingDescription,
        message: "Semantic SVG symbols need a desc.",
        schemaKey: doc.source.schemaKey)
    if doc.a11y.ariaLabel.len == 0:
      result.add VectorDiagnostic(kind: vdkMissingAria,
        message: "Semantic SVG symbols need an ARIA label.",
        schemaKey: doc.source.schemaKey)
  if doc.a11y.role == varDecorative and doc.a11y.focusable:
    result.add VectorDiagnostic(kind: vdkInvalidFocusability,
      message: "Decorative SVG symbols must not be focusable.",
      schemaKey: doc.source.schemaKey)
  for obj in doc.objects:
    if obj.fill == obj.stroke and obj.fill.len > 0 and obj.fill != "none":
      result.add VectorDiagnostic(kind: vdkContrastViolation,
        message: "Vector fill and stroke are identical; verify contrast.",
        objectId: obj.id,
        schemaKey: obj.source.schemaKey)

func diagnoseUnsupportedVectorSvgFeatures*(svg: string;
    schemaKey = ""): seq[VectorDiagnostic] =
  let lower = svg.toLowerAscii
  for feature in ["<clippath", "<mask", "<filter", "<pattern", "<foreignobject"]:
    if feature in lower:
      let label = feature.replace("<", "").replace("path", "Path")
      result.add VectorDiagnostic(kind: vdkUnsupportedOperation,
        message: "Unsupported SVG feature '" & label &
          "' requires a preserving third-party vector adapter before saving.",
        schemaKey: schemaKey)
  if "clip-path=" in lower or "clip-path:" in lower:
    result.add VectorDiagnostic(kind: vdkUnsupportedOperation,
      message: "Unsupported SVG clip-path reference requires a preserving third-party vector adapter before saving.",
      schemaKey: schemaKey)
  if "mask=" in lower or "mask:" in lower:
    result.add VectorDiagnostic(kind: vdkUnsupportedOperation,
      message: "Unsupported SVG mask reference requires a preserving third-party vector adapter before saving.",
      schemaKey: schemaKey)
  if "filter=" in lower or "filter:" in lower:
    result.add VectorDiagnostic(kind: vdkUnsupportedOperation,
      message: "Unsupported SVG filter reference requires a preserving third-party vector adapter before saving.",
      schemaKey: schemaKey)

func sourceSvgForDiagnostics(doc: VectorDocument): string =
  if doc.symbols.len > 0 and doc.symbols[0].svgContent.len > 0:
    return doc.symbols[0].svgContent
  doc.exportVectorDocumentSvg

func diagnoseUnsupportedVectorPathEditing*(doc: VectorDocument): seq[VectorDiagnostic] =
  for obj in doc.objects:
    if obj.kind == vskPath and obj.pathData.len > 0 and obj.pathNodes.len == 0:
      result.add VectorDiagnostic(kind: vdkUnsupportedOperation,
        message: "Path node editing is disabled for '" & obj.id &
          "' because its SVG path data uses syntax outside the supported " &
          "source-preserving path-node subset; original pathData is preserved.",
        objectId: obj.id,
        schemaKey: obj.source.schemaKey)

proc commitVectorDocument(editor: EditorVM; operation: VectorOperationKind;
    beforeDoc, afterDoc: VectorDocument): VectorOperationResult =
  let unsupportedSource =
    beforeDoc.sourceSvgForDiagnostics & "\n" & afterDoc.sourceSvgForDiagnostics
  let unsupported = unsupportedSource.diagnoseUnsupportedVectorSvgFeatures(
    afterDoc.source.schemaKey)
  if unsupported.len > 0:
    editor.vectorEditor.diagnostics.val = unsupported
    return VectorOperationResult(ok: false, operation: operation,
      document: beforeDoc, diagnostics: unsupported)

  let beforeSvg = beforeDoc.exportVectorDocumentSvg.optimizeVectorSvg
  let afterSvg = afterDoc.exportVectorDocumentSvg.optimizeVectorSvg
  let plan = afterDoc.vectorSourcePlan(beforeSvg, afterSvg)
  editor.vectorEditor.document.val = afterDoc
  editor.vectorEditor.diagnostics.val = afterDoc.validateVectorAccessibility()
  editor.vectorEditor.undoStack.update proc(prev: seq[VectorEditTransaction]): seq[
      VectorEditTransaction] =
    result = prev
    result.add VectorEditTransaction(operation: operation,
      beforeDocument: beforeDoc,
      afterDocument: afterDoc,
      sourceEdit: plan)
  editor.vectorEditor.redoStack.val = @[]
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.workspaceEditStage.val = wesDirty
  VectorOperationResult(ok: true, operation: operation, document: afterDoc,
    sourceEdit: plan, diagnostics: editor.vectorEditor.diagnostics.val)

proc commitVectorSourceSnapshot*(editor: EditorVM; operation: VectorOperationKind;
    exportedSvg: string; requireExpectedOldValue = true): VectorOperationResult {.discardable.} =
  ## Bridge a mature browser vector adapter export back into the headless
  ## source-edit journal. The browser owns interaction geometry; the ViewModel
  ## owns the persisted SVG snapshot and M27 save transaction.
  let normalized = exportedSvg.optimizeVectorSvg
  if normalized.len == 0 or "<svg" notin normalized:
    return VectorOperationResult(ok: false, operation: operation,
      diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
        message: "Browser vector adapter did not provide an SVG export.")])

  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.source.schemaKey.len == 0:
    return VectorOperationResult(ok: false, operation: operation,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingDocument,
        message: "Select a source-backed vector symbol before editing.")])

  let unsupportedSource = beforeDoc.sourceSvgForDiagnostics & "\n" & normalized
  let unsupported = unsupportedSource.diagnoseUnsupportedVectorSvgFeatures(
    beforeDoc.source.schemaKey)
  if unsupported.len > 0:
    editor.vectorEditor.diagnostics.val = unsupported
    return VectorOperationResult(ok: false, operation: operation,
      document: beforeDoc, diagnostics: unsupported)

  let beforeSvg = beforeDoc.exportVectorDocumentSvg.optimizeVectorSvg
  var afterDoc = beforeDoc
  if afterDoc.symbols.len == 0:
    afterDoc.symbols.add VectorSymbolDefinition(id: afterDoc.id,
      name: afterDoc.name, source: afterDoc.source, a11y: afterDoc.a11y)
  afterDoc.symbols[0].svgContent = normalized
  let expected = if requireExpectedOldValue: beforeSvg else: ""
  let plan = afterDoc.vectorSourcePlan(beforeSvg, normalized, expected)

  editor.vectorEditor.document.val = afterDoc
  editor.vectorEditor.diagnostics.val = afterDoc.validateVectorAccessibility()
  editor.vectorEditor.undoStack.update proc(prev: seq[VectorEditTransaction]): seq[
      VectorEditTransaction] =
    result = prev
    result.add VectorEditTransaction(operation: operation,
      beforeDocument: beforeDoc,
      afterDocument: afterDoc,
      sourceEdit: plan)
  editor.vectorEditor.redoStack.val = @[]
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  editor.workspaceEditStage.val = wesDirty
  VectorOperationResult(ok: true, operation: operation, document: afterDoc,
    sourceEdit: plan, diagnostics: editor.vectorEditor.diagnostics.val)

proc commitBrowserVectorSvg*(editor: EditorVM;
    exportedSvg: string): VectorOperationResult {.discardable.} =
  editor.commitVectorSourceSnapshot(vokExportSvg, exportedSvg,
    requireExpectedOldValue = false)

proc commitSupplementalVectorPathSvg*(editor: EditorVM; operationName,
    exportedSvg: string): VectorOperationResult {.discardable.} =
  let normalized = exportedSvg.optimizeVectorSvg
  if "<path" notin normalized:
    return VectorOperationResult(ok: false, operation: vokBooleanPath,
      diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
        message: "Supplemental path backend must return SVG path data for " &
          operationName & ".")])
  editor.commitVectorSourceSnapshot(vokBooleanPath, normalized,
    requireExpectedOldValue = false)

proc commitSupplementalPathSegmentMoveSvg*(editor: EditorVM;
    exportedSvg: string): VectorOperationResult {.discardable.} =
  let normalized = exportedSvg.optimizeVectorSvg
  if "<path" notin normalized:
    return VectorOperationResult(ok: false, operation: vokMovePathSegment,
      diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
        message: "Supplemental path backend must return SVG path data for segment moves.")])
  editor.commitVectorSourceSnapshot(vokMovePathSegment, normalized,
    requireExpectedOldValue = false)

proc unsupportedVectorOperation*(editor: EditorVM;
    operationName: string): VectorOperationResult {.discardable.} =
  let message = operationName &
    " is not exposed until Fabric or a mature supplemental path library " &
    "backs the operation."
  let diagnostics = @[VectorDiagnostic(kind: vdkUnsupportedOperation,
    message: message)]
  editor.vectorEditor.diagnostics.val = diagnostics
  VectorOperationResult(ok: false, operation: vokOptimizeSvg,
    document: editor.vectorEditor.document.val, diagnostics: diagnostics)

proc duplicateVectorSelection*(editor: EditorVM): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len == 0:
    return VectorOperationResult(ok: false, operation: vokDuplicate,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select a vector object before duplicating.")])
  var afterDoc = beforeDoc
  for id in beforeDoc.selectedIds:
    let idx = afterDoc.objectIndex(id)
    if idx < 0:
      continue
    var clone = afterDoc.objects[idx]
    clone.id = clone.id & "-copy"
    clone.name = clone.name & " copy"
    clone.x += 8
    clone.y += 8
    afterDoc.objects.add clone
    let layerPos = afterDoc.layerIndex(clone.layerId)
    if layerPos >= 0:
      afterDoc.layers[layerPos].objectIds.add clone.id
    afterDoc.selectedIds = @[clone.id]
  editor.commitVectorDocument(vokDuplicate, beforeDoc, afterDoc)

proc deleteVectorSelection*(editor: EditorVM): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len == 0:
    return VectorOperationResult(ok: false, operation: vokDelete,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select a vector object before deleting.")])
  var afterDoc = beforeDoc
  afterDoc.objects = afterDoc.objects.filterIt(it.id notin beforeDoc.selectedIds)
  for i in 0 ..< afterDoc.layers.len:
    afterDoc.layers[i].objectIds = afterDoc.layers[i].objectIds.filterIt(
      it notin beforeDoc.selectedIds)
  afterDoc.selectedIds = @[]
  editor.commitVectorDocument(vokDelete, beforeDoc, afterDoc)

proc groupVectorSelection*(editor: EditorVM): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len < 2:
    return VectorOperationResult(ok: false, operation: vokGroup,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least two vector objects before grouping.")])
  var afterDoc = beforeDoc
  let groupId = "group-" & $(afterDoc.objects.len + 1)
  let layerId =
    if afterDoc.objects.len > 0: afterDoc.objects[0].layerId else: "base"
  afterDoc.objects.add VectorObject(id: groupId, name: "Group",
    kind: vskGroup, layerId: layerId, children: beforeDoc.selectedIds,
    source: beforeDoc.source, a11y: beforeDoc.a11y)
  let layerPos = afterDoc.layerIndex(layerId)
  if layerPos >= 0:
    afterDoc.layers[layerPos].objectIds.add groupId
  afterDoc.selectedIds = @[groupId]
  editor.commitVectorDocument(vokGroup, beforeDoc, afterDoc)

proc reuseVectorSymbol*(editor: EditorVM; symbolId: string): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  var afterDoc = beforeDoc
  let useId = "use-" & symbolId.normalize & "-" & $(afterDoc.objects.len + 1)
  afterDoc.objects.add VectorObject(id: useId, name: "Use " & symbolId,
    kind: vskSymbolUse, layerId: "base", x: 4, y: 4, width: 16, height: 16,
    symbolRef: symbolId, source: beforeDoc.source, a11y: beforeDoc.a11y)
  let layerPos = afterDoc.layerIndex("base")
  if layerPos >= 0:
    afterDoc.layers[layerPos].objectIds.add useId
  afterDoc.selectedIds = @[useId]
  editor.commitVectorDocument(vokReuseSymbol, beforeDoc, afterDoc)

proc setVectorObjectProperty*(editor: EditorVM;
    request: VectorPropertyEditRequest): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(request.objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokSetProperty,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector object '" & request.objectId & "'.",
        objectId: request.objectId)])
  var afterDoc = beforeDoc
  case request.kind
  of vpkFill:
    afterDoc.objects[idx].fill = request.value
  of vpkStroke:
    afterDoc.objects[idx].stroke = request.value
  of vpkGradient:
    afterDoc.objects[idx].gradient = request.value
    afterDoc.objects[idx].fill = "url(#" & request.value & ")"
  of vpkDashArray:
    afterDoc.objects[idx].dashArray = request.value
  of vpkStrokeCap:
    afterDoc.objects[idx].strokeCap = request.value.strokeCapFromString
  of vpkStrokeJoin:
    afterDoc.objects[idx].strokeJoin = request.value.strokeJoinFromString
  of vpkOpacity:
    try:
      afterDoc.objects[idx].opacity = max(0.0, min(1.0, request.value.parseFloat))
    except ValueError:
      return VectorOperationResult(ok: false, operation: vokSetProperty,
        diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
          message: "Opacity must be a number between 0 and 1.",
          objectId: request.objectId)])
  of vpkTransform:
    try:
      afterDoc.objects[idx].rotation = request.value.parseFloat
    except ValueError:
      return VectorOperationResult(ok: false, operation: vokSetProperty,
        diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
          message: "Transform rotation must be numeric.",
          objectId: request.objectId)])
  of vpkBlendMode:
    afterDoc.objects[idx].blendMode = request.value
  editor.commitVectorDocument(vokSetProperty, beforeDoc, afterDoc)

proc setVectorDocumentViewBox*(editor: EditorVM;
    viewBox: string): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if viewBox.splitWhitespace.len != 4:
    return VectorOperationResult(ok: false, operation: vokSetViewBox,
      diagnostics: @[VectorDiagnostic(kind: vdkInvalidSvg,
        message: "ViewBox must contain four numeric values.")])
  var afterDoc = beforeDoc
  afterDoc.viewBox = viewBox
  editor.commitVectorDocument(vokSetViewBox, beforeDoc, afterDoc)

func polygonPath(cx, cy, radius: float; sides: int): string =
  var points: seq[string] = @[]
  for i in 0 ..< sides:
    let angle = (2 * PI * float(i) / float(sides)) - PI / 2
    points.add $(cx + cos(angle) * radius) & " " & $(cy + sin(angle) * radius)
  if points.len == 0:
    return ""
  "M" & points.join("L") & "Z"

func starPath(cx, cy, outerRadius, innerRadius: float; pointsCount: int): string =
  var points: seq[string] = @[]
  for i in 0 ..< pointsCount * 2:
    let radius = if i mod 2 == 0: outerRadius else: innerRadius
    let angle = (PI * float(i) / float(pointsCount)) - PI / 2
    points.add $(cx + cos(angle) * radius) & " " & $(cy + sin(angle) * radius)
  if points.len == 0:
    return ""
  "M" & points.join("L") & "Z"

proc addVectorPolygon*(editor: EditorVM; sides: int = 6): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  var afterDoc = beforeDoc
  let id = "polygon-" & $(afterDoc.objects.len + 1)
  afterDoc.objects.add VectorObject(id: id, name: "Polygon",
    kind: vskPolygon, layerId: "base", x: 120, y: 80, width: 96, height: 96,
    pathData: polygonPath(168, 128, 48, max(3, sides)), fill: "none",
    stroke: "currentColor", strokeWidth: 2, opacity: 1, strokeCap: scButt,
    strokeJoin: sjRound, source: beforeDoc.source, a11y: beforeDoc.a11y)
  let layerPos = afterDoc.layerIndex("base")
  if layerPos >= 0:
    afterDoc.layers[layerPos].objectIds.add id
  afterDoc.selectedIds = @[id]
  editor.commitVectorDocument(vokAddShape, beforeDoc, afterDoc)

proc addVectorStar*(editor: EditorVM; pointsCount: int = 5): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  var afterDoc = beforeDoc
  let id = "star-" & $(afterDoc.objects.len + 1)
  afterDoc.objects.add VectorObject(id: id, name: "Star",
    kind: vskStar, layerId: "base", x: 240, y: 80, width: 104, height: 104,
    pathData: starPath(292, 132, 52, 22, max(3, pointsCount)), fill: "none",
    stroke: "currentColor", strokeWidth: 2, opacity: 1, strokeCap: scButt,
    strokeJoin: sjRound, source: beforeDoc.source, a11y: beforeDoc.a11y)
  let layerPos = afterDoc.layerIndex("base")
  if layerPos >= 0:
    afterDoc.layers[layerPos].objectIds.add id
  afterDoc.selectedIds = @[id]
  editor.commitVectorDocument(vokAddShape, beforeDoc, afterDoc)

proc selectVectorObjects*(editor: EditorVM; ids: seq[string]): bool {.discardable.} =
  var doc = editor.vectorEditor.document.val
  for id in ids:
    if doc.objectIndex(id) < 0:
      editor.vectorEditor.diagnostics.val = @[VectorDiagnostic(
        kind: vdkMissingObject,
        message: "Unknown vector object '" & id & "'.")]
      return false
  doc.selectedIds = ids
  editor.vectorEditor.document.val = doc
  editor.vectorEditor.diagnostics.val = @[]
  true

func selectedPathNodeIds(obj: VectorObject): seq[string] =
  for node in obj.pathNodes:
    if node.selected:
      result.add node.id

proc rejectUnsupportedPathNodeEdit(editor: EditorVM; operation: VectorOperationKind;
    objectId: string): VectorOperationResult =
  let diagnostics = @[VectorDiagnostic(kind: vdkUnsupportedOperation,
    message: "Path node editing requires parsed source-backed path nodes for '" &
      objectId & "'; original pathData is preserved.",
    objectId: objectId)]
  editor.vectorEditor.diagnostics.val = diagnostics
  VectorOperationResult(ok: false, operation: operation,
    document: editor.vectorEditor.document.val, diagnostics: diagnostics)

proc selectVectorPathNodes*(editor: EditorVM; objectId: string;
    nodeIds: seq[string]; append = false): VectorOperationResult {.discardable.} =
  var doc = editor.vectorEditor.document.val
  let idx = doc.objectIndex(objectId)
  if idx < 0:
    let diagnostics = @[VectorDiagnostic(kind: vdkMissingObject,
      message: "Unknown vector path object '" & objectId & "'.",
      objectId: objectId)]
    editor.vectorEditor.diagnostics.val = diagnostics
    return VectorOperationResult(ok: false, operation: vokSelectPathNode,
      diagnostics: diagnostics)
  if doc.objects[idx].pathNodes.len == 0:
    let diagnostics = @[VectorDiagnostic(kind: vdkUnsupportedOperation,
      message: "Path node selection requires parsed source-backed path nodes for '" &
        objectId & "'; original pathData is preserved.", objectId: objectId)]
    editor.vectorEditor.diagnostics.val = diagnostics
    return VectorOperationResult(ok: false, operation: vokSelectPathNode,
      diagnostics: diagnostics)
  for id in nodeIds:
    if not doc.objects[idx].pathNodes.anyIt(it.id == id):
      let diagnostics = @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown path node '" & id & "'.", objectId: objectId)]
      editor.vectorEditor.diagnostics.val = diagnostics
      return VectorOperationResult(ok: false, operation: vokSelectPathNode,
        diagnostics: diagnostics)
  if not append:
    for node in doc.objects[idx].pathNodes.mitems:
      node.selected = false
  for node in doc.objects[idx].pathNodes.mitems:
    if node.id in nodeIds:
      node.selected = true
  doc.selectedIds = @[objectId]
  editor.vectorEditor.document.val = doc
  editor.vectorEditor.diagnostics.val = @[]
  VectorOperationResult(ok: true, operation: vokSelectPathNode, document: doc)

proc moveVectorPathNodes*(editor: EditorVM; objectId: string;
    nodeIds: seq[string]; dx, dy: float): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokMovePathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector path object '" & objectId & "'.",
        objectId: objectId)])
  if beforeDoc.objects[idx].pathNodes.len == 0:
    return editor.rejectUnsupportedPathNodeEdit(vokMovePathNode, objectId)
  var afterDoc = beforeDoc
  let targets =
    if nodeIds.len > 0: nodeIds else: afterDoc.objects[idx].selectedPathNodeIds
  if targets.len == 0:
    return VectorOperationResult(ok: false, operation: vokMovePathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least one path node before moving.",
        objectId: objectId)])
  for node in afterDoc.objects[idx].pathNodes.mitems:
    if node.id in targets:
      node.x += dx
      node.y += dy
      node.inX += dx
      node.inY += dy
      node.outX += dx
      node.outY += dy
      node.selected = true
  afterDoc.objects[idx].pathData = afterDoc.objects[idx].pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokMovePathNode, beforeDoc, afterDoc)

proc insertVectorPathNode*(editor: EditorVM; objectId: string; afterNodeId: string;
    x, y: float; nodeType = ntCorner): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokInsertPathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector path object '" & objectId & "'.",
        objectId: objectId)])
  if beforeDoc.objects[idx].pathNodes.len == 0:
    return editor.rejectUnsupportedPathNodeEdit(vokInsertPathNode, objectId)
  var afterDoc = beforeDoc
  var insertAt = afterDoc.objects[idx].pathNodes.len
  for i, node in afterDoc.objects[idx].pathNodes:
    if node.id == afterNodeId:
      insertAt = i + 1
      break
  if afterNodeId.len > 0 and insertAt == afterDoc.objects[idx].pathNodes.len and
      not afterDoc.objects[idx].pathNodes.anyIt(it.id == afterNodeId):
    return VectorOperationResult(ok: false, operation: vokInsertPathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown insertion node '" & afterNodeId & "'.",
        objectId: objectId)])
  for node in afterDoc.objects[idx].pathNodes.mitems:
    node.selected = false
  let id = vectorNodeId(afterDoc.objects[idx].pathNodes.len)
  afterDoc.objects[idx].pathNodes.insert(VectorPathNode(id: id, x: x, y: y,
    inX: x, inY: y, outX: x, outY: y, nodeType: nodeType, selected: true),
    insertAt)
  afterDoc.objects[idx].pathData = afterDoc.objects[idx].pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokInsertPathNode, beforeDoc, afterDoc)

proc deleteVectorPathNodes*(editor: EditorVM; objectId: string;
    nodeIds: seq[string]): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokDeletePathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector path object '" & objectId & "'.",
        objectId: objectId)])
  if beforeDoc.objects[idx].pathNodes.len == 0:
    return editor.rejectUnsupportedPathNodeEdit(vokDeletePathNode, objectId)
  var afterDoc = beforeDoc
  let targets =
    if nodeIds.len > 0: nodeIds else: afterDoc.objects[idx].selectedPathNodeIds
  if targets.len == 0:
    return VectorOperationResult(ok: false, operation: vokDeletePathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least one path node before deleting.",
        objectId: objectId)])
  afterDoc.objects[idx].pathNodes =
    afterDoc.objects[idx].pathNodes.filterIt(it.id notin targets)
  if afterDoc.objects[idx].pathNodes.len < 2:
    return VectorOperationResult(ok: false, operation: vokDeletePathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkUnsupportedOperation,
        message: "A path must keep at least two nodes.", objectId: objectId)])
  afterDoc.objects[idx].pathData = afterDoc.objects[idx].pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokDeletePathNode, beforeDoc, afterDoc)

proc convertVectorPathNodes*(editor: EditorVM; objectId: string;
    nodeIds: seq[string]; nodeType: NodeType): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokConvertPathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector path object '" & objectId & "'.",
        objectId: objectId)])
  if beforeDoc.objects[idx].pathNodes.len == 0:
    return editor.rejectUnsupportedPathNodeEdit(vokConvertPathNode, objectId)
  var afterDoc = beforeDoc
  let targets =
    if nodeIds.len > 0: nodeIds else: afterDoc.objects[idx].selectedPathNodeIds
  if targets.len == 0:
    return VectorOperationResult(ok: false, operation: vokConvertPathNode,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least one path node before conversion.",
        objectId: objectId)])
  for node in afterDoc.objects[idx].pathNodes.mitems:
    if node.id in targets:
      node.nodeType = nodeType
      if nodeType == ntCorner:
        node.inX = node.x
        node.inY = node.y
        node.outX = node.x
        node.outY = node.y
      elif node.inX == 0 and node.inY == 0 and node.outX == 0 and node.outY == 0:
        node.inX = node.x - 8
        node.inY = node.y
        node.outX = node.x + 8
        node.outY = node.y
      node.selected = true
  afterDoc.objects[idx].pathData = afterDoc.objects[idx].pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokConvertPathNode, beforeDoc, afterDoc)

proc dragVectorPathHandle*(editor: EditorVM; objectId, nodeId: string;
    handle: VectorHandleKind; x, y: float): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  let idx = beforeDoc.objectIndex(objectId)
  if idx < 0:
    return VectorOperationResult(ok: false, operation: vokDragPathHandle,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown vector path object '" & objectId & "'.",
        objectId: objectId)])
  if beforeDoc.objects[idx].pathNodes.len == 0:
    return editor.rejectUnsupportedPathNodeEdit(vokDragPathHandle, objectId)
  var afterDoc = beforeDoc
  var found = false
  for node in afterDoc.objects[idx].pathNodes.mitems:
    if node.id == nodeId:
      found = true
      node.nodeType = if node.nodeType == ntCorner: ntAsymmetric else: node.nodeType
      if handle == vhkIn:
        node.inX = x
        node.inY = y
      else:
        node.outX = x
        node.outY = y
      node.selected = true
  if not found:
    return VectorOperationResult(ok: false, operation: vokDragPathHandle,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingObject,
        message: "Unknown path node '" & nodeId & "'.", objectId: objectId)])
  afterDoc.objects[idx].pathData = afterDoc.objects[idx].pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokDragPathHandle, beforeDoc, afterDoc)

proc ungroupVectorSelection*(editor: EditorVM): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len != 1:
    return VectorOperationResult(ok: false, operation: vokUngroup,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select one vector group before ungrouping.")])
  let idx = beforeDoc.objectIndex(beforeDoc.selectedIds[0])
  if idx < 0 or beforeDoc.objects[idx].kind != vskGroup:
    return VectorOperationResult(ok: false, operation: vokUngroup,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Selected vector object is not a group.")])
  var afterDoc = beforeDoc
  let group = beforeDoc.objects[idx]
  afterDoc.objects.delete(idx)
  for i in 0 ..< afterDoc.layers.len:
    afterDoc.layers[i].objectIds = afterDoc.layers[i].objectIds.filterIt(it != group.id)
  afterDoc.selectedIds = group.children
  editor.commitVectorDocument(vokUngroup, beforeDoc, afterDoc)

proc nudgeVectorSelection*(editor: EditorVM; dx, dy: float): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len == 0:
    return VectorOperationResult(ok: false, operation: vokNudgeSelection,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select vector objects before nudging.")])
  var afterDoc = beforeDoc
  for obj in afterDoc.objects.mitems:
    if obj.id in beforeDoc.selectedIds:
      obj.x += dx
      obj.y += dy
      for node in obj.pathNodes.mitems:
        node.x += dx
        node.y += dy
        node.inX += dx
        node.inY += dy
        node.outX += dx
        node.outY += dy
      if obj.pathNodes.len > 0:
        obj.pathData = obj.pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokNudgeSelection, beforeDoc, afterDoc)

proc snapVectorSelection*(editor: EditorVM; gridSize: float): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len == 0 or gridSize <= 0:
    return VectorOperationResult(ok: false, operation: vokSnapSelection,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select vector objects and provide a positive grid before snapping.")])
  var afterDoc = beforeDoc
  for obj in afterDoc.objects.mitems:
    if obj.id in beforeDoc.selectedIds:
      obj.x = round(obj.x / gridSize) * gridSize
      obj.y = round(obj.y / gridSize) * gridSize
      for node in obj.pathNodes.mitems:
        node.x = round(node.x / gridSize) * gridSize
        node.y = round(node.y / gridSize) * gridSize
        node.inX = round(node.inX / gridSize) * gridSize
        node.inY = round(node.inY / gridSize) * gridSize
        node.outX = round(node.outX / gridSize) * gridSize
        node.outY = round(node.outY / gridSize) * gridSize
      if obj.pathNodes.len > 0:
        obj.pathData = obj.pathNodes.pathDataFromNodes
  editor.commitVectorDocument(vokSnapSelection, beforeDoc, afterDoc)

proc alignVectorSelection*(editor: EditorVM;
    alignment: VectorAlignment): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len < 2:
    return VectorOperationResult(ok: false, operation: vokAlignSelection,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least two vector objects before aligning.")])
  let selected = beforeDoc.objects.filterIt(it.id in beforeDoc.selectedIds)
  let left = selected.mapIt(it.x).min
  let right = selected.mapIt(it.x + it.width).max
  let top = selected.mapIt(it.y).min
  let bottom = selected.mapIt(it.y + it.height).max
  var afterDoc = beforeDoc
  for obj in afterDoc.objects.mitems:
    if obj.id in beforeDoc.selectedIds:
      case alignment
      of vaLeft: obj.x = left
      of vaCenter: obj.x = (left + right - obj.width) / 2
      of vaRight: obj.x = right - obj.width
      of vaTop: obj.y = top
      of vaMiddle: obj.y = (top + bottom - obj.height) / 2
      of vaBottom: obj.y = bottom - obj.height
  editor.commitVectorDocument(vokAlignSelection, beforeDoc, afterDoc)

proc distributeVectorSelection*(editor: EditorVM;
    axis: VectorDistributeAxis): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len < 3:
    return VectorOperationResult(ok: false, operation: vokDistributeSelection,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select at least three vector objects before distributing.")])
  var selected = beforeDoc.objects.filterIt(it.id in beforeDoc.selectedIds)
  if axis == vdaHorizontal:
    selected.sort(proc(a, b: VectorObject): int = cmp(a.x, b.x))
  else:
    selected.sort(proc(a, b: VectorObject): int = cmp(a.y, b.y))
  let first = selected[0]
  let last = selected[^1]
  let span =
    if axis == vdaHorizontal: (last.x + last.width / 2) - (first.x + first.width / 2)
    else: (last.y + last.height / 2) - (first.y + first.height / 2)
  let step = span / float(selected.len - 1)
  var afterDoc = beforeDoc
  for i, item in selected:
    let idx = afterDoc.objectIndex(item.id)
    if idx < 0:
      continue
    if axis == vdaHorizontal:
      afterDoc.objects[idx].x = first.x + first.width / 2 + step * float(i) -
        afterDoc.objects[idx].width / 2
    else:
      afterDoc.objects[idx].y = first.y + first.height / 2 + step * float(i) -
        afterDoc.objects[idx].height / 2
  editor.commitVectorDocument(vokDistributeSelection, beforeDoc, afterDoc)

proc reorderVectorSelection*(editor: EditorVM;
    order: VectorZOrder): VectorOperationResult {.discardable.} =
  let beforeDoc = editor.vectorEditor.document.val
  if beforeDoc.selectedIds.len == 0:
    return VectorOperationResult(ok: false, operation: vokReorderSelection,
      diagnostics: @[VectorDiagnostic(kind: vdkMissingSelection,
        message: "Select vector objects before changing z-order.")])
  var afterDoc = beforeDoc
  for layer in afterDoc.layers.mitems:
    for id in beforeDoc.selectedIds:
      let pos = layer.objectIds.find(id)
      if pos < 0:
        continue
      case order
      of vzoBringForward:
        if pos < layer.objectIds.high:
          swap layer.objectIds[pos], layer.objectIds[pos + 1]
      of vzoSendBackward:
        if pos > 0:
          swap layer.objectIds[pos], layer.objectIds[pos - 1]
      of vzoBringToFront:
        layer.objectIds.delete(pos)
        layer.objectIds.add id
      of vzoSendToBack:
        layer.objectIds.delete(pos)
        layer.objectIds.insert(id, 0)
  editor.commitVectorDocument(vokReorderSelection, beforeDoc, afterDoc)

proc undoVectorEdit*(editor: EditorVM): bool {.discardable.} =
  let stack = editor.vectorEditor.undoStack.val
  if stack.len == 0:
    return false
  let tx = stack[^1]
  editor.vectorEditor.undoStack.val = stack[0 ..< stack.len - 1]
  editor.vectorEditor.redoStack.update proc(prev: seq[VectorEditTransaction]): seq[
      VectorEditTransaction] =
    result = prev
    result.add tx
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    if prev.len > 0:
      for i in countdown(prev.high, 0):
        let plan = prev[i]
        if plan.file == tx.sourceEdit.file and
            plan.schemaKey == tx.sourceEdit.schemaKey and
            plan.property == tx.sourceEdit.property and
            plan.oldValue == tx.sourceEdit.oldValue and
            plan.newValue == tx.sourceEdit.newValue:
          result.delete(i)
          break
  editor.vectorEditor.document.val = tx.beforeDocument
  editor.workspaceEditStage.val =
    if editor.inspector.pendingSourceEdits.val.len == 0: wesClean else: wesDirty
  true

proc redoVectorEdit*(editor: EditorVM): bool {.discardable.} =
  let stack = editor.vectorEditor.redoStack.val
  if stack.len == 0:
    return false
  let tx = stack[^1]
  editor.vectorEditor.redoStack.val = stack[0 ..< stack.len - 1]
  editor.vectorEditor.undoStack.update proc(prev: seq[VectorEditTransaction]): seq[
      VectorEditTransaction] =
    result = prev
    result.add tx
  editor.vectorEditor.document.val = tx.afterDocument
  editor.inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add tx.sourceEdit
  editor.workspaceEditStage.val = wesDirty
  true

proc createVectorEditorVM*(): VectorEditorVM =
  let activeTool = createSignal(vtSelect)
  let symbols = createSignal[seq[VectorSymbol]](@[])
  let document = createSignal(VectorDocument())
  let adapter = createSignal(selectedVectorAdapter())
  let diagnostics = createSignal[seq[VectorDiagnostic]](@[])
  let undoStack = createSignal[seq[VectorEditTransaction]](@[])
  let redoStack = createSignal[seq[VectorEditTransaction]](@[])
  let searchFilter = createSignal("")
  let selectedSymbol = createSignal(-1)
  let zoom = createSignal(1.0)
  let panX = createSignal(0.0)
  let panY = createSignal(0.0)
  let showGrid = createSignal(true)
  let snapToGrid = createSignal(true)
  let gridSize = createSignal(8.0)

  let isEditing = createMemo[bool](proc(): bool =
    selectedSymbol.val >= 0
  )
  let isDirty = createMemo[bool](proc(): bool =
    undoStack.val.len > 0
  )

  let filteredSymbols = createMemo[seq[VectorSymbol]](proc(): seq[VectorSymbol] =
    let query = searchFilter.val.toLowerAscii()
    let all = symbols.val
    if query.len == 0:
      return all
    result = @[]
    for s in all:
      if query in s.name.toLowerAscii() or query in s.category.toLowerAscii():
        result.add s
      else:
        for tag in s.tags:
          if query in tag.toLowerAscii():
            result.add s
            break
  )

  VectorEditorVM(
    activeTool: activeTool,
    symbols: symbols,
    document: document,
    adapter: adapter,
    diagnostics: diagnostics,
    undoStack: undoStack,
    redoStack: redoStack,
    searchFilter: searchFilter,
    filteredSymbols: filteredSymbols,
    selectedSymbol: selectedSymbol,
    isEditing: isEditing,
    isDirty: isDirty,
    zoom: zoom,
    panX: panX,
    panY: panY,
    showGrid: showGrid,
    snapToGrid: snapToGrid,
    gridSize: gridSize)

proc createFoundationEditorVM*(): FoundationEditorVM =
  let tokens = createSignal[seq[FoundationTokenEntry]](@[])
  let selectedCategory = createSignal(ftkColorPalette)
  let selectedTokenKey = createSignal("")
  let searchFilter = createSignal("")
  let impacts = createSignal[seq[FoundationTokenImpact]](@[])
  let diagnostics = createSignal[seq[FoundationEditDiagnostic]](@[])
  let undoStack = createSignal[seq[FoundationEditHistoryEntry]](@[])
  let redoStack = createSignal[seq[FoundationEditHistoryEntry]](@[])
  let availableCategories = createMemo[seq[FoundationTokenKind]](proc(): seq[
      FoundationTokenKind] =
    for kind in allFoundationTokenKinds():
      if tokens.val.anyIt(it.kind == kind):
        result.add kind)
  let filteredTokens = createMemo[seq[FoundationTokenEntry]](proc(): seq[
      FoundationTokenEntry] =
    let kind = selectedCategory.val
    let query = searchFilter.val
    for token in tokens.val:
      if token.kind == kind and token.tokenMatchesSearch(query):
        result.add token)
  let selectedToken = createMemo[FoundationTokenEntry](proc(): FoundationTokenEntry =
    let key = selectedTokenKey.val
    for token in tokens.val:
      if token.key.sameTokenKey(key):
        return token
    let filtered = filteredTokens.val
    if filtered.len > 0:
      filtered[0]
    else:
      FoundationTokenEntry())
  let isDirty = createMemo[bool](proc(): bool = undoStack.val.len > 0)
  let hasDiagnostics = createMemo[bool](proc(): bool = diagnostics.val.len > 0)
  FoundationEditorVM(
    tokens: tokens,
    selectedCategory: selectedCategory,
    selectedTokenKey: selectedTokenKey,
    searchFilter: searchFilter,
    impacts: impacts,
    diagnostics: diagnostics,
    undoStack: undoStack,
    redoStack: redoStack,
    availableCategories: availableCategories,
    filteredTokens: filteredTokens,
    selectedToken: selectedToken,
    isDirty: isDirty,
    hasDiagnostics: hasDiagnostics)

proc createComponentVariantEditorVM*(): ComponentVariantEditorVM =
  let variants = createSignal[seq[ComponentVariantDefinition]](@[])
  let diagnostics = createSignal[seq[ComponentVariantDiagnostic]](@[])
  let stateDiagnostics = createSignal[seq[ComponentStateCoverageDiagnostic]](@[])
  let selectedVariant = createSignal(-1)
  let variantMatrix = createMemo[seq[ComponentVariantMatrixCell]](proc(): seq[
      ComponentVariantMatrixCell] =
    var component = ""
    let idx = selectedVariant.val
    let all = variants.val
    if idx >= 0 and idx < all.len:
      component = all[idx].component
    elif all.len > 0:
      component = all[0].component
    if component.len == 0:
      @[]
    else:
      variantMatrixPreviews(all, component)
  )
  let hasDiagnostics = createMemo[bool](proc(): bool =
    diagnostics.val.len > 0 or stateDiagnostics.val.len > 0)
  ComponentVariantEditorVM(
    variants: variants,
    diagnostics: diagnostics,
    stateDiagnostics: stateDiagnostics,
    selectedVariant: selectedVariant,
    variantMatrix: variantMatrix,
    hasDiagnostics: hasDiagnostics)

proc createAgentChatVM*(): AgentChatVM =
  let messages = createSignal[seq[ChatMessage]](@[])
  let sessionStatus = createSignal(asIdle)
  let accumulatedEdits = createSignal[seq[EditRecord]](@[])
  let inputText = createSignal("")
  let connectionState = createSignal("disconnected")
  let planEntries = createSignal[seq[string]](@[])
  let toolCalls = createSignal[seq[string]](@[])
  let proposedEdits = createSignal[seq[AgentEditProposal]](@[])
  let permissionRequests = createSignal[seq[AgentPermissionRequest]](@[])
  let lastPromptContext = createSignal(AgentPromptContext())
  let promptIncludesScreenshots = createSignal(false)
  let promptIncludesDomSnapshots = createSignal(false)
  let designSystemConstraints = createSignal[seq[string]](@[
    "Respect project-owned source schema and source-map ownership.",
    "Do not bypass component, token, variant, or story fixture ownership scopes.",
    "Preserve accessibility diagnostics and design-token constraints."
  ])
  let backend = createSignal(absUnconfigured)
  let stopReason = createSignal("")

  let messageCount = createMemo[int](proc(): int = messages.val.len)

  AgentChatVM(
    messages: messages,
    sessionStatus: sessionStatus,
    accumulatedEdits: accumulatedEdits,
    inputText: inputText,
    connectionState: connectionState,
    planEntries: planEntries,
    toolCalls: toolCalls,
    proposedEdits: proposedEdits,
    permissionRequests: permissionRequests,
    lastPromptContext: lastPromptContext,
    promptIncludesScreenshots: promptIncludesScreenshots,
    promptIncludesDomSnapshots: promptIncludesDomSnapshots,
    designSystemConstraints: designSystemConstraints,
    backend: backend,
    stopReason: stopReason,
    messageCount: messageCount)

proc createReviewResultsVM*(): ReviewResultsVM =
  let violations = createSignal[seq[Violation]](@[])
  let annotations = createSignal[seq[ReviewAnnotation]](@[])

  let errorCount = createMemo[int](proc(): int =
    var count = 0
    for v in violations.val:
      if v.severity == vsError: inc count
    count
  )

  let warningCount = createMemo[int](proc(): int =
    var count = 0
    for v in violations.val:
      if v.severity == vsWarning: inc count
    count
  )

  let hasIssues = createMemo[bool](proc(): bool =
    violations.val.len > 0 or annotations.val.anyIt(it.state == ransOpen))

  ReviewResultsVM(
    violations: violations,
    annotations: annotations,
    errorCount: errorCount,
    warningCount: warningCount,
    hasIssues: hasIssues)

proc createProjectPreviewVM*(selectedStory: Signal[StoryRef];
    platform: Signal[Platform]): ProjectPreviewVM =
  let preview = ProjectPreviewVM(hook: defaultPreviewHook)
  preview.current = createMemo[ProjectPreview](proc(): ProjectPreview =
    preview.hook(selectedStory.val, platform.val)
  )
  preview

proc createFlowPlayerVM*(): FlowPlayerVM =
  let steps = createSignal[seq[FlowStep]](@[])
  let currentStep = createSignal(0)
  let playState = createSignal(psStopped)

  let totalSteps = createMemo[int](proc(): int = steps.val.len)
  let isFirstStep = createMemo[bool](proc(): bool = currentStep.val == 0)
  let isLastStep = createMemo[bool](proc(): bool =
    let total = steps.val.len
    total == 0 or currentStep.val >= total - 1
  )
  let currentAction = createMemo[string](proc(): string =
    let idx = currentStep.val
    let all = steps.val
    if idx >= 0 and idx < all.len: all[idx].action else: ""
  )

  FlowPlayerVM(
    steps: steps,
    currentStep: currentStep,
    playState: playState,
    totalSteps: totalSteps,
    isFirstStep: isFirstStep,
    isLastStep: isLastStep,
    currentAction: currentAction)

proc createEditorVM*(): EditorVM =
  ## Create the top-level editor ViewModel with all sub-VMs wired up.
  let activeView = createSignal(evStoryboard)
  let selectedStory = createSignal(StoryRef())
  let editMode = createSignal(emView)
  let panels = createSignal(PanelVisibility(sidebar: true, inspector: true))
  let rightPanelWidth = createSignal(320)
  let platform = createSignal(pfWeb)
  let viewport = createSignal(pvDesktop)
  let workspacePermissions = createSignal(defaultWorkspacePermissions())
  let sourceAdapterReady = createSignal(false)
  let workspaceEditStage = createSignal(wesClean)
  let workspaceEditDiagnostics = createSignal[seq[WorkspaceEditDiagnostic]](@[])
  let workspaceEditPatches = createSignal[seq[WorkspaceFilePatch]](@[])
  let workspaceEditAffectedStories = createSignal[seq[StoryRef]](@[])
  let workspaceEditFullReload = createSignal(false)
  let workspaceEditGeneratedArtifacts = createSignal[seq[string]](@[])
  let workspaceEditRequiredTestCommands = createSignal[seq[string]](@[])
  let workspaceEditReviewDiagnostics = createSignal[seq[WorkspaceEditDiagnostic]](@[])
  let livePreviewReloadGeneration = createSignal(0)
  let commandStates = createSignal[seq[EditorCommandState]](@[])
  let commandPaletteOpen = createSignal(false)
  let performanceBudgets = createSignal(defaultEditorPerformanceBudgets())
  let telemetryEvents = createSignal[seq[EditorTelemetryEvent]](@[])
  let telemetryOverlayVisible = createSignal(false)
  let designSystemSchema = createSignal(DesignSystemSchema())

  let sidebar = createSidebarVM()
  let storyboard = createStoryboardVM()
  let inspector = createInspectorVM()
  let vectorEditor = createVectorEditorVM()
  let foundations = createFoundationEditorVM()
  let variants = createComponentVariantEditorVM()
  let chat = createAgentChatVM()
  let review = createReviewResultsVM()
  let preview = createProjectPreviewVM(selectedStory, platform)
  let flowPlayer = createFlowPlayerVM()

  let hasSelection = createMemo[bool](proc(): bool =
    selectedStory.val.name.len > 0
  )

  EditorVM(
    activeView: activeView,
    selectedStory: selectedStory,
    editMode: editMode,
    panels: panels,
    rightPanelWidth: rightPanelWidth,
    platform: platform,
    viewport: viewport,
    workspacePermissions: workspacePermissions,
    sourceAdapterReady: sourceAdapterReady,
    workspaceEditStage: workspaceEditStage,
    workspaceEditDiagnostics: workspaceEditDiagnostics,
    workspaceEditPatches: workspaceEditPatches,
    workspaceEditAffectedStories: workspaceEditAffectedStories,
    workspaceEditFullReload: workspaceEditFullReload,
    workspaceEditGeneratedArtifacts: workspaceEditGeneratedArtifacts,
    workspaceEditRequiredTestCommands: workspaceEditRequiredTestCommands,
    workspaceEditReviewDiagnostics: workspaceEditReviewDiagnostics,
    livePreviewReloadGeneration: livePreviewReloadGeneration,
    commandStates: commandStates,
    commandPaletteOpen: commandPaletteOpen,
    performanceBudgets: performanceBudgets,
    telemetryEvents: telemetryEvents,
    telemetryOverlayVisible: telemetryOverlayVisible,
    designSystemSchema: designSystemSchema,
    sidebar: sidebar,
    storyboard: storyboard,
    inspector: inspector,
    vectorEditor: vectorEditor,
    foundations: foundations,
    variants: variants,
    chat: chat,
    review: review,
    preview: preview,
    flowPlayer: flowPlayer,
    hasSelection: hasSelection)
