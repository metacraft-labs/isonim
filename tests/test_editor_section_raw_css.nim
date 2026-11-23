## The per-section Raw CSS editor of the section-based inspector.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Universal
## Patterns": "Raw CSS toggle -- switch to raw CSS text editing for any
## section", and the clause under it that says how the raw CSS is shown,
## committed, refused and undone; "Saving" for the act-time refusals, the
## automatic write and undo across writes. isonim-pm issue
## 2026-09-26-the-consumer-editor-spec-tests-the-inspector-that-was-demolished,
## "The removed-controls cases are missing features, not stale tests".
##
## The writer suites use no mock writer: the editor example's production
## adapter (`demo_workspace.demoVectorEditAdapter`) writes the example's real
## foundation source held in memory, exactly as `main.nim` mounts it, and a
## real EditorVM plans, journals, writes and undoes through it.
##
## Mock justification: MockRenderer stands in for the browser DOM so the
## production inspector panel (`shell.renderInspectorPanel`, its section
## widgets, property rows and the raw CSS editor) runs natively and under
## strict Node JS with real signals, owners and EditorVM; events are
## dispatched to the listeners the views registered. One case gives the
## EditorVM an `inspectorSourceCommit` recording callback: it stands for the
## native source bridge, which the inspector calls and does not own, and no
## write is claimed there. One case replaces a single row's commit with one
## that refuses, standing for a refusal made at the write itself, which the
## real writer never gives after the act-time check (see that case). The browser, the example's page and its writer are
## exercised by the editor-example Playwright case
## `e2e_section_raw_css_toggle_commits_refuses_and_undoes`, and the consumer's
## real write bridge by metacraft-web-editor's
## `metacraft_long_tail_properties_validate_real_components`.

import std/[options, sequtils, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor
import isonim/editor/demo_workspace
import isonim/editor/views/shell
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/section_raw_css

const LongTailRule = ".long-tail-card { letter-spacing: 0px; text-transform: none; " &
  "background-image: none; background-size: auto; border-style: solid; " &
  "outline-offset: 0px; filter: none; transform: none; " &
  "transition-duration: 0s; flex-wrap: nowrap; overflow: visible; " &
  "aspect-ratio: auto; }\n"

proc demoVm(foundation: ref string; writable = true;
    tokens = demoFoundationTokens();
    schema = demoDesignSystemSchema()): EditorVM =
  let vector = new(string)
  vector[] = "<svg/>"
  result = createEditorVM(newEditorWorkspace(
    title = "Wanderlust raw CSS fixture",
    storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
      expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
        group: "DestinationCard")])],
    initialStory = some(StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0)),
    foundationTokens = tokens,
    designSystemSchema = schema,
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: writable),
    editAdapter = demoVectorEditAdapter(vector, foundation)))
  check result.selectInspectorElement(demoInspectorElement())

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

proc press(node: MockNode; key: string; shift = false) =
  node.fireEventWith("keydown", MockEvent(`type`: "keydown", target: node,
    currentTarget: node, key: key, shiftKey: shift))

proc typeInto(r: MockRenderer; node: MockNode; value: string) =
  r.setInputValue(node, value)
  node.fireEvent("input")

template need(node: MockNode) {.dirty.} =
  ## A control the test drives must exist; a missing one fails here and ends
  ## the case instead of crashing on a nil node later.
  check node != nil
  if node == nil:
    dispose()
    return

proc value(vm: EditorVM; name: string): string =
  for prop in vm.inspector.selectedElement.val.properties:
    if prop.name == name: return prop.value

proc stacks(vm: EditorVM): (int, int) =
  (vm.inspector.undoStack.val.len, vm.inspector.redoStack.val.len)

proc field(panel: MockNode; section: string): MockNode =
  findByAttr(panel, "aria-label", "Edit raw CSS for " & section & " section")

proc toggle(panel: MockNode; section: string): MockNode =
  findByAttr(panel, "aria-label", "Show raw CSS for " & section & " section")

proc message(panel: MockNode; slug: string): MockNode =
  findByAttr(panel, "data-section-raw-css-message", slug)

proc rowsOf(panel: MockNode; slug: string): MockNode =
  findByAttr(panel, "data-inspector-section-rows", slug)

