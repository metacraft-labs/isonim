## NH-M2 — the native hot-component proxy, the signal registry, and the
## reload lifecycle driven by a stand-in Reprobuild agent.
##
## MOCK POLICY (workspace rule: every mock justified in the test file's
## header). Exactly ONE double is used — ``tests/helpers/hcr_stub.nim``,
## the HCR agent — and its justification is written out at length in that
## file: the shipped ``librepro_hcr_agent`` exports the ten ``rb_hcr_*``
## symbols with baseline bodies that never fire a callback, and live
## dispatch is Reprobuild milestone HLX-M8, which is ``planned``. Linking
## the real library would exercise IsoNim's reload lifecycle zero times.
##
## Everything else here is real and is the production object:
## ``isonim/native/hmr``'s registry, ``isonim/renderers/native``'s
## ``NativeRenderer`` / ``NativeWidget`` (the same backend
## ``tests/test_native_renderer.nim`` exercises), NH-M1's ``renderNative``
## seam, and the real reactive core. Nothing is stubbed, faked or
## intercepted between ``mountUiHot`` and the widget tree.
##
## NO SKIP ARMS. There is no prerequisite to probe for: the whole path is
## in-process Nim. A missing flag is a COMPILE error (below), not a
## skipped test.
##
## ## What each gate proves, and how it discriminates
##
## The claim NH-M2 makes is not "a proc named mountUiHot exists". It is
## four separable behaviours, each paired here with a control that must
## stay green when the behaviour is present and would have to go red if
## the control were itself accidentally reactive:
##
## - **Signal preservation.** The new body re-claims the same
##   ``SignalState`` instead of creating a fresh one. Asserted on the
##   Signal's REFERENCE, not only on its value — a fresh signal that
##   happened to hold the same number would pass a value-only check.
## - **Re-render on hash change.** Control: a reload in which no hash
##   changes must leave ``renders`` unmoved.
## - **Node identity when the hash matches.** Asserted on the NODE
##   REFERENCE and its renderer-assigned id, never on rendered text —
##   a rebuilt-but-identical-looking subtree is exactly the failure this
##   gate exists to catch, and text cannot see it.
## - **Failure preserves the tree.** Asserted on the observed tree (text
##   AND node identity AND generation counter), never on a returned
##   status.

when not defined(isonimHmr):
  {.error: "test_native_hmr must be compiled with -d:isonimHmr. " &
      "Without the flag isonim/native/hmr has no registry, no slots and " &
      "no agent callbacks, so every assertion below would be about the " &
      "build-once fallback and would pass while proving nothing. " &
      "Run: nim c -r -d:isonimHmr tests/test_native_hmr.nim".}

import std/[strutils, tables]
import unittest

import isonim/renderers/native
import isonim/native/hmr
import isonim/core/signals

import ./helpers/hcr_stub

# ---------------------------------------------------------------------------
# The fixture: a two-slot "app".
#
# Slot locations and body hashes are written as explicit literals rather
# than derived from `instantiationInfo` / `symBodyHash`. That is the
# HIGHER-fidelity choice, not a shortcut: a real Reprobuild patch replaces
# a function BODY in place, so the ui block keeps its file:line:col and
# gets a new `symBodyHash`. Two literal versions of a body registered at
# one fixed loc with two different hash strings is exactly that, whereas
# two Nim procs at two source lines would reproduce neither.
# ---------------------------------------------------------------------------

const
  slotA = "demo_app.nim:12:2"
  slotB = "demo_app.nim:31:2"
  counterId = "demo_app.nim:14:10"

var r: NativeRenderer

var versionA = 1
var versionB = 1
var entryRaises = false
var entryRuns = 0

var lastSignalA: Signal[int] = nil
var bodyARuns = 0
var bodyBRuns = 0

proc makeBodyA(version: int): UiSlotFactory =
  ## Version N of slot A's body. Declares component state through
  ## `hmrSignalImpl`, whose id is the (fixed) call site.
  uiSlotFactory(proc(): NativeWidget =
    inc bodyARuns
    let count = hmrSignalImpl[int](counterId, 0)
    lastSignalA = count
    let n = r.createElement("div")
    r.setAttribute(n, "class", "slot-a")
    r.appendChild(n, r.createTextNode("A" & $version & " count=" & $count.val))
    n)

