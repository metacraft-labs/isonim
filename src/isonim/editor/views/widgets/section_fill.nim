## Phase G — Fill section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * One row per fill entry. Each row: 16x16 swatch + 7-char hex
##     input + opacity ``%`` input + bind affordance.
##   * "+ Add fill" pill below the list (mirrors the section header
##     ``+`` button).
##
## Phase G keeps fills in a section-local
## ``Signal[seq[FillEntry]]`` seeded from ``background-color`` on the
## selected element. Phase H lifts the signal onto the inspector so
## multi-fill compositing is a first-class VM concept.

import std/[options, strutils, math]

import isonim/core/owner
import isonim/core/signals
import isonim/core/computation
import isonim/core/batch
import isonim/dsl/ui
import isonim/editor/views/widgets/anchored_popover
import isonim/editor/views/widgets/color_popover
import isonim/editor/views/choice_row
import isonim/editor/types
import isonim/editor/element_semantics
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/section_position
import isonim/editor/views/widgets/variable_chip
import isonim/editor/views/widgets/property_row  # measureAnchorRect (VBIND-M2)
import isonim/editor/views/widgets/property_actions
import isonim/editor/views/widgets/inspector_search
import isonim/editor/views/widgets/section_raw_css

type
  FillEntry* = object
    color*: string
    alpha*: float

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  accent = "#7C7AED"
  bgInput = "#1A1B22"

  # Phase G+1 refusal copy. Held as constants so the closures that
  # raise them stay single-statement — a multi-line `&` as the last
  # expression of an anonymous proc trips Nim's indentation rules.
  secondaryFillNotice =
    "Only the first fill maps to a source property; additional fills " &
    "are preview-only."
  fillAlphaNotice =
    "Fill opacity is preview-only until fills compose an rgba() source value."

