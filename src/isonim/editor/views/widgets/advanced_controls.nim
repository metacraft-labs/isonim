## What the inspector's specialized editors share: the `Show advanced
## <property> controls` disclosure, the commit through a property row's
## pipeline, a scrubbable number field, and the browser event seams.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" -> "Specialized
## Editors" (gradient, shadow and Bezier curve editors) and "Planned
## interaction parity" ("Specialized controls use this same commit/cancel
## contract"). The editors themselves are `gradient_editor`,
## `shadow_editor` and `timing_editor`.
##
## A specialized editor is not a second editing path. It edits the property
## its section's row edits, through that row's `InspectorRowWiring`: the
## scope chosen on the row, the act-time refusals, validation, the preview,
## one undo entry and the automatic write are the row's
## (`commitCompoundValue`). The row shows the value the editor committed and
## the editor shows the value the row committed, because both read the
## selection's property.

import std/[math, options, strutils]

import isonim/core/[signals, computation, owner]
from isonim/core/batch import untrack
import isonim/core/nondet as nondet
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/view_lifecycle
import ./property_commit
import ./property_row
import ./inspector_search

when defined(js):
  import std/[dom, jsffi]
  import isonim/web/dom_api

const
  advTextPrimary* = "#ECEDF3"
  advTextMuted* = "#6B6F80"
  advTextDisabled* = "#3A3D4D"
  advBorder* = "#2A2C3A"
  advAccent* = "#7C7AED"
  advDanger* = "#F87171"
  advTrough* = "#1A1B22"
  advPressed* = "#262838"
  scrubThreshold* = 3.0
    ## Pointer travel before a press becomes a drag; less is a click.

func advancedControlsLabel*(property: string): string =
  ## The accessible name of ``property``'s disclosure.
  "Show advanced " & property & " controls"

# --------------------------------------------------------------------------- #
#  Browser event seams (the headless renderer's events carry the same).
# --------------------------------------------------------------------------- #

when defined(js):
  proc readAdvKey[E: dom.Event | dom_api.Event](ev: E): cstring
    {.importjs: "(#.key || '')".}
  proc readAdvShift[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.shiftKey)".}
  proc readAdvAlt[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.altKey)".}
  proc readAdvButton[E: dom.Event | dom_api.Event](ev: E): int
    {.importjs: "(#.button | 0)".}
  proc advKey*(ev: dom.Event | dom_api.Event): string = $readAdvKey(ev)
  proc advShift*(ev: dom.Event | dom_api.Event): bool = readAdvShift(ev)
  proc advAlt*(ev: dom.Event | dom_api.Event): bool = readAdvAlt(ev)
  proc advButton*(ev: dom.Event | dom_api.Event): int = readAdvButton(ev)
  proc captureAdvPointer*[N, E](node: N; ev: E)
    {.importjs: "(function (n, e) { try { n.setPointerCapture(e.pointerId); } catch (err) {} })(#, #)".}

proc advKey*[E](ev: E): string = ev.key
proc advShift*[E](ev: E): bool = ev.shiftKey
proc advAlt*[E](ev: E): bool = ev.altKey

template preventAdvDefault*(ev: untyped) =
  mixin preventDefault
  when compiles(ev.preventDefault()):
    ev.preventDefault()
  elif defined(js):
    proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
    prevent(ev)

template stopAdvPropagation*(ev: untyped) =
  mixin stopPropagation
  when compiles(ev.stopPropagation()):
    ev.stopPropagation()
  elif defined(js):
    proc stop(event: typeof(ev)) {.importjs: "#.stopPropagation()".}
    stop(ev)

template stopAdvActivationKeys*(r, node: untyped) =
  ## Native button activation gives Enter and Space one click each; keep the
  ## editor's own shortcuts from seeing them.
  r.addEventListener(node, "keydown", proc(ev: auto) =
    if advKey(ev) in ["Enter", " "]: stopAdvPropagation(ev))

proc nodeRect*[E](node: E): tuple[x, y, w, h: float] =
  ## ``node``'s rectangle in viewport coordinates, the coordinates pointer
  ## events report, through the platform layout seam (`nondet.measure`).
  ## Without a browser there is no layout: the zero rectangle, and callers
  ## use their nominal size.
  when isDomViewHost(E):
    let rect = nondet.measure(cast[JsObject](node))
    (rect.x, rect.y, rect.width, rect.height)
  else:
    discard node
    (0.0, 0.0, 0.0, 0.0)

