## Browser host for `tests/test_editor_shorthand_order_gui.mjs`: the editor
## example (`src/isonim/editor/main.nim`) with its real writer
## (`demoVectorEditAdapter`), real preview document and real browser
## selection bridge, plus project schema entries for the card's padding and
## margin sides -- the same `classes.destination-card.<side>` entries
## `tests/test_editor_section_box_model.nim` appends. The shipped example maps
## only the `padding` shorthand, so a side cannot be written there at all.
##
## The card rule the page starts from is read from
## `window.__isonimShorthandCardRule`, and CSS appended after the
## foundation's rules from `window.__isonimShorthandExtraCss` (both set by the
## test's page before this script), so each case starts from the
## declaration order it is about.
##
## The card is given the id `window.__isonimShorthandCardId` names, when
## it names one, for the cases about a rule that selects it by id, and the
## extra class `window.__isonimShorthandCardClass` names (`2xl`, which
## Chromium serialises in a selector as `.\32 xl`).
##
## `window.__isonimShorthandSourceReplace` holds `from<TAB>to` lines replaced
## in the foundation source before the page starts (the canvas resize GUI's
## percentage gap, written in the long-tail rule the writer writes `gap` to).
##
## `window.__isonimShorthandReadOnly` set to `1` makes the workspace read-only
## for source changes (the canvas resize GUI's read-only cases); unset, the
## workspace is writable as before. `window.__isonimShorthandSetWriteSource`
## (defined by this script) changes that while the page runs.
## `window.__isonimShorthandVectorSymbols` set gives the workspace the editor
## example's source-backed Compass symbol (the vector refusal GUI); unset,
## the workspace has no vector symbols, as before. With it, the symbol file's
## starting content is in `window.__isonimDemoSources` from the start.
##
## Further properties of the card rule are mapped when
## `window.__isonimShorthandMapped` names them (comma-separated): the canvas
## resize handle's cases (`tests/test_editor_canvas_resize_gui.mjs`) map
## `width`.
##
## The card's corners are mapped too, and the example document's inline
## `border-radius:8px` is left out of the preview unless
## `window.__isonimShorthandKeepInlineRadius` is set: an inline declaration
## outranks every rule, so with it no rule order could show on the corners
## (the case that keeps it asserts exactly that the inline corners hold).

when not defined(js):
  {.error: "Compile with `nim js`".}

import std/strutils

import examples/wanderlust/stories as wanderlust
import isonim/editor
import isonim/editor/browser
import isonim/editor/demo_workspace
import isonim/core/signals

const MappedSides = ["padding-top", "padding-right", "padding-bottom",
  "padding-left", "margin-top", "margin-right", "margin-bottom", "margin-left",
  "margin", "border-radius", "border-top-left-radius",
  "border-top-right-radius", "border-bottom-right-radius",
  "border-bottom-left-radius"]

proc startingRule(): string =
  var rule: cstring = ""
  {.emit: [rule, " = (typeof window !== 'undefined' && window.__isonimShorthandCardRule) || '';"].}
  $rule

proc pageString(name: string): string =
  ## A string the test's page set on `window` before this script, or "".
  var value: cstring = ""
  let key: cstring = name
  {.emit: [value, " = (typeof window !== 'undefined' && window[", key, "]) || '';"].}
  $value

proc orderless(): bool =
  ## `window.__isonimShorthandOrderless`: the writer reports no rule order
  ## and does not name the rule it writes, a host with neither writer order
  ## nor native catalog statements.
  var drop = false
  {.emit: [drop, " = !!(typeof window !== 'undefined' && window.__isonimShorthandOrderless);"].}
  drop

proc keepInlineRadius(): bool =
  var keep = false
  {.emit: [keep, " = !!(typeof window !== 'undefined' && window.__isonimShorthandKeepInlineRadius);"].}
  keep

proc extraCss(): string =
  var css: cstring = ""
  {.emit: [css, " = (typeof window !== 'undefined' && window.__isonimShorthandExtraCss) || '';"].}
  $css

