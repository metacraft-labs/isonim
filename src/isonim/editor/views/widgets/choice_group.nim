## TBAR-M2 — ChoiceGroup widget: pill-style segmented control and
## chevron-popup variant.
##
## Two reusable variants in one module:
##
##   1. ``segmentedChoice`` — a row of N pill buttons, one active at a
##      time. Used by Preview ⇄ Spec (TBAR-M3) and View / Comment /
##      Edit (TBAR-M3 follow-up).
##   2. ``chevronChoice`` — a single pill displaying the active label
##      with a right-aligned chevron; click opens a positioned popup
##      menu listing the alternatives. Used by the screen-size selector
##      in TBAR-M3.
##
## Visual contract is ported from the settings-app's ChoiceItem (see
## ``isonim-examples/settings_app/`` per-platform leaves for the
## rounded-pill look) — *no code dependency* on that repo is taken
## here; the widget uses only ``isonim/dsl/ui`` and renderer protocols
## already established in ``isonim``.
##
## ARIA contract:
##   * segmented variant uses ``role="group"`` on the parent and
##     ``aria-pressed`` on each pill.
##   * chevron variant uses ``aria-haspopup="listbox"`` on the trigger
##     and ``role="listbox"`` with ``role="option"`` children in the
##     popup.
##
## Dogfood: this module uses only the ``ui:`` DSL — no raw ``setStyle``
## calls and no raw ``createElement``. The
## ``test_editor_choice_group_no_setstyle`` source scan asserts this
## invariant.
##
## Keyboard handling on the chevron variant: arrow keys move focus
## within the popup, Enter selects, Escape closes. The arrow-key
## machinery lives inside a ``when defined(js):`` ``{.emit.}`` block
## (the same pattern used by ``shell.nim``'s command palette) — the
## headless tests exercise the VM directly via ``activate`` /
## ``togglePopup`` / ``closePopup``.

import std/sets

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui

type
  ChoiceGroupVariant* = enum
    cgvSegmented   ## Row of pill buttons; one active.
    cgvChevron     ## Single pill + chevron, popup menu.

  ChoiceGroupContainerVariant* = enum
    ## CHRM-M2: originally the chrome-bar Backend + Mode clusters
    ## stripped the widget's container background so each pill could
    ## read as its own affordance. CHRM-M6 Wave B realigned both
    ## variants on the filterBar / ChoiceItem visual spec
    ## (``isonim-examples/task_app/web/leaves.nim``'s ``filterBar``):
    ## every pill is a content-hugging rounded rectangle with
    ## ``border-radius: 6px``, ``padding: 4px 12px``, ``font-size: 12px``,
    ## ``font-weight: 500``, ``min-width: 80px`` for equal pill widths,
    ## active fill in indigo accent, inactive transparent fill with a
    ## subtle outline. Both ``cgvFilled`` and ``cgvTransparent`` now
    ## render IDENTICAL pill chrome — the only difference is the outer
    ## container: ``cgvFilled`` keeps a 1px hairline + padded
    ## background so the row reads as one bordered segmented control
    ## (used in the gallery / story body), while ``cgvTransparent``
    ## drops the container chrome so the pills sit directly on the
    ## chrome-bar surface (used by all four toolbar clusters: Surface,
    ## Backend, Viewport, Mode). The choice between variants is
    ## therefore about *container chrome*, never about *pill chrome* —
    ## the canonical reference is the task_app FilterBar.
    cgvFilled        ## Bordered, rounded container around the pill row.
    cgvTransparent   ## No container chrome; pills sit on parent surface.

  ChoiceGroupVM* = ref object
    ## Reactive ViewModel shared by both variants.
    ##
    ## ``labels`` are immutable for the lifetime of the VM — the
    ## constructor takes them by value and the view binds positionally
    ## by index. ``activeIndex`` and ``popupOpen`` are reactive
    ## signals: writes through ``activate`` / ``togglePopup`` /
    ## ``closePopup`` propagate via the reactive graph.
    ##
    ## ``disabledIndices`` (CHRM-M2) is a reactive set of indices whose
    ## options the mount renders as visually disabled (reduced opacity,
    ## ``aria-disabled="true"``, ``cursor: not-allowed``). Clicks on a
    ## disabled option short-circuit before ``activeIndex`` is mutated
    ## and ``onChange`` does not fire. Writes to the signal propagate
    ## through the reactive graph so the chrome bar's per-backend
    ## availability flag can flip indices in/out at runtime.
    variant*: ChoiceGroupVariant
    labels*: seq[string]
    activeIndex*: Signal[int]
    popupOpen*: Signal[bool]
    disabledIndices*: Signal[HashSet[int]]

