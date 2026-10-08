## Phase G — Layout section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * Layout mode — 4-button row (none / vertical / horizontal / grid),
##     mapping to CSS ``display: block | flex-column | flex-row | grid``.
##   * W / H — numeric inputs (px unit).
##   * Constraint icon — placeholder square.
##   * Gap — numeric, visible only when flex or grid.
##   * Padding — four numeric inputs (top / right / bottom / left).
##   * Overflow — segmented choice (visible / hidden / scroll / auto).

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/core/owner
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_position

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  border = "#2A2C3A"
  accent = "#7C7AED"

const
  pxUnit = PropertyUnitOption(label: "px", code: "px")

func layoutModeFor*(display, direction: string): string =
  if display in ["grid", "inline-grid"]: "grid"
  elif display in ["flex", "inline-flex"]:
    if direction in ["column", "column-reverse"]: "vertical" else: "horizontal"
  else: "none"

func layoutModeChanges*(display, direction, wanted: string): seq[tuple[property, value: string]] =
  let current = layoutModeFor(display, direction)
  if current == wanted: return
  let inline = display.startsWith("inline")
  let wantedDisplay =
    if wanted == "none": "block"
    elif wanted == "grid": (if inline: "inline-grid" else: "grid")
    else: (if inline: "inline-flex" else: "flex")
  let wantedDirection = (if wanted == "vertical": "column" else: "row") &
    (if direction.endsWith("-reverse"): "-reverse" else: "")
  if display != wantedDisplay: result.add ("display", wantedDisplay)
  if wanted in ["vertical", "horizontal"] and direction != wantedDirection:
    result.add ("flex-direction", wantedDirection)

