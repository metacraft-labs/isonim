## The Layout section's auto layout, grid, constraint and responsive override
## controls.
##
## Editor spec "Full CSS Property Inspector": "The layout section exposes
## `display`, flex, grid, positioning, sizing, constraints, overflow, and
## responsive overrides as source-backed CSS concepts"; "Section catalogue":
## Layout owns the layout mode and "W/H + constraint"; "Contextual
## sub-panels -- selecting Flex display reveals flex controls; Grid reveals
## track editor"; "Behavioural invariants": layout semantics stay close to CSS.
## The clauses that say what each control is and how it commits are in the
## spec's "Layout auto layout, grid, constraint and responsive controls".
##
## Three entry points sit in the section itself:
##
## * `Enable flex wrap`, a pressed / unpressed button after the layout mode
##   row, sets `flex-wrap` to `wrap` or back to `nowrap` on a flex layout;
## * `Set grid template tracks`, after it, opens the controls at the grid
##   track editor on a grid layout;
## * `Set left right top bottom constraints`, beside W/H, opens them at the
##   constraints.
##
## A button that does not apply to the selection's layout says why (its title
## and `aria-disabled`) and, pressed, shows that reason in the section.
##
## The controls themselves are a disclosure (`Show layout auto grid
## constraint controls`), closed when the editor opens and remembered for the
## session (`InspectorVM.layoutControlsShown`). Its header shows the
## responsive mode the preview is in. Open, it has four groups, each a set of
## ordinary property rows -- the same rows, wirings, scopes, validation,
## refusals, undo and automatic write as every other inspector row:
##
## * Auto layout (flex layouts only): Wrap, Align (`align-items`), Justify
##   (`justify-content`);
## * Grid (grid layouts only): Columns and Rows (`grid-template-columns`,
##   `grid-template-rows`, track lists as CSS text) and Flow
##   (`grid-auto-flow`);
## * Constraints: Position, the Top / Right / Bottom / Left insets, and Min /
##   Max width and height;
## * Responsive overrides: a declaration of one Layout property written for
##   Tablet or Mobile only (`viewmodels.commitResponsiveOverride`).
##
## A row is shown only while the selection exposes its property. The rows
## register with the section's raw CSS and search like every row; the
## disclosure registers its own search text so a search for any of them
## finds Layout.

import std/[options, strutils]

import isonim/core/[signals, computation, owner]
from isonim/core/batch import untrack
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/choice_row
import ./property_commit
import ./property_row
import ./inspector_search
import ./section_position
import ./section_raw_css

const
  layoutControlsToggleLabel* = "Show layout auto grid constraint controls"
  flexWrapToggleLabel* = "Enable flex wrap"
  gridTracksLabel* = "Set grid template tracks"
  constraintsLabel* = "Set left right top bottom constraints"
  layoutControlsSearchText* = "Auto layout grid tracks constraints " &
    "responsive overrides flex-wrap align-items justify-content " &
    "grid-template-columns grid-template-rows grid-auto-flow position top " &
    "right bottom left min-width max-width min-height max-height"
    ## What the inspector search finds the disclosure by: what it edits.
  responsiveOverrideProperties* = ["gap", "flex-direction", "flex-wrap",
    "align-items", "justify-content", "grid-template-columns",
    "grid-template-rows", "grid-auto-flow", "padding", "min-width",
    "max-width", "min-height", "max-height", "overflow"]
    ## The Layout properties a responsive override can be set for, in the
    ## order its property choice lists them; only those the selection
    ## exposes are offered. They are the Layout families a class rule has a
    ## tested shared writer for (`viewmodels.sharedDesignCategory`): an
    ## override is a class rule's declaration, so `display`, `width` and
    ## `height`, which have none, are not offered.
  flexWrapReason* = "Flex wrap applies to a flex layout. Set the layout to " &
    "vertical or horizontal first."
  gridTracksReason* = "Grid tracks apply to a grid layout. Set the layout " &
    "to grid first."

  textPrimary = "#ECEDF3"
  textMuted = "#6B6F80"
  border = "#2A2C3A"
  accent = "#7C7AED"
  danger = "#F87171"
  trough = "#1A1B22"

func responsiveOverrideLabel*(mode: string): string =
  ## The accessible name of the button that writes an override for ``mode``.
  "Set responsive override for " & mode & " mode"