proc write(vm: EditorVM) =
  let saved = vm.applyWorkspaceFileEdits()
  check saved.ok
  check vm.inspector.pendingSourceEdits.val.len == 0

suite "raw CSS text":
  test "declarations separate on semicolons and line breaks outside brackets and quotes":
    let parsed = parseRawCss("filter: brightness(1.08) contrast(1.1);\n" &
      "transform: translateX(8px)\n /* a comment; with a semicolon */ " &
      "background-image: url(\"a;b.png\"), linear-gradient(\n  red,\n  blue);" &
      "FONT-family: 'A; B', serif")
    check parsed.error == ""
    check parsed.declarations == @[
      RawCssDeclaration(property: "filter", value: "brightness(1.08) contrast(1.1)"),
      RawCssDeclaration(property: "transform", value: "translateX(8px)"),
      RawCssDeclaration(property: "background-image",
        value: "url(\"a;b.png\"), linear-gradient(   red,   blue)"),
      RawCssDeclaration(property: "font-family", value: "'A; B', serif")]

  test "a custom property keeps its case; !important is the value's trailing flag only":
    # Custom property names are case-sensitive (CSS Variables 1 §2).
    check parseRawCss("--Card-Glow: 4px").declarations ==
      @[RawCssDeclaration(property: "--Card-Glow", value: "4px")]
    # A quoted string that contains the word is a value like any other.
    check parseRawCss("content: \"!important\"").declarations ==
      @[RawCssDeclaration(property: "content", value: "\"!important\"")]
    for text in ["filter: none!important", "filter: none ! IMPORTANT"]:
      check "!important cannot be set" in parseRawCss(text).error

  test "a later declaration of the same property replaces an earlier one":
    let parsed = parseRawCss("gap: 4px; padding: 2px; gap: 8px")
    check parsed.error == ""
    check parsed.declarations == @[
      RawCssDeclaration(property: "gap", value: "8px"),
      RawCssDeclaration(property: "padding", value: "2px")]

  test "blank text has no declarations; formatted text parses back":
    check parseRawCss("  \n ; ;\n").declarations.len == 0
    let declarations = @[RawCssDeclaration(property: "gap", value: "8px"),
      RawCssDeclaration(property: "aspect-ratio", value: "4 / 3")]
    check formatRawCss(declarations) == "gap: 8px;\naspect-ratio: 4 / 3;\n"
    check parseRawCss(formatRawCss(declarations)).declarations == declarations

  test "text that is not a declaration list is refused with the reason":
    for (text, reason) in [
        ("filter brightness(2)", "is not a declaration"),
        ("fil ter: none", "is not a CSS property name"),
        ("2col: none", "is not a CSS property name"),
        ("filter:", "has no value"),
        ("filter: none !important", "!important cannot be set"),
        ("content: \"open", "Unterminated string"),
        ("filter: none /* open", "Unterminated comment"),
        ("filter: blur(2px", "Unclosed bracket"),
        ("filter: blur(2px))", "Unbalanced"),
        (".card { gap: 2px }", "without a selector or braces")]:
      let parsed = parseRawCss(text)
      check reason in parsed.error
      check parsed.declarations.len == 0

suite "the raw CSS field and toggle of each section":
  test "every section that edits CSS has the field and toggle; the others have none":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      for (slug, name) in inspectorPlaceholderSections:
        let editsCss = slug in inspectorRawCssSections
        let field = panel.field(name)
        let toggle = panel.toggle(name)
        check (field != nil) == editsCss
        check (toggle != nil) == editsCss
        if editsCss and field != nil and toggle != nil:
          check field.tag == "textarea"
          check toggle.tag == "button"
          check toggle.attributes.getOrDefault("aria-pressed") == "false"
      dispose()

  test "the toggle switches a section between its rows and its declarations as text":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      let toggle = panel.toggle("Effects")
      need(toggle)
      let rows = panel.rowsOf("effects")
      need(rows)
      # On its rows, the field is an empty one-line entry under them.
      check rows.styles.getOrDefault("display") == "flex"
      check r.inputValue(field) == ""
      check field.attributes.getOrDefault("rows") == "1"
      toggle.fireEvent("click")
      check vm.inspector.sectionShowsRawCss(isEffects)
      check toggle.attributes.getOrDefault("aria-pressed") == "true"
      check rows.styles.getOrDefault("display") == "none"
      # Every declaration the section's rows edit for the selection, in row
      # order, as CSS text.
      check r.inputValue(field) ==
        "filter: none;\ntransform: none;\ntransition-duration: 0s;\n"
      check field.attributes.getOrDefault("rows") == "4"
      # Another section is unaffected.
      check panel.rowsOf("layout").styles.getOrDefault("display") == "flex"
      check r.inputValue(panel.field("Layout")) == ""
      toggle.fireEvent("click")
      check not vm.inspector.sectionShowsRawCss(isEffects)
      check toggle.attributes.getOrDefault("aria-pressed") == "false"
      check rows.styles.getOrDefault("display") == "flex"
      check r.inputValue(field) == ""
      dispose()

