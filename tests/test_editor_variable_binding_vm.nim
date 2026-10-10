## Phase E.1 — Design system variable binding VM data model.
##
## Pure VM-layer tests for the bindings introduced by Phase E.1 of
## the IsoNim editor sidebar redesign:
##
## * ``EditorVM.bindPropertyToVariable``
## * ``EditorVM.detachPropertyBinding``
## * ``EditorVM.propertyBindingFor``
## * ``EditorVM.resolveVariableValue``
## * ``EditorVM.usageCountFor``
## * ``variableCategoryFor``
## * ``InspectorVM.availableVariables`` Memo
##
## The appended Save coordination test deliberately defers the consumer's
## metadata completion callback to prove running/refusal sequencing. This one
## callback is an admission spy, not simulated durable metadata success: its
## success phase writes an actual sidecar and uses the production CSS patcher,
## actual files and Nim compiler for the staged source draft. Production browser
## tests separately prove authenticated sidecar admission, picker and reload.
## No UI here. The picker chip (E.2), picker popover (E.3), and
## inline variable editor (E.4) live in later phases; they consume
## the data model exercised below.

import std/[options, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/editor/viewmodels
when not defined(js):
  import std/[os, osproc, strutils, tempfiles]
  import isonim/editor/css_patch

suite "Editor variable binding VM (Phase E.1)":

  test "bindPropertyToVariable records binding under the correct key":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A", sourceFile: "foundations/colour.nim",
          sourceLine: 12)]

      let key = PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color")
      vm.bindPropertyToVariable(key, "color/surface")

      let bindings = vm.inspector.propertyBindings.val
      check bindings.len == 1
      check bindings.hasKey(key)
      check bindings[key].variableKey == "color/surface"
      check bindings[key].state == vbsBound
      check bindings[key].resolvedValue == "#0F172A"
      check bindings[key].sourceFileRef == "foundations/colour.nim"
      check bindings[key].sourceLineRef == 12
      dispose()

  test "bindPropertyToVariable overwrites an existing binding":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A"),
        FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
          value: "#7C7AED")]

      let key = PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color")
      vm.bindPropertyToVariable(key, "color/surface")
      vm.bindPropertyToVariable(key, "color/accent")

      let bindings = vm.inspector.propertyBindings.val
      check bindings.len == 1
      check bindings[key].variableKey == "color/accent"
      check bindings[key].resolvedValue == "#7C7AED"
      dispose()

  test "detachPropertyBinding removes the binding":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px")]

      let key = PropertyBindingKey(
        elementId: "row-1", propertyName: "gap")
      vm.bindPropertyToVariable(key, "spacing/4")
      check vm.inspector.propertyBindings.val.hasKey(key)

      vm.detachPropertyBinding(key, "16px")
      check vm.inspector.propertyBindings.val.len == 0
      check (not vm.inspector.propertyBindings.val.hasKey(key))
      dispose()

  test "propertyBindingFor returns none for unbound properties":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let key = PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color")

      check vm.propertyBindingFor(key).isNone

      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A")]
      vm.bindPropertyToVariable(key, "color/surface")
      let bound = vm.propertyBindingFor(key)
      check bound.isSome
      check bound.get().variableKey == "color/surface"

      let otherKey = PropertyBindingKey(
        elementId: "frame-2", propertyName: "background-color")
      check vm.propertyBindingFor(otherKey).isNone
      dispose()

  test "inspectorBindingFor keys off the current selection (VBIND-M1)":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A")]
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1")

      # Default: no binding, no selection dependence — returns none.
      check vm.inspectorBindingFor("background-color").isNone

      vm.bindPropertyToVariable(PropertyBindingKey(
        elementId: "frame-1", propertyName: "background-color"),
        "color/surface")
      let bound = vm.inspectorBindingFor("background-color")
      check bound.isSome
      check bound.get().variableKey == "color/surface"

      # A different property is still unbound.
      check vm.inspectorBindingFor("gap").isNone
      # An empty property name is a no-op.
      check vm.inspectorBindingFor("").isNone

      # The binding is scoped to the selected element only.
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-9")
      check vm.inspectorBindingFor("background-color").isNone
      dispose()

  test "resolveVariableValue returns foundations value or empty for missing":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A"),
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px")]

      check vm.resolveVariableValue("color/surface") == "#0F172A"
      check vm.resolveVariableValue("spacing/4") == "16px"
      check vm.resolveVariableValue("does/not/exist") == ""
      check vm.resolveVariableValue("") == ""
      dispose()

  test "usageCountFor returns non-negative count from foundations.tokens":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A",
          affectedStories: @[
            StoryRef(group: "TaskRow", name: "Active", kind: skComponent),
            StoryRef(group: "TaskRow", name: "Done", kind: skComponent),
            StoryRef(group: "Home", name: "Default", kind: skPage)]),
        FoundationTokenEntry(key: "spacing/0", kind: ftkSpacingScale,
          value: "0px",
          affectedStories: @[])]

      check vm.usageCountFor("color/surface") == 3
      check vm.usageCountFor("spacing/0") == 0
      check vm.usageCountFor("does/not/exist") == 0
      check vm.usageCountFor("") == 0
      check vm.usageCountFor("color/surface") >= 0
      dispose()

  test "variableCategoryFor maps sample token kinds correctly":
    check variableCategoryFor(FoundationTokenEntry(kind: ftkColorPalette)) ==
        vpcColour
    check variableCategoryFor(FoundationTokenEntry(kind: ftkSemanticColor)) ==
        vpcColour
    check variableCategoryFor(FoundationTokenEntry(kind: ftkSpacingScale)) ==
        vpcSpacing
    check variableCategoryFor(FoundationTokenEntry(kind: ftkTypographyScale)) ==
        vpcTypography
    check variableCategoryFor(FoundationTokenEntry(kind: ftkRadiusScale)) ==
        vpcRadius
    check variableCategoryFor(FoundationTokenEntry(kind: ftkShadow)) ==
        vpcEffect
    check variableCategoryFor(FoundationTokenEntry(kind: ftkMotion)) ==
        vpcEffect
    check variableCategoryFor(FoundationTokenEntry(kind: ftkBreakpoint)) ==
        vpcNumber
    check variableCategoryFor(FoundationTokenEntry(
        kind: ftkAccessibilityConstraint)) == vpcString

  test "availableVariables Memo reflects updates to foundations.tokens":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.inspector.availableVariables.val.len == 0

      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A")]
      check vm.inspector.availableVariables.val.len == 1
      check vm.inspector.availableVariables.val[0].key == "color/surface"

      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
          value: "#0F172A"),
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px"),
        FoundationTokenEntry(key: "radius/sm", kind: ftkRadiusScale,
          value: "4px")]
      check vm.inspector.availableVariables.val.len == 3
      check vm.inspector.availableVariables.val[1].key == "spacing/4"
      check vm.inspector.availableVariables.val[2].key == "radius/sm"

      vm.foundations.tokens.val = @[]
      check vm.inspector.availableVariables.val.len == 0
      dispose()

