## The per-section Raw CSS editor of the section-based inspector.
##
## Editor spec "Editing Controls (Figma-Grade Affordances)" → "Universal
## Patterns": "Raw CSS toggle — switch to raw CSS text editing for any
## section". The section-based redesign keeps those controls in force
## ("Property row pattern": the redesign "is about LAYOUT, not the
## per-control sophistication"), and the section's own clause under
## "Universal Patterns" states the behaviour this module implements.
##
## Every section that edits CSS ends with a raw CSS field
## (`Edit raw CSS for <Section> section`) and the section's Raw CSS toggle
## (`Show raw CSS for <Section> section`, a pressed/unpressed button):
##
## * On the section's rows (the default) the field is a one-line entry under
##   them. Declarations typed there are committed and the entry clears.
## * Toggled on, the section is switched to raw CSS text editing: its rows are
##   hidden and the field shows every declaration the section's rows edit for
##   the selection, one `property: value;` per line, editable as text.
##   Toggling again shows the rows.
##
## Which properties a section edits is not a second catalogue kept next to the
## widgets. Every row wired to the source pipeline registers its
## `InspectorRowWiring` with the section it is mounted in, through the
## reactive owner tree (`inspectorSectionCssContext`, provided per section by
## `shell.renderInspectorPanel`), exactly as rows register their searchable
## text with `inspector_search`. The raw editor therefore covers precisely
## the properties the section's rows edit, in their order, and commits each
## declaration through that row's own wiring: the scope the row commits at
## (including a scope the user chose on the row), the same validation,
## writer refusals, preview, undo entry and automatic save.
##
## A commit is checked as a whole before anything moves (spec "Saving": "A
## refusal the editor can know at the act is made at the act"): the text must
## parse, each declaration must name a property this section edits and the
## selection exposes, and each changed declaration must be admitted at its
## row's scope (`propertyValueCommitRefusal`). Any refusal refuses the
## commit, with the reason where it was made, and changes nothing.
## Declarations whose value is already the property's value are not edits.
## A declaration left out of the text is left as it is: removing a
## declaration is Reset, in the row's menu.

import std/[options, strutils]

import isonim/core/[signals, computation, owner, context, batch]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import ./property_commit

when defined(js):
  import std/dom
  import isonim/web/dom_api

# --------------------------------------------------------------------------- #
#  The section's row registry.
# --------------------------------------------------------------------------- #

type
  SectionCssRow = object
    id: int
    wiring: InspectorRowWiring

  InspectorSectionCss* = ref object
    ## The source-wired rows mounted in one inspector section. Reactive:
    ## rows mount and unmount (Typography for text only, State rows rebuilt
    ## per selection, Layout's mode wirings re-created per selection ...).
    mounted: Signal[seq[SectionCssRow]]
    order: seq[string]
      ## Properties in first-mounted order. A row that is re-mounted keeps
      ## its place, so the raw text does not reshuffle on reselection.
    nextId: int

let inspectorSectionCssContext* = createContext[InspectorSectionCss](nil)

proc createInspectorSectionCss*(): InspectorSectionCss =
  InspectorSectionCss(mounted: createSignal[seq[SectionCssRow]](@[]))

proc rows*(registry: InspectorSectionCss): seq[InspectorRowWiring] =
  ## One wiring per property the section's mounted rows edit, in
  ## first-mounted order; the first mounted row of a property stands for it.
  ## Reactive.
  if registry == nil: return
  let mounted = registry.mounted.val
  for property in registry.order:
    for row in mounted:
      if row.wiring.cssProperty == property:
        result.add row.wiring
        break

