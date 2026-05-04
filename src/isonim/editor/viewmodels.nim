## IsoNim Editor — all ViewModel types.
##
## Pure state machines using IsoNim reactive primitives.
## No CSS, no colors, no rendering — only signals, memos, and enums.
## Created via withViewModel inside createRoot.

import std/[math, sequtils, strutils]
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
    activeSection*: Signal[InspectorSection]
    editDiagnostics*: Signal[seq[PropertyEditDiagnostic]]
    pendingSourceEdits*: Signal[seq[SourceEditPlan]]
    sourcePreviews*: Signal[seq[CSSSourcePreview]]
    conflicts*: Signal[seq[CSSSourceConflict]]
    undoStack*: Signal[seq[CSSPropertyEditTransaction]]
    redoStack*: Signal[seq[CSSPropertyEditTransaction]]
    hasElement*: Memo[bool]
    properties*: Memo[seq[PropertyInfo]]
    propertyEditors*: Memo[seq[CSSPropertyEditorVM]]
    isDirty*: Memo[bool]
    ## CSS-specific state
    displayMode*: Signal[DisplayMode]
    flexDirection*: Signal[FlexDirection]

  VectorEditorVM* = ref object of ViewModel
    ## Embedded vector editor for SVG symbols.
    activeTool*: Signal[VectorTool]
    symbols*: Signal[seq[VectorSymbol]]
    searchFilter*: Signal[string]
    filteredSymbols*: Memo[seq[VectorSymbol]]
    selectedSymbol*: Signal[int] ## Index into symbols (-1 = none)
    isEditing*: Memo[bool]
    zoom*: Signal[float]
    showGrid*: Signal[bool]
    snapToGrid*: Signal[bool]
    gridSize*: Signal[float]

  FoundationEditorVM* = ref object of ViewModel
    tokens*: Signal[seq[FoundationTokenEntry]]
    impacts*: Signal[seq[FoundationTokenImpact]]
    diagnostics*: Signal[seq[FoundationEditDiagnostic]]
    hasDiagnostics*: Memo[bool]

  ComponentVariantEditorVM* = ref object of ViewModel
    variants*: Signal[seq[ComponentVariantDefinition]]
    diagnostics*: Signal[seq[ComponentVariantDiagnostic]]
    selectedVariant*: Signal[int]
    hasDiagnostics*: Memo[bool]

  AgentChatVM* = ref object of ViewModel
    messages*: Signal[seq[ChatMessage]]
    sessionStatus*: Signal[AsyncState]
    accumulatedEdits*: Signal[seq[EditRecord]]
    inputText*: Signal[string]
    connectionState*: Signal[string]
    planEntries*: Signal[seq[string]]
    toolCalls*: Signal[seq[string]]
    stopReason*: Signal[string]
    messageCount*: Memo[int]
    promptAdapter*: AgentPromptAdapter
    cancelAdapter*: AgentCancelAdapter

  ReviewResultsVM* = ref object of ViewModel
    violations*: Signal[seq[Violation]]
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
    platform*: Signal[Platform]
    viewport*: Signal[PreviewViewport]
    workspacePermissions*: Signal[EditorWorkspacePermissions]
    sourceAdapterReady*: Signal[bool]
    workspaceEditStage*: Signal[WorkspaceEditStage]
    workspaceEditDiagnostics*: Signal[seq[WorkspaceEditDiagnostic]]
    workspaceEditPatches*: Signal[seq[WorkspaceFilePatch]]
    workspaceEditAffectedStories*: Signal[seq[StoryRef]]
    workspaceEditFullReload*: Signal[bool]
    commandStates*: Signal[seq[EditorCommandState]]
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

func commandLabel*(kind: EditorCommandKind): string =
  case kind
  of eckEdit: "Edit"
  of eckInspect: "Inspect"
  of eckApply: "Apply"
  of eckRevert: "Revert"
  of eckSave: "Save"
  of eckDiscard: "Discard"
  of eckDuplicate: "Duplicate"
  of eckDelete: "Delete"
  of eckCreateVariant: "Create variant"
  of eckCreateStory: "Create story"
  of eckOpenSource: "Open source"