suite "Editor variable binding VM (VBIND-M3 unlink → local override)":

  test "detachPropertyBinding journals the resolved value as a local literal":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px", sourceFile: "foundations/spacing.nim",
          sourceLine: 7)]
      # Selection owns the property being bound, with a real source
      # anchor so the detach can journal a local literal override.
      vm.inspector.selectedElement.val = ElementRef(
        tag: "div", id: "row-1",
        sourceFile: "components/Row.nim", sourceLine: 42,
        properties: @[PropertyInfo(name: "gap", value: "8px",
          origin: poInherited, sourceFile: "components/Row.nim",
          sourceLine: 42, directStyleAllowed: true)])

      let key = PropertyBindingKey(elementId: "row-1", propertyName: "gap")
      vm.bindPropertyToVariable(key, "spacing/4")
      check vm.inspector.propertyBindings.val.hasKey(key)
      check vm.inspector.pendingSourceEdits.val.len == 0

      # Detach with the binding's currently-resolved value.
      vm.detachPropertyBinding(key, "16px")

      # (a) the binding is gone.
      check vm.inspector.propertyBindings.val.len == 0
      check (not vm.inspector.propertyBindings.val.hasKey(key))
      # (b) a local literal edit for gap = 16px is journaled.
      let edits = vm.inspector.pendingSourceEdits.val
      check edits.len == 1
      check edits[0].property == "gap"
      check edits[0].newValue == "16px"
      check edits[0].scope == pesLocal
      # (c) the selected element now carries the literal override, so the
      # row re-renders the editable literal control seeded with 16px.
      check vm.propertyBindingFor(key).isNone
      var gapLiteral = ""
      for p in vm.inspector.selectedElement.val.properties:
        if p.name == "gap": gapLiteral = p.value
      check gapLiteral == "16px"
      dispose()

  test "detachPropertyBinding to empty removes the binding without journaling":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px")]
      vm.inspector.selectedElement.val = ElementRef(
        tag: "div", id: "row-1",
        sourceFile: "components/Row.nim", sourceLine: 42,
        properties: @[PropertyInfo(name: "gap", value: "8px",
          origin: poInherited, sourceFile: "components/Row.nim",
          sourceLine: 42, directStyleAllowed: true)])

      let key = PropertyBindingKey(elementId: "row-1", propertyName: "gap")
      vm.bindPropertyToVariable(key, "spacing/4")
      check vm.inspector.propertyBindings.val.hasKey(key)

      # "Detach to empty" — no literal override staged.
      vm.detachPropertyBinding(key, "")
      check vm.inspector.propertyBindings.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "detachPropertyBinding off-selection removes binding, does not mis-journal":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px")]
      # Nothing selected — a detach for an off-screen element must not
      # journal an edit against the (empty) selection.
      let key = PropertyBindingKey(elementId: "row-9", propertyName: "gap")
      vm.bindPropertyToVariable(key, "spacing/4")
      vm.detachPropertyBinding(key, "16px")
      check vm.inspector.propertyBindings.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "detach then a further literal edit keeps the property unbound":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
          value: "16px")]
      vm.inspector.selectedElement.val = ElementRef(
        tag: "div", id: "row-1",
        sourceFile: "components/Row.nim", sourceLine: 42,
        properties: @[PropertyInfo(name: "gap", value: "8px",
          origin: poInherited, sourceFile: "components/Row.nim",
          sourceLine: 42, directStyleAllowed: true)])

      let key = PropertyBindingKey(elementId: "row-1", propertyName: "gap")
      vm.bindPropertyToVariable(key, "spacing/4")
      vm.detachPropertyBinding(key, "16px")

      # A subsequent local literal edit (the same channel the sections use)
      # keeps the property unbound and updates only this element.
      discard vm.editCssProperty("gap", "24px", scope = pesLocal)
      check vm.propertyBindingFor(key).isNone
      var gapLiteral = ""
      for p in vm.inspector.selectedElement.val.properties:
        if p.name == "gap": gapLiteral = p.value
      check gapLiteral == "24px"
      let edits = vm.inspector.pendingSourceEdits.val
      check edits.len >= 1
      check edits[^1].property == "gap"
      check edits[^1].newValue == "24px"
      dispose()