proc makeBodyB(version: int): UiSlotFactory =
  uiSlotFactory(proc(): NativeWidget =
    inc bodyBRuns
    let n = r.createElement("div")
    r.setAttribute(n, "class", "slot-b")
    r.appendChild(n, r.createTextNode("B" & $version))
    n)

proc appEntry() =
  ## The ui-block registration pass. Re-run by `rb_hcr_before_reload`;
  ## after a real patch it would be the patched bodies registering their
  ## new hashes, which is what `versionA` / `versionB` stand for here.
  inc entryRuns
  hmrRegisterFactory(slotA, "hashA" & $versionA, makeBodyA(versionA))
  if entryRaises:
    # Raise AFTER one registration has been staged. A failure that raised
    # before staging anything would be indistinguishable from a reload
    # that did nothing, and this gate is specifically about a PARTIAL
    # registration pass not reaching the surface.
    raise newException(ValueError, "simulated broken ui block in slot B")
  hmrRegisterFactory(slotB, "hashB" & $versionB, makeBodyB(versionB))

var includeSlotB = true

proc appFactory(): NativeWidget =
  ## The mount factory. Every reactive read on this path is a slot memo
  ## read, which is what makes the mount seam's dependency set "the slots
  ## this mount reaches" and nothing else.
  let root = r.createElement("div")
  r.setAttribute(root, "class", "app")
  r.appendChild(root, hmrInvokeSlot[NativeWidget](slotA))
  if includeSlotB:
    r.appendChild(root, hmrInvokeSlot[NativeWidget](slotB))
  root

type Fixture = object
  stub: HcrStubAgent
  root: HmrRoot
  host: NativeWidget
  mount: HmrMount[NativeWidget]
  errors: seq[string]

proc newFixture(): Fixture =
  versionA = 1
  versionB = 1
  entryRaises = false
  entryRuns = 0
  includeSlotB = true
  bodyARuns = 0
  bodyBRuns = 0
  lastSignalA = nil
  r = NativeRenderer()
  result.errors = @[]
  let errs = addr result.errors
  result.stub = installHcrStub()
  result.root = newHmrRoot(appEntry, proc(loc: string; err: ref Exception) =
    errs[].add(loc & ": " & err.msg))
  result.root.start()
  result.host = r.createElement("host")
  result.mount = mountUiHot(r, result.host,
                            proc(): NativeWidget = appFactory())

proc teardown(f: var Fixture) =
  f.mount.dispose()
  f.root.stop()
  f.stub.uninstall()

proc slotNode(host: NativeWidget; cls: string): NativeWidget =
  ## The node the named slot currently contributes, found through the
  ## renderer's own tree rather than through a side-copy the test kept.
  for child in host.children:
    for grand in child.children:
      if grand.attributes.getOrDefault("class") == cls:
        return grand
  nil

proc queueSimple(stub: HcrStubAgent; files: seq[string] = @["demo_app.nim"]) =
  stub.queuePatch(HcrStubPatch(changedFiles: files, changedTypes: @[]))