func allEditorCommandKinds*(): seq[EditorCommandKind] =
  @[
    eckEdit,
    eckInspect,
    eckApply,
    eckRevert,
    eckSave,
    eckDiscard,
    eckDuplicate,
    eckDelete,
    eckCreateVariant,
    eckCreateStory,
    eckOpenSource
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
  of skComponent, skPattern, skFoundation, skGuideline:
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
      "align-items", "align-content", "justify-content",
      "justify-items", "gap", "row-gap", "column-gap", "grid-template-columns",
      "grid-template-rows", "grid-column", "grid-row"]:
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
  elif prop in ["color", "background", "background-color", "fill", "stroke"]:
    cpcColor
  elif prop in ["border", "border-width", "border-color", "border-style",
      "border-radius", "outline", "outline-offset"]:
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
  if suffix in ["px", "rem", "em", "vw", "vh", "ch", "%"]:
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
  for unit in ["px", "rem", "em", "vw", "vh", "ch"]:
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
      "vw", "vh", "ch"]:
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
    conflictKey: prop.sourceFile & ":" & $prop.sourceLine & ":" & prop.name,
    expectedOldValue: prop.value)

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
  editor.storyboard.selectedItem.val = editor.findCanvasItem(story)
  editor.syncFlowStep(story)
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

proc switchInspectorSection*(editor: EditorVM; section: InspectorSection) =
  editor.inspector.activeSection.val = section

proc selectInspectorElement*(editor: EditorVM;
    element: ElementRef): bool {.discardable.} =
  if element.tag.len == 0:
    editor.inspector.selectedElement.val = ElementRef()
    editor.inspector.editDiagnostics.val = @[]
    return false

  editor.inspector.selectedElement.val = element
  editor.inspector.editDiagnostics.val = @[]
  true

proc changePlatform*(editor: EditorVM; platform: Platform) =
  editor.platform.val = platform
  editor.viewport.val = viewportForPlatform(platform)

proc changeViewport*(editor: EditorVM; viewport: PreviewViewport) =
  editor.viewport.val = viewport
  editor.platform.val = platformForViewport(viewport)

proc selectVectorSymbol*(editor: EditorVM; index: int): bool {.discardable.} =
  let symbols = editor.vectorEditor.symbols.val
  if index < 0 or index >= symbols.len:
    return false

  editor.vectorEditor.selectedSymbol.val = index
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

proc commandRequirementFailure(editor: EditorVM;
    kind: EditorCommandKind): string =
  let story = editor.selectedStory.val
  let element = editor.inspector.selectedElement.val
  let permissions = editor.workspacePermissions.val
  let source = editor.selectedSourceContext()

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
        editor.chat.accumulatedEdits.val.len == 0:
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

proc setEditMode*(editor: EditorVM; mode: EditMode) =
  editor.editMode.val = mode
  if mode == emEdit and editor.activeView.val in {evComponentDetail,
      evPagePreview}:
    editor.activeView.val = evComponentEdit
  elif mode == emView and editor.activeView.val == evComponentEdit:
    editor.activeView.val = evPagePreview

proc setVectorTool*(editor: EditorVM; tool: VectorTool) =
  editor.vectorEditor.activeTool.val = tool

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
  of eckInspect:
    editor.setEditMode(emView)
  of eckApply:
    discard
  of eckRevert, eckDiscard:
    let stack = editor.inspector.undoStack.val
    if stack.len > 0:
      editor.inspector.selectedElement.val = stack[0].beforeElement
    editor.inspector.pendingSourceEdits.val = @[]
    editor.inspector.sourcePreviews.val = @[]
    editor.inspector.undoStack.val = @[]
    editor.inspector.redoStack.val = @[]
    editor.inspector.conflicts.val = @[]
    editor.inspector.editDiagnostics.val = @[]
    editor.chat.accumulatedEdits.val = @[]
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
  inspector.selectedElement.val = element
  inspector.editDiagnostics.val = @[]

proc setSection*(inspector: InspectorVM; section: InspectorSection) =
  inspector.activeSection.val = section

proc clearSelection*(inspector: InspectorVM) =
  inspector.selectedElement.val = ElementRef()
  inspector.editDiagnostics.val = @[]