# --------------------------------------------------------------------------- #
#  Values and commits.
# --------------------------------------------------------------------------- #

proc compoundValue*(vm: EditorVM; property: string): Option[string] =
  ## The value the selection has for ``property``: as the source authored it
  ## when known, otherwise as the inspector reads it. Reactive.
  let found = vm.inspectorProperty(property)
  if found.isNone: return none(string)
  let prop = found.get
  some(if prop.authoredValue.strip().len > 0: prop.authoredValue.strip()
       else: prop.value.strip())

proc compoundSelectionKey*(vm: EditorVM): string =
  ## The story and element an editor's draft or drag belongs to. Reactive.
  let story = vm.selectedStory.val
  story.group & " / " & story.name & " / " & $story.kind & " / " &
    vm.inspector.selectedElement.val.id

proc compoundRefusal*(vm: EditorVM; property: string;
    wiring: InspectorRowWiring): string =
  ## Why an editor of ``property`` cannot commit now, or "". Reactive.
  if vm.inspector.selectedElement.val.tag.len == 0:
    return "Select an element to edit its " & property & "."
  if vm.inspectorProperty(property).isNone:
    return "The selected element does not expose " & property & "."
  if wiring.readOnlyReason != nil:
    return wiring.readOnlyReason()

type
  CompoundCommitOutcome* = object
    ## ``ok`` is false for a refusal, with ``message`` saying why. A commit
    ## of the value already in place is ok with ``changed`` false.
    ok*: bool
    changed*: bool
    message*: string

proc commitCompoundValue*(vm: EditorVM; property: string;
    wiring: InspectorRowWiring; value: string;
    done: proc(outcome: CompoundCommitOutcome) {.closure.} = nil):
    CompoundCommitOutcome {.discardable.} =
  ## Commit ``value`` for ``property`` through its row's pipeline
  ## (``wiring``). The questions the commit will ask are asked first, so a
  ## refusal the editor can know at the act changes nothing (editor spec
  ## "Saving"); a native source project's bridge is called by the wiring
  ## and so never receives a value the editor refuses.
  ##
  ## The returned outcome is final for a refusal, a no-op and a synchronous
  ## project; ``done`` receives the final outcome in every case.
  proc finish(outcome: CompoundCommitOutcome): CompoundCommitOutcome =
    if done != nil: done(outcome)
    outcome
  let text = value.strip()
  if text.len == 0:
    # Removing the declaration is Reset, in the row's menu.
    return finish(CompoundCommitOutcome(ok: true))
  let refusal = untrack(proc(): string = vm.compoundRefusal(property, wiring))
  if refusal.len > 0:
    return finish(CompoundCommitOutcome(ok: false, message: refusal))
  let current = untrack(proc(): Option[string] = vm.compoundValue(property))
  if current.isSome and current.get == text:
    return finish(CompoundCommitOutcome(ok: true))
  if wiring.commitAsync == nil:
    return finish(CompoundCommitOutcome(ok: false,
      message: property & " has no source pipeline in this inspector."))
  let selected = if wiring.selectedSourceScope != nil:
      untrack(proc(): Option[SourceScopeChoice] = wiring.selectedSourceScope())
    else: none(SourceScopeChoice)
  let scope = if selected.isSome: selected.get.kind else: sskLocalInstance
  let admission = untrack(proc(): string =
    vm.propertyValueCommitRefusal(property, text, scope))
  if admission.len > 0:
    return finish(CompoundCommitOutcome(ok: false, message: admission))
  var outcome = CompoundCommitOutcome(ok: true, changed: true)
  wiring.commitAsync(text, proc(ok: bool) =
    if ok:
      outcome = CompoundCommitOutcome(ok: true, changed: true)
    else:
      let reason = wiring.commitMessage.val
      outcome = CompoundCommitOutcome(ok: false, message:
        if reason.len > 0: reason else: "The edit to " & property & " was refused.")
    if done != nil: done(outcome))
  outcome