proc registerSectionCssRow*(registry: InspectorSectionCss;
    wiring: InspectorRowWiring) =
  ## Register ``wiring`` with ``registry`` for as long as the current owner
  ## lives. A wiring without a CSS property or a commit (a zeroed or
  ## inspect-only row) is not a source-wired row and is ignored.
  if registry == nil or wiring.cssProperty.len == 0 or
      wiring.commitAsync == nil:
    return
  if registry.order.find(wiring.cssProperty) < 0:
    registry.order.add wiring.cssProperty
  inc registry.nextId
  let id = registry.nextId
  untrack(proc() =
    var next = registry.mounted.val
    next.add SectionCssRow(id: id, wiring: wiring)
    registry.mounted.val = next)
  onCleanup(proc() =
    untrack(proc() =
      var next = registry.mounted.val
      for i in 0 ..< next.len:
        if next[i].id == id:
          next.delete(i)
          registry.mounted.val = next
          return))

proc registerSectionCssRow*(wiring: InspectorRowWiring) =
  ## Register ``wiring`` with the enclosing inspector section, if any. A row
  ## mounted outside a section (widget tests, the variable editor) finds no
  ## registry and does nothing.
  registerSectionCssRow(useContext(inspectorSectionCssContext), wiring)

proc useInspectorSectionCss*(): InspectorSectionCss =
  ## The enclosing section's registry, for a widget that creates wirings
  ## later, under an owner of its own (Layout's per-selection mode wirings).
  useContext(inspectorSectionCssContext)

# --------------------------------------------------------------------------- #
#  CSS text.
# --------------------------------------------------------------------------- #

type
  RawCssDeclaration* = object
    property*: string
    value*: string

  RawCssParse* = object
    ## ``error`` is empty exactly when the text parsed.
    declarations*: seq[RawCssDeclaration]
    error*: string

func isPropertyName(name: string): bool =
  ## A CSS property name: an identifier of letters, digits, `-` and `_`
  ## (custom properties `--x` included), not starting with a digit.
  ## https://www.w3.org/TR/css-syntax-3/#ident-token-diagram
  if name.len == 0 or name[0] in Digits: return false
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: return false
  name != "-" and name != "--"

func hasImportantFlag(value: string): bool =
  ## Whether ``value`` ends with the `!important` flag (`!`, optional
  ## whitespace, `important`, ASCII case-insensitive). Only the end of a
  ## declaration's value can carry it
  ## (https://www.w3.org/TR/css-syntax-3/#consume-declaration), so a quoted
  ## string that merely contains the word does not.
  let lowered = value.strip().toLowerAscii()
  if not lowered.endsWith("important"): return false
  let before = lowered[0 ..< lowered.len - "important".len].strip(leading = false)
  before.endsWith("!")

