## IsoNim Editor — Component Detail View.
##
## Storybook-style: each variant gets its own section with title,
## description, and full-width rendering.

import std/strutils

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/choice_row

const
  bgBase = "#0D0E14"
  bgSurface = "#1A1B26"
  bgCard = "#15161F"
  bgPreview = "#0F1018"
  border = "#2A2C3A"
  borderFaint = "#1F212C"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  accent = "#7C7AED"
  green = "#22C55E"
  red = "#EF4444"

proc renderGenericComponentPreview[R, E](r: R; title, description: string): E =
  ## Generic dark-themed placeholder card. The real demo lives in the
  ## iframe `srcdoc` provided by the preview hook; this card only shows
  ## when no preview document is available.
  ui(r):
    tdiv(width = "360px", padding = "22px",
          background_color = bgCard, color = textPrimary,
          border = "1px solid " & border,
          border_radius = "14px",
          display = "flex", flex_direction = "column", gap = "14px"):
      tdiv(height = "100px", border_radius = "10px",
            background_image = "linear-gradient(135deg, #272752, #15161F)",
            border = "1px solid " & border)
      span(font_size = "16px", font_weight = "600",
            letter_spacing = "-0.01em",
            color = textPrimary):
        text title
      span(font_size = "12px", color = textMuted, line_height = "1.45"):
        text description
      tdiv(display = "flex", gap = "8px"):
        tdiv(height = "26px", width = "76px", border_radius = "999px",
              background_color = accent)
        tdiv(height = "26px", width = "62px", border_radius = "999px",
              background_color = "transparent",
              border = "1px solid " & border)

proc sectionLabel[R, E](r: R; title: string): E =
  ui(r):
    span(font_size = "11px", font_weight = "700", color = textSecondary,
          text_transform = "uppercase", letter_spacing = "1px"):
      text title

proc renderVariantSection[R, E](r: R; name, description: string;
                                  component: E): E =
  ## A single variant: header annotation + full-width preview area.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          border = "1px solid " & border, border_radius = "8px",
          overflow = "hidden")

  # Annotation header
  let header = ui(r):
    tdiv(display = "flex", align_items = "baseline", gap = "12px",
          padding = "12px 16px",
          background_color = bgCard,
          border_bottom = "1px solid " & border):
      span(font_size = "14px", font_weight = "600", color = textPrimary):
        text name
      span(font_size = "12px", color = textMuted):
        text description
  r.appendChild(section, header)

  # Preview area (light bg to contrast with the component)
  let preview = ui(r):
    tdiv(padding = "24px", display = "flex",
          justify_content = "center",
          background_color = bgPreview,
          min_height = "120px")
  r.appendChild(preview, component)
  r.appendChild(section, preview)
  section

func nextOption(options: seq[string]; current: string): string =
  if options.len == 0:
    return current
  let index = options.find(current)
  if index < 0 or index == options.high:
    options[0]
  else:
    options[index + 1]

proc selectedComponentVariant(vm: EditorVM;
    variants: seq[ComponentVariantDefinition]): ComponentVariantDefinition =
  let selected = vm.variants.selectedVariant.val
  if selected >= 0 and selected < vm.variants.variants.val.len:
    let candidate = vm.variants.variants.val[selected]
    for variant in variants:
      if variant.component == candidate.component and
          variant.variantKey == candidate.variantKey:
        return candidate
  if variants.len > 0:
    variants[0]
  else:
    ComponentVariantDefinition()

proc componentVariantsForStory(vm: EditorVM;
    story: StoryRef): seq[ComponentVariantDefinition] =
  for variant in vm.variants.variants.val:
    if variant.story.group == story.group and variant.story.name == story.name:
      result.add variant

func jsString(value: string): string =
  value
    .replace("\\", "\\\\")
    .replace("\"", "\\\"")
    .replace("\n", "\\n")
    .replace("\r", "\\r")

func jsLiteral(value: string): string =
  "\"" & value.jsString & "\""

func componentPropertyValue(variant: ComponentVariantDefinition;
    name: string): string =
  for prop in variant.properties:
    if prop.name == name:
      return prop.value
  ""

func previewMutationValue(mutation: PreviewVariantMutation;
    sourceValue: string): string =
  for value in mutation.values:
    if value.sourceValue == sourceValue:
      return value.previewValue
  sourceValue

func previewMutationClassValues(mutation: PreviewVariantMutation): seq[string] =
  for value in mutation.values:
    if value.previewValue.len > 0 and value.previewValue notin result:
      result.add value.previewValue