suite "committing raw CSS through the section's rows":
  test "a typed declaration commits, previews, is written inside its rule and undoes":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      let generation = vm.autoSaveGeneration.val
      r.typeInto(field, "filter: brightness(1.08) contrast(1.1)")
      field.press("Enter")
      check vm.value("filter") == "brightness(1.08) contrast(1.1)"
      check vm.stacks == (1, 0)
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.autoSaveGeneration.val == generation + 1
      check panel.message("effects").styles.getOrDefault("display") == "none"
      # The entry clears once its declarations are committed.
      check r.inputValue(field) == ""
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        " filter: none;", " filter: brightness(1.08) contrast(1.1);")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      check vm.value("filter") == "none"
      dispose()

  test "values valid under CSS that hold commas, lists or functions are written; a malformed one is refused":
    # isonim-pm issue 2026-11-20 "The editor refuses valid CSS values it
    # mistakes for lengths": the raw CSS editor refuses a value its row
    # rejects, so a wrongly rejected value had no editor path. These values
    # are valid (Filter Effects 1 §6 drop-shadow(), CSS Transforms 1 §11,
    # CSS Transitions 1 §2.2) and are written as typed.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      let message = panel.message("effects")
      need(message)
      # A transform whose arguments are malformed is refused, and nothing
      # changes.
      r.typeInto(field, "transform: translate(-3 -3)")
      field.press("Enter")
      check "Transform values must use supported CSS transform functions" in
        textContent(message)
      check vm.value("transform") == "none"
      check vm.stacks == (0, 0)
      check foundation[] == DemoFoundationInitialSource
      r.typeInto(field, "filter: drop-shadow(0 1px 2px #000);\n" &
        "transform: translate(4px, 2px) scale(1.2);\n" &
        "transition-duration: 1s, 200ms;\n")
      field.press("Enter")
      check vm.value("filter") == "drop-shadow(0 1px 2px #000)"
      check vm.value("transform") == "translate(4px, 2px) scale(1.2)"
      check vm.value("transition-duration") == "1s, 200ms"
      check vm.stacks == (3, 0)
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        " filter: none;", " filter: drop-shadow(0 1px 2px #000);").replace(
        " transform: none;", " transform: translate(4px, 2px) scale(1.2);").replace(
        " transition-duration: 0s;", " transition-duration: 1s, 200ms;")
      dispose()

  test "the section's text commits each changed declaration as one write, undone one by one":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      panel.toggle("Effects").fireEvent("click")
      r.typeInto(field, "filter: none;\ntransform: translateX(8px) scale(1.02);\n" &
        "transition-duration: 180ms;\n")
      # Shift+Enter is a line break, not a commit.
      field.press("Enter", shift = true)
      check vm.stacks == (0, 0)
      # Leaving the field commits.
      field.fireEvent("blur")
      check vm.value("transform") == "translateX(8px) scale(1.02)"
      check vm.value("transition-duration") == "180ms"
      check vm.value("filter") == "none"
      # Two edits: the unchanged declaration is not one.
      check vm.stacks == (2, 0)
      check r.inputValue(field) == "filter: none;\n" &
        "transform: translateX(8px) scale(1.02);\ntransition-duration: 180ms;\n"
      vm.write()
      let written = DemoFoundationInitialSource.replace(" transform: none;",
        " transform: translateX(8px) scale(1.02);").replace(
        " transition-duration: 0s;", " transition-duration: 180ms;")
      check foundation[] == written
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(" transform: none;",
        " transform: translateX(8px) scale(1.02);")
      check vm.runEditorCommand(eckUndo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource
      # The text follows the model after the undos.
      check r.inputValue(field) ==
        "filter: none;\ntransform: none;\ntransition-duration: 0s;\n"
      check vm.runEditorCommand(eckRedo).status == ecsSucceeded
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(" transform: none;",
        " transform: translateX(8px) scale(1.02);")
      dispose()

  test "invalid text is refused at the commit with the reason, and nothing changes":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      let message = panel.message("effects")
      need(message)
      let generation = vm.autoSaveGeneration.val
      for (text, reason) in [
          ("filter brightness(2)", "is not a declaration"),
          # A value its row would refuse refuses the whole commit, including
          # the valid declaration before it.
          ("transform: scale(2); filter: glow(4px)",
            "Filter values must use supported CSS filter functions"),
          # A property another section edits.
          ("padding: 4px", "padding is not edited in the Effects section."),
          ("--card-glow: 4px", "--card-glow is not edited in the Effects section.")]:
        r.typeInto(field, text)
        field.press("Enter")
        check reason in textContent(message)
        check message.attributes.getOrDefault("role") == "alert"
        check message.styles.getOrDefault("display") == "block"
        check field.attributes.getOrDefault("aria-invalid") == "true"
        # The text stays, so it can be corrected.
        check r.inputValue(field) == text
        check vm.value("transform") == "none"
        check vm.value("filter") == "none"
        check vm.stacks == (0, 0)
        check vm.inspector.pendingSourceEdits.val.len == 0
        check vm.autoSaveGeneration.val == generation
      # Switching the section keeps the refused text and its reason.
      let toggle = panel.toggle("Effects")
      need(toggle)
      toggle.fireEvent("click")
      check vm.inspector.sectionShowsRawCss(isEffects)
      check r.inputValue(field) == "--card-glow: 4px"
      check message.styles.getOrDefault("display") == "block"
      toggle.fireEvent("click")
      check r.inputValue(field) == "--card-glow: 4px"
      check vm.stacks == (0, 0)
      # Escape gives the field back to the model.
      field.press("Escape")
      check r.inputValue(field) == ""
      check message.styles.getOrDefault("display") == "none"
      check "aria-invalid" notin field.attributes
      check foundation[] == DemoFoundationInitialSource
      dispose()

  test "a scope the project's writer refuses is refused at the act with the writer's reason":
    ## The example writer refuses a class rule shared by a selector list
    ## (editor spec "Saving"): changing it would change every selector in
    ## the list.
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let listed = DemoFoundationInitialSource.replace(".long-tail-card {",
        ".long-tail-card, .hero {")
      check listed != DemoFoundationInitialSource
      let foundation = new(string)
      foundation[] = listed
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      let generation = vm.autoSaveGeneration.val
      r.typeInto(field, "filter: brightness(1.08)")
      field.press("Enter")
      check "shared by the selector list `.long-tail-card, .hero`" in
        textContent(panel.message("effects"))
      check vm.value("filter") == "none"
      check vm.stacks == (0, 0)
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.autoSaveGeneration.val == generation
      check foundation[] == listed
      dispose()

  test "a refusal only the commit can know stops there and names what was applied":
    ## Editor spec "Universal Patterns", Raw CSS toggle: "A refusal that only
    ## the commit itself can know stops the commit at that declaration and
    ## says which declarations were applied before it." The act-time check
    ## asks every question the example's writer asks, so no real writer
    ## refuses after it; the transform row's commit is replaced by one that
    ## refuses with a reason, standing for a refusal made at the write (a
    ## file changed underneath). The filter row is the production wiring.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let registry = createInspectorSectionCss()
      registerSectionCssRow(registry, vm.inspectorRowWiring("filter"))
      var refusing = vm.inspectorRowWiring("transform")
      let message = refusing.commitMessage
      refusing.commitAsync = proc(value: string; done: proc(ok: bool) {.closure.}) =
        message.val = "the source file changed on disk."
        done(false)
      registerSectionCssRow(registry, refusing)
      var reported: seq[RawCssCommitOutcome] = @[]
      let outcome = commitSectionRawCss(vm, registry, "Effects",
        "filter: brightness(1.08); transform: scale(2)",
        proc(outcome: RawCssCommitOutcome) = reported.add outcome)
      check not outcome.ok
      check outcome.message ==
        "transform: the source file changed on disk. Applied before it: filter."
      check outcome.changed == @["filter"]
      check reported == @[outcome]
      check vm.value("filter") == "brightness(1.08)"
      check vm.value("transform") == "none"
      check vm.stacks == (1, 0)
      dispose()

  test "a read-only workspace refuses the commit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation, writable = false)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Layout")
      need(field)
      r.typeInto(field, "aspect-ratio: 4 / 3")
      field.press("Enter")
      check "read-only" in textContent(panel.message("layout"))
      check vm.value("aspect-ratio") == "auto"
      check vm.stacks == (0, 0)
      dispose()

  test "another selection discards the typed text and the refusal":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      r.typeInto(field, "filter brightness")
      field.press("Enter")
      check panel.message("effects").styles.getOrDefault("display") == "block"
      var other = demoInspectorElement()
      other.id = "destination-card-copy"
      check vm.selectInspectorElement(other)
      check r.inputValue(field) == ""
      check panel.message("effects").styles.getOrDefault("display") == "none"
      dispose()

  test "a native source project is sent one declaration at a time":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      var sent: seq[(string, string)] = @[]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        sent.add (property, value)
        done(true, "")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      r.typeInto(field, "filter: brightness(2); transform: scale(2)")
      field.press("Enter")
      check "one declaration at a time" in textContent(panel.message("effects"))
      check sent.len == 0
      r.typeInto(field, "filter: brightness(2)")
      field.press("Enter")
      check sent == @[("filter", "brightness(2)")]
      check panel.message("effects").styles.getOrDefault("display") == "none"
      check r.inputValue(field) == ""
      dispose()