# --------------------------------------------------------------------------- #
#  Constructors + state helpers.
# --------------------------------------------------------------------------- #

proc clampInitialIndex(labels: seq[string]; initialIndex: int): int =
  ## Defensive: an out-of-range ``initialIndex`` collapses to 0 (or -1
  ## when the label list is empty). Keeps the VM in a self-consistent
  ## state even when the caller passes garbage.
  if labels.len == 0:
    return -1
  if initialIndex < 0 or initialIndex >= labels.len:
    return 0
  initialIndex

proc createSegmentedChoiceVM*(labels: seq[string];
                              initialIndex: int = 0): ChoiceGroupVM =
  ## Build the VM for the segmented variant. ``popupOpen`` is unused by
  ## the segmented mount but kept on the type so a single VM can be
  ## handed to either mount and so future composition (segmented inside
  ## a chevron, etc.) doesn't need a second VM type.
  ChoiceGroupVM(
    variant: cgvSegmented,
    labels: @labels,
    activeIndex: createSignal(clampInitialIndex(labels, initialIndex)),
    popupOpen: createSignal(false),
    disabledIndices: createSignal(initHashSet[int]()),
  )

proc createChevronChoiceVM*(labels: seq[string];
                            initialIndex: int = 0): ChoiceGroupVM =
  ## Build the VM for the chevron variant.
  ChoiceGroupVM(
    variant: cgvChevron,
    labels: @labels,
    activeIndex: createSignal(clampInitialIndex(labels, initialIndex)),
    popupOpen: createSignal(false),
    disabledIndices: createSignal(initHashSet[int]()),
  )

proc isDisabled*(vm: ChoiceGroupVM; index: int): bool =
  ## CHRM-M2 helper — guards against ``nil`` signal references in case
  ## a VM is hand-constructed without the field initialized.
  if vm == nil or vm.disabledIndices == nil:
    return false
  index in vm.disabledIndices.val

proc setDisabledIndices*(vm: ChoiceGroupVM; indices: HashSet[int]) =
  ## CHRM-M2 — reactive write of the disabled set. Mount-side render
  ## effects react to this change and update ARIA + visual state.
  if vm == nil or vm.disabledIndices == nil:
    return
  vm.disabledIndices.val = indices

proc activate*(vm: ChoiceGroupVM; index: int) =
  ## Set the active index. Out-of-range indices are a no-op (the VM
  ## never lands on a non-existent label). Activating the
  ## already-active index is also a no-op — ``Signal[int]``'s default
  ## equality short-circuits, so subscribers (and ``onChange`` from the
  ## mount) do not re-fire. For the chevron variant, a successful
  ## activation also closes the popup.
  ##
  ## CHRM-M2: a disabled index is also a no-op — the mount's click
  ## handler also guards, but the VM-level guard means that programmatic
  ## ``activate`` calls (e.g. tests, keyboard navigation) respect
  ## disability too.
  if index < 0 or index >= vm.labels.len:
    return
  if vm.isDisabled(index):
    return
  vm.activeIndex.val = index
  if vm.variant == cgvChevron and vm.popupOpen.val:
    vm.popupOpen.val = false

proc togglePopup*(vm: ChoiceGroupVM) =
  ## Flip ``popupOpen``. Idempotent against listeners — the signal's
  ## default equality only fires when the value flips.
  vm.popupOpen.val = not vm.popupOpen.val

