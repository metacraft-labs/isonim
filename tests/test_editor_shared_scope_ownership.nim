## Which shared source scope a property row offers, which one it commits at by
## default, and when its Reset is available, once a project declares an
## honest shared owner for a property captured off the preview.
##
## isonim-pm issue 2026-09-26-the-consumer-editor-spec-tests-the-inspector-
## that-was-demolished, section "The two shared-class cases after
## metacraft-web declared the Topbar owner": metacraft-web owns the Topbar's
## padding edges in its `.bo-topbar` rule (which declares no padding) and had
## to withhold that owner, because offering it
##
## 1. pre-selected the shared rule for every captured padding edit
##    (`defaultScopeIndex` accepted the capture's synthesized schema key),
## 2. offered the Topbar's rule on every other element's padding rows (the
##    first node with the same property was taken when no key matched), and
##    showed it enabled although the writer refuses it (`editRefusal` was
##    asked only at the commit),
## 3. and, on the reactive path, judged Reset's availability without the
##    writer's statement.
##
## Editor spec "Saving" (a scope the project cannot write is shown disabled
## with the reason and is never the default; Reset is enabled only where the
## write would succeed) and "Inspector UI for Shared Properties".
##
## The properties under test are built by the production preview capture
## (`previewDomElementRef`), so they carry exactly the origin detail and
## schema key the iframe bridge gives a consumer's elements; IsoNim's own
## editor example (`demo_workspace`) is the control for a captured value a
## shared rule does author.
##
## Mock justification: `ClassRuleProject` keeps two project files in memory
## and implements a shared-class writer the way the metacraft-web consumer's
## does (`patchClassRule` / `classRuleEditRefusal`), because IsoNim cannot
## depend on that consumer and this suite must also run under strict Node JS,
## which has no filesystem. It owns one top-level `.topbar { ... }` rule in
## `tokens.css` (set, append and remove one declaration; a removal with no
## declaration is refused) and appends `# isonim-editor` marker lines to
## `components.nim` for local edits, and its `editRefusal` states the reason
## the test configures. MockRenderer stands in for the browser DOM so the
## production property row runs natively and under strict Node JS; events are
## dispatched to the listeners the row registered. Everything else -- the capture, EditorVM, the scope
## choices, the row wiring, the commit, Reset's admission and the workspace
## write -- is production code. The real consumer writer, bridge and browser
## are exercised by the consumer cases `e2e_style_manager_scope_choices_
## update_real_preview`, `e2e_metacraft_shared_scope_save_reload_verify_and_
## revert` and `metacraft_property_reset_removes_the_declaration_and_undo_
## restores_it`.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/demo_workspace
import isonim/editor/views/choice_row
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/property_row

const ComponentFile = "components.nim"
const TokenFile = "tokens.css"
const ComponentOriginal = "proc topbar() = discard\n"
const TokenOriginal = ".topbar {\n  display: flex;\n}\n"
const TopbarKey = "dom.component-topbar"
const Refusal = "The .topbar rule is shared by a selector list."
const PanelKey = "dom.component-panel"

let topbarStory = StoryRef(group: "Operational components", name: "Topbar",
  kind: skComponent)

func ruleSpan(): SourceSpan =
  SourceSpan(file: TokenFile, line: 1, column: 1, endLine: 3, endColumn: 2)

func classNode(key, property: string; value = ""): DesignSchemaNode =
  ## A class-definition node keyed by the schema key of the element its rule
  ## styles, as metacraft-web keys `.bo-topbar`'s.
  DesignSchemaNode(key: key, kind: dsnClassDefinition, name: "topbar",
    component: "Topbar", property: property, value: value,
    sourceSpan: ruleSpan(), components: @["Topbar"], usageCount: 2)

