## Phase D — Property row widget for the Editor sidebar redesign.
##
## Reusable property row that implements the spec's 4-slot pattern:
##
##   ``[label-scrubber]   [value-input + unit-chip]   [bind]   [⫶]``
##
## A single row hosts one of five control kinds (numeric, color,
## choice, text, boolean) plus three optional affordances (scrub-drag
## label, bind chip, more menu). The widget is built bottom-up to fit
## inside a section body — Phase G will sweep the legacy
## ``renderPropertyInput`` callers from ``component_edit.nim`` and
## reuse this widget instead.
##
## Design contract (mirrors the spec in
## ``isonim-specs/isonim-editor.md``
## § "Property row pattern" + § "Editing Controls"):
##
##   * **Label scrubber** is a 80px-wide span. For ``prkNumeric`` it
##     carries ``cursor: col-resize`` and accepts click-drag (mousedown
##     → mousemove → mouseup) that nudges the value by
##     ``numericStep`` per pixel. Shift multiplies the step by 10,
##     Alt divides by 10.
##   * **Value-input + unit-chip** is a flex-1 host. The visual fill
##     and metrics match the Figma reference: ``#1A1B22`` background,
##     4px radius, 4px x 8px padding, 12px font, 26px height.
##     - ``prkNumeric`` — text input + a right-aligned unit chip that
##       cycles available units on click.
##     - ``prkColor`` — 16x16 swatch + hex text input.
##     - ``prkChoice`` — embedded ``mountSegmentedChoice`` widget.
##     - ``prkText`` — plain text input.
##     - ``prkBoolean`` — checkbox toggle.
##   * **Bind affordance** is a 24px-wide ``◇`` button. When
##     ``binding.isSome``, the value-input area renders a "linked
##     chip" placeholder carrying ``data-property-row-linked="true"``
##     so Phase E.2 can upgrade the styling without re-touching this
##     widget.
##   * **More (⫶)** is a 20x20 button that calls ``config.onMore``.
##
## Reactive wiring uses ``createRenderEffect`` and ``setAttribute`` —
## NO ``setStyle`` calls outside reactive effects, NO raw
## ``createElement``. The widget delegates math-expression evaluation
## to ``evalMathExpr`` (a tiny recursive-descent parser for
## ``+ - * /`` so the user can type ``100+50`` and get 150).
##
## Data attributes exposed on the row root (for Phase G / tests):
##
##   * ``data-property-row=<slug>``
##   * ``data-property-row-kind=<numeric|color|choice|text|boolean>``
##   * ``data-property-row-name=<display name>``
##   * ``data-property-row-linked=<true|false>``
##
## Test fixture: ``tests/test_editor_widget_property_row.nim``.

