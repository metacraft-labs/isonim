## VBIND-M5 — Workspace-file persistence of design-system variable
## bindings.
##
## Headless VM/pure-function tests for the persistence LAYER introduced
## by VBIND-M5:
##
## * ``bindingSidecarJson`` / ``parseBindingSidecar`` round-trip of the
##   two additive ``EditorWorkspace`` fields (order-preserving,
##   crash-free on malformed/absent input).
## * ``applyWorkspace`` REHYDRATE: seeds ``InspectorVM.propertyBindings``
##   from ``variableBindings`` (resolvable key → ``vbsBound``; stale key
##   → ``vbsBoundMissing``), stashes ``variableBindingHistory``, and is
##   DETERMINISTIC (re-apply replaces, never leaks).
## * RECORD path: ``bindPropertyToVariable`` / ``detachPropertyBinding``
##   maintain the persisted snapshot + previously-linked history
##   (most-recent-first, deduped) and fire the ``onBindingsChanged`` save
##   seam.
## * BACKWARD-COMPAT: a default (empty-metadata) workspace rehydrates to
##   empty ``propertyBindings`` — the M1 byte-unchanged property holds.
##
## No filesystem here: the framework owns (de)serialize + rehydrate +
## record; the actual sidecar read/write is the consumer's (a pilot save
## hook), deferred to M7's e2e.

import std/[algorithm, tables, unittest]
import isonim/core/[owner, signals]
import isonim/editor

proc colourTokens(): seq[FoundationTokenEntry] =
  @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
      value: "#0F172A", sourceFile: "foundations/colour.nim", sourceLine: 12),
    FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
      value: "#7C7AED", sourceFile: "foundations/colour.nim", sourceLine: 20),
    FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
      value: "16px", sourceFile: "foundations/spacing.nim", sourceLine: 7)]

suite "VBIND-M5 sidecar (de)serialization":

  test "toJson/fromJson round-trips bindings and most-recent-first history":
    let bindings = @[
      PersistedPropertyBinding(elementId: "frame-1",
        propertyName: "background-color", variableKey: "color/surface"),
      PersistedPropertyBinding(elementId: "row-1",
        propertyName: "gap", variableKey: "spacing/4")]
    let history = @[
      PropertyBindingHistoryEntry(elementId: "frame-1",
        propertyName: "background-color",
        variableKeys: @["color/accent", "color/surface"]),
      PropertyBindingHistoryEntry(elementId: "row-1",
        propertyName: "gap", variableKeys: @["spacing/4"])]

    let raw = bindingSidecarJson(bindings, history)
    let parsed = parseBindingSidecar(raw)

    check parsed.bindings == bindings
    # History order (entries AND per-entry keys, most-recent-first) is
    # preserved verbatim.
    check parsed.history == history
    check parsed.history[0].variableKeys == @["color/accent", "color/surface"]

  test "workspace overload round-trips through loadBindingSidecar":
    let ws = newEditorWorkspace(
      title = "Persist",
      storyGroups = @[],
      variableBindings = @[
        PersistedPropertyBinding(elementId: "frame-1",
          propertyName: "color", variableKey: "color/accent")],
      variableBindingHistory = @[
        PropertyBindingHistoryEntry(elementId: "frame-1",
          propertyName: "color", variableKeys: @["color/accent"])])

    let raw = bindingSidecarJson(ws)
    var restored = newEditorWorkspace(title = "Blank", storyGroups = @[])
    check restored.variableBindings.len == 0
    restored.loadBindingSidecar(raw)
    check restored.variableBindings == ws.variableBindings
    check restored.variableBindingHistory == ws.variableBindingHistory

  test "malformed and absent JSON parse to empty (no crash)":
    check parseBindingSidecar("").bindings.len == 0
    check parseBindingSidecar("").history.len == 0
    check parseBindingSidecar("   \n ").bindings.len == 0
    check parseBindingSidecar("{ this is not json").bindings.len == 0
    check parseBindingSidecar("[]").bindings.len == 0        # wrong root kind
    check parseBindingSidecar("42").bindings.len == 0
    # Partially-valid document: missing keys degrade to empty strings,
    # non-object array items are skipped — still no crash.
    let partial = parseBindingSidecar(
      """{"variableBindings":[{"elementId":"x"}, 7],
          "variableBindingHistory":"nope"}""")
    check partial.bindings.len == 1
    check partial.bindings[0].elementId == "x"
    check partial.bindings[0].variableKey == ""
    check partial.history.len == 0