proc captured(testId: string; computedStyles: string;
    sourceKey = ""): ElementRef =
  ## An element exactly as the preview's iframe bridge reports it: no style
  ## provenance, every property keyed `dom.<testid>.<property>`.
  previewDomElementRef(StoryRenderMetadata(story: topbarStory,
      sourceFile: ComponentFile, sourceLine: 1),
    tag = "header", testId = testId, className = "", role = "",
    elementPath = "", ancestry = "", sourceFile = ComponentFile,
    sourceLine = 1, display = "", position = "", backgroundColor = "",
    color = "", padding = "", margin = "", width = "", height = "",
    borderRadius = "", borderWidth = "", borderStyle = "", borderColor = "",
    fontSize = "", fontWeight = "", lineHeight = "", boxShadow = "",
    opacity = "", rectWidth = "", rectHeight = "", textContent = "",
    elementId = testId, sourceKey = sourceKey, schemaKey = "",
    ancestorIds = "", layerTreeJson = "", computedStyles = computedStyles)

proc property(element: ElementRef; name: string): PropertyInfo =
  for prop in element.properties:
    if prop.name == name:
      return prop

func choiceOf(choices: seq[SourceScopeChoice];
    kind: SourceScopeChoiceKind): SourceScopeChoice =
  for choice in choices:
    if choice.kind == kind:
      return choice

# --------------------------------------------------------------------------- #
#  The in-memory class-rule project (see the module comment).
# --------------------------------------------------------------------------- #

type ClassRuleProject = ref object
  files: Table[string, string]
  refusal: string
    ## What `editRefusal` says about a shared-class plan; "" accepts it.
  refusalAsked: int

func ruleDeclarationLine(lines: seq[string]; property: string): int =
  result = -1
  for i, line in lines:
    if line.strip().startsWith(property & ":"):
      return i

proc classRuleAdapter(project: ClassRuleProject): WorkspaceEditAdapter =
  result = WorkspaceEditAdapter(bridgeLabel: "in-memory class-rule writer",
    allowMissingExpectedOldValue: true,
    schema: @[
      WorkspaceEditableSchemaEntry(key: "fixture.components",
        kind: wskSourceMap, file: ComponentFile, path: "components",
        property: "", removable: true)])
  for property in ["display", "padding-top"]:
    result.schema.add WorkspaceEditableSchemaEntry(
      key: "fixture.classRules." & property, kind: wskSourceMap,
      file: TokenFile, path: "topbar." & property, property: property,
      removable: true)
  result.readFile = proc(file: string): WorkspaceReadResult =
    WorkspaceReadResult(ok: file in project.files,
      content: project.files.getOrDefault(file))
  result.writeFile = proc(file, content: string): WorkspaceOperationResult =
    project.files[file] = content
    WorkspaceOperationResult(ok: true)
  result.patchFile = proc(plan: SourceEditPlan; content: string;
      schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
    proc refused(message: string): WorkspacePatchResult =
      WorkspacePatchResult(ok: false, diagnostics: @[WorkspaceEditDiagnostic(
        kind: wedPatchFailed, message: message, file: schema.file,
        property: plan.property)])
    if schema.file == TokenFile:
      var lines = content.split('\n')
      let found = lines.ruleDeclarationLine(plan.property)
      if plan.planKind == cspPropertyRemoval:
        if found < 0:
          return refused("the .topbar rule has no " & plan.property &
            " declaration to remove.")
        lines.delete(found)
      elif found >= 0:
        lines[found] = "  " & plan.property & ": " & plan.newValue & ";"
      else:
        lines.insert("  " & plan.property & ": " & plan.newValue & ";",
          lines.find("}"))
      return WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
        file: TokenFile, beforeContent: content,
        afterContent: lines.join("\n")))
    let marker = "# isonim-editor " & plan.schemaKey & " " & plan.property &
      "=" & plan.newValue
    if plan.planKind == cspPropertyRemoval:
      var kept: seq[string]
      var removed = 0
      for line in content.splitLines():
        if line.startsWith("# isonim-editor " & plan.schemaKey & " "):
          inc removed
        else:
          kept.add line
      if removed != 1:
        return refused("no editor declaration of " & plan.property & ".")
      return WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
        file: ComponentFile, beforeContent: content,
        afterContent: kept.join("\n")))
    WorkspacePatchResult(ok: true, patch: WorkspaceFilePatch(
      file: ComponentFile, beforeContent: content,
      afterContent: content.strip(leading = false) & "\n" & marker & "\n"))
  result.editRefusal = proc(plan: SourceEditPlan;
      schema: WorkspaceEditableSchemaEntry): string =
    if schema.file != TokenFile:
      return ""
    inc project.refusalAsked
    project.refusal

