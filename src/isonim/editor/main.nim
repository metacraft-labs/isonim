## IsoNim Editor — browser demo entry point.
## Compiles to JS via `nim js` and mounts a project workspace.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import examples/wanderlust/stories as wanderlust
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
      name: "Compass", category: "Icons", svgContent: "<svg></svg>",
      tags: @["travel", "navigation"], width: 24, height: 24),
    VectorSymbol(
      name: "Heart", category: "Icons", svgContent: "<svg></svg>",
      tags: @["save", "favorite"], width: 24, height: 24),
    VectorSymbol(
      name: "Pin", category: "Icons", svgContent: "<svg></svg>",
      tags: @["map", "place"], width: 24, height: 24)
  ]

proc main() =
  let groups = wanderlust.buildWanderlustStoryboard()
  var editor: EditorVM
  let workspace = newEditorWorkspace(
    title = "Wanderlust",
    storyGroups = groups,
    canvasItems = wanderlust.wanderlustCanvasItems(groups),
    flowSteps = wanderlust.wanderlustFlowSteps(groups),
    vectorSymbols = demoVectorSymbols(),
    initialInspectorElement = some(demoInspectorElement()),
    previewHook = wanderlust.wanderlustPreviewHook,
    agentPromptAdapter = proc(prompt: string; context: AgentPromptContext): bool =
      editor.chat.addAgentResponse(
        "Fake adapter streamed response for '" & prompt &
        "' with tool state complete and " &
        $context.accumulatedEdits.len & " inspector edit(s).")
      editor.chat.toolCalls.val = @["fake.applyDesignEdit"]
      editor.chat.stopReason.val = "complete"
      true,
    agentCancelAdapter = proc(): bool = true,
    id = "wanderlust",
    description = "Travel app workspace for IsoNim Editor development")
  editor = mountEditor(workspace)

main()
