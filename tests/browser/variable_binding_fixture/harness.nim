## Phase E.2 + E.3 + E.4 — browser harness for the variable binding
## flow (chip → picker → inline editor → propagation).
##
## Compiled to JS via ``nim js`` and loaded by
## ``e2e_editor_variable_binding_live.mjs``. The harness seeds an
## ``EditorVM`` with sample variables, mounts a single ``variable_chip``
## bound to ``color/surface`` plus the picker + inline editor states
## at the page root, and exposes a few diagnostic windows so the
## Playwright test can:
##
##   * Click the chip's chevron to open the picker.
##   * Type in the picker's search input to filter variables.
##   * Click a picker row to swap the chip's binding (and propagate to
##     a "live preview" swatch elsewhere on the page).
##   * Click the chip's name to open the inline editor.
##   * Save a new value in the inline editor and observe the live
##     preview update.
##
## The harness intentionally re-uses ``DomRenderer`` from the editor —
## the same renderer the production bundle uses — so the e2e exercises
## the real widget code, not a test-only path.

when not defined(js):
  {.error: "harness.nim requires the JS backend (nim js)".}

import std/[dom, options, tables]

import isonim/core/[owner, signals, computation]
import isonim/editor/dom_renderer
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/variable_chip
import isonim/editor/views/widgets/variable_picker
import isonim/editor/views/widgets/variable_inline_editor

proc seedTokens(vm: EditorVM) =
  vm.foundations.tokens.val = @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor,
      value: "#0F172A",
      schemaKey: "color/surface",
      sourceFile: "foundations/colour.nim",
      sourceLine: 12,
      affectedStories: @[
        StoryRef(group: "TaskRow", name: "Active", kind: skComponent),
        StoryRef(group: "Home", name: "Default", kind: skPage)]),
    FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor,
      value: "#7C7AED",
      schemaKey: "color/accent",
      sourceFile: "foundations/colour.nim",
      sourceLine: 18,
      affectedStories: @[]),
    FoundationTokenEntry(key: "spacing/4", kind: ftkSpacingScale,
      value: "16px",
      schemaKey: "spacing/4",
      sourceFile: "foundations/spacing.nim",
      sourceLine: 8,
      affectedStories: @[])]

proc mountHarness*() {.exportc.} =
  let chipHost = document.getElementById("chip-host".cstring)
  let popoverHost = document.getElementById("popover-host".cstring)
  let previewSwatch = document.getElementById("preview-swatch".cstring)

  let r = DomRenderer()
  createRoot do (dispose: proc()):
    let vm = createEditorVM()
    seedTokens(vm)

    let pickerState = createVariablePickerState()
    let inlineState = createVariableInlineEditorState()

    pickerState.onVariableEdit.val =
      proc(variableKey: string) {.closure.} =
        let rect = pickerState.anchorRect.val
        openVariableInlineEditorWithRect(vm, inlineState, variableKey,
          rect.x, rect.y, rect.w, rect.h)

    # Mount picker + inline editor at the popover host so they layer
    # above the chip.
    discard r.mountVariablePicker(popoverHost, vm, pickerState)
    discard r.mountVariableInlineEditor(popoverHost, vm, inlineState)

    # Seed the chip with an existing binding to color/surface — this
    # mirrors the "linked chip" surfaced by a property row whose value
    # is bound to a variable.
    let currentBinding = createSignal(VariableBinding(
      state: vbsBound,
      variableKey: "color/surface",
      resolvedValue: vm.resolveVariableValue("color/surface"),
      sourceFileRef: "foundations/colour.nim",
      sourceLineRef: 12))

    let targetKey = PropertyBindingKey(
      elementId: "harness-frame",
      propertyName: "background-color")

    proc remountChip()
    var chipRoot: Element

    proc remountChip() =
      # Wipe the chip host and re-mount with the latest binding.
      while chipHost.firstChild != nil:
        chipHost.removeChild(chipHost.firstChild)
      let binding = currentBinding.val
      let chevronCb = proc() =
        openVariablePicker(pickerState, chipRoot, targetKey)
      let nameCb = proc() =
        openVariableInlineEditor(vm, inlineState, chipRoot,
          binding.variableKey)
      let detachCb = proc() =
        vm.detachPropertyBinding(targetKey, binding.resolvedValue)
        currentBinding.val = VariableBinding(state: vbsUnbound)
      let usage = vm.usageCountFor(binding.variableKey)
      let cfg = variableChipConfig(
        binding = binding,
        usageCount = usage,
        onChevronClick = chevronCb,
        onNameClick = nameCb,
        onDetach = detachCb)
      chipRoot = r.mountVariableChip(chipHost, cfg)

    # Whenever the binding picked in the picker changes, rebuild the
    # chip so its data attributes + visible name follow the latest
    # binding.
    createRenderEffect proc() =
      let bindings = vm.inspector.propertyBindings.val
      if bindings.hasKey(targetKey):
        let b = bindings[targetKey]
        if b.variableKey != currentBinding.val.variableKey or
            b.resolvedValue != currentBinding.val.resolvedValue:
          currentBinding.val = b
      else:
        currentBinding.val = VariableBinding(state: vbsUnbound,
          variableKey: "")

    # Initial mount.
    remountChip()

    # Re-mount on binding changes — skip the first invocation since
    # the initial mount above already built the chip with the current
    # binding.
    var firstEffectRun = true
    createRenderEffect proc() =
      discard currentBinding.val
      if firstEffectRun:
        firstEffectRun = false
        return
      remountChip()

    # Live preview swatch — mirrors the resolved value of the current
    # binding so the test can verify propagation by reading the
    # swatch's ``background-color``.
    createRenderEffect proc() =
      let resolved =
        vm.resolveVariableValue(currentBinding.val.variableKey)
      if resolved.len > 0:
        previewSwatch.setAttribute("data-preview-resolved".cstring,
          resolved.cstring)
        previewSwatch.style.backgroundColor = resolved.cstring
      else:
        previewSwatch.setAttribute("data-preview-resolved".cstring,
          "".cstring)

mountHarness()