suite "NH-M2: native hot-component proxy + signal registry":

  test "test_hmr_root_start_registers_managed_types_and_callbacks":
    # Deliverable: `rb_hcr_register_managed_type` called during
    # `HmrRoot.start()`, and the two reload callbacks installed.
    var f = newFixture()
    check f.stub.isManaged("isonim.SignalState")
    check f.stub.isManaged("isonim.SignalStorage")
    check f.stub.isManaged("isonim.UiSlot")
    check f.stub.isManaged("isonim.UiSlotFactory")
    check f.stub.beforeCallbackCount == 1
    check f.stub.afterCallbackCount == 1
    # `start` is idempotent and must not double-register: the real
    # agent de-duplicates on (callback, user_data), so a second start
    # that did register again would be invisible there and visible here.
    f.root.start()
    check f.stub.beforeCallbackCount == 1
    check f.stub.afterCallbackCount == 1
    teardown(f)
    check f.stub.beforeCallbackCount == 0
    check f.stub.afterCallbackCount == 0

  test "test_native_hot_signal_preserved_across_simulated_reload":
    # GATE 1. `hmrSignal` state survives a reload that replaces the body
    # that declared it.
    var f = newFixture()
    check textContent(f.host).contains("A1 count=0")
    check lastSignalA != nil
    let signalBefore = lastSignalA

    lastSignalA.val = 5
    check lastSignalA.val == 5
    # The body reads the signal UNTRACKED (the dynamic-accessor rule), so
    # a bare write does not repaint — the surface still shows the value
    # the last body run captured.
    check textContent(f.host).contains("count=0")
    check f.mount.handle.renders == 1

    versionA = 2
    f.stub.queueSimple()
    check rbHcrWantsReload()
    rbHcrApplyReload()

    check f.root.beforeReloads == 1
    check f.root.afterReloads == 1
    check f.root.appliedReloads == 1
    check f.root.failedReloads == 0
    # Value AND reference: a fresh Signal holding 5 would satisfy a
    # value-only check and would mean the registry did nothing.
    check lastSignalA.val == 5
    check lastSignalA == signalBefore
    check f.root.signalCount == 1
    # And it is visible: the new body rendered the preserved value.
    check textContent(f.host).contains("A2 count=5")
    teardown(f)

  test "test_native_ui_slot_re_renders_when_hash_changes":
    # GATE 2.
    var f = newFixture()
    check textContent(f.host).contains("A1")
    check textContent(f.host).contains("B1")
    let rendersBefore = f.mount.handle.renders
    let mountsBefore = uiHotMounts

    versionA = 2
    f.stub.queueSimple()
    rbHcrApplyReload()

    check textContent(f.host).contains("A2")
    check not textContent(f.host).contains("A1 ")
    check f.mount.handle.renders > rendersBefore
    # The reload reached the surface WITHOUT re-running the mount: the
    # reactive root was opened once and was never re-opened or disposed.
    check uiHotMounts == mountsBefore
    check not f.mount.isDisposed()
    check f.root.slotHash(slotA) == "hashA2"
    teardown(f)

  test "test_control_reload_with_unchanged_hashes_does_not_re_render":
    # DISCRIMINATION CONTROL for gate 2. The reload machinery runs end to
    # end — callbacks fire, the entry re-runs, factories are re-registered
    # — but no hash changes. If `renders` moved here, gate 2 would be
    # measuring "a reload happened", not "a hash change dispatched".
    var f = newFixture()
    let rendersBefore = f.mount.handle.renders
    let bodyARunsBefore = bodyARuns

    f.stub.queueSimple()
    rbHcrApplyReload()

    check f.root.beforeReloads == 1
    check f.root.afterReloads == 1
    check entryRuns == 2          # the entry really did re-run
    check f.mount.handle.renders == rendersBefore
    check bodyARuns == bodyARunsBefore
    check textContent(f.host).contains("A1")
    teardown(f)

  test "test_native_ui_slot_dom_untouched_when_hash_matches":
    # GATE 3 — the subtle one. Asserted on NODE IDENTITY, because a
    # rebuilt subtree renders identical text and a text assertion would
    # be green either way.
    var f = newFixture()
    let nodeABefore = slotNode(f.host, "slot-a")
    let nodeBBefore = slotNode(f.host, "slot-b")
    check nodeABefore != nil
    check nodeBBefore != nil
    let idABefore = nodeABefore.id
    let idBBefore = nodeBBefore.id
    let bodyBRunsBefore = bodyBRuns

    versionA = 2                  # only A changes
    f.stub.queueSimple()
    rbHcrApplyReload()

    let nodeAAfter = slotNode(f.host, "slot-a")
    let nodeBAfter = slotNode(f.host, "slot-b")
    check nodeAAfter != nil
    check nodeBAfter != nil

    # B's hash matched: the SAME object is still in the tree.
    check nodeBAfter == nodeBBefore
    check nodeBAfter.id == idBBefore
    check bodyBRuns == bodyBRunsBefore   # its body never re-ran
    # A's hash changed: a different object, so the check above is not
    # passing because nothing moved at all.
    check nodeAAfter != nodeABefore
    check nodeAAfter.id != idABefore
    teardown(f)

  test "test_native_reload_failure_preserves_tree":
    # GATE 4 — never blank the surface. Asserted on the observed tree,
    # not on a returned status.
    var f = newFixture()
    let nodeABefore = slotNode(f.host, "slot-a")
    let nodeBBefore = slotNode(f.host, "slot-b")
    let textBefore = textContent(f.host)
    let genBefore = f.root.currentGeneration
    let rendersBefore = f.mount.handle.renders
    let slotsBefore = f.root.slotCount

    versionA = 2          # the entry stages a real change …
    entryRaises = true    # … and then throws before finishing.
    f.stub.queueSimple()
    rbHcrApplyReload()

    # The callbacks did run — this is a failure INSIDE the reload, not a
    # reload that never happened.
    check f.root.beforeReloads == 1
    check f.root.afterReloads == 1
    check f.root.failedReloads == 1
    check f.root.appliedReloads == 0

    # The tree is untouched: same text, same node objects, same render
    # count, same slot population.
    check textContent(f.host) == textBefore
    check slotNode(f.host, "slot-a") == nodeABefore
    check slotNode(f.host, "slot-b") == nodeBBefore
    check f.mount.handle.renders == rendersBefore
    check f.root.slotCount == slotsBefore
    check f.root.slotHash(slotA) == "hashA1"   # the staged change was dropped
    # Generation rolled back (design doc, "Failure mode").
    check f.root.currentGeneration == genBefore
    # The error handler was invoked, with the raised message.
    check f.errors.len == 1
    check f.errors[0].contains("simulated broken ui block")

    # And the root is still usable: a subsequent good reload applies.
    entryRaises = false
    f.stub.queueSimple()
    rbHcrApplyReload()
    check f.root.appliedReloads == 1
    check textContent(f.host).contains("A2")
    teardown(f)

  test "test_incompatible_layout_change_is_rejected_and_fires_no_callback":
    # HCR-Overview § 7.4 through the stub, and HLX-M8's
    # "a rejected patch leaves the process untouched".
    var f = newFixture()
    let textBefore = textContent(f.host)
    versionA = 2

    f.stub.queuePatch(HcrStubPatch(
      changedFiles: @["demo_app.nim"],
      changedTypes: @[HcrStubTypeChange(typeName: "app.NotRegistered",
                                        oldSize: 16, newSize: 24)]))
    rbHcrApplyReload()

    check f.stub.lastOutcome.rejection == hsrIncompatibleChange
    check f.stub.lastOutcome.unmanagedTypes == @["app.NotRegistered"]
    # Neither callback fired, so IsoNim never even learned about it …
    check f.root.beforeReloads == 0
    check f.root.afterReloads == 0
    # … and the surface is exactly as it was.
    check textContent(f.host) == textBefore
    # A managed type in the same position is accepted, which is what
    # makes the rejection above about MANAGEDNESS and not about layout
    # changes being refused outright.
    f.stub.queuePatch(HcrStubPatch(
      changedFiles: @["demo_app.nim"],
      changedTypes: @[HcrStubTypeChange(typeName: "isonim.UiSlot",
                                        oldSize: 16, newSize: 24)]))
    rbHcrApplyReload()
    check f.stub.lastOutcome.applied
    check f.root.beforeReloads == 1
    check textContent(f.host).contains("A2")
    teardown(f)

  test "test_file_changed_answers_about_the_applied_reload_not_the_requested_one":
    # HLX-M8 deliverable 6. Conflating requested with applied tells a
    # program to migrate state it does not have.
    var f = newFixture()
    check not rbHcrFileChanged("views.nim")

    f.stub.queuePatch(HcrStubPatch(changedFiles: @["views.nim"],
                                   changedTypes: @[]))
    rbHcrApplyReload()
    check rbHcrFileChanged("views.nim")
    check not rbHcrFileChanged("other.nim")

    # Now request a patch that is refused during prepare. It must not
    # move the answer.
    f.stub.queuePatch(HcrStubPatch(changedFiles: @["other.nim"],
                                   changedTypes: @[],
                                   prepareFails: true,
                                   prepareDiagnostic: "island-unplaceable"))
    rbHcrApplyReload()
    check f.stub.lastOutcome.rejection == hsrPrepareFailed
    check not rbHcrFileChanged("other.nim")
    check rbHcrFileChanged("views.nim")
    teardown(f)

  test "test_reload_lifecycle_runs_in_the_specified_order":
    # § 13.1: before-reload callbacks → patch application → after-reload
    # callbacks, and § 13.3's "they execute in registration order".
    var f = newFixture()
    f.stub.queueSimple()
    rbHcrApplyReload()
    check f.stub.lifecycle == @["prepare", "latch", "before", "apply", "after"]
    teardown(f)

  test "test_deleted_ui_block_is_pruned_after_reload":
    # Deliverable: the after-reload callback prunes stale-generation
    # entries. A slot the entry stops registering is a ui block the
    # developer deleted.
    var f = newFixture()
    check f.root.slotCount == 2

    # The developer deleted slot B: its registration is gone from the
    # entry pass AND its call site is gone from the parent's body. Both
    # halves matter — a slot the parent still invokes is still live, and
    # pruning it out from under a live mount would be the wrong fix.
    f.root.entry = proc() =
      inc entryRuns
      hmrRegisterFactory(slotA, "hashA9", makeBodyA(9))
    includeSlotB = false
    f.stub.queueSimple()
    rbHcrApplyReload()

    check f.root.slotCount == 1
    check f.root.slotHash(slotB) == ""
    # The signal that lived in the surviving slot is still there.
    check f.root.signalCount == 1
    teardown(f)

  test "test_mount_survives_and_is_never_re_entered_across_many_reloads":
    # The operative form of "without re-running the mount", measured over
    # a sequence rather than a single event.
    var f = newFixture()
    let mountsAtStart = uiHotMounts
    let handleAtStart = f.mount.handle
    for v in 2 .. 6:
      versionA = v
      f.stub.queueSimple()
      rbHcrApplyReload()
      check textContent(f.host).contains("A" & $v)
    check uiHotMounts == mountsAtStart
    check f.mount.handle == handleAtStart
    check not f.mount.isDisposed()
    check f.root.appliedReloads == 5
    teardown(f)

  test "test_control_mount_without_slots_is_inert_under_reload":
    # DISCRIMINATION CONTROL for the whole file. A mount whose factory
    # reaches no slot must not move when a reload dispatches slot
    # factories — otherwise "the tree changed" would be evidence for
    # nothing in particular.
    var f = newFixture()
    let inertHost = r.createElement("inert-host")
    var inertBuilds = 0
    let inertMount = mountUiHot(r, inertHost, proc(): NativeWidget =
      inc inertBuilds
      let n = r.createElement("div")
      r.appendChild(n, r.createTextNode("static"))
      n)
    check inertBuilds == 1

    versionA = 2
    f.stub.queueSimple()
    rbHcrApplyReload()

    check inertBuilds == 1
    check textContent(inertHost) == "static"
    check inertMount.handle.renders == 1
    # …while the slot-bearing mount in the same process did move.
    check textContent(f.host).contains("A2")
    inertMount.dispose()
    teardown(f)

  test "test_hmr_signal_outside_a_root_degrades_to_a_plain_signal":
    # Loud-by-construction prerequisite: a component written for HMR must
    # still work when mounted outside an `HmrRoot`, and must NOT silently
    # share state through a stale global registry.
    activeUiRegistry = nil
    let s1 = hmrSignalImpl[int]("free:1", 7)
    let s2 = hmrSignalImpl[int]("free:1", 9)
    check s1.val == 7
    check s2.val == 9
    check s1 != s2

  test "test_missing_slot_registration_raises_rather_than_rendering_nothing":
    # A slot invoked but never registered is a programming error, and it
    # must be loud. Returning an empty node here would make every later
    # assertion in a consumer's suite vacuously true.
    var f = newFixture()
    expect Defect:
      discard hmrInvokeSlot[NativeWidget]("demo_app.nim:999:0")
    teardown(f)