proc editProperty*(inspector: InspectorVM;
    request: PropertyEditRequest): PropertyEditResult {.discardable.} =
  ## Update the selected element and produce source-aware edit data.
  let element = inspector.selectedElement.val
  if element.tag.len == 0:
    result = withStatus(pesRejected, @[
      diagnostic(pedMissingSelection, element, request.property,
        "Select an element before editing inspector properties.")
    ])
    inspector.editDiagnostics.val = result.diagnostics
    return

  var propIndex = -1
  var prop = PropertyInfo()
  for i, candidate in element.properties:
    if candidate.name == request.property:
      propIndex = i
      prop = candidate
      break

  if propIndex < 0:
    if request.newValue.strip.len == 0 or element.sourceFile.len == 0:
      result = withStatus(pesRejected, @[
        diagnostic(pedUnknownProperty, element, request.property,
          "The selected element does not expose this property.")
      ])
      inspector.editDiagnostics.val = result.diagnostics
      return
    prop = PropertyInfo(
      name: request.property,
      value: "",
      origin: poInherited,
      originDetail: "property-addition",
      sourceFile: element.sourceFile,
      sourceLine: element.sourceLine,
      directStyleAllowed: true)

  var diagnostics: seq[PropertyEditDiagnostic] = @[]
  if prop.isShared and request.scope == pesUnspecified:
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

  if prop.isTokenDrift(request.newValue):
    diagnostics.add diagnostic(pedTokenDrift, prop,
      "Theme-token properties must stay on token values instead of literal colors.")

  if prop.isEmptyA11yEdit(request.newValue):
    diagnostics.add diagnostic(pedAccessibility, prop,
      "Accessibility text properties cannot be blank.")

  let normalized = parseCssPropertyValue(prop.name, request.newValue)
  diagnostics.add prop.validateCssPropertyValue(request, normalized)

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

  let record = prop.editRecord(request)
  let plan = prop.sourcePlan(request)
  inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan
  inspector.sourcePreviews.update proc(prev: seq[CSSSourcePreview]): seq[
      CSSSourcePreview] =
    result = prev
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
    let acceptedRecord = result.record
    editor.chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
      result = prev
      result.add acceptedRecord
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
    let aliasLike = value.startsWith("token(") or value.startsWith("$")
    if not parsed.ok and not aliasLike:
      result.add foundationDiagnostic(fedInvalidTokenValue, token,
        "Color tokens must use a hex color or token alias.")
  if token.kind == ftkSemanticColor and
      (value.startsWith("token(") or value.startsWith("$")):
    let target = tokenNameFromRaw(value)
    if editor.foundations.tokens.val.hasAliasCycle(token.key, target):
      result.add foundationDiagnostic(fedAliasCycle, token,
        "Semantic token aliases cannot form a cycle.")
  if token.kind == ftkAccessibilityConstraint and token.minContrast > 0:
    let foreground = if value.len > 0: value else: token.foreground
    let ratio = contrastRatio(foreground, token.background)
    if ratio > 0 and ratio < token.minContrast:
      result.add foundationDiagnostic(fedContrastViolation, token,
        "Token contrast ratio " & $ratio & " is below " & $token.minContrast & ".")

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
  if newValue.strip().startsWith("token(") or newValue.strip().startsWith("$"):
    updatedTokens[tokenIndex].aliasOf = tokenNameFromRaw(newValue)
  editor.foundations.tokens.val = updatedTokens

  let impact = editor.foundationImpact(key)
  editor.foundations.impacts.val = @[impact]
  editor.foundations.diagnostics.val = @[]
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
  editor.workspaceEditStage.val = stage
  editor.workspaceEditDiagnostics.val = diagnostics
  WorkspaceEditResult(
    ok: false,
    stage: stage,
    diagnostics: diagnostics,
    patches: patches)

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

  var patches: seq[WorkspaceFilePatch] = @[]
  var diagnostics: seq[WorkspaceEditDiagnostic] = @[]
  var files: seq[string] = @[]
  var schemaKeys: seq[string] = @[]
  var affectedStories: seq[StoryRef] = @[]
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
    written.add patch

  if adapter.formatFiles != nil:
    editor.workspaceEditStage.val = wesFormatting
    let formatted = adapter.formatFiles(files)
    if formatted.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedFormatFailed, formatted,
        "Workspace formatting failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)

  if adapter.regenerate != nil:
    editor.workspaceEditStage.val = wesRegenerating
    let regenerated = adapter.regenerate(schemaKeys)
    if regenerated.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedRegenerateFailed, regenerated,
        "Workspace regeneration failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)
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

  if adapter.reloadPreview != nil:
    editor.workspaceEditStage.val = wesReloading
    let reloaded = adapter.reloadPreview(affectedStories, fullReload)
    if reloaded.workspaceOpFailed:
      diagnostics = operationDiagnostics(wedReloadFailed, reloaded,
        "Workspace preview reload failed.")
      diagnostics.add rollbackWorkspaceWrites(editor, adapter, written)
      return editor.failWorkspaceEdit(diagnostics, patches)

  editor.inspector.markCssPropertyEditsSaved()
  editor.chat.accumulatedEdits.val = @[]
  editor.workspaceEditStage.val = wesClean
  editor.workspaceEditDiagnostics.val = @[]
  editor.workspaceEditPatches.val = patches
  editor.workspaceEditAffectedStories.val = affectedStories
  editor.workspaceEditFullReload.val = fullReload
  WorkspaceEditResult(
    ok: true,
    stage: wesClean,
    patches: patches,
    affectedStories: affectedStories,
    fullReload: fullReload)

# ===========================================================================
# AgentChatVM actions
# ===========================================================================

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