type
  CompoundEditorStatus* = ref object
    ## An editor's status line: the refusal of its last commit, or what a
    ## diagnostic found. Cleared by an accepted commit and by another
    ## selection.
    message*: Signal[string]
    failed*: Signal[bool]

proc newCompoundEditorStatus*(): CompoundEditorStatus =
  CompoundEditorStatus(message: createSignal(""), failed: createSignal(false))

proc commitThrough*(vm: EditorVM; property: string; wiring: InspectorRowWiring;
    status: CompoundEditorStatus; label, value: string;
    after: proc(ok: bool) {.closure.} = nil): bool {.discardable.} =
  ## Commit ``value`` and report the outcome in ``status`` (prefixed with
  ## ``label`` on a refusal). Returns whether the commit was accepted (for a
  ## native project: so far). An answer that arrives after another selection
  ## is not shown.
  let key = untrack(proc(): string = vm.compoundSelectionKey())
  let outcome = commitCompoundValue(vm, property, wiring, value,
    proc(outcome: CompoundCommitOutcome) =
      if untrack(proc(): string = vm.compoundSelectionKey()) != key: return
      if outcome.ok:
        if outcome.changed:
          status.failed.val = false
          status.message.val = ""
      else:
        status.failed.val = true
        status.message.val = label & ": " & outcome.message
      if after != nil: after(outcome.ok))
  outcome.ok

proc watchSelection*(vm: EditorVM; onChange: proc() {.closure.}) =
  ## Call ``onChange`` (untracked) whenever the selection changes, not on
  ## the first run: a draft or a drag belongs to the selection it was
  ## started on ("Planned interaction parity").
  var last = ""
  var first = true
  createRenderEffect proc() =
    let key = vm.compoundSelectionKey()
    if first:
      first = false
      last = key
    elif key != last:
      last = key
      untrack(onChange)

# --------------------------------------------------------------------------- #
#  The disclosure.
# --------------------------------------------------------------------------- #

proc mountAdvancedDisclosure*[R, E](r: R; parent: E; vm: EditorVM;
    property, caption, searchText: string;
    mountContents: proc(panel: E) {.closure.}): E =
  ## ``property``'s `Show advanced <property> controls` disclosure at the end
  ## of ``parent``: closed when the editor opens and remembered for the
  ## session (`InspectorVM.advancedControlsShown`). Its contents are mounted
  ## the first time it is opened, and kept. It is shown while the selection
  ## exposes ``property``. Returns the panel.
  var toggle, toggleText, panel: E
  let host = ui(r):
    tdiv(`data-advanced-controls-host` = property,
         display = "none", flex_direction = "column", gap = "4px",
         padding_top = "2px", min_width = "0"):
      button(ref = toggle, `type` = "button",
             `data-advanced-controls-toggle` = property,
             `data-isonim-focus-id` = "advanced-controls-" & property,
             `aria-expanded` = "false",
             display = "flex", align_items = "center", gap = "6px",
             height = "22px", padding = "0 4px",
             border = "1px solid transparent", border_radius = "4px",
             background_color = "transparent", color = advTextMuted,
             font_family = "inherit", font_size = "11px",
             cursor = "pointer", text_align = "left"):
        span(ref = toggleText):
          text "\xE2\x96\xB8 " & caption
      tdiv(ref = panel, `data-advanced-controls` = property,
           role = "group", display = "none", flex_direction = "column",
           gap = "6px", min_width = "0")
  r.setAttribute(toggle, "aria-label", advancedControlsLabel(property))
  r.setAttribute(panel, "aria-label", caption)
  r.appendChild(parent, host)
  createRenderEffect proc() =
    r.setStyle(host, "display",
      if vm.inspectorProperty(property).isSome: "flex" else: "none")
  createRenderEffect proc() =
    let shown = vm.inspector.advancedControlsOpen(property)
    r.setAttribute(toggle, "aria-expanded", if shown: "true" else: "false")
    r.setStyle(panel, "display", if shown: "flex" else: "none")
    r.setTextContent(toggleText,
      (if shown: "\xE2\x96\xBE " else: "\xE2\x96\xB8 ") & caption)
    r.setStyle(toggle, "color", if shown: advTextPrimary else: advTextMuted)
  r.addEventListener(toggle, "click", proc() =
    vm.inspector.toggleAdvancedControls(property))
  stopAdvActivationKeys(r, toggle)
  # The section search finds the editor by what it edits.
  let search = registerInspectorSearchText(searchText)
  if search != nil:
    createRenderEffect proc() =
      let hit = searchTextMatches(searchText, search.query())
      r.setAttribute(toggle, "data-inspector-search-match",
        if hit: "true" else: "false")
      r.setStyle(toggle, "background-color",
        if hit: "rgba(124, 122, 237, 0.16)" else: "transparent")
  let owner = getOwner()
  var mounted = false
  createRenderEffect proc() =
    if vm.inspector.advancedControlsOpen(property) and not mounted:
      mounted = true
      untrack(proc() = runWithOwner(owner, proc() = mountContents(panel)))
  panel

