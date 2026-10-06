## Real typed EditorVM/agent-context serialization for HTTP transport tests.
## This constructs deterministic editor state without replacing its VM, context
## builder or serializer. No provider, filesystem/compiler or GUI success is
## inferred from this data fixture; the parent test owns the real HTTP boundary.
import std/[algorithm, json, os, sequtils, strutils, tables]
import isonim/dsl/tailwind
import isonim/core/[signals, owner]
import isonim/viewmodel
import isonim/editor/[types, viewmodels]
import isonim/editor/design_review/editor_agent_adapter
import isonim/editor/design_review/context_policy
if "--preview-classes" in commandLineParams():
  # Actual production extraction for the mounted compiler-output/DOM oracle.
  echo %previewClassNames(stdin.readAll())
  quit(0)
var snapshot: JsonNode
createRoot do (dispose: proc()):
  let editor = createEditorVM()
  editor.inspector.layers.val = @[
    ElementLayerRow(id: "root", tag: "main", childCount: 1),
    ElementLayerRow(id: "branch", parentId: "root", depth: 1, tag: "section", childCount: 1),
    ElementLayerRow(id: "actual-target", parentId: "branch", depth: 2, tag: "button", selected: true)]
  editor.inspector.selectedElement.val = ElementRef(id: "actual-target", sourceKey: "source.target",
    domPath: "main > button", schemaKey: "target.ariaLabel", tag: "button", sourceFile: "catalog.nim",
    sourceLine: 42, sourceColumn: 7, properties: @[PropertyInfo(name: "ariaLabel", value: "保持😀 exact")],
    children: @["child"], ancestors: @["main"], ancestorIds: @["root"], depth: 2,
    styleBindings: "  background: token(保持😀); opacity: 0.75  ")
  editor.chat.accumulatedEdits.val = @[EditRecord(file: "catalog.nim", line: 42,
    property: "ariaLabel", oldValue: "old 保持😀", newValue: "  exact current  ")]
  editor.inspector.pendingSourceEdits.val = @[SourceEditPlan(file: "catalog.nim", line: 42,
    property: "ariaLabel", oldValue: "old 保持😀", newValue: "  exact current  ")]
  editor.chat.designSystemConstraints.val = @["保持😀 exact user constraints"]
  if "--preview-html" in commandLineParams():
    let html = stdin.readAll()
    editor.preview.hook = proc(story: StoryRef; platform: Platform): ProjectPreview =
      ProjectPreview(status: ppsRendered, story: story, documentHtml: html)
    editor.selectedStory.val = StoryRef(group: "Class relevance", name: "actual preview")
  if "--all-compiled-classes" in commandLineParams():
    var names: seq[string]
    for name in tailwindStyles.keys: names.add name
    names.sort()
    # A real selection requiring more than 128 compiled classes exercises the
    # producer's larger relevance minimum; no synthetic style-map is injected.
    var selected = editor.inspector.selectedElement.val
    selected.properties.add PropertyInfo(name: "class", value: names.join(" "))
    editor.inspector.selectedElement.val = selected
  var context = editor.buildAgentPromptContext()
  context.currentFileDiffs = @[types.AgentFileDiff(file: "catalog.nim",
    beforeText: "old 保持😀", afterText: "  exact current  ")]
  if "--all-compiled-classes" in commandLineParams() and context.availableTailwindClasses.len > 129:
    let currentMinimum = context.availableTailwindClasses.len - 1
    let rebound = boundAgentPromptContext(context, maxChars = 100000, preserveTailwind = currentMinimum)
    doAssert compiledClassMinimumMarker(currentMinimum) in rebound.contextAvailability
    doAssert compiledClassMinimumMarker(context.availableTailwindClasses.len) notin rebound.contextAvailability
    doAssert rebound.availableTailwindClasses == context.availableTailwindClasses
  if "--optional-compiled-classes" in commandLineParams():
    context.availableTailwindClasses = @[]
    for name in tailwindStyles.keys: context.availableTailwindClasses.add name
    context.availableTailwindClasses.sort()
    # Same production policy with ample nominal space retains optional extras;
    # quota must still be able to remove only those above the stable minimum.
    context.contextAvailability.add compiledClassMinimumMarker(context.availableTailwindClasses.len + 1)
    context.contextAvailability.add "availableTailwindClasses: required minimum malformed"
    context = boundAgentPromptContext(context, maxChars = 100000)
    doAssert not context.contextAvailability.anyIt(it.startsWith("availableTailwindClasses: required minimum"))
  snapshot = agentPromptContextJson(context)
  dispose()
echo snapshot