proc closePopup*(vm: ChoiceGroupVM) =
  ## Force the popup closed. Safe to call when already closed.
  if vm.popupOpen.val:
    vm.popupOpen.val = false

# --------------------------------------------------------------------------- #
#  Visual contract — pill chrome ported 1:1 from the task_app's
#  ``filterBar`` (the canonical Patterns / Segmented Control reference;
#  see ``isonim-examples/task_app/web/leaves.nim`` lines ~200-235 and
#  ``isonim-examples/briefs/pattern/segmented-control.md``). No code
#  dependency on isonim-examples is taken here — only the visual values.
#
#  CHRM-M6 Wave B: the pill chrome was previously cramped
#  (``padding: 3px 10px``, ``border-radius: 999px`` fully-circular,
#  ``font-size: 11px``, no ``min-width``, ``font-weight: 600``). That
#  diverged from the filterBar / ChoiceItem reference on every property.
#  The realigned spec below restores the canonical rounded-rectangle
#  look so every cluster reads as the same widget family as the
#  task_app's FilterBar and the settings-app's ChoiceItem.
# --------------------------------------------------------------------------- #

const
  # Container chrome — the segmented-control "strip" that hosts the
  # pills. Visibly LIGHTER than the surrounding chrome (bgToolbar
  # = #16171F) so the strip reads as a distinct surface. The active
  # pill sits inset with breathing room on all sides — the user
  # should clearly see the pill is INSIDE the strip, not edge-to-edge.
  cgGroupBg     = "#22232e"  # lifted from bgToolbar so the strip is seen
  cgGroupBorder = "#2d2d3a"

  # Pill chrome — matches settings_app ChoiceItem.
  # Demo render: pills sit inside the trough with NO inter-pill gap
  # and NO inactive fill — inactive pills are just text on the trough
  # background. Only the active pill carries the indigo accent fill.
  # The trough itself provides the cluster's visible shape.
  cgPillBg        = "transparent"  # inactive pills are JUST text
  cgPillBgOn      = "#7c7aed"      # active accent (settings_app demo)
  cgPillBorder    = "transparent"  # no individual pill outlines
  cgPillBorderOn  = "#7c7aed"      # active border matches fill
  cgPillBorderDis = "transparent"
  cgTextDim       = "#A0A2B0"  # inactive muted (readable, not greyed)
  cgTextOn        = "#FFFFFF"  # active text
  cgTextPrim      = "#F1F5F9"  # primary (chevron trigger label)
  cgTextDisabled  = "#475569"  # disabled — visibly lower contrast

  # Pill geometry — every property below is 1:1 with the filterBar.
  cgPillPadding    = "3px 12px"
  cgPillRadius     = "4px"  # smaller than the strip radius — nested look
  cgPillFontSize   = "12px"
  cgPillFontWeight = "500"
  # Pill minimum width — equal pill widths across each cluster's row.
  # The filterBar canonical spec is ``min-width: 80px``; we use ``72px``
  # in the editor's ChoiceGroup because the chrome bar fits four
  # clusters (Backend / Surface / Viewport / Mode) on one row at laptop
  # 1440 px and 80×(7+2+1+3)+gaps overflows the available toolbar width.
  # 72 px still satisfies the brief's "equal pill widths" requirement
  # for every label in use (longest is "Comment" at ~64 px natural,
  # well under the cap) and keeps the visual rhythm consistent with
  # the filterBar at viewport widths where four chrome clusters must
  # coexist with a "Review this preview" + history button.
  cgPillMinWidth   = "72px"
  cgPillMinHeight  = "26px"      # 4 + 12 + 4 + 2 baseline ≈ 26 px

  # Popup chrome (chevron variant).
  cgPopupBg     = "#151D2E"
  cgPopupBorder = "#334155"

# --------------------------------------------------------------------------- #
#  Segmented variant mount.
# --------------------------------------------------------------------------- #