func parseRawCss*(text: string): RawCssParse =
  ## Parse the raw CSS of a section: declarations `property: value`,
  ## separated by `;` or a line break outside quotes and brackets, with
  ## `/* … */` comments. The syntax is the declaration list of a style rule
  ## (https://www.w3.org/TR/css-syntax-3/#parse-a-list-of-declarations),
  ## restricted to what an inspector row can write: a declaration must have
  ## a property name and a value, `!important` is refused (a row writes the
  ## one declaration that owns the property, and has no importance to set),
  ## and a line break outside brackets ends a declaration so that a typed
  ## list needs no semicolons. A later declaration of the same property
  ## replaces an earlier one, as in a style rule.
  var fragments: seq[string] = @[]
  var current = ""
  var depth = 0
  var quote = '\0'
  var i = 0
  while i < text.len:
    let c = text[i]
    if quote != '\0':
      current.add c
      if c == '\\' and i + 1 < text.len:
        current.add text[i + 1]
        inc i
      elif c == quote:
        quote = '\0'
      elif c == '\n':
        return RawCssParse(error: "Unterminated string in the raw CSS.")
    elif c == '/' and i + 1 < text.len and text[i + 1] == '*':
      let close = text.find("*/", i + 2)
      if close < 0:
        return RawCssParse(error: "Unterminated comment in the raw CSS.")
      current.add ' '
      i = close + 1
    elif c in {'"', '\''}:
      quote = c
      current.add c
    elif c in {'(', '['}:
      inc depth
      current.add c
    elif c in {')', ']'}:
      if depth == 0:
        return RawCssParse(error: "Unbalanced '" & $c & "' in the raw CSS.")
      dec depth
      current.add c
    elif c in {'{', '}'}:
      return RawCssParse(error: "The raw CSS of a section holds declarations " &
        "only, without a selector or braces.")
    elif depth == 0 and (c == ';' or c == '\n'):
      fragments.add current
      current = ""
    elif c == '\n' or c == '\r' or c == '\t':
      current.add ' '
    else:
      current.add c
    inc i
  if quote != '\0':
    return RawCssParse(error: "Unterminated string in the raw CSS.")
  if depth != 0:
    return RawCssParse(error: "Unclosed bracket in the raw CSS.")
  fragments.add current
  for fragment in fragments:
    let declaration = fragment.strip()
    if declaration.len == 0: continue
    let colon = declaration.find(':')
    if colon < 0:
      return RawCssParse(error: "`" & declaration &
        "` is not a declaration; write property: value.")
    # Property names are ASCII case-insensitive, except a custom property's,
    # which is case-sensitive (https://www.w3.org/TR/css-variables-1/#defining-variables).
    let name = declaration[0 ..< colon].strip()
    let property = if name.startsWith("--"): name else: name.toLowerAscii()
    let value = declaration[colon + 1 .. ^1].strip()
    if not property.isPropertyName:
      return RawCssParse(error: "`" & declaration[0 ..< colon].strip() &
        "` is not a CSS property name.")
    if value.len == 0:
      return RawCssParse(error: property & " has no value. To remove a " &
        "declaration, use Reset in the " & property & " row's menu.")
    if value.hasImportantFlag:
      return RawCssParse(error: property & ": !important cannot be set " &
        "here; the editor writes the one declaration that owns the property.")
    var replaced = false
    for existing in result.declarations.mitems:
      if existing.property == property:
        existing.value = value
        replaced = true
    if not replaced:
      result.declarations.add RawCssDeclaration(property: property,
        value: value)

func formatRawCss*(declarations: openArray[RawCssDeclaration]): string =
  ## One `property: value;` per line -- the text the raw editor shows and
  ## `parseRawCss` reads back.
  for declaration in declarations:
    result.add declaration.property & ": " & declaration.value & ";\n"

proc rawCssValue(prop: PropertyInfo): string =
  ## The value a declaration shows: what the source authored, when known,
  ## otherwise the value the inspector reads.
  if prop.authoredValue.len > 0: prop.authoredValue else: prop.value

proc sectionRawCssDeclarations*(vm: EditorVM;
    registry: InspectorSectionCss): seq[RawCssDeclaration] =
  ## The section's declarations for the selection: every property its rows
  ## edit that the selection exposes with a value, in row order. Reactive.
  if registry == nil: return
  for row in registry.rows:
    let found = vm.inspectorProperty(row.cssProperty)
    if found.isNone: continue
    let value = found.get.rawCssValue.strip()
    if value.len > 0:
      result.add RawCssDeclaration(property: row.cssProperty, value: value)

# --------------------------------------------------------------------------- #
#  Commit.
# --------------------------------------------------------------------------- #

type
  RawCssCommitOutcome* = object
    ## ``ok`` is false for every refusal, and ``message`` then says why.
    ## ``changed`` lists the properties that were committed, in order.
    ok*: bool
    message*: string
    changed*: seq[string]

func rawCssRefusal(message: string): RawCssCommitOutcome =
  RawCssCommitOutcome(ok: false, message: message)

proc hasNativeSourceCommit(vm: EditorVM): bool =
  vm.hasAsyncSourceProject or vm.inspectorSourceCommit != nil

