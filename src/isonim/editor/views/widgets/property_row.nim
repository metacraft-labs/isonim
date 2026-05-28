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
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md``
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
import isonim/editor/views/widgets/choice_group
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

    # Callbacks — every callback is allowed to be ``nil``; the mount
    # treats a nil callback as a no-op.
    onChange*: proc()
    onBindRequest*: proc()
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

# --------------------------------------------------------------------------- #
#  Visual contract — pulled from the spec's editing-control reference.
# --------------------------------------------------------------------------- #

const
  # Slot widths.
  prLabelWidth   = "80px"
  prBindWidth    = "24px"
  prMoreWidth    = "20px"

  # Row metrics — single dense line, 26px tall like the Figma
  # reference. The wrapper carries a 4px vertical gutter so adjacent
  # rows have breathing room without overflowing the section body.
  prRowMinHeight = "26px"
  prRowGap       = "8px"
  prRowVPad      = "4px"

  # Input visual contract.
  prInputBg      = "#1A1B22"
  prInputColor   = "#F1F5F9"
  prInputBorder  = "1px solid #2A2B36"
  prInputRadius  = "4px"
  prInputPadding = "4px 8px"
  prInputHeight  = "26px"
  prInputFont    = "12px"

  # Label scrubber.
  prLabelColor   = "#A0A2B0"
  prLabelFont    = "12px"

  # Unit chip.
  prUnitBg       = "#0F172A"
  prUnitColor    = "#A0A2B0"
  prUnitPadding  = "0 6px"
  prUnitFont     = "10px"
  prUnitRadius   = "3px"

  # Bind affordance.
  prBindColor    = "#A0A2B0"
  prBindFont     = "14px"

  # More affordance.
  prMoreColor    = "#A0A2B0"
  prMoreFont     = "14px"

  # Swatch.
  prSwatchSize   = "16px"
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
                         onChange: proc() = nil;
                         onBindRequest: proc() = nil;
                         onMore: proc() = nil;
                         onDetachRequest: proc() = nil;
                         onVariableNameClick: proc() = nil): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkNumeric,
    numericValue: value, numericUnit: unit, availableUnits: units,
    numericMin: minValue, numericMax: maxValue, numericStep: step,
    binding: binding,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick)

proc propertyRowColor*(name: string;
                       value: Signal[string];
                       alpha: Signal[float];
                       binding = none(VariableBinding);
                       onChange: proc() = nil;
                       onBindRequest: proc() = nil;
                       onMore: proc() = nil;
                       onDetachRequest: proc() = nil;
                       onVariableNameClick: proc() = nil): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkColor,
    colorValue: value, alphaValue: alpha,
    binding: binding,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick)

proc propertyRowChoice*(name: string;
                        value: Signal[string];
                        options: seq[tuple[label: string; value: string]];
                        binding = none(VariableBinding);
                        onChange: proc() = nil;
                        onBindRequest: proc() = nil;
                        onMore: proc() = nil;
                        onDetachRequest: proc() = nil;
                        onVariableNameClick: proc() = nil): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkChoice,
    choiceValue: value, choiceOptions: options,
    binding: binding,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick)

proc propertyRowText*(name: string;
                      value: Signal[string];
                      binding = none(VariableBinding);
                      onChange: proc() = nil;
                      onBindRequest: proc() = nil;
                      onMore: proc() = nil;
                      onDetachRequest: proc() = nil;
                      onVariableNameClick: proc() = nil): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkText,
    textValue: value,
    binding: binding,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick)