func isFlexLayout*(mode: string): bool =
  ## ``mode`` is one of `section_layout.layoutModeFor`'s slugs.
  mode in ["vertical", "horizontal"]

func flexWrapPressed*(value: string): bool =
  ## Whether `flex-wrap: <value>` wraps.
  value.strip() in ["wrap", "wrap-reverse"]

func flexWrapNext*(value: string): string =
  ## The `flex-wrap` value pressing `Enable flex wrap` commits.
  if flexWrapPressed(value): "nowrap" else: "wrap"

type
  LayoutControlsFocus* = ref object
    ## How the section's entry points open the controls at a group: set by
    ## `mountLayoutControls`, called by the buttons mounted before it.
    focusGroup*: proc(slug: string)

proc newLayoutControlsFocus*(): LayoutControlsFocus =
  LayoutControlsFocus(focusGroup: proc(slug: string) = discard)

template stopLayoutPropagation(ev: untyped) =
  mixin stopPropagation
  when compiles(ev.stopPropagation()):
    ev.stopPropagation()
  elif defined(js):
    proc stop(event: typeof(ev)) {.importjs: "#.stopPropagation()".}
    stop(ev)

template stopLayoutKeys(r, node: untyped) =
  ## Native button activation gives Enter and Space one click each; keep the
  ## editor's own shortcuts from seeing them.
  r.addEventListener(node, "keydown", proc(ev: auto) =
    if inspectorSearchKey(ev) in ["Enter", " "]: stopLayoutPropagation(ev))

proc mountLayoutModeExtras*[R, E](r: R; parent: E; vm: EditorVM;
    layoutMode: Signal[string]; message: Signal[string];
    wrapWiring: InspectorRowWiring; focus: LayoutControlsFocus) =
  ## `Enable flex wrap` and `Set grid template tracks`, after the layout mode
  ## row. ``message`` is the section's layout message line; ``wrapWiring``
  ## is the Wrap row's, so the toggle and the row commit at one scope.
  var wrapButton, tracksButton: E
  let extras = ui(r):
    tdiv(`data-layout-mode-extras` = "true",
         display = "flex", flex_direction = "row",
         background_color = trough, border_radius = "4px",
         padding = "1px", margin = "2px 0", gap = "1px"):
      button(ref = wrapButton, `type` = "button", border = "none",
             `data-layout-wrap-toggle` = "true",
             `data-isonim-focus-id` = "layout-wrap-toggle",
             `aria-label` = flexWrapToggleLabel,
             `aria-pressed` = "false",
             display = "flex", align_items = "center",
             justify_content = "center", width = "28px", height = "24px",
             border_radius = "3px", background_color = "transparent",
             color = textMuted, font_size = "12px", cursor = "pointer"):
        text "\xE2\x86\xA9"
      button(ref = tracksButton, `type` = "button", border = "none",
             `data-layout-grid-tracks` = "true",
             `data-isonim-focus-id` = "layout-grid-tracks",
             `aria-label` = gridTracksLabel,
             display = "flex", align_items = "center",
             justify_content = "center", width = "28px", height = "24px",
             border_radius = "3px", background_color = "transparent",
             color = textMuted, font_size = "12px", cursor = "pointer"):
        text "\xE2\x96\xA5"
  r.appendChild(parent, extras)

  var alive = true
  var pending = false
  onCleanup(proc() = alive = false)

  proc wrapValue(): string =
    findPropertyValue(vm.inspector.properties.val, "flex-wrap", "nowrap")

  proc wrapReason(): string =
    if not isFlexLayout(layoutMode.val): return flexWrapReason
    if vm.inspectorProperty("flex-wrap").isNone:
      return "The selected element does not expose flex-wrap."
    if wrapWiring.readOnlyReason != nil: wrapWiring.readOnlyReason() else: ""

  proc tracksReason(): string =
    if layoutMode.val != "grid": gridTracksReason else: ""

  createRenderEffect proc() =
    let pressed = flexWrapPressed(wrapValue())
    let reason = wrapReason()
    r.setAttribute(wrapButton, "aria-pressed", if pressed: "true" else: "false")
    r.setAttribute(wrapButton, "aria-disabled",
      if reason.len > 0: "true" else: "false")
    r.setAttribute(wrapButton, "title",
      if reason.len > 0: reason
      else: "Wrap children onto new lines (flex-wrap: wrap)")
    r.setStyle(wrapButton, "background-color",
      if pressed: "#262838" else: "transparent")
    r.setStyle(wrapButton, "color",
      if pressed: textPrimary elif reason.len > 0: "#3A3D4D" else: textMuted)
  createRenderEffect proc() =
    let reason = tracksReason()
    r.setAttribute(tracksButton, "aria-disabled",
      if reason.len > 0: "true" else: "false")
    r.setAttribute(tracksButton, "title",
      if reason.len > 0: reason
      else: "Edit the grid's column and row tracks (grid-template-columns, grid-template-rows)")
    r.setStyle(tracksButton, "color",
      if reason.len > 0: "#3A3D4D" else: textMuted)

  r.addEventListener(wrapButton, "click", proc() =
    if not alive or pending: return
    let reason = untrack(proc(): string = wrapReason())
    if reason.len > 0:
      message.val = reason
      return
    let next = flexWrapNext(untrack(proc(): string = wrapValue()))
    let story = vm.selectedStory.val
    let selected = vm.inspector.selectedElement.val.id
    pending = true
    wrapWiring.commitAsync(next, proc(ok: bool) =
      pending = false
      if not alive or vm.selectedStory.val != story or
          vm.inspector.selectedElement.val.id != selected: return
      message.val = if ok: "" else: wrapWiring.commitMessage.val))
  r.addEventListener(tracksButton, "click", proc() =
    if not alive: return
    let reason = untrack(proc(): string = tracksReason())
    if reason.len > 0:
      message.val = reason
      return
    message.val = ""
    focus.focusGroup("grid"))
  stopLayoutKeys(r, wrapButton)
  stopLayoutKeys(r, tracksButton)

