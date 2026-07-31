## IsoNim Editor workspace definitions.
##
## A workspace is the project-owned data contract for the editor shell. The
## editor package owns the framework, view models, and rendering; consuming
## projects own their story groups, flow data, symbols, and initial state.

import std/[json, options, strutils]

import isonim/core/signals
import isonim/viewmodel
import isonim/editor/types
import isonim/editor/viewmodels

export types
export options

type
  EditorWorkspace* = object
    ## Project-supplied editor workspace data.
    id*: string
    title*: string
    version*: string
    description*: string
    storyGroups*: seq[StoryGroup]
    canvasItems*: seq[CanvasItem]
    connections*: seq[FlowConnection]
    flowSteps*: seq[FlowStep]
    vectorSymbols*: seq[VectorSymbol]
    foundationTokens*: seq[FoundationTokenEntry]
    componentVariants*: seq[ComponentVariantDefinition]
    designSystemSchema*: DesignSystemSchema
    initialView*: EditorView
    initialStory*: Option[StoryRef]
    initialCanvasItem*: Option[int]
    initialInspectorElement*: Option[ElementRef]
    initialInspectorSection*: InspectorSection
    initialVectorSymbol*: Option[int]
    initialReviewBaseline*: Option[seq[Violation]]
    previewHook*: ProjectPreviewHook
    agentPromptAdapter*: AgentPromptAdapter
    agentCancelAdapter*: AgentCancelAdapter
    agentBackend*: AgentBackendSelection
    permissions*: EditorWorkspacePermissions
    sourceAdapterReady*: bool
    editAdapter*: WorkspaceEditAdapter
    platform*: Platform
    allowedPlatforms*: set[PreviewBackend]
      ## Optional per-project platform allow-list for the backend/platform
      ## toolbar. Empty set = ALL platforms (today's behaviour), so pilots
      ## that do not opt in are byte-unchanged. When non-empty, only the
      ## listed backends appear in the left-edge strip and the VM's active
      ## platform is forced into the allowed set at workspace-apply time.
    panels*: PanelVisibility
    variableBindings*: seq[PersistedPropertyBinding]
      ## VBIND-M5: persisted design-system variable bindings for this
      ## workspace, loaded from the JSON sidecar
      ## (``<workspace-dir>/.isonim/bindings.json``) and seeded into
      ## ``InspectorVM.propertyBindings`` at apply time. Additive and
      ## default-empty: a workspace that sets neither this nor
      ## ``variableBindingHistory`` rehydrates to empty bindings and
      ## behaves byte-for-byte as before (every pilot today; editor_chrome
      ## + task_app forever). NEVER carried in the DTCG token source.
    variableBindingHistory*: seq[PropertyBindingHistoryEntry]
      ## VBIND-M5: previously-linked variable history (most-recent-first
      ## per element × property), loaded from the same sidecar and stashed
      ## on the inspector VM for the "Previously linked" picker group
      ## (VBIND-M6). Additive and default-empty.

proc defaultPanelVisibility*(): PanelVisibility =
  PanelVisibility(sidebar: true, inspector: true)

proc defaultEditorPermissions*(): EditorWorkspacePermissions =
  EditorWorkspacePermissions(
    readSource: true,
    writeSource: false,
    createStory: false,
    createVariant: false,
    duplicate: false,
    delete: false)

proc emptyEditorWorkspace*(): EditorWorkspace =
  ## Build an empty workspace with production defaults.
  EditorWorkspace(
    id: "workspace",
    title: "IsoNim Editor",
    version: "0.1.0",
    initialView: evStoryboard,
    initialStory: none(StoryRef),
    initialCanvasItem: none(int),
    initialInspectorElement: none(ElementRef),
    initialInspectorSection: isLayout,
    initialVectorSymbol: none(int),
    initialReviewBaseline: none(seq[Violation]),
    previewHook: defaultPreviewHook,
    agentPromptAdapter: nil,
    agentCancelAdapter: nil,
    agentBackend: absUnconfigured,
    permissions: defaultEditorPermissions(),
    sourceAdapterReady: false,
    editAdapter: nil,
    platform: pbWeb,
    panels: defaultPanelVisibility(),
    designSystemSchema: DesignSystemSchema()
  )