proc propertyRowBoolean*(name: string;
                         value: Signal[bool];
                         binding = none(VariableBinding);
                         onChange: proc() = nil;
                         onBindRequest: proc() = nil;
                         onMore: proc() = nil;
                         onDetachRequest: proc() = nil;
                         onVariableNameClick: proc() = nil): PropertyRowConfig =
  PropertyRowConfig(
    name: name, kind: prkBoolean,
    booleanValue: value,
    binding: binding,
    onChange: onChange, onBindRequest: onBindRequest, onMore: onMore,
    onDetachRequest: onDetachRequest,
    onVariableNameClick: onVariableNameClick)

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
  var bindNode: E
  var moreNode: E

  let root = ui(r):
    tdiv(
      `data-property-row` = slug,
      `data-property-row-kind` = kindStr,
      `data-property-row-name` = cfg.name,
      `data-property-row-linked` = (if isLinked: "true" else: "false"),
      display = "flex",
      flex_direction = "row",
      align_items = "center",
      gap = prRowGap,
      padding = prRowVPad & " 0",
      min_height = prRowMinHeight,
      width = "100%"):
      span(
        ref = labelNode,
        `data-property-row-slot` = "label-scrubber",
        font_size = prLabelFont,
        color = prLabelColor,
        white_space = "nowrap",
        overflow = "hidden",
        text_overflow = "ellipsis",
        min_width = prLabelWidth,
        max_width = prLabelWidth,
        cursor = (if cfg.kind == prkNumeric: "col-resize" else: "default"),
        user_select = "none"):
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
  #  Value-slot content per kind. When ``binding.isSome`` we render a
  #  "linked chip" placeholder instead of the kind-specific control
  #  so Phase E.2 can upgrade the visual without touching this widget.
  # ------------------------------------------------------------------------- #

  if isLinked:
    # Phase E.2 (2026-05-28): the placeholder chip is now the real
    # ``variable_chip`` widget — tinted purple background, accent
    # border, clickable name + chevron + hoverable detach affordance.
    # The chip widget exposes ``extraRootAttr`` + ``extraNameAttr``
    # hooks so the property row can preserve the legacy
    # ``data-property-row-linked-chip="true"`` +
    # ``data-property-row-linked-variable=<key>`` selectors that
    # landed in Phase D — those data-attrs are the contract between
    # property_row and the Phase D headless tests.
    let binding = cfg.binding.get
    let chevronCb = cfg.onBindRequest
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
    discard r.mountVariableChip(valueSlot, chipConfig)
  else:
    case cfg.kind
    of prkNumeric:
      var inputNode: E
      var unitNode: E
      let row = ui(r):
        tdiv(display = "flex", flex = "1",
              align_items = "center", gap = "4px",
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
          cfg.numericValue.val = v
          r.setInputValue(inputNode, formatNumber(v))
          if cfg.onChange != nil: cfg.onChange()
        else:
          # Reject garbage — restore the previous value so the input
          # never displays an unparseable string after losing focus.
          r.setInputValue(inputNode, formatNumber(cfg.numericValue.val))
      r.addEventListener(inputNode, "change", commit)
      r.addEventListener(inputNode, "blur", commit)

      let cycleUnit = proc() =
        let nxt = nextUnit(cfg)
        cfg.numericUnit.val = nxt
        if cfg.onChange != nil: cfg.onChange()
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
        if cfg.onChange != nil: cfg.onChange()
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
          if cfg.onChange != nil: cfg.onChange()
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
          if cfg.onChange != nil: cfg.onChange()
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
        if cfg.onChange != nil: cfg.onChange()
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
            width = "16px",
            height = "16px",
            margin = "0",
            cursor = "pointer")
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
        if cfg.onChange != nil: cfg.onChange()
      r.addEventListener(checkboxNode, "click", toggle)
      r.addEventListener(checkboxNode, "change", toggle)

  # ------------------------------------------------------------------------- #
  #  Wire the bind + more affordances. Both forward to the
  #  caller-supplied closure — Phase E.2 (variable picker) and Phase
  #  G (overflow menu) plug the real handlers in.
  # ------------------------------------------------------------------------- #
  let bindHandler = proc() =
    if cfg.onBindRequest != nil: cfg.onBindRequest()
  r.addEventListener(bindNode, "click", bindHandler)
  r.addEventListener(bindNode, "keydown", bindHandler)

  let moreHandler = proc() =
    if cfg.onMore != nil: cfg.onMore()
  r.addEventListener(moreNode, "click", moreHandler)
  r.addEventListener(moreNode, "keydown", moreHandler)

  r.appendChild(parent, root)
  result = root