proc mountLayoutConstraintButton*[R, E](r: R; parent: E; vm: EditorVM;
    focus: LayoutControlsFocus) =
  ## The constraint control beside W/H: names the selection's positioning
  ## and opens the controls at the constraints.
  var button, summary: E
  let row = ui(r):
    tdiv(`data-layout-constraint` = "true",
         display = "flex", align_items = "center", gap = "6px",
         padding = "2px 0", font_size = "11px", color = textMuted):
      button(ref = button, `type` = "button",
             `data-layout-constraint-button` = "true",
             `data-isonim-focus-id` = "layout-constraints",
             `aria-label` = constraintsLabel,
             title = "Edit the position, insets and minimum and maximum size",
             display = "flex", align_items = "center", gap = "6px",
             height = "22px", padding = "0 4px",
             border = "1px solid transparent", border_radius = "4px",
             background_color = "transparent", color = textMuted,
             font_family = "inherit", font_size = "11px", cursor = "pointer"):
        span(width = "18px", display = "flex", justify_content = "center"):
          text "\xE2\x9F\x8B"
        span(ref = summary, `data-layout-constraint-summary` = "true"):
          text "Constraints"
  r.appendChild(parent, row)
  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    let position = findPropertyValue(props, "position", "")
    r.setTextContent(summary,
      if position.len > 0: "Constraints \xC2\xB7 " & position else: "Constraints")
  r.addEventListener(button, "click", proc() = focus.focusGroup("constraints"))
  stopLayoutKeys(r, button)

