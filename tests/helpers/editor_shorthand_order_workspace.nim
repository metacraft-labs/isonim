## Browser host for `tests/test_editor_shorthand_order_gui.mjs`: the editor
## example (`src/isonim/editor/main.nim`) with its real writer
## (`demoVectorEditAdapter`), real preview document and real browser
## selection bridge, plus project schema entries for the card's padding and
## margin sides -- the same `classes.destination-card.<side>` entries
## `tests/test_editor_section_box_model.nim` appends. The shipped example maps
## only the `padding` shorthand, so a side cannot be written there at all.
##
## The card rule the page starts from is read from
## `window.__isonimShorthandCardRule` (set by the test's page before this
## script), so each case starts from the declaration order it is about.

when not defined(js):
  {.error: "Compile with `nim js`".}

import std/strutils

import examples/wanderlust/stories as wanderlust
import isonim/editor
import isonim/editor/browser
import isonim/editor/demo_workspace

const MappedSides = ["padding-top", "padding-right", "padding-bottom",
  "padding-left", "margin-top", "margin-right", "margin-bottom", "margin-left",
  "margin"]

proc startingRule(): string =
  var rule: cstring = ""
  {.emit: [rule, " = (typeof window !== 'undefined' && window.__isonimShorthandCardRule) || '';"].}
  $rule

proc main() =
  let groups = wanderlust.buildWanderlustStoryboard()
  let vectorSource = new(string)
  let foundationSource = new(string)
  vectorSource[] = "<svg/>"
  let rule = startingRule()
  foundationSource[] =
    if rule.len > 0:
      DemoFoundationInitialSource.replace(".destination-card { padding: 18px; }",
        ".destination-card { " & rule & " }")
    else: DemoFoundationInitialSource
  exposeDemoSource(DemoFoundationSource, foundationSource[])
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  var schema = demoDesignSystemSchema()
  var adapter = demoVectorEditAdapter(vectorSource, foundationSource)
  for property in MappedSides:
    schema.nodes.add DesignSchemaNode(
      key: "classes.destination-card." & property,
      kind: dsnClassDefinition, name: "destination-card",
      component: "DestinationCard", property: property, value: "",
      sourceSpan: SourceSpan(file: DemoFoundationSource, line: 9, column: 1,
        endLine: 9, endColumn: 80),
      stories: @[story], components: @["DestinationCard"], usageCount: 4)
    adapter.schema.add WorkspaceEditableSchemaEntry(
      key: "classes.destination-card." & property, kind: wskSourceMap,
      file: DemoFoundationSource,
      path: "classes.destination-card." & property, story: story,
      property: property, removable: true)
  let workspace = newEditorWorkspace(
    title = "Wanderlust shorthand order",
    storyGroups = groups,
    canvasItems = wanderlust.wanderlustCanvasItems(groups),
    flowSteps = wanderlust.wanderlustFlowSteps(groups),
    foundationTokens = demoFoundationTokens(),
    designSystemSchema = schema,
    initialInspectorElement = some(demoInspectorElement()),
    responsiveBreakpoints = demoResponsiveBreakpoints(foundationSource[]),
    previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
      result = wanderlust.wanderlustPreviewHook(story, platform)
      if story.kind == skComponent and story.group == "DestinationCard":
        result.documentHtml = demoComponentDocument(foundationSource[],
          result.title, result.bodyText),
    id = "wanderlust-shorthand-order",
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = adapter)
  discard mountEditor(workspace)

main()