proc newEditor(project: ClassRuleProject; schema: DesignSystemSchema;
    element: ElementRef): EditorVM =
  project.files[ComponentFile] = ComponentOriginal
  project.files[TokenFile] = TokenOriginal
  result = createEditorVM(newEditorWorkspace(
    title = "shared-scope ownership",
    storyGroups = @[StoryGroup(name: topbarStory.group,
      kind: topbarStory.kind, expanded: true, items: @[StoryItem(
        name: topbarStory.name, kind: topbarStory.kind,
        group: topbarStory.group)])],
    designSystemSchema = schema,
    permissions = EditorWorkspacePermissions(readSource: true,
      writeSource: true),
    editAdapter = classRuleAdapter(project),
    initialStory = some(topbarStory)))
  check result.selectInspectorElement(element)

func topbarSchema(nodes: varargs[DesignSchemaNode]): DesignSystemSchema =
  DesignSystemSchema(schemaVersion: 1, projectId: "shared-scope-ownership",
    ownerPackage: "fixture", nodes: @nodes)

let topbar = captured("component-topbar", "padding-top=0px;display=flex")

suite "A captured value defaults to the scope that authors it":
  test "the capture keys every property by element, with no provenance":
    ## The premise of the defect: a schema key on a captured property names
    ## the element, not an owner.
    let padding = topbar.property("padding-top")
    check padding.schemaKey == TopbarKey & ".padding-top"
    check padding.originDetail.capturedWithoutProvenance
    check padding.sharedCount == 0 and padding.tokenName == ""

  test "an offered shared owner that declares none of the value is not the default":
    let schema = topbarSchema(classNode(TopbarKey, "padding-top"))
    let padding = topbar.property("padding-top")
    let choices = sourceScopeChoices(schema, topbar, padding)
    let shared = choices.choiceOf(sskSharedClass)
    # The Topbar's own rule is offered and writable...
    check shared.editable and shared.schemaKey == TopbarKey
    check not shared.authorsValue
    # ...but the captured value is the element's until the user chooses it.
    check choices[defaultScopeIndex(choices, padding)].kind == sskLocalInstance

  test "the row commits a captured, unauthored value locally by default":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "padding-top")), topbar)
      let wiring = vm.inspectorRowWiring("padding-top")
      check wiring.selectedSourceScope().get.kind == sskLocalInstance
      check vm.sourceScopeChoices(topbar.property("padding-top")).choiceOf(
        sskSharedClass).editable
      wiring.commit("20px")
      check wiring.commitMessage.val == ""
      check vm.applyWorkspaceFileEdits().ok
      check project.files[ComponentFile] == ComponentOriginal &
        "# isonim-editor " & TopbarKey & ".padding-top padding-top=20px\n"
      check project.files[TokenFile] == TokenOriginal
      dispose()

  test "a shared owner that declares the value is the default":
    let schema = topbarSchema(classNode(TopbarKey, "display", "flex"))
    let display = topbar.property("display")
    let choices = sourceScopeChoices(schema, topbar, display)
    check choices.choiceOf(sskSharedClass).authorsValue
    check choices[defaultScopeIndex(choices, display)].kind == sskSharedClass

  test "the editor example's captured card padding stays a shared-class edit":
    ## IsoNim's own example keys its card `classes.destination-card`, so the
    ## captured padding's schema key is the class node's key: the rule
    ## authors it, and the shared default must survive.
    let card = previewDomElementRef(StoryRenderMetadata(story: StoryRef(
        group: "DestinationCard", name: "Default", kind: skComponent),
        sourceFile: DemoFoundationSource, sourceLine: 9),
      tag = "article", testId = "component-edit-preview",
      className = "destination-card long-tail-card", role = "",
      elementPath = "", ancestry = "", sourceFile = DemoFoundationSource,
      sourceLine = 9, display = "", position = "", backgroundColor = "",
      color = "", padding = "18px", margin = "", width = "", height = "",
      borderRadius = "", borderWidth = "", borderStyle = "",
      borderColor = "", fontSize = "", fontWeight = "", lineHeight = "",
      boxShadow = "", opacity = "", rectWidth = "", rectHeight = "",
      textContent = "", elementId = "card", sourceKey = "",
      schemaKey = "classes.destination-card", ancestorIds = "",
      layerTreeJson = "")
    let padding = card.property("padding")
    check padding.originDetail.capturedWithoutProvenance
    let choices = sourceScopeChoices(demoDesignSystemSchema(), card, padding)
    let shared = choices.choiceOf(sskSharedClass)
    check shared.schemaKey == "classes.destination-card.padding"
    check shared.authorsValue
    check choices[defaultScopeIndex(choices, padding)].kind == sskSharedClass

  test "provenance that names a shared origin still defaults to it":
    var classed = topbar.property("padding-top")
    classed.origin = poTailwindClass
    classed.originDetail = "class:topbar"
    classed.sharedCount = 2
    let choices = sourceScopeChoices(
      topbarSchema(classNode(TopbarKey, "padding-top")), topbar, classed)
    check choices[defaultScopeIndex(choices, classed)].kind == sskSharedClass