suite "var() references written as typed":
  ## isonim-pm issue 2026-11-21 "var() references written in upper case,
  ## with spaces or after a comment are refused". Each spelling is valid
  ## CSS (CSS Syntax 3 function names and whitespace; CSS Variables 1 §3.1)
  ## and is typed through the inspector's own commit -- a row, and the
  ## section's raw CSS field -- then written by the example's production
  ## writer; the file must hold exactly what was typed. `var(--name)` keeps
  ## the token form the editor already writes for it.
  const typed = ["VAR(--a)", "var( --a )", "var(/**/--a)", "var(--a) 1px",
    "Var(--a) 1px", "var( --a ) auto", "var(/* c */ --a, 2px)"]

  test "a row commit writes each spelling exactly, and undo restores the file":
    for property in ["letter-spacing", "outline-offset", "filter", "transform"]:
      for value in typed:
        checkpoint property & ": " & value
        createRoot proc(dispose: proc()) =
          let foundation = new(string)
          foundation[] = DemoFoundationInitialSource
          let vm = demoVm(foundation)
          let before = " " & property & ": " & vm.value(property) & ";"
          let committed = vm.commitInspectorValue(property, value, sskSharedClass)
          check committed.ok
          check committed.message == ""
          check vm.value(property) == value
          vm.write()
          check foundation[] == DemoFoundationInitialSource.replace(before,
            " " & property & ": " & value & ";")
          check vm.runEditorCommand(eckUndo).status == ecsSucceeded
          vm.write()
          check foundation[] == DemoFoundationInitialSource
          dispose()

  test "the raw CSS field writes each spelling exactly":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = panel.field("Effects")
      need(field)
      r.typeInto(field, "filter: VAR(--f);\ntransform: var( --t ) scale(2);\n" &
        "transition-duration: var(/**/--d);\n")
      field.press("Enter")
      check panel.message("effects").styles.getOrDefault("display") == "none"
      check vm.value("filter") == "VAR(--f)"
      check vm.value("transform") == "var( --t ) scale(2)"
      # The raw text's comments are ignored (editor spec "Raw CSS toggle"):
      # one ends the token before it, so it is read as a space.
      check vm.value("transition-duration") == "var( --d)"
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(
        " filter: none;", " filter: VAR(--f);").replace(
        " transform: none;", " transform: var( --t ) scale(2);").replace(
        " transition-duration: 0s;", " transition-duration: var( --d);")
      dispose()

  test "var(--name) is written as typed, not in a token form":
    for property in ["letter-spacing", "filter"]:
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation)
        let before = " " & property & ": " & vm.value(property) & ";"
        check vm.commitInspectorValue(property, "var(--a)", sskSharedClass).ok
        vm.write()
        check foundation[] == DemoFoundationInitialSource.replace(before,
          " " & property & ": var(--a);")
        dispose()

  test "a var() with a fallback is a use of the custom property, not of its fallback":
    # Written as typed, and the token identity is the custom property's name
    # alone, so the use counts towards that token (editor spec: the editor
    # shows the token identity and its known direct usage).
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let before = " letter-spacing: " & vm.value("letter-spacing") & ";"
      check vm.commitInspectorValue("letter-spacing", "var(--wl-space-card, 4px)",
        sskSharedClass).ok
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(before,
        " letter-spacing: var(--wl-space-card, 4px);")
      check vm.value("letter-spacing") == "var(--wl-space-card, 4px)"
      var tokenName = ""
      for prop in vm.inspector.selectedElement.val.properties:
        if prop.name == "letter-spacing": tokenName = prop.tokenName
      check tokenName == "wl-space-card"
      check vm.tokenChain(vm.value("letter-spacing")) == @["wl-space-card"]
      var used: seq[string]
      for prop in vm.foundationImpact("wl-space-card").affectedProperties:
        used.add prop.name
      check "letter-spacing" in used
      check vm.foundationImpact("wl-space-card, 4px").affectedProperties.len == 0
      dispose()

  test "a custom property is never refused for its name; a design token must be defined":
    # isonim-pm issue 2026-11-23-var-missing-is-refused-as-an-unknown-design-
    # token: `var(--missing)` is valid CSS whatever the name (CSS Variables 1
    # §3). A design-schema spelling names a token the project defines.
    for value in ["var(--missing)", "var(--missing, 1px)"]:
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation)
        let before = " letter-spacing: " & vm.value("letter-spacing") & ";"
        check vm.commitInspectorValue("letter-spacing", value, sskSharedClass).ok
        vm.write()
        check foundation[] == DemoFoundationInitialSource.replace(before,
          " letter-spacing: " & value & ";")
        dispose()
    for value in ["token(no.such.token)", "$no.such.token"]:
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation)
        let outcome = vm.commitInspectorValue("letter-spacing", value, sskSharedClass)
        check not outcome.ok
        check outcome.message == "Unknown design token 'no.such.token'."
        vm.write()
        check foundation[] == DemoFoundationInitialSource
        dispose()
    # A token the example defines (its foundations) is accepted.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.commitInspectorValue("letter-spacing", "token(space.card)",
        sskSharedClass).ok
      dispose()

  test "a design-schema token key is defined without any foundation token":
    # The example's schema defines `wanderlust.foundation.space.card`; with
    # no foundation tokens that key alone is accepted, and a key neither
    # defines is refused (review R3).
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation, tokens = @[])
      let before = " letter-spacing: " & vm.value("letter-spacing") & ";"
      let refused = vm.commitInspectorValue("letter-spacing", "token(no.such)",
        sskSharedClass)
      check not refused.ok
      check refused.message == "Unknown design token 'no.such'."
      check vm.commitInspectorValue("letter-spacing",
        "token(wanderlust.foundation.space.card)", sskSharedClass).ok
      vm.write()
      check foundation[] == DemoFoundationInitialSource.replace(before,
        " letter-spacing: token(wanderlust.foundation.space.card);")
      dispose()

  test "a project that defines no tokens refuses no design-token key":
    # Nothing says which keys exist, so none is refused for its name.
    var bare = demoDesignSystemSchema()
    var kept: seq[DesignSchemaNode]
    for node in bare.nodes:
      if node.kind notin {dsnFoundation, dsnSemanticToken, dsnComponentToken}:
        kept.add node
    bare.nodes = kept
    for value in ["token(no.such)", "$no.such"]:
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation, tokens = @[], schema = bare)
        let before = " letter-spacing: " & vm.value("letter-spacing") & ";"
        check vm.commitInspectorValue("letter-spacing", value, sskSharedClass).ok
        vm.write()
        check foundation[] == DemoFoundationInitialSource.replace(before,
          " letter-spacing: token(no.such);")
        dispose()

  test "a Foundations alias names a defined design token":
    # An alias to a key the project does not define would be written and
    # break the token and every use of it: refused at the edit with the
    # same reason a use site gets, and nothing is written.
    for (value, reason) in [("token(nope)", "Unknown design token 'nope'."),
        ("$nope", "Unknown design token 'nope'."),
        ("token()", "Token references must name a token."),
        ("$a b", "Token references must name a token.")]:
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation)
        checkpoint value
        let edit = vm.editFoundationToken("semantic.action.primary", value)
        check edit.status == pesRejected
        check edit.diagnostics.anyIt(it.message == reason)
        discard vm.applyWorkspaceFileEdits()
        check foundation[] == DemoFoundationInitialSource
        dispose()
    # A design-schema token key is a defined alias target too, with no
    # foundation token of that name.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.editFoundationToken("semantic.action.primary",
        "token(wanderlust.foundation.radius.card)").status == pesAccepted
      vm.write()
      check "--wl-action-primary: token(wanderlust.foundation.radius.card);" in
        foundation[]
      dispose()
    # An alias that closes a cycle is refused whatever the edited token's
    # kind: `semantic.action.primary` already aliases `color.blue.600`, a
    # palette colour.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      let edit = vm.editFoundationToken("color.blue.600",
        "token(semantic.action.primary)")
      check edit.status == pesRejected
      check edit.diagnostics.anyIt(it.kind == fedAliasCycle and
        it.message == "Token aliases cannot form a cycle.")
      discard vm.applyWorkspaceFileEdits()
      check foundation[] == DemoFoundationInitialSource
      dispose()
    # A longer cycle is seen through the whole chain, not only one hop:
    # space.card -> radius.card -> shadow.card, then shadow.card -> space.card.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.editFoundationToken("space.card", "token(radius.card)").status ==
        pesAccepted
      check vm.editFoundationToken("radius.card", "token(shadow.card)").status ==
        pesAccepted
      let closing = vm.editFoundationToken("shadow.card", "token(space.card)")
      check closing.status == pesRejected
      check closing.diagnostics.anyIt(it.kind == fedAliasCycle and
        it.message == "Token aliases cannot form a cycle.")
      var shadow = ""
      for token in vm.foundations.tokens.val:
        if token.key == "shadow.card": shadow = token.value
      check shadow == "0 12px 28px #0F172A"
      dispose()
    # An alias to a defined token is accepted and written.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource
      let vm = demoVm(foundation)
      check vm.editFoundationToken("semantic.action.primary",
        "token(type.body.size)").status == pesAccepted
      vm.write()
      check "--wl-action-primary: token(type.body.size);" in foundation[]
      dispose()

  test "a malformed reference is refused and nothing is written":
    for value in ["var(-a)", "var(--)", "var(--a b)", "VAR(--a;)", "vars(--a)"]:
      checkpoint value
      createRoot proc(dispose: proc()) =
        let foundation = new(string)
        foundation[] = DemoFoundationInitialSource
        let vm = demoVm(foundation)
        let committed = vm.commitInspectorValue("letter-spacing", value, sskSharedClass)
        check not committed.ok
        check vm.value("letter-spacing") == "0px"
        check vm.inspector.pendingSourceEdits.val.len == 0
        check foundation[] == DemoFoundationInitialSource
        dispose()