proc mountEditorStatus*[R, E](r: R; parent: E; status: CompoundEditorStatus;
    attr: string) =
  ## The editor's status line (`role=status`), shown while it has text.
  var line: E
  let node = ui(r):
    tdiv(ref = line, role = "status", `aria-live` = "polite",
         display = "none", font_size = "11px", color = advTextMuted,
         overflow_wrap = "anywhere")
  r.setAttribute(line, attr, "true")
  r.appendChild(parent, node)
  createRenderEffect proc() =
    let text = status.message.val
    r.setTextContent(line, text)
    r.setStyle(line, "display", if text.len > 0: "block" else: "none")
    r.setStyle(line, "color", if status.failed.val: advDanger else: advTextMuted)

proc mountScopeNote*[R, E](r: R; parent: E; property: string;
    wiring: InspectorRowWiring; rowName: string) =
  ## Which scope the editor commits at: the row's (the editor has no scope
  ## chips of its own; choosing a scope on the row applies here too).
  var note: E
  let node = ui(r):
    tdiv(ref = note, role = "note", font_size = "10px", color = advTextMuted,
         overflow_wrap = "anywhere")
  r.setAttribute(note, "data-advanced-controls-scope", property)
  r.appendChild(parent, node)
  createRenderEffect proc() =
    let selected = if wiring.selectedSourceScope != nil:
        wiring.selectedSourceScope() else: none(SourceScopeChoice)
    r.setTextContent(note,
      if selected.isNone: "Commits through the " & rowName & " row."
      else: "Commits through the " & rowName & " row \xC2\xB7 " &
        selected.get.label &
        (if selected.get.ownerLabel.len > 0: " \xC2\xB7 Owner: " &
           selected.get.ownerLabel else: ""))

proc setButtonAvailability*[R, E](r: R; node: E; reason, title: string) =
  ## A control that cannot act says why: `aria-disabled` and its title. It
  ## still answers a press, with the reason in the editor's status line.
  r.setAttribute(node, "aria-disabled", if reason.len > 0: "true" else: "false")
  r.setAttribute(node, "title", if reason.len > 0: reason else: title)
  r.setStyle(node, "color", if reason.len > 0: advTextDisabled else: advTextPrimary)

# --------------------------------------------------------------------------- #
#  A scrubbable number field.
# --------------------------------------------------------------------------- #

type
  CompoundNumberField* = object
    ## How a number field reads and commits its value. ``shown`` is the
    ## committed text (reactive); ``commit`` commits text and answers
    ## whether it was accepted; ``draft``, when set, previews text while the
    ## label is scrubbed; ``reason`` says why the field cannot be edited now
    ## (reactive, "" when it can).
    label*: string
    ariaLabel*: string
    unit*: string
      ## The unit a bare typed number gets (`px`, `deg`, `%`), or "".
    step*: float
    minimum*: Option[float]
    maximum*: Option[float]
    shown*: proc(): string {.closure.}
    commit*: proc(text: string): bool {.closure.}
    draft*: proc(text: string) {.closure.}
    reason*: proc(): string {.closure.}
    generation*: proc(): int {.closure.}
      ## Reactive; changes when the editor's selection changes. A draft or a
      ## scrub belongs to the selection it was started on: a change discards
      ## it ("Planned interaction parity").

