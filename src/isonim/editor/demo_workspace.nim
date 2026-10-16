## The editor example's project workspace adapter (`src/isonim/editor/main.nim`).
##
## Moved out of `main.nim`, which only compiles with `nim js`, so that the
## example's real source writer can be exercised natively and under strict
## Node JS against the example's real foundation source
## (`tests/test_editor_reset_removal.nim`).

import std/strutils

import isonim/editor/types

const DemoFoundationSource* = "examples/wanderlust/design-system/foundations.css"

proc exposeDemoSource*(file, content: string) =
  when defined(js):
    # Guarded: outside a browser (strict Node tests) there is no window.
    {.emit: ["""
      if (typeof window !== 'undefined') {
        window.__isonimDemoSources = window.__isonimDemoSources || {};
        window.__isonimDemoSources[toJSStr(""", file, """)] = toJSStr(""", content, """);
      }
    """].}

const DemoFoundationInitialSource* =
  "--wl-color-blue-600: #2563EB;\n" &
  "--wl-action-primary: token(color.blue.600);\n" &
  "--wl-type-body-size: 16px;\n" &
  "--wl-space-card: 16px;\n" &
  "--wl-radius-card: 14px;\n" &
  "--wl-shadow-card: 0 12px 28px #0F172A;\n" &
  "--wl-motion-fast: 120ms;\n" &
  "--wl-breakpoint-compact: 640px;\n" &
  ".destination-card { padding: 18px; }\n"

proc demoInspectorElement*(): ElementRef =
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

proc demoDesignSystemSchema*(): DesignSystemSchema =
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

proc demoFoundationTokens*(): seq[FoundationTokenEntry] =
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

func demoDeclarations(content, property: string): seq[tuple[start, stop: int;
    value: string]] =
  ## Every `property: value;` declaration of ``property`` in ``content``:
  ## where it starts, one past its `;`, and its value. A name is matched
  ## whole (`padding` is not inside `--wl-padding` or `padding-top`).
  const nameChars = {'A'..'Z', 'a'..'z', '0'..'9', '-', '_'}
  if property.len == 0: return
  var at = content.find(property)
  while at >= 0:
    let startsName = at == 0 or content[at - 1] notin nameChars
    var colon = at + property.len
    while colon < content.len and content[colon] in {' ', '\t'}: inc colon
    if startsName and colon < content.len and content[colon] == ':':
      let semicolon = content.find(';', colon)
      let lineEnd = content.find('\n', colon)
      if semicolon > 0 and (lineEnd < 0 or semicolon < lineEnd):
        result.add (start: at, stop: semicolon + 1,
          value: content[colon + 1 ..< semicolon].strip())
    at = content.find(property, at + 1)

func removeDemoDeclaration(plan: SourceEditPlan; content: string;
    schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
  ## Reset: remove exactly the one declaration that owns ``plan.property``,
  ## with the single space that separated it from the rest of its line, or
  ## the whole line when the declaration is all it holds. Refused, with
  ## nothing changed, when no declaration or more than one owns the property
  ## (as a value replacement is refused when its value is not one whole
  ## occurrence), or when the declaration no longer says what the editor
  ## showed.
  let file = if schema.file.len > 0: schema.file else: plan.file
  proc refuse(kind: WorkspaceEditDiagnosticKind; why: string): WorkspacePatchResult =
    WorkspacePatchResult(ok: false, diagnostics: @[WorkspaceEditDiagnostic(
      kind: kind, message: "Refused to reset " & plan.property & ": " & why &
        " No source was changed.", file: file, schemaKey: plan.schemaKey,
      property: plan.property)])
  let found = content.demoDeclarations(plan.property)
  if found.len == 0:
    return refuse(wedPatchFailed, file & " has no " & plan.property &
      " declaration to remove.")
  if found.len > 1:
    return refuse(wedPatchFailed, file & " has " & $found.len & " " &
      plan.property & " declarations, so the one this edit owns cannot be " &
      "identified.")
  let declaration = found[0]
  if plan.expectedOldValue.len > 0 and
      declaration.value != plan.expectedOldValue:
    return refuse(wedSourceConflict, file & " declares " & plan.property &
      ": " & declaration.value & ", not " & plan.expectedOldValue & ".")
  var first = declaration.start
  var last = declaration.stop
  var lineStart = first
  while lineStart > 0 and content[lineStart - 1] != '\n': dec lineStart
  var lineEnd = last
  while lineEnd < content.len and content[lineEnd] != '\n': inc lineEnd
  if content[lineStart ..< first].strip().len == 0 and
      content[last ..< lineEnd].strip().len == 0:
    first = lineStart
    last = if lineEnd < content.len: lineEnd + 1 else: lineEnd
  elif last < content.len and content[last] == ' ':
    inc last
  elif first > 0 and content[first - 1] == ' ':
    dec first
  WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
    file: file,
    beforeContent: content,
    afterContent: content[0 ..< first] & content[last .. ^1],
    affectedStory: schema.story,
    fullReload: true))

proc demoVectorEditAdapter*(vectorSource, foundationSource: ref string): WorkspaceEditAdapter =
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
  # Removal (Reset) is stated per entry. A token definition is not
  # removable: every `var()` that names it would lose its value rather than
  # fall back to a class or inherited one. The SVG symbol is a whole file.
  for token in demoFoundationTokens():
    schema.add WorkspaceEditableSchemaEntry(
      key: token.schemaKey,
      kind: wskToken,
      file: DemoFoundationSource,
      path: token.key,
      story: foundationStory,
      property: token.property,
      removable: false)
  # The class rule's declaration is: removing it leaves the card's padding to
  # the cascade, which is what Reset means.
  schema.add WorkspaceEditableSchemaEntry(
    key: "classes.destination-card.padding",
    kind: wskSourceMap,
    file: DemoFoundationSource,
    path: "classes.destination-card.padding",
    story: StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0),
    property: "padding",
    removable: true)
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
    if plan.planKind == cspPropertyRemoval:
      return removeDemoDeclaration(plan, content, schema)
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