suite "A shared scope is offered only by the element's own owner":
  test "another element's rule is not offered for the same property":
    let panel = captured("component-panel", "padding-top=16px")
    let schema = topbarSchema(classNode(TopbarKey, "padding-top"))
    let shared = sourceScopeChoices(schema, panel,
      panel.property("padding-top")).choiceOf(sskSharedClass)
    check shared.schemaKey == ""
    check not shared.editable
    check shared.reason ==
      "No project schema owner is currently mapped for this scope."
    # The Topbar itself still gets its rule.
    check sourceScopeChoices(schema, topbar, topbar.property(
      "padding-top")).choiceOf(sskSharedClass).schemaKey == TopbarKey

  test "a source-ownership edge maps an element to a node keyed otherwise":
    let panel = captured("component-panel", "padding-top=16px",
      sourceKey = "panel.source")
    var schema = topbarSchema(classNode("classes.panel.padding-top",
      "padding-top", "16px"))
    schema.sourceOwnership = @[DesignSourceOwnership(
      elementSourceKey: "panel.source", property: "padding-top",
      nodeKey: "classes.panel.padding-top")]
    let shared = sourceScopeChoices(schema, panel,
      panel.property("padding-top")).choiceOf(sskSharedClass)
    check shared.schemaKey == "classes.panel.padding-top"
    check shared.editable and shared.authorsValue
    # The edge names the panel's source key; the Topbar is not the panel.
    check sourceScopeChoices(schema, topbar, topbar.property(
      "padding-top")).choiceOf(sskSharedClass).schemaKey == ""

  test "edges that disagree about the owner offer neither":
    let panel = captured("component-panel", "padding-top=16px",
      sourceKey = "panel.source")
    var schema = topbarSchema(classNode("classes.a", "padding-top"),
      classNode("classes.b", "padding-top"))
    schema.sourceOwnership = @[
      DesignSourceOwnership(elementSourceKey: "panel.source",
        property: "padding-top", nodeKey: "classes.a"),
      DesignSourceOwnership(elementSourceKey: "panel.source",
        property: "padding-top", nodeKey: "classes.b")]
    let shared = sourceScopeChoices(schema, panel,
      panel.property("padding-top")).choiceOf(sskSharedClass)
    check not shared.editable and shared.schemaKey == ""
    check shared.reason.startsWith("Multiple Shared class owners")

  test "a DOM-path edge the element's path cannot confirm offers nothing":
    ## The writer's predicate accepts a path-scoped edge for an element with
    ## no DOM path without checking it; that is not evidence the edge names
    ## this element (`designSourceOwnershipIsAmbiguous`).
    var schema = topbarSchema(classNode("classes.panel.padding-top",
      "padding-top", "16px"))
    schema.sourceOwnership = @[DesignSourceOwnership(
      domPath: "main > section.bo-panel", property: "padding-top",
      nodeKey: "classes.panel.padding-top")]
    check topbar.domPath == ""
    let shared = sourceScopeChoices(schema, topbar,
      topbar.property("padding-top")).choiceOf(sskSharedClass)
    check not shared.editable and shared.schemaKey == ""
    check shared.reason.startsWith("Multiple Shared class owners")
    # With a path to check, the edge is honoured where it matches and
    # ignored where it does not.
    var located = topbar
    located.domPath = "main > section.bo-panel"
    check sourceScopeChoices(schema, located, located.property(
      "padding-top")).choiceOf(sskSharedClass).schemaKey ==
      "classes.panel.padding-top"
    located.domPath = "main > header.bo-topbar"
    check sourceScopeChoices(schema, located, located.property(
      "padding-top")).choiceOf(sskSharedClass).reason ==
      "No project schema owner is currently mapped for this scope."

  test "the owner component's chain names one node per scope, or none":
    ## A component token is offered at its scope only as the one member of
    ## the owner component's chain there; two candidates are not resolved by
    ## list order.
    func token(key: string; component = "Topbar"): DesignSchemaNode =
      DesignSchemaNode(key: key, kind: dsnComponentToken, name: key,
        component: component, property: "padding-top", value: "8px",
        sourceSpan: SourceSpan(file: TokenFile, line: 5),
        components: @[component], usageCount: 1)
    let padding = topbar.property("padding-top")
    let single = sourceScopeChoices(topbarSchema(
      classNode(TopbarKey, "padding-top"), token("topbar.padding"),
      token("panel.padding", "Panel")), topbar, padding).choiceOf(
      sskComponentToken)
    check single.schemaKey == "topbar.padding"
    check single.editable and not single.authorsValue
    let two = sourceScopeChoices(topbarSchema(
      classNode(TopbarKey, "padding-top"), token("topbar.padding"),
      token("topbar.padding.compact")), topbar, padding).choiceOf(
      sskComponentToken)
    check not two.editable and two.schemaKey == ""
    check two.reason.startsWith("Multiple Component token owners")
    # No identified owner, no chain: the Panel's token is not the Topbar's.
    check sourceScopeChoices(topbarSchema(token("panel.padding", "Panel")),
      topbar, padding).choiceOf(sskComponentToken).schemaKey == ""

