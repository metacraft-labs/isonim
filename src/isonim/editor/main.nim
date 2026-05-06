## IsoNim Editor — browser demo entry point.
## Compiles to JS via `nim js` and mounts a project workspace.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import examples/wanderlust/stories as wanderlust
import std/strutils
import isonim/core/signals
import isonim/editor
import isonim/editor/browser

const DemoFoundationSource = "examples/wanderlust/design-system/foundations.css"

proc exposeDemoSource(file, content: string) =
  when defined(js):
    {.emit: ["""
      window.__isonimDemoSources = window.__isonimDemoSources || {};
      window.__isonimDemoSources[toJSStr(""", file, """)] = toJSStr(""", content, """);
    """].}

proc demoInspectorElement(): ElementRef =
  ElementRef(
    id: "destination-card-root",
    sourceKey: "destination-card.root",
    tag: "DestinationCard",
    sourceFile: DemoFoundationSource,
    sourceLine: 9,
    properties: @[
      PropertyInfo(
        name: "padding",
        value: "18px",
        origin: poTailwindClass,
        originDetail: "class:destination-card",
        sourceFile: DemoFoundationSource,
        sourceLine: 9,
        schemaKey: "classes.destination-card.padding",
        sharedCount: 4,
        directStyleAllowed: true),
      PropertyInfo(
        name: "border-radius",
        value: "14px",
        origin: poThemeToken,
        originDetail: "token:wanderlust.foundation.radius.card",
        sourceFile: DemoFoundationSource,
        sourceLine: 5,
        schemaKey: "wanderlust.foundation.radius.card",
        tokenName: "wanderlust.foundation.radius.card",
        sharedCount: 5,
        directStyleAllowed: true)
    ])

func demoSourceSpan(line: int): SourceSpan =
  SourceSpan(file: DemoFoundationSource, line: line, column: 1,
    endLine: line, endColumn: 80)