proc mountSectionLayout*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Layout section body. The widget owns its own local
  ## signals so a selection change rebinds the seeds via a render
  ## effect rather than re-mounting the DOM tree.
  let layoutMode = createSignal("block")
  let width = createSignal(0.0)
  let height = createSignal(0.0)
  let widthUnit = createSignal(pxUnit)
  let heightUnit = createSignal(pxUnit)
  let gap = createSignal(0.0)
  let gapUnit = createSignal(pxUnit)
  let padTop = createSignal(0.0)
  let padRight = createSignal(0.0)
  let padBottom = createSignal(0.0)
  let padLeft = createSignal(0.0)
  let padTopUnit = createSignal(pxUnit)
  let padRightUnit = createSignal(pxUnit)
  let padBottomUnit = createSignal(pxUnit)
  let padLeftUnit = createSignal(pxUnit)
  let overflow = createSignal("visible")
  let modeMessage = createSignal("")
  var modeAlive = true
  var modePending = false
  onCleanup(proc() = modeAlive = false)


  createRenderEffect proc() =
    discard vm.selectedStory.val
    let props = vm.inspector.properties.val
    modeMessage.val = ""
    let display = findPropertyValue(props, "display", "block")
    let flexDir = findPropertyValue(props, "flex-direction", "row")
    layoutMode.val = layoutModeFor(display, flexDir)
    width.val = parseLeadingFloat(findPropertyValue(props, "width", "0"), 0.0)
    height.val = parseLeadingFloat(findPropertyValue(props, "height", "0"), 0.0)
    gap.val = parseLeadingFloat(findPropertyValue(props, "gap", "0"), 0.0)
    padTop.val = parseLeadingFloat(findPropertyValue(props, "padding-top",
      findPropertyValue(props, "padding", "0")), 0.0)
    padRight.val = parseLeadingFloat(findPropertyValue(props, "padding-right",
      findPropertyValue(props, "padding", "0")), 0.0)
    padBottom.val = parseLeadingFloat(findPropertyValue(props, "padding-bottom",
      findPropertyValue(props, "padding", "0")), 0.0)
    padLeft.val = parseLeadingFloat(findPropertyValue(props, "padding-left",
      findPropertyValue(props, "padding", "0")), 0.0)
    overflow.val = findPropertyValue(props, "overflow", "visible")

  # ----- Layout mode button row ------------------------------------ #
  # Four icon buttons. The active one carries ``data-layout-mode-
  # active="true"`` so the per-section test can pin the choice.
  var modeButtons: array[4, E]
  let modes = ["none", "vertical", "horizontal", "grid"]
  let modeGlyphs = ["\xE2\x9A\xAC", "\xE2\x86\x95",
                    "\xE2\x86\x94", "\xE2\x96\xA6"]
  # Phase H (2026-05-28): pack the 4 mode buttons inside a single
  # tinted trough so the cluster reads as a tightly-segmented
  # control rather than a row of 4 individually-bordered buttons.
  # Mirrors the alignment-cluster pattern used in section_position
  # and the Figma reference.
  let modeRow = ui(r):
    tdiv(`data-layout-mode-row` = "true",
         display = "flex", flex_direction = "row",
         background_color = "#1A1B22",
         border_radius = "4px",
         padding = "1px",
         margin = "2px 0"):
      for i, slug in modes:
        button(ref = modeButtons[i], `type` = "button", border = "none",
              role = "button", tabindex = "0",
              `data-layout-mode` = slug,
              `aria-label` = "Set layout to " & slug,
              title = "Set layout to " & slug,
              display = "flex", align_items = "center",
              justify_content = "center",
              flex = "1", height = "24px",
              border_radius = "3px",
              color = textMuted, font_size = "12px", cursor = "pointer"):
          text modeGlyphs[i]
  r.appendChild(parent, modeRow)
  var modeDiagnostic: E
  let diagnostic = ui(r):
    tdiv(ref = modeDiagnostic, `data-layout-mode-message` = "true", role = "status",
         `aria-live` = "polite", color = textMuted, font_size = "11px"):
      text modeMessage.val
  r.appendChild(parent, diagnostic)

  proc bindModeClick(btn: E; slug: string) =
    let activate = proc() =
      if not modeAlive or modePending: return
      if not vm.workspacePermissions.val.writeSource:
        modeMessage.val = "This workspace is read-only for source changes."
        return
      if not vm.hasAsyncSourceProject:
        layoutMode.val = slug # Explicit preview/library composition.
        return
      if not vm.sourceAdapterReady.val:
        modeMessage.val = "Loading editable properties."
        return
      let props = vm.inspector.properties.val
      let display = findPropertyValue(props, "display", "block")
      let direction = findPropertyValue(props, "flex-direction", "row")
      let changes = layoutModeChanges(display, direction, slug)
      if changes.len == 0:
        modeMessage.val = ""
        return
      if changes.len != 1:
        modeMessage.val = "The editor cannot safely change both layout declarations together yet."
        return
      let change = changes[0]
      let wiring = vm.inspectorRowWiring(change.property)
      let reason = wiring.readOnlyReason()
      if reason.len > 0:
        modeMessage.val = reason
        return
      # One existing guarded native operation. Compound changes never issue two
      # independent writes or optimistically change the active layout pill.
      let story = vm.selectedStory.val
      let selected = vm.inspector.selectedElement.val.id
      modePending = true
      wiring.commitAsync(change.value, proc(ok: bool) =
        modePending = false
        if not modeAlive or vm.selectedStory.val != story or
            vm.inspector.selectedElement.val.id != selected: return
        if ok:
          layoutMode.val = slug
          modeMessage.val = ""
        else:
          modeMessage.val = wiring.commitMessage.val)
    createRenderEffect proc() =
      let props = vm.inspector.properties.val
      let changes = layoutModeChanges(findPropertyValue(props, "display", "block"),
        findPropertyValue(props, "flex-direction", "row"), slug)
      var reason = ""
      if not vm.workspacePermissions.val.writeSource: reason = "This workspace is read-only for source changes."
      elif vm.hasAsyncSourceProject:
        if not vm.sourceAdapterReady.val: reason = "Loading editable properties."
        elif changes.len > 1: reason = "The editor cannot safely change both layout declarations together yet."
        elif changes.len == 1: reason = vm.inspectorRowWiring(changes[0].property).readOnlyReason()
      r.setAttribute(btn, "aria-disabled", if reason.len > 0: "true" else: "false")
      r.setAttribute(btn, "title", if reason.len > 0: reason else: "Set layout to " & slug)
    r.addEventListener(btn, "click", activate)
    when defined(js):
      # Actual button semantics produce one click for Enter/Space. Stop editor
      # shortcuts while preserving native activation and Tab/Escape navigation.
      var removeKeys: proc() {.closure.}
      {.emit: ["if(typeof ",btn,".addEventListener==='function'){const button=",btn,";function key(e){if(e.key==='Enter'||e.key===' '||e.key==='Escape')e.stopPropagation();}button.addEventListener('keydown',key);",removeKeys,"=()=>button.removeEventListener('keydown',key);}"].}
      onCleanup(proc() =
        if removeKeys != nil: removeKeys())
  for i, slug in modes:
    bindModeClick(modeButtons[i], slug)
  # Phase H: the active mode pill now reads as a quiet raised inset
  # (matching the Figma reference's near-white pill in light theme).
  # In our dark theme we lift the active mode to ``#262838`` — a
  # subtle elevation above the trough's ``#1A1B22`` — and pair it
  # with a faint hairline to mimic Figma's chip border. The previous
  # accent (#7C7AED) violet pill competed with the much more
  # consequential variable-binding accent elsewhere in the panel.
  createRenderEffect proc() =
    let active = layoutMode.val
    for i, slug in modes:
      let isActive = slug == active
      r.setAttribute(modeButtons[i], "data-layout-mode-active",
        if isActive: "true" else: "false")
      r.setStyle(modeButtons[i], "background-color",
        if isActive: "#262838" else: "transparent")
      r.setStyle(modeButtons[i], "color",
        if isActive: textPrimary else: textMuted)
      r.setStyle(modeButtons[i], "box-shadow",
        if isActive: "0 0 0 1px #2A2C3A" else: "none")

  # ----- W / H + constraint icon row ------------------------------- #
  # Two numeric rows + a placeholder constraint glyph. The glyph is a
  # data marker for the per-section test; Phase G+1 wires a real
  # constraint editor.
  # A width without its height is half a question.
  discard r.mountPropertyRowPair(parent,
    propertyRowNumeric(
    name = "W", value = width, unit = widthUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("width"),
    onBindRequest = vm.inspectorBindRequestHandler("width"),
    onDetachRequest = vm.inspectorDetachRequestHandler("width"),
    wiring = vm.inspectorRowWiring("width")),
    propertyRowNumeric(
    name = "H", value = height, unit = heightUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("height"),
    onBindRequest = vm.inspectorBindRequestHandler("height"),
    onDetachRequest = vm.inspectorDetachRequestHandler("height"),
    wiring = vm.inspectorRowWiring("height")))
  # Phase H (2026-05-28): the constraint indicator reads as a quiet
  # icon-and-hint row. The Figma reference puts the constraint
  # affordance as a small bracket glyph on the right edge next to W/H;
  # we keep the row for the headless test contract but render it
  # without the bordered chrome that competed with the alignment
  # cluster pills above.
  let constraintRow = ui(r):
    tdiv(`data-layout-constraint` = "true",
         display = "flex", align_items = "center", gap = "6px",
         padding = "2px 0", font_size = "11px", color = textMuted):
      tdiv(width = "18px", height = "18px",
            display = "flex", align_items = "center",
            justify_content = "center",
            color = textMuted):
        text "\xE2\x9F\x8B"
      text "Constraints (auto)"
  r.appendChild(parent, constraintRow)

  # ----- Gap (visible only for flex / grid) ------------------------ #
  var gapHostEl: E
  let gapHost = ui(r):
    tdiv(ref = gapHostEl,
         `data-layout-gap-host` = "true",
         display = "flex", flex_direction = "column")
  r.appendChild(parent, gapHost)
  discard r.mountPropertyRow(gapHostEl, propertyRowNumeric(
    name = "Gap", value = gap, unit = gapUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("gap"),
    onBindRequest = vm.inspectorBindRequestHandler("gap"),
    onDetachRequest = vm.inspectorDetachRequestHandler("gap"),
    wiring = vm.inspectorRowWiring("gap")))
  createRenderEffect proc() =
    let m = layoutMode.val
    let visible = m in ["vertical", "horizontal", "grid"]
    r.setStyle(gapHostEl, "display", if visible: "flex" else: "none")

  # ----- Padding (4 sides) ----------------------------------------- #
  var padHostEl: E
  let padHost = ui(r):
    tdiv(ref = padHostEl,
         `data-layout-padding-host` = "true",
         display = "flex", flex_direction = "column")
  r.appendChild(parent, padHost)
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad top", value = padTop, unit = padTopUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("padding-top"),
    onBindRequest = vm.inspectorBindRequestHandler("padding-top"),
    onDetachRequest = vm.inspectorDetachRequestHandler("padding-top"),
    wiring = vm.inspectorRowWiring("padding-top")))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad right", value = padRight, unit = padRightUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("padding-right"),
    onBindRequest = vm.inspectorBindRequestHandler("padding-right"),
    onDetachRequest = vm.inspectorDetachRequestHandler("padding-right"),
    wiring = vm.inspectorRowWiring("padding-right")))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad bottom", value = padBottom, unit = padBottomUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("padding-bottom"),
    onBindRequest = vm.inspectorBindRequestHandler("padding-bottom"),
    onDetachRequest = vm.inspectorDetachRequestHandler("padding-bottom"),
    wiring = vm.inspectorRowWiring("padding-bottom")))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad left", value = padLeft, unit = padLeftUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("padding-left"),
    onBindRequest = vm.inspectorBindRequestHandler("padding-left"),
    onDetachRequest = vm.inspectorDetachRequestHandler("padding-left"),
    wiring = vm.inspectorRowWiring("padding-left")))
  # ----- Overflow choice ------------------------------------------- #
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Overflow", value = overflow,
    options = @[
      (label: "Visible", value: "visible"),
      (label: "Hidden", value: "hidden"),
      (label: "Scroll", value: "scroll"),
      (label: "Auto", value: "auto")],
    bindingReactive = vm.inspectorBindingThunk("overflow"),
    onBindRequest = vm.inspectorBindRequestHandler("overflow"),
    onDetachRequest = vm.inspectorDetachRequestHandler("overflow"),
    wiring = vm.inspectorRowWiring("overflow")))
