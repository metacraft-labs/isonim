## IsoNim Editor — shared types used across all ViewModels.
## Pure data types with no rendering or presentation logic.

type
  # --- Story types ---
  StoryKind* = enum
    skFoundation   ## Design token display (colors, typography, spacing)
    skComponent    ## Individual component in a specific state
    skPattern      ## Composition pattern (forms, tables, navigation)
    skPage         ## Full page composition with realistic data
    skFlow         ## Multi-step user navigation sequence
    skGuideline    ## Usage guideline (do/don't, content, motion, a11y)
    skVectorSymbol ## M-EVP-8: Reusable SVG symbol (icon/illustration).
                   ## Carries a sidebar "edit" affordance that opens the
                   ## vector editor (see ``openVectorEditor``).

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
    usesVectorSymbols*: seq[string]
      ## M-EVP-8: names of vector symbols this story references. The
      ## vector editor's usage-context companion reads this to surface
      ## every Page/Component that uses the symbol being edited.

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

  # --- Editor surface (TBAR-M3) ---
  Surface* = enum
    ## Top-bar surface toggle introduced in TBAR-M3. The editor switches
    ## between the live preview workspace and the per-brief markdown
    ## spec pane via the segmented control in the top toolbar.
    ##
    ##   * ``sPreview`` — the default surface. Shows the preview canvas
    ##     plus the right-side property/AI-assistant panel.
    ##   * ``sSpec`` — read-only brief markdown view in this milestone
    ##     (TBAR-M4 replaces the placeholder with a TipTap-backed
    ##     renderer). The right-side property panel is hidden while
    ##     this surface is active so brief reading stays distraction
    ##     free.
    sPreview
    sSpec

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
    eckSelectPrevious
    eckSelectNext
    eckSelectParent
    eckSelectChild
    eckFocusInspector
    eckIncrementProperty
    eckDecrementProperty
    eckUndo
    eckRedo
    eckToggleSidebar
    eckToggleInspector
    eckOpenCommandPalette
    eckNavigateLayersUp
    eckNavigateLayersDown

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

  EditorShortcutBinding* = object
    kind*: EditorCommandKind
    shortcut*: string
    scope*: string
    description*: string

  EditorCommandPaletteEntry* = object
    kind*: EditorCommandKind
    label*: string
    shortcut*: string
    section*: string
    status*: EditorCommandStatus
    diagnostic*: string

  EditorPerformanceBudgetKind* = enum
    epbkStorySelection
    epbkElementSelection
    epbkModeSwitch
    epbkPropertyEditPreview
    epbkSaveReload
    epbkLargeSidebarSearch

  EditorPerformanceBudget* = object
    kind*: EditorPerformanceBudgetKind
    label*: string
    maxMs*: int

  EditorTelemetryEvent* = object
    name*: string
    durationMs*: int
    budgetKind*: EditorPerformanceBudgetKind
    withinBudget*: bool
    detail*: string

  # --- Editor default view ---
  EditorView* = enum
    evStoryboard      ## Default: canvas showing user flow diagrams
    evComponentDetail ## Component page: hero, variants, props, guidelines
    evComponentEdit   ## Editable state: CSS inspector + live preview
    evPagePreview     ## Full page preview (Home, Destination Detail, etc.)
    evFoundationsPage ## Dedicated design-token foundations editing workflow
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
    isLayout          ## Display, flex/grid, alignment, gap, overflow
    isSize            ## Width, height, min/max, flex grow/shrink
    isSpacing         ## Visual box model: margin + padding
    isPosition        ## Position mode, top/right/bottom/left, z-index
    isFill            ## Background color, gradients, opacity
    isStroke          ## Border width, color, style, radius
    isTypography      ## Font, weight, size, line-height, alignment, decoration
    isEffects         ## Shadows, blur, backdrop-blur, blend, transforms
    isTransitions     ## CSS transitions and animations
    isFilters         ## CSS filter functions (brightness, contrast, etc.)
    isState           ## ViewModel signal editor
    isSource          ## Source ownership, cascade, and impact controls
    # Phase C (2026-05-28): the section catalogue in the spec
    # (`Front-Ends/IsoNim/isonim-editor.md` §"Section catalogue")
    # introduces four sections that did not exist in the M19
    # twelve-section enum: Appearance, Selection colors,
    # Component properties, Export. The slugs `appearance`,
    # `selection-colors`, `component-properties`, and `export` in
    # ``inspectorPlaceholderSections`` map to these.
    isAppearance      ## Opacity, corner radius, blend mode, individual corners
    isSelectionColors ## Auto-computed colours present in the selection
    isComponentProps  ## Component instance variant / state / slot properties
    isExport          ## Export settings (size, format, suffix) per entry

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

  VectorHandleKind* = enum
    vhkIn
    vhkOut

  VectorPathNode* = object
    id*: string
    x*, y*: float
    inX*, inY*: float
    outX*, outY*: float
    nodeType*: NodeType
    selected*: bool

  VectorAlignment* = enum
    vaLeft
    vaCenter
    vaRight
    vaTop
    vaMiddle
    vaBottom

  VectorDistributeAxis* = enum
    vdaHorizontal
    vdaVertical

  VectorZOrder* = enum
    vzoBringForward
    vzoSendBackward
    vzoBringToFront
    vzoSendToBack

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
    pathNodes*: seq[VectorPathNode]
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
    vokSelectPathNode
    vokMovePathNode
    vokInsertPathNode
    vokDeletePathNode
    vokConvertPathNode
    vokDragPathHandle
    vokAlignSelection
    vokDistributeSelection
    vokReorderSelection
    vokNudgeSelection
    vokSnapSelection

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

  VectorSymbolUsage* = object
    ## M-EVP-8: a single Page/Component story that references the vector
    ## symbol currently loaded in the vector editor. Drives the
    ## usage-context companion panel (split for <=3 usages, carousel for
    ## >3 usages).
    story*: StoryRef
    anchor*: string    ## Optional element path / fragment selector
    thumbnail*: string ## Optional thumbnail URI / inline SVG

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

  SourceScopeChoiceKind* = enum
    sskLocalInstance
    sskStoryFixture
    sskComponentSchemaApi
    sskSharedClass
    sskComponentToken
    sskSemanticToken
    sskGlobalPrimitiveToken

  SourceScopeRiskLevel* = enum
    ssrNone
    ssrLow
    ssrMedium
    ssrHigh

  SourceScopeImpact* = object
    ownerLabel*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    usageCount*: int
    affectedComponents*: seq[string]
    affectedStories*: seq[StoryRef]
    riskLevel*: SourceScopeRiskLevel
    summary*: string

  SourceScopeChoice* = object
    kind*: SourceScopeChoiceKind
    label*: string
    ownerLabel*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    editable*: bool
    usageCount*: int
    affectedComponents*: seq[string]
    affectedStories*: seq[StoryRef]
    riskLevel*: SourceScopeRiskLevel
    impact*: SourceScopeImpact
    reason*: string

  SharedDesignEditorCategory* = enum
    sdecColor
    sdecSpacing
    sdecRadii
    sdecTypography
    sdecShadowElevation
    sdecMotion
    sdecComponentToken
    sdecSemanticToken
    sdecSharedClass
    sdecUnsupported

  SharedDesignEditorStatus* = enum
    sdesEditable
    sdesReadOnly
    sdesUnsupported

  SharedDesignFlowKind* = enum
    sdfEditValue
    sdfDetach
    sdfPromote
    sdfTokenize

  SharedDesignCommitPreview* = object
    property*: string
    sourceScope*: SourceScopeChoiceKind
    plan*: SourceEditPlan
    sourceDiff*: string
    affectedComponents*: seq[string]
    affectedStories*: seq[StoryRef]
    livePreviewable*: bool
    dependentExamplesLivePreviewed*: bool
    rebuildRequired*: bool
    fullReloadRequired*: bool
    regenerationRequired*: bool
    reloadRequired*: bool
    previewStateLabel*: string
    diagnostics*: seq[PropertyEditDiagnostic]

  SharedDesignPropertyEditor* = object
    property*: string
    category*: SharedDesignEditorCategory
    value*: CSSPropertyValue
    sourceScope*: SourceScopeChoice
    status*: SharedDesignEditorStatus
    readOnlyReason*: string
    commitPreview*: SharedDesignCommitPreview
    flowCapabilities*: seq[SharedDesignFlowKind]
    diagnostics*: seq[PropertyEditDiagnostic]

  SharedDesignEditResult* = object
    status*: PropertyEditStatus
    editor*: SharedDesignPropertyEditor
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[PropertyEditDiagnostic]

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
    sourceScopeChoices*: seq[SourceScopeChoice]
    impactSummaries*: seq[SourceScopeImpact]
    diagnostics*: seq[PropertyEditDiagnostic]

  LongTailPropertyEvidenceStatus* = enum
    ltpesValidated
    ltpesReadOnly
    ltpesBrowserLimited
    ltpesConsumerUnvalidated
    ltpesUnsupported

  LongTailPropertyEvidenceRow* = object
    ## M49 evidence ledger for non-core CSS/property editor families.
    family*: string
    representativeProperties*: seq[string]
    status*: LongTailPropertyEvidenceStatus
    sourceWrite*: bool
    headlessValidation*: bool
    browserBehavior*: bool
    visualEvidence*: bool
    metacraftEvidence*: bool
    limitations*: string
    implementationReferences*: seq[string]

  PrimitiveControlFamily* = enum
    pcfNumeric
    pcfColor
    pcfGradient
    pcfShadow
    pcfTypography
    pcfBorderRadiusStroke
    pcfMotion

  SourceSpan* = object
    file*: string
    line*: int
    column*: int
    endLine*: int
    endColumn*: int

  LayoutControlFamily* = enum
    lcfFlexAutoLayout
    lcfGrid
    lcfConstraints
    lcfResponsiveOverride
    lcfCanvasGuide

  LayoutControlCapability* = enum
    lccFlexDirection
    lccFlexWrap
    lccGap
    lccPadding
    lccAlign
    lccJustify
    lccDistribution
    lccHugFillFixedSizing
    lccChildOrder
    lccPerChildAlignment
    lccGridTemplateTracks
    lccGridGap
    lccGridPlacement
    lccGridAutoFlow
    lccGridNamedAreas
    lccConstraints
    lccMinMax
    lccIntrinsicContentSizing
    lccAspectRatio
    lccOverflowStrategy
    lccBreakpointScopedOverride
    lccProjectDefinedMode
    lccSpacingMeasurement
    lccGapOverlay
    lccAlignHandle
    lccResizeHandle
    lccSnapLine
    lccLayoutDiagnostic
    lccSourceRoutedPlan

  ResponsiveModeKind* = enum
    rmkDesktop
    rmkTablet
    rmkMobile
    rmkProjectDefined

  ResponsiveEditMode* = object
    key*: string
    label*: string
    kind*: ResponsiveModeKind
    sourceSpan*: SourceSpan

  PrimitiveControlCapability* = enum
    pccSelectAllFocus
    pccLabelScrub
    pccPrecisionModifiers
    pccArrowIncrement
    pccUnitCycle
    pccMathExpression
    pccMinMaxValidation
    pccReset
    pccTokenBinding
    pccUndoJournal
    pccSwatches
    pccVariableMode
    pccColorFormats
    pccOpacity
    pccEyedropper
    pccCopyPaste
    pccContrastPreview
    pccGradientStops
    pccGradientAngle
    pccGradientType
    pccShadowLayers
    pccShadowCrosshair
    pccInsetShadow
    pccElevationToken
    pccTypographyStyle
    pccResponsiveText
    pccTruncateWrap
    pccLinkedCorners
    pccSideSpecificStroke
    pccCanvasHandle
    pccBezierCurve
    pccMotionPreset
    pccReducedMotionDiagnostic
    pccLivePreview
    pccSourceCommit

  PrimitiveControlModel* = object
    ## Normalized, source-aware model for a primitive property control.
    family*: PrimitiveControlFamily
    property*: string
    raw*: string
    canonical*: string
    unit*: string
    numeric*: float
    tokenName*: string
    sourcePlanKind*: CSSSourcePlanKind
    sourceSerialized*: string
    livePreviewValue*: string
    minValue*: float
    maxValue*: float
    valid*: bool
    reducedMotionDiagnostic*: string
    capabilities*: seq[PrimitiveControlCapability]
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
    sourceScope*: SourceScopeChoiceKind
    planKind*: CSSSourcePlanKind
    schemaKey*: string
    tokenName*: string
    variantKey*: string
    sourceScopeChoices*: seq[SourceScopeChoice]
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
    sourceScopeChoices*: seq[SourceScopeChoice]

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

  ReviewAnnotationSeverity* = enum
    rasInfo
    rasWarning
    rasError

  ReviewAnnotationState* = enum
    ransOpen
    ransResolved
    ransDismissed

  ReviewViewportContext* = object
    platform*: Platform
    viewport*: PreviewViewport
    width*: int
    height*: int
    zoom*: float

  ReviewSourceOwnershipContext* = object
    ownerPackage*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    nodeKey*: string
    generatedViewFile*: string
    generatedViewLine*: int
    cssModuleFile*: string
    cssModuleClass*: string
    tailwindUtilities*: seq[string]
    fallbackAllowed*: bool
    unstructuredViewCode*: bool

  ReviewAnnotation* = object
    id*: string
    text*: string
    selectedElement*: ElementRef
    elementId*: string
    elementSourceKey*: string
    domPath*: string
    selector*: string
    ancestry*: string
    screenshotRef*: string
    domSnapshot*: string
    viewport*: ReviewViewportContext
    ownership*: ReviewSourceOwnershipContext
    source*: string
    severity*: ReviewAnnotationSeverity
    suggestedScope*: PropertyEditScope
    sourceScopeChoices*: seq[SourceScopeChoice]
    includedInPrompt*: bool
    state*: ReviewAnnotationState

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
    pendingSourceEdits*: seq[SourceEditPlan]
    sourceMap*: seq[AgentSourceMapEntry]
    designSystemSchema*: seq[AgentDesignSystemSchemaEntry]
    selectedSchemaNodes*: seq[AgentDesignSystemSchemaEntry]
    tokenContext*: seq[string]
    componentVariantContext*: seq[string]
    reviewAnnotations*: seq[ReviewAnnotation]
    screenshotRefs*: seq[string]
    domSnapshots*: seq[string]
    designSystemConstraints*: seq[string]
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
    sourceScope*: SourceScopeChoiceKind
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

  AgentEditProposalValidity* = enum
    aepvCurrent
    aepvNeedsRebase
    aepvStale

  AgentProposalImpact* = object
    summary*: string
    affectedStories*: seq[StoryRef]
    affectedComponents*: seq[string]
    affectedPages*: seq[string]
    diagnostics*: seq[AgentDiagnosticSnapshot]

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
    targetScopes*: seq[PropertyEditScope]
    impact*: AgentProposalImpact
    affectedStories*: seq[StoryRef]
    tests*: seq[string]
    validity*: AgentEditProposalValidity
    validityDiagnostics*: seq[AgentDiagnosticSnapshot]
    basePendingEditCount*: int

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

  WriteBridgeClientState* = enum
    wbcsOffline
    wbcsConnecting
    wbcsDegraded
    wbcsReadOnly
    wbcsStaged
    wbcsWritable
    wbcsSaving
    wbcsConflict
    wbcsFailed
    wbcsRecovered

  WriteBridgeProtocolContract* = object
    version*: string
    capabilities*: seq[string]
    requiredCapabilities*: seq[string]
    missingCapabilities*: seq[string]
    maxFileBytes*: int
    canRead*: bool
    canWrite*: bool
    supportsStructuredDiagnostics*: bool

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
    wedBridgeUnavailable
    wedExternalChange

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
    generatedArtifacts*: seq[string]
    requiredTestCommands*: seq[string]
    reviewDiagnostics*: seq[WorkspaceEditDiagnostic]

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
    generatedArtifacts*: seq[string]
    requiredTestCommands*: seq[string]
    reviewDiagnostics*: seq[WorkspaceEditDiagnostic]

  WorkspaceEditAdapter* = ref object
    ## Project-owned implementation for source reads, writes, codegen, and review.
    ## The framework owns transaction ordering and rollback around these callbacks.
    stagingOnly*: bool
    bridgeLabel*: string
    allowMissingExpectedOldValue*: bool
    schema*: seq[WorkspaceEditableSchemaEntry]
    readFile*: proc(file: string): WorkspaceReadResult {.closure.}
    writeFile*: proc(file, content: string): WorkspaceOperationResult {.closure.}
    writeFiles*: proc(patches: seq[WorkspaceFilePatch]): WorkspaceOperationResult {.closure.}
      ## Optional transactional batch write. Adapters that set this callback must
      ## either write every patch or leave the workspace unchanged.
    patchFile*: proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult {.closure.}
    formatFiles*: proc(files: seq[string]): WorkspaceOperationResult {.closure.}
    regenerate*: proc(schemaKeys: seq[string]): WorkspaceOperationResult {.closure.}
    compile*: proc(stories: seq[StoryRef]): WorkspaceOperationResult {.closure.}
    reloadPreview*: proc(stories: seq[StoryRef];
      fullReload: bool): WorkspaceOperationResult {.closure.}
    review*: proc(patches: seq[WorkspaceFilePatch]): WorkspaceReviewResult {.closure.}

  # --- Design-system schema and source ownership ---
  DesignSchemaNodeKind* = enum
    dsnFoundation
    dsnSemanticToken
    dsnComponentToken
    dsnComponentVariant
    dsnComponentState
    dsnDensityMode
    dsnResponsiveMode
    dsnClassDefinition
    dsnStyleDefinition
    dsnStoryFixture

  DesignTokenModeKind* = enum
    dtmkLight
    dtmkDark
    dtmkDensity
    dtmkPlatform
    dtmkBrand
    dtmkBreakpoint

  DesignSchemaReviewLevel* = enum
    dsrlNone
    dsrlLocal
    dsrlShared
    dsrlAccessibility
    dsrlDesignSystem

  DesignSchemaAccessibilityImpactKind* = enum
    dsaiNone
    dsaiContrast
    dsaiTouchTarget
    dsaiMotion
    dsaiKeyboardFocus

  DesignTokenModeValue* = object
    kind*: DesignTokenModeKind
    name*: string
    value*: string
    sourceSpan*: SourceSpan
    schemaKey*: string

  DesignSchemaNode* = object
    ## Project-owned schema node. IsoNim treats this as data, not as a
    ## framework-owned token file format.
    key*: string
    kind*: DesignSchemaNodeKind
    name*: string
    component*: string
    property*: string
    value*: string
    sourceSpan*: SourceSpan
    modeValues*: seq[DesignTokenModeValue]
    stories*: seq[StoryRef]
    components*: seq[string]
    pages*: seq[string]
    usageCount*: int
    foreground*: string
    background*: string
    minContrast*: float
    accessibilityImpact*: DesignSchemaAccessibilityImpactKind
    reviewLevel*: DesignSchemaReviewLevel

  DesignSourceOwnership* = object
    ## Graph edge from a selected DOM property to project-owned source.
    elementSourceKey*: string
    domPath*: string
    property*: string
    schemaKey*: string
    nodeKey*: string
    sourceSpan*: SourceSpan
    generatedViewFile*: string
    generatedViewLine*: int
    cssModuleFile*: string
    cssModuleClass*: string
    tailwindUtilities*: seq[string]
    fallbackInlineFile*: string
    fallbackInlineLine*: int
    fallbackAllowed*: bool
    unstructuredViewCode*: bool

  DesignSchemaDiagnosticKind* = enum
    dsdUnsupportedSchemaVersion
    dsdMissingProjectOwner
    dsdMissingSourceOwnership
    dsdMissingSourceSpan
    dsdMissingModeSource
    dsdUnstructuredViewCode
    dsdContrastImpact

  DesignSchemaDiagnostic* = object
    kind*: DesignSchemaDiagnosticKind
    message*: string
    file*: string
    line*: int
    property*: string
    schemaKey*: string

  DesignSystemSchema* = object
    ## Versioned framework contract. Concrete schema files remain consumer-owned.
    schemaVersion*: int
    projectId*: string
    ownerPackage*: string
    frameworkContract*: string
    nodes*: seq[DesignSchemaNode]
    sourceOwnership*: seq[DesignSourceOwnership]

  DesignSourceOwnershipReport* = object
    ok*: bool
    property*: string
    nodeKey*: string
    schemaNode*: DesignSchemaNode
    ownership*: DesignSourceOwnership
    planKind*: CSSSourcePlanKind
    diagnostics*: seq[DesignSchemaDiagnostic]

  LayoutControlCommand* = object
    family*: LayoutControlFamily
    property*: string
    value*: string
    scope*: PropertyEditScope
    modeKey*: string
    childSourceKey*: string
    sourceBackedOnly*: bool

  LayoutControlPlan* = object
    ok*: bool
    command*: LayoutControlCommand
    sourceEdit*: SourceEditPlan
    ownership*: DesignSourceOwnershipReport
    capabilities*: seq[LayoutControlCapability]
    diagnostics*: seq[PropertyEditDiagnostic]

  DirectCanvasOperationKind* = enum
    dcokResize
    dcokSpacing
    dcokReorder
    dcokInlineText
    dcokContextCommand

  DirectCanvasContextCommand* = enum
    dcccCopyStyles
    dcccPasteStyles
    dcccReset
    dcccDetach
    dcccPromote
    dcccCreateVariant
    dcccWrap
    dcccDuplicate
    dcccDelete
    dcccOpenSource
    dcccAskAi

  DirectCanvasOperation* = object
    kind*: DirectCanvasOperationKind
    property*: string
    value*: string
    oldValue*: string
    handle*: string
    fromIndex*: int
    toIndex*: int
    command*: DirectCanvasContextCommand
    sourceKey*: string
    measurement*: string

  DirectCanvasOperationResult* = object
    ok*: bool
    operation*: DirectCanvasOperation
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[PropertyEditDiagnostic]
    commandState*: EditorCommandState
    measurement*: string

  DesignSchemaImpact* = object
    schemaKey*: string
    usageCount*: int
    affectedStories*: seq[StoryRef]
    affectedComponents*: seq[string]
    affectedPages*: seq[string]
    modes*: seq[DesignTokenModeValue]
    contrastRatio*: float
    minContrast*: float
    accessibilityImpact*: DesignSchemaAccessibilityImpactKind
    reviewLevel*: DesignSchemaReviewLevel
    diagnostics*: seq[DesignSchemaDiagnostic]

  # --- Style, class, cascade, and token manager ---
  StyleScopeChoiceKind* = enum
    sscLocalInstance
    sscStoryFixture
    sscComponentSchema
    sscComponentToken
    sscSharedClass
    sscSemanticToken
    sscGlobalPrimitiveToken

  StyleCascadeLayerKind* = enum
    sclFinalValue
    sclLocalOverride
    sclStoryFixture
    sclComponentSchema
    sclComponentToken
    sclSharedClass
    sclSemanticToken
    sclGlobalPrimitiveToken
    sclInheritedValue
    sclGeneratedFallback

  StyleClassOperationKind* = enum
    scokCreateClass
    scokRenameClass
    scokDuplicateClass
    scokDetachClass
    scokPromoteLocalOverride
    scokTokenizeValue

  StyleDiagnosticKind* = enum
    sdkOneOffValueShouldBeToken
    sdkDuplicateClass
    sdkHardcodedColorMatchingToken
    sdkUnsafeDetachment

  StyleScopeChoice* = object
    kind*: StyleScopeChoiceKind
    label*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    editable*: bool
    impact*: DesignSchemaImpact
    reason*: string

  StyleClassEntry* = object
    className*: string
    properties*: seq[PropertyInfo]
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    sharedCount*: int
    editable*: bool

  StyleCascadeLayer* = object
    kind*: StyleCascadeLayerKind
    property*: string
    value*: string
    finalValue*: string
    inheritedValue*: string
    overridden*: bool
    tokenChain*: seq[string]
    className*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    editable*: bool
    editScope*: StyleScopeChoiceKind

  TokenManagerItem* = object
    key*: string
    value*: string
    aliasOf*: string
    kind*: FoundationTokenKind
    modes*: seq[DesignTokenModeValue]
    usages*: seq[PropertyInfo]
    impact*: DesignSchemaImpact
    contrastRatio*: float
    minContrast*: float
    diagnostics*: seq[FoundationEditDiagnostic]
    dependentStories*: seq[StoryRef]
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    editable*: bool

  StyleDiagnostic* = object
    kind*: StyleDiagnosticKind
    message*: string
    property*: string
    value*: string
    tokenKey*: string
    className*: string
    file*: string
    line*: int
    sourceBackedFix*: SourceEditPlan

  StyleManagerSnapshot* = object
    property*: string
    finalValue*: string
    inheritedValue*: string
    currentClassStack*: seq[StyleClassEntry]
    reusableStyles*: seq[StyleClassEntry]
    cascadeLayers*: seq[StyleCascadeLayer]
    scopeChoices*: seq[StyleScopeChoice]
    tokenItems*: seq[TokenManagerItem]
    diagnostics*: seq[StyleDiagnostic]

  StyleOperationResult* = object
    status*: PropertyEditStatus
    operation*: StyleClassOperationKind
    classEntry*: StyleClassEntry
    sourceEdit*: SourceEditPlan
    diagnostics*: seq[StyleDiagnostic]

  # --- Foundations and component variant editors ---
  FoundationTokenKind* = enum
    ftkColorPalette
    ftkSemanticColor
    ftkTypographyScale
    ftkSpacingScale
    ftkRadiusScale
    ftkShadow
    ftkMotion
    ftkBreakpoint
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

  FoundationEditHistoryEntry* = object
    key*: string
    beforeToken*: FoundationTokenEntry
    afterToken*: FoundationTokenEntry
    sourceEdit*: SourceEditPlan

  ComponentVariantEditHistoryEntry* = object
    beforeVariant*: ComponentVariantDefinition
    afterVariant*: ComponentVariantDefinition
    selectedBefore*: int
    selectedAfter*: int
    sourceEdit*: SourceEditPlan

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

  ComponentPropertyKind* = enum
    cpkEnum
    cpkBoolean
    cpkText
    cpkIcon
    cpkSlotContent
    cpkDataFixture
    cpkDensity
    cpkPlatform
    cpkAccessibilityLabel

  ComponentStateKind* = enum
    cskSize
    cskEmphasis
    cskTone
    cskSelected
    cskDisabled
    cskHover
    cskFocus
    cskPressed
    cskLoading
    cskEmpty
    cskError
    cskSuccess
    cskProjectSpecific

  ComponentPropertyEditMode* = enum
    cpemManual
    cpemAi

  ComponentPropertySurfaceKind* = enum
    cpskComponentApi
    cpskCssOnly

  ComponentEditTargetKind* = enum
    cetFixture
    cetVariant
    cetPseudoState
    cetResponsive
    cetComponentProp
    cetSharedDesignSystem

  ComponentEditBlastRadiusKind* = enum
    cebrOneStory
    cebrAllVariantsOfComponent
    cebrSharedDesignSystem

  ComponentStateCoverageDiagnosticKind* = enum
    cscdMissingStory
    cscdMissingFixture
    cscdDuplicateState
    cscdInvalidStateValue

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

  ComponentPropertyDefinition* = object
    name*: string
    kind*: ComponentPropertyKind
    value*: string
    options*: seq[string]
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    fixtureKey*: string
    constructor*: string
    documentation*: string
    usageGuidance*: string

  ComponentStateControl* = object
    key*: string
    kind*: ComponentStateKind
    label*: string
    value*: string
    options*: seq[string]
    story*: StoryRef
    fixtureName*: string
    sourceFile*: string
    sourceLine*: int
    schemaKey*: string
    projectSpecific*: bool

  ComponentEditImpact* = object
    targetKind*: ComponentEditTargetKind
    blastRadius*: ComponentEditBlastRadiusKind
    sourceScope*: SourceScopeChoiceKind
    ownerLabel*: string
    schemaKey*: string
    sourceFile*: string
    sourceLine*: int
    affectedComponent*: string
    affectedComponents*: seq[string]
    affectedStories*: seq[StoryRef]
    affectedVariantKeys*: seq[string]
    usageCount*: int
    summary*: string

  ComponentPropertySurface* = object
    component*: string
    variantKey*: string
    property*: string
    value*: string
    surfaceKind*: ComponentPropertySurfaceKind
    targetKind*: ComponentEditTargetKind
    sourceScope*: SourceScopeChoiceKind
    schemaKey*: string
    sourceFile*: string
    sourceLine*: int
    documentation*: string
    usageGuidance*: string
    cssOrigin*: PropertyOrigin
    cssOriginDetail*: string
    impact*: ComponentEditImpact

  ComponentVariantMatrixCell* = object
    component*: string
    variantKey*: string
    stateKey*: string
    label*: string
    story*: StoryRef
    fixtureName*: string
    covered*: bool
    missingStorySuggestion*: string
    createStoryCommand*: string

  ComponentStateCoverageDiagnostic* = object
    kind*: ComponentStateCoverageDiagnosticKind
    message*: string
    component*: string
    variantKey*: string
    stateKey*: string
    suggestion*: string
    command*: string
    file*: string
    line*: int

  ComponentVariantDefinition* = object
    component*: string
    variantKey*: string
    story*: StoryRef
    fixtureName*: string
    metadataName*: string
    fields*: seq[ComponentVariantField]
    properties*: seq[ComponentPropertyDefinition]
    stateControls*: seq[ComponentStateControl]
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
    impact*: ComponentEditImpact

  # --- Preview ---
  PreviewBackend* = enum
    ## Canonical preview backend identifier. Surfaces the seven renderer
    ## targets we support (Web / TUI / GPUI / Freya / Cocoa / Android /
    ## iOS). Replaces the legacy 3-value `Platform` enum (`pfWeb`/
    ## `pfIOS`/`pfAndroid`) per M57. Cocoa is Mac AppKit in-process;
    ## iOS UIKit-on-device is now a first-class separate backend
    ## (`pbIos`) that streams real device frames over a Wi-Fi TCP
    ## socket, distinct from the historical "Cocoa renderer + phone
    ## viewport" shorthand.
    pbWeb     ## Default — iframe HTML preview.
    pbTui     ## `isonim-tui-serve` (M26); D/M/P wire protocol.
    pbGpui    ## `isonim-render-serve` + GPUI adapter (RS-M2).
    pbFreya   ## `isonim-render-serve` + Freya adapter (RS-M4).
    pbCocoa   ## `isonim-render-serve` + Cocoa adapter (RS-M5).
    pbAndroid ## `isonim-render-serve` + Android adapter (RS-M6).
    pbIos     ## `isonim-render-serve` + iOS UIKit on a real device,
              ## streamed over a Wi-Fi TCP socket (host launcher binds
              ## bridge port 8107).

  Platform* = PreviewBackend
    ## Backward-compatible alias retained for downstream code that still
    ## reads the broader "platform" concept. Treat `PreviewBackend` as
    ## the canonical name in new code; the alias keeps API symmetry with
    ## existing fields named `platform` (e.g. `ReviewViewportContext`,
    ## `AgentPromptContext`, `EditorWorkspace.platform`).

  PreviewViewportKind* = enum
    ## Catalogue of well-known preview viewport presets. The accompanying
    ## `PreviewViewport` object carries the resolved label / extent / unit
    ## metadata so renderers don't need to switch on the kind directly.
    pvkDesktop
    pvkLaptop
    pvkTablet
    pvkPhone
    pvkTui80x24
    pvkTui120x40
    pvkWide
    pvkUltrawide
    pvkPhoneSm
    pvkPhoneXl
    pvkCustom

  PreviewViewport* = object
    ## Descriptor for the active preview viewport. Replaces the legacy
    ## 3-value enum (`pvDesktop`/`pvTablet`/`pvMobile`) with a richer
    ## object that captures the per-backend pinned/popup classification
    ## from the editor spec § "Preview-pane chrome layout".
    kind*: PreviewViewportKind
    slug*: string  ## Stable identifier used in URLs and serialisation.
    label*: string ## Human-facing label rendered in the edge strip.
    width*: int
      ## Pixels for graphical backends, character cells for TUI viewports.
    height*: int
    isCells*: bool
      ## True iff the extent is measured in cell grid units (TUI-style);
      ## false for pixel viewports.

  ProjectPreviewStatus* = enum
    ppsMissingSelection
    ppsUnsupportedStory
    ppsRendered

  PreviewVariantMutationKind* = enum
    pvmkClassToken
    pvmkAttribute
    pvmkTextContent

  PreviewVariantValueMap* = object
    ## Consumer-owned mapping from schema values to rendered preview values.
    sourceValue*: string
    previewValue*: string

  PreviewVariantMutation* = object
    ## Generic DOM mutation that lets consumer previews reflect unsaved
    ## component API changes without editor-owned project assumptions.
    component*: string
    variantKey*: string
    property*: string
    selector*: string
    kind*: PreviewVariantMutationKind
    classPrefix*: string
    attributeName*: string
    values*: seq[PreviewVariantValueMap]

  ProjectPreview* = object
    ## Headless preview payload produced by a project-owned preview hook.
    status*: ProjectPreviewStatus
    story*: StoryRef
    title*: string
    bodyText*: string
    documentHtml*: string
      ## Web-only after CHRM-M5. The Web composition root has no
      ## streaming launcher — the editor itself is HTML, so the
      ## per-backend ``documentHtml`` from the project's preview
      ## hook is mounted in-iframe via srcdoc. Every non-Web
      ## backend (TUI / GPUI / Freya / Cocoa / Android) hits the
      ## canvas path instead, which streams real demo frames from
      ## the launcher process. Producers may still emit
      ## ``documentHtml`` for non-Web backends (the value is
      ## carried through to flow-card thumbnails in
      ## ``views/storyboard.nim``) but the main preview pane
      ## consumers (``page_preview``, ``foundations_page``,
      ## ``component_detail``) ignore it for non-Web.
    metadata*: StoryRenderMetadata
    variantMutations*: seq[PreviewVariantMutation]

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

  # --- Right sidebar tab selection ---
  # DEPRECATED Phase A — replaced by aiDrawerOpen in Phase F.
  # The right sidebar's Manual/Assistant tab pair was demolished on
  # 2026-05-28 (see ``Front-Ends/IsoNim/isonim-editor.md`` §"AI
  # assistant placement"). The sidebar is now a single-column scroll
  # surface; the AI chat moved to a chrome-bar-driven slide-out
  # drawer. This enum is retained as a deprecation shim so the
  # spec-comment chat-handoff site in ``shell.nim`` keeps compiling
  # until Phase F replaces it with ``vm.openAiDrawer``.
  RightSidebarTab* = enum
    rstManual          ## DEPRECATED Phase A — no longer wired.
    rstAssistant       ## DEPRECATED Phase A — no longer wired.

  InspectorControlSlot* = enum
    icsLabel
    icsScrubValue
    icsUnitSelector
    icsBindingIndicator
    icsScopeIndicator
    icsReset
    icsMoreMenu

  InspectorDenseRowContract* = object
    maxHeightPx*: int
    slots*: seq[InspectorControlSlot]
    rejectsDebugFormLayout*: bool

  InspectorLargeControlKind* = enum
    ilcColorPlane
    ilcBoxModel
    ilcShadow
    ilcGradient
    ilcTypographyDetail
    ilcTransitionCurve
    ilcRawCss
    ilcSourceCascade

  InspectorLargeControlContract* = object
    kind*: InspectorLargeControlKind
    container*: string
    inlineInDenseRow*: bool

  # --- Design system variable binding (Phase E.1) ---
  # Data model for the Property Inspector's "linked chip" affordance.
  # When a property value resolves through a design system variable
  # (rather than a literal), a ``VariableBinding`` records the link.
  # Phase E.1 only persists bindings in VM memory; Phase E.4 will
  # write the binding back to the source file.
  VariableBindingState* = enum
    vbsUnbound        ## Value is a literal — no binding exists.
    vbsBound          ## Value resolves through a known design-system
                      ## variable; ``resolvedValue`` mirrors the
                      ## current foundations token value.
    vbsBoundMissing   ## Binding refers to a variable that has been
                      ## deleted or renamed in foundations. The
                      ## inspector surfaces this as a broken-link
                      ## diagnostic; the user can re-bind or detach.

  VariableBinding* = object
    state*: VariableBindingState
    variableKey*: string       ## e.g., "color/surface", "spacing/4".
    resolvedValue*: string     ## Literal the variable currently
                               ## resolves to. Mirrors the foundations
                               ## token value so the inspector can
                               ## render the value preview without a
                               ## second lookup.
    sourceFileRef*: string     ## Foundations file that owns the
                               ## variable definition (informational —
                               ## the picker's source-scope footer
                               ## reads this).
    sourceLineRef*: int

  PropertyBindingKey* = object
    ## Compound key identifying the (element × property) pair a
    ## binding belongs to. The inspector tracks bindings per
    ## selected element so switching selection does not lose the
    ## bindings on other elements.
    elementId*: string         ## Selection identifier (matches
                               ## ``ElementRef.id`` / fallback id).
    propertyName*: string      ## CSS property name, e.g.,
                               ## ``background-color`` or ``gap``.

  VariablePickerCategory* = enum
    ## Coarse grouping used by the variable picker popover. The
    ## picker collapses each category like an inspector section.
    vpcColour
    vpcSpacing
    vpcTypography
    vpcRadius
    vpcEffect
    vpcNumber
    vpcString