proc newEditorWorkspace*(title: string;
                          storyGroups: seq[StoryGroup];
                          id = "workspace";
                          version = "0.1.0";
                          description = "";
                          canvasItems: seq[CanvasItem] = @[];
                          connections: seq[FlowConnection] = @[];
                          flowSteps: seq[FlowStep] = @[];
                          vectorSymbols: seq[VectorSymbol] = @[];
                          foundationTokens: seq[FoundationTokenEntry] = @[];
                          componentVariants: seq[ComponentVariantDefinition] = @[];
                          designSystemSchema = DesignSystemSchema();
                          initialView = evStoryboard;
                          initialStory = none(StoryRef);
                          initialCanvasItem = none(int);
                          initialInspectorElement = none(ElementRef);
                          initialInspectorSection = isLayout;
                          initialVectorSymbol = none(int);
                          initialReviewBaseline = none(seq[Violation]);
                          previewHook: ProjectPreviewHook = defaultPreviewHook;
                          agentPromptAdapter: AgentPromptAdapter = nil;
                          agentCancelAdapter: AgentCancelAdapter = nil;
                          agentBackend = absUnconfigured;
                          permissions = defaultEditorPermissions();
                          sourceAdapterReady = false;
                          editAdapter: WorkspaceEditAdapter = nil;
                          platform = pbWeb;
                          allowedPlatforms: set[PreviewBackend] = {};
                          panels = defaultPanelVisibility();
                          variableBindings: seq[PersistedPropertyBinding] = @[];
                          variableBindingHistory:
                            seq[PropertyBindingHistoryEntry] = @[]):
                            EditorWorkspace =
  ## Convenience constructor for project-owned workspace definitions.
  EditorWorkspace(
    id: id,
    title: title,
    version: version,
    description: description,
    storyGroups: storyGroups,
    canvasItems: canvasItems,
    connections: connections,
    flowSteps: flowSteps,
    vectorSymbols: vectorSymbols,
    foundationTokens: foundationTokens,
    componentVariants: componentVariants,
    designSystemSchema: designSystemSchema,
    initialView: initialView,
    initialStory: initialStory,
    initialCanvasItem: initialCanvasItem,
    initialInspectorElement: initialInspectorElement,
    initialInspectorSection: initialInspectorSection,
    initialVectorSymbol: initialVectorSymbol,
    initialReviewBaseline: initialReviewBaseline,
    previewHook: previewHook,
    agentPromptAdapter: agentPromptAdapter,
    agentCancelAdapter: agentCancelAdapter,
    agentBackend: agentBackend,
    permissions: permissions,
    sourceAdapterReady: sourceAdapterReady,
    editAdapter: editAdapter,
    platform: platform,
    allowedPlatforms: allowedPlatforms,
    panels: panels,
    variableBindings: variableBindings,
    variableBindingHistory: variableBindingHistory
  )

const bindingSidecarVersion = 1

const bindingSidecarRelPath* = ".isonim/bindings.json"
  ## VBIND-M5: the sidecar path, RELATIVE to a pilot's chosen workspace
  ## directory. The FRAMEWORK never opens this file — a consumer joins it
  ## against its own base (demo project dir, docs ``design/`` dir, …). The
  ## framework only owns the (de)serialization + rehydrate mechanism, so
  ## no absolute path is ever hard-coded here.

proc bindingSidecarJson*(bindings: seq[PersistedPropertyBinding];
    history: seq[PropertyBindingHistoryEntry]): string =
  ## VBIND-M5 SERIALIZE: render the two persisted binding fields to the
  ## sidecar JSON text. Covers ONLY these fields — this is a small,
  ## self-contained sidecar document, NOT full-workspace serialization
  ## (the editor has none). The DTCG token source is untouched.
  var bindingsArr = newJArray()
  for b in bindings:
    bindingsArr.add(%*{
      "elementId": b.elementId,
      "propertyName": b.propertyName,
      "variableKey": b.variableKey})
  var historyArr = newJArray()
  for h in history:
    historyArr.add(%*{
      "elementId": h.elementId,
      "propertyName": h.propertyName,
      "variableKeys": h.variableKeys})
  let doc = %*{
    "version": bindingSidecarVersion,
    "variableBindings": bindingsArr,
    "variableBindingHistory": historyArr}
  pretty(doc)

