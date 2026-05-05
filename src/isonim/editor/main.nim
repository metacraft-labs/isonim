## IsoNim Editor — browser demo entry point.
## Compiles to JS via `nim js` and mounts a project workspace.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import examples/wanderlust/stories as wanderlust
import std/strutils
import isonim/core/signals
import isonim/editor
import isonim/editor/browser

proc demoInspectorElement(): ElementRef =
  ElementRef(
    tag: "DestinationCard",
    sourceFile: "examples/wanderlust/components/views.nim",
    sourceLine: 42,
    properties: @[
      PropertyInfo(
        name: "padding",
        value: "20",
        origin: poTailwindClass,
        originDetail: "class:p-5",
        sourceFile: "examples/wanderlust/components/views.nim",
        sourceLine: 42),
      PropertyInfo(
        name: "border-radius",
        value: "14",
        origin: poTailwindClass,
        originDetail: "class:rounded-[14px]",
        sourceFile: "examples/wanderlust/components/views.nim",
        sourceLine: 42)
    ])

proc demoVectorSymbols(): seq[VectorSymbol] =
  @[
    VectorSymbol(
      name: "Compass", category: "Icons",
      svgContent: "<path d=\"M12 2l4 14-4-2-4 2 4-14z\" />",
      tags: @["travel", "navigation"], width: 24, height: 24),
    VectorSymbol(
      name: "Heart", category: "Icons",
      svgContent: "<path d=\"M12 21s-7-4.4-9-9a5 5 0 018-6 5 5 0 018 6c-2 4.6-9 9-9 9z\" />",
      tags: @["save", "favorite"], width: 24, height: 24),
    VectorSymbol(
      name: "Pin", category: "Icons",
      svgContent: "<path d=\"M12 22s7-6.1 7-13a7 7 0 10-14 0c0 6.9 7 13 7 13z\" />",
      tags: @["map", "place"], width: 24, height: 24)
  ]

proc demoVectorEditAdapter(vectorSource: ref string): WorkspaceEditAdapter =
  let vectorStory = StoryRef(group: "Foundations", name: "Vector Symbols",
    kind: skFoundation, index: 0)
  result = WorkspaceEditAdapter(schema: @[
    WorkspaceEditableSchemaEntry(
      key: "symbols.compass.svg",
      kind: wskSvgSymbol,
      file: "examples/wanderlust/design-system/vector-symbols.svg",
      path: "symbols.compass.svg",
      story: vectorStory,
      property: "svgContent")
  ])
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: true, content: vectorSource[])
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    let next =
      if plan.expectedOldValue.len > 0 and plan.expectedOldValue in content:
        content.replace(plan.expectedOldValue, plan.newValue)
      elif plan.property == "svgContent":
        plan.newValue
      else:
        content
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
      file: schema.file,
      beforeContent: content,
      afterContent: next,
      affectedStory: schema.story,
      fullReload: true))
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    vectorSource[] = content
    WorkspaceOperationResult(ok: true)
  result.formatFiles = proc(files: seq[string]): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: true)
  result.regenerate = proc(keys: seq[string]): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: true, affectedStories: @[vectorStory],
      fullReload: true)
  result.reloadPreview = proc(stories: seq[StoryRef];
      fullReload: bool): WorkspaceOperationResult =
    WorkspaceOperationResult(ok: true, affectedStories: stories,
      fullReload: fullReload)
  result.review = proc(patches: seq[WorkspaceFilePatch]): WorkspaceReviewResult =
    WorkspaceReviewResult(ok: true, violations: @[
      Violation(severity: vsWarning, category: vcAccessibility,
        message: "Review passed with accessible vector metadata intact.",
        file: "examples/wanderlust/design-system/vector-symbols.svg",
        line: 1,
        autoFixable: false)
    ])

proc main() =
  let groups = wanderlust.buildWanderlustStoryboard()
  var editor: EditorVM
  let vectorSource = new(string)
  vectorSource[] = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>"
  let workspace = newEditorWorkspace(
    title = "Wanderlust",
    storyGroups = groups,
    canvasItems = wanderlust.wanderlustCanvasItems(groups),
    flowSteps = wanderlust.wanderlustFlowSteps(groups),
    vectorSymbols = demoVectorSymbols(),
    initialVectorSymbol = some(0),
    initialInspectorElement = some(demoInspectorElement()),
    previewHook = wanderlust.wanderlustPreviewHook,
    agentPromptAdapter = proc(prompt: string; context: AgentPromptContext): bool =
      editor.chat.addAgentResponse(
        "Fake adapter streamed response for '" & prompt &
        "' with tool state complete and " &
        $context.accumulatedEdits.len & " inspector edit(s), " &
        $context.reviewAnnotations.len & " included review comment(s), " &
        $context.selectedSchemaNodes.len & " selected schema node(s).")
      editor.chat.toolCalls.val = @["fake.applyDesignEdit"]
      discard editor.chat.addAgentPermissionRequest(AgentPermissionRequest(
        title: "Write workspace source",
        detail: "Apply the generated SVG source edit through the workspace adapter.",
        options: @["allow", "deny"]))
      discard editor.chat.addAgentEditProposal(AgentEditProposal(
        title: "Compass icon source edit",
        summary: "examples/wanderlust/design-system/vector-symbols.svg svgContent",
        sourceEdits: @[SourceEditPlan(
          file: "examples/wanderlust/design-system/vector-symbols.svg",
          line: 1,
          property: "svgContent",
          oldValue: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>",
          newValue: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><title>Compass</title><path d=\"M12 2l5 15-5-3-5 3 5-15z\" /></svg>",
          originDetail: "fake-agent:svgContent",
          scope: pesShared,
          planKind: cspStructuredSchemaUpdate,
          schemaKey: "symbols.compass.svg",
          reversible: true,
          previewBefore: "compass before",
          previewAfter: "compass after",
          formatterHook: "svgo",
          regeneratorHook: "wanderlust-vector",
          conflictKey: "symbols.compass.svg",
          expectedOldValue: "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>")],
        diffs: @[AgentFileDiff(
          file: "examples/wanderlust/design-system/vector-symbols.svg",
          beforeText: "compass before",
          afterText: "compass after",
          summary: "svgContent updated")],
        impact: AgentProposalImpact(
          summary: "Updates the shared Compass vector symbol through the workspace adapter.",
          affectedStories: @[StoryRef(group: "Foundations",
            name: "Vector Symbols", kind: skFoundation, index: 0)],
          affectedComponents: @["Compass"]),
        affectedStories: @[StoryRef(group: "Foundations",
          name: "Vector Symbols", kind: skFoundation, index: 0)],
        tests: @["compile Foundations / Vector Symbols",
          "reload affected vector symbol preview"]))
      editor.chat.stopReason.val = "complete"
      true,
    agentCancelAdapter = proc(): bool = true,
    agentBackend = absAgentHarbor,
    id = "wanderlust",
    description = "Travel app workspace for IsoNim Editor development",
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true, createStory: false, createVariant: false,
      duplicate: false, delete: false),
    editAdapter = demoVectorEditAdapter(vectorSource))
  editor = mountEditor(workspace)

main()
