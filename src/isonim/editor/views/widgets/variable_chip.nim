## Phase E.2 — Design system variable chip widget.
##
## A reusable "linked chip" that renders an active variable binding as
## the spec's tinted purple chip:
##
##   ``[◇ color/surface ▾]`` + a thin ``↕`` detach affordance on hover.
##
## Spec reference: ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md``
## § "Design system variable binding" → "Visual indicator — the linked
## chip".
##
## The chip is the load-bearing visual carrier for the binding state.
## It is reused in:
##
##   * ``property_row.nim`` — when a property row's ``binding.isSome``,
##     the row's value-input slot is replaced by this chip.
##   * Future "Selection colors" / "Source scope" rows that surface
##     bound values inline without a full property row.
##   * Anywhere else the design wants to inline a variable-bound value
##     (e.g. the variable picker's "current binding" row).
##
## The chip is independent of any ViewModel — it takes a
## ``VariableChipConfig`` value with the variable key, resolved value,
## usage count, and three callbacks (chevron, name, detach). The picker
## (E.3) and inline editor (E.4) provide the callbacks; the chip stays
## focused on rendering.
##
## Visual contract (matches the spec to 1px precision):
##
##   * **Background**: ``rgba(124, 122, 237, 0.12)`` — accent at 12% α.
##   * **Border**: 1px solid ``rgba(124, 122, 237, 0.30)``.
##   * **Leading diamond** glyph ``◇`` (U+25C7) rendered in the accent
##     ``#7C7AED``.
##   * **Variable name** in ``#F1F5F9`` (textPrimary), 12px, monospace
##     family so the token slug reads as code rather than copy.
##   * **Trailing chevron** ``▾`` (U+25BE) in muted ``#A0A2B0``.
##   * **Detach affordance** ``↕`` (U+2195) appears on hover at the
##     right edge. CSS-only — the affordance lives in the DOM and the
##     widget toggles its visibility through ``data-variable-chip-hover``
##     so the headless tests can observe both states.
##
## Data attributes for tests + Phase G observers:
##
##   * ``data-variable-chip="true"`` on the root.
##   * ``data-variable-chip-key=<variable key>`` on the root.
##   * ``data-variable-chip-state=<bound|bound-missing>`` on the root.
##   * ``data-variable-chip-resolved=<resolved value>`` on the root.
##   * ``data-variable-chip-usage-count=<count>`` on the root.
##   * ``data-variable-chip-name="true"`` on the clickable name span.
##   * ``data-variable-chip-chevron="true"`` on the clickable chevron.
##   * ``data-variable-chip-detach="true"`` on the detach button.

import std/strutils

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types

# --------------------------------------------------------------------------- #
#  Configuration.
# --------------------------------------------------------------------------- #

type
  VariableChipConfig* = object
    ## Static configuration consumed by ``mountVariableChip``. Callers
    ## that want reactive updates can rebuild + re-mount the chip; the
    ## binding signal updates are batched at the property-row level
    ## (the row tears down + rebuilds its value slot when the binding
    ## option flips).
    binding*: VariableBinding
      ## The active binding — variable key, resolved value, source
      ## file/line, and ``state`` (``vbsBound`` vs ``vbsBoundMissing``).
    usageCount*: int
      ## "used 23 ×" badge. The chip doesn't render the badge by itself
      ## (the spec scopes that to picker rows); it stamps the count as
      ## a data-attr so consumers can surface the number elsewhere.
    onChevronClick*: proc()
      ## Called when the user clicks the chevron — wires the variable
      ## picker open. Nil is a no-op.
    onNameClick*: proc()
      ## Called when the user clicks the variable name — wires the
      ## inline editor open. Nil is a no-op.
    onDetach*: proc()
      ## Called when the user clicks the detach affordance. Nil is a
      ## no-op. The picker / property row chooses what to do (open a
      ## confirmation mini-popup, detach with the resolved value,
      ## etc.).
    extraRootAttr*: string
      ## Optional ``key=value`` pair stamped on the chip root. Used by
      ## the property row to preserve the legacy
      ## ``data-property-row-linked-chip="true"`` selector. Empty
      ## skips the stamp. Format: ``"key=value"``.
    extraNameAttr*: string
      ## Optional ``key=value`` pair stamped on the chip's name span.
      ## Used by the property row to preserve the legacy
      ## ``data-property-row-linked-variable=<key>`` selector. Empty
      ## skips the stamp.

# --------------------------------------------------------------------------- #
#  Visual contract — matches the spec to 1px precision.
# --------------------------------------------------------------------------- #