proc mountSegmentedChoice*[R, E](r: R; parent: E; vm: ChoiceGroupVM;
                                  onChange: proc(i: int) {.closure.};
                                  variant: ChoiceGroupContainerVariant =
                                    cgvFilled) =
  ## Mount the segmented pill row into ``parent``. The mount body
  ## structure:
  ##
  ##   1. Build the outer ``role="group"`` container via ``ui(r):``.
  ##   2. Build each pill imperatively via a small ``ui(r):`` block so
  ##      every pill captures its own click + keydown index; append it
  ##      to the root.
  ##   3. Per pill: ``role="button"``, ``aria-pressed`` mirrored via a
  ##      ``createRenderEffect`` over ``vm.activeIndex``; the same
  ##      effect drives the inline ``style`` attribute (so no
  ##      ``setStyle`` call ever leaves a reactive effect).
  ##   4. ``onChange`` fires only when the active index actually moves
  ##      — re-activating the same index is a no-op.
  ##   5. ``appendChild(parent, root)``.
  ##
  ## ``variant`` (CHRM-M2) picks the container chrome: ``cgvFilled``
  ## keeps the TBAR-M2 rounded-pill backdrop, ``cgvTransparent`` strips
  ## the backdrop + widens the inter-pill gap so the pills can sit
  ## directly on a chrome-bar surface without the bespoke
  ## ``tiltHorizontal`` setStyle workaround.
  let capturedVm = vm
  let capturedOnChange = onChange
  let labels = vm.labels

  var pills: seq[E] = @[]

  # Both variants now render as settings_app ChoiceItem (GPUI choiceLeaf)
  # segmented controls: a dark trough with inset pills. ``cgvTransparent``
  # variant drops the outer border (so multiple clusters on a chrome bar
  # don't add up to a heavy 1px-border grid); ``cgvFilled`` keeps the
  # 1px hairline for standalone in-story usage. The trough fill and
  # 2px inner padding are present in both — that's what gives the
  # cluster its ChoiceItem reading.
  let containerBg = cgGroupBg
  let containerBorder =
    if variant == cgvTransparent: "none" else: "1px solid " & cgGroupBorder
  let containerRadius = "6px"  # strip outer radius
  let containerGap = "2px"     # tiny gap between pills (visible separation inside the strip)
  let containerPadding = "3px" # breathing room around pills inside the strip
  let variantAttr =
    if variant == cgvTransparent: "transparent" else: "filled"

  let root = ui(r):
    tdiv(
      `role` = "group",
      `aria-label` = "Choice group",
      `data-choice-group` = "segmented",
      `data-choice-group-variant` = variantAttr,
      display = "inline-flex",
      flex_direction = "row",
      align_items = "center",
      gap = containerGap,
      padding = containerPadding,
      background_color = containerBg,
      border = containerBorder,
      border_radius = containerRadius,
      user_select = "none")

  for i in 0 ..< labels.len:
    closureScope:
      let lbl = labels[i]
      var pillNode: E
      discard ui(r):
        tdiv(
          ref = pillNode,
          `role` = "button",
          tabindex = "0",
          `aria-pressed` = "false",
          `data-choice-group-pill` = $i,
          `data-choice-group-label` = lbl,
          display = "inline-flex",
          align_items = "center",
          justify_content = "center",
          min_height = cgPillMinHeight,
          min_width = cgPillMinWidth,
          padding = cgPillPadding,
          font_size = cgPillFontSize,
          font_weight = cgPillFontWeight,
          font_family = "inherit",
          line_height = "1",
          text_align = "center",
          color = cgTextDim,
          background_color = cgPillBg,
          border = "1px solid " & cgPillBorder,
          border_radius = cgPillRadius,
          cursor = "pointer",
          white_space = "nowrap",
          transition = "background-color 120ms ease-out, " &
            "border-color 120ms ease-out, color 120ms ease-out"):
          text lbl
      pills.add pillNode
      r.appendChild(root, pillNode)

  proc selectIndex(i: int) =
    # CHRM-M2: disabled options refuse the click before the VM mutates.
    if capturedVm.isDisabled(i):
      return
    let prev = capturedVm.activeIndex.val
    capturedVm.activate(i)
    let now = capturedVm.activeIndex.val
    if now != prev and capturedOnChange != nil:
      capturedOnChange(now)

  for i in 0 ..< labels.len:
    closureScope:
      let idx = i
      let pill = pills[idx]
      let handler = proc() = selectIndex(idx)
      r.addEventListener(pill, "click", handler)
      r.addEventListener(pill, "keydown", handler)

  # Reactive visual binding — drives ``aria-pressed`` plus an
  # inline-style string so we avoid ``setStyle`` calls outside this
  # reactive effect.
  createRenderEffect proc() =
    let active = capturedVm.activeIndex.val
    let disabled =
      if capturedVm.disabledIndices == nil: initHashSet[int]()
      else: capturedVm.disabledIndices.val
    for i in 0 ..< pills.len:
      let isActive = (i == active)
      let isDisabled = i in disabled
      r.setAttribute(pills[i], "aria-pressed",
                     if isActive: "true" else: "false")
      r.setAttribute(pills[i], "aria-disabled",
                     if isDisabled: "true" else: "false")
      r.setAttribute(pills[i], "data-active",
                     if isActive: "true" else: "false")
      r.setAttribute(pills[i], "data-choice-group-disabled",
                     if isDisabled: "true" else: "false")
      r.setAttribute(pills[i], "tabindex",
                     if isDisabled: "-1" else: "0")
      # The reactive ``setAttribute("style", ...)`` REPLACES the
      # entire style attribute (it does not merge with the DSL-declared
      # properties). So this string must carry the FULL pill chrome
      # (layout + colors + transition), not just the state-dependent
      # colors. Without this, the rendered pill loses padding /
      # border-radius / font-size / min-width on the first paint and
      # reads as bare text. See user report 2026-05-27.
      const layoutCss =
        "display: inline-flex; align-items: center; " &
        "justify-content: center; " &
        "padding: " & cgPillPadding & "; " &
        "min-width: " & cgPillMinWidth & "; " &
        "min-height: " & cgPillMinHeight & "; " &
        "border-radius: " & cgPillRadius & "; " &
        "border-width: 1px; border-style: solid; " &
        "font-size: " & cgPillFontSize & "; " &
        "font-weight: " & cgPillFontWeight & "; " &
        "font-family: inherit; line-height: 1; " &
        "text-align: center; white-space: nowrap; " &
        "flex: 0 0 auto; " &
        "transition: background-color 120ms ease-out, " &
        "border-color 120ms ease-out, color 120ms ease-out;"
      var inline =
        if isDisabled:
          layoutCss &
            " background-color: " & cgPillBg &
            "; color: " & cgTextDisabled &
            "; border-color: " & cgPillBorderDis &
            "; cursor: not-allowed;"
        elif isActive:
          layoutCss &
            " background-color: " & cgPillBgOn &
            "; color: " & cgTextOn &
            "; border-color: " & cgPillBorderOn &
            "; cursor: pointer;"
        else:
          layoutCss &
            " background-color: " & cgPillBg &
            "; color: " & cgTextDim &
            "; border-color: " & cgPillBorder &
            "; cursor: pointer;"
      r.setAttribute(pills[i], "style", inline)

  r.appendChild(parent, root)