proc componentPreviewVariantScript(vm: EditorVM;
    preview: ProjectPreview): string =
  if preview.variantMutations.len == 0:
    return ""
  let story = vm.selectedStory.val
  let variants = vm.componentVariantsForStory(story)
  if variants.len == 0:
    return ""
  let variant = vm.selectedComponentVariant(variants)
  for mutation in preview.variantMutations:
    if mutation.component != variant.component:
      continue
    if mutation.variantKey.len > 0 and
        mutation.variantKey != variant.variantKey:
      continue
    if mutation.selector.len == 0 or mutation.property.len == 0:
      continue
    let sourceValue = variant.componentPropertyValue(mutation.property)
    if sourceValue.len == 0:
      continue
    let previewValue = mutation.previewMutationValue(sourceValue)
    result.add "var node = doc.querySelector(" & mutation.selector.jsLiteral &
      ");\n"
    result.add "if (node) {\n"
    case mutation.kind
    of pvmkClassToken:
      if mutation.classPrefix.len == 0:
        result.add "}\n"
        continue
      for classValue in mutation.previewMutationClassValues():
        result.add "  node.classList.remove(" &
          (mutation.classPrefix & classValue).jsLiteral & ");\n"
      result.add "  node.classList.add(" &
        (mutation.classPrefix & previewValue).jsLiteral & ");\n"
    of pvmkAttribute:
      if mutation.attributeName.len == 0:
        result.add "}\n"
        continue
      result.add "  node.setAttribute(" & mutation.attributeName.jsLiteral &
        ", " & previewValue.jsLiteral & ");\n"
    of pvmkTextContent:
      result.add "  node.textContent = " & previewValue.jsLiteral & ";\n"
    result.add "}\n"

func componentPropertyMutationsForProp(
    mutations: seq[PreviewVariantMutation];
    component, variantKey, propName: string): seq[PreviewVariantMutation] =
  for m in mutations:
    if m.component != component:
      continue
    if m.variantKey.len > 0 and m.variantKey != variantKey:
      continue
    if m.property != propName:
      continue
    if m.selector.len == 0:
      continue
    result.add m

func componentPropertyMutationsJsLiteral(
    mutations: seq[PreviewVariantMutation]): string =
  ## Serialize the property's preview mutations as a JSON literal so the live
  ## preview JS handler can apply them to the iframe without going through the
  ## reactive signal store.
  result = "["
  for i, m in mutations:
    if i > 0: result.add ","
    result.add "{\"selector\":" & m.selector.jsLiteral
    result.add ",\"kind\":" & $m.kind.ord
    result.add ",\"attributeName\":" & m.attributeName.jsLiteral
    result.add ",\"classPrefix\":" & m.classPrefix.jsLiteral
    result.add ",\"values\":["
    for j, v in m.values:
      if j > 0: result.add ","
      result.add "{\"sourceValue\":" & v.sourceValue.jsLiteral
      result.add ",\"previewValue\":" & v.previewValue.jsLiteral & "}"
    result.add "]}"
  result.add "]"

proc attachComponentPropertyLivePreview[R, E](r: R; inputNode, frame: E;
    mutationsJson: string) =
  ## Mirror what variantScript does on commit, but without committing: on each
  ## `input` event, apply the matching preview mutations directly to the iframe
  ## DOM. This lets the user see live changes while typing without triggering
  ## a reactive rebuild that would steal focus from the input.
  when defined(js):
    {.emit: ["""
      (function () {
        const input = """, inputNode, """;
        const frame = """, frame, """;
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const json = toJsString(""", mutationsJson, """);
        if (!input || !frame) return;
        if (input.__isonimComponentPropertyLivePreviewInstalled) return;
        input.__isonimComponentPropertyLivePreviewInstalled = true;
        let mutations;
        try { mutations = JSON.parse(json); } catch (_) { mutations = []; }
        if (!Array.isArray(mutations) || mutations.length === 0) return;
        input.addEventListener('input', () => {
          try {
            const doc = frame.contentDocument;
            if (!doc) return;
            const value = input.value || '';
            for (const m of mutations) {
              const node = doc.querySelector(m.selector);
              if (!node) continue;
              let previewValue = value;
              for (const v of m.values) {
                if (v.sourceValue === value) {
                  previewValue = v.previewValue;
                  break;
                }
              }
              if (m.kind === 0) {
                if (!m.classPrefix) continue;
                for (const v of m.values) {
                  if (v.previewValue) {
                    node.classList.remove(m.classPrefix + v.previewValue);
                  }
                }
                if (previewValue) {
                  node.classList.add(m.classPrefix + previewValue);
                }
              } else if (m.kind === 1) {
                if (m.attributeName) {
                  node.setAttribute(m.attributeName, previewValue);
                }
              } else if (m.kind === 2) {
                node.textContent = previewValue;
              }
            }
          } catch (_) {}
        });
      })();
    """].}
  else:
    discard r
    discard inputNode
    discard frame
    discard mutationsJson