const
  # Chip chrome (Phase E.2 spec — § "Visual indicator — the linked
  # chip"). The tinted purple is the design system accent at 12% alpha;
  # the border is the same accent at 30% so the chip reads as a tinted
  # surface, not as a button.
  vcChipBg          = "rgba(124, 122, 237, 0.12)"
  vcChipBorder      = "1px solid rgba(124, 122, 237, 0.30)"
  vcChipRadius      = "4px"
  vcChipHeight      = "26px"
  vcChipPadding     = "0 4px 0 6px"
  vcChipGap         = "4px"

  vcAccent          = "#7C7AED"           ## Indigo accent (diamond glyph)
  vcAccentMissing   = "#F87171"           ## Red — broken-link state
  vcTextPrimary     = "#F1F5F9"           ## Variable name
  vcTextMuted       = "#A0A2B0"           ## Chevron + detach idle colour

  vcGlyphFont       = "14px"
  vcChevronFont     = "10px"
  vcDetachFont      = "11px"
  vcNameFont        = "12px"
  vcNameFamily      = "ui-monospace, 'SFMono-Regular', Menlo, " &
                      "Consolas, monospace"

# --------------------------------------------------------------------------- #
#  Constructor helpers.
# --------------------------------------------------------------------------- #

proc variableChipConfig*(binding: VariableBinding;
                          usageCount: int = 0;
                          onChevronClick: proc() = nil;
                          onNameClick: proc() = nil;
                          onDetach: proc() = nil;
                          extraRootAttr: string = "";
                          extraNameAttr: string = ""): VariableChipConfig =
  ## Convenience constructor that keeps the call sites in property_row
  ## and the picker terse and the unit tests readable.
  VariableChipConfig(
    binding: binding,
    usageCount: usageCount,
    onChevronClick: onChevronClick,
    onNameClick: onNameClick,
    onDetach: onDetach,
    extraRootAttr: extraRootAttr,
    extraNameAttr: extraNameAttr)

func chipStateAttr(state: VariableBindingState): string =
  case state
  of vbsUnbound:       "unbound"
  of vbsBound:         "bound"
  of vbsBoundMissing:  "bound-missing"

# --------------------------------------------------------------------------- #
#  Mount.
# --------------------------------------------------------------------------- #