suite "colour and list values holding var() keep their case when written":
  ## Varspell review R1/R2: a colour holding var() was written in lower case,
  ## so `rgb(var(--Ink) 0 0)` named `--ink`, a different custom property
  ## (CSS Variables 1 §2; editor spec "Token names are case-sensitive").
  ## The example's `.long-tail-card` rule is given the colour, transition
  ## and family declarations these rows write (its shadow is its own), each mapped by a
  ## schema entry as the example maps its own; the production writer then
  ## writes them, and the file must hold exactly what was typed.
  const extra = [("color", "black"), ("outline-color", "black"),
    ("background-color", "white"), ("border-color", "black"),
    ("transition", "none"), ("font-family", "serif")]
  proc extendedSource(): string =
    var add = ""
    for (p, v) in extra: add.add " " & p & ": " & v & ";"
    const marker = " background-repeat: repeat; }\n"
    check marker in DemoFoundationInitialSource
    DemoFoundationInitialSource.replace(marker,
      " background-repeat: repeat;" & add & " }\n")
  proc extendedVm(foundation: ref string): EditorVM =
    let vector = new(string)
    vector[] = "<svg/>"
    var adapter = demoVectorEditAdapter(vector, foundation)
    let story = StoryRef(group: "DestinationCard", name: "Default",
      kind: skComponent, index: 0)
    for (p, _) in extra:
      adapter.schema.add WorkspaceEditableSchemaEntry(
        key: "classes.destination-card." & p, kind: wskSourceMap,
        file: DemoFoundationSource, path: "classes.long-tail-card." & p,
        story: story, property: p, removable: true, breakpointOverrides: true)
    result = createEditorVM(newEditorWorkspace(
      title = "Wanderlust colour fixture",
      storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
        expanded: true, items: @[StoryItem(name: "Default", kind: skComponent,
          group: "DestinationCard")])],
      initialStory = some(story),
      foundationTokens = demoFoundationTokens(),
      designSystemSchema = demoDesignSystemSchema(),
      permissions = EditorWorkspacePermissions(readSource: true, writeSource: true),
      editAdapter = adapter))
    var element = demoInspectorElement()
    # The example's own shadow declaration and schema entry, which the
    # preview capture reports once the card is selected.
    for (p, v) in DemoEffectValues:
      if p == "box-shadow":
        element.properties.add PropertyInfo(name: p, value: v,
          origin: poTailwindClass, originDetail: "class:long-tail-card",
          sourceFile: DemoFoundationSource, sourceLine: 10,
          schemaKey: "classes.destination-card." & p,
          sharedCount: 4, directStyleAllowed: true)
    for (p, v) in extra:
      element.properties.add PropertyInfo(name: p, value: v,
        origin: poTailwindClass, originDetail: "class:long-tail-card",
        sourceFile: DemoFoundationSource, sourceLine: 10,
        schemaKey: "classes.destination-card." & p,
        sharedCount: 4, directStyleAllowed: true)
    check result.selectInspectorElement(element)

  test "each value is written exactly as typed, and undo restores the file":
    for (property, value) in [("color", "rgb(var(--Ink) 0 0)"),
        ("color", "RGB(var(--Ink) 0 0)"), ("color", "VAR(--ink)"),
        ("outline-color", "rgb(var(--A) var(--B) var(--C))"),
        ("color", "hsl(var(--H) 50% 50%)"), ("background-color", "#ABCDEF var(--X)"),
        ("border-color", "rgb(VAR(--Ink) 0 0)"),
        ("box-shadow", "0 1px 2px VAR(--c)"), ("transition", "opacity VAR(--d)"),
        ("font-family", "VAR(--f), serif"), ("font-family", "VAR(--F),serif")]:
      checkpoint property & ": " & value
      createRoot proc(dispose: proc()) =
        let source = extendedSource()
        let foundation = new(string)
        foundation[] = source
        let vm = extendedVm(foundation)
        let before = " " & property & ": " & vm.value(property) & ";"
        check before in source
        let committed = vm.commitInspectorValue(property, value, sskSharedClass)
        check committed.ok
        check committed.message == ""
        vm.write()
        check foundation[] == source.replace(before, " " & property & ": " & value & ";")
        check vm.runEditorCommand(eckUndo).status == ecsSucceeded
        vm.write()
        check foundation[] == source
        dispose()

  test "a family list with var() only in a comment keeps its written form":
    createRoot proc(dispose: proc()) =
      let source = extendedSource()
      let foundation = new(string)
      foundation[] = source
      let vm = extendedVm(foundation)
      check vm.commitInspectorValue("font-family", "Inter,serif /* VAR(--x) */",
        sskSharedClass).ok
      vm.write()
      check foundation[] == source.replace(" font-family: serif;",
        " font-family: Inter, serif /* VAR(--x) */;")
      dispose()

  test "a colour without var() is still written in lower case":
    for (value, written) in [("#ABC", "#abc"), ("RGB(1, 2, 3)", "rgb(1, 2, 3)"),
        # A var() inside a comment is no reference (CSS Syntax 3 §4.3.2).
        ("#FFF /* var(--x) */", "#fff /* var(--x) */"),
        ("RGB(1, 2, 3) /* var(--A) */", "rgb(1, 2, 3) /* var(--a) */")]:
      createRoot proc(dispose: proc()) =
        let source = extendedSource()
        let foundation = new(string)
        foundation[] = source
        let vm = extendedVm(foundation)
        check vm.commitInspectorValue("color", value, sskSharedClass).ok
        vm.write()
        check foundation[] == source.replace(" color: black;", " color: " & written & ";")
        dispose()
