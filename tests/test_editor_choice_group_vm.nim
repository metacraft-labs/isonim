## TBAR-M2 — ViewModel + headless mount tests for the ChoiceGroup
## widget (``src/isonim/editor/views/widgets/choice_group.nim``).
##
## Two suites:
##   * segmented variant — constructing the VM, activating an index
##     through ``activate(i)``, the ``onChange`` callback firing on
##     real transitions only, out-of-range indices being no-ops, and
##     activating the already-active index being a no-op.
##   * chevron variant — same activation semantics + ``togglePopup``
##     flips ``popupOpen``, and activating an option while the popup
##     is open also closes it.
##
## The mount tests use the canonical ``createRoot`` / ``dispose``
## pattern over a ``MockRenderer``: build a root element, mount the
## widget, drive interactions via the VM (the canonical no-DOM-poking
## test path), and assert the resulting attribute / structure
## invariants.

import std/[sets, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/views/widgets/choice_group

# --------------------------------------------------------------------------- #
#  Helpers
# --------------------------------------------------------------------------- #

proc mkRoot(): tuple[r: MockRenderer; root: MockNode] =
  let r = MockRenderer()
  let root = r.createElement("div")
  (r, root)

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  ## Depth-first search for the first element with attribute ``attr``
  ## equal to ``value``. Returns ``nil`` when no match exists.
  if node == nil:
    return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil:
      return hit
  return nil

proc collectByAttr(node: MockNode; attr: string): seq[MockNode] =
  result = @[]
  if node == nil:
    return
  if node.kind == mnkElement and attr in node.attributes:
    result.add node
  for c in node.children:
    for hit in collectByAttr(c, attr):
      result.add hit

# --------------------------------------------------------------------------- #
#  Segmented variant
# --------------------------------------------------------------------------- #

suite "TBAR-M2 segmented choice VM":

  test "segmented_vm_constructs_with_initial_active_index":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["Preview", "Spec"], initialIndex = 0)
      check vm.variant == cgvSegmented
      check vm.labels == @["Preview", "Spec"]
      check vm.activeIndex.val == 0
      check vm.popupOpen.val == false
      dispose()

  test "segmented_vm_clamps_out_of_range_initial_index":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["A", "B", "C"], initialIndex = 99)
      check vm.activeIndex.val == 0
      let vm2 = createSegmentedChoiceVM(@["A", "B"], initialIndex = -3)
      check vm2.activeIndex.val == 0
      dispose()

  test "segmented_vm_activate_changes_index_and_fires_on_change":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createSegmentedChoiceVM(@["Preview", "Spec"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} =
        observed.add i)
      # Drive the change through the *DOM*, not the VM, so the test
      # also exercises the click handler bound to the pill element.
      let pillSpec = findByAttr(root, "data-choice-group-pill", "1")
      check pillSpec != nil
      fireEvent(pillSpec, "click")
      check vm.activeIndex.val == 1
      check observed == @[1]
      dispose()

  test "segmented_vm_activate_out_of_range_is_no_op":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createSegmentedChoiceVM(@["A", "B"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} =
        observed.add i)
      vm.activate(99)
      check vm.activeIndex.val == 0
      check observed.len == 0
      vm.activate(-1)
      check vm.activeIndex.val == 0
      check observed.len == 0
      dispose()

  test "segmented_vm_activating_same_index_does_not_refire_on_change":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createSegmentedChoiceVM(@["A", "B"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} =
        observed.add i)
      let pillA = findByAttr(root, "data-choice-group-pill", "0")
      check pillA != nil
      fireEvent(pillA, "click")
      check vm.activeIndex.val == 0
      check observed.len == 0
      dispose()

  test "segmented_view_aria_pressed_mirrors_active_index":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(
        @["View", "Comment", "Edit"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm,
        proc(i: int) {.closure.} = discard)
      let pills = collectByAttr(root, "data-choice-group-pill")
      check pills.len == 3
      check pills[0].attributes.getOrDefault("aria-pressed") == "true"
      check pills[1].attributes.getOrDefault("aria-pressed") == "false"
      check pills[2].attributes.getOrDefault("aria-pressed") == "false"
      vm.activate(2)
      check pills[0].attributes.getOrDefault("aria-pressed") == "false"
      check pills[1].attributes.getOrDefault("aria-pressed") == "false"
      check pills[2].attributes.getOrDefault("aria-pressed") == "true"
      dispose()

  test "segmented_view_parent_uses_role_group":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["Preview", "Spec"])
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} = discard)
      let group = findByAttr(root, "data-choice-group", "segmented")
      check group != nil
      check group.attributes.getOrDefault("role") == "group"
      dispose()

