## The Layout section's visual box model.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors": "Visual box model -- nested rectangles for margin/padding/
## content; click any segment to type a value; click center to set all sides
## uniformly", and the clause under it that says where the box model lives
## and how its fields commit. The section-based redesign keeps those editors
## in force ("Property row pattern": the redesign "is about LAYOUT, not the
## per-control sophistication") and places spacing in Layout ("Section
## catalogue": Layout owns "gap, padding").
##
## The box model is a disclosure under the Layout section's padding rows
## (`Show box model controls`). Open, it draws the selection's CSS box
## (https://www.w3.org/TR/css-box-3/#box-model) as nested rings -- margin,
## border, padding, content -- with one field per margin and padding side and
## an all-sides field for each: the centre sets the `padding` shorthand, the
## margin ring's corner sets `margin`. The border ring shows the border width,
## which Stroke's Width row edits; the content box shows the element's size.
##
## A field is not a second editing path. It commits through an
## `InspectorRowWiring`, the same connection to the source pipeline a property
## row has: the padding sides share the very wirings of Layout's `Pad top` ..
## `Pad left` rows (so a scope chosen on either applies to both), and the
## margin sides and the two shorthands get wirings of their own. Validation,
## writer refusals, the preview, the undo entry and the automatic write are
## therefore the row's. The margin sides register with the section's raw CSS
## (`section_raw_css`), as every source-wired row does, and the box model
## registers its text with the section search (`inspector_search`).
##
## Interaction follows the inspector's numeric contract ("Numeric Inputs";
## "Planned interaction parity"): click selects the text; Enter, Tab or
## leaving the field commits; a bare number is pixels and arithmetic is
## evaluated; Escape restores the committed value; ArrowUp/ArrowDown step by
## 1 (Shift 10, Alt 0.1), one commit per step; a horizontal drag on a field
## that is not being typed in scrubs it and commits one edit on release, a
## press without movement only focuses it, and Escape or pointer cancellation
## restores the value from before the drag. A draft or a drag belongs to the
## selection it was started on: another selection discards it.
##
## Not built here: the spec bullet's "drag handles on canvas for live
## preview". The canvas has only the selection overlay's single spacing
## handle (`component_edit`); per-side margin and padding handles are future
## work, and a field scrub reaches the preview when it is released.

import std/[math, options, strutils]

import isonim/core/[signals, computation, owner]
from isonim/core/batch import untrack
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/choice_row
import isonim/editor/views/view_lifecycle
import ./property_commit
import ./property_row
import ./section_raw_css
import ./inspector_search

when defined(js):
  import std/dom
  import isonim/web/dom_api

const
  boxSides* = ["top", "right", "bottom", "left"]
    ## CSS's clockwise side order, which the shorthands use as well.
  boxModelSearchText* = "Box model margin margin-top margin-right " &
    "margin-bottom margin-left padding"
    ## What the inspector search finds the box model by. It names only what
    ## the box model edits: the border ring is not edited here, so a search
    ## for a border property does not list Layout.
  scrubThresholdPx = 3.0
    ## Horizontal travel before a press on a field becomes a scrub; less is a
    ## click, which focuses the field.

  textPrimary = "#ECEDF3"
  textMuted = "#6B6F80"
  textDim = "#4B4F60"
  border = "#2A2C3A"
  accent = "#7C7AED"
  bgInput = "#1A1B22"
  danger = "#F87171"
  marginTint = "rgba(251, 191, 36, 0.06)"
  paddingTint = "rgba(52, 211, 153, 0.07)"

# --------------------------------------------------------------------------- #
#  Values.
# --------------------------------------------------------------------------- #

func boxNumber(value: float): string =
  ## A number as a field shows and commits it, at the precision it has: an
  ## authored `0.125rem` stays `0.125rem` (`formatNumber`'s two-decimal
  ## rounding is for a row's compact display, not for source values).
  formatExactNumber(value)

func boxSteppedNumber(value: float): string =
  ## A number a step or a scrub produced. Steps of 0.1 accumulate binary
  ## rounding error (`0.2 + 0.1` is `0.30000000000000004`); the smallest
  ## movement either makes is 0.025, so four decimals keep every step and
  ## drop the noise.
  formatExactNumber(round(value * 10_000.0) / 10_000.0)

