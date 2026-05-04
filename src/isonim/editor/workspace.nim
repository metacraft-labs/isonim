## IsoNim Editor workspace definitions.
##
## A workspace is the project-owned data contract for the editor shell. The
## editor package owns the framework, view models, and rendering; consuming
## projects own their story groups, flow data, symbols, and initial state.

import isonim/core/signals
import isonim/editor/types
import isonim/editor/viewmodels

export types

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
    initialInspectorSection*: InspectorSection
    platform*: Platform
    panels*: PanelVisibility

proc defaultPanelVisibility*(): PanelVisibility =
  PanelVisibility(sidebar: true, inspector: true)

proc emptyEditorWorkspace*(): EditorWorkspace =
  ## Build an empty workspace with production defaults.
  EditorWorkspace(
    id: "workspace",
    title: "IsoNim Editor",
    version: "0.1.0",
    initialView: evStoryboard,
    initialInspectorSection: isLayout,
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
                          initialInspectorSection = isLayout;
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
    initialInspectorSection: initialInspectorSection,
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
  vm.activeView.val = workspace.initialView
  vm.inspector.activeSection.val = workspace.initialInspectorSection
  vm.platform.val = workspace.platform
  vm.panels.val = workspace.panels

proc createEditorVM*(workspace: EditorWorkspace): EditorVM =
  ## Create a fully wired editor VM and immediately load workspace data.
  result = viewmodels.createEditorVM()
  result.applyWorkspace(workspace)