proc renderComponentPropertyInput[R, E](r: R; vm: EditorVM; frame: E;
    variant: ComponentVariantDefinition;
    prop: ComponentPropertyDefinition;
    previewMutations: seq[PreviewVariantMutation]): E =
  let component = variant.component
  let variantKey = variant.variantKey
  let propName = prop.name
  let propOptions = prop.options
  proc choosePropertyOption(nextValue: string): proc() =
    let capturedValue = nextValue
    result = proc() =
      discard vm.editComponentProperty(component, variantKey, propName,
        capturedValue, cpemManual)
  if propOptions.len > 0:
    var choices: seq[CompactChoiceOption] = @[]
    for option in propOptions:
      choices.add CompactChoiceOption(
        label: option,
        shortLabel: option,
        ariaLabel: "Apply component property " & propName & " option " & option,
        selected: option == prop.value,
        enabled: true,
        onChoose: choosePropertyOption(option))
    let choiceRow = renderCompactChoiceRow[R, E](r, prop.name,
      "Choose component property " & prop.name, choices, visibleLimit = 3,
      labelWidth = "82px", minHeight = "30px")
    result = choiceRow.root
    r.setAttribute(result, "data-component-property-control", prop.name)
    r.setAttribute(result, "data-component-property-options", $propOptions.len)
    r.setAttribute(result, "title",
      componentPropertyKindLabel(prop.kind) & ". " & prop.documentation & " " &
        prop.usageGuidance)
    return

  var inputNode: E
  var cycleNode: E
  let commit = proc() =
    discard vm.editComponentProperty(component, variantKey, propName,
      r.inputValue(inputNode), cpemManual)
  let cycle = proc() =
    let next = nextOption(propOptions, r.inputValue(inputNode))
    r.setInputValue(inputNode, next)
    discard vm.editComponentProperty(component, variantKey, propName, next,
      cpemManual)
  result = ui(r):
    tdiv(display = "grid",
          grid_template_columns = "82px minmax(0, 1fr) 30px",
          align_items = "center", gap = "6px",
          min_height = "30px", max_width = "100%",
          overflow = "hidden"):
      label(font_size = "10px", color = textMuted,
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text prop.name
      input(ref = inputNode,
            class = "editor-input",
            height = "24px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "0 6px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            min_width = "0",
            onchange = commit,
            onblur = commit)
      tdiv(ref = cycleNode, role = "button", tabindex = "0",
            height = "23px",
            display = "flex", align_items = "center",
            justify_content = "center",
            border = "1px solid " & border,
            border_radius = "4px",
            background_color = bgSurface,
            color = textMuted, font_size = "10px",
            cursor = "pointer"):
        text ">"
  r.setInputValue(inputNode, prop.value)
  r.setAttribute(inputNode, "aria-label", "Edit component property " & prop.name)
  r.setAttribute(inputNode, "data-component-property-control", prop.name)
  r.setAttribute(cycleNode, "aria-label", "Cycle component property " & prop.name)
  r.setAttribute(cycleNode, "title",
    componentPropertyKindLabel(prop.kind) & ". " & prop.documentation & " " &
      prop.usageGuidance)
  let propMutations = componentPropertyMutationsForProp(previewMutations,
    component, variantKey, propName)
  if propMutations.len > 0:
    r.attachComponentPropertyLivePreview(inputNode, frame,
      componentPropertyMutationsJsLiteral(propMutations))
  r.addEventListener(cycleNode, "click", cycle)
  r.addEventListener(cycleNode, "keydown", cycle)

proc renderComponentStateButton[R, E](r: R; vm: EditorVM;
    variant: ComponentVariantDefinition;
    state: ComponentStateControl): E =
  let component = variant.component
  let variantKey = variant.variantKey
  let stateKey = state.key
  let stateOptions = state.options
  let currentValue = state.value
  proc chooseStateOption(nextValue: string): proc() =
    let capturedValue = nextValue
    result = proc() =
      discard vm.editComponentStateControl(component, variantKey, stateKey,
        capturedValue, cpemManual)
  if stateOptions.len > 0:
    var choices: seq[CompactChoiceOption] = @[]
    for option in stateOptions:
      choices.add CompactChoiceOption(
        label: option,
        shortLabel: option,
        ariaLabel: "Apply component state " & state.key & " option " & option,
        selected: option == currentValue,
        enabled: true,
        onChoose: chooseStateOption(option))
    let choiceRow = renderCompactChoiceRow[R, E](r, state.label,
      "Choose component state " & state.key, choices, visibleLimit = 2,
      labelWidth = "64px", minHeight = "26px")
    result = choiceRow.root
    r.setAttribute(result, "data-component-state-control", state.key)
    r.setAttribute(result, "title",
      componentStateKindLabel(state.kind) & " state routed through schema " &
        state.schemaKey)
    return

  let activate = proc() =
    let next = nextOption(stateOptions, currentValue)
    discard vm.editComponentStateControl(component, variantKey, stateKey, next,
      cpemManual)
  result = ui(r):
    tdiv(role = "button", tabindex = "0",
          min_height = "24px",
          padding = "4px 7px",
          border = "1px solid " & border,
          border_radius = "4px",
          background_color = (if currentValue in ["true", "success", "error"]:
      bgSurface else: bgCard),
          color = textSecondary,
          font_size = "10px",
          cursor = "pointer",
          overflow = "hidden",
          white_space = "nowrap",
          text_overflow = "ellipsis"):
      text (state.label & ": " & state.value)
  r.setAttribute(result, "aria-label", "Set component state " & state.key)
  r.setAttribute(result, "data-component-state-control", state.key)
  r.setAttribute(result, "title",
    componentStateKindLabel(state.kind) & " state routed through schema " &
      state.schemaKey)
  r.addEventListener(result, "click", activate)
  r.addEventListener(result, "keydown", activate)

proc renderCreateStateStoryButton[R, E](r: R; vm: EditorVM;
    cell: ComponentVariantMatrixCell): E =
  let component = cell.component
  let variantKey = cell.variantKey
  let stateKey = cell.stateKey
  let create = proc() =
    discard vm.createStoryForComponentState(component, variantKey, stateKey)
  result = ui(r):
    tdiv(role = "button", tabindex = "0",
          margin_top = "5px",
          padding = "3px 6px",
          border_radius = "4px",
          background_color = accent,
          color = textPrimary,
          font_size = "10px",
          cursor = "pointer"):
      text "Create story"
  r.setAttribute(result, "aria-label", "Create story for " & component & " " &
    stateKey & " state")
  r.setAttribute(result, "data-create-state-story", cell.createStoryCommand)
  r.addEventListener(result, "click", create)
  r.addEventListener(result, "keydown", create)

proc populateComponentPropertyPanel[R, E](r: R; vm: EditorVM; panel, frame: E;
    previewMutations: seq[PreviewVariantMutation]) =
  r.clearChildren(panel)
  let story = vm.selectedStory.val
  if story.kind notin {skComponent, skPattern}:
    r.setStyle(panel, "display", "none")
    return
  let variants = vm.componentVariantsForStory(story)
  if variants.len == 0:
    r.setStyle(panel, "display", "none")
    return
  let variant = vm.selectedComponentVariant(variants)
  let componentKey = variant.component
  let coverage = vm.stateCoverageDiagnostics(componentKey)
  let pendingCount = vm.inspector.pendingSourceEdits.val.len
  vm.variants.stateDiagnostics.val = coverage
  r.setStyle(panel, "display", "flex")

  var saveButton: E
  var revertButton: E
  let header = ui(r):
    tdiv(display = "flex", justify_content = "space-between",
          align_items = "baseline", gap = "12px"):
      tdiv(display = "flex", flex_direction = "column", gap = "3px"):
        span(font_size = "13px", font_weight = "700", color = textPrimary):
          text "Component properties"
        span(font_size = "11px", color = textMuted):
          text ("Schema-backed controls for " & variant.component & " / " &
            variant.variantKey)
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        span(font_size = "10px", color = textDim):
          text ($coverage.len & " diagnostics")
        span(font_size = "10px", color = textDim):
          text ($pendingCount & " component plan(s) staged")
        tdiv(ref = revertButton, role = "button", tabindex = "0",
              padding = "4px 7px", border_radius = "4px",
              background_color = bgCard, color = textMuted,
              font_size = "10px", cursor = "pointer"):
          text "Revert"
        tdiv(ref = saveButton, role = "button", tabindex = "0",
              padding = "4px 7px", border_radius = "4px",
              background_color = accent, color = textPrimary,
              font_size = "10px", font_weight = "600", cursor = "pointer"):
          text "Save"
  r.appendChild(panel, header)
  r.setAttribute(saveButton, "aria-label", "Save component property source edits")
  r.setAttribute(revertButton, "aria-label",
    "Revert component property source edits")
  r.addEventListener(saveButton, "click", proc() =
    discard vm.runEditorCommand(eckSave))
  r.addEventListener(saveButton, "keydown", proc() =
    discard vm.runEditorCommand(eckSave))
  r.addEventListener(revertButton, "click", proc() =
    discard vm.runEditorCommand(eckRevert))
  r.addEventListener(revertButton, "keydown", proc() =
    discard vm.runEditorCommand(eckRevert))

  let props = ui(r):
    tdiv(display = "grid",
          grid_template_columns = "repeat(auto-fit, minmax(230px, 1fr))",
          gap = "8px")
  for property in variant.properties:
    let prop = property
    let row = ui(r):
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            padding = "8px",
            border = "1px solid " & borderFaint,
            border_radius = "6px",
            background_color = bgCard,
            min_width = "0"):
        discard
    r.appendChild(row, renderComponentPropertyInput[R, E](r, vm, frame,
      variant, prop, previewMutations))
    let guidance = ui(r):
      span(font_size = "10px", color = textDim, line_height = "1.35"):
        text (componentPropertyKindLabel(prop.kind) & " - " &
          prop.usageGuidance)
    r.appendChild(row, guidance)
    r.appendChild(props, row)
  r.appendChild(panel, props)

  let states = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px"):
      span(font_size = "11px", font_weight = "700", color = textSecondary,
            text_transform = "uppercase"):
        text "States"
      tdiv(display = "grid",
            grid_template_columns = "repeat(auto-fit, minmax(112px, 1fr))",
            gap = "6px"):
        discard
  let stateGrid = states
  for stateControl in variant.stateControls:
    let state = stateControl
    r.appendChild(stateGrid, renderComponentStateButton[R, E](r, vm, variant,
      state))
  r.appendChild(panel, states)

  let matrix = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px"):
      span(font_size = "11px", font_weight = "700", color = textSecondary,
            text_transform = "uppercase"):
        text "Variant matrix"
      tdiv(display = "grid",
            grid_template_columns = "repeat(auto-fit, minmax(132px, 1fr))",
            gap = "6px"):
        discard
  r.setAttribute(matrix, "data-component-variant-matrix", "true")
  let matrixCells = variantMatrixPreviews(vm, componentKey)
  for matrixCell in matrixCells:
    let cell = matrixCell
    let cellNode = ui(r):
      tdiv(padding = "7px",
            border = "1px solid " & (if cell.covered: borderFaint else: red),
            border_radius = "6px",
            background_color = bgCard,
            min_height = "58px",
            display = "flex", flex_direction = "column",
            justify_content = "space-between",
            gap = "4px"):
        span(font_size = "10px", color = textSecondary,
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis"):
          text cell.label
        span(font_size = "10px", color = (if cell.covered: green else: red)):
          text (if cell.covered: "covered" else: "missing story")
    r.setAttribute(cellNode, "data-component-variant-matrix-cell",
      cell.variantKey & ":" & cell.stateKey)
    if not cell.covered:
      r.appendChild(cellNode, renderCreateStateStoryButton[R, E](r, vm, cell))
    r.appendChild(matrix, cellNode)
  r.appendChild(panel, matrix)

  if coverage.len > 0:
    let diagnostics = ui(r):
      tdiv(display = "flex", flex_direction = "column", gap = "5px",
            padding = "8px",
            border = "1px solid " & borderFaint,
            border_radius = "6px",
            background_color = bgCard):
        span(font_size = "11px", font_weight = "700", color = textSecondary):
          text "State coverage diagnostics"
    for coverageDiagnostic in coverage[0 .. min(coverage.high, 3)]:
      let diagnostic = coverageDiagnostic
      let item = ui(r):
        span(font_size = "10px", color = textMuted, line_height = "1.35"):
          text (diagnostic.message & " " & diagnostic.suggestion)
      r.appendChild(diagnostics, item)
    r.appendChild(panel, diagnostics)

proc renderComponentDetail*[R, E](r: R; vm: EditorVM): E =
  let page = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase, overflow_y = "auto")

  # Header bar
  var editButton: E
  var headerTitle: E
  let header = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          height = "44px", min_height = "44px", padding = "0 20px",
          background_color = bgCard,
          border_bottom = "1px solid " & border):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(font_size = "11px", color = textDim):
          text "Components"
        span(font_size = "11px", color = textDim):
          text "\xE2\x80\xBA"
        span(ref = headerTitle,
              font_size = "13px", font_weight = "600", color = textPrimary):
          text "Component preview"
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        tdiv(ref = editButton,
              padding = "4px 12px", border_radius = "4px",
              font_size = "11px", font_weight = "500",
              background_color = accent, color = textPrimary,
              cursor = "pointer"):
          text "Edit"
        tdiv(padding = "4px 12px", border_radius = "4px",
              font_size = "11px", font_weight = "500",
              background_color = bgSurface, color = textMuted,
              cursor = "default"):
          text "Code"
  r.appendChild(page, header)
  r.setAttribute(editButton, "role", "button")
  r.setAttribute(editButton, "tabindex", "0")
  r.setAttribute(editButton, "aria-label", "Open selected component in edit mode")
  r.addEventListener(editButton, "click", proc() =
    discard vm.runEditorCommand(eckEdit))
  r.addEventListener(editButton, "keydown", proc() =
    discard vm.runEditorCommand(eckEdit))
  createRenderEffect proc() =
    let state = vm.evaluateCommand(eckEdit)
    r.setAttribute(editButton, "aria-disabled",
      if state.status == ecsDisabled: "true" else: "false")
    if state.diagnostic.len > 0:
      r.setAttribute(editButton, "title", state.diagnostic)
    else:
      r.removeAttribute(editButton, "title")

  # Scrollable content
  let content = ui(r):
    tdiv(padding = "24px 32px", display = "flex",
          flex_direction = "column", gap = "24px")

  var projectSection: E
  var projectName: E
  var projectDescription: E
  var projectFrame: E
  let projectPreviewSection = ui(r):
    tdiv(ref = projectSection,
          display = "none", flex_direction = "column",
          border = "1px solid " & border, border_radius = "8px",
          overflow = "hidden"):
      tdiv(display = "flex", align_items = "baseline", gap = "12px",
            padding = "12px 16px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        span(ref = projectName,
              font_size = "14px", font_weight = "600", color = textPrimary):
          text ""
        span(ref = projectDescription,
              font_size = "12px", color = textMuted):
          text ""
      tdiv(padding = "24px", display = "flex",
            justify_content = "center",
            background_color = bgPreview,
            min_height = "120px"):
        iframe(ref = projectFrame,
            title = "Component preview",
            width = "1280",
            height = "1",
            border = "0",
            scrolling = "no",
            background_color = "#FFFFFF")
  r.appendChild(content, projectPreviewSection)

  var propertyPanel: E
  let componentProperties = ui(r):
    tdiv(ref = propertyPanel,
          class = "component-property-schema-panel",
          display = "none",
          flex_direction = "column",
          gap = "12px",
          padding = "12px",
          border = "1px solid " & border,
          border_radius = "8px",
          background_color = bgSurface)
  r.setAttribute(componentProperties, "aria-label",
    "Component property schema and variant matrix")
  r.appendChild(content, componentProperties)

  let genericContent = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "24px")
  var renderedVariants = false
  for group in vm.sidebar.groups.val:
    if group.kind == skComponent and not renderedVariants:
      for item in group.items:
        let preview = renderGenericComponentPreview[R, E](r, item.name,
          item.description)
        let section = renderVariantSection[R, E](r, item.name,
          item.description, preview)
        r.appendChild(genericContent, section)
      renderedVariants = true

  if not renderedVariants:
    let preview = renderGenericComponentPreview[R, E](r,
      "Component preview",
      "Select a component story from the workspace sidebar.")
    let section = renderVariantSection[R, E](r,
      "Component preview",
      "Project-owned component state",
      preview)
    r.appendChild(genericContent, section)
  r.appendChild(content, genericContent)

  var lastProjectSrcdoc = ""
  createRenderEffect proc() =
    let story = vm.selectedStory.val
    let preview = vm.preview.current.val
    let title =
      if story.kind in {skComponent, skPattern, skFoundation, skGuideline} and
          preview.title.len > 0:
        preview.title
      elif story.kind in {skComponent, skPattern, skFoundation, skGuideline} and
          story.group.len > 0 and story.name.len > 0:
        story.group & " / " & story.name
      else:
        "Component preview"
    let showProject = preview.documentHtml.len > 0 and
      story.kind in {skComponent, skPattern}

    r.setTextContent(headerTitle, title)
    r.setTextContent(projectName,
      if story.kind in {skComponent, skPattern}: story.name else: "")
    r.setTextContent(projectDescription,
      if story.kind in {skComponent, skPattern} and preview.bodyText.len > 0:
        preview.bodyText
      else:
        "Project-owned component state")
    r.setAttribute(projectFrame, "title", "Component preview " & title)
    r.setAttribute(projectFrame, "height", "1")
    let reloadGeneration = vm.livePreviewReloadGeneration.val
    let nextProjectSrcdoc =
      if showProject:
        preview.documentHtml & "\n<!-- isonim-reload:" & $reloadGeneration &
          " -->"
      else:
        ""
    if nextProjectSrcdoc != lastProjectSrcdoc:
      r.setAttribute(projectFrame, "srcdoc", nextProjectSrcdoc)
      lastProjectSrcdoc = nextProjectSrcdoc
    r.setStyle(projectFrame, "width", "100%")
    r.setStyle(projectFrame, "min-height", "1px")
    r.setStyle(projectFrame, "overflow", "hidden")
    r.setStyle(projectSection, "display", if showProject: "flex" else: "none")
    r.setStyle(genericContent, "display", if showProject: "none" else: "flex")
    r.populateComponentPropertyPanel(vm, propertyPanel, projectFrame,
      preview.variantMutations)

    when defined(js):
      let frame = projectFrame
      let variantScript = vm.componentPreviewVariantScript(preview)
      {.emit: ["""
        (function (frame, sourceRaw) {
          const source = Array.isArray(sourceRaw)
            ? String.fromCharCode.apply(null, sourceRaw)
            : String(sourceRaw || '');
          if (!frame) return;
          const apply = () => {
            if (!source) return;
            try {
              const doc = frame.contentDocument;
              if (!doc) return;
              Function('doc', source)(doc);
            } catch (_) {
              // Preview variant metadata is best-effort; broken consumer
              // selectors must not break the editor shell.
            }
          };
          frame.__isonimApplyPreviewVariants = apply;
          if (!frame.__isonimPreviewVariantListenerInstalled) {
            frame.__isonimPreviewVariantListenerInstalled = true;
            frame.addEventListener('load', () => {
              if (frame.__isonimApplyPreviewVariants) {
                frame.__isonimApplyPreviewVariants();
              }
            });
          }
          requestAnimationFrame(apply);
        })(""", frame, ", ", variantScript, """);
      """].}
      {.emit: ["""
        const frame = """, frame,
          """;
        if (frame && !frame.__isonimAutoHeightInstalled) {
          frame.__isonimAutoHeightInstalled = true;
          frame.style.overflow = 'hidden';
          frame.setAttribute('scrolling', 'no');
          const resizeFrame = () => {
            try {
              const doc = frame.contentDocument;
              if (!doc) return;
              const body = doc.body;
              const html = doc.documentElement;
              if (!body || !html) return;
              body.style.overflow = 'hidden';
              html.style.overflow = 'hidden';
              const height = Math.max(
                body.scrollHeight, body.offsetHeight,
                html.clientHeight, html.scrollHeight, html.offsetHeight
              );
              frame.style.height = `${height}px`;
              frame.setAttribute('height', String(height));
            } catch (_) {
              // Cross-origin frames keep their declared height.
            }
          };
          frame.addEventListener('load', resizeFrame);
          requestAnimationFrame(resizeFrame);
        } else if (frame) {
          requestAnimationFrame(() => {
            try {
              const doc = frame.contentDocument;
              const body = doc?.body;
              const html = doc?.documentElement;
              if (!body || !html) return;
              body.style.overflow = 'hidden';
              html.style.overflow = 'hidden';
              const height = Math.max(
                body.scrollHeight, body.offsetHeight,
                html.clientHeight, html.scrollHeight, html.offsetHeight
              );
              frame.style.height = `${height}px`;
              frame.setAttribute('height', String(height));
            } catch (_) {}
          });
        }
      """].}

  # === Props / API Table ===
  let propsLabel = sectionLabel[R, E](r, "PROPERTIES")
  r.appendChild(content, propsLabel)

  let propsTable = ui(r):
    tdiv(background_color = bgCard, border = "1px solid " & border,
          border_radius = "8px", overflow = "hidden"):
      tdiv(display = "flex", padding = "8px 16px",
            background_color = bgSurface,
            border_bottom = "1px solid " & border):
        span(width = "120px", font_size = "10px", font_weight = "600",
              color = textSecondary):
          text "Name"
        span(width = "100px", font_size = "10px", font_weight = "600",
              color = textSecondary):
          text "Type"
        span(width = "80px", font_size = "10px", font_weight = "600",
              color = textSecondary):
          text "Default"
        span(flex = "1", font_size = "10px", font_weight = "600",
              color = textSecondary):
          text "Description"
  r.appendChild(content, propsTable)

  let propDefs = @[
    ("name", "string", "\"\"", "Destination display name"),
    ("country", "string", "\"\"", "Country name"),
    ("tagline", "string", "\"\"", "Short description shown below name"),
    ("rating", "float", "0.0", "Star rating (0.0 - 5.0)"),
    ("reviewCount", "int", "0", "Number of user reviews"),
    ("pricePerNight", "int", "0", "Average price per night in USD"),
    ("tags", "seq[string]", "@[]", "Category tags (Beach, Culture, etc.)"),
    ("isSaved", "bool", "false", "Whether user has saved this destination"),
  ]
  for prop in propDefs:
    let n = prop[0]; let t = prop[1]; let d = prop[2]; let desc = prop[3]
    let row = ui(r):
      tdiv(display = "flex", padding = "8px 16px",
            border_bottom = "1px solid " & borderFaint):
        span(width = "120px", font_size = "12px", color = accent,
              font_family = "'JetBrains Mono', monospace"):
          text n
        span(width = "100px", font_size = "11px", color = textMuted,
              font_family = "monospace"):
          text t
        span(width = "80px", font_size = "11px", color = textDim,
              font_family = "monospace"):
          text d
        span(flex = "1", font_size = "11px", color = textSecondary):
          text desc
    r.appendChild(propsTable, row)

  # === Usage Guidelines ===
  let guideLabel = sectionLabel[R, E](r, "USAGE GUIDELINES")
  r.appendChild(content, guideLabel)

  let guidelines = @[
    (true, "Use DestinationCard in a scrollable grid or carousel for discovery"),
    (false, "Use DestinationCard for trip itinerary items — use TripCard instead"),
    (true, "Show the save heart icon on all cards to encourage wishlisting"),
    (false, "Truncate the tagline — let it wrap to 2 lines naturally"),
    (true, "Show tags relevant to the user's search filters"),
    (false, "Show more than 4 tags — it clutters the card"),
  ]
  for guideline in guidelines:
    let isDo = guideline[0]; let gdesc = guideline[1]
    let rule = ui(r):
      tdiv(display = "flex", align_items = "center", gap = "10px",
            padding = "10px 16px", background_color = bgCard,
            border_radius = "6px",
            border_left = (if isDo: "3px solid " & green else: "3px solid " & red)):
        span(font_size = "12px", font_weight = "600",
              color = (if isDo: green else: red)):
          text(if isDo: "\xE2\x9C\x93 Do" else: "\xC3\x97 Don't")
        span(font_size = "12px", color = textSecondary):
          text gdesc
    r.appendChild(content, rule)

  # === Accessibility ===
  let a11yLabel = sectionLabel[R, E](r, "ACCESSIBILITY")
  r.appendChild(content, a11yLabel)

  let a11yNotes = @[
    ("Keyboard", "Tab focuses the card, Enter opens detail, Space toggles save"),
    ("ARIA", "role=\"article\" with aria-label for destination name and rating"),
    ("Screen Reader", "Announces: name, country, rating, price, saved status"),
    ("Color", "Rating stars use both color and shape; save uses fill and icon change"),
  ]
  for a11yNote in a11yNotes:
    let atopic = a11yNote[0]; let adesc = a11yNote[1]
    let note = ui(r):
      tdiv(display = "flex", align_items = "flex-start", gap = "10px",
            padding = "10px 16px", background_color = bgCard,
            border_radius = "6px"):
        tdiv(padding = "2px 8px", border_radius = "4px",
              background_color = bgSurface, font_size = "10px",
              font_weight = "600", color = textSecondary,
              white_space = "nowrap"):
          text atopic
        span(font_size = "12px", color = textSecondary, line_height = "1.4"):
          text adesc
    r.appendChild(content, note)

  # === Related ===
  let relLabel = sectionLabel[R, E](r, "RELATED")
  r.appendChild(content, relLabel)

  let relGrid = ui(r):
    tdiv(display = "flex", gap = "12px"):
      for rel in ["TripCard", "SearchBar", "FilterChip", "ReviewCard"]:
        tdiv(padding = "10px 16px", background_color = bgCard,
              border = "1px solid " & border, border_radius = "6px",
              cursor = "pointer"):
          span(font_size = "12px", color = accent):
            text rel
  r.appendChild(content, relGrid)

  r.appendChild(page, content)
  page
