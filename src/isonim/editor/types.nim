## IsoNim Editor — shared types used across all ViewModels.
## Pure data types with no rendering or presentation logic.

type
  # --- Story types ---
  StoryKind* = enum
    skFoundation ## Design token display (colors, typography, spacing)
    skComponent  ## Individual component in a specific state
    skPattern    ## Composition pattern (forms, tables, navigation)
    skPage       ## Full page composition with realistic data
    skFlow       ## Multi-step user navigation sequence
    skGuideline  ## Usage guideline (do/don't, content, motion, a11y)

  SidebarSection* = enum
    ssUserJourneys
    ssPages
    ssComponents
    ssFoundations
    ssGuidelines

  SidebarSectionExpansion* = object
    userJourneys*: bool
    pages*: bool
    components*: bool
    foundations*: bool
    guidelines*: bool

  StoryRef* = object
    ## Reference to a specific story in the storyboard.
    group*: string ## e.g. "TaskRow", "TaskApp", "First Task"
    name*: string  ## e.g. "Active task", "Empty State", step name
    kind*: StoryKind
    index*: int    ## Position within its group

  StoryGroup* = object
    ## A group of related stories (one component, page, or flow).
    name*: string
    kind*: StoryKind
    description*: string
    items*: seq[StoryItem]
    expanded*: bool

  StoryItem* = object
    ## A single story entry in the sidebar.
    name*: string
    description*: string
    kind*: StoryKind
    group*: string ## Parent group name

  StoryRenderMetadata* = object
    ## Project-owned render metadata for a story, separate from sidebar copy.
    story*: StoryRef
    title*: string
    sourceFile*: string
    sourceLine*: int
    fixtureName*: string
    renderKind*: string

  # --- Edit mode ---
  EditMode* = enum
    emView ## Normal view — component interactions work
    emComment ## Click-to-select — comments are gathered for the AI assistant
    emEdit ## Click-to-select — inspector populates on click

  EditorCommandKind* = enum
    eckEdit
    eckComment
    eckInspect
    eckApply
    eckRevert
    eckSave
    eckDiscard
    eckDuplicate
    eckDelete
    eckCreateVariant
    eckCreateStory
    eckOpenSource

  EditorCommandStatus* = enum
    ecsAvailable
    ecsDisabled
    ecsRunning
    ecsSucceeded
    ecsFailed

  EditorCommandPermission* = enum
    ecpReadSource
    ecpWriteSource
    ecpCreateStory
    ecpCreateVariant
    ecpDuplicate
    ecpDelete

  EditorWorkspacePermissions* = object
    readSource*: bool
    writeSource*: bool
    createStory*: bool
    createVariant*: bool
    duplicate*: bool
    delete*: bool

  EditorCommandState* = object
    kind*: EditorCommandKind
    label*: string
    status*: EditorCommandStatus
    diagnostic*: string
    sourceFile*: string
    sourceLine*: int

  # --- Editor default view ---
  EditorView* = enum
    evStoryboard      ## Default: canvas showing user flow diagrams
    evComponentDetail ## Component page: hero, variants, props, guidelines
    evComponentEdit   ## Editable state: CSS inspector + live preview
    evPagePreview     ## Full page preview (Home, Destination Detail, etc.)
    evVectorEditor    ## SVG vector editor for design system symbols

  # --- Storyboard canvas ---
  CanvasItem* = object
    ## A screen/page thumbnail on the storyboard canvas.
    storyRef*: StoryRef
    x*, y*: float          ## Position on canvas
    width*, height*: float ## Thumbnail dimensions
    label*: string

  FlowConnection* = object
    ## Arrow connecting two screens on the storyboard.
    fromItem*: int   ## Index into canvasItems
    toItem*: int
    trigger*: string ## e.g. "Taps + button", "Swipes left"
    label*: string   ## Optional annotation

  # --- Inspector ---
  InspectorSection* = enum
    isLayout      ## Display, flex/grid, alignment, gap, overflow
    isSize        ## Width, height, min/max, flex grow/shrink
    isSpacing     ## Visual box model: margin + padding
    isPosition    ## Position mode, top/right/bottom/left, z-index
    isFill        ## Background color, gradients, opacity
    isStroke      ## Border width, color, style, radius
    isTypography  ## Font, weight, size, line-height, alignment, decoration
    isEffects     ## Shadows, blur, backdrop-blur, blend, transforms
    isTransitions ## CSS transitions and animations
    isFilters     ## CSS filter functions (brightness, contrast, etc.)
    isState       ## ViewModel signal editor

  # --- Component detail page ---
  UsageExample* = object
    ## A Do/Don't example pair.
    description*: string
    isDo*: bool ## true = Do, false = Don't

  ComponentProp* = object
    ## A configurable property on a component.
    name*: string
    propType*: string ## e.g. "string", "bool", "FilterMode"
    defaultVal*: string
    description*: string

  AccessibilityNote* = object
    ## Keyboard/ARIA/screen reader guidance.
    topic*: string ## e.g. "Keyboard", "ARIA", "Screen Reader"
    description*: string

  # --- CSS value input ---
  CSSUnit* = enum
    cuPx, cuEm, cuRem, cuPercent, cuVw, cuVh, cuAuto, cuNone

  CSSValueInput* = object
    ## A numeric CSS value with unit, for scrub-able inputs.
    value*: float
    unit*: CSSUnit
    property*: string ## CSS property name

  # --- Layout helpers ---
  DisplayMode* = enum
    dmBlock, dmFlex, dmGrid, dmInline, dmInlineBlock, dmInlineFlex, dmNone

  FlexDirection* = enum
    fdRow, fdRowReverse, fdColumn, fdColumnReverse

  AlignValue* = enum
    avStart, avCenter, avEnd, avStretch, avBaseline, avSpaceBetween,
      avSpaceAround, avSpaceEvenly

  # --- Vector editor ---
  VectorTool* = enum
    vtSelect    ## Select / move / resize
    vtPen       ## Pen tool: click corners, drag curves
    vtPencil    ## Freehand drawing
    vtRectangle ## Rectangle / rounded rect
    vtEllipse   ## Circle / ellipse
    vtPolygon   ## Regular polygon (n-gon)
    vtStar      ## Star shape
    vtLine      ## Straight line / arrow
    vtText      ## Text on canvas
    vtPathEdit  ## Direct node/handle editing

  BooleanOp* = enum
    boUnion, boSubtract, boIntersect, boExclude, boFlatten

  NodeType* = enum
    ntSmooth     ## Symmetric handles (curve through)
    ntCorner     ## Sharp corner (no handles)
    ntAsymmetric ## Independent handle lengths

  FillType* = enum
    ftSolid, ftLinearGradient, ftRadialGradient, ftPattern, ftNone

  StrokeCapStyle* = enum
    scButt, scRound, scSquare

  StrokeJoinStyle* = enum
    sjMiter, sjRound, sjBevel

  VectorBackendKind* = enum
    vbFabric
    vbPaperJs
    vbSvgJsPlugins
    vbMethodDraw
    vbCustom

  VectorAdapterCapability* = enum
    vacSelection
    vacHitTesting
    vacTransformControls
    vacDrawingTools
    vacPathEditing
    vacTextEditing
    vacGrouping
    vacLayerOrdering
    vacSerialization
    vacSvgImport
    vacSvgExport
    vacAccessibilityMetadata
    vacOptimization
    vacPathBooleanOps
    vacPathDataEditing

  VectorPathBackendOperation* = enum
    vpboUnite
    vpboSubtract
    vpboIntersect
    vpboExclude
    vpboMoveSegment

  VectorPathBackendContract* = object
    backend*: VectorBackendKind
    libraryName*: string
    libraryVersion*: string
    browserGlobal*: string
    license*: string
    operations*: seq[VectorPathBackendOperation]
    adapterModule*: string
    sourceBacked*: bool

  VectorLibraryCandidate* = object
    name*: string
    version*: string
    license*: string
    backend*: VectorBackendKind
    capabilities*: seq[VectorAdapterCapability]
    runtimeNotes*: string
    interopNotes*: string
    selected*: bool
    selectionReason*: string

  VectorAdapterContract* = object
    backend*: VectorBackendKind
    libraryName*: string
    libraryVersion*: string
    adapterModule*: string
    browserGlobal*: string
    license*: string
    capabilities*: seq[VectorAdapterCapability]
    usesThirdPartyInteraction*: bool
    unsupportedAdvancedOperations*: seq[string]

  VectorShapeKind* = enum
    vskRect
    vskEllipse
    vskLine
    vskPath
    vskPolygon
    vskStar
    vskText
    vskGroup
    vskSymbolUse

  VectorAccessibilityRole* = enum
    varDecorative
    varSemantic
    varInteractive

  VectorAccessibilityMeta* = object
    title*: string
    desc*: string
    ariaLabel*: string
    role*: VectorAccessibilityRole
    focusable*: bool

  VectorSourceOrigin* = object
    symbolKey*: string
    file*: string
    schemaKey*: string
    sourceMapKey*: string

  VectorObject* = object
    id*: string
    name*: string
    kind*: VectorShapeKind
    layerId*: string
    x*, y*, width*, height*: float
    rotation*: float
    pathData*: string
    text*: string
    fill*: string
    stroke*: string
    strokeWidth*: float
    dashArray*: string
    strokeCap*: StrokeCapStyle
    strokeJoin*: StrokeJoinStyle
    opacity*: float
    gradient*: string
    blendMode*: string
    children*: seq[string]
    symbolRef*: string
    source*: VectorSourceOrigin
    a11y*: VectorAccessibilityMeta

  VectorLayer* = object
    id*: string
    name*: string
    visible*: bool
    locked*: bool
    objectIds*: seq[string]

  VectorSymbolDefinition* = object
    id*: string
    name*: string
    svgContent*: string
    source*: VectorSourceOrigin
    a11y*: VectorAccessibilityMeta

  VectorDocument* = object
    id*: string
    name*: string
    viewBox*: string
    width*, height*: float
    layers*: seq[VectorLayer]
    objects*: seq[VectorObject]
    symbols*: seq[VectorSymbolDefinition]
    selectedIds*: seq[string]
    source*: VectorSourceOrigin
    a11y*: VectorAccessibilityMeta

  VectorOperationKind* = enum
    vokImportSvg
    vokOptimizeSvg
    vokExportSvg
    vokSelect
    vokDuplicate
    vokDelete
    vokGroup
    vokUngroup
    vokReorderLayer
    vokSetProperty
    vokSetViewBox
    vokAddShape
    vokReuseSymbol
    vokBooleanPath
    vokMovePathSegment

  VectorPropertyKind* = enum
    vpkFill
    vpkStroke
    vpkGradient
    vpkDashArray
    vpkStrokeCap
    vpkStrokeJoin
    vpkOpacity
    vpkTransform
    vpkBlendMode

  VectorPropertyEditRequest* = object
    objectId*: string
    kind*: VectorPropertyKind
    value*: string

  VectorDiagnosticKind* = enum
    vdkMissingLibrary
    vdkUnsupportedOperation
    vdkMissingDocument
    vdkMissingSelection
    vdkMissingObject
    vdkInvalidSvg
    vdkMissingTitle
    vdkMissingDescription
    vdkMissingAria
    vdkContrastViolation
    vdkInvalidFocusability

  VectorDiagnostic* = object
    kind*: VectorDiagnosticKind
    message*: string
    objectId*: string
    schemaKey*: string

  VectorOperationResult* = object
    ok*: bool
    operation*: VectorOperationKind
    document*: VectorDocument
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[VectorDiagnostic]

  VectorEditTransaction* = object
    operation*: VectorOperationKind
    beforeDocument*: VectorDocument
    afterDocument*: VectorDocument
    sourceEdit*: SourceEditPlan

  VectorSymbol* = object
    ## A reusable vector symbol in the design system.
    name*: string
    category*: string   ## e.g. "Icons", "Illustrations", "Logos"
    svgContent*: string ## Raw SVG source
    tags*: seq[string]  ## Searchable tags
    width*, height*: float

  PropertyOrigin* = enum
    poTailwindClass ## From a Tailwind utility in class="..."
    poSetStyle      ## From a direct setStyle call
    poThemeToken    ## From themeColor/themeSpacing
    poConstant      ## From a Nim const/let
    poInherited     ## Inherited from parent/theme

  PropertyInfo* = object
    ## A single CSS property with its value and source origin.
    name*: string         ## CSS property name (e.g. "padding")
    value*: string        ## Resolved value (e.g. "16")
    origin*: PropertyOrigin
    originDetail*: string ## e.g. "class:p-4" or "themeColor(\"primary\")"
    sourceLine*: int      ## Line in source file
    sourceFile*: string   ## Source file path
    sharedCount*: int     ## How many elements share this origin (0 = local only)
    schemaKey*: string    ## Project schema key when this is schema-owned
    tokenName*: string    ## Token name when token-backed
    variantKey*: string   ## Responsive/state variant key when variant-backed
    directStyleAllowed*: bool ## True only when the source map permits direct edits

  CSSPropertyCategory* = enum
    cpcLayout
    cpcFlexGrid
    cpcSize
    cpcSpacing
    cpcPosition
    cpcTypography
    cpcColor
    cpcBorder
    cpcEffects
    cpcFilters
    cpcTransitions
    cpcTransforms
    cpcOverflow
    cpcInteractionState
    cpcAccessibilityVisual

  CSSValueKind* = enum
    cvkKeyword
    cvkLength
    cvkPercentage
    cvkLengthPercentage
    cvkColor
    cvkGradient
    cvkShadow
    cvkFontStack
    cvkZIndex
    cvkOpacity
    cvkTimingFunction
    cvkTokenReference
    cvkTransform
    cvkTransition
    cvkFilter
    cvkOverflow
    cvkAccessibility

  CSSSourcePlanKind* = enum
    cspStructuredSchemaUpdate
    cspTokenUpdate
    cspTailwindClassReplacement
    cspInlineStyleUpdate
    cspPropertyAddition
    cspPropertyRemoval

  CSSResponsiveVariant* = enum
    crvBase
    crvHover
    crvFocus
    crvActive
    crvDisabled
    crvSm
    crvMd
    crvLg
    crvXl

  CSSPropertyValue* = object
    ## Parsed and normalized CSS value used by the source-backed edit engine.
    kind*: CSSValueKind
    raw*: string
    canonical*: string
    unit*: string
    numeric*: float
    tokenName*: string
    variant*: CSSResponsiveVariant

  CSSPropertyEditorVM* = object
    ## Headless property editor contract. Views may render controls from this.
    property*: string
    category*: CSSPropertyCategory
    value*: CSSPropertyValue
    allowedValueKinds*: seq[CSSValueKind]
    origin*: PropertyOrigin
    sourcePlanKind*: CSSSourcePlanKind
    sharedCount*: int
    supportsLocalScope*: bool
    supportsSharedScope*: bool
    diagnostics*: seq[PropertyEditDiagnostic]

  CSSSourcePreview* = object
    plan*: SourceEditPlan
    beforeText*: string
    afterText*: string

  CSSSourceConflict* = object
    file*: string
    property*: string
    expectedOldValue*: string
    actualValue*: string
    message*: string

  PropertyEditKind* = enum
    pekCss
    pekLayout
    pekState

  PropertyEditScope* = enum
    pesUnspecified
    pesLocal
    pesShared

  PropertyEditOrigin* = enum
    peoInspector
    peoReviewFix
    peoAgent

  PropertyEditStatus* = enum
    pesAccepted
    pesRejected
    pesNeedsScope

  PropertyEditDiagnosticKind* = enum
    pedUnsupportedDirectStyle
    pedViewModelBoundary
    pedTokenDrift
    pedAccessibility
    pedSharedScopeRequired
    pedMissingSelection
    pedUnknownProperty
    pedInvalidCssValue
    pedInvalidTokenReference
    pedInvalidPropertyCombination
    pedSchemaViolation
    pedSourceConflict

  PropertyEditDiagnostic* = object
    kind*: PropertyEditDiagnosticKind
    message*: string
    file*: string
    line*: int
    property*: string

  PropertyEditRequest* = object
    property*: string
    newValue*: string
    kind*: PropertyEditKind
    scope*: PropertyEditScope
    origin*: PropertyEditOrigin

  SourceEditPlan* = object
    ## Source patch description produced by headless editing.
    file*: string
    line*: int
    property*: string
    oldValue*: string
    newValue*: string
    originDetail*: string
    scope*: PropertyEditScope
    planKind*: CSSSourcePlanKind
    schemaKey*: string
    tokenName*: string
    variantKey*: string
    reversible*: bool
    previewBefore*: string
    previewAfter*: string
    formatterHook*: string
    regeneratorHook*: string
    conflictKey*: string
    expectedOldValue*: string

  SourceEditAdapter* = proc(plan: SourceEditPlan): bool {.closure.}

  PropertyEditResult* = object
    status*: PropertyEditStatus
    record*: EditRecord
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[PropertyEditDiagnostic]

  ElementRef* = object
    ## Reference to a selected element in the preview.
    id*: string            ## Stable source-backed element identity
    sourceKey*: string     ## Source/schema key shared by DOM, tree rows, breadcrumbs
    domPath*: string       ## DOM path used as a fallback browser selector
    schemaKey*: string     ## Primary editable source schema entry
    tag*: string           ## e.g. "div", "span", "button"
    sourceFile*: string
    sourceLine*: int
    sourceColumn*: int
    properties*: seq[PropertyInfo]
    children*: seq[string] ## Child element summaries for tree view
    ancestors*: seq[string] ## Breadcrumb labels from root to selected element
    ancestorIds*: seq[string] ## Breadcrumb identities from root to selected element
    depth*: int            ## Nesting depth

  ElementLayerRow* = object
    ## Source-backed row in the editor-owned element/layers tree.
    id*: string
    parentId*: string
    label*: string
    tag*: string
    sourceKey*: string
    schemaKey*: string
    domPath*: string
    sourceFile*: string
    sourceLine*: int
    depth*: int
    childCount*: int
    expanded*: bool
    selected*: bool
    hovered*: bool
    hidden*: bool
    locked*: bool

  # --- Agent chat ---
  ChatMessageKind* = enum
    cmkUser    ## User's prompt
    cmkAgent   ## Agent's response
    cmkContext ## Editor-injected context (accumulated edits)
    cmkError   ## Error message

  ChatMessage* = object
    kind*: ChatMessageKind
    text*: string
    timestamp*: float

  AgentBackendSelection* = enum
    absUnconfigured
    absAcp
    absAgentHarbor

  AgentSourceMapEntry* = object
    elementTag*: string
    property*: string
    file*: string
    line*: int
    originDetail*: string
    schemaKey*: string
    tokenName*: string
    variantKey*: string

  AgentDesignSystemSchemaEntry* = object
    key*: string
    kind*: string
    file*: string
    path*: string
    property*: string

  AgentFileDiff* = object
    file*: string
    beforeText*: string
    afterText*: string
    summary*: string

  AgentDiagnosticSnapshot* = object
    source*: string
    severity*: string
    category*: string
    message*: string
    file*: string
    line*: int
    property*: string

  AgentPromptContext* = object
    selectedStory*: StoryRef
    selectedElement*: ElementRef
    accumulatedEdits*: seq[EditRecord]
    sourceMap*: seq[AgentSourceMapEntry]
    designSystemSchema*: seq[AgentDesignSystemSchemaEntry]
    diagnostics*: seq[AgentDiagnosticSnapshot]
    currentFileDiffs*: seq[AgentFileDiff]
    platform*: Platform
    backend*: AgentBackendSelection

  AgentPromptAdapter* = proc(prompt: string;
                              context: AgentPromptContext): bool {.closure.}
  AgentCancelAdapter* = proc(): bool {.closure.}

  EditRecord* = object
    ## Record of a user edit made via the inspector.
    file*: string
    line*: int
    property*: string
    oldValue*: string
    newValue*: string
    origin*: PropertyOrigin
    originDetail*: string
    scope*: PropertyEditScope
    isShared*: bool
    editOrigin*: PropertyEditOrigin
    sourcePlanKind*: CSSSourcePlanKind

  CSSPropertyEditTransaction* = object
    record*: EditRecord
    sourceEdit*: SourceEditPlan
    beforeElement*: ElementRef
    afterElement*: ElementRef

  AgentEditProposalStatus* = enum
    aepsProposed
    aepsAccepted
    aepsPartiallyAccepted
    aepsRejected
    aepsReverted
    aepsFailed

  AgentPermissionStatus* = enum
    apsPending
    apsGranted
    apsDenied
    apsCancelled

  AgentPermissionRequest* = object
    id*: string
    title*: string
    detail*: string
    options*: seq[string]
    status*: AgentPermissionStatus

  AgentEditProposal* = object
    id*: string
    title*: string
    summary*: string
    sourceEdits*: seq[SourceEditPlan]
    diffs*: seq[AgentFileDiff]
    reviewDiagnostics*: seq[AgentDiagnosticSnapshot]
    status*: AgentEditProposalStatus
    selectedEditIndexes*: seq[int]
    appliedPatches*: seq[WorkspaceFilePatch]

  # --- Review ---
  ViolationSeverity* = enum
    vsError
    vsWarning

  ViolationCategory* = enum
    vcViewModelBoundary
    vcDryTokens
    vcTailwindPreference
    vcStoryCoverage
    vcMockCompleteness
    vcAccessibility
    vcDirectStyle
    vcDeprecatedDsl
    vcHtmlBuilder

  Violation* = object
    severity*: ViolationSeverity
    category*: ViolationCategory
    message*: string
    file*: string
    line*: int
    autoFixable*: bool

  SourceSnapshot* = object
    ## Project-owned source text supplied to headless review.
    file*: string
    content*: string

  # --- Workspace source edits ---
  WorkspaceSchemaKind* = enum
    wskToken
    wskComponentVariant
    wskStoryFixture
    wskSvgSymbol
    wskPageMetadata
    wskJourneyMetadata
    wskSourceMap

  WorkspaceEditStage* = enum
    wesClean
    wesDirty
    wesApplying
    wesFormatting
    wesRegenerating
    wesCompiling
    wesReloading
    wesReviewing
    wesFailed

  WorkspaceEditDiagnosticKind* = enum
    wedMissingAdapter
    wedMissingOperation
    wedMissingSchema
    wedUnsafeSourceMap
    wedSourceConflict
    wedReadFailed
    wedPatchFailed
    wedWriteFailed
    wedFormatFailed
    wedRegenerateFailed
    wedCompileFailed
    wedReloadFailed
    wedReviewFailed
    wedRollbackFailed

  WorkspaceEditableSchemaEntry* = object
    ## Project-owned schema/source map entry used to resolve stable edit keys.
    key*: string
    kind*: WorkspaceSchemaKind
    file*: string
    path*: string
    generatedModule*: string
    story*: StoryRef
    property*: string

  WorkspaceEditDiagnostic* = object
    kind*: WorkspaceEditDiagnosticKind
    message*: string
    file*: string
    schemaKey*: string
    property*: string

  WorkspaceReadResult* = object
    ok*: bool
    content*: string
    diagnostics*: seq[WorkspaceEditDiagnostic]

  WorkspaceOperationResult* = object
    ok*: bool
    message*: string
    diagnostics*: seq[WorkspaceEditDiagnostic]
    affectedStories*: seq[StoryRef]
    fullReload*: bool

  WorkspaceFilePatch* = object
    plan*: SourceEditPlan
    schema*: WorkspaceEditableSchemaEntry
    file*: string
    beforeContent*: string
    afterContent*: string
    affectedStory*: StoryRef
    fullReload*: bool

  WorkspacePatchResult* = object
    ok*: bool
    patch*: WorkspaceFilePatch
    diagnostics*: seq[WorkspaceEditDiagnostic]

  WorkspaceReviewResult* = object
    ok*: bool
    violations*: seq[Violation]
    diagnostics*: seq[WorkspaceEditDiagnostic]

  WorkspaceEditResult* = object
    ok*: bool
    stage*: WorkspaceEditStage
    diagnostics*: seq[WorkspaceEditDiagnostic]
    patches*: seq[WorkspaceFilePatch]
    affectedStories*: seq[StoryRef]
    fullReload*: bool

  WorkspaceEditAdapter* = ref object
    ## Project-owned implementation for source reads, writes, codegen, and review.
    ## The framework owns transaction ordering and rollback around these callbacks.
    schema*: seq[WorkspaceEditableSchemaEntry]
    readFile*: proc(file: string): WorkspaceReadResult {.closure.}
    writeFile*: proc(file, content: string): WorkspaceOperationResult {.closure.}
    patchFile*: proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult {.closure.}
    formatFiles*: proc(files: seq[string]): WorkspaceOperationResult {.closure.}
    regenerate*: proc(schemaKeys: seq[string]): WorkspaceOperationResult {.closure.}
    compile*: proc(stories: seq[StoryRef]): WorkspaceOperationResult {.closure.}
    reloadPreview*: proc(stories: seq[StoryRef];
      fullReload: bool): WorkspaceOperationResult {.closure.}
    review*: proc(patches: seq[WorkspaceFilePatch]): WorkspaceReviewResult {.closure.}

  # --- Foundations and component variant editors ---
  FoundationTokenKind* = enum
    ftkColorPalette
    ftkSemanticColor
    ftkTypographyScale
    ftkSpacingScale
    ftkRadiusScale
    ftkShadow
    ftkMotion
    ftkDensity
    ftkAccessibilityConstraint

  FoundationEditDiagnosticKind* = enum
    fedInvalidTokenValue
    fedContrastViolation
    fedAliasCycle
    fedMissingTokenSchema

  FoundationTokenEntry* = object
    key*: string
    kind*: FoundationTokenKind
    value*: string
    aliasOf*: string
    foreground*: string
    background*: string
    minContrast*: float
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    property*: string
    affectedStories*: seq[StoryRef]

  FoundationTokenImpact* = object
    tokenKey*: string
    affectedProperties*: seq[PropertyInfo]
    affectedStories*: seq[StoryRef]
    message*: string

  FoundationEditDiagnostic* = object
    kind*: FoundationEditDiagnosticKind
    message*: string
    key*: string
    file*: string
    line*: int

  FoundationEditResult* = object
    status*: PropertyEditStatus
    sourceEdit*: SourceEditPlan
    impacts*: seq[FoundationTokenImpact]
    diagnostics*: seq[FoundationEditDiagnostic]

  ComponentVariantFieldKind* = enum
    cvfkProp
    cvfkState
    cvfkSampleData
    cvfkResponsiveBehavior
    cvfkUsageExample
    cvfkStoryMetadata

  ComponentVariantDiagnosticKind* = enum
    cvdMissingVariantFixture
    cvdInconsistentStoryMetadata
    cvdMissingVariantSchema
    cvdInvalidVariantValue

  ComponentVariantField* = object
    name*: string
    kind*: ComponentVariantFieldKind
    value*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string

  ComponentVariantDefinition* = object
    component*: string
    variantKey*: string
    story*: StoryRef
    fixtureName*: string
    metadataName*: string
    fields*: seq[ComponentVariantField]
    usageExamples*: seq[UsageExample]

  ComponentVariantDiagnostic* = object
    kind*: ComponentVariantDiagnosticKind
    message*: string
    component*: string
    variantKey*: string
    field*: string
    file*: string
    line*: int

  ComponentVariantEditResult* = object
    status*: PropertyEditStatus
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[ComponentVariantDiagnostic]
    affectedStory*: StoryRef

  # --- Preview ---
  Platform* = enum
    pfWeb
    pfIOS
    pfAndroid

  PreviewViewport* = enum
    pvDesktop
    pvTablet
    pvMobile

  ProjectPreviewStatus* = enum
    ppsMissingSelection
    ppsUnsupportedStory
    ppsRendered

  ProjectPreview* = object
    ## Headless preview payload produced by a project-owned preview hook.
    status*: ProjectPreviewStatus
    story*: StoryRef
    title*: string
    bodyText*: string
    documentHtml*: string
    metadata*: StoryRenderMetadata

  ProjectPreviewHook* = proc(story: StoryRef;
                            platform: Platform): ProjectPreview {.closure.}

  # --- Flow player ---
  PlayState* = enum
    psStopped
    psPlaying
    psPaused

  FlowStep* = object
    ## A single step in a user flow.
    screenRef*: StoryRef ## Which story/page to show
    action*: string      ## What the user does (e.g. "Taps + button")
    description*: string ## Narrative context

  # --- Panel visibility ---
  EditorPanel* = enum
    epSidebar
    epInspector

  PanelVisibility* = object
    sidebar*: bool
    inspector*: bool