# --------------------------------------------------------------------------- #
#  Chevron variant
# --------------------------------------------------------------------------- #

suite "TBAR-M2 chevron choice VM":

  test "chevron_vm_constructs_with_initial_index_and_closed_popup":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(
        @["320x568", "768x1024", "1280x800"], initialIndex = 1)
      check vm.variant == cgvChevron
      check vm.labels.len == 3
      check vm.activeIndex.val == 1
      check vm.popupOpen.val == false
      dispose()

  test "chevron_vm_toggle_popup_flips_open_state":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["A", "B", "C"])
      check vm.popupOpen.val == false
      vm.togglePopup()
      check vm.popupOpen.val == true
      vm.togglePopup()
      check vm.popupOpen.val == false
      dispose()

  test "chevron_vm_close_popup_is_idempotent":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["A", "B"])
      vm.closePopup()
      check vm.popupOpen.val == false
      vm.togglePopup()
      check vm.popupOpen.val == true
      vm.closePopup()
      check vm.popupOpen.val == false
      vm.closePopup()
      check vm.popupOpen.val == false
      dispose()

  test "chevron_vm_activate_changes_index_and_fires_on_change":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createChevronChoiceVM(@["A", "B", "C"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm,
        proc(i: int) {.closure.} = observed.add i)
      let optionB = findByAttr(root, "data-choice-group-option", "1")
      check optionB != nil
      fireEvent(optionB, "click")
      check vm.activeIndex.val == 1
      check observed == @[1]
      dispose()

  test "chevron_vm_activating_option_while_popup_open_closes_popup":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createChevronChoiceVM(@["A", "B", "C"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm,
        proc(i: int) {.closure.} = observed.add i)
      vm.togglePopup()
      check vm.popupOpen.val == true
      let optionC = findByAttr(root, "data-choice-group-option", "2")
      check optionC != nil
      fireEvent(optionC, "click")
      check vm.activeIndex.val == 2
      check observed == @[2]
      check vm.popupOpen.val == false
      dispose()

  test "chevron_vm_activate_out_of_range_is_no_op":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createChevronChoiceVM(@["A", "B"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm,
        proc(i: int) {.closure.} = observed.add i)
      vm.activate(99)
      check vm.activeIndex.val == 0
      vm.activate(-1)
      check vm.activeIndex.val == 0
      check observed.len == 0
      dispose()

  test "chevron_vm_activating_same_index_does_not_refire_on_change":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createChevronChoiceVM(@["A", "B"], initialIndex = 1)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm,
        proc(i: int) {.closure.} = observed.add i)
      let optB = findByAttr(root, "data-choice-group-option", "1")
      check optB != nil
      fireEvent(optB, "click")
      check vm.activeIndex.val == 1
      check observed.len == 0
      dispose()

  test "chevron_view_trigger_uses_aria_haspopup_listbox":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["Tiny", "Medium", "Large"])
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm, proc(i: int) {.closure.} = discard)
      let trigger = findByAttr(root, "data-choice-group-trigger", "true")
      check trigger != nil
      check trigger.attributes.getOrDefault("aria-haspopup") == "listbox"
      check trigger.attributes.getOrDefault("aria-expanded") == "false"
      let popup = findByAttr(root, "data-choice-group-popup", "true")
      check popup != nil
      check popup.attributes.getOrDefault("role") == "listbox"
      let options = collectByAttr(root, "data-choice-group-option")
      check options.len == 3
      check options[0].attributes.getOrDefault("role") == "option"
      dispose()

  test "chevron_view_trigger_label_updates_after_activation":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["320", "768", "1280"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm, proc(i: int) {.closure.} = discard)
      let lbl = findByAttr(
        root, "data-choice-group-trigger-label", "true")
      check lbl != nil
      check textContent(lbl) == "320"
      vm.activate(2)
      check textContent(lbl) == "1280"
      dispose()

  test "chevron_view_popup_data_attribute_mirrors_open_state":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["A", "B"])
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm, proc(i: int) {.closure.} = discard)
      let popup = findByAttr(root, "data-choice-group-popup", "true")
      check popup != nil
      check popup.attributes.getOrDefault("data-popup-open") == "false"
      vm.togglePopup()
      check popup.attributes.getOrDefault("data-popup-open") == "true"
      let trigger = findByAttr(root, "data-choice-group-trigger", "true")
      check trigger != nil
      check trigger.attributes.getOrDefault("aria-expanded") == "true"
      dispose()