func boxModelFieldLabel*(property: string): string =
  ## The accessible name of the field that edits ``property``:
  ## `margin-top` -> `Margin top`, `padding` -> `Padding, all sides`.
  let dash = property.find('-')
  if dash < 0:
    return property.capitalizeAscii & ", all sides"
  property[0 ..< dash].capitalizeAscii & " " & property[dash + 1 .. ^1]

proc boxModelDisplayValue*(value: string): string =
  ## A CSS length as a box field shows it: pixels as a bare number (`18px`
  ## -> `18`), any other unit with its unit (`1.5rem`), anything that is not
  ## a single number (`auto`, `var(--space)`) as written.
  let text = value.strip()
  let parsed = parseNumericInput(text)
  if parsed.value.isNone or parsed.unit notin ["", "px", "em", "rem", "%",
      "vw", "vh", "vmin", "vmax", "ch", "ex"]:
    return text
  let number = boxNumber(parsed.value.get)
  if parsed.unit in ["", "px"]: number else: number & parsed.unit

proc boxModelCssValue*(text: string): string =
  ## The CSS value a typed field commits: a number or arithmetic expression
  ## with an optional unit is evaluated, and a bare number is pixels (`24` ->
  ## `24px`, `10+4` -> `14px`, `2rem` -> `2rem`). Anything else -- a keyword,
  ## `var()`, `calc()` -- is committed as typed, for the property's own
  ## validation to admit or refuse. Empty text is "" (no edit).
  let raw = text.strip()
  if raw.len == 0: return ""
  let parsed = parseNumericInput(raw)
  if parsed.value.isNone: return raw
  boxNumber(parsed.value.get) & (if parsed.unit.len == 0: "px" else: parsed.unit)

proc boxModelSteppedValue*(text: string; delta: float): string =
  ## ``text`` moved by ``delta`` in its own unit, as a CSS value, or "" when
  ## it is not a number (a keyword cannot be stepped).
  let parsed = parseNumericInput(text.strip())
  if parsed.value.isNone: return ""
  boxSteppedNumber(parsed.value.get + delta) &
    (if parsed.unit.len == 0: "px" else: parsed.unit)

func boxModelStep*(shift, alt: bool): float =
  ## The arrow-key step ("Numeric Inputs": Arrow +/-1, Shift 10, Alt 0.1).
  if shift: 10.0 elif alt: 0.1 else: 1.0

func boxShorthandOf(property: string): string =
  let dash = property.find('-')
  if dash < 0: "" else: property[0 ..< dash]

proc boxPropertyValue(vm: EditorVM; property: string): Option[string] =
  ## The value the selection has for ``property``: what the source authored
  ## when known, otherwise the value the inspector reads. Reactive.
  let found = vm.inspectorProperty(property)
  if found.isNone: return none(string)
  let prop = found.get
  some(if prop.authoredValue.len > 0: prop.authoredValue else: prop.value)

proc boxModelSideValue*(vm: EditorVM; property: string): string =
  ## The value a side field shows: the side's own, or -- when the selection
  ## exposes only the shorthand -- that side of a simple shorthand. Reactive.
  let own = vm.boxPropertyValue(property)
  if own.isSome: return own.get
  let shorthand = boxShorthandOf(property)
  let side = boxSides.find(property[shorthand.len + 1 .. ^1])
  if shorthand.len == 0 or side < 0: return ""
  let whole = vm.boxPropertyValue(shorthand)
  if whole.isNone: return ""
  let values = shorthandSideValues(whole.get)
  if values.len == 4: values[side] else: ""

proc boxModelUniformValue*(vm: EditorVM; shorthand: string): string =
  ## What an all-sides field shows: the shared value when the four sides
  ## agree, "" (shown as `Mixed`) when they do not. Reactive.
  var first = ""
  for i, side in boxSides:
    let value = boxModelDisplayValue(vm.boxModelSideValue(shorthand & "-" & side))
    if value.len == 0: return ""
    if i == 0: first = value
    elif value != first: return ""
  first

proc boxModelFieldRefusal*(vm: EditorVM; property: string;
    wiring: InspectorRowWiring): string =
  ## Why the field that edits ``property`` cannot commit now, or "".
  ## Reactive.
  if vm.inspector.selectedElement.val.tag.len == 0:
    return "Select an element to edit its box model."
  if vm.inspectorProperty(property).isNone:
    return "The selected element does not expose " & property & "."
  if wiring.readOnlyReason != nil:
    return wiring.readOnlyReason()

# --------------------------------------------------------------------------- #
#  Commit.
# --------------------------------------------------------------------------- #