proc configureAgentAdapters*(chat: AgentChatVM;
    promptAdapter: AgentPromptAdapter = nil;
    cancelAdapter: AgentCancelAdapter = nil) =
  chat.promptAdapter = promptAdapter
  chat.cancelAdapter = cancelAdapter

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

  let context = AgentPromptContext(
    selectedStory: editor.selectedStory.val,
    selectedElement: editor.inspector.selectedElement.val,
    accumulatedEdits: editor.chat.accumulatedEdits.val,
    platform: editor.platform.val)
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

  let displayMode = createSignal(dmFlex)
  let flexDirection = createSignal(fdRow)

  InspectorVM(
    selectedElement: selectedElement,
    activeSection: activeSection,
    editDiagnostics: editDiagnostics,
    pendingSourceEdits: pendingSourceEdits,
    sourcePreviews: sourcePreviews,
    conflicts: conflicts,
    undoStack: undoStack,
    redoStack: redoStack,
    hasElement: hasElement,
    properties: properties,
    propertyEditors: propertyEditors,
    isDirty: isDirty,
    displayMode: displayMode,
    flexDirection: flexDirection)

proc createVectorEditorVM*(): VectorEditorVM =
  let activeTool = createSignal(vtSelect)
  let symbols = createSignal[seq[VectorSymbol]](@[])
  let searchFilter = createSignal("")
  let selectedSymbol = createSignal(-1)
  let zoom = createSignal(1.0)
  let showGrid = createSignal(true)
  let snapToGrid = createSignal(true)
  let gridSize = createSignal(8.0)

  let isEditing = createMemo[bool](proc(): bool =
    selectedSymbol.val >= 0
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
    searchFilter: searchFilter,
    filteredSymbols: filteredSymbols,
    selectedSymbol: selectedSymbol,
    isEditing: isEditing,
    zoom: zoom,
    showGrid: showGrid,
    snapToGrid: snapToGrid,
    gridSize: gridSize)

proc createFoundationEditorVM*(): FoundationEditorVM =
  let tokens = createSignal[seq[FoundationTokenEntry]](@[])
  let impacts = createSignal[seq[FoundationTokenImpact]](@[])
  let diagnostics = createSignal[seq[FoundationEditDiagnostic]](@[])
  let hasDiagnostics = createMemo[bool](proc(): bool = diagnostics.val.len > 0)
  FoundationEditorVM(
    tokens: tokens,
    impacts: impacts,
    diagnostics: diagnostics,
    hasDiagnostics: hasDiagnostics)

proc createComponentVariantEditorVM*(): ComponentVariantEditorVM =
  let variants = createSignal[seq[ComponentVariantDefinition]](@[])
  let diagnostics = createSignal[seq[ComponentVariantDiagnostic]](@[])
  let selectedVariant = createSignal(-1)
  let hasDiagnostics = createMemo[bool](proc(): bool = diagnostics.val.len > 0)
  ComponentVariantEditorVM(
    variants: variants,
    diagnostics: diagnostics,
    selectedVariant: selectedVariant,
    hasDiagnostics: hasDiagnostics)

proc createAgentChatVM*(): AgentChatVM =
  let messages = createSignal[seq[ChatMessage]](@[])
  let sessionStatus = createSignal(asIdle)
  let accumulatedEdits = createSignal[seq[EditRecord]](@[])
  let inputText = createSignal("")
  let connectionState = createSignal("disconnected")
  let planEntries = createSignal[seq[string]](@[])
  let toolCalls = createSignal[seq[string]](@[])
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
    stopReason: stopReason,
    messageCount: messageCount)

proc createReviewResultsVM*(): ReviewResultsVM =
  let violations = createSignal[seq[Violation]](@[])

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

  let hasIssues = createMemo[bool](proc(): bool = violations.val.len > 0)

  ReviewResultsVM(
    violations: violations,
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
  let platform = createSignal(pfWeb)
  let viewport = createSignal(pvDesktop)
  let workspacePermissions = createSignal(defaultWorkspacePermissions())
  let sourceAdapterReady = createSignal(false)
  let workspaceEditStage = createSignal(wesClean)
  let workspaceEditDiagnostics = createSignal[seq[WorkspaceEditDiagnostic]](@[])
  let workspaceEditPatches = createSignal[seq[WorkspaceFilePatch]](@[])
  let workspaceEditAffectedStories = createSignal[seq[StoryRef]](@[])
  let workspaceEditFullReload = createSignal(false)
  let commandStates = createSignal[seq[EditorCommandState]](@[])

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
    platform: platform,
    viewport: viewport,
    workspacePermissions: workspacePermissions,
    sourceAdapterReady: sourceAdapterReady,
    workspaceEditStage: workspaceEditStage,
    workspaceEditDiagnostics: workspaceEditDiagnostics,
    workspaceEditPatches: workspaceEditPatches,
    workspaceEditAffectedStories: workspaceEditAffectedStories,
    workspaceEditFullReload: workspaceEditFullReload,
    commandStates: commandStates,
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
