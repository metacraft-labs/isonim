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

func demoRuleSelector(schema: WorkspaceEditableSchemaEntry): string =
  ## The class rule a `classes.<name>.<property>` entry owns, as `.<name>`,
  ## or "" for an entry that is not a class rule's declaration.
  const prefix = "classes."
  if schema.kind != wskSourceMap or not schema.path.startsWith(prefix): return
  let rest = schema.path[prefix.len .. ^1]
  let suffix = "." & schema.property
  if schema.property.len == 0 or not rest.endsWith(suffix): return
  "." & rest[0 ..< rest.len - suffix.len]

type DemoRule = tuple[selector: string; bodyStart, bodyEnd: int]

func demoRules(content, selector: string): seq[DemoRule] =
  ## Every `{ ... }` rule whose selector list names ``selector``. The
  ## foundation file mixes top-level custom properties with rules, so a
  ## rule's selector is the text since the previous `;` or `}`.
  var segment = 0
  var at = 0
  while at < content.len:
    case content[at]
    of ';', '}':
      segment = at + 1
    of '{':
      let close = content.find('}', at + 1)
      if close < 0: return
      let text = content[segment ..< at].strip()
      for member in text.split(','):
        if member.strip() == selector:
          result.add (selector: text, bodyStart: at + 1, bodyEnd: close)
          break
      segment = close + 1
      at = close
    else: discard
    inc at

func demoRuleRefusal(rules: seq[DemoRule]; file, selector,
    property: string): string =
  ## Why ``property`` cannot be written in the one rule ``selector`` owns, or
  ## "" when it can. A rule whose selector is a list also styles every other
  ## selector in the list, so an edit there would not be this class's alone
  ## (editor spec "Saving": an edit changes exactly the one owning
  ## declaration).
  if rules.len == 0:
    return file & " has no " & selector & " rule to hold " & property & "."
  if rules.len > 1:
    return file & " has " & $rules.len & " " & selector & " rules, so the " &
      "one that owns " & property & " cannot be identified."
  if ',' in rules[0].selector:
    return "The " & selector & " rule is shared by the selector list `" &
      rules[0].selector & "`; changing " & property & " there would change " &
      "every selector in the list. Edit the stylesheet directly."

func setDemoDeclaration(plan: SourceEditPlan; content: string;
    schema: WorkspaceEditableSchemaEntry; selector: string): WorkspacePatchResult =
  ## A value for a class rule's property, written inside that rule: the one
  ## declaration's value is replaced, or -- when the rule has none, as after
  ## Reset removed it -- `property: value;` is inserted before the rule's
  ## closing brace. Nothing outside the rule is touched; anything else is
  ## refused with nothing changed.
  let file = if schema.file.len > 0: schema.file else: plan.file
  proc refuse(kind: WorkspaceEditDiagnosticKind; why: string): WorkspacePatchResult =
    WorkspacePatchResult(ok: false, diagnostics: @[WorkspaceEditDiagnostic(
      kind: kind, message: "Refused to set " & plan.property & ": " & why &
        " No source was changed.", file: file, schemaKey: plan.schemaKey,
      property: plan.property)])
  let rules = content.demoRules(selector)
  let refusal = demoRuleRefusal(rules, file, selector, plan.property)
  if refusal.len > 0: return refuse(wedPatchFailed, refusal)
  let rule = rules[0]
  let body = content[rule.bodyStart ..< rule.bodyEnd]
  let found = body.demoDeclarations(plan.property)
  if found.len > 1:
    return refuse(wedPatchFailed, "the " & selector & " rule has " &
      $found.len & " " & plan.property & " declarations, so the one this " &
      "edit owns cannot be identified.")
  let value = plan.newValue.strip()
  var next: string
  if found.len == 1:
    let declaration = found[0]
    if plan.expectedOldValue.len > 0 and
        declaration.value != plan.expectedOldValue:
      return refuse(wedSourceConflict, file & " declares " & plan.property &
        ": " & declaration.value & ", not " & plan.expectedOldValue & ".")
    let colon = body.find(':', declaration.start)
    next = content[0 ..< rule.bodyStart + colon + 1] & " " & value &
      content[rule.bodyStart + declaration.stop - 1 .. ^1]
  else:
    if plan.expectedOldValue.len > 0:
      return refuse(wedSourceConflict, "the " & selector & " rule declares " &
        "no " & plan.property & ", not " & plan.expectedOldValue & ".")
    # Before the closing brace, after the rule's last declaration: one
    # space on either side, as the rule is written on one line.
    var stop = rule.bodyEnd
    while stop > rule.bodyStart and content[stop - 1] in Whitespace: dec stop
    let separator = if stop > rule.bodyStart and content[stop - 1] != ';': "; "
      else: " "
    next = content[0 ..< stop] & separator & plan.property & ": " & value &
      "; " & content[rule.bodyEnd .. ^1]
  WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
    file: file,
    beforeContent: content,
    afterContent: next,
    affectedStory: schema.story,
    fullReload: true))

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
  # A class rule's declaration is removed only from that rule, and not from
  # a rule its selector shares with others.
  let selector = demoRuleSelector(schema)
  if selector.len > 0:
    let rules = content.demoRules(selector)
    let refusal = demoRuleRefusal(rules, file, selector, plan.property)
    if refusal.len > 0: return refuse(wedPatchFailed, refusal)
    if declaration.start < rules[0].bodyStart or
        declaration.stop > rules[0].bodyEnd:
      return refuse(wedPatchFailed, "its " & plan.property & " declaration " &
        "is not in the " & selector & " rule.")
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
    let selector = demoRuleSelector(schema)
    if selector.len > 0:
      return setDemoDeclaration(plan, content, schema, selector)
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
  # The writer's statement at the act: a class rule shared by a selector list
  # is refused when the edit is committed, from the source this adapter holds
  # (no file read), before anything is previewed, journaled or written.
  result.editRefusal = proc(plan: SourceEditPlan;
      schema: WorkspaceEditableSchemaEntry): string =
    let selector = demoRuleSelector(schema)
    if selector.len == 0 or schema.file != DemoFoundationSource: return
    let rules = foundationSource[].demoRules(selector)
    if rules.len == 1 and ',' in rules[0].selector:
      return demoRuleRefusal(rules, schema.file, selector, plan.property)
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