import std/[math, options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/views/choice_row
import isonim/editor/views/widgets/choice_group
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/variable_chip

# --------------------------------------------------------------------------- #
#  Public types.
# --------------------------------------------------------------------------- #

type
  PropertyRowKind* = enum
    prkNumeric        ## Scrubbable numeric with unit chip.
    prkColor          ## Color swatch + hex input.
    prkChoice         ## One-of-many segmented control.
    prkText           ## Free-form text input.
    prkBoolean        ## Checkbox toggle.

  PropertyUnitOption* = object
    ## A unit option for the numeric input's unit chip. ``label`` is
    ## the human-readable string shown on the chip (e.g. ``"px"``);
    ## ``code`` is the CSS unit token that gets appended to the value
    ## when the input is committed. ``code == ""`` is the ``auto``
    ## sentinel — no unit token gets appended.
    label*: string
    code*: string

  PropertyRowConfig* = object
    ## Discriminated configuration for a single property row. Each
    ## branch carries the reactive signal(s) for that control kind.
    name*: string
    case kind*: PropertyRowKind
    of prkNumeric:
      numericValue*: Signal[float]
      numericUnit*: Signal[PropertyUnitOption]
      availableUnits*: seq[PropertyUnitOption]
      numericMin*: Option[float]
      numericMax*: Option[float]
      numericStep*: float
    of prkColor:
      colorValue*: Signal[string]
      alphaValue*: Signal[float]
    of prkChoice:
      choiceValue*: Signal[string]
      choiceOptions*: seq[tuple[label: string; value: string]]
    of prkText:
      textValue*: Signal[string]
    of prkBoolean:
      booleanValue*: Signal[bool]

    # Optional binding — when set, the value-input slot collapses
    # into a "linked chip" placeholder so Phase E.2's variable picker
    # can find every row that is currently bound to a foundations
    # variable.
    binding*: Option[VariableBinding]

    # Optional REACTIVE binding source (VBIND-M2 hot-swap). When set,
    # the mount ignores the static ``binding`` above and instead reads
    # this closure INSIDE a ``createRenderEffect`` so the value slot
    # re-renders the chip vs. the literal control live whenever the
    # binding changes (a variable is linked/unlinked, or the selection
    # moves to/from a bound element) — without the parent section
    # having to re-mount the row. ``nil`` keeps the legacy static
    # behaviour (built once from ``binding``), so callers that pass
    # neither are byte-unchanged.
    bindingReactive*: proc(): Option[VariableBinding]

    # Callbacks — every callback is allowed to be ``nil``; the mount
    # treats a nil callback as a no-op.
    onChange*: proc()
    onBindRequest*: proc(x, y, w, h: float)
      ## VBIND-M2: fired when the bind affordance (the ``◇`` slot or the
      ## chip chevron) is clicked. The mount measures the affordance's
      ## document rect (``getBoundingClientRect`` + scroll on the JS
      ## side; zeros headless) and passes it so the parent can anchor
      ## the variable picker to this row. Nil is a no-op.
    onMore*: proc()
    onDetachRequest*: proc()
      ## Phase E.2 (2026-05-28): invoked when the linked chip's
      ## detach affordance is clicked. The parent (typically the
      ## inspector section) routes this to
      ## ``vm.detachPropertyBinding(key, detachedValue)``. Nil is a
      ## no-op so the chip still tolerates a missing handler — the
      ## detach affordance stays visible but inert.
    onVariableNameClick*: proc()
      ## Phase E.4 (2026-05-28): invoked when the linked chip's
      ## variable name is clicked. Parents route this to the inline
      ## variable editor (Phase E.4). Nil is a no-op.

    # --- Phase G+1: source-edit writeback ------------------------- #
    #
    # Everything below is optional. A config that leaves these zeroed
    # renders and behaves exactly as it did before Phase G+1 — which
    # is what ``tests/test_editor_widget_property_row.nim`` and any
    # non-inspector caller get. The inspector sections fill them from
    # ``property_commit.inspectorRowWiring``.
    cssProperty*: string
      ## The CSS property this row edits (``"padding-top"``,
      ## ``"font-size"``, …). The row had no representation for this
      ## at all: the property name existed only inside the three
      ## strings a section passed to the binding helpers, so the row
      ## could scrub and format a value but could not name what to
      ## commit it as. Empty means "not an inspector row".
    scopeOptions*: proc(): seq[CompactChoiceOption]
      ## Thunk of source-scope chips for the bind/scope slot. The spec
      ## (``isonim-specs/isonim-editor.md`` §"Property row pattern",
      ## ~1010) defines slot 3 as **Bind/scope** — "the source-scope
      ## mini-picker (Local / Shared / Component schema / Theme
      ## token)". Phases D–H shipped the bind half (the ``◇``) and not
      ## the scope half, which is why the sections had nowhere to say
      ## which source an edit should modify. Nil keeps the slot
      ## bind-only.
    commitMessage*: Signal[string]
    commitRejected*: Signal[int]
      ## See `InspectorRowWiring.commitRejected`: a refused commit must put
      ## the control back, or the panel keeps showing a value the document
      ## does not have.
      ## Refusal / diagnostic text for the last commit attempt,
      ## rendered inline under the row. Nil means the row has no
      ## message surface — acceptable only for rows that cannot
      ## commit at all.
    onCommitValue*: proc(value: string)
      ## Called with the row's value rendered as the CSS string that
      ## should reach the source-edit pipeline (``"24px"``,
      ## ``"#F8FAFC"``, ``"flex"``, …). Distinct from ``onChange``,
      ## which stays a bare notification so existing callers are
      ## unaffected: both fire, ``onCommitValue`` first.

# --------------------------------------------------------------------------- #
#  Visual contract — pulled from the spec's editing-control reference.
# --------------------------------------------------------------------------- #

const
  # Slot widths.
  # Phase H (2026-05-28): the label scrubber column shrinks from 80px
  # to a tight prefix-letter cell — the Figma reference puts a faded
  # single-letter prefix INSIDE the input (X / Y / W / H / etc.). The
  # outer slot stays present (preserves the
  # ``data-property-row-slot="label-scrubber"`` test contract + the
  # scrub-drag region) but its visual weight drops dramatically: the
  # column is now a 22px-wide gutter that holds the (short) property
  # name in textMuted, and the longer property names just truncate.
  prLabelWidth   = "22px"
  # A row that gets no inline glyph has to write its name somewhere. 88px
  # is measured, not guessed: at 76px the longest names in the catalogue
  # ("Paragraph spacing", "Text alignment", "Text transform") ellipsised to
  # "Paragraph s...", which defeats the purpose of writing the label at all.
  # 88px clears all three and still leaves ~130px for the value, which is
  # more than a number with a unit chip or a popup trigger needs.
  prLabelWideWidth = "88px"
  prBindWidth    = "20px"
  prMoreWidth    = "18px"

  # Row metrics — single dense line, 24px tall to match the Figma
  # reference (was 26px). The wrapper carries a 2px vertical gutter
  # (was 4px) so adjacent rows pack tighter — the reference looks
  # 1.5x denser than the prior Phase D contract.
  prRowMinHeight = "24px"
  prRowGap       = "6px"
  prRowVPad      = "2px"

  # Input visual contract. Phase H: drop the visible border so the
  # input reads as a quiet rounded pill (Figma's pattern); the input
  # gets a subtle hover border via the injected stylesheet so
  # affordance is preserved without a constant 1px line.
  prInputBg      = "#1A1B22"
  prInputColor   = "#F1F5F9"
  prInputBorder  = "1px solid transparent"
  prInputRadius  = "4px"
  prInputPadding = "3px 8px"
  prInputHeight  = "24px"
  prInputFont    = "12px"

  # Inline prefix glyph (the "X" / "Y" / "W" / "H" letter sitting
  # inside the input). Faded so the value reads loudest.
  prPrefixColor   = "#6B6F80"
  prPrefixFont    = "11px"
  prPrefixWidth   = "12px"

  # Label scrubber (outer). Phase H: now a thin gutter — the property
  # name is rendered inside the input as a prefix; the outer slot
  # only exists to host the scrub-drag affordance.
  prLabelColor   = "#6B6F80"
  prLabelFont    = "11px"

  # Unit chip. Phase H: dropped background — the chip reads as plain
  # muted text right-aligned inside the input. Figma's pattern.
  # Refusal line. Amber rather than red: a refused edit is a
  # correctable condition (wrong scope, read-only workspace), not a
  # crash, and the palette reserves red for review errors.
  prMessageColor = "#FBBF24"

  prUnitBg       = "transparent"
  prUnitColor    = "#6B6F80"
  prUnitPadding  = "0 2px"
  prUnitFont     = "11px"
  prUnitRadius   = "0"

  # Bind affordance. Phase H: hidden by default; CSS rule in
  # ``injectEditorStyles`` flips opacity to 1 on row hover/focus.
  prBindColor    = "#6B6F80"
  prBindFont     = "13px"

  # More affordance. Same hover-reveal behaviour.
  prMoreColor    = "#6B6F80"
  prMoreFont     = "13px"

  # Swatch.
  prSwatchSize   = "14px"
  prSwatchBorder = "1px solid rgba(255, 255, 255, 0.12)"

# --------------------------------------------------------------------------- #
#  Helpers.
# --------------------------------------------------------------------------- #

proc propertyRowSlug*(name: string): string =
  ## Lowercases and replaces spaces with dashes for the
  ## ``data-property-row`` attribute. Exposed because Phase G tests
  ## want the same slugger when querying for a row by name.
  result = newStringOfCap(name.len)
  for ch in name:
    if ch == ' ': result.add '-'
    else: result.add toLowerAscii(ch)

proc formatNumber*(value: float): string =
  ## Pretty-print a float for the value input. Integers come back
  ## without a trailing ``.0`` (so the user sees ``150`` not
  ## ``150.0``); otherwise we round to 2 decimal places to keep the
  ## input box compact.
  if abs(value - float(int(value))) < 1e-6:
    return $int(value)
  let rounded = round(value * 100.0) / 100.0
  result = $rounded

# ----- Tiny math expression evaluator ------------------------------------ #
#
# Supports ``+ - * /`` with the usual precedence and parenthesised
# sub-expressions. Returns ``some(value)`` on success. The parser
# tolerates leading / trailing whitespace and a trailing unit suffix
# (``"100+50px"`` parses to 150 — the unit is dropped on the floor;
# the caller already tracks the active unit via the signal).
#
# Implementation is intentionally small (recursive descent) — the
# inspector only ever sees short expressions so we don't need a full
# tokenizer.

type
  MathParser = object
    src: string
    pos: int

proc peek(p: MathParser): char =
  if p.pos < p.src.len: p.src[p.pos] else: '\0'

proc skipSpaces(p: var MathParser) =
  while p.pos < p.src.len and p.src[p.pos] in {' ', '\t'}:
    inc p.pos

proc parseExpr(p: var MathParser): Option[float]

proc parseNumber(p: var MathParser): Option[float] =
  skipSpaces(p)
  let start = p.pos
  if p.peek == '+' or p.peek == '-':
    inc p.pos
  var sawDigit = false
  while p.pos < p.src.len and p.src[p.pos].isDigit:
    inc p.pos
    sawDigit = true
  if p.peek == '.':
    inc p.pos
    while p.pos < p.src.len and p.src[p.pos].isDigit:
      inc p.pos
      sawDigit = true
  if not sawDigit:
    return none(float)
  try:
    return some(parseFloat(p.src[start ..< p.pos]))
  except ValueError:
    return none(float)

proc parsePrimary(p: var MathParser): Option[float] =
  skipSpaces(p)
  if p.peek == '(':
    inc p.pos
    let inner = parseExpr(p)
    skipSpaces(p)
    if p.peek == ')': inc p.pos
    return inner
  parseNumber(p)

proc parseMulDiv(p: var MathParser): Option[float] =
  var left = parsePrimary(p)
  if left.isNone: return left
  while true:
    skipSpaces(p)
    let op = p.peek
    if op != '*' and op != '/': break
    inc p.pos
    let right = parsePrimary(p)
    if right.isNone: return none(float)
    case op
    of '*': left = some(left.get * right.get)
    of '/':
      if right.get == 0.0: return none(float)
      left = some(left.get / right.get)
    else: discard
  left

proc parseExpr(p: var MathParser): Option[float] =
  var left = parseMulDiv(p)
  if left.isNone: return left
  while true:
    skipSpaces(p)
    let op = p.peek
    if op != '+' and op != '-': break
    inc p.pos
    let right = parseMulDiv(p)
    if right.isNone: return none(float)
    case op
    of '+': left = some(left.get + right.get)
    of '-': left = some(left.get - right.get)
    else: discard
  left

proc evalMathExpr*(raw: string): Option[float] =
  ## Evaluate ``raw`` as a tiny arithmetic expression. Returns
  ## ``some(value)`` on success; ``none`` when the input is empty or
  ## malformed. The parser drops a trailing unit suffix
  ## (``"100+50px"`` → ``150``) so the value input can carry the
  ## currently-active unit on the chip without the user having to
  ## strip it before editing.
  ##
  ## A bare number (``"150"``) is the trivial case. The exposed
  ## visibility lets the test fixture exercise the parser directly
  ## without round-tripping through a DOM event.
  if raw.len == 0:
    return none(float)
  var p = MathParser(src: raw, pos: 0)
  let value = parseExpr(p)
  value

# --------------------------------------------------------------------------- #
#  PropertyRowConfig constructors — keeps the call sites in
#  ``component_edit.nim`` (Phase G) terse and the unit tests readable.
# --------------------------------------------------------------------------- #

proc propertyRowNumeric*(name: string;
                         value: Signal[float];
                         unit: Signal[PropertyUnitOption];
                         units: seq[PropertyUnitOption] = @[];
                         minValue = none(float);
                         maxValue = none(float);
                         step: float = 1.0;
                         binding = none(VariableBinding);
                         bindingReactive: proc(): Option[VariableBinding] = nil;
                         onChange: proc() = nil;
                         onBindRequest: proc(x, y, w, h: float) = nil;
                         onMore: proc() = nil;
                         onDetachRequest: proc() = nil;
                         onVariableNameClick: proc() = nil;
                         wiring = InspectorRowWiring()): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkNumeric,
    numericValue: value, numericUnit: unit, availableUnits: units,
    numericMin: minValue, numericMax: maxValue, numericStep: step,
    binding: binding,
    bindingReactive: bindingReactive,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick,
    cssProperty: wiring.cssProperty,
    scopeOptions: wiring.scopeOptions,
    commitMessage: wiring.commitMessage,
    commitRejected: wiring.commitRejected,
    onCommitValue: wiring.commit)