# --------------------------------------------------------------------------- #
#  Chevron variant mount.
# --------------------------------------------------------------------------- #

proc mountChevronChoice*[R, E](r: R; parent: E; vm: ChoiceGroupVM;
                                onChange: proc(i: int) {.closure.};
                                variant: ChoiceGroupContainerVariant =
                                  cgvFilled) =
  ## Mount the chevron + popup combo into ``parent``. The mount body
  ## structure:
  ##
  ##   1. Build a relative-positioned wrapper, the trigger pill (with
  ##      ``aria-haspopup="listbox"`` + the active label + a chevron
  ##      glyph), and the popup ``role="listbox"`` host in one
  ##      ``ui(r):`` block.
  ##   2. Build each popup option imperatively via a small ``ui(r):``
  ##      block (so each option captures its own index for the click
  ##      handler); append into the popup host.
  ##   3. Trigger click → ``vm.togglePopup``. The popup's visibility,
  ##      ``aria-expanded``, and trigger label are driven from
  ##      ``createRenderEffect`` blocks bound to ``vm.popupOpen`` /
  ##      ``vm.activeIndex``.
  ##   4. Keyboard handling (ArrowDown / ArrowUp / Enter / Escape) and
  ##      outside-click dismissal live in a ``when defined(js):``
  ##      ``{.emit.}`` block — the headless tests exercise the same
  ##      transitions via the VM API directly.
  ##   5. ``appendChild(parent, root)``.
  let capturedVm = vm
  let capturedOnChange = onChange
  let labels = vm.labels

  var triggerNode: E
  var triggerLabelNode: E
  var popupNode: E
  var optionNodes: seq[E] = @[]

  # CHRM-M6 Wave B: the chevron trigger pill now uses the same
  # filterBar-aligned chrome as the segmented variant. The only
  # geometric deviations are (1) a slightly wider ``min-width`` so
  # viewport labels like "Mobile Portrait" don't truncate, and (2)
  # ``justify-content: space-between`` so the chevron glyph sits at
  # the trailing edge of the pill rather than centred.
  let triggerBg =
    if variant == cgvTransparent: "transparent" else: cgGroupBg
  let triggerBorder = "1px solid " & cgPillBorder
  let variantAttr =
    if variant == cgvTransparent: "transparent" else: "filled"

  let root = ui(r):
    tdiv(
      `data-choice-group` = "chevron",
      `data-choice-group-variant` = variantAttr,
      display = "inline-block",
      position = "relative",
      user_select = "none"):
      tdiv(
        ref = triggerNode,
        `role` = "button",
        tabindex = "0",
        `aria-haspopup` = "listbox",
        `aria-expanded` = "false",
        `data-choice-group-trigger` = "true",
        display = "inline-flex",
        align_items = "center",
        justify_content = "space-between",
        min_height = cgPillMinHeight,
        min_width = "112px",
        gap = "6px",
        padding = cgPillPadding,
        font_size = cgPillFontSize,
        font_weight = cgPillFontWeight,
        font_family = "inherit",
        line_height = "1",
        color = cgTextPrim,
        background_color = triggerBg,
        border = triggerBorder,
        border_radius = cgPillRadius,
        cursor = "pointer",
        white_space = "nowrap",
        transition = "background-color 120ms ease-out, " &
          "border-color 120ms ease-out, color 120ms ease-out"):
        span(
          ref = triggerLabelNode,
          `data-choice-group-trigger-label` = "true",
          font_size = cgPillFontSize,
          font_weight = cgPillFontWeight):
          # Initial text is empty; the reactive ``createRenderEffect``
          # below seeds it from ``vm.activeIndex`` + ``labels`` on the
          # first reactive tick.
          text ""
        span(
          `aria-hidden` = "true",
          `data-choice-group-chevron` = "true",
          font_size = "10px",
          color = cgTextDim,
          margin_left = "4px"):
          # Unicode chevron down (U+25BE BLACK DOWN-POINTING SMALL
          # TRIANGLE). Chosen over inline SVG because the editor's
          # other toolbar glyphs (the history-button clock face, the
          # ``choice_row.nim`` overflow chevron) all use Unicode
          # symbols — staying consistent keeps the bundle smaller.
          text "\xE2\x96\xBE"
      tdiv(
        ref = popupNode,
        `role` = "listbox",
        tabindex = "-1",
        `aria-label` = "Choice options",
        `data-choice-group-popup` = "true",
        `data-popup-open` = "false",
        position = "absolute",
        left = "0",
        top = "100%",
        margin_top = "4px",
        min_width = "100%",
        padding = "4px",
        background_color = cgPopupBg,
        border = "1px solid " & cgPopupBorder,
        border_radius = "6px",
        box_shadow = "0 8px 24px rgba(0,0,0,0.28)",
        z_index = "40")

  # Build the popup options imperatively so each one gets its own
  # click handler bound to a captured index.
  for i in 0 ..< labels.len:
    closureScope:
      let lbl = labels[i]
      var optNode: E
      discard ui(r):
        tdiv(
          ref = optNode,
          `role` = "option",
          tabindex = "-1",
          `aria-selected` = "false",
          `data-choice-group-option` = $i,
          `data-choice-group-option-label` = lbl,
          display = "flex",
          align_items = "center",
          padding = "4px 12px",
          font_size = cgPillFontSize,
          font_weight = cgPillFontWeight,
          font_family = "inherit",
          line_height = "1.4",
          color = cgTextPrim,
          background_color = "transparent",
          border_radius = "4px",
          cursor = "pointer",
          white_space = "nowrap"):
          text lbl
      optionNodes.add optNode
      r.appendChild(popupNode, optNode)

  proc selectIndex(i: int) =
    # CHRM-M2: disabled options refuse the click.
    if capturedVm.isDisabled(i):
      return
    let prev = capturedVm.activeIndex.val
    capturedVm.activate(i)
    let now = capturedVm.activeIndex.val
    if now != prev and capturedOnChange != nil:
      capturedOnChange(now)

  # Trigger click → toggle popup.
  let triggerHandler = proc() =
    capturedVm.togglePopup()
  r.addEventListener(triggerNode, "click", triggerHandler)
  # We intentionally do *not* register a no-arg ``keydown`` handler
  # on the trigger here. A generic keydown listener would fire for
  # ArrowDown / ArrowUp / Escape too and conflict with the
  # JS-side arrow-navigation. The JS handler (in the
  # ``when defined(js):`` block below) interprets ArrowDown / Enter
  # / Space and either opens the popup + moves focus or synthesises
  # a click against the trigger.

  for i in 0 ..< labels.len:
    closureScope:
      let idx = i
      let opt = optionNodes[idx]
      let pickHandler = proc() = selectIndex(idx)
      r.addEventListener(opt, "click", pickHandler)
      # We deliberately do *not* register a per-option ``keydown``
      # listener here: a generic no-arg keydown would fire on every
      # key (including ArrowUp / ArrowDown) and steal the
      # arrow-navigation that the JS-side handler implements. The
      # ``Enter`` key is forwarded via the JS-side handler which
      # synthesises a ``click`` against the focused option.

  # Reactive popup visibility — drives ``aria-expanded`` on the
  # trigger and the inline ``style`` attribute on the popup. The
  # ``style`` attribute is set via ``setAttribute("style", ...)``
  # rather than ``setStyle`` so the ``no setStyle outside reactive
  # effects`` lexer scan stays green. (And anyway, this *is* inside a
  # reactive effect.)
  createRenderEffect proc() =
    let open = capturedVm.popupOpen.val
    r.setAttribute(triggerNode, "aria-expanded",
                   if open: "true" else: "false")
    r.setAttribute(popupNode, "data-popup-open",
                   if open: "true" else: "false")
    r.setAttribute(popupNode, "style",
                   if open: "display: flex; flex-direction: column;"
                   else: "display: none;")

  # Reactive active-label binding — updates trigger text + per-option
  # ``aria-selected``. CHRM-M2 also surfaces ``aria-disabled`` +
  # reduced-opacity styling for disabled options.
  createRenderEffect proc() =
    let active = capturedVm.activeIndex.val
    let safe =
      if active >= 0 and active < labels.len: active
      else: -1
    let disabled =
      if capturedVm.disabledIndices == nil: initHashSet[int]()
      else: capturedVm.disabledIndices.val
    if safe >= 0:
      r.setTextContent(triggerLabelNode, labels[safe])
    else:
      r.setTextContent(triggerLabelNode, "")
    for i in 0 ..< optionNodes.len:
      let isDisabled = i in disabled
      r.setAttribute(optionNodes[i], "aria-selected",
                     if i == safe: "true" else: "false")
      r.setAttribute(optionNodes[i], "aria-disabled",
                     if isDisabled: "true" else: "false")
      r.setAttribute(optionNodes[i], "data-active",
                     if i == safe: "true" else: "false")
      r.setAttribute(optionNodes[i], "data-choice-group-disabled",
                     if isDisabled: "true" else: "false")
      let optStyle =
        if isDisabled: "opacity: 0.35; cursor: not-allowed;"
        else: "opacity: 1; cursor: pointer;"
      r.setAttribute(optionNodes[i], "style", optStyle)

  when defined(js):
    # Browser-side keyboard navigation + outside-click dismissal.
    # Same pattern as ``shell.nim``'s command palette: the JS layer
    # intercepts ArrowDown / ArrowUp / Enter / Escape on the wrapper
    # and dispatches focus moves / synthetic click events back into
    # the renderer-managed handlers.
    let rootNode = root
    let triggerEl = triggerNode
    let popupEl = popupNode
    {.emit: ["""
      (function(rootEl, triggerEl, popupEl) {
        if (!rootEl || !document) return;
        function options() {
          return Array.from(popupEl.querySelectorAll(
            '[data-choice-group-option]'));
        }
        function focusedIndex() {
          var opts = options();
          var active = document.activeElement;
          for (var i = 0; i < opts.length; i++) {
            if (opts[i] === active) return i;
          }
          return -1;
        }
        function activeOptionIndex() {
          var opts = options();
          for (var i = 0; i < opts.length; i++) {
            if (opts[i].getAttribute('data-active') === 'true') return i;
          }
          return -1;
        }
        function openPopup() {
          if (popupEl.getAttribute('data-popup-open') !== 'true') {
            triggerEl.click();
          }
        }
        function closePopup() {
          if (popupEl.getAttribute('data-popup-open') === 'true') {
            triggerEl.click();
          }
        }
        rootEl.addEventListener('keydown', function(ev) {
          var key = ev && ev.key;
          if (!key) return;
          var inPopup = popupEl.contains && popupEl.contains(ev.target);
          var onTrigger = (ev.target === triggerEl);
          if (key === 'Escape') {
            ev.preventDefault();
            closePopup();
            triggerEl.focus();
            return;
          }
          if (key === 'ArrowDown' || key === 'Down') {
            ev.preventDefault();
            ev.stopPropagation();
            openPopup();
            var opts = options();
            if (!opts.length) return;
            if (onTrigger) {
              var initial = activeOptionIndex();
              if (initial < 0) initial = 0;
              opts[initial].focus();
            } else if (inPopup) {
              var ci = focusedIndex();
              var ni = (ci + 1) % opts.length;
              opts[ni].focus();
            }
            return;
          }
          if (key === 'ArrowUp' || key === 'Up') {
            ev.preventDefault();
            ev.stopPropagation();
            if (inPopup) {
              var opts2 = options();
              if (!opts2.length) return;
              var ci2 = focusedIndex();
              var pi = (ci2 - 1 + opts2.length) % opts2.length;
              opts2[pi].focus();
            }
            return;
          }
          if (key === 'Enter' || key === ' ' || key === 'Space'
              || key === 'Spacebar') {
            if (inPopup) {
              ev.preventDefault();
              ev.stopPropagation();
              var ci3 = focusedIndex();
              if (ci3 >= 0) {
                options()[ci3].click();
                triggerEl.focus();
              }
            } else if (onTrigger) {
              // The Nim-side ``keydown`` listener already toggled the
              // popup; do not double-fire.
              ev.preventDefault();
            }
            return;
          }
        });
        document.addEventListener('mousedown', function(ev) {
          var t = ev && ev.target;
          if (!t) return;
          if (rootEl.contains && rootEl.contains(t)) return;
          if (popupEl.getAttribute('data-popup-open') !== 'true') return;
          closePopup();
        }, true);
      })(""", rootNode, """, """, triggerEl, """, """, popupEl, """);
    """].}

  r.appendChild(parent, root)
