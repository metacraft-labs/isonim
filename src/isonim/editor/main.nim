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