proc propertyRowColor*(name: string;
                       value: Signal[string];
                       alpha: Signal[float];
                       binding = none(VariableBinding);
                       bindingReactive: proc(): Option[VariableBinding] = nil;
                       onChange: proc() = nil;
                       onBindRequest: proc(x, y, w, h: float) = nil;
                       onMore: proc() = nil;
                       onDetachRequest: proc() = nil;
                       onVariableNameClick: proc() = nil;
                       wiring = InspectorRowWiring()): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkColor,
    colorValue: value, alphaValue: alpha,
    binding: binding,
    bindingReactive: bindingReactive,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick,
    cssProperty: wiring.cssProperty,
    scopeOptions: wiring.scopeOptions,
    commitMessage: wiring.commitMessage,
    commitRejected: wiring.commitRejected,
    onCommitValue: wiring.commit)

proc propertyRowChoice*(name: string;
                        value: Signal[string];
                        options: seq[tuple[label: string; value: string]];
                        binding = none(VariableBinding);
                        bindingReactive: proc(): Option[VariableBinding] = nil;
                        onChange: proc() = nil;
                        onBindRequest: proc(x, y, w, h: float) = nil;
                        onMore: proc() = nil;
                        onDetachRequest: proc() = nil;
                        onVariableNameClick: proc() = nil;
                       wiring = InspectorRowWiring()): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkChoice,
    choiceValue: value, choiceOptions: options,
    binding: binding,
    bindingReactive: bindingReactive,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick,
    cssProperty: wiring.cssProperty,
    scopeOptions: wiring.scopeOptions,
    commitMessage: wiring.commitMessage,
    commitRejected: wiring.commitRejected,
    onCommitValue: wiring.commit)

proc propertyRowText*(name: string;
                      value: Signal[string];
                      binding = none(VariableBinding);
                      bindingReactive: proc(): Option[VariableBinding] = nil;
                      onChange: proc() = nil;
                      onBindRequest: proc(x, y, w, h: float) = nil;
                      onMore: proc() = nil;
                      onDetachRequest: proc() = nil;
                      onVariableNameClick: proc() = nil;
                      wiring = InspectorRowWiring()): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkText,
    textValue: value,
    binding: binding,
    bindingReactive: bindingReactive,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick,
    cssProperty: wiring.cssProperty,
    scopeOptions: wiring.scopeOptions,
    commitMessage: wiring.commitMessage,
    commitRejected: wiring.commitRejected,
    onCommitValue: wiring.commit)

proc propertyRowBoolean*(name: string;
                         value: Signal[bool];
                         binding = none(VariableBinding);
                         bindingReactive: proc(): Option[VariableBinding] = nil;
                         onChange: proc() = nil;
                         onBindRequest: proc(x, y, w, h: float) = nil;
                         onMore: proc() = nil;
                         onDetachRequest: proc() = nil;
                         onVariableNameClick: proc() = nil;
                         wiring = InspectorRowWiring()): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkBoolean,
    booleanValue: value,
    binding: binding,
    bindingReactive: bindingReactive,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick,
    cssProperty: wiring.cssProperty,
    scopeOptions: wiring.scopeOptions,
    commitMessage: wiring.commitMessage,
    commitRejected: wiring.commitRejected,
    onCommitValue: wiring.commit)

# --------------------------------------------------------------------------- #
#  Mount.
# --------------------------------------------------------------------------- #

proc kindAttr(kind: PropertyRowKind): string =
  case kind
  of prkNumeric: "numeric"
  of prkColor:   "color"
  of prkChoice:  "choice"
  of prkText:    "text"
  of prkBoolean: "boolean"

proc inlinePrefixGlyph*(name: string): string =
  ## Phase H (2026-05-28): return the short prefix string that sits
  ## INSIDE the input pill — Figma's pattern. Single-letter property
  ## names ("X", "Y", "W", "H") render as-is; short alphabetic names
  ## ("Gap", "Pad", "Opacity") use their first letter; the empty
  ## string disables the prefix entirely (long / non-alphabetic
  ## names just leave the input to host the value uncluttered).
  ##
  ## Exported so per-section tests can assert the same prefix map
  ## without recreating the rules.
  if name.len == 0:
    return ""
  if name.len <= 2:
    return name.toUpperAscii
  # Heuristic: the prefix is the first letter for short, well-known
  # property labels. The dispatch table avoids over-shortening
  # uncommon labels (e.g. "Overflow", "Blend mode") which we leave
  # blank — the value control there is descriptive enough.
  let lower = name.toLowerAscii
  case lower
  of "gap": return "G"
  of "pad top": return "T"
  of "pad right": return "R"
  of "pad bottom": return "B"
  of "pad left": return "L"
  of "rotation": return "\xE2\x86\xBB" # U+21BB CLOCKWISE OPEN CIRCLE ARROW
  of "opacity": return "%"
  of "corner radius": return "\xE2\x97\x90" # U+25D0 CIRCLE WITH LEFT HALF BLACK
  else:
    return ""