suite "A scope the writer refuses is shown disabled with the writer's reason":

  test "the chip is disabled, carries the reason and is never the default":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject(refusal: Refusal)
      # The rule declares display, so without the refusal it would be the
      # default scope.
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "display", "flex")), topbar)
      let shared = vm.sourceScopeChoices(topbar.property("display")).choiceOf(
        sskSharedClass)
      check not shared.editable
      check shared.reason == Refusal
      check project.refusalAsked > 0
      let wiring = vm.inspectorRowWiring("display")
      check wiring.selectedSourceScope().get.kind == sskLocalInstance
      var chip = CompactChoiceOption()
      for option in wiring.scopeOptions():
        if option.ariaLabel == "Apply shared class scope for display":
          chip = option
      check not chip.enabled
      check ("title", Refusal) in chip.dataAttrs or
        ("data-source-scope-reason", Refusal) in chip.dataAttrs
      # Choosing it anyway changes nothing.
      let outcome = vm.commitInspectorValue("display", "grid", sskSharedClass)
      check not outcome.ok
      check Refusal in outcome.message
      check vm.inspector.pendingSourceEdits.val.len == 0
      check project.files[TokenFile] == TokenOriginal
      dispose()

  test "a writer that accepts the plan leaves the chip enabled":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "display", "flex")), topbar)
      check vm.sourceScopeChoices(topbar.property("display")).choiceOf(
        sskSharedClass).editable
      check vm.inspectorRowWiring("display").selectedSourceScope().get.kind ==
        sskSharedClass
      dispose()