type
  BoxModelCommitOutcome* = object
    ## ``ok`` is false for a refusal, with ``message`` saying why. A commit
    ## that changes nothing (empty text, the value already in place) is ok
    ## with ``changed`` false.
    ok*: bool
    changed*: bool
    message*: string

proc commitBoxModelField*(vm: EditorVM; property: string;
    wiring: InspectorRowWiring; text: string;
    done: proc(outcome: BoxModelCommitOutcome) {.closure.} = nil):
    BoxModelCommitOutcome {.discardable.} =
  ## Commit the text of the box field that edits ``property``, through
  ## ``wiring`` -- the scope it commits at, validation, writer refusals,
  ## preview, one undo entry and the automatic write are the row's.
  ##
  ## The returned outcome is final for a refusal, a no-op and a synchronous
  ## project; ``done`` receives the final outcome in every case, after a
  ## native source project has answered.
  proc finish(outcome: BoxModelCommitOutcome): BoxModelCommitOutcome =
    if done != nil: done(outcome)
    outcome
  let value = boxModelCssValue(text)
  if value.len == 0:
    # Removing a declaration is Reset, in a row's menu, not an empty field.
    return finish(BoxModelCommitOutcome(ok: true))
  let refusal = untrack(proc(): string = vm.boxModelFieldRefusal(property, wiring))
  if refusal.len > 0:
    return finish(BoxModelCommitOutcome(ok: false, message: refusal))
  let current = untrack(proc(): string =
    let found = vm.boxPropertyValue(property)
    if found.isSome: found.get.strip() else: "")
  if value == current or boxModelDisplayValue(value) == boxModelDisplayValue(current):
    return finish(BoxModelCommitOutcome(ok: true))
  if wiring.commitAsync == nil:
    return finish(BoxModelCommitOutcome(ok: false,
      message: property & " has no source pipeline in this inspector."))
  # The act-time questions the commit will ask, asked first (editor spec
  # "Saving": a refusal the editor can know at the act is made at the act).
  # A native source project's bridge is called directly by the wiring, so
  # this is what keeps an invalid value from reaching it.
  let selected = if wiring.selectedSourceScope != nil:
      untrack(proc(): Option[SourceScopeChoice] = wiring.selectedSourceScope())
    else: none(SourceScopeChoice)
  let scope = if selected.isSome: selected.get.kind else: sskLocalInstance
  let admission = untrack(proc(): string =
    vm.propertyValueCommitRefusal(property, value, scope))
  if admission.len > 0:
    return finish(BoxModelCommitOutcome(ok: false, message: admission))
  var outcome = BoxModelCommitOutcome(ok: true, changed: true)
  wiring.commitAsync(value, proc(ok: bool) =
    if ok:
      outcome = BoxModelCommitOutcome(ok: true, changed: true)
    else:
      let reason = wiring.commitMessage.val
      outcome = BoxModelCommitOutcome(ok: false, message:
        if reason.len > 0: reason else: "The edit to " & property & " was refused.")
    if done != nil: done(outcome))
  outcome

# --------------------------------------------------------------------------- #
#  View.
# --------------------------------------------------------------------------- #

when defined(js):
  proc readBoxKey[E: dom.Event | dom_api.Event](ev: E): cstring
    {.importjs: "(#.key || '')".}
  proc readBoxShift[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.shiftKey)".}
  proc readBoxAlt[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.altKey)".}
  proc readBoxComposing[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.isComposing)".}

  proc boxKey(ev: dom.Event | dom_api.Event): string = $readBoxKey(ev)
  proc boxShift(ev: dom.Event | dom_api.Event): bool = readBoxShift(ev)
  proc boxAlt(ev: dom.Event | dom_api.Event): bool = readBoxAlt(ev)
  proc boxComposing(ev: dom.Event | dom_api.Event): bool = readBoxComposing(ev)

when defined(js):
  proc readBoxButton[E: dom.Event | dom_api.Event](ev: E): int
    {.importjs: "(#.button | 0)".}
  proc boxButton(ev: dom.Event | dom_api.Event): int = readBoxButton(ev)
  proc captureBoxPointer[N, E](node: N; ev: E)
    {.importjs: "(function (n, e) { try { n.setPointerCapture(e.pointerId); } catch (err) {} })(#, #)".}
  proc selectBoxField[N](node: N)
    {.importjs: "#.select()".}
  proc blurBoxField[N](node: N) {.importjs: "#.blur()".}