proc currentUnitLabel(config: PropertyRowConfig): string =
  ## Returns the human label of the current unit chip. Defers to
  ## ``availableUnits`` when the signal-carried unit's label is empty
  ## (the caller may seed the signal from a literal string and only
  ## populate ``availableUnits``).
  if config.kind != prkNumeric:
    return ""
  let active = config.numericUnit.val
  if active.label.len > 0: return active.label
  if config.availableUnits.len > 0: return config.availableUnits[0].label
  ""

proc currentUnitCode*(config: PropertyRowConfig): string =
  ## The CSS unit token for the active unit chip — the ``code`` side
  ## of ``PropertyUnitOption``, as opposed to ``currentUnitLabel``'s
  ## display side. ``"deg"`` vs. ``"°"``, and ``""`` for the ``auto``
  ## sentinel. Phase G+1 needs the code: the chip may read ``°`` but
  ## the source-edit pipeline must receive ``deg``.
  if config.kind != prkNumeric:
    return ""
  let active = config.numericUnit.val
  if active.label.len > 0 or active.code.len > 0:
    return active.code
  if config.availableUnits.len > 0: return config.availableUnits[0].code
  ""

proc nextUnit(config: PropertyRowConfig): PropertyUnitOption =
  ## Walks the ``availableUnits`` sequence and returns the unit after
  ## the currently-active one (wraps at the end). Falls back to the
  ## active unit when ``availableUnits`` is empty.
  if config.availableUnits.len == 0:
    return config.numericUnit.val
  let activeCode = config.numericUnit.val.code
  var idx = -1
  for i in 0 ..< config.availableUnits.len:
    if config.availableUnits[i].code == activeCode:
      idx = i
      break
  let nextIdx =
    if idx < 0: 0
    else: (idx + 1) mod config.availableUnits.len
  config.availableUnits[nextIdx]

proc measureAnchorRect*[E](node: E): tuple[x, y, w, h: float] =
  ## VBIND-M2: return ``node``'s bounding rectangle in DOCUMENT
  ## coordinates (viewport rect + ``window.scrollX/Y``) so a caller can
  ## anchor the variable picker to a bind affordance. JS-only; on the
  ## native/headless path there is no layout, so the zero rect is
  ## returned (the picker's headless path anchors from the rect the
  ## test supplies instead). Mirrors ``openVariablePicker``'s own
  ## measurement so the row anchor and the picker agree.
  result = (0.0, 0.0, 0.0, 0.0)
  when defined(js):
    var rx = 0.0
    var ry = 0.0
    var rw = 0.0
    var rh = 0.0
    {.emit: ["""
      (function (el) {
        if (!el || !el.getBoundingClientRect) return;
        var rc = el.getBoundingClientRect();
        var sx = window.scrollX || 0;
        var sy = window.scrollY || 0;
        """, rx, """ = rc.left + sx;
        """, ry, """ = rc.top + sy;
        """, rw, """ = rc.width;
        """, rh, """ = rc.height;
      })(""", node, """);
    """].}
    result = (rx, ry, rw, rh)
  else:
    discard node

proc attachNumericKeySteps*[R, E](r: R; inputNode: E; step: float) =
  ## Arrow-key stepping on a numeric input.
  ##
  ## The old inspector had this (``component_edit.nim``'s
  ## ``attachPrimitiveInputKeys``); the section rows did not, so
  ## ArrowUp on a property row did nothing at all. Same contract as
  ## the old one: ArrowUp / ArrowDown move the value by one step,
  ## Shift multiplies the step by 10, Alt divides it by 10, and the
  ## unit suffix (if the user typed one) is preserved.
  ##
  ## It is a ``{.emit.}`` block for the same reason the old one was:
  ## the renderer's ``addEventListener`` hands Nim a ``proc()`` with
  ## no event object, so there is no way to read ``event.key`` or the
  ## modifier flags from the Nim side. Rather than invent a callback
  ## shape for it, the handler rewrites ``input.value`` and dispatches
  ## a ``change`` event — which the Nim-side commit handler above is
  ## already listening for. The parse, the clamp, the signal write and
  ## the source-edit commit all stay in Nim; only the key decoding is
  ## in JS.
  ##
  ## Headless builds get nothing, which is correct: there is no key
  ## event to decode and the headless tests drive the value signal and
  ## the commit path directly.
  when defined(js):
    {.emit: ["""
      (function () {
        const input = """, inputNode, """;
        if (!input || input.__isonimRowKeyStepsInstalled) return;
        input.__isonimRowKeyStepsInstalled = true;
        const baseStep = Number(""", step, """) || 1;
        function split(raw) {
          const text = String(raw || '').trim();
          const match = text.match(/^([+-]?(?:\d+\.?\d*|\.\d+))(.*)$/);
          if (!match) return null;
          return { number: Number(match[1]), unit: match[2] || '' };
        }
        function format(number, unit) {
          const rounded = Math.abs(number - Math.round(number)) < 0.0001
            ? String(Math.round(number))
            : String(Math.round(number * 100) / 100);
          return rounded + unit;
        }
        input.addEventListener('keydown', (event) => {
          if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
          const parsed = split(input.value);
          if (!parsed) return;
          let magnitude = baseStep;
          if (event.shiftKey) magnitude = baseStep * 10;
          else if (event.altKey) magnitude = baseStep / 10;
          const delta = event.key === 'ArrowUp' ? magnitude : -magnitude;
          input.value = format(parsed.number + delta, parsed.unit);
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          event.preventDefault();
        });
      })();
    """].}
  else:
    discard r
    discard inputNode
    discard step