suite "Reset at a shared scope asks the writer":
  test "a rule with no declaration of the property cannot be Reset there":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "padding-top")), topbar)
      check vm.propertyResetRefusal("padding-top", sskSharedClass) ==
        "the .topbar rule has no padding-top declaration to remove."
      # Locally there is no editor declaration either.
      check vm.propertyResetRefusal("padding-top", sskLocalInstance) ==
        "no editor declaration of padding-top."
      # Once the rule declares it, the shared Reset is available and removes
      # exactly that line.
      project.files[TokenFile] = ".topbar {\n  display: flex;\n" &
        "  padding-top: 28px;\n}\n"
      check vm.propertyResetRefusal("padding-top", sskSharedClass) == ""
      check vm.editSharedDesignProperty("padding-top", "",
        sskSharedClass).status == pesAccepted
      check vm.applyWorkspaceFileEdits().ok
      check project.files[TokenFile] == TokenOriginal
      dispose()

  test "the reactive Reset availability includes the writer's statement":
    ## `checkWrite = false` (a Fill entry's Delete, shown reactively) skips
    ## only the file read, not the writer's refusal.
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "padding-top", "28px")), topbar)
      project.files[TokenFile] = ".topbar {\n  display: flex;\n" &
        "  padding-top: 28px;\n}\n"
      check vm.propertyResetRefusal("padding-top", sskSharedClass,
        checkWrite = false) == ""
      check vm.propertyResetRefusal("padding-top", sskSharedClass) == ""
      project.refusal = Refusal
      check vm.propertyResetRefusal("padding-top", sskSharedClass,
        checkWrite = false) == Refusal
      check vm.propertyResetRefusal("padding-top", sskSharedClass) == Refusal
      dispose()

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