proc boxKey[E](ev: E): string = ev.key
proc boxShift[E](ev: E): bool = ev.shiftKey
proc boxAlt[E](ev: E): bool = ev.altKey
proc boxComposing[E](ev: E): bool = false

template preventBoxDefault(ev: untyped) =
  mixin preventDefault
  when compiles(ev.preventDefault()):
    ev.preventDefault()
  elif defined(js):
    proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
    prevent(ev)

template stopBoxPropagation(ev: untyped) =
  mixin stopPropagation
  when compiles(ev.stopPropagation()):
    ev.stopPropagation()
  elif defined(js):
    proc stop(event: typeof(ev)) {.importjs: "#.stopPropagation()".}
    stop(ev)

func boxModelToggleLabel*(): string = "Show box model controls"

proc mountSectionBoxModel*[R, E](r: R; parent: E; vm: EditorVM;
    paddingWirings: array[4, InspectorRowWiring]) =
  ## Mount the box model disclosure and its panel at the end of ``parent``.
  ## ``paddingWirings`` are the Layout section's `Pad top` .. `Pad left`
  ## wirings, in `boxSides` order, which the padding sides commit through.
  var toggle, panel, message, scopeHost, scopeNote: E
  var marginCells, paddingCells: array[4, E]
  var marginAllCell, borderCaption, contentHost, contentSize: E
  let host = ui(r):
    tdiv(`data-box-model-host` = "true",
         display = "flex", flex_direction = "column", gap = "4px",
         padding_top = "4px", min_width = "0"):
      button(ref = toggle, `type` = "button",
             `data-box-model-toggle` = "true",
             `data-isonim-focus-id` = "box-model-toggle",
             `aria-expanded` = "false",
             display = "flex", align_items = "center", gap = "6px",
             height = "22px", padding = "0 4px",
             border = "1px solid transparent", border_radius = "4px",
             background_color = "transparent", color = textMuted,
             font_family = "inherit", font_size = "11px",
             cursor = "pointer", text_align = "left"):
        text "\xE2\x96\xB8 Box model"
      tdiv(ref = panel,
           `data-box-model` = "true",
           role = "group",
           `aria-label` = "Box model",
           display = "none", flex_direction = "column", gap = "4px",
           min_width = "0"):
        # Margin ring: a 3x3 grid, the sides at the edges and the border
        # ring in the middle cell.
        tdiv(`data-box-model-ring` = "margin",
             display = "grid",
             grid_template_columns = "36px minmax(0, 1fr) 36px",
             align_items = "center", justify_items = "center",
             gap = "2px", padding = "2px",
             border = "1px dashed " & textDim, border_radius = "4px",
             background_color = marginTint, min_width = "0"):
          span(justify_self = "start", font_size = "9px", color = textMuted,
               text_transform = "uppercase", letter_spacing = "0.4px",
               padding_left = "2px"):
            text "Margin"
          tdiv(ref = marginCells[0], display = "flex", justify_content = "center")
          tdiv(ref = marginAllCell, display = "flex", justify_content = "center")
          tdiv(ref = marginCells[3], display = "flex", justify_content = "center")
          # Border ring, read-only: the border width is Stroke's.
          tdiv(`data-box-model-ring` = "border",
               display = "flex", flex_direction = "column", gap = "2px",
               width = "100%", box_sizing = "border-box", min_width = "0",
               padding = "2px 3px 3px",
               border = "1px solid " & border, border_radius = "3px"):
            span(ref = borderCaption, `data-box-model-border` = "true",
                 title = "Border width (edited in the Stroke section)",
                 font_size = "9px", color = textMuted,
                 text_transform = "uppercase", letter_spacing = "0.4px")
            # Padding ring.
            tdiv(`data-box-model-ring` = "padding",
                 display = "grid",
                 grid_template_columns = "36px minmax(0, 1fr) 36px",
                 align_items = "center", justify_items = "center",
                 gap = "2px", padding = "2px",
                 border = "1px dashed " & textDim, border_radius = "3px",
                 background_color = paddingTint, min_width = "0"):
              span(justify_self = "start", font_size = "9px", color = textMuted,
                   text_transform = "uppercase", letter_spacing = "0.4px",
                   padding_left = "2px"):
                text "Pad"
              tdiv(ref = paddingCells[0], display = "flex", justify_content = "center")
              tdiv()
              tdiv(ref = paddingCells[3], display = "flex", justify_content = "center")
              # Content box: the all-sides padding field and the size.
              tdiv(ref = contentHost, `data-box-model-content` = "true",
                   display = "flex", flex_direction = "column",
                   align_items = "center", gap = "1px",
                   width = "100%", box_sizing = "border-box",
                   padding = "3px 2px", min_width = "0",
                   border = "1px solid " & border, border_radius = "2px",
                   background_color = bgInput):
                span(ref = contentSize, `data-box-model-size` = "true",
                     title = "Content size (width x height)",
                     font_size = "9px", color = textMuted,
                     white_space = "nowrap", overflow = "hidden",
                     text_overflow = "ellipsis", max_width = "100%")
              tdiv(ref = paddingCells[1], display = "flex", justify_content = "center")
              tdiv()
              tdiv(ref = paddingCells[2], display = "flex", justify_content = "center")
              tdiv()
          tdiv(ref = marginCells[1], display = "flex", justify_content = "center")
          tdiv()
          tdiv(ref = marginCells[2], display = "flex", justify_content = "center")
          tdiv()
        tdiv(ref = scopeHost, `data-box-model-scopes` = "true",
             display = "flex", flex_direction = "column", min_width = "0")
        tdiv(ref = scopeNote, `data-box-model-scope` = "true", role = "note",
             font_size = "10px", color = textMuted, overflow_wrap = "anywhere")
        tdiv(ref = message, `data-box-model-message` = "true", role = "alert",
             display = "none", color = danger, font_size = "11px",
             overflow_wrap = "anywhere")
  r.setAttribute(toggle, "aria-label", boxModelToggleLabel())
  r.appendChild(parent, host)

  # The disclosure.
  createRenderEffect proc() =
    let shown = vm.inspector.boxModelShown.val
    r.setAttribute(toggle, "aria-expanded", if shown: "true" else: "false")
    r.setStyle(panel, "display", if shown: "flex" else: "none")
    r.setTextContent(toggle, (if shown: "\xE2\x96\xBE" else: "\xE2\x96\xB8") & " Box model")
    r.setStyle(toggle, "color", if shown: textPrimary else: textMuted)
  r.addEventListener(toggle, "click", proc() = vm.inspector.toggleBoxModel())
  # Native button activation gives Enter and Space one click each; keep the
  # editor's own shortcuts from seeing them.
  r.addEventListener(toggle, "keydown", proc(ev: auto) =
    if boxKey(ev) in ["Enter", " "]: stopBoxPropagation(ev))

  # The section search finds the box model; its disclosure is highlighted
  # like a matched row.
  let search = registerInspectorSearchText(boxModelSearchText)
  if search != nil:
    createRenderEffect proc() =
      let hit = searchTextMatches(boxModelSearchText, search.query())
      r.setAttribute(toggle, "data-inspector-search-match",
        if hit: "true" else: "false")
      r.setStyle(toggle, "background-color",
        if hit: "rgba(124, 122, 237, 0.16)" else: "transparent")

  # Wirings. The padding sides are Layout's own rows'; the margin sides and
  # the shorthands are the box model's, and the margin sides join the
  # section's raw CSS like any source-wired row.
  var marginWirings: array[4, InspectorRowWiring]
  for i, side in boxSides:
    marginWirings[i] = vm.inspectorRowWiring("margin-" & side)
    registerSectionCssRow(marginWirings[i])
  let marginAll = vm.inspectorRowWiring("margin")
  let paddingAll = vm.inspectorRowWiring("padding")

  proc wiringFor(property: string): InspectorRowWiring =
    if property == "margin": return marginAll
    if property == "padding": return paddingAll
    for i, side in boxSides:
      if property == "margin-" & side: return marginWirings[i]
      if property == "padding-" & side: return paddingWirings[i]

  let refusal = createSignal("")
  let active = createSignal("padding")
  var alive = true
  onCleanup(proc() = alive = false)

  createRenderEffect proc() =
    let reason = refusal.val
    r.setTextContent(message, reason)
    r.setStyle(message, "display", if reason.len > 0: "block" else: "none")

  # A new selection starts clean: no reason, and (below, per field) no
  # draft or drag, which belong to the element they were started on
  # ("Planned interaction parity": changing selection cannot apply a pending
  # edit to a different element).
  var selectionKey = ""
  let selectionTick = createSignal(0)
  createRenderEffect proc() =
    let story = vm.selectedStory.val
    let key = story.group & " / " & story.name & " / " &
      vm.inspector.selectedElement.val.id
    if key != selectionKey:
      selectionKey = key
      untrack(proc() =
        refusal.val = ""
        selectionTick.val = selectionTick.val + 1)

  # Border and content, read-only.
  createRenderEffect proc() =
    var widths: seq[string] = @[]
    for side in boxSides:
      let found = vm.boxPropertyValue("border-" & side & "-width")
      if found.isSome: widths.add boxModelDisplayValue(found.get)
    if widths.len == 0:
      let whole = vm.boxPropertyValue("border-width")
      if whole.isSome: widths.add boxModelDisplayValue(whole.get)
    var same = widths.len > 0
    for value in widths:
      if value != widths[0]: same = false
    r.setTextContent(borderCaption, "Border " &
      (if widths.len == 0: "-" elif same: widths[0] else: widths.join(" ")))
  createRenderEffect proc() =
    let width = vm.boxPropertyValue("width")
    let height = vm.boxPropertyValue("height")
    r.setTextContent(contentSize,
      (if width.isSome: boxModelDisplayValue(width.get) else: "-") & " \xC3\x97 " &
      (if height.isSome: boxModelDisplayValue(height.get) else: "-"))

  # The scope the field last focused commits at, and its owner: the box model
  # has no per-row scope slot, so it shows the active field's.
  proc recommitAfter(property: string; choose: proc()): proc() =
    ## Choosing a scope re-commits the field's value there, as choosing one
    ## on a property row does (`property_row`: "Choosing a scope also
    ## RE-COMMITS at the new scope"). Its own proc so each chip keeps its own
    ## callback.
    result = proc() =
      if choose != nil: choose()
      let wiring = wiringFor(property)
      let reason = untrack(proc(): string = vm.boxModelFieldRefusal(property, wiring))
      let value = untrack(proc(): Option[string] = vm.boxPropertyValue(property))
      if reason.len > 0 or value.isNone or value.get.strip().len == 0 or
          wiring.commitAsync == nil:
        return
      let story = vm.selectedStory.val
      let selected = vm.inspector.selectedElement.val.id
      wiring.commitAsync(value.get.strip(), proc(ok: bool) =
        if not alive or vm.selectedStory.val != story or
            vm.inspector.selectedElement.val.id != selected: return
        refusal.val =
          if ok: ""
          else: boxModelFieldLabel(property) & ": " & wiring.commitMessage.val)
  let strip = renderCompactChoiceRow[R, E](r, "", "Choose box model source scope",
    proc(): seq[CompactChoiceOption] =
      # Mounted only while the box model is open: closed, it has no chips
      # (and no hidden overflow menu) and asks no scope question.
      if not vm.inspector.boxModelShown.val: return
      let property = active.val
      let wiring = wiringFor(property)
      if wiring.scopeOptions == nil: return
      result = wiring.scopeOptions()
      # The same chips as the row's, named apart from the row's own.
      for option in result.mitems:
        option.ariaLabel = option.ariaLabel & " in the box model"
        option.onChoose = recommitAfter(property, option.onChoose),
    visibleLimit = 2)
  r.appendChild(scopeHost, strip.root)
  createRenderEffect proc() =
    let property = active.val
    let wiring = wiringFor(property)
    let selected = if wiring.selectedSourceScope != nil: wiring.selectedSourceScope()
      else: none(SourceScopeChoice)
    r.setTextContent(scopeNote,
      if selected.isNone: boxModelFieldLabel(property) & " (" & property &
        "): no mapped source scope."
      else: boxModelFieldLabel(property) & " (" & property & ") · " &
        selected.get.label & " · Owner: " & selected.get.ownerLabel)

  proc mountField(cell: E; property: string; minimum: Option[float];
      wide = false) =
    let wiring = wiringFor(property)
    let isUniform = property in ["margin", "padding"]
    var field: E
    let node = ui(r):
      input(ref = field, `type` = "text",
            class = "editor-input",
            `data-box-model-field` = property,
            `data-isonim-focus-id` = "box-model-" & property,
            spellcheck = "false",
            autocomplete = "off",
            width = (if wide: "48px" else: "34px"),
            max_width = "100%",
            height = "18px",
            box_sizing = "border-box",
            padding = "0 2px",
            # An all-sides field is drawn apart from the side fields.
            border = (if isUniform: "1px dashed " & textDim
                      else: "1px solid transparent"),
            border_radius = "3px",
            background_color = "transparent",
            color = textPrimary,
            font_family = "inherit",
            font_size = "11px",
            text_align = "center",
            outline = "none",
            cursor = "ew-resize")
    r.setAttribute(field, "aria-label", boxModelFieldLabel(property))
    r.appendChild(cell, node)
    var dirty = false
    var pending = false
    var scrubbing = false
    var pressed = false
    var startX, startY, startValue: float
    var startText = ""

    proc modelText(): string =
      if isUniform: vm.boxModelUniformValue(property)
      else: boxModelDisplayValue(vm.boxModelSideValue(property))

    proc resync() =
      r.setInputValue(field, untrack(proc(): string = modelText()))

    createRenderEffect proc() =
      let text = modelText()
      if not dirty and not scrubbing and not pending:
        r.setInputValue(field, text)
      r.setAttribute(field, "data-committed-value", text)
      if isUniform:
        r.setAttribute(field, "placeholder", if text.len == 0: "Mixed" else: "")
    createRenderEffect proc() =
      let reason = vm.boxModelFieldRefusal(property, wiring)
      if reason.len > 0:
        r.setAttribute(field, "readonly", "true")
        r.setAttribute(field, "aria-readonly", "true")
        r.setAttribute(field, "title", reason)
        r.setStyle(field, "color", textMuted)
        r.setStyle(field, "cursor", "not-allowed")
      else:
        r.removeAttribute(field, "readonly")
        r.removeAttribute(field, "aria-readonly")
        r.setAttribute(field, "title", boxModelFieldLabel(property) & " (" &
          property & ")")
        r.setStyle(field, "color", textPrimary)
        r.setStyle(field, "cursor", "ew-resize")

    proc commitText(text: string) =
      dirty = false
      if pending: return
      let story = vm.selectedStory.val
      let selected = vm.inspector.selectedElement.val.id
      pending = true
      discard commitBoxModelField(vm, property, wiring, text,
        proc(outcome: BoxModelCommitOutcome) =
          pending = false
          if not alive: return
          # A native project answers later; the answer belongs to the
          # selection it was made for.
          if vm.selectedStory.val != story or
              vm.inspector.selectedElement.val.id != selected: return
          if outcome.ok:
            if outcome.changed: refusal.val = ""
          else:
            refusal.val = boxModelFieldLabel(property) & ": " & outcome.message
          resync())

    proc commit() =
      if not dirty: return
      commitText(r.inputValue(field))

    proc step(delta: float) =
      let next = boxModelSteppedValue(r.inputValue(field), delta)
      if next.len == 0: return
      var value = next
      if minimum.isSome:
        let parsed = parseNumericInput(next)
        if parsed.value.isSome and parsed.value.get < minimum.get:
          value = boxNumber(minimum.get) & parsed.unit
      r.setInputValue(field, boxModelDisplayValue(value))
      commitText(value)

    # Scrub. `pressed` arms on a press of a field that is not being typed
    # in; travel past the threshold makes it a scrub, which previews in the
    # field and commits once on release.
    proc scrubStart(x, y: float; shift, alt: bool) =
      if pending: return
      pressed = true
      scrubbing = false
      startX = x
      startY = y
      startText = r.inputValue(field)
      let parsed = parseNumericInput(startText)
      startValue = if parsed.value.isSome: parsed.value.get else: NaN
    proc scrubMove(x, y: float; shift, alt: bool) =
      if not pressed: return
      if not scrubbing:
        if abs(x - startX) < scrubThresholdPx: return
        if startValue.isNaN: # not a number: it cannot be scrubbed
          pressed = false
          let reason = untrack(proc(): string =
            vm.boxModelFieldRefusal(property, wiring))
          refusal.val = boxModelFieldLabel(property) & ": " &
            (if reason.len > 0: reason
             elif startText.len == 0:
               "The sides differ (Mixed); type a value to set them all."
             else: "Type a numeric value to replace " & startText & ".")
          return
        scrubbing = true
        active.val = property
        # Focus, without selecting, so that Escape reaches the field during
        # the drag; the drag ends by giving focus back up.
        when isDomViewHost(E):
          r.focus(field)
      let value = scrubbedValue(startValue, x - startX, y - startY, 1.0,
        shift, alt, minimum, none(float))
      let unit = parseNumericInput(startText).unit
      r.setInputValue(field, boxModelDisplayValue(boxSteppedNumber(value) &
        (if unit.len == 0: "px" else: unit)))
    proc scrubEnd(x, y: float; shift, alt: bool): bool =
      ## Whether the press was a scrub (and so committed); a press that did
      ## not travel is a click.
      if not pressed: return false
      pressed = false
      if not scrubbing: return false
      scrubbing = false
      let text = r.inputValue(field)
      if boxModelCssValue(text) == boxModelCssValue(startText):
        resync()
      else:
        dirty = true
        commitText(text)
      true
    proc scrubCancel() =
      if not pressed: return
      let wasScrubbing = scrubbing
      pressed = false
      scrubbing = false
      if wasScrubbing:
        r.setInputValue(field, startText)
        when isDomViewHost(E): blurBoxField(field)

    var seenTick = -1
    createRenderEffect proc() =
      let tick = selectionTick.val
      if seenTick >= 0 and tick != seenTick:
        untrack(proc() =
          dirty = false
          scrubCancel()
          resync())
      seenTick = tick

    r.addEventListener(field, "focus", proc() =
      active.val = property
      # Clicking a field selects its text ("Numeric Inputs"), but not while
      # a drag holds it.
      when isDomViewHost(E):
        if not scrubbing: selectBoxField(field))
    r.addEventListener(field, "input", proc() =
      dirty = true)
    r.addEventListener(field, "change", proc() = commit())
    r.addEventListener(field, "blur", proc() = commit())
    r.addEventListener(field, "keydown", proc(ev: auto) =
      let key = boxKey(ev)
      if key == "Enter" and not boxComposing(ev):
        preventBoxDefault(ev)
        stopBoxPropagation(ev)
        dirty = true
        commit()
      elif key == "Escape":
        if scrubbing or pressed:
          preventBoxDefault(ev)
          stopBoxPropagation(ev)
          scrubCancel()
        elif dirty:
          preventBoxDefault(ev)
          stopBoxPropagation(ev)
          dirty = false
          resync()
      elif key in ["ArrowUp", "ArrowDown"]:
        preventBoxDefault(ev)
        let size = boxModelStep(boxShift(ev), boxAlt(ev))
        step(if key == "ArrowUp": size else: -size))

    # The gesture arrives through the renderer's pointer seam (position and
    # modifiers). In a browser a press also needs its button, the field's
    # focus and pointer capture, which the event handler below decides
    # first: a press on a field that already has focus places the caret, as
    # in any text field; a press on one that does not is a scrub or, without
    # travel, a click that focuses the field and selects its text. A
    # renderer without a browser DOM (the headless tests) arms every press.
    var gate = true
    when isDomViewHost(E):
      gate = false
      r.addEventListener(field, "pointerdown", proc(ev: auto) =
        gate = boxButton(ev) == 0 and r.activeElement() != field and
          r.getAttribute(field, "readonly").len == 0 and not pending
        if gate:
          # The drag keeps reaching the field when the pointer leaves it
          # (https://w3c.github.io/pointerevents/#pointer-capture), and the
          # press neither focuses the field nor starts a text selection.
          captureBoxPointer(field, ev)
          preventBoxDefault(ev))
    r.addPointerListener(field, "pointerdown", proc(x, y: float; shift, alt: bool) =
      if gate: scrubStart(x, y, shift, alt))
    r.addPointerListener(field, "pointermove", proc(x, y: float; shift, alt: bool) =
      scrubMove(x, y, shift, alt))
    r.addPointerListener(field, "pointerup", proc(x, y: float; shift, alt: bool) =
      let wasPressed = pressed
      if scrubEnd(x, y, shift, alt):
        when isDomViewHost(E): blurBoxField(field)
      elif wasPressed:
        r.focus(field)
        when isDomViewHost(E): selectBoxField(field))
    r.addEventListener(field, "pointercancel", proc() = scrubCancel())
    r.addEventListener(field, "lostpointercapture", proc() = scrubCancel())
    onCleanup(proc() = scrubCancel())

  for i, side in boxSides:
    mountField(marginCells[i], "margin-" & side, none(float))
    # Negative padding is invalid CSS (https://www.w3.org/TR/css-box-4/#padding-physical).
    mountField(paddingCells[i], "padding-" & side, some(0.0))
  mountField(marginAllCell, "margin", none(float))
  mountField(contentHost, "padding", some(0.0), wide = true)