proc numberFieldValue*(text, unit: string): string =
  ## The CSS text a typed field commits: arithmetic is evaluated and a bare
  ## number takes ``unit`` (`8` -> `8px`, `10+4` -> `14px`); anything else is
  ## committed as typed, for the property's validation to admit or refuse.
  let raw = text.strip()
  if raw.len == 0: return ""
  let parsed = parseNumericInput(raw)
  if parsed.value.isNone: return raw
  var rounded = round(parsed.value.get * 1000.0) / 1000.0
  if rounded == 0.0: rounded = 0.0
  let digits = formatExactNumber(rounded)
  digits & (if parsed.unit.len > 0: parsed.unit else: unit)

proc steppedFieldValue*(text, unit: string; delta: float;
    minimum, maximum: Option[float]): string =
  ## ``text`` moved by ``delta`` in its own unit, or "" when it is not a
  ## number.
  let parsed = parseNumericInput(text.strip())
  if parsed.value.isNone: return ""
  var next = parsed.value.get + delta
  if minimum.isSome and next < minimum.get: next = minimum.get
  if maximum.isSome and next > maximum.get: next = maximum.get
  numberFieldValue(formatExactNumber(round(next * 1000.0) / 1000.0) &
    parsed.unit, unit)

proc mountCompoundNumberField*[R, E](r: R; parent: E;
    field: CompoundNumberField): E =
  ## A number field: its label scrubs ("Click-drag on label"), the field
  ## takes typed numbers and arithmetic, Enter or leaving it commits, Escape
  ## restores, ArrowUp / ArrowDown step by ``step`` (Shift 10x, Alt 0.1x),
  ## each step one commit. A scrub previews through ``draft`` and commits
  ## once on release; Escape or pointer cancellation restores ("Numeric
  ## Inputs"; "Planned interaction parity").
  var labelEl, inputEl: E
  let node = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "4px", min_width = "0"):
      span(ref = labelEl, font_size = "10px", color = advTextMuted,
           width = "34px", flex_shrink = "0", cursor = "ew-resize",
           user_select = "none", touch_action = "none"):
        text field.label
      input(ref = inputEl, `type` = "text", spellcheck = "false",
            autocomplete = "off", class = "editor-input",
            height = "22px", min_width = "0", flex = "1",
            padding = "0 6px", box_sizing = "border-box",
            border = "1px solid " & advBorder, border_radius = "4px",
            background_color = advTrough, color = advTextPrimary,
            font_family = "inherit", font_size = "11px")
  r.setAttribute(inputEl, "aria-label", field.ariaLabel)
  r.setAttribute(labelEl, "data-compound-scrub", field.ariaLabel)
  r.setAttribute(labelEl, "title", "Drag to scrub " & field.ariaLabel)
  r.appendChild(parent, node)

  var dirty = false
  var pressed = false
  var scrubbing = false
  var startX = 0.0
  var startText = ""
  var startValue = NaN
  var startUnit = ""

  proc resync() =
    r.setInputValue(inputEl, untrack(proc(): string = field.shown()))
  createRenderEffect proc() =
    let text = field.shown()
    if not dirty and not scrubbing:
      r.setInputValue(inputEl, text)
  createRenderEffect proc() =
    let reason = if field.reason != nil: field.reason() else: ""
    if reason.len > 0:
      r.setAttribute(inputEl, "readonly", "true")
      r.setAttribute(inputEl, "aria-readonly", "true")
      r.setAttribute(inputEl, "title", reason)
      r.setStyle(inputEl, "color", advTextMuted)
    else:
      r.removeAttribute(inputEl, "readonly")
      r.removeAttribute(inputEl, "aria-readonly")
      r.setAttribute(inputEl, "title", field.ariaLabel)
      r.setStyle(inputEl, "color", advTextPrimary)

  proc blocked(): bool =
    field.reason != nil and untrack(field.reason).len > 0

  var scrubCancelHook: proc() {.closure.} = proc() = discard

  proc commitText(text: string) =
    dirty = false
    let value = numberFieldValue(text, field.unit)
    if value.len == 0 or blocked():
      resync()
      return
    if not field.commit(value): resync()

  r.addEventListener(inputEl, "input", proc() = dirty = true)
  r.addEventListener(inputEl, "change", proc() =
    if dirty: commitText(r.inputValue(inputEl)))
  r.addEventListener(inputEl, "blur", proc() =
    if dirty: commitText(r.inputValue(inputEl)))
  r.addEventListener(inputEl, "keydown", proc(ev: auto) =
    let key = advKey(ev)
    if key == "Enter":
      preventAdvDefault(ev)
      stopAdvPropagation(ev)
      commitText(r.inputValue(inputEl))
    elif key == "Escape":
      if pressed:
        preventAdvDefault(ev)
        stopAdvPropagation(ev)
        scrubCancelHook()
      elif dirty:
        preventAdvDefault(ev)
        stopAdvPropagation(ev)
        dirty = false
        resync()
    elif key in ["ArrowUp", "ArrowDown"]:
      preventAdvDefault(ev)
      stopAdvPropagation(ev)
      if blocked(): return
      var size = if field.step > 0: field.step else: 1.0
      if advShift(ev): size *= 10.0
      elif advAlt(ev): size /= 10.0
      let next = steppedFieldValue(r.inputValue(inputEl), field.unit,
        if key == "ArrowUp": size else: -size, field.minimum, field.maximum)
      if next.len == 0: return
      r.setInputValue(inputEl, next)
      commitText(next))

  # The label scrubs: right increases, left decreases, by ``step`` per pixel
  # (Shift 10x, Alt 0.1x); the field shows the value as the pointer moves.
  proc scrubStart(x: float) =
    if blocked(): return
    pressed = true
    scrubbing = false
    startX = x
    startText = untrack(proc(): string = field.shown())
    let parsed = parseNumericInput(startText)
    startValue = if parsed.value.isSome: parsed.value.get else: NaN
    startUnit = parsed.unit
  proc scrubMove(x: float; shift, alt: bool) =
    if not pressed: return
    if not scrubbing:
      if abs(x - startX) < scrubThreshold: return
      if startValue.isNaN:
        pressed = false
        return
      scrubbing = true
      # Focus without selecting, so that Escape reaches the field during
      # the drag.
      when isDomViewHost(E):
        r.focus(inputEl)
    let value = scrubbedValue(startValue, x - startX, 0.0,
      if field.step > 0: field.step else: 1.0, shift, alt,
      field.minimum, field.maximum)
    let text = numberFieldValue(formatExactNumber(round(value * 1000.0) / 1000.0) &
      startUnit, field.unit)
    r.setInputValue(inputEl, text)
    if field.draft != nil: field.draft(text)
  proc scrubEnd() =
    if not pressed: return
    pressed = false
    if not scrubbing: return
    scrubbing = false
    let text = r.inputValue(inputEl)
    if text == startText:
      if field.draft != nil: field.draft("")
      return
    if field.draft != nil: field.draft("")
    commitText(text)
  proc scrubCancel() =
    if not pressed: return
    let was = scrubbing
    pressed = false
    scrubbing = false
    if was:
      r.setInputValue(inputEl, startText)
      if field.draft != nil: field.draft("")
  scrubCancelHook = scrubCancel
  if field.generation != nil:
    var seen = -1
    createRenderEffect proc() =
      let now = field.generation()
      if seen >= 0 and now != seen:
        untrack(proc() =
          dirty = false
          scrubCancel()
          resync())
      seen = now
  when isDomViewHost(E):
    r.addEventListener(labelEl, "pointerdown", proc(ev: auto) =
      if advButton(ev) == 0:
        captureAdvPointer(labelEl, ev)
        preventAdvDefault(ev))
  r.addPointerListener(labelEl, "pointerdown", proc(x, y: float; shift, alt: bool) =
    scrubStart(x))
  r.addPointerListener(labelEl, "pointermove", proc(x, y: float; shift, alt: bool) =
    scrubMove(x, shift, alt))
  r.addPointerListener(labelEl, "pointerup", proc(x, y: float; shift, alt: bool) =
    scrubEnd())
  r.addEventListener(labelEl, "pointercancel", proc() = scrubCancel())
  r.addEventListener(labelEl, "lostpointercapture", proc() = scrubCancel())
  r.addEventListener(labelEl, "keydown", proc(ev: auto) =
    if advKey(ev) == "Escape" and pressed:
      stopAdvPropagation(ev)
      scrubCancel())
  onCleanup(proc() = scrubCancel())
  inputEl