proc mountSectionFill*[R, E](r: R; parent: E; vm: EditorVM) =
  let entries = createSignal[seq[FillEntry]](@[])

  # Phase G+1: the fill section hand-builds its rows rather than going
  # through ``mountPropertyRow``, so it needs the writeback wired
  # directly. Only the primary fill has a source property to write:
  # the section's own read path (see ``mountRow``) already treats
  # entry 0 as the selected element's canonical ``background-color``
  # and calls multi-fill compositing an honest M1 gap.
  #
  # The consequence for rows 1..n is that they cannot commit — and
  # saying so is the whole point of this phase. Before, editing them
  # silently updated a section-local signal and nothing else, which
  # looks identical to editing row 0 and is not.
  # Which property "Fill" means depends on what is selected: a text layer's
  # fill is its text colour (`element_semantics.fillTargetProperty`). The
  # wiring has to follow the selection, so it is read inside the effects
  # below rather than captured once at mount -- capturing it here would bind
  # every element to whatever the first selection happened to be.
  proc fillProperty(): string =
    fillTargetProperty(vm.inspector.selectedElement.val.tag)

  # Both wirings are built once. `inspectorRowWiring` owns signals, so
  # rebuilding one per commit would hand each commit a fresh message signal
  # that nothing is rendering -- the refusal would be recorded where no one
  # could see it. Two cheap long-lived wirings, and a picker.
  let textFillWiring = vm.inspectorRowWiring("color")
  let boxFillWiring = vm.inspectorRowWiring("background-color")
  proc fillWiringNow(): InspectorRowWiring =
    if fillProperty() == "color": textFillWiring else: boxFillWiring
  # The fill rows are hand-built, so they register their wirings with the
  # section's raw CSS themselves (`property_row` does it for its rows).
  registerSectionCssRow(boxFillWiring)
  registerSectionCssRow(textFillWiring)

  # Selection identity precedes asynchronously delivered computed properties.
  # Track the actual fill-bearing input as well as ID so hydration/reload of the
  # same selected element refreshes its controls. Unrelated property updates do
  # not discard locally added fill rows or an in-progress draft.
  var lastFillInput = (id: "", story: "", property: "", value: "", hasElement: false)
  let fillTargetIdentity = createSignal("")
  createRenderEffect proc() =
    let el = vm.inspector.selectedElement.val
    let selectedStory = vm.selectedStory.val
    let story = selectedStory.group & " / " & selectedStory.name & " / " & $selectedStory.kind
    let hasElement = vm.inspector.hasElement.val
    let property = fillTargetProperty(el.tag)
    let value = if hasElement: findPropertyValue(el.properties, property, "") else: ""
    let input = (id: el.id, story: story, property: property, value: value, hasElement: hasElement)
    fillTargetIdentity.val = story & " / " & el.id & " / " & property
    if input != lastFillInput:
      lastFillInput = input
      if hasElement and value.len > 0 and value notin ["transparent", "none"]:
        entries.val = @[FillEntry(color: value, alpha: colorChannels(value).alpha.float / 255)]
      else:
        entries.val = @[]

  var listEl: E
  var emptyEl: E
  var addBtnEl: E
  var messageEl: E

  # Phase H (2026-05-28): the Figma reference shows ONLY the
  # placeholder hint when the list is empty — the section header's
  # ``+`` button is the canonical "add fill" affordance. We retain
  # the body-level ``data-fill-add`` button (the per-section test
  # binds to it) but render it as a tiny invisible focus target
  # behind the placeholder text — the placeholder doubles as the
  # click surface. This keeps the spec's section-header ``+`` as
  # the visual anchor without breaking the headless test contract.
  let body = ui(r):
    tdiv(`data-fill-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "4px", padding = "2px 0"):
      tdiv(ref = listEl,
            `data-fill-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-fill-empty` = "true",
            padding = "2px 0",
            font_size = "12px",
            color = textMuted):
        text "Click + to replace mixed content"
      # Phase G+1 refusal surface. Hidden while empty; carries the
      # reason a fill edit could not reach source.
      tdiv(ref = messageEl,
            `data-fill-message` = "true",
            role = "status",
            `aria-live` = "polite",
            padding = "0 0 2px 0",
            font_size = "10px",
            line_height = "1.35",
            color = "#FBBF24"):
        text ""
      tdiv(ref = addBtnEl,
            role = "button", tabindex = "0",
            `data-fill-add` = "true",
            `aria-label` = "Add fill",
            display = "none")
  r.appendChild(parent, body)
  let sourceChoices = renderCompactChoiceRow[R,E](r,"","Choose fill source scope",
    proc(): seq[CompactChoiceOption] = fillWiringNow().scopeOptions(), visibleLimit = 1)
  r.setAttribute(sourceChoices.root,"data-fill-source-scope","true")
  r.appendChild(body,sourceChoices.root)
  let sourceImpact = ui(r):
    tdiv(`data-fill-source-impact` = "true", role = "note",
      font_size = "10px", line_height = "1.35", color = textMuted)
  r.appendChild(body,sourceImpact)
  createRenderEffect proc() =
    var description = ""
    for option in fillWiringNow().scopeOptions():
      for (key,value) in option.dataAttrs:
        if key == "data-source-scope-token" and value.len > 0 and option.selected:
          description = option.shortLabel & ": " & option.label
    r.setTextContent(sourceImpact,description)
    r.setStyle(sourceImpact,"display",if description.len > 0: "block" else: "none")

  proc mountRow(idx: int) =
    ## Isolating helper — closure-captures ``idx`` from this proc's
    ## scope so each row's click handlers bind to the right index.
    ## ``for``-body ``let`` does not isolate captures across iterations.
    ##
    ## VBIND-M1 read-path: the first fill entry maps onto the
    ## selected element's canonical ``background-color`` property, so
    ## when that property is bound to a design-system variable the
    ## value area renders the real ``variable_chip`` instead of the
    ## inert ``◇``. Reading the binding here (inside ``rebuildList``'s
    ## ``createRenderEffect``) makes the row re-render when the binding
    ## or the selection changes. Because ``propertyBindings`` is empty
    ## for every workspace until M5 seeds it, ``binding`` is ``none``
    ## for every row today and the DOM is byte-identical to before.
    ##
    ## Only the primary fill (idx 0) participates in M1: multi-fill
    ## compositing has no per-index canonical CSS property yet, so
    ## additional fill rows stay literal (honest M1 gap — see M2/M3).
    # The row follows ITS entry reactively instead of being rebuilt for
    # every new value. Rebuilding on each value change disposed the open
    # colour picker the moment one of its fields committed, so a picker
    # could make at most one edit per opening.
    proc entryNow(): FillEntry =
      let list = entries.val
      if idx < list.len: list[idx] else: FillEntry()
    let targetId = vm.inspector.selectedElement.val.id
    let targetStory = vm.selectedStory.val
    proc currentTarget(): bool =
      let current = vm.selectedStory.val
      vm.inspector.selectedElement.val.id == targetId and
        current.group == targetStory.group and current.name == targetStory.name and current.kind == targetStory.kind
    var rowActive = true
    onCleanup(proc() = rowActive = false)
    let binding =
      if idx == 0: vm.inspectorBindingFor(fillProperty())
      else: none(VariableBinding)
    var swatchEl: E
    var hexEl: E
    var alphaEl: E
    var bindEl: E
    var deleteEl: E
    var chipHostEl: E
    let row = ui(r):
      tdiv(`data-fill-row` = $idx,
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            padding = "4px 6px",
            border = "1px solid " & border, border_radius = "4px"):
        tdiv(ref = swatchEl,
              `data-fill-row-swatch` = $idx,
              role = "button", tabindex = "0",
              width = "16px", height = "16px",
              # The swatch sits on a near-black panel and very often holds a
              # near-black colour -- `sys.color.text.primary` is rgb(21,23,26)
              # in the grip pilot. At 12% the border was invisible and the
              # swatch read as an empty outline, i.e. as "no colour set" for
              # an element that has one. 34% separates it from the panel
              # without competing with the value next to it.
              border = "1px solid rgba(255, 255, 255, 0.34)",
              border_radius = "3px",
              cursor = "pointer", flex_shrink = "0")
        if binding.isSome:
          # Linked chip read-path — replaces the hex + opacity inputs
          # and the inert ◇ bind slot with the real variable chip.
          # The detach / re-bind click wiring lands in M2/M3; for M1
          # the chip is display-only.
          tdiv(ref = chipHostEl,
                `data-fill-row-chip-host` = $idx,
                display = "flex", flex = "1", min_width = "0",
                align_items = "center")
        else:
          input(ref = hexEl,
                 `data-fill-row-hex` = $idx,
                 `aria-label` = "Edit fill hex",
                 flex = "1", min_width = "0",
                 background_color = bgInput,
                 border = "1px solid " & border,
                 border_radius = "3px",
                 color = textPrimary, font_size = "11px",
                 font_family = "monospace",
                 padding = "2px 6px", height = "22px")
          input(ref = alphaEl,
                 `data-fill-row-alpha` = $idx,
                 `aria-label` = "Edit fill opacity",
                 width = "48px",
                 background_color = bgInput,
                 border = "1px solid " & border,
                 border_radius = "3px",
                 color = textSecondary, font_size = "11px",
                 padding = "2px 6px", height = "22px",
                 text_align = "right")
          tdiv(ref = bindEl,
                role = "button", tabindex = "0",
                `data-fill-row-bind` = $idx,
                `aria-label` = "Bind fill to variable",
                width = "20px", height = "20px",
                display = "flex", align_items = "center",
                justify_content = "center",
                color = textMuted, font_size = "12px",
                cursor = "pointer"):
            text "\xE2\x97\x87"
        tdiv(ref = deleteEl,
              role = "button", tabindex = "0",
              `data-fill-row-delete` = $idx,
              `aria-label` = "Delete fill",
              `aria-disabled` = "true",
              width = "20px", height = "20px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = textMuted, font_size = "11px",
              cursor = "pointer"):
          text "\xC3\x97"
    r.appendChild(listEl, row)
    createRenderEffect proc() =
      r.setStyle(swatchEl, "background-color", entryNow().color)
    # Set below for a literal (unbound) fill: the paste commits through the
    # same `commitColor` as typing a hex value.
    var pasteColor: proc(value: string) {.closure.}
    if binding.isSome:
      r.setAttribute(row, "data-fill-row-linked", "true")
      # VBIND-M2: the chip's chevron re-opens the picker anchored to the
      # chip for the canonical ``background-color`` binding (primary fill
      # only). Additional fill rows have no canonical CSS key yet, so
      # their chevron stays inert (honest M2 gap — see M3+).
      var chipRootRef: E
      let chevronCb =
        if idx == 0:
          (proc() =
            let rc = measureAnchorRect(chipRootRef)
            vm.requestInspectorVariablePicker(fillProperty(),
              rc.x, rc.y, rc.w, rc.h))
        else:
          nil
      # VBIND-M3: the chip's UNLINK / detach affordance detaches the
      # primary fill's ``background-color`` binding into a LOCAL literal
      # override seeded with the resolved value, journaled onto
      # ``pendingSourceEdits``. Additional fill rows have no canonical
      # CSS key yet, so their detach stays inert (honest gap — see M3+).
      let detachCb =
        if idx == 0: vm.inspectorDetachRequestHandler(fillProperty())
        else: nil
      let chipConfig = variableChipConfig(
        binding = binding.get,
        onChevronClick = chevronCb,
        onDetach = detachCb,
        extraRootAttr = "data-fill-row-linked-chip=true")
      chipRootRef = r.mountVariableChip(chipHostEl, chipConfig)
    else:
      # VBIND-M2: clicking the inert ◇ bind slot opens the variable
      # picker for the primary fill's canonical ``background-color``
      # property, anchored to the slot. Only the primary fill (idx 0)
      # participates — extra fill rows have no canonical key yet.
      if idx == 0:
        installPopoverTrigger(bindEl)
        r.addEventListener(bindEl, "click", proc() =
          let rc = measureAnchorRect(bindEl)
          vm.requestInspectorVariablePicker(fillProperty(),
            rc.x, rc.y, rc.w, rc.h))
      let colorState = createColorPopoverState()
      proc commitColor(value: string; done: proc(ok: bool) {.closure.}) {.closure.} =
        if not rowActive or not currentTarget():
          done(false)
          return
        if idx != 0:
          fillWiringNow().commitMessage.val = secondaryFillNotice
          done(false)
          return
        let sourceReason = fillWiringNow().readOnlyReason()
        if sourceReason.len > 0:
          fillWiringNow().commitMessage.val = sourceReason
          done(false)
          return
        let normalized = normalizedHexColor(value)
        if normalized.len == 0:
          fillWiringNow().commitMessage.val = "Enter a complete hex color."
          done(false)
          return
        if normalized == normalizedHexColor(entryNow().color):
          done(true)
          return
        fillWiringNow().commitAsync(normalized, proc(ok: bool) =
          if ok and rowActive and currentTarget():
            var next = entries.val
            if idx < next.len:
              next[idx].color = normalized
              next[idx].alpha = colorChannels(normalized).alpha.float / 255
              entries.val = next
          done(ok))
      discard mountColorPopover(r, row, swatchEl, colorState,
        proc(): string = entryNow().color,
        proc(value: string): bool =
          # Enter in a channel / HSL field keeps the picker open; Apply and
          # the hex field close it. Read when the commit starts, because an
          # asynchronous source commit completes later.
          let closeOnSuccess = colorState.commitCloses
          colorState.pending.val = true
          var completed = false
          var accepted = false
          commitColor(value, proc(ok: bool) =
            completed = true
            accepted = ok
            if not rowActive or not currentTarget(): return
            colorState.pending.val = false
            if ok:
              if closeOnSuccess: colorState.open.val = false
              # Still open after a committed Enter: the committed colour is
              # the new point Cancel / Escape return to, also when the
              # source confirmed it asynchronously.
              else: colorState.markColorDraftCommitted()
            else: colorState.diagnostic.val = fillWiringNow().commitMessage.val)
          completed and accepted)
      createRenderEffect proc() =
        let current = entryNow()
        r.setInputValue(hexEl, current.color)
        r.setInputValue(alphaEl, $int(round(current.alpha * 100.0)))
      createRenderEffect proc() =
        let reason = fillWiringNow().readOnlyReason()
        r.setAttribute(row, "data-fill-row-readonly", if reason.len > 0: "true" else: "false")
        r.setAttribute(row, "data-fill-row-readonly-reason", reason)
        when defined(js):
          {.emit: [hexEl,".readOnly = ",reason,".length > 0;",alphaEl,".readOnly = ",reason,".length > 0;"].}
      pasteColor = proc(value: string) =
        let color = normalizedSourceColor(value)
        if color.len == 0:
          fillWiringNow().commitMessage.val = "Cannot paste " & value & " into Fill."
          return
        commitColor(color, proc(ok: bool) = discard)
      # Disclosure is inspection, including when the source cannot be edited.
      # The live commitColor guard refuses Apply and literal/alpha mutations;
      # mountColorPopover owns pointer/Enter/Space disclosure and cleanup.
      r.addEventListener(hexEl, "change", proc() =
        commitColor(r.inputValue(hexEl), proc(ok: bool) =
          if not ok and rowActive: r.setInputValue(hexEl, entryNow().color)))
      r.addEventListener(alphaEl, "change", proc() =
        if not rowActive or not currentTarget(): return
        try:
          let parsed = parseFloat(r.inputValue(alphaEl))
          if classify(parsed) in {fcNan, fcInf, fcNegInf} or parsed < 0 or parsed > 100:
            raise newException(ValueError, "Invalid alpha")
          var channels = colorChannels(entryNow().color)
          channels.alpha = int(round(parsed * 255 / 100))
          commitColor(channelsHex(channels), proc(ok: bool) =
            if not ok and rowActive: r.setInputValue(alphaEl, $int(round(entryNow().alpha*100))))
        except ValueError:
          fillWiringNow().commitMessage.val = "Fill opacity must be from 0 to 100%."
          r.setInputValue(alphaEl, $int(round(entryNow().alpha*100))))
    # Property actions (editor spec "Universal Patterns": "right-click
    # property -> Copy, then paste onto another element"). A fill entry has
    # no More slot, so right-click is its entry point.
    discard registerInspectorSearchText("fill " & fillProperty())
    proc removalAdmission(): string =
      ## Everything `removalReason` asks except the file read.
      if idx != 0: secondaryFillNotice
      elif binding.isSome:
        "Detach the variable before removing this fill."
      else: fillWiringNow().resetAdmission()
    proc removalReason(): string =
      let cheap = removalAdmission()
      if cheap.len > 0: cheap else: fillWiringNow().resetReason()
    proc removeFill() =
      # The empty commit is planned as removing the owning declaration.
      if rowActive and currentTarget() and idx == 0:
        fillWiringNow().commitAsync("", proc(ok: bool) = discard)
    let actionsConfig = PropertyActionsConfig(
      name: "Fill",
      clipboard: vm.inspector.propertyClipboard,
      copyValue: proc(): string = entryNow().color,
      copyProperty: fillProperty(),
      paste: proc(value: string) =
        if pasteColor != nil and rowActive and currentTarget(): pasteColor(value),
      unavailableReason: proc(): string =
        if idx != 0: secondaryFillNotice
        elif binding.isSome:
          "Detach the variable before pasting a value into this fill."
        else: fillWiringNow().readOnlyReason(),
      # Reset commits an empty fill through the fill's own commit, which
      # plans it as removing the declaration that sets it (as Delete does).
      resetReason: removalReason,
      reset: removeFill,
      detach: (if idx == 0 and binding.isSome:
                 vm.inspectorDetachRequestHandler(fillProperty())
               else: nil),
      isBound: proc(): bool = binding.isSome)
    let rowOwner = getOwner()
    var actionsMenu: PropertyActionsMenu[E]
    var actionsMounted = false
    proc openActions() =
      if not rowActive or not currentTarget(): return
      if not actionsMounted:
        actionsMounted = true
        runWithOwner(rowOwner, proc() =
          actionsMenu = mountPropertyActionsMenu[R, E](r, row, row, actionsConfig))
      if not actionsMenu.state.isOpen.val: actionsMenu.open()
    r.addEventListener(row, "contextmenu", proc(ev: auto) =
      mixin preventDefault
      # The hex and opacity fields keep the browser's own text menu.
      if isEditableEventTarget(ev): return
      when compiles(ev.preventDefault()):
        ev.preventDefault()
      elif defined(js):
        proc prevent(event: typeof(ev)) {.importjs: "#.preventDefault()".}
        prevent(ev)
      openActions())
    # Delete (−) of the fill removes the declaration that sets it: for a
    # single fill that is exactly what Reset does, so it commits the same
    # empty value through the same fill commit, and is enabled exactly where
    # Reset is (`removalReason`). Elsewhere it stays in place, disabled with
    # that reason, and a click explains it without changing anything.
    #
    # Tracked: only the answers that read no source file (permissions,
    # binding, secondary fill, native writer, schema admission). Whether the
    # write finds exactly one declaration reads the file -- a bridge request
    # in a consumer -- so it is asked untracked when the user reaches for the
    # button (hover, focus, click), as Reset asks it when its menu opens,
    # never on every selection, viewport or pending-edit change.
    proc showDeleteState(reason: string) =
      r.setAttribute(deleteEl, "aria-disabled",
        if reason.len > 0: "true" else: "false")
      r.setAttribute(deleteEl, "title",
        if reason.len > 0: reason else: "Delete fill")
    proc checkDelete(): string =
      result = untrack(removalReason)
      showDeleteState(result)
    createRenderEffect proc() =
      showDeleteState(if rowActive: removalAdmission() else: "")
    r.addEventListener(deleteEl, "pointerenter", proc() =
      if rowActive and currentTarget(): discard checkDelete())
    r.addEventListener(deleteEl, "focus", proc() =
      if rowActive and currentTarget(): discard checkDelete())
    r.addEventListener(deleteEl, "click", proc() =
      if not rowActive or not currentTarget(): return
      let reason = checkDelete()
      if reason.len > 0:
        fillWiringNow().commitMessage.val = reason
        return
      removeFill())
    installPopoverTrigger(deleteEl)

  proc rebuildList(count: int) =
    r.clearChildren(listEl)
    for i in 0 ..< count:
      mountRow(i)

  # Rows are rebuilt when the target, its binding or the NUMBER of fills
  # changes; a value change is rendered by the row itself (see `mountRow`).
  # A memo, so that an unrelated property update on the same element (which
  # re-runs anything reading the selection) does not rebuild the rows.
  let rowsKey = createMemo(proc(): tuple[target: string,
      binding: Option[VariableBinding], count: int] =
    (target: fillTargetIdentity.val,
     binding: vm.inspectorBindingFor(fillProperty()),
     count: entries.val.len))
  createRenderEffect proc() =
    let count = rowsKey.val.count
    untrack(proc() = rebuildList(count))
    r.setStyle(emptyEl, "display",
      if count == 0: "block" else: "none")

  var sectionActive = true
  onCleanup(proc() = sectionActive = false)
  let onAdd = proc() =
    if not sectionActive: return
    let reason = fillWiringNow().readOnlyReason()
    if reason.len > 0:
      fillWiringNow().commitMessage.val = reason
      return
    var next = entries.val
    next.add FillEntry(color: "#FFFFFF", alpha: 1.0)
    entries.val = next
  r.addEventListener(addBtnEl, "click", onAdd)
  installPopoverTrigger(addBtnEl)

  createRenderEffect proc() =
    let wiring = fillWiringNow()
    let refusal = wiring.commitMessage.val
    let reason = wiring.readOnlyReason()
    let text = if refusal.len > 0: refusal else: reason
    r.setTextContent(messageEl, text)
    r.setAttribute(messageEl, "data-fill-message-visible",
      if text.len > 0: "true" else: "false")
    r.setStyle(messageEl, "display", if text.len > 0: "block" else: "none")
