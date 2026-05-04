## IsoNim Editor workspace definitions.
##
## A workspace is the project-owned data contract for the editor shell. The
## editor package owns the framework, view models, and rendering; consuming
## projects own their story groups, flow data, symbols, and initial state.

import std/options

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
    permissions*: EditorWorkspacePermissions
    sourceAdapterReady*: bool
    platform*: Platform
    panels*: PanelVisibility

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
    permissions: defaultEditorPermissions(),
    sourceAdapterReady: false,
    platform: pfWeb,
    panels: defaultPanelVisibility()
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
                          permissions = defaultEditorPermissions();
                          sourceAdapterReady = false;
                          platform = pfWeb;
                          panels = defaultPanelVisibility()): EditorWorkspace =
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
    permissions: permissions,
    sourceAdapterReady: sourceAdapterReady,
    platform: platform,
    panels: panels
  )

proc applyWorkspace*(vm: EditorVM; workspace: EditorWorkspace) =
  ## Load project workspace data into an existing editor VM.
  vm.sidebar.groups.val = workspace.storyGroups
  vm.storyboard.canvasItems.val = workspace.canvasItems
  vm.storyboard.connections.val = workspace.connections
  vm.flowPlayer.steps.val = workspace.flowSteps
  vm.vectorEditor.symbols.val = workspace.vectorSymbols
  vm.preview.hook = workspace.previewHook
  vm.selectedStory.val = StoryRef()
  vm.storyboard.selectedItem.val = -1
  vm.inspector.selectedElement.val = ElementRef()
  vm.inspector.editDiagnostics.val = @[]
  vm.inspector.pendingSourceEdits.val = @[]
  vm.vectorEditor.selectedSymbol.val = -1
  vm.review.violations.val = @[]
  vm.chat.accumulatedEdits.val = @[]
  vm.chat.messages.val = @[]
  vm.chat.sessionStatus.val = asIdle
  vm.chat.inputText.val = ""
  vm.chat.connectionState.val = "disconnected"
  vm.chat.planEntries.val = @[]
  vm.chat.toolCalls.val = @[]
  vm.chat.stopReason.val = ""
  vm.chat.configureAgentAdapters(workspace.agentPromptAdapter,
                                  workspace.agentCancelAdapter)
  vm.workspacePermissions.val = workspace.permissions
  vm.sourceAdapterReady.val = workspace.sourceAdapterReady
  vm.flowPlayer.currentStep.val = 0
  vm.activeView.val = workspace.initialView
  vm.inspector.activeSection.val = workspace.initialInspectorSection
  vm.changePlatform(workspace.platform)
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
