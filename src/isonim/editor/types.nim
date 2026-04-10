## IsoNim Editor — shared types used across all ViewModels.
## Pure data types with no rendering or presentation logic.

type
  # --- Story types ---
  StoryKind* = enum
    skFoundation    ## Design token display (colors, typography, spacing)
    skComponent     ## Individual component in a specific state
    skPage          ## Full page composition with realistic data
    skFlow          ## Multi-step user navigation sequence

  StoryRef* = object
    ## Reference to a specific story in the storyboard.
    group*: string      ## e.g. "TaskRow", "TaskApp", "First Task"
    name*: string       ## e.g. "Active task", "Empty State", step name
    kind*: StoryKind
    index*: int         ## Position within its group

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
    group*: string        ## Parent group name

  # --- Edit mode ---
  EditMode* = enum
    emView    ## Normal view — component interactions work
    emEdit    ## Click-to-select — inspector populates on click

  # --- Inspector ---
  InspectorSection* = enum
    isLayout
    isSize
    isSpacing
    isFill
    isBorder
    isTypography
    isEffects
    isState       ## ViewModel signal editor

  PropertyOrigin* = enum
    poTailwindClass   ## From a Tailwind utility in class="..."
    poSetStyle        ## From a direct setStyle call
    poThemeToken      ## From themeColor/themeSpacing
    poConstant        ## From a Nim const/let
    poInherited       ## Inherited from parent/theme

  PropertyInfo* = object
    ## A single CSS property with its value and source origin.
    name*: string         ## CSS property name (e.g. "padding")
    value*: string        ## Resolved value (e.g. "16")
    origin*: PropertyOrigin
    originDetail*: string ## e.g. "class:p-4" or "themeColor(\"primary\")"
    sourceLine*: int      ## Line in source file
    sourceFile*: string   ## Source file path
    sharedCount*: int     ## How many elements share this origin (0 = local only)

  ElementRef* = object
    ## Reference to a selected element in the preview.
    tag*: string          ## e.g. "div", "span", "button"
    sourceFile*: string
    sourceLine*: int
    sourceColumn*: int
    properties*: seq[PropertyInfo]
    children*: seq[string]  ## Child element summaries for tree view
    depth*: int             ## Nesting depth

  # --- Agent chat ---
  ChatMessageKind* = enum
    cmkUser       ## User's prompt
    cmkAgent      ## Agent's response
    cmkContext     ## Editor-injected context (accumulated edits)
    cmkError      ## Error message

  ChatMessage* = object
    kind*: ChatMessageKind
    text*: string
    timestamp*: float

  EditRecord* = object
    ## Record of a user edit made via the inspector.
    file*: string
    line*: int
    property*: string
    oldValue*: string
    newValue*: string

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

  Violation* = object
    severity*: ViolationSeverity
    category*: ViolationCategory
    message*: string
    file*: string
    line*: int
    autoFixable*: bool

  # --- Preview ---
  Platform* = enum
    pfWeb
    pfIOS
    pfAndroid

  # --- Flow player ---
  PlayState* = enum
    psStopped
    psPlaying
    psPaused

  FlowStep* = object
    ## A single step in a user flow.
    screenRef*: StoryRef    ## Which story/page to show
    action*: string         ## What the user does (e.g. "Taps + button")
    description*: string    ## Narrative context

  # --- Panel visibility ---
  PanelVisibility* = object
    sidebar*: bool
    inspector*: bool
