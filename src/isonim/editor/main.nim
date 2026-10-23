## IsoNim Editor — browser demo entry point.
## Compiles to JS via `nim js` and mounts a project workspace.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import examples/wanderlust/stories as wanderlust
import isonim/core/signals
import isonim/editor
import isonim/editor/browser
import isonim/editor/demo_workspace

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

proc main() =
  let groups = wanderlust.buildWanderlustStoryboard()
  var editor: EditorVM
  let vectorSource = new(string)
  let foundationSource = new(string)
  vectorSource[] = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>"
  foundationSource[] = DemoFoundationInitialSource
  exposeDemoSource(DemoFoundationSource, foundationSource[])
  let workspace = newEditorWorkspace(
    title = "Wanderlust",
    storyGroups = groups,
    canvasItems = wanderlust.wanderlustCanvasItems(groups),
    flowSteps = wanderlust.wanderlustFlowSteps(groups),
    vectorSymbols = demoVectorSymbols(),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = demoDesignSystemSchema(),
    initialVectorSymbol = some(0),
    initialInspectorElement = some(demoInspectorElement()),
    responsiveBreakpoints = demoResponsiveBreakpoints(foundationSource[]),
    previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
      result = wanderlust.wanderlustPreviewHook(story, platform)
      if story.kind == skComponent and story.group == "DestinationCard":
        result.documentHtml = demoComponentDocument(foundationSource[],
          result.title, result.bodyText),
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
          sourceScope: sskSharedClass,
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
    editAdapter = demoVectorEditAdapter(vectorSource, foundationSource))
  editor = mountEditor(workspace)

main()