proc demoDesignSystemSchema(): DesignSystemSchema =
  let componentStory = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  DesignSystemSchema(
    schemaVersion: 1,
    projectId: "wanderlust-demo",
    ownerPackage: "isonim-example",
    frameworkContract: "isonim-editor-design-schema-v1",
    nodes: @[
      DesignSchemaNode(key: "classes.destination-card.padding",
        kind: dsnClassDefinition, name: "destination-card",
        component: "DestinationCard", property: "padding", value: "18px",
        sourceSpan: demoSourceSpan(9), stories: @[componentStory],
        components: @["DestinationCard"], usageCount: 4),
      DesignSchemaNode(key: "wanderlust.foundation.radius.card",
        kind: dsnComponentToken, name: "Destination card radius",
        component: "DestinationCard", property: "border-radius",
        value: "14px", sourceSpan: demoSourceSpan(5),
        stories: @[componentStory], components: @["DestinationCard"],
        usageCount: 5),
      DesignSchemaNode(key: "wanderlust.foundation.space.card",
        kind: dsnComponentToken, name: "Destination card spacing",
        component: "DestinationCard", property: "padding",
        value: "16px", sourceSpan: demoSourceSpan(4),
        stories: @[componentStory], components: @["DestinationCard"],
        usageCount: 3)
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

proc demoFoundationTokens(): seq[FoundationTokenEntry] =
  let foundationStory = StoryRef(group: "Foundations", name: "Colors",
    kind: skFoundation, index: 0)
  @[
    FoundationTokenEntry(key: "color.blue.600", kind: ftkColorPalette,
      value: "#2563EB", sourceFile: DemoFoundationSource, sourceLine: 1,
      schemaKey: "wanderlust.foundation.color.blue.600",
      property: "--wl-color-blue-600", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "semantic.action.primary", kind: ftkSemanticColor,
      value: "token(color.blue.600)", aliasOf: "color.blue.600",
      foreground: "#FFFFFF", background: "#2563EB", minContrast: 4.5,
      sourceFile: DemoFoundationSource, sourceLine: 2,
      schemaKey: "wanderlust.foundation.semantic.action.primary",
      property: "--wl-action-primary", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "type.body.size", kind: ftkTypographyScale,
      value: "16px", sourceFile: DemoFoundationSource, sourceLine: 3,
      schemaKey: "wanderlust.foundation.type.body.size",
      property: "--wl-type-body-size", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "space.card", kind: ftkSpacingScale,
      value: "16px", sourceFile: DemoFoundationSource, sourceLine: 4,
      schemaKey: "wanderlust.foundation.space.card",
      property: "--wl-space-card", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "radius.card", kind: ftkRadiusScale,
      value: "14px", sourceFile: DemoFoundationSource, sourceLine: 5,
      schemaKey: "wanderlust.foundation.radius.card",
      property: "--wl-radius-card", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "shadow.card", kind: ftkShadow,
      value: "0 12px 28px #0F172A", sourceFile: DemoFoundationSource,
      sourceLine: 6, schemaKey: "wanderlust.foundation.shadow.card",
      property: "--wl-shadow-card", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "motion.fast", kind: ftkMotion,
      value: "120ms", sourceFile: DemoFoundationSource, sourceLine: 7,
      schemaKey: "wanderlust.foundation.motion.fast",
      property: "--wl-motion-fast", affectedStories: @[foundationStory]),
    FoundationTokenEntry(key: "breakpoint.compact", kind: ftkBreakpoint,
      value: "640px", sourceFile: DemoFoundationSource, sourceLine: 8,
      schemaKey: "wanderlust.foundation.breakpoint.compact",
      property: "--wl-breakpoint-compact", affectedStories: @[foundationStory])
  ]

proc demoVectorEditAdapter(vectorSource, foundationSource: ref string): WorkspaceEditAdapter =
  let vectorStory = StoryRef(group: "Foundations", name: "Vector Symbols",
    kind: skFoundation, index: 0)
  let foundationStory = StoryRef(group: "Foundations", name: "Colors",
    kind: skFoundation, index: 0)
  var schema = @[
    WorkspaceEditableSchemaEntry(
      key: "symbols.compass.svg",
      kind: wskSvgSymbol,
      file: "examples/wanderlust/design-system/vector-symbols.svg",
      path: "symbols.compass.svg",
      story: vectorStory,
      property: "svgContent")]
  for token in demoFoundationTokens():
    schema.add WorkspaceEditableSchemaEntry(
      key: token.schemaKey,
      kind: wskToken,
      file: DemoFoundationSource,
      path: token.key,
      story: foundationStory,
      property: token.property)
  schema.add WorkspaceEditableSchemaEntry(
    key: "classes.destination-card.padding",
    kind: wskSourceMap,
    file: DemoFoundationSource,
    path: "classes.destination-card.padding",
    story: StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0),
    property: "padding")
  result = WorkspaceEditAdapter(schema: schema)
  result.readFile = proc(file: string): WorkspaceReadResult =
    if file == DemoFoundationSource:
      exposeDemoSource(file, foundationSource[])
      WorkspaceReadResult(ok: true, content: foundationSource[])
    else:
      exposeDemoSource(file, vectorSource[])
      WorkspaceReadResult(ok: true, content: vectorSource[])
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    let next =
      if plan.expectedOldValue.len > 0 and plan.expectedOldValue in content:
        content.replace(plan.expectedOldValue, plan.newValue)
      elif plan.property == "svgContent":
        plan.newValue
      else:
        content.strip(leading = false, trailing = true) & "\n" &
          plan.property & ": " & plan.newValue & ";\n"
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
      file: schema.file,
      beforeContent: content,
      afterContent: next,
      affectedStory: schema.story,
      fullReload: true))
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    if file == DemoFoundationSource:
      foundationSource[] = content
    else:
      vectorSource[] = content
    exposeDemoSource(file, content)
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
  let foundationSource = new(string)
  vectorSource[] = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>"
  foundationSource[] =
    "--wl-color-blue-600: #2563EB;\n" &
    "--wl-action-primary: token(color.blue.600);\n" &
    "--wl-type-body-size: 16px;\n" &
    "--wl-space-card: 16px;\n" &
    "--wl-radius-card: 14px;\n" &
    "--wl-shadow-card: 0 12px 28px #0F172A;\n" &
    "--wl-motion-fast: 120ms;\n" &
    "--wl-breakpoint-compact: 640px;\n" &
    ".destination-card { padding: 18px; }\n"
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