suite "VBIND-M5 rehydrate in applyWorkspace":

  test "seeds propertyBindings from variableBindings (bound + missing)":
    createRoot proc(dispose: proc()) =
      let ws = newEditorWorkspace(
        title = "Rehydrate",
        storyGroups = @[],
        foundationTokens = colourTokens(),
        variableBindings = @[
          PersistedPropertyBinding(elementId: "frame-1",
            propertyName: "background-color", variableKey: "color/surface"),
          PersistedPropertyBinding(elementId: "row-1",
            propertyName: "gap", variableKey: "spacing/gone")])
      let vm = createEditorVM(ws)

      let bound = PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color")
      let missing = PropertyBindingKey(elementId: "row-1", propertyName: "gap")

      check vm.inspector.propertyBindings.val.len == 2
      check vm.inspector.propertyBindings.val[bound].state == vbsBound
      check vm.inspector.propertyBindings.val[bound].resolvedValue == "#0F172A"
      check vm.inspector.propertyBindings.val[bound].sourceFileRef ==
        "foundations/colour.nim"
      check vm.inspector.propertyBindings.val[missing].state == vbsBoundMissing
      check vm.inspector.propertyBindings.val[missing].resolvedValue == ""
      dispose()

  test "empty-metadata workspace seeds nothing (backward-compat default)":
    createRoot proc(dispose: proc()) =
      let ws = newEditorWorkspace(title = "Empty", storyGroups = @[],
        foundationTokens = colourTokens())
      let vm = createEditorVM(ws)
      check vm.inspector.propertyBindings.val.len == 0
      check vm.inspector.variableBindingHistory.val.len == 0
      dispose()

  test "stashes variableBindingHistory for the picker (VBIND-M6)":
    createRoot proc(dispose: proc()) =
      let ws = newEditorWorkspace(
        title = "History",
        storyGroups = @[],
        foundationTokens = colourTokens(),
        variableBindingHistory = @[
          PropertyBindingHistoryEntry(elementId: "frame-1",
            propertyName: "background-color",
            variableKeys: @["color/accent", "color/surface"])])
      let vm = createEditorVM(ws)
      check vm.inspector.variableBindingHistory.val.len == 1
      check vm.inspector.variableBindingHistory.val[0].variableKeys ==
        @["color/accent", "color/surface"]
      dispose()

  test "re-applyWorkspace is deterministic — a different set replaces prior":
    createRoot proc(dispose: proc()) =
      let first = newEditorWorkspace(
        title = "First", storyGroups = @[], foundationTokens = colourTokens(),
        variableBindings = @[
          PersistedPropertyBinding(elementId: "frame-1",
            propertyName: "background-color", variableKey: "color/surface")])
      let vm = createEditorVM(first)
      check vm.inspector.propertyBindings.val.len == 1

      let second = newEditorWorkspace(
        title = "Second", storyGroups = @[], foundationTokens = colourTokens(),
        variableBindings = @[
          PersistedPropertyBinding(elementId: "row-1",
            propertyName: "gap", variableKey: "spacing/4")])
      vm.applyWorkspace(second)

      # No leakage from the first apply; only the second set survives.
      check vm.inspector.propertyBindings.val.len == 1
      check (not vm.inspector.propertyBindings.val.hasKey(
        PropertyBindingKey(elementId: "frame-1",
          propertyName: "background-color")))
      check vm.inspector.propertyBindings.val.hasKey(
        PropertyBindingKey(elementId: "row-1", propertyName: "gap"))

      # Applying an empty-metadata workspace clears everything.
      vm.applyWorkspace(newEditorWorkspace(title = "Third", storyGroups = @[],
        foundationTokens = colourTokens()))
      check vm.inspector.propertyBindings.val.len == 0
      dispose()