proc commitSectionRawCss*(vm: EditorVM; registry: InspectorSectionCss;
    sectionName, text: string;
    done: proc(outcome: RawCssCommitOutcome) {.closure.} = nil):
    RawCssCommitOutcome {.discardable.} =
  ## Commit the raw CSS ``text`` of the section ``sectionName``.
  ##
  ## Checked as a whole first; then each changed declaration is committed, in
  ## text order, through its row's wiring -- one edit on the editor's one
  ## undo timeline per declaration. In a project written by the editor
  ## itself (a `WorkspaceEditAdapter`) the edits join one automatic write. A
  ## native source project writes each committed declaration as its own
  ## guarded request; a raw commit there changes one declaration at a time,
  ## for the reason Layout's mode control gives: two independent writes could
  ## leave half of the change applied.
  ##
  ## The returned outcome is final for a refusal and for a synchronous
  ## project. ``done`` is called with the final outcome in every case, after
  ## a native project has answered.
  proc finish(outcome: RawCssCommitOutcome): RawCssCommitOutcome =
    if done != nil: done(outcome)
    outcome

  let parsed = parseRawCss(text)
  if parsed.error.len > 0:
    return finish(rawCssRefusal(parsed.error))
  var wirings: seq[InspectorRowWiring] = @[]
  var changes: seq[RawCssDeclaration] = @[]
  let rows = untrack(proc(): seq[InspectorRowWiring] = registry.rows)
  for declaration in parsed.declarations:
    var wiring = InspectorRowWiring()
    for row in rows:
      if row.cssProperty == declaration.property:
        wiring = row
        break
    if wiring.cssProperty.len == 0:
      return finish(rawCssRefusal(declaration.property &
        " is not edited in the " & sectionName & " section."))
    let found = vm.inspectorProperty(declaration.property)
    if found.isNone:
      return finish(rawCssRefusal("The selected element does not expose " &
        declaration.property & "."))
    let current = found.get.rawCssValue.strip()
    if declaration.value == current or normalizePrimitiveInputValue(
        declaration.property, declaration.value) == current:
      continue
    let readOnly = wiring.readOnlyReason()
    if readOnly.len > 0:
      return finish(rawCssRefusal(declaration.property & ": " & readOnly))
    let selected = wiring.selectedSourceScope()
    let scope = if selected.isSome: selected.get.kind else: sskLocalInstance
    let refusal = vm.propertyValueCommitRefusal(declaration.property,
      declaration.value, scope)
    if refusal.len > 0:
      return finish(rawCssRefusal(declaration.property & ": " & refusal))
    wirings.add wiring
    changes.add declaration
  if changes.len > 1 and vm.hasNativeSourceCommit:
    return finish(rawCssRefusal("This project's source connection writes " &
      "one declaration at a time; commit the " & $changes.len &
      " changed declarations one by one."))
  if changes.len == 0:
    return finish(RawCssCommitOutcome(ok: true))

  # Every change was admitted. Commit them in order; a refusal that only the
  # commit itself can know stops the rest and says what was applied.
  var committed: seq[string] = @[]
  var outcome = RawCssCommitOutcome(ok: true)
  var settled = false
  proc commitFrom(index: int) =
    if index >= changes.len:
      outcome = RawCssCommitOutcome(ok: true, changed: committed)
      settled = true
      if done != nil: done(outcome)
      return
    let wiring = wirings[index]
    let declaration = changes[index]
    wiring.commitAsync(declaration.value, proc(ok: bool) =
      if ok:
        committed.add declaration.property
        commitFrom(index + 1)
      else:
        let reason = wiring.commitMessage.val
        var message = declaration.property & ": " &
          (if reason.len > 0: reason else: "the edit was refused.")
        if committed.len > 0:
          message.add " Applied before it: " & committed.join(", ") & "."
        outcome = RawCssCommitOutcome(ok: false, message: message,
          changed: committed)
        settled = true
        if done != nil: done(outcome))
  commitFrom(0)
  if settled: outcome
  else: RawCssCommitOutcome(ok: true, changed: committed)