proc mountLayoutControls*[R, E](r: R; parent: E; vm: EditorVM;
    layoutMode: Signal[string]; wrapWiring: InspectorRowWiring;
    focus: LayoutControlsFocus) =
  ## The disclosure and its four groups, at the end of ``parent``.
  var toggle, toggleText, modeTag, panel: E
  var autoGroup, autoRows, autoNote: E
  var gridGroup, gridRows, gridNote: E
  var constraintsGroup, constraintRows: E
  var responsiveGroup, overrideProperty, overrideValue, overrideScope: E
  var overrideModes, overrideMessage: E
  let host = ui(r):
    tdiv(`data-layout-controls-host` = "true",
         display = "flex", flex_direction = "column", gap = "4px",
         padding_top = "4px", min_width = "0"):
      button(ref = toggle, `type` = "button",
             `data-layout-controls-toggle` = "true",
             `data-isonim-focus-id` = "layout-controls-toggle",
             `aria-label` = layoutControlsToggleLabel,
             `aria-expanded` = "false",
             display = "flex", align_items = "center", gap = "6px",
             height = "22px", padding = "0 4px",
             border = "1px solid transparent", border_radius = "4px",
             background_color = "transparent", color = textMuted,
             font_family = "inherit", font_size = "11px",
             cursor = "pointer", text_align = "left"):
        span(ref = toggleText):
          text "\xE2\x96\xB8 Auto layout, grid, constraints"
        span(ref = modeTag, `data-layout-responsive-mode` = "true",
             title = "The responsive mode the preview is showing",
             margin_left = "auto", color = accent,
             font_family = "monospace", font_size = "10px"):
          text ""
      tdiv(ref = panel, `data-layout-controls` = "true",
           role = "group", `aria-label` = "Auto layout, grid and constraints",
           display = "none", flex_direction = "column", gap = "8px",
           min_width = "0"):
        tdiv(ref = autoGroup, `data-layout-controls-group` = "auto-layout",
             role = "group", `aria-label` = "Auto layout", tabindex = "-1",
             display = "flex", flex_direction = "column", gap = "2px",
             min_width = "0", outline = "none"):
          span(font_size = "10px", font_weight = "600", color = textMuted,
               text_transform = "uppercase", letter_spacing = "0.4px"):
            text "Auto layout"
          tdiv(ref = autoRows, `data-layout-controls-rows` = "auto-layout",
               display = "flex", flex_direction = "column",
               min_width = "0")
          span(ref = autoNote, `data-layout-controls-note` = "auto-layout",
               font_size = "10px", color = textMuted):
            text "Auto layout applies to a vertical or horizontal layout."
        tdiv(ref = gridGroup, `data-layout-controls-group` = "grid",
             role = "group", `aria-label` = "Grid tracks", tabindex = "-1",
             display = "flex", flex_direction = "column", gap = "2px",
             min_width = "0", outline = "none"):
          span(font_size = "10px", font_weight = "600", color = textMuted,
               text_transform = "uppercase", letter_spacing = "0.4px"):
            text "Grid tracks"
          tdiv(ref = gridRows, `data-layout-controls-rows` = "grid",
               display = "flex", flex_direction = "column",
               min_width = "0")
          span(ref = gridNote, `data-layout-controls-note` = "grid",
               font_size = "10px", color = textMuted):
            text "Grid tracks apply to a grid layout."
        tdiv(ref = constraintsGroup, `data-layout-controls-group` = "constraints",
             role = "group", `aria-label` = "Constraints", tabindex = "-1",
             display = "flex", flex_direction = "column", gap = "2px",
             min_width = "0", outline = "none"):
          span(font_size = "10px", font_weight = "600", color = textMuted,
               text_transform = "uppercase", letter_spacing = "0.4px"):
            text "Constraints"
          tdiv(ref = constraintRows, `data-layout-controls-rows` = "constraints",
               display = "flex", flex_direction = "column",
               min_width = "0")
        tdiv(ref = responsiveGroup, `data-layout-controls-group` = "responsive",
             role = "group", `aria-label` = "Responsive overrides",
             tabindex = "-1",
             display = "flex", flex_direction = "column", gap = "4px",
             min_width = "0", outline = "none"):
          span(font_size = "10px", font_weight = "600", color = textMuted,
               text_transform = "uppercase", letter_spacing = "0.4px"):
            text "Responsive overrides"
          tdiv(ref = overrideProperty, min_width = "0")
          input(ref = overrideValue, `type` = "text",
                `data-layout-override-value` = "true",
                `aria-label` = "Responsive override value",
                title = "The value the override sets; empty removes the override",
                height = "24px", padding = "0 8px", min_width = "0",
                border = "1px solid " & border, border_radius = "6px",
                background_color = trough, color = textPrimary,
                font_family = "inherit", font_size = "12px")
          tdiv(ref = overrideModes, `data-layout-override-modes` = "true",
               display = "grid",
               grid_template_columns = "repeat(2, minmax(0, 1fr))",
               gap = "4px", min_width = "0")
          tdiv(ref = overrideScope, `data-layout-override-scope` = "true",
               role = "note", font_size = "10px", color = textMuted,
               overflow_wrap = "anywhere")
          tdiv(ref = overrideMessage, `data-layout-override-message` = "true",
               role = "status", `aria-live` = "polite",
               font_size = "11px", color = textMuted,
               overflow_wrap = "anywhere")
  r.appendChild(parent, host)

  var alive = true
  onCleanup(proc() = alive = false)

  # ----- The disclosure -------------------------------------------- #
  createRenderEffect proc() =
    let shown = vm.inspector.layoutControlsShown.val
    r.setAttribute(toggle, "aria-expanded", if shown: "true" else: "false")
    r.setStyle(panel, "display", if shown: "flex" else: "none")
    r.setTextContent(toggleText,
      (if shown: "\xE2\x96\xBE" else: "\xE2\x96\xB8") &
        " Auto layout, grid, constraints")
    r.setStyle(toggle, "color", if shown: textPrimary else: textMuted)
  createRenderEffect proc() =
    r.setTextContent(modeTag, layoutModeKey(vm.viewport.val))
  r.addEventListener(toggle, "click", proc() =
    vm.inspector.toggleLayoutControls())
  stopLayoutKeys(r, toggle)

  focus.focusGroup = proc(slug: string) =
    if not alive: return
    if not vm.inspector.layoutControlsShown.val:
      vm.inspector.layoutControlsShown.val = true
    let group =
      case slug
      of "grid": gridGroup
      of "constraints": constraintsGroup
      of "responsive": responsiveGroup
      else: autoGroup
    r.focus(group)

  let search = registerInspectorSearchText(layoutControlsSearchText)
  if search != nil:
    createRenderEffect proc() =
      let hit = searchTextMatches(layoutControlsSearchText, search.query())
      r.setAttribute(toggle, "data-inspector-search-match",
        if hit: "true" else: "false")
      r.setStyle(toggle, "background-color",
        if hit: "rgba(124, 122, 237, 0.16)" else: "transparent")

  # ----- Rows (mounted when the controls are first opened) --------- #
  # Each row's wiring exists from the start and joins the section's raw CSS
  # at once, so a closed disclosure still leaves its properties in Layout's
  # raw CSS; the rows themselves, the costly part, are mounted the first time
  # the controls are opened (story selection is measured: "Performance
  # budgets") and then kept.
  const rowProperties = ["align-items", "justify-content",
    "grid-template-columns", "grid-template-rows", "grid-auto-flow",
    "position", "top", "right", "bottom", "left", "min-width", "max-width",
    "min-height", "max-height"]
  var rowWirings: seq[InspectorRowWiring] = @[]
  for property in rowProperties:
    let wiring = vm.inspectorRowWiring(property)
    registerSectionCssRow(wiring)
    rowWirings.add wiring
  registerSectionCssRow(wrapWiring)
  proc wiringFor(property: string): InspectorRowWiring =
    for wiring in rowWirings:
      if wiring.cssProperty == property: return wiring
    vm.inspectorRowWiring(property)

  proc mountContents() =
    # ----- Rows ------------------------------------------------------ #
    # One host per row, shown while the selection exposes its property.
    proc rowHost(into: E; property: string): E =
      result = r.createElement("div")
      r.setAttribute(result, "data-layout-controls-property", property)
      r.setStyle(result, "display", "none")
      r.setStyle(result, "flex-direction", "column")
      r.appendChild(into, result)
      let captured = result
      createRenderEffect proc() =
        r.setStyle(captured, "display",
          if vm.inspectorProperty(property).isSome: "flex" else: "none")

    proc textValue(property: string): Signal[string] =
      result = createSignal("")
      let captured = result
      createRenderEffect proc() =
        captured.val = findPropertyValue(vm.inspector.properties.val, property, "")

    proc choiceRow(into: E; name, property: string;
        options: seq[tuple[label: string; value: string]];
        wiring = InspectorRowWiring()) =
      let host = rowHost(into, property)
      let wired = if wiring.cssProperty.len > 0: wiring
                  else: wiringFor(property)
      discard r.mountPropertyRow(host, propertyRowChoice(
        name = name, value = textValue(property), options = options,
        bindingReactive = vm.inspectorBindingThunk(property),
        onBindRequest = vm.inspectorBindRequestHandler(property),
        onDetachRequest = vm.inspectorDetachRequestHandler(property),
        wiring = wired))

    proc textRow(into: E; name, property: string) =
      let host = rowHost(into, property)
      discard r.mountPropertyRow(host, propertyRowText(
        name = name, value = textValue(property),
        bindingReactive = vm.inspectorBindingThunk(property),
        onBindRequest = vm.inspectorBindRequestHandler(property),
        onDetachRequest = vm.inspectorDetachRequestHandler(property),
        wiring = wiringFor(property)))

    # Auto layout: CSS Flexible Box Layout
    # (https://www.w3.org/TR/css-flexbox-1/#flex-wrap-property,
    # https://www.w3.org/TR/css-align-3/#align-items-property).
    choiceRow(autoRows, "Wrap", "flex-wrap", @[
      (label: "No wrap", value: "nowrap"), (label: "Wrap", value: "wrap"),
      (label: "Reverse", value: "wrap-reverse")], wrapWiring)
    choiceRow(autoRows, "Align", "align-items", @[
      (label: "Start", value: "flex-start"), (label: "Center", value: "center"),
      (label: "End", value: "flex-end"), (label: "Stretch", value: "stretch"),
      (label: "Baseline", value: "baseline")])
    choiceRow(autoRows, "Justify", "justify-content", @[
      (label: "Start", value: "flex-start"), (label: "Center", value: "center"),
      (label: "End", value: "flex-end"),
      (label: "Between", value: "space-between"),
      (label: "Around", value: "space-around"),
      (label: "Evenly", value: "space-evenly")])
    # Grid tracks: CSS Grid Layout
    # (https://www.w3.org/TR/css-grid-1/#track-sizing,
    # https://www.w3.org/TR/css-grid-1/#grid-auto-flow-property).
    textRow(gridRows, "Columns", "grid-template-columns")
    textRow(gridRows, "Rows", "grid-template-rows")
    choiceRow(gridRows, "Flow", "grid-auto-flow", @[
      (label: "Row", value: "row"), (label: "Column", value: "column"),
      (label: "Row dense", value: "row dense"),
      (label: "Column dense", value: "column dense")])
    # Constraints: positioning and insets
    # (https://www.w3.org/TR/css-position-3/#insets) and the minimum and
    # maximum size (https://www.w3.org/TR/css-sizing-3/#min-size-properties).
    choiceRow(constraintRows, "Position", "position", @[
      (label: "Static", value: "static"), (label: "Relative", value: "relative"),
      (label: "Absolute", value: "absolute"), (label: "Fixed", value: "fixed"),
      (label: "Sticky", value: "sticky")])
    for (name, property) in [("Top", "top"), ("Right", "right"),
        ("Bottom", "bottom"), ("Left", "left"), ("Min W", "min-width"),
        ("Max W", "max-width"), ("Min H", "min-height"),
        ("Max H", "max-height")]:
      textRow(constraintRows, name, property)

    # Contextual sub-panels: the flex rows for a flex layout, the track editor
    # for a grid; elsewhere a note says what they need.
    createRenderEffect proc() =
      let mode = layoutMode.val
      let flex = isFlexLayout(mode)
      r.setStyle(autoRows, "display", if flex: "flex" else: "none")
      r.setStyle(autoNote, "display", if flex: "none" else: "block")
      r.setStyle(gridRows, "display", if mode == "grid": "flex" else: "none")
      r.setStyle(gridNote, "display", if mode == "grid": "none" else: "block")

    # ----- Responsive overrides -------------------------------------- #
    let property = createSignal("gap")
    let message = createSignal("")
    let messageFailed = createSignal(false)

    proc offered(): seq[string] =
      for name in responsiveOverrideProperties:
        if vm.inspectorProperty(name).isSome: result.add name

    # The property follows the selection: kept while the new selection exposes
    # it, else the first one it exposes. A new selection or property starts
    # with its current value and no message.
    var lastKey = ""
    createRenderEffect proc() =
      let names = offered()
      let selected = vm.inspector.selectedElement.val.id
      untrack(proc() =
        if names.len > 0 and property.val notin names:
          property.val = names[0])
      let current = property.val
      let key = selected & "\x1f" & current
      let value = findPropertyValue(vm.inspector.properties.val, current, "")
      untrack(proc() =
        if key != lastKey:
          lastKey = key
          message.val = ""
        r.setInputValue(overrideValue, value))

    proc chooseProperty(name: string): proc() =
      result = proc() = property.val = name
    proc propertyOptions(): seq[CompactChoiceOption] =
      let current = property.val
      for name in offered():
        result.add CompactChoiceOption(label: name, shortLabel: name,
          ariaLabel: "Override " & name, selected: name == current,
          enabled: true,
          dataAttrs: @[("data-layout-override-property", name)],
          onChoose: chooseProperty(name))
    let chooser = renderCompactChoiceRow[R, E](r, "Property",
      "Choose the property to override", propertyOptions, visibleLimit = 2)
    r.appendChild(overrideProperty, chooser.root)

    createRenderEffect proc() =
      let current = property.val
      let scope = vm.responsiveOverrideScope(current)
      r.setTextContent(overrideScope,
        if scope.refusal.len > 0: scope.refusal
        else:
          "Writes " & current & " in the class rule " &
            (if scope.choice.ownerLabel.len > 0: scope.choice.ownerLabel & " "
             else: "") &
            (if scope.choice.sourceFile.len > 0:
               "(" & scope.choice.sourceFile &
                 (if scope.choice.sourceLine > 0: ":" & $scope.choice.sourceLine
                  else: "") & ") "
             else: "") &
            "repeated inside the mode's breakpoint; other widths keep their value.")

    createRenderEffect proc() =
      let text = message.val
      r.setTextContent(overrideMessage, text)
      r.setStyle(overrideMessage, "color",
        if messageFailed.val: danger else: textMuted)

    # One button per mode, each in its own proc so its closures keep its own
    # mode and nodes.
    proc mountModeButton(initial: ResponsiveOverrideTarget) =
      let modeKey = initial.modeKey
      let label = initial.label
      var modeButton, modeText: E
      let node = ui(r):
        button(ref = modeButton, `type` = "button",
               `data-layout-override-mode` = modeKey,
               `aria-label` = responsiveOverrideLabel(label),
               display = "flex", flex_direction = "column",
               align_items = "flex-start", gap = "1px",
               padding = "3px 6px", min_width = "0",
               border = "1px solid " & border, border_radius = "4px",
               background_color = trough, color = textPrimary,
               font_family = "inherit", font_size = "11px", cursor = "pointer",
               text_align = "left"):
          span(font_weight = "600"):
            text label
          span(ref = modeText, `data-layout-override-breakpoint` = modeKey,
               font_size = "10px", color = textMuted, white_space = "nowrap",
               overflow = "hidden", text_overflow = "ellipsis", max_width = "100%"):
            text ""
      r.appendChild(overrideModes, node)
      # Not `aria-disabled`: a mode without a breakpoint still answers a press
      # with the reason, as a refused row commit does, and the button says it
      # in its caption and title before then.
      createRenderEffect proc() =
        let target = vm.responsiveOverrideTarget(modeKey)
        let current = property.val
        r.setTextContent(modeText,
          if target.refusal.len > 0: "no breakpoint"
          else: target.breakpoint.label)
        r.setAttribute(modeButton, "data-layout-override-available",
          if target.refusal.len > 0: "false" else: "true")
        r.setAttribute(modeButton, "title",
          if target.refusal.len > 0: target.refusal
          else: "Set " & current & " for " & label & " only, inside " &
            target.breakpoint.condition)
      r.addEventListener(modeButton, "click", proc() =
        if not alive: return
        let name = untrack(proc(): string = property.val)
        let value = r.inputValue(overrideValue).strip()
        let outcome = commitResponsiveOverrideValue(vm, name, value, modeKey)
        let target = untrack(proc(): ResponsiveOverrideTarget =
          vm.responsiveOverrideTarget(modeKey))
        messageFailed.val = not outcome.ok
        message.val =
          if outcome.ok:
            label & ": " & name &
              (if value.len > 0: " set to " & outcome.committedValue
               else: " override removed") & " inside " &
              target.breakpoint.condition & "."
          else: label & ": " & outcome.message)
      stopLayoutKeys(r, modeButton)

    for initial in untrack(proc(): seq[ResponsiveOverrideTarget] =
        vm.responsiveOverrideTargets()):
      mountModeButton(initial)

  let contentsOwner = getOwner()
  var contentsMounted = false
  createRenderEffect proc() =
    if vm.inspector.layoutControlsShown.val and not contentsMounted:
      contentsMounted = true
      untrack(proc() = runWithOwner(contentsOwner, mountContents))