# --------------------------------------------------------------------------- #
#  CHRM-M2 — per-option disabled flag + transparent container variant.
# --------------------------------------------------------------------------- #

suite "CHRM-M2 ChoiceGroup extensions":

  test "segmented disabled option mirrors aria-disabled":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["A", "B", "C"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} = discard)
      # Disable index 1 reactively after mount; the render effect must
      # flip the pill's aria-disabled attribute.
      vm.setDisabledIndices(toHashSet([1]))
      let pillB = findByAttr(root, "data-choice-group-pill", "1")
      check pillB != nil
      check pillB.attributes.getOrDefault("aria-disabled") == "true"
      let pillA = findByAttr(root, "data-choice-group-pill", "0")
      check pillA.attributes.getOrDefault("aria-disabled") == "false"
      dispose()

  test "segmented disabled option click is a no-op":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createSegmentedChoiceVM(@["A", "B", "C"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} =
        observed.add i)
      vm.setDisabledIndices(toHashSet([1]))
      let pillB = findByAttr(root, "data-choice-group-pill", "1")
      check pillB != nil
      fireEvent(pillB, "click")
      # Disabled clicks do not flip the active index and do not fire
      # the onChange callback.
      check vm.activeIndex.val == 0
      check observed.len == 0
      # Re-enabling the index lets the next click through.
      vm.setDisabledIndices(initHashSet[int]())
      fireEvent(pillB, "click")
      check vm.activeIndex.val == 1
      check observed == @[1]
      dispose()

  test "vm.activate refuses to land on a disabled index":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["A", "B"], initialIndex = 0)
      vm.setDisabledIndices(toHashSet([1]))
      vm.activate(1)
      check vm.activeIndex.val == 0
      vm.setDisabledIndices(initHashSet[int]())
      vm.activate(1)
      check vm.activeIndex.val == 1
      dispose()

  test "segmented transparent variant exposes the data-choice-group-variant attr":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["A", "B"])
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} = discard,
                             variant = cgvTransparent)
      let group = findByAttr(root, "data-choice-group", "segmented")
      check group != nil
      check group.attributes.getOrDefault("data-choice-group-variant") ==
        "transparent"
      dispose()

  test "segmented filled variant is the default":
    createRoot do (dispose: proc()):
      let vm = createSegmentedChoiceVM(@["A", "B"])
      let (r, root) = mkRoot()
      r.mountSegmentedChoice(root, vm, proc(i: int) {.closure.} = discard)
      let group = findByAttr(root, "data-choice-group", "segmented")
      check group != nil
      check group.attributes.getOrDefault("data-choice-group-variant") ==
        "filled"
      dispose()

  test "chevron transparent variant exposes the data-choice-group-variant attr":
    createRoot do (dispose: proc()):
      let vm = createChevronChoiceVM(@["A", "B", "C"])
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm, proc(i: int) {.closure.} = discard,
                           variant = cgvTransparent)
      let group = findByAttr(root, "data-choice-group", "chevron")
      check group != nil
      check group.attributes.getOrDefault("data-choice-group-variant") ==
        "transparent"
      dispose()

  test "chevron disabled option click is a no-op":
    createRoot do (dispose: proc()):
      var observed: seq[int] = @[]
      let vm = createChevronChoiceVM(@["A", "B", "C"], initialIndex = 0)
      let (r, root) = mkRoot()
      r.mountChevronChoice(root, vm,
        proc(i: int) {.closure.} = observed.add i)
      vm.setDisabledIndices(toHashSet([2]))
      let optC = findByAttr(root, "data-choice-group-option", "2")
      check optC != nil
      check optC.attributes.getOrDefault("aria-disabled") == "true"
      fireEvent(optC, "click")
      check vm.activeIndex.val == 0
      check observed.len == 0
      dispose()