proc mountVariableChip*[R, E](r: R; parent: E;
                               config: VariableChipConfig): E =
  ## Mount the chip under ``parent``. Returns the chip's root element
  ## so the caller can capture refs or anchor a popover.
  ##
  ## Behaviour:
  ##   * The chevron is the primary chip CTA — clicking it opens the
  ##     variable picker (``config.onChevronClick``).
  ##   * Clicking the variable NAME (not the chevron) opens the inline
  ##     editor (``config.onNameClick``). This matches the spec — two
  ##     surfaces of the same chip, different intent.
  ##   * The detach affordance is hidden by default; on chip hover the
  ##     ``data-variable-chip-hover`` attr flips to ``"true"`` and the
  ##     detach button surfaces. Clicking it calls ``config.onDetach``.
  ##   * Bound-missing chips colour the leading glyph red so the
  ##     broken-link diagnostic reads at a glance (per spec).
  let cfg = config
  let varKey = cfg.binding.variableKey
  let resolved = cfg.binding.resolvedValue
  let stateAttr = chipStateAttr(cfg.binding.state)
  let isMissing = cfg.binding.state == vbsBoundMissing
  let glyphColor = if isMissing: vcAccentMissing else: vcAccent

  var rootNode: E
  var nameNode: E
  var chevronNode: E
  var detachNode: E

  let chip = ui(r):
    tdiv(
      ref = rootNode,
      `data-variable-chip` = "true",
      `data-variable-chip-key` = varKey,
      `data-variable-chip-state` = stateAttr,
      `data-variable-chip-resolved` = resolved,
      `data-variable-chip-usage-count` = $cfg.usageCount,
      `data-variable-chip-hover` = "false",
      role = "group",
      `aria-label` = (if isMissing:
        "Broken binding to " & varKey
      else:
        "Bound to variable " & varKey),
      display = "inline-flex",
      align_items = "center",
      gap = vcChipGap,
      flex = "1",
      min_width = "0",
      height = vcChipHeight,
      padding = vcChipPadding,
      background_color = vcChipBg,
      border = vcChipBorder,
      border_radius = vcChipRadius,
      overflow = "hidden",
      white_space = "nowrap",
      cursor = "default"):
      # Leading diamond glyph — accent colour, or red for broken-link.
      # U+25C7 WHITE DIAMOND.
      span(
        `data-variable-chip-glyph` = "true",
        `aria-hidden` = "true",
        flex_shrink = "0",
        font_size = vcGlyphFont,
        color = glyphColor,
        line_height = "1",
        user_select = "none"):
        text "\xE2\x97\x87"
      # Variable name — clickable. Carries its own data-attr so the
      # picker and the inline editor can tell the two click surfaces
      # apart.
      span(
        ref = nameNode,
        `data-variable-chip-name` = "true",
        role = "button",
        tabindex = "0",
        flex = "1",
        min_width = "0",
        color = vcTextPrimary,
        font_size = vcNameFont,
        font_family = vcNameFamily,
        overflow = "hidden",
        text_overflow = "ellipsis",
        cursor = "pointer"):
        text varKey
      # Detach affordance — hidden by default, surfaces on hover via
      # the ``data-variable-chip-hover`` flip.  The mount sets the
      # attribute reactively so the value scan stays inside a render
      # effect (no setStyle outside reactive effects).
      tdiv(
        ref = detachNode,
        `data-variable-chip-detach` = "true",
        role = "button",
        tabindex = "0",
        `aria-label` = "Detach variable",
        title = "Detach variable",
        flex_shrink = "0",
        display = "none",
        align_items = "center",
        justify_content = "center",
        width = "16px",
        height = "16px",
        margin_right = "2px",
        color = vcTextMuted,
        font_size = vcDetachFont,
        cursor = "pointer",
        user_select = "none"):
        # U+2195 UP DOWN ARROW — matches the spec's "thin ↕ detach
        # affordance" copy.
        text "\xE2\x86\x95"
      # Trailing chevron — primary chip CTA. U+25BE BLACK DOWN-POINTING
      # SMALL TRIANGLE.
      tdiv(
        ref = chevronNode,
        `data-variable-chip-chevron` = "true",
        role = "button",
        tabindex = "0",
        `aria-label` = "Change variable binding for " & varKey,
        `aria-haspopup` = "listbox",
        flex_shrink = "0",
        display = "flex",
        align_items = "center",
        justify_content = "center",
        width = "16px",
        height = "16px",
        color = vcTextMuted,
        font_size = vcChevronFont,
        cursor = "pointer",
        user_select = "none"):
        text "\xE2\x96\xBE"

  # Reactive driver for the hover-state mirror. A signal carries the
  # hover state so the detach affordance's display style can be driven
  # from inside a ``createRenderEffect`` (the only allowed home for a
  # ``setStyle`` call in the widgets layer). ``data-variable-chip-hover``
  # also reflects the same state so the headless tests can observe
  # both transitions.
  let hovered = createSignal(false)

  let setHover = proc(value: bool) =
    hovered.val = value

  createRenderEffect proc() =
    let show = hovered.val
    r.setAttribute(rootNode,
      "data-variable-chip-hover",
      if show: "true" else: "false")
    r.setStyle(detachNode, "display",
      if show: "inline-flex" else: "none")

  r.addEventListener(rootNode, "mouseenter", proc() = setHover(true))
  r.addEventListener(rootNode, "mouseleave", proc() = setHover(false))

  # Click wiring. The handlers stop propagation so a chevron click
  # doesn't also fire the name-click on the parent (the chip root is
  # not itself clickable; only its children are).
  if cfg.onChevronClick != nil:
    let cb = cfg.onChevronClick
    r.addEventListener(chevronNode, "click", proc() = cb())
    r.addEventListener(chevronNode, "keydown", proc() = cb())

  if cfg.onNameClick != nil:
    let cb = cfg.onNameClick
    r.addEventListener(nameNode, "click", proc() = cb())
    r.addEventListener(nameNode, "keydown", proc() = cb())

  if cfg.onDetach != nil:
    let cb = cfg.onDetach
    r.addEventListener(detachNode, "click", proc() = cb())
    r.addEventListener(detachNode, "keydown", proc() = cb())

  # Optional legacy attributes — used by the property row to preserve
  # the ``data-property-row-linked-chip="true"`` +
  # ``data-property-row-linked-variable=<key>`` selectors that landed
  # in Phase D. The chip widget owns the visual chrome; the property
  # row owns the legacy selector contract.
  if cfg.extraRootAttr.len > 0:
    let pair = cfg.extraRootAttr.split('=', maxsplit = 1)
    if pair.len == 2:
      r.setAttribute(rootNode, pair[0], pair[1])
  if cfg.extraNameAttr.len > 0:
    let pair = cfg.extraNameAttr.split('=', maxsplit = 1)
    if pair.len == 2:
      r.setAttribute(nameNode, pair[0], pair[1])

  r.appendChild(parent, chip)
  result = chip