proc main() =
  let groups = wanderlust.buildWanderlustStoryboard()
  let vectorSource = new(string)
  let foundationSource = new(string)
  vectorSource[] =
    if pageString("__isonimShorthandVectorSymbols").len > 0:
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\"><path d=\"M12 2l4 14-4-2-4 2 4-14z\" /></svg>"
    else: "<svg/>"
  let rule = startingRule()
  foundationSource[] =
    if rule.len > 0:
      DemoFoundationInitialSource.replace(".destination-card { padding: 18px; }",
        ".destination-card { " & rule & " }")
    else: DemoFoundationInitialSource
  foundationSource[].add extraCss()
  # `window.__isonimShorthandSourceReplace`: `from<TAB>to` lines applied to
  # the foundation source, for a case that needs another value in a rule the
  # example already has (the long-tail rule's `gap`, say).
  for line in pageString("__isonimShorthandSourceReplace").splitLines():
    let tab = line.find('\t')
    if tab > 0:
      foundationSource[] = foundationSource[].replace(line[0 ..< tab], line[tab + 1 .. ^1])
  # Text placed at the start of the preview's stylesheet, before every rule
  # (`window.__isonimShorthandPrefixCss`; added to the document, not to the
  # foundation source, whose first `.destination-card` the example's page
  # splits at), and a stylesheet the preview links from another origin
  # (`window.__isonimShorthandLink`), for the cases about what the capture
  # can read.
  let prefix = pageString("__isonimShorthandPrefixCss")
  let link = pageString("__isonimShorthandLink")
  # A script run right after the preview's stylesheet, before the editor's
  # preview runtime (`window.__isonimShorthandAfterStyleScript`): a page
  # script whose CSSOM edits the runtime cannot have seen.
  let afterStyle = pageString("__isonimShorthandAfterStyleScript")
  let cardId = pageString("__isonimShorthandCardId")
  let cardClass = pageString("__isonimShorthandCardClass")
  let stripInline = not keepInlineRadius()
  exposeDemoSource(DemoFoundationSource, foundationSource[])
  let story = StoryRef(group: "DestinationCard", name: "Default",
    kind: skComponent, index: 0)
  var schema = demoDesignSystemSchema()
  var adapter = demoVectorEditAdapter(vectorSource, foundationSource)
  # The vector file's starting content is published (in
  # `window.__isonimDemoSources`) before any edit reads it, so a write receipt
  # compares against what the file held: the adapter otherwise publishes a
  # file on its first read, which would look like a write.
  if pageString("__isonimShorthandVectorSymbols").len > 0:
    for entry in adapter.schema:
      if entry.key == "symbols.compass.svg":
        exposeDemoSource(entry.file, vectorSource[])
  if orderless():
    adapter.ruleDeclarations = nil
    adapter.editRule = nil
  # `window.__isonimShorthandStagingOnly`: a project that only stages edits
  # (the write does not reload the preview); `window.__isonimShorthandFailWrites`:
  # every file write fails, as a full disk or a locked file would.
  if pageString("__isonimShorthandStagingOnly").len > 0:
    adapter.stagingOnly = true
  if pageString("__isonimShorthandFailWrites").len > 0:
    adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
      WorkspaceOperationResult(ok: false, message: "Could not write " & file &
        ": the test host refuses every write.")
  # `window.__isonimShorthandMapped`: more of the card rule's properties to
  # map, comma-separated (`width` for the canvas resize handle's cases).
  var mapped = @MappedSides
  for extra in pageString("__isonimShorthandMapped").split(','):
    if extra.strip().len > 0: mapped.add extra.strip()
  for property in mapped:
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
    # `window.__isonimShorthandVectorSymbols` set: the editor example's
    # Compass symbol, source-backed by the example's vector writer, opened
    # first in the vector view (the vector refusal GUI). Unset: no symbols,
    # as before.
    vectorSymbols = (if pageString("__isonimShorthandVectorSymbols").len > 0:
      @[VectorSymbol(name: "Compass", category: "Icons",
        svgContent: "<path d=\"M12 2l4 14-4-2-4 2 4-14z\" />",
        tags: @["travel", "navigation"], width: 24, height: 24)]
      else: @[]),
    initialVectorSymbol = (if pageString("__isonimShorthandVectorSymbols").len > 0:
      some(0) else: none(int)),
    initialInspectorElement = some(demoInspectorElement()),
    responsiveBreakpoints = demoResponsiveBreakpoints(foundationSource[]),
    previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
      result = wanderlust.wanderlustPreviewHook(story, platform)
      if story.kind == skComponent and story.group == "DestinationCard":
        result.documentHtml = demoComponentDocument(foundationSource[],
          result.title, result.bodyText).replace("border-radius:8px;",
            if stripInline: "" else: "border-radius:8px;")
        if afterStyle.len > 0:
          result.documentHtml = result.documentHtml.replace("</style>",
            "</style><script>" & afterStyle & "</script>")
        if cardId.len > 0:
          result.documentHtml = result.documentHtml.replace(
            "<article class=\"destination-card",
            "<article id=\"" & cardId & "\" class=\"destination-card")
        if cardClass.len > 0:
          result.documentHtml = result.documentHtml.replace(
            "class=\"destination-card long-tail-card\"",
            "class=\"destination-card long-tail-card " & cardClass & "\"")
        if prefix.len > 0:
          result.documentHtml = result.documentHtml.replace("<head><style>",
            "<head><style>" & prefix)
        if link.len > 0:
          result.documentHtml = result.documentHtml.replace("<head>",
            "<head><link rel=\"stylesheet\" href=\"" & link & "\">"),
    id = "wanderlust-shorthand-order",
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: pageString("__isonimShorthandReadOnly") != "1"),
    editAdapter = adapter)
  let vm = mountEditor(workspace)
  # `window.__isonimShorthandSetWriteSource(on)`: grant or withdraw source
  # writes while the page runs (the vector canvas's case of a refusal after
  # accepted edits). Unused, it changes nothing.
  let setWriteSource = proc(on: bool) =
    var permissions = vm.workspacePermissions.val
    permissions.writeSource = on
    vm.workspacePermissions.val = permissions
  {.emit: ["window.__isonimShorthandSetWriteSource = function (on) { ", setWriteSource, "(!!on); };"].}

main()