proc bindingSidecarJson*(workspace: EditorWorkspace): string =
  ## Convenience overload: serialize a workspace's persisted binding
  ## fields to the sidecar JSON text.
  bindingSidecarJson(workspace.variableBindings,
    workspace.variableBindingHistory)

proc parseBindingSidecar*(raw: string):
    tuple[bindings: seq[PersistedPropertyBinding],
          history: seq[PropertyBindingHistoryEntry]] =
  ## VBIND-M5 DESERIALIZE: parse the sidecar JSON text back into the two
  ## fields. MALFORMED or ABSENT (empty) input yields two empty seqs and
  ## NEVER raises, so a missing sidecar is a no-op load and a corrupt file
  ## degrades to today's (empty) behaviour rather than crashing the editor.
  if raw.strip().len == 0:
    return
  var doc: JsonNode
  try:
    doc = parseJson(raw)
  except CatchableError:
    return
  if doc.kind != JObject:
    return
  let bindingsNode = doc{"variableBindings"}
  if not bindingsNode.isNil and bindingsNode.kind == JArray:
    for item in bindingsNode:
      if item.kind != JObject:
        continue
      result.bindings.add PersistedPropertyBinding(
        elementId: item{"elementId"}.getStr(),
        propertyName: item{"propertyName"}.getStr(),
        variableKey: item{"variableKey"}.getStr())
  let historyNode = doc{"variableBindingHistory"}
  if not historyNode.isNil and historyNode.kind == JArray:
    for item in historyNode:
      if item.kind != JObject:
        continue
      var keys: seq[string] = @[]
      let keysNode = item{"variableKeys"}
      if not keysNode.isNil and keysNode.kind == JArray:
        for k in keysNode:
          keys.add k.getStr()
      result.history.add PropertyBindingHistoryEntry(
        elementId: item{"elementId"}.getStr(),
        propertyName: item{"propertyName"}.getStr(),
        variableKeys: keys)

proc loadBindingSidecar*(workspace: var EditorWorkspace; raw: string) =
  ## VBIND-M5: load sidecar JSON text into a workspace's binding fields
  ## (the consumer reads the file; the framework parses). Malformed/empty
  ## input leaves both fields empty.
  let parsed = parseBindingSidecar(raw)
  workspace.variableBindings = parsed.bindings
  workspace.variableBindingHistory = parsed.history

