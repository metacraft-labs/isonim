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
    ## CHRM-M2: the chrome-bar Backend + Mode clusters strip the
    ## widget's container background so each pill reads as its own
    ## affordance rather than a segment of one filled bar. ``cgvFilled``
    ## keeps the canonical TBAR-M2 rounded-pill chrome (background +
    ## border on the container). ``cgvTransparent`` drops the container
    ## chrome so the pills sit directly on the surrounding surface; the
    ## inter-pill gap widens to compensate. The Surface (segmented) and
    ## Viewport (chevron) clusters use ``cgvTransparent`` in the chrome
    ## bar today — passing the variant declaratively here replaces the
    ## old ``tiltHorizontal`` imperative setStyle hack.
    cgvFilled        ## Default — bordered, rounded container.
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
#  Visual contract — colours / sizing copied from the settings-app's
#  rounded-pill look (no code dependency on isonim-examples).
# --------------------------------------------------------------------------- #

const
  cgGroupBg     = "#15151c"
  cgPillBg      = "transparent"
  cgPillBgOn    = "#3B82F6"
  cgBorder      = "#2d2d3a"
  cgBorderOn    = "#3B82F6"
  cgTextDim     = "#A0A2B0"
  cgTextOn      = "#FFFFFF"
  cgTextPrim    = "#F1F5F9"
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

  let containerBg =
    if variant == cgvTransparent: "transparent" else: cgGroupBg
  let containerBorder =
    if variant == cgvTransparent: "none" else: "1px solid " & cgBorder
  let containerRadius =
    if variant == cgvTransparent: "0" else: "8px"
  let containerGap =
    if variant == cgvTransparent: "4px" else: "2px"
  let containerPadding =
    if variant == cgvTransparent: "0" else: "2px"
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
          min_height = "22px",
          padding = "3px 12px",
          font_size = "11px",
          font_weight = "500",
          line_height = "1",
          color = cgTextDim,
          background_color = cgPillBg,
          border = "1px solid transparent",
          border_radius = "6px",
          cursor = "pointer",
          white_space = "nowrap"):
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
      var inline =
        if isActive:
          "background-color: " & cgPillBgOn &
            "; color: " & cgTextOn &
            "; border-color: " & cgBorderOn & ";"
        else:
          "background-color: " & cgPillBg &
            "; color: " & cgTextDim &
            "; border-color: transparent;"
      if isDisabled:
        inline.add " opacity: 0.35; cursor: not-allowed;"
      else:
        inline.add " opacity: 1; cursor: pointer;"
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

  let triggerBg =
    if variant == cgvTransparent: "transparent" else: cgGroupBg
  let triggerBorder =
    if variant == cgvTransparent: "1px solid rgba(255,255,255,0.08)"
    else: "1px solid " & cgBorder
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
        min_width = "96px",
        gap = "6px",
        padding = "3px 10px",
        font_size = "11px",
        font_weight = "500",
        line_height = "1",
        color = cgTextPrim,
        background_color = triggerBg,
        border = triggerBorder,
        border_radius = "6px",
        cursor = "pointer",
        white_space = "nowrap"):
        span(
          ref = triggerLabelNode,
          `data-choice-group-trigger-label` = "true",
          font_size = "11px",
          font_weight = "500"):
          # Initial text is empty; the reactive ``createRenderEffect``
          # below seeds it from ``vm.activeIndex`` + ``labels`` on the
          # first reactive tick.
          text ""
        span(
          `aria-hidden` = "true",
          `data-choice-group-chevron` = "true",
          font_size = "9px",
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
          padding = "4px 10px",
          font_size = "11px",
          font_weight = "500",
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