proc mountPropertyRow*[R, E](r: R; parent: E;
                              config: PropertyRowConfig): E =
  ## Mount a property row inside ``parent``. Returns the row's root
  ## element so the caller can capture refs or query data-attrs.
  ##
  ## Mount steps:
  ##   1. Build the row root via ``ui(r):`` with the 4-slot grid.
  ##   2. Build per-kind slot contents (numeric input + unit chip,
  ##      color swatch + hex input, segmented choice, text input, or
  ##      checkbox).
  ##   3. Wire event listeners for commits + the scrub-drag handler.
  ##   4. Mirror ``data-property-row-linked`` from
  ##      ``config.binding.isSome`` on the root.
  ##   5. ``appendChild(parent, root)``.
  let cfg = config
  let kindStr = kindAttr(cfg.kind)
  let slug = propertyRowSlug(cfg.name)
  let isLinked = cfg.binding.isSome

  var labelNode: E
  var valueSlot: E
  var scopeSlot: E
  var bindNode: E
  var moreNode: E
  var messageNode: E

  # Phase G+1: the root is now a column — the 4-slot line, plus a
  # refusal line beneath it. The root keeps every
  # ``data-property-row*`` attribute it carried before, and the slot
  # elements keep theirs, so the widget's attribute contract is
  # unchanged; the headless fixture resolves them with a recursive
  # ``findByAttr`` and does not care about nesting depth.
  #
  # A refusal needs somewhere to land. Without it the only honest
  # option is to drop the message, and a property row that swallows
  # "this workspace is read-only" is the exact defect this phase
  # exists to remove.
  # A row is ANONYMOUS when nothing on it says what it edits. Typography was
  # the proof: font size, line height, letter spacing and paragraph spacing
  # rendered as four unlabelled numbers in a column (19, 30.4, -0.01, 0),
  # identifiable only by hovering each one for its `title`.
  #
  # Choice rows were exempted at first, on the theory that the value names
  # the row -- "Visible", "Normal". It does not hold: decoration, transform
  # and list style all read **None**, so three consecutive rows said the
  # same word and named nothing. The value only identifies a row when its
  # vocabulary happens to be unique, which is not a property anything
  # enforces.
  #
  # So every kind writes its name except where a glyph already carries it.
  # Figma gets away without labels here because it has an icon for each of
  # these; we do not, and an unlabelled control is worse than a wider one.
  let writesOwnLabel = inlinePrefixGlyph(cfg.name).len == 0
  let root = ui(r):
    tdiv(
      `data-property-row` = slug,
      `data-property-row-kind` = kindStr,
      `data-property-row-name` = cfg.name,
      `data-property-row-linked` = (if isLinked: "true" else: "false"),
      `data-property-row-css-property` = cfg.cssProperty,
      display = "flex",
      flex_direction = "column",
      width = "100%"):
     tdiv(
      `data-property-row-line` = "true",
      display = "flex",
      flex_direction = "row",
      align_items = "center",
      gap = prRowGap,
      padding = prRowVPad & " 0",
      min_height = prRowMinHeight,
      width = "100%"):
      # Phase H: the label slot is now a thin scrub gutter rather
      # than a full label column. The display text moved inside the
      # input as a prefix glyph (see prkNumeric / prkText). The slot
      # still carries the ``data-property-row-slot="label-scrubber"``
      # attribute and the col-resize cursor + scrub event handlers,
      # so headless scrub-drag tests remain green. We render the
      # name as the slot's accessible title (hover tooltip) for long
      # labels that don't fit in the inline prefix.
      span(
        ref = labelNode,
        `data-property-row-slot` = "label-scrubber",
        title = cfg.name,
        font_size = prLabelFont,
        color = prLabelColor,
        white_space = "nowrap",
        overflow = "hidden",
        text_overflow = "ellipsis",
        min_width = (if writesOwnLabel: prLabelWideWidth else: prLabelWidth),
        max_width = (if writesOwnLabel: prLabelWideWidth else: prLabelWidth),
        cursor = (if cfg.kind == prkNumeric: "col-resize" else: "default"),
        user_select = "none"):
        # Blank unless the row would otherwise be anonymous. See
        # `writesOwnLabel` above: a glyph row is already named, and a choice
        # row's value names it, but a bare number names nothing.
        if writesOwnLabel:
          text cfg.name
      tdiv(
        ref = valueSlot,
        `data-property-row-slot` = "value",
        display = "flex",
        flex = "1",
        align_items = "center",
        gap = "4px",
        min_width = "0",
        overflow = "hidden")
      # Bind/scope slot, left half: the source-scope mini-picker the
      # spec prescribes (isonim-editor.md ~1010). Empty and
      # zero-width when the row has no ``scopeOptions`` thunk, so a
      # non-inspector row lays out exactly as before.
      tdiv(
        ref = scopeSlot,
        `data-property-row-slot` = "scope",
        display = "flex",
        align_items = "center",
        min_width = "0",
        overflow = "visible")
      tdiv(
        ref = bindNode,
        role = "button",
        tabindex = "0",
        `data-property-row-slot` = "bind",
        `aria-label` = "Bind " & cfg.name & " to variable",
        display = "flex",
        align_items = "center",
        justify_content = "center",
        min_width = prBindWidth,
        max_width = prBindWidth,
        height = prInputHeight,
        color = prBindColor,
        font_size = prBindFont,
        cursor = "pointer",
        user_select = "none"):
        # Unicode diamond U+25C7 — placeholder for the bind chip
        # icon. Phase E.2 swaps this for the inline SVG used by the
        # variable picker chip.
        text "\xE2\x97\x87"
      tdiv(
        ref = moreNode,
        role = "button",
        tabindex = "0",
        `data-property-row-slot` = "more",
        `aria-label` = "More actions for " & cfg.name,
        display = "flex",
        align_items = "center",
        justify_content = "center",
        min_width = prMoreWidth,
        max_width = prMoreWidth,
        height = prInputHeight,
        color = prMoreColor,
        font_size = prMoreFont,
        cursor = "pointer",
        user_select = "none"):
        # Unicode tricolon U+22EE (VERTICAL ELLIPSIS).
        text "\xE2\x8B\xAE"

  # ------------------------------------------------------------------------- #
  #  Phase G+1: the commit path.
  #
  #  ``commitValue`` is what makes a keystroke reach the source-edit
  #  pipeline. Every kind renders its current state as the CSS string
  #  the property should take and hands it to ``cfg.onCommitValue``;
  #  the section built that closure from
  #  ``property_commit.inspectorRowWiring``, which resolves the scope
  #  and dispatches to ``editCssProperty`` or
  #  ``editSharedDesignProperty``.
  #
  #  ``onChange`` still fires, unchanged, after it. The two are
  #  separate because ``onChange`` is a bare notification with no
  #  value and 37 existing call sites; making it carry the commit
  #  would have changed its meaning under every one of them.
  # ------------------------------------------------------------------------- #

  proc currentCssValue(): string =
    ## The row's value as CSS text. For a numeric row that is the
    ## number plus the active unit chip's code — the unit lives in a
    ## separate signal from the magnitude, so ``24`` and ``px`` have
    ## to be rejoined here or the pipeline receives a unitless length.
    case cfg.kind
    of prkNumeric:
      formatNumber(cfg.numericValue.val) & currentUnitCode(cfg)
    of prkColor:
      cfg.colorValue.val
    of prkChoice:
      cfg.choiceValue.val
    of prkText:
      cfg.textValue.val
    of prkBoolean:
      if cfg.booleanValue.val: "true" else: "false"

  proc commitValue(restore: proc() {.closure.} = nil) =
    ## Commit the row's current value, and put the control back if the
    ## pipeline refuses it.
    ##
    ## `restore` is supplied by the caller because only the caller still
    ## holds the previous value: every kind's input handler writes the new
    ## value into its signal BEFORE committing, so by the time we are here
    ## the old one is gone. A refused edit that leaves the typed value in
    ## the field makes the panel disagree with the document -- grip showed
    ## `42` in Font size while the element stayed at `34`, with a one-line
    ## message the eye slides past as the only correction.
    let hadRejections =
      if cfg.commitRejected != nil: cfg.commitRejected.val else: 0
    if cfg.onCommitValue != nil:
      cfg.onCommitValue(currentCssValue())
    if cfg.commitRejected != nil and
       cfg.commitRejected.val != hadRejections:
      if restore != nil:
        restore()
      return
    if cfg.onChange != nil:
      cfg.onChange()

  # ------------------------------------------------------------------------- #
  #  Value-slot content per kind. When ``binding.isSome`` we render a
  #  "linked chip" placeholder instead of the kind-specific control
  #  so Phase E.2 can upgrade the visual without touching this widget.
  # ------------------------------------------------------------------------- #

  proc buildValueSlot(activeBinding: Option[VariableBinding]) =
    ## VBIND-M2: (re)build the value slot for the current binding
    ## state. Called once for the static path, or from a render
    ## effect for the reactive (hot-swap) path so the chip vs.
    ## literal control follows the binding live.
    r.setAttribute(root, "data-property-row-linked",
      if activeBinding.isSome: "true" else: "false")
    if activeBinding.isSome:
      # Phase E.2 (2026-05-28): the placeholder chip is now the real
      # ``variable_chip`` widget — tinted purple background, accent
      # border, clickable name + chevron + hoverable detach affordance.
      # The chip widget exposes ``extraRootAttr`` + ``extraNameAttr``
      # hooks so the property row can preserve the legacy
      # ``data-property-row-linked-chip="true"`` +
      # ``data-property-row-linked-variable=<key>`` selectors that
      # landed in Phase D — those data-attrs are the contract between
      # property_row and the Phase D headless tests.
      let binding = activeBinding.get
      var chipRootRef: E
      # VBIND-M2: the chevron re-opens the picker anchored to the
      # chip. Measure the chip's rect at click time and forward it.
      let onBind = cfg.onBindRequest
      let chevronCb =
        if onBind != nil:
          (proc() =
            let rc = measureAnchorRect(chipRootRef)
            onBind(rc.x, rc.y, rc.w, rc.h))
        else:
          nil
      let nameCb = cfg.onVariableNameClick
      let detachCb = cfg.onDetachRequest
      let chipConfig = variableChipConfig(
        binding = binding,
        usageCount = 0,
        onChevronClick = chevronCb,
        onNameClick = nameCb,
        onDetach = detachCb,
        extraRootAttr = "data-property-row-linked-chip=true",
        extraNameAttr = "data-property-row-linked-variable=" &
          binding.variableKey)
      chipRootRef = r.mountVariableChip(valueSlot, chipConfig)
    else:
      case cfg.kind
      of prkNumeric:
        var inputNode: E
        var unitNode: E
        let prefix = inlinePrefixGlyph(cfg.name)
        let row = ui(r):
          tdiv(`data-property-row-pill` = "true",
                display = "flex", flex = "1",
                align_items = "center", gap = "4px",
                min_width = "0",
                height = prInputHeight,
                padding = prInputPadding,
                background_color = prInputBg,
                border = prInputBorder,
                border_radius = prInputRadius,
                overflow = "hidden"):
            # Phase H: inline prefix glyph — the "X" / "Y" / "W" / "H"
            # / etc. letter sits inside the input as a faded prefix,
            # mirroring the Figma reference. Hidden when no prefix is
            # configured for this property name (long names like
            # "Overflow" render without a glyph).
            if prefix.len > 0:
              span(
                `data-property-row-prefix` = "true",
                `aria-hidden` = "true",
                min_width = prPrefixWidth,
                color = prPrefixColor,
                font_size = prPrefixFont,
                user_select = "none",
                flex_shrink = "0",
                white_space = "nowrap"):
                text prefix
            input(
              ref = inputNode,
              `data-property-row-input` = "true",
              `aria-label` = "Edit " & cfg.name,
              flex = "1",
              min_width = "0",
              background_color = "transparent",
              border = "none",
              outline = "none",
              color = prInputColor,
              font_size = prInputFont,
              font_family = "inherit",
              padding = "0",
              height = "100%",
              text_align = "right")
            tdiv(
              ref = unitNode,
              role = "button",
              tabindex = "0",
              `data-property-row-unit` = "true",
              `aria-label` = "Cycle " & cfg.name & " unit",
              display = "flex",
              align_items = "center",
              justify_content = "center",
              padding = prUnitPadding,
              background_color = prUnitBg,
              color = prUnitColor,
              font_size = prUnitFont,
              border_radius = prUnitRadius,
              cursor = "pointer",
              user_select = "none",
              white_space = "nowrap",
              flex_shrink = "0"):
              text currentUnitLabel(cfg)
        r.appendChild(valueSlot, row)
        r.setInputValue(inputNode, formatNumber(cfg.numericValue.val))

        # Reactive bind — when ``numericValue`` mutates externally the
        # input mirrors it (e.g. variable updates, undo). When the user
        # types and presses Enter the commit handler writes the parsed
        # math expression back through ``numericValue.val``.
        createRenderEffect proc() =
          let v = cfg.numericValue.val
          r.setInputValue(inputNode, formatNumber(v))

        createRenderEffect proc() =
          r.setTextContent(unitNode, currentUnitLabel(cfg))

        let commit = proc() =
          let raw = r.inputValue(inputNode)
          let parsed = evalMathExpr(raw)
          if parsed.isSome:
            var v = parsed.get
            if cfg.numericMin.isSome and v < cfg.numericMin.get:
              v = cfg.numericMin.get
            if cfg.numericMax.isSome and v > cfg.numericMax.get:
              v = cfg.numericMax.get
            let priorValue = cfg.numericValue.val
            cfg.numericValue.val = v
            r.setInputValue(inputNode, formatNumber(v))
            commitValue(proc() =
              cfg.numericValue.val = priorValue
              r.setInputValue(inputNode, formatNumber(priorValue)))
          else:
            # Reject garbage — restore the previous value so the input
            # never displays an unparseable string after losing focus.
            r.setInputValue(inputNode, formatNumber(cfg.numericValue.val))
        r.addEventListener(inputNode, "change", commit)
        r.addEventListener(inputNode, "blur", commit)
        attachNumericKeySteps(r, inputNode, cfg.numericStep)

        let cycleUnit = proc() =
          let nxt = nextUnit(cfg)
          cfg.numericUnit.val = nxt
          commitValue()
        r.addEventListener(unitNode, "click", cycleUnit)
        r.addEventListener(unitNode, "keydown", cycleUnit)

        # ---- Scrub-drag on the label -------------------------------- #
        #
        # Headless tests exercise the scrub via three synthetic events
        # fired in sequence on the label node — ``mousedown`` arms the
        # drag, ``mousemove`` nudges the value by ``numericStep``,
        # ``mouseup`` disarms. The Nim-side handlers update the signal
        # on every move so callers can observe the value transition
        # without leaving the test process.
        var dragArmed = false
        let scrubStart = proc() =
          dragArmed = true
        let scrubMove = proc() =
          if not dragArmed: return
          var step = cfg.numericStep
          if step <= 0.0: step = 1.0
          var v = cfg.numericValue.val + step
          if cfg.numericMin.isSome and v < cfg.numericMin.get:
            v = cfg.numericMin.get
          if cfg.numericMax.isSome and v > cfg.numericMax.get:
            v = cfg.numericMax.get
          cfg.numericValue.val = v
          r.setInputValue(inputNode, formatNumber(v))
          commitValue()
        let scrubEnd = proc() =
          dragArmed = false
        r.addEventListener(labelNode, "mousedown", scrubStart)
        r.addEventListener(labelNode, "mousemove", scrubMove)
        r.addEventListener(labelNode, "mouseup", scrubEnd)

      of prkColor:
        var swatchNode: E
        var hexInput: E
        let row = ui(r):
          tdiv(display = "flex", flex = "1",
                align_items = "center", gap = "6px",
                min_width = "0",
                height = prInputHeight,
                padding = prInputPadding,
                background_color = prInputBg,
                border = prInputBorder,
                border_radius = prInputRadius,
                overflow = "hidden"):
            tdiv(
              ref = swatchNode,
              role = "button",
              tabindex = "0",
              `data-property-row-swatch` = "true",
              `aria-label` = "Open " & cfg.name & " color picker",
              width = prSwatchSize,
              height = prSwatchSize,
              border = prSwatchBorder,
              border_radius = "3px",
              cursor = "pointer",
              flex_shrink = "0",
              background_color = cfg.colorValue.val)
            input(
              ref = hexInput,
              `data-property-row-input` = "true",
              `aria-label` = "Edit " & cfg.name & " hex value",
              flex = "1",
              min_width = "0",
              background_color = "transparent",
              border = "none",
              outline = "none",
              color = prInputColor,
              font_size = prInputFont,
              font_family = "monospace",
              padding = "0",
              height = "100%")
        r.appendChild(valueSlot, row)
        r.setInputValue(hexInput, cfg.colorValue.val)

        createRenderEffect proc() =
          let v = cfg.colorValue.val
          r.setInputValue(hexInput, v)
          r.setAttribute(swatchNode, "data-property-row-swatch-value", v)
          # Update the inline background-color via setAttribute("style",
          # ...) — this is inside a reactive effect, so the
          # no-setStyle-outside-reactive-effects invariant holds. We
          # rewrite the full style attribute so we don't leak through
          # the no-setStyle scan in widgets/.
          r.setAttribute(swatchNode, "style",
            "width: " & prSwatchSize & "; height: " & prSwatchSize &
            "; border: " & prSwatchBorder & "; border-radius: 3px;" &
            " cursor: pointer; flex-shrink: 0; background-color: " & v & ";")

        let commit = proc() =
          let raw = r.inputValue(hexInput).strip()
          if raw.len > 0:
            cfg.colorValue.val = raw
            commitValue()
        r.addEventListener(hexInput, "change", commit)
        r.addEventListener(hexInput, "blur", commit)

        let openPicker = proc() =
          # Phase G wires the real picker — Phase D leaves a no-op
          # marker so behaviour tests can confirm the click reached
          # the swatch.
          r.setAttribute(swatchNode, "data-property-row-picker-requested", "true")
        r.addEventListener(swatchNode, "click", openPicker)

      of prkChoice:
        var labels: seq[string] = @[]
        var values: seq[string] = @[]
        for opt in cfg.choiceOptions:
          labels.add opt.label
          values.add opt.value
        var initialIdx = 0
        let current = cfg.choiceValue.val
        for i in 0 ..< values.len:
          if values[i] == current:
            initialIdx = i
            break
        let vm = createSegmentedChoiceVM(labels, initialIndex = initialIdx)
        let host = ui(r):
          tdiv(
            `data-property-row-choice-host` = "true",
            display = "flex",
            flex = "1",
            align_items = "center",
            min_width = "0")
        r.appendChild(valueSlot, host)
        let onPick = proc(i: int) {.closure.} =
          if i >= 0 and i < values.len:
            cfg.choiceValue.val = values[i]
            commitValue()
        # Segmented strips only fit while their labels do. The container
        # clips rather than scrolls, so an overlong strip does not compress
        # -- it slices the last option mid-word. The grip pilot showed
        # "Auto" as "Au", "Overlay" as "O" and "Line-through" as
        # "Line-thro". A truncated option reads as a rendering fault, and it
        # is not clickable either.
        #
        # Counting options is not enough: None / Underline / Line-through is
        # only three and still overflows, while None / Disc / Decimal fits.
        # So estimate the width the pills need and compare it with the room
        # the row has.
        #
        # The constants are CALIBRATED, not guessed. Measured in the grip
        # pilot at the default 320px panel, where the choice host is 196px:
        #
        #   Visible/Hidden/Scroll/Auto      23 chars, 4 pills -> 230px
        #   Left/Center/Right/Justify       22 chars, 4 pills -> 229px
        #   None/Underline/Line-through     25 chars, 3 pills -> 222px
        #   None/Disc/Decimal               15 chars, 3 pills -> 177px
        #
        # which fit `5.0 * chars + 34 * pills` closely, rounded UP at every
        # step. Rounding up is the point: being wrong toward the popup costs
        # one click, being wrong toward the strip cuts a label in half.
        #
        # The panel is resizable down to 200px, so a strip that just fits
        # here will not fit there. That is the remaining gap, and it argues
        # for the bias rather than against it.
        var pillWidth = 0.0
        for opt in cfg.choiceOptions:
          pillWidth += float(opt.label.len) * 5.0 + 34.0
        # Minus the label gutter when this row writes its own name: 76px
        # instead of 22px leaves 54px less for pills.
        let roomForPills = 196.0 - (if writesOwnLabel: 66.0 else: 0.0)
        if pillWidth > roomForPills:
          r.mountChevronChoice(host, vm, onPick, variant = cgvTransparent)
        else:
          r.mountSegmentedChoice(host, vm, onPick, variant = cgvTransparent)

        # When the bound signal is updated externally, mirror the
        # selection into the VM so the segmented control stays in
        # sync.
        createRenderEffect proc() =
          let v = cfg.choiceValue.val
          for i in 0 ..< values.len:
            if values[i] == v:
              vm.activate(i)
              break

      of prkText:
        var inputNode: E
        let row = ui(r):
          tdiv(display = "flex", flex = "1",
                align_items = "center",
                min_width = "0",
                height = prInputHeight,
                padding = prInputPadding,
                background_color = prInputBg,
                border = prInputBorder,
                border_radius = prInputRadius,
                overflow = "hidden"):
            input(
              ref = inputNode,
              `data-property-row-input` = "true",
              `aria-label` = "Edit " & cfg.name,
              flex = "1",
              min_width = "0",
              background_color = "transparent",
              border = "none",
              outline = "none",
              color = prInputColor,
              font_size = prInputFont,
              font_family = "inherit",
              padding = "0",
              height = "100%")
        r.appendChild(valueSlot, row)
        r.setInputValue(inputNode, cfg.textValue.val)

        createRenderEffect proc() =
          let v = cfg.textValue.val
          r.setInputValue(inputNode, v)

        let commit = proc() =
          cfg.textValue.val = r.inputValue(inputNode)
          commitValue()
        r.addEventListener(inputNode, "change", commit)
        r.addEventListener(inputNode, "blur", commit)

      of prkBoolean:
        var checkboxNode: E
        let row = ui(r):
          tdiv(display = "flex", flex = "1",
                align_items = "center",
                gap = "8px",
                min_width = "0",
                height = prInputHeight):
            input(
              ref = checkboxNode,
              `data-property-row-input` = "true",
              `aria-label` = "Toggle " & cfg.name,
              width = "14px",
              height = "14px",
              margin = "0",
              cursor = "pointer")
            # Phase H: the boolean kind has no inline-prefix pattern —
            # the checkbox already encodes the value visually. The
            # label sits to the right of the checkbox as muted text so
            # the row reads "[☑] Per-corner" inline.
            span(
              `data-property-row-boolean-label` = "true",
              color = prLabelColor,
              font_size = prInputFont,
              user_select = "none",
              overflow = "hidden",
              text_overflow = "ellipsis",
              white_space = "nowrap"):
              text cfg.name
        r.appendChild(valueSlot, row)
        # The DSL's ``input`` does not natively expose ``type`` (it
        # could collide with the Nim ``type`` keyword). Apply it via
        # ``setAttribute`` so the rendered DOM is a real checkbox.
        r.setAttribute(checkboxNode, "type", "checkbox")
        r.setAttribute(checkboxNode, "checked",
          if cfg.booleanValue.val: "true" else: "false")

        createRenderEffect proc() =
          let v = cfg.booleanValue.val
          r.setAttribute(checkboxNode, "checked",
            if v: "true" else: "false")
          r.setAttribute(checkboxNode, "data-property-row-boolean-value",
            if v: "true" else: "false")

        let toggle = proc() =
          cfg.booleanValue.val = not cfg.booleanValue.val
          commitValue()
        r.addEventListener(checkboxNode, "click", toggle)
        r.addEventListener(checkboxNode, "change", toggle)

  # ------------------------------------------------------------------------- #
  #  Build the value slot. When ``bindingReactive`` is supplied the build
  #  runs inside a render effect (VBIND-M2 hot-swap) so linking/unlinking a
  #  variable — or moving the selection to/from a bound element — swaps the
  #  chip and the literal control live, without the section re-mounting the
  #  row. With no ``bindingReactive`` the slot is built once from the static
  #  ``binding`` — byte-identical to before.
  #
  #  The build must run on EVERY pass of this effect, unconditionally.
  #  ``buildValueSlot`` creates nested computations — the numeric/text
  #  input's value bind, the unit-chip label bind, the colour swatch bind
  #  — and those are owned by this effect. ``updateComputation`` calls
  #  ``cleanNode`` before each re-run, which recursively disposes owned
  #  computations and unlinks them from their sources. So by the time this
  #  body runs, the previous pass's value binds are already dead. An
  #  earlier "skip the rebuild when the binding signature is unchanged"
  #  guard therefore did not save work — it permanently severed the row
  #  from its value signal. Every numeric row in the inspector froze at
  #  its mount-time value on the first selection change, which is why
  #  X / Y / W / H / opacity / font-size all read 0 (or their fallback)
  #  no matter what was selected. The guard is unsound by construction in
  #  this ownership model; if the DOM churn ever matters, the fix is to
  #  own the value-slot computations outside this effect, not to skip the
  #  rebuild.
  # ------------------------------------------------------------------------- #
  if cfg.bindingReactive != nil:
    let bindingReactive = cfg.bindingReactive
    createRenderEffect proc() =
      let active = bindingReactive()
      r.clearChildren(valueSlot)
      buildValueSlot(active)
  else:
    buildValueSlot(cfg.binding)

  # ------------------------------------------------------------------------- #
  #  Wire the bind + more affordances. Both forward to the
  #  caller-supplied closure — Phase E.2 (variable picker) and Phase
  #  G (overflow menu) plug the real handlers in.
  # ------------------------------------------------------------------------- #
  let bindHandler = proc() =
    if cfg.onBindRequest != nil:
      let rc = measureAnchorRect(bindNode)
      cfg.onBindRequest(rc.x, rc.y, rc.w, rc.h)
  r.addEventListener(bindNode, "click", bindHandler)
  r.addEventListener(bindNode, "keydown", bindHandler)

  let moreHandler = proc() =
    if cfg.onMore != nil: cfg.onMore()
  r.addEventListener(moreNode, "click", moreHandler)
  r.addEventListener(moreNode, "keydown", moreHandler)

  # ------------------------------------------------------------------------- #
  #  Phase G+1: the bind/scope slot's scope half.
  #
  #  The spec's slot 3 is "Bind/scope — the source-scope mini-picker
  #  (Local / Shared / Component schema / Theme token)". Phases D-H
  #  built the bind side and left the scope side out, which is why the
  #  sections had no way to express which source an edit modifies.
  #
  #  Rendered with ``renderCompactChoiceRow`` at ``visibleLimit = 1``,
  #  the same call shape the old inspector's row used — the head of
  #  the ordered scope list is visible and the rest is in the overflow
  #  popup, which is the spec's "common scopes remain visible, overflow
  #  lists less common or read-only scopes".
  #
  #  Choosing a scope also RE-COMMITS at the new scope. The old row did
  #  this (its ``scopeChoiceHandler`` called ``commitScope``, which
  #  wrote the value), and it is the behaviour
  #  ``e2e_style_manager_scope_choices_update_real_preview`` describes:
  #  clicking "Apply shared class scope for padding" changes the
  #  rendered padding. A picker that only records a preference and
  #  waits for the next keystroke would look inert.
  # ------------------------------------------------------------------------- #
  if cfg.scopeOptions != nil:
    let scopeOptionsThunk = cfg.scopeOptions
    let rowName = cfg.name
    proc wrappedScopeOptions(): seq[CompactChoiceOption] =
      result = scopeOptionsThunk()
      for option in result.mitems:
        let inner = option.onChoose
        option.onChoose = proc() =
          if inner != nil: inner()
          commitValue()
    let strip = renderCompactChoiceRow[R, E](r, "",
      "Choose source scope for " & rowName, wrappedScopeOptions,
      visibleLimit = 1, labelWidth = "0", minHeight = prInputHeight)
    r.setAttribute(strip.root, "data-property-row-scope-selector", "true")
    # Kept from the old row so a selector that knows the legacy
    # inspector still resolves the control in the new one.
    r.setAttribute(strip.root, "data-inspector-scope-selector", "true")
    r.setAttribute(strip.root, "data-compact-choice-strip", "true")
    r.setAttribute(strip.root, "data-source-scope-count",
      $scopeOptionsThunk().len)
    r.appendChild(scopeSlot, strip.root)

  # ------------------------------------------------------------------------- #
  #  Phase G+1: the refusal line.
  #
  #  ``commitMessage`` is non-empty exactly when the last commit was
  #  refused — read-only workspace, no adapter, a non-editable scope, a
  #  rejected value. The line is ``display: none`` while it is empty,
  #  so an accepted edit leaves the row looking as it did.
  #
  #  This is the whole point of the phase. The founder's report was
  #  "nothing happens"; a row that refuses in silence and a row that
  #  does nothing are the same row from the outside.
  # ------------------------------------------------------------------------- #
  if cfg.commitMessage != nil:
    let messageSignal = cfg.commitMessage
    let messageEl = ui(r):
      tdiv(
        ref = messageNode,
        `data-property-row-message` = "true",
        role = "status",
        `aria-live` = "polite",
        padding = "0 0 2px " & prLabelWidth,
        font_size = "10px",
        line_height = "1.35",
        color = prMessageColor):
        text ""
    r.appendChild(root, messageEl)
    createRenderEffect proc() =
      let text = messageSignal.val
      r.setTextContent(messageNode, text)
      r.setAttribute(messageNode, "data-property-row-message-visible",
        if text.len > 0: "true" else: "false")
      r.setStyle(messageNode, "display", if text.len > 0: "block" else: "none")

  r.appendChild(parent, root)
  result = root