# --------------------------------------------------------------------------- #
#  View.
# --------------------------------------------------------------------------- #

const
  textPrimary = "#ECEDF3"
  textMuted = "#6B6F80"
  border = "#2A2C3A"
  accent = "#7C7AED"
  bgInput = "#1A1B22"
  danger = "#F87171"

when defined(js):
  proc readRawCssKey[E: dom.Event | dom_api.Event](ev: E): cstring
    {.importjs: "(#.key || '')".}
  proc readRawCssShift[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.shiftKey)".}
  proc readRawCssComposing[E: dom.Event | dom_api.Event](ev: E): bool
    {.importjs: "(!!#.isComposing)".}

  proc rawCssKey(ev: dom.Event | dom_api.Event): string = $readRawCssKey(ev)
  proc rawCssShift(ev: dom.Event | dom_api.Event): bool = readRawCssShift(ev)
  proc rawCssComposing(ev: dom.Event | dom_api.Event): bool =
    readRawCssComposing(ev)

proc rawCssKey[E](ev: E): string = ev.key
proc rawCssShift[E](ev: E): bool = ev.shiftKey
proc rawCssComposing[E](ev: E): bool = false

func rawCssFieldLabel*(sectionName: string): string =
  "Edit raw CSS for " & sectionName & " section"

func rawCssToggleLabel*(sectionName: string): string =
  "Show raw CSS for " & sectionName & " section"