proc applyWorkspace*(vm: EditorVM; workspace: EditorWorkspace) =
  ## Load project workspace data into an existing editor VM.
  vm.sidebar.groups.val = workspace.storyGroups
  vm.storyboard.canvasItems.val = workspace.canvasItems
  vm.storyboard.connections.val = workspace.connections
  vm.flowPlayer.steps.val = workspace.flowSteps
  vm.vectorEditor.symbols.val = workspace.vectorSymbols
  vm.vectorEditor.document.val = VectorDocument()
  vm.vectorEditor.diagnostics.val = @[]
  vm.vectorEditor.undoStack.val = @[]
  vm.vectorEditor.redoStack.val = @[]
  vm.vectorEditor.adapter.val = selectedVectorAdapter()
  vm.foundations.tokens.val = workspace.foundationTokens
  vm.foundations.selectedCategory.val = ftkColorPalette
  vm.foundations.storyCategories.val = {}
  vm.foundations.selectedTokenKey.val =
    if workspace.foundationTokens.len > 0: workspace.foundationTokens[0].key
    else: ""
  vm.foundations.searchFilter.val = ""
  vm.foundations.impacts.val = @[]
  vm.foundations.diagnostics.val = @[]
  vm.foundations.undoStack.val = @[]
  vm.foundations.redoStack.val = @[]
  vm.variants.variants.val = workspace.componentVariants
  vm.variants.selectedVariant.val = -1
  vm.variants.diagnostics.val = @[]
  vm.variants.stateDiagnostics.val = @[]
  vm.designSystemSchema.val = workspace.designSystemSchema
  vm.preview.hook = workspace.previewHook
  vm.selectedStory.val = StoryRef()
  vm.storyboard.selectedItem.val = -1
  vm.inspector.selectedElement.val = ElementRef()
  # VBIND-M5: deterministically rehydrate the in-memory bindings from the
  # workspace's persisted metadata (empty for every default pilot ⇒ empty
  # propertyBindings ⇒ today's behaviour). This is the ONLY place
  # ``propertyBindings`` is reset, so re-applying a workspace never leaks
  # bindings across applies. Runs after ``foundations.tokens`` is loaded
  # (above) so each variableKey resolves to vbsBound / vbsBoundMissing.
  vm.rehydratePropertyBindings(workspace.variableBindings,
    workspace.variableBindingHistory)
  vm.inspector.editDiagnostics.val = @[]
  vm.inspector.pendingSourceEdits.val = @[]
  vm.inspector.sourcePreviews.val = @[]
  vm.inspector.conflicts.val = @[]
  vm.inspector.undoStack.val = @[]
  vm.inspector.redoStack.val = @[]
  vm.workspaceEditStage.val = wesClean
  vm.workspaceEditDiagnostics.val = @[]
  vm.workspaceEditPatches.val = @[]
  vm.workspaceEditAffectedStories.val = @[]
  vm.workspaceEditFullReload.val = false
  vm.workspaceEditGeneratedArtifacts.val = @[]
  vm.workspaceEditRequiredTestCommands.val = @[]
  vm.workspaceEditReviewDiagnostics.val = @[]
  vm.livePreviewReloadGeneration.val = 0
  vm.vectorEditor.selectedSymbol.val = -1
  vm.review.violations.val = @[]
  vm.review.annotations.val = @[]
  vm.chat.accumulatedEdits.val = @[]
  vm.chat.messages.val = @[]
  vm.chat.sessionStatus.val = asIdle
  vm.chat.inputText.val = ""
  vm.chat.connectionState.val = "disconnected"
  vm.chat.planEntries.val = @[]
  vm.chat.toolCalls.val = @[]
  vm.chat.stopReason.val = ""
  vm.chat.lastPromptContext.val = AgentPromptContext()
  vm.chat.configureAgentAdapters(workspace.agentPromptAdapter,
                                  workspace.agentCancelAdapter,
                                  workspace.agentBackend)
  vm.workspacePermissions.val = workspace.permissions
  vm.workspaceEditAdapter = workspace.editAdapter
  vm.sourceAdapterReady.val = workspace.sourceAdapterReady or
    not workspace.editAdapter.isNil
  vm.flowPlayer.currentStep.val = 0
  vm.activeView.val = workspace.initialView
  vm.inspector.activeSection.val = workspace.initialInspectorSection
  vm.allowedPlatforms = workspace.allowedPlatforms
  # M1: when a project restricts platforms and its declared active platform is
  # not in the allow-list, fall back to the first allowed backend in canonical
  # order (the PreviewBackend enum order matches `backendsForLeftEdge`).
  var initialPlatform = workspace.platform
  if workspace.allowedPlatforms.len > 0 and
      workspace.platform notin workspace.allowedPlatforms:
    for b in PreviewBackend:
      if b in workspace.allowedPlatforms:
        initialPlatform = b
        break
  vm.changePlatform(initialPlatform)
  vm.panels.val = workspace.panels
  if workspace.initialReviewBaseline.isSome:
    vm.review.violations.val = workspace.initialReviewBaseline.get()
  if workspace.initialStory.isSome:
    discard vm.selectStory(workspace.initialStory.get())
  if workspace.initialCanvasItem.isSome:
    discard vm.selectCanvasItem(workspace.initialCanvasItem.get())
  if workspace.initialInspectorElement.isSome:
    discard vm.selectInspectorElement(workspace.initialInspectorElement.get())
  if workspace.initialVectorSymbol.isSome:
    discard vm.selectVectorSymbol(workspace.initialVectorSymbol.get())
  vm.activeView.val = workspace.initialView

proc createEditorVM*(workspace: EditorWorkspace): EditorVM =
  ## Create a fully wired editor VM and immediately load workspace data.
  result = viewmodels.createEditorVM()
  result.applyWorkspace(workspace)