suite "Detach gives the element an inline override of the shared value":
  ## Editor spec "Inspector UI for Shared Properties" ("[Detach]") and "Edit
  ## Routing -- Detach from token".
  test "Detach is offered by name at a shared scope and commits locally":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "padding-top")), topbar)
      let wiring = vm.inspectorRowWiring("padding-top")
      let r = MockRenderer()
      let host = r.createElement("div")
      let row = r.mountPropertyRow(host, propertyRowText("Top",
        createSignal("0px"), wiring = wiring))
      let detach = row.findByAttr("data-property-row-detach", "true")
      check detach != nil
      if detach == nil:
        dispose()
        return
      # Local by default: nothing to detach from.
      check detach.styles.getOrDefault("display") == "none"
      let sharedChip = row.findByAttr("aria-label",
        "Apply shared class scope for padding-top")
      check sharedChip != nil
      sharedChip.fireEvent("click")
      check wiring.selectedSourceScope().get.kind == sskSharedClass
      check detach.styles.getOrDefault("display") == "inline-flex"
      check detach.attributes.getOrDefault("aria-label") ==
        "Detach padding-top from shared class"
      check vm.applyWorkspaceFileEdits().ok
      check project.files[TokenFile] == ".topbar {\n  display: flex;\n" &
        "  padding-top: 0px;\n}\n"
      # Detach: back to the local instance, carrying the current value as
      # this element's own declaration; the shared rule is untouched.
      detach.fireEventWith("keydown", MockEvent(`type`: "keydown",
        target: detach, currentTarget: detach, key: "Enter"))
      check wiring.selectedSourceScope().get.kind == sskLocalInstance
      check detach.styles.getOrDefault("display") == "none"
      check vm.applyWorkspaceFileEdits().ok
      check project.files[ComponentFile] == ComponentOriginal &
        "# isonim-editor " & TopbarKey & ".padding-top padding-top=0px\n"
      check project.files[TokenFile] == ".topbar {\n  display: flex;\n" &
        "  padding-top: 0px;\n}\n"
      dispose()

  test "Detach is not offered when the local instance cannot be written":
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      var element = topbar
      for prop in element.properties.mitems:
        if prop.name == "display":
          prop.directStyleAllowed = false
      element.sourceFile = ""
      element.sourceLine = 0
      for prop in element.properties.mitems:
        prop.sourceFile = ""
        prop.sourceLine = 0
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "display", "flex")), element)
      check not vm.sourceScopeChoices(element.property("display")).choiceOf(
        sskLocalInstance).editable
      let wiring = vm.inspectorRowWiring("display")
      check wiring.selectedSourceScope().get.kind == sskSharedClass
      let r = MockRenderer()
      let row = r.mountPropertyRow(r.createElement("div"), propertyRowText(
        "Display", createSignal("flex"), wiring = wiring))
      let detach = row.findByAttr("data-property-row-detach", "true")
      check detach != nil and detach.styles.getOrDefault("display") == "none"
      dispose()

  test "repeated scope choices on a mounted row re-commit each time":
    ## Each choice re-renders the strip and re-commits the row's value at
    ## the chosen scope. (An intermediate version of this change, which
    ## also rewrote the property's origin on a shared edit, made this
    ## sequence read freed memory under ORC; see isonim-pm issue
    ## 2026-10-22-a-compact-choice-callback-can-free-its-own-environment.)
    createRoot proc(dispose: proc()) =
      let project = ClassRuleProject()
      let vm = newEditor(project,
        topbarSchema(classNode(TopbarKey, "padding-top")), topbar)
      let wiring = vm.inspectorRowWiring("padding-top")
      let r = MockRenderer()
      let row = r.mountPropertyRow(r.createElement("div"), propertyRowText(
        "Top", createSignal("0px"), wiring = wiring))
      for round in 0 ..< 3:
        row.findByAttr("aria-label",
          "Apply shared class scope for padding-top").fireEvent("click")
        check wiring.selectedSourceScope().get.kind == sskSharedClass
        row.findByAttr("aria-label",
          "Apply local instance scope for padding-top").fireEvent("click")
        check wiring.selectedSourceScope().get.kind == sskLocalInstance
      check wiring.commitMessage.val == ""
      check vm.inspector.undoStack.val.len == 6
      # Detach runs the local chip's callback from the row's own slot; the
      # choice re-renders the strip and hides Detach while it runs.
      let detach = row.findByAttr("data-property-row-detach", "true")
      for round in 0 ..< 3:
        row.findByAttr("aria-label",
          "Apply shared class scope for padding-top").fireEvent("click")
        check detach.styles.getOrDefault("display") == "inline-flex"
        detach.fireEvent("click")
        check wiring.selectedSourceScope().get.kind == sskLocalInstance
        check detach.styles.getOrDefault("display") == "none"
      check wiring.commitMessage.val == ""
      check vm.inspector.undoStack.val.len == 12
      dispose()

suite "Reset's reactive availability asks the writer at the local scope too":
  test "the editor example's selector-list rule disables a local Reset":
    ## IsoNim's own example: its writer refuses a rule shared by a selector
    ## list (`demoVectorEditAdapter.editRefusal`), and the card's local plan
    ## resolves to that rule. The reactive availability (`checkWrite =
    ## false`) must say so, as the full check does.
    createRoot proc(dispose: proc()) =
      let foundation = new(string)
      foundation[] = DemoFoundationInitialSource.replace(
        ".destination-card { padding: 18px; }\n",
        ".destination-card, .hero { padding: 18px; }\n")
      let vm = createEditorVM(newEditorWorkspace(
        title = "Wanderlust selector-list fixture",
        storyGroups = @[StoryGroup(name: "DestinationCard", kind: skComponent,
          expanded: true, items: @[StoryItem(name: "Default",
            kind: skComponent, group: "DestinationCard")])],
        initialStory = some(StoryRef(group: "DestinationCard",
          name: "Default", kind: skComponent, index: 0)),
        foundationTokens = demoFoundationTokens(),
        designSystemSchema = demoDesignSystemSchema(),
        permissions = EditorWorkspacePermissions(readSource: true,
          writeSource: true),
        editAdapter = demoVectorEditAdapter(new(string), foundation)))
      check vm.selectInspectorElement(demoInspectorElement())
      let full = vm.propertyResetRefusal("padding", sskLocalInstance)
      check "shared by the selector list" in full
      check vm.propertyResetRefusal("padding", sskLocalInstance,
        checkWrite = false) == full
      dispose()