when not defined(js):
  suite "binding metadata Save coordinates real source drafts":
    test "Save stays running until metadata completes; refusal preserves draft and retry writes real source":
      let directory = createTempDir("binding_save_", "_source")
      defer: removeDir(directory)
      let source = directory / "styles.nim"
      let original = "const styles* = \"\"\"#action { width:120px; }\"\"\"\necho styles\n"
      writeFile(source, original)
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.workspacePermissions.val = EditorWorkspacePermissions(readSource: true, writeSource: true)
        vm.sourceAdapterReady.val = true
        vm.selectedStory.val = StoryRef(group: "Card", name: "ready", kind: skComponent)
        vm.inspector.selectedElement.val = ElementRef(id: "action", tag: "button", sourceFile: source,
          properties: @[PropertyInfo(name: "width", value: "120px", schemaKey: "style.width", sourceFile: source, directStyleAllowed: true)])
        vm.inspector.journalSourceEdit(SourceEditPlan(file: source, schemaKey: "style.width", property: "width",
          oldValue: "120px", expectedOldValue: "120px", newValue: "240px", scope: pesLocal,
          sourceScope: sskLocalInstance, reversible: true))
        let adapter = WorkspaceEditAdapter(schema: @[WorkspaceEditableSchemaEntry(key: "style.width", file: source, kind: wskSourceMap, property: "width")])
        adapter.readFile = proc(file: string): WorkspaceReadResult =
          WorkspaceReadResult(ok: true, content: readFile(file))
        adapter.writeFile = proc(file, content: string): WorkspaceOperationResult =
          writeFile(file, content)
          WorkspaceOperationResult(ok: true)
        adapter.patchFile = proc(plan: SourceEditPlan; content: string; schema: WorkspaceEditableSchemaEntry): WorkspacePatchResult =
          let patch = patchCssInNimConst(content, "styles", "#action", plan.property, plan.newValue)
          WorkspacePatchResult(ok: patch.ok, patch: WorkspaceFilePatch(file: schema.file, afterContent: patch.content, fullReload: true))
        let binary = directory / "compiled"
        adapter.compile = proc(stories: seq[StoryRef]): WorkspaceOperationResult =
          let built = execCmdEx(@["nim", "c", "--hints:off", "--nimcache:" & directory / "cache", "--out:" & binary, source].quoteShellCommand())
          WorkspaceOperationResult(ok: built.exitCode == 0, message: built.output)
        adapter.reloadPreview = proc(stories: seq[StoryRef]; fullReload: bool): WorkspaceOperationResult =
          let rendered = execCmdEx(binary.quoteShell)
          if rendered.exitCode == 0: writeFile(directory / "preview.txt", rendered.output)
          WorkspaceOperationResult(ok: rendered.exitCode == 0, message: rendered.output)
        vm.workspaceEditAdapter = adapter
        vm.sourceBindingMetadataDirty = createSignal(true)
        vm.workspaceEditStage.val = wesDirty
        check vm.saveIndicator.state == sisDirty
        check vm.saveIndicator.pending == 2
        var completion: proc(ok: bool; diagnostic: string) {.closure.}
        vm.sourceBindingMetadataSave = proc(done: proc(ok: bool; diagnostic: string) {.closure.}) = completion = done
        check vm.runEditorCommand(eckSave).status == ecsRunning
        check readFile(source) == original
        check vm.inspector.pendingSourceEdits.val.len == 1
        vm.workspaceEditStage.val = wesFailed
        vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedWriteFailed, message: "Owned sidecar refused")]
        completion(false, "Owned sidecar refused")
        check vm.commandState(eckSave).status == ecsFailed
        check vm.saveIndicator.state == sisFailed
        check vm.sourceBindingMetadataDirty.val
        check vm.inspector.pendingSourceEdits.val.len == 1
        check readFile(source) == original
        check vm.runEditorCommand(eckSave).status == ecsRunning
        writeFile(directory / "bindings.json", "{\"version\":1,\"variableBindings\":[],\"variableBindingHistory\":[]}")
        vm.sourceBindingMetadataDirty.val = false
        completion(true, "")
        check vm.commandState(eckSave).status == ecsSucceeded
        check fileExists(directory / "bindings.json")
        check "width:240px" in readFile(source)
        check "width:240px" in readFile(directory / "preview.txt")
        check vm.inspector.pendingSourceEdits.val.len == 0
        check vm.saveIndicator.state == sisClean
        dispose()