suite "VBIND-M5 record path (bind / detach maintain persisted state)":

  test "bindPropertyToVariable records persisted snapshot + history":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = colourTokens()

      let key = PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color")
      vm.bindPropertyToVariable(key, "color/surface")

      let meta = vm.collectWorkspaceBindingMetadata()
      check meta.bindings.len == 1
      check meta.bindings[0].elementId == "frame-1"
      check meta.bindings[0].propertyName == "background-color"
      check meta.bindings[0].variableKey == "color/surface"
      check meta.history.len == 1
      check meta.history[0].variableKeys == @["color/surface"]
      dispose()

  test "history is most-recent-first and deduped across re-links":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = colourTokens()
      let key = PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color")

      vm.bindPropertyToVariable(key, "color/surface")
      vm.bindPropertyToVariable(key, "color/accent")
      # Re-linking the first variable floats it back to the front.
      vm.bindPropertyToVariable(key, "color/surface")

      let hist = vm.inspector.variableBindingHistory.val
      check hist.len == 1
      check hist[0].variableKeys == @["color/surface", "color/accent"]
      dispose()

  test "detach floats the just-unlinked variable to the front of history":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = colourTokens()
      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        properties: @[PropertyInfo(name: "background-color", value: "#000",
          origin: poInherited, directStyleAllowed: true)])
      let key = PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color")

      vm.bindPropertyToVariable(key, "color/accent")
      vm.bindPropertyToVariable(key, "color/surface")
      # Detaching color/surface removes the binding but keeps it in history,
      # now at the front.
      vm.detachPropertyBinding(key, "#0F172A")

      check vm.inspector.propertyBindings.val.len == 0
      let hist = vm.inspector.variableBindingHistory.val
      check hist.len == 1
      check hist[0].variableKeys == @["color/surface", "color/accent"]
      dispose()

  test "onBindingsChanged save seam fires on bind and detach":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = colourTokens()
      var saves = 0
      vm.inspector.onBindingsChanged = proc() = inc saves

      vm.inspector.selectedElement.val = ElementRef(tag: "div", id: "frame-1",
        properties: @[PropertyInfo(name: "background-color", value: "#000",
          origin: poInherited, directStyleAllowed: true)])
      let key = PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color")

      vm.bindPropertyToVariable(key, "color/surface")
      check saves == 1
      vm.detachPropertyBinding(key, "#0F172A")
      check saves == 2
      dispose()

  test "collect → serialize → parse → rehydrate is a full closed loop":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = colourTokens()
      vm.bindPropertyToVariable(PropertyBindingKey(elementId: "frame-1",
        propertyName: "background-color"), "color/surface")
      vm.bindPropertyToVariable(PropertyBindingKey(elementId: "row-1",
        propertyName: "gap"), "spacing/4")

      # Consumer save side: snapshot → serialize.
      let meta = vm.collectWorkspaceBindingMetadata()
      let raw = bindingSidecarJson(meta.bindings, meta.history)

      # Consumer load side (fresh VM): parse → rehydrate.
      let restored = parseBindingSidecar(raw)
      let vm2 = createEditorVM()
      vm2.foundations.tokens.val = colourTokens()
      vm2.rehydratePropertyBindings(restored.bindings, restored.history)

      # Both bindings survived the round trip (order-independent set check).
      check vm2.inspector.propertyBindings.val.len == 2
      var restoredKeys: seq[string] = @[]
      for k, b in vm2.inspector.propertyBindings.val:
        restoredKeys.add k.elementId & "/" & k.propertyName & "=" & b.variableKey
      restoredKeys.sort()
      check restoredKeys == @[
        "frame-1/background-color=color/surface",
        "row-1/gap=spacing/4"]
      dispose()