proc mountSectionRawCss*[R, E](r: R; parent, rows: E; vm: EditorVM;
    registry: InspectorSectionCss; section: InspectorSection;
    slug, sectionName: string) =
  ## Mount the raw CSS field and toggle of one section at the end of
  ## ``parent``; ``rows`` is the host of the section's rows, hidden while
  ## the section shows raw CSS.
  var field, toggle, message: E
  let host = ui(r):
    tdiv(`data-section-raw-css` = slug,
         display = "flex", flex_direction = "column", gap = "4px",
         padding_top = "6px", min_width = "0"):
      tdiv(display = "flex", align_items = "flex-start", gap = "4px",
           min_width = "0"):
        textarea(ref = field,
                 class = "editor-input",
                 `data-section-raw-css-input` = slug,
                 `data-isonim-focus-id` = "raw-css-" & slug,
                 rows = "1",
                 spellcheck = "false",
                 placeholder = "property: value",
                 flex = "1", min_width = "0",
                 min_height = "24px",
                 box_sizing = "border-box",
                 padding = "4px 6px",
                 background_color = bgInput,
                 border = "1px solid " & border,
                 border_radius = "4px",
                 color = textPrimary,
                 font_family = "monospace",
                 font_size = "11px",
                 line_height = "16px",
                 outline = "none",
                 white_space = "pre",
                 overflow_x = "auto")
        button(ref = toggle, `type` = "button",
               `data-section-raw-css-toggle` = slug,
               `aria-pressed` = "false",
               title = "Raw CSS",
               flex_shrink = "0",
               height = "24px", padding = "0 6px",
               border = "1px solid " & border, border_radius = "4px",
               background_color = "transparent",
               color = textMuted,
               font_family = "monospace", font_size = "11px",
               cursor = "pointer"):
          text "{ }"
      tdiv(ref = message,
           `data-section-raw-css-message` = slug,
           role = "alert",
           display = "none",
           color = danger, font_size = "11px")
  r.setAttribute(field, "aria-label", rawCssFieldLabel(sectionName))
  r.setAttribute(toggle, "aria-label", rawCssToggleLabel(sectionName))
  r.setStyle(message, "overflow-wrap", "anywhere")
  r.appendChild(parent, host)

  let refusal = createSignal("")
  # The text differs from what the model shows because the user typed it.
  # While it does, a model change (an automatic write, a preview read) does
  # not overwrite it; a new selection, a commit or Escape ends it.
  var dirty = false
  var refusedText = ""
  var selectionKey = ""

  proc rawMode(): bool = vm.inspector.sectionShowsRawCss(section)

  proc modelText(): string =
    if rawMode(): formatRawCss(vm.sectionRawCssDeclarations(registry))
    else: ""

  proc resync() =
    let text = untrack(proc(): string = modelText())
    r.setInputValue(field, text)

  proc commit() =
    let text = r.inputValue(field)
    if not dirty or text == refusedText: return
    let story = vm.selectedStory.val
    let selected = vm.inspector.selectedElement.val.id
    discard commitSectionRawCss(vm, registry, sectionName, text,
      proc(outcome: RawCssCommitOutcome) =
        # A native project answers later; the answer belongs to the
        # selection it was made for.
        if vm.selectedStory.val != story or
            vm.inspector.selectedElement.val.id != selected: return
        if outcome.ok:
          dirty = false
          refusedText = ""
          refusal.val = ""
          resync()
        else:
          refusedText = text
          refusal.val = outcome.message)

  proc revert() =
    dirty = false
    refusedText = ""
    refusal.val = ""
    resync()

  # Mode, text and selection. The rows host keeps its own display value
  # (a flex column) while the section shows its rows.
  createRenderEffect proc() =
    let raw = rawMode()
    let el = vm.inspector.selectedElement.val
    let story = vm.selectedStory.val
    let key = story.group & " / " & story.name & " / " & el.id
    let text = modelText()
    if key != selectionKey:
      selectionKey = key
      dirty = false
      refusedText = ""
      untrack(proc() = refusal.val = "")
    r.setStyle(rows, "display", if raw: "none" else: "flex")
    r.setAttribute(toggle, "aria-pressed", if raw: "true" else: "false")
    r.setAttribute(host, "data-section-raw-css-mode",
      if raw: "text" else: "rows")
    r.setStyle(toggle, "color", if raw: accent else: textMuted)
    r.setStyle(toggle, "border-color", if raw: accent else: border)
    let lines = max(1, text.count('\n'))
    r.setAttribute(field, "rows", if raw: $min(16, lines + 1) else: "1")
    r.setStyle(field, "resize", if raw: "vertical" else: "none")
    if not dirty:
      r.setInputValue(field, text)

  createRenderEffect proc() =
    let reason = refusal.val
    r.setTextContent(message, reason)
    r.setStyle(message, "display", if reason.len > 0: "block" else: "none")
    if reason.len > 0: r.setAttribute(field, "aria-invalid", "true")
    else: r.removeAttribute(field, "aria-invalid")

  r.addEventListener(toggle, "click", proc() =
    # Leaving the field for the toggle commits what was typed, as leaving
    # any text field does (a browser has already blurred the field, and this
    # is then a no-op); the toggle then switches what the section shows. Text
    # whose commit was refused stays in the field with its reason, in either
    # mode, until it is corrected or discarded with Escape.
    commit()
    vm.inspector.toggleSectionRawCss(section))
  r.addEventListener(field, "input", proc() =
    dirty = true)
  r.addEventListener(field, "blur", proc() = commit())
  r.addEventListener(field, "keydown", proc(ev: auto) =
    mixin preventDefault
    let key = rawCssKey(ev)
    if key == "Enter" and not rawCssShift(ev) and not rawCssComposing(ev):
      # Enter commits, as in every inspector text field (spec "Saving": "A
      # text field commits on change (Enter or leaving the field)");
      # Shift+Enter is a line break.
      when compiles(ev.preventDefault()):
        ev.preventDefault()
      elif defined(js):
        proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
        prevent(ev)
      dirty = true
      commit()
    elif key == "Escape" and (dirty or refusal.val.len > 0):
      when compiles(ev.preventDefault()):
        ev.preventDefault()
      elif defined(js):
        proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
        prevent(ev)
      revert())
