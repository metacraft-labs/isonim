## tests/helpers/hcr_stub.nim — a Reprobuild HCR agent test double.
##
## ## MOCK POLICY (workspace rule: every mock justified in the header)
##
## This file IS a mock, deliberately, and it is the only one in the NH-M2
## test set. The justification is that the thing it stands in for does not
## exist yet on any platform:
##
## - Reprobuild's shipped ``librepro_hcr_agent`` exports the ten
##   ``rb_hcr_*`` functions with **baseline** bodies
##   (``reprobuild/libs/repro_hcr_agent/c/repro_hcr_agent.c``, section
##   "Application Runtime ABI: rb_hcr_*"). ``rb_hcr_wants_reload`` returns
##   a constant ``false``, ``rb_hcr_apply_reload`` is a commented no-op,
##   and ``rb_hcr_file_changed`` / ``rb_hcr_type_changed`` return constant
##   ``false``. Nothing fires a callback.
## - Dynamic patch delivery, live callback dispatch and managed-type
##   layout checking are Reprobuild milestone ``HLX-M8``, which is
##   ``planned``.
##
## So linking the real library would exercise IsoNim's reload lifecycle
## exactly zero times. The alternative to this double is no test at all.
##
## Everything else on the path under test is real: the real reactive core,
## the real registry in ``isonim/native/hmr.nim``, the real renderer, the
## real ``{.cdecl.}`` callbacks, and real C-shaped ``RbHcrReloadInfo`` /
## ``RbHcrTypeChange`` structures built from the declarations in
## ``isonim/native/hcr.nim``.
##
## ## This file is a CROSS-REPO CONTRACT
##
## Reprobuild's ``HLX-M8`` (``reprobuild-specs/HCR-Linux-ELF-Provider.
## milestones.org``) carries the deliverable "Conform to the shape of
## IsoNim's stub agent ``tests/helpers/hcr_stub.nim``". So the shape here
## is not "whatever these four tests needed" — every behaviour below is
## derived from one of:
##
## 1. **The declarations IsoNim binds** —
##    ``isonim/src/isonim/native/hcr.nim``. Ten functions, exact
##    signatures, unchanged.
## 2. **The specified API** — ``reprobuild-specs/HCR/HCR-Overview.md``
##    § 13 (lifecycle, registration, callbacks, introspection) and § 7.4
##    (the layout-change acceptance rule).
## 3. **The shipped baseline implementation** — ``repro_hcr_agent.c``, for
##    the details § 13 leaves to the implementation: de-duplication,
##    ordering, matching rules and capacities.
## 4. **``HLX-M8``'s own deliverable list**, for the two behaviours it
##    pins that § 13 does not: before-reload fires only after prepare has
##    fully succeeded, and ``rb_hcr_file_changed`` answers about the most
##    recent APPLIED reload rather than the most recent requested one.
## 5. **``reprobuild-specs/HCR/Patch-Loading-Lifecycle.md`` § 3.1 / § 3.3**
##    — the normative phase ORDER, which HCR-Overview's document index
##    designates "Normative specification for the exact ordering of
##    operations". Added 2026-09-17; see the next section.
##
## ## THE PHASE ORDER THIS STUB SIMULATES — corrected 2026-09-17
##
## The stub's first version fired before-reload callbacks with the new
## code notionally already live, following IsoNim's design doc. That was
## **wrong**, and it is the defect that made all four NH-M2 gates green
## against a shape a conforming agent will never present. The normative
## order is:
##
## | Phase | Steps | What happens |
## |---|---|---|
## | E | 12-15 | ``before_reload`` callbacks fire. **Old code is still the only code in the process.** |
## | F | 16-20 | The patch library is loaded (``dlopen``) and symbols resolved. |
## | G | 21-27 | Threads suspended, **trampolines installed** — this is where new code becomes live — threads resumed. |
## | H | 28-29 | ``after_reload`` callbacks fire. New code is live. |
##
## So this stub OWNS the code swap. ``HcrStubPatch.applyCodeSwap`` is the
## test's stand-in for Phase G, and the stub calls it BETWEEN the two
## callback sets. A test must not mutate its own "source" before calling
## ``applyReload`` — doing so re-creates the inverted order the stub used
## to model, and the gate
## ``test_dispatch_observes_post_swap_code_not_pre_swap_code`` exists to
## make that failure loud.
##
## ``HcrStubPatch.loadFails`` models § 3.3 **step 38**: ``dlopen`` fails
## in Phase F, *after* before-reload has already fired. The agent **must
## still** invoke after-reload callbacks — with an ``RbHcrReloadInfo``
## carrying **zero** ``changed_types`` — so the application can restore
## what it saved. No code swap happens on that path and nothing is marked
## applied. This is distinct from ``prepareFails``, which is refused
## before any callback fires.
##
## Note, because it constrains what an application may do with the § 38
## signal: zero ``changed_types`` is ALSO what an ordinary patch with no
## layout change carries, so an application **cannot** use it to detect
## the failure. § 38 gives the agent an obligation, not the application a
## discriminator. Recorded as ``OPEN-5``.
##
## Where none of the four pins a behaviour, the gap is marked ``OPEN:``
## in place rather than filled with a plausible guess. A stub that encodes
## a guess as a contract is worse than one that documents the gap.
##
## ### Pinned by the real ABI
##
## | Behaviour | Source |
## |---|---|
## | Ten function names and signatures | hcr.nim (IsoNim binds them) |
## | ``RbHcrReloadInfo`` / ``RbHcrTypeChange`` field layout | § 13.3 + the C header |
## | Callbacks run in **registration order** | § 13.3, both registration doc comments |
## | Registration is **idempotent on (callback, user_data)** | ``repro_hcr_agent.c``: both register procs scan and return early on a match |
## | Removal matches on **(callback, user_data)** | § 13.3 "Matches by function pointer and user_data" + the C loops |
## | Managed-type registration de-duplicates by name | ``repro_hcr_agent.c::rb_hcr_register_managed_type`` |
## | The agent stores the ``const char*`` **pointer**, not a copy | same proc — no ``strdup`` anywhere |
## | Capacities: 64 callbacks, 128 managed types, silent drop past them | ``RB_HCR_MAX_CALLBACKS`` / ``RB_HCR_MAX_MANAGED_TYPES`` |
## | Accept iff **every** layout-changed type is managed; otherwise reject ``IncompatibleChange`` **listing the unmanaged ones** | § 7.4 + § 13.7's error row |
## | A rejected patch fires **neither** callback and leaves the process untouched | HLX-M8 deliverable 3 + its ``integration_hcr_linux_rejected_patch_never_fires_before_reload`` |
## | ``rb_hcr_file_changed`` is about the most recent **applied** reload | HLX-M8 deliverable 6 |
## | ``rb_hcr_wants_reload`` is non-blocking and false when nothing is pending | § 13.1 |
##
## ### OPEN — not pinned anywhere, and therefore not asserted as contract
##
## - **When the "most recent applied reload" window opens.** § 13.6's own
##   usage example calls ``rb_hcr_type_changed`` *inside* a before-reload
##   callback to decide whether to serialize, so the answer set must
##   already describe the incoming patch by then; HLX-M8 says it must
##   describe the *applied* one. This stub latches the window the moment
##   prepare succeeds — i.e. after the point where a patch can still be
##   refused and before the first before-callback runs — because that is
##   the only latch point at which both statements are simultaneously
##   true. No spec text states it. See ``OPEN-1`` below.
## - **Managed-type name matching is exact.** § 13.2 says "the canonical
##   type name as it appears in debug info" and the shipped registry is a
##   ``strcmp`` whitelist, so there is no glob. IsoNim's design doc asks
##   for ``isonim.SignalState[*]``; whether the agent will ever grow
##   pattern matching is undecided. This stub matches exactly. ``OPEN-2``.
## - **What the agent does if a before-reload callback faults.** C
##   callbacks cannot throw, and the spec says nothing. This stub calls
##   them straight, so a Nim exception escaping a ``{.cdecl.}`` callback
##   would unwind into the stub's own frame — which is *more* forgiving
##   than a real C agent would be. IsoNim's callbacks therefore catch
##   everything themselves and must keep doing so. ``OPEN-3``.
## - ``OPEN-4`` — **RESOLVED 2026-09-17, and it was not open.** It used
##   to read: "the design doc's sequence installs trampolines *before*
##   firing before_reload … this stub fires before-callbacks with the new
##   code notionally live, matching the design doc, because that is what
##   IsoNim's entry call depends on." That was a guess encoded as a
##   contract, which this file's own header says is worse than a gap.
##   ``Patch-Loading-Lifecycle.md`` § 3.1 states the order normatively and
##   the design doc was the side that disagreed; § 3.2 confirms Direct
##   Patch Injection keeps the same phase structure, and HCR-Overview
##   § 7.4's Save/Patch/Restore list agrees. The stub now models the
##   normative order and IsoNim moved its entry call to after-reload. See
##   the phase table above.
## - ``OPEN-5`` — **what an application can conclude from § 3.3 step 38.**
##   The step obliges the agent to fire after-reload with zero
##   ``changed_types`` when the load fails. But zero ``changed_types`` is
##   indistinguishable from an ordinary no-layout-change patch, and no
##   spec text gives the application any other channel — ``RbHcrReloadInfo``
##   has no status field and ``rb_hcr_file_changed`` is defined over the
##   APPLIED reload, so on this stub's latch semantics it answers "no" for
##   a failed load, which is correct but is also what it answers for a file
##   that was simply not in the patch. An application therefore cannot
##   detect the case and must be correct without detecting it. IsoNim is;
##   whether a conforming agent should offer a discriminator is undecided.
##
## ### Constraints the real Linux agent carries that this stub cannot express
##
## Recorded so a conforming implementation is not surprised by them:
##
## - CIE augmentations carrying a **personality routine or LSDA are
##   refused by name** (Reprobuild HLX-M5). A patched body that does C++
##   exception handling is out of scope, which also means a Nim body
##   compiled to use C++ EH is.
## - Patch objects must be built ``-gz=none``.
## - Clang with ``-fcf-protection`` produces no admissible publication
##   window at all (HLX-OQ-6), so that toolchain combination gets no HCR.
##
## ## Usage
##
##     let stub = installHcrStub()
##     defer: stub.uninstall()
##     let root = newHmrRoot(entry)
##     root.start()                      # registers with `stub`
##     stub.queuePatch(HcrStubPatch(
##       changedFiles: @["views.nim"],
##       # Phase G. NOT done by the test before applyReload — the agent
##       # owns when new code becomes live, and it is after Phase E.
##       applyCodeSwap: proc() = sourceVersion = 2))
##     doAssert rbHcrWantsReload()
##     let outcome = stub.applyReload()  # or: rbHcrApplyReload()

when defined(js):
  {.error: "hcr_stub is a native-only (nim c) test helper".}

when not defined(isonimHmr):
  {.error: "tests/helpers/hcr_stub requires -d:isonimHmr: the agent seam " &
      "it installs into (isonim/native/hcr.nim's HcrAgentHooks) only " &
      "exists under that flag, so without it the stub would register " &
      "callbacks nothing could ever fire and every test would pass " &
      "vacuously.".}

when defined(reprobuildHcr):
  {.error: "tests/helpers/hcr_stub cannot be built with -d:reprobuildHcr. " &
      "Under that flag isonim/native/hcr.nim declares RbHcrReloadInfo as " &
      "`importc: \"const RbHcrReloadInfo\"`, i.e. the const qualifier is " &
      "part of the Nim TYPE, so the double cannot construct one to hand " &
      "to a callback. Build the stub's suites with -d:isonimHmr alone; " &
      "driving the real agent is NH-M4's job, not this file's.".}

import std/[strutils, tables]
import isonim/native/hcr

const
  hcrStubMaxCallbacks* = 64
    ## ``RB_HCR_MAX_CALLBACKS`` in ``repro_hcr_agent.c``. Registrations
    ## past the ceiling are silently dropped there, so they are here too.
  hcrStubMaxManagedTypes* = 128
    ## ``RB_HCR_MAX_MANAGED_TYPES``, same treatment.

type
  HcrStubTypeChange* = object
    ## One entry of ``RbHcrReloadInfo.changed_types`` — a type whose
    ## layout changed in this patch. HCR-Overview § 13.3.
    typeName*: string
    oldSize*: uint32
    newSize*: uint32

  HcrStubPatch* = object
    ## A patch as the coordinator would describe it to the agent.
    changedFiles*: seq[string]
    changedTypes*: seq[HcrStubTypeChange]
      ## Layout-changed types. § 7.4's acceptance rule is evaluated over
      ## exactly this set.
    prepareFails*: bool
      ## Simulate a provider-side refusal that happens during prepare —
      ## an unplaceable island, a sled with no admissible window, a
      ## hardened host. The observable is the same as a rejection: no
      ## callback fires and nothing is marked applied.
    prepareDiagnostic*: string
      ## The named refusal the provider would report. Reprobuild's
      ## Linux provider names five (``sled-window-not-instruction-
      ## boundary``, ``island-unplaceable``, …); the stub does not
      ## enumerate them, it just carries whichever the caller supplies.
    applyCodeSwap*: proc() {.closure.}
      ## **Phase G.** The test's stand-in for trampoline installation:
      ## whatever makes the "new bodies" reachable. The stub calls it
      ## between the before-reload and after-reload callback sets, which
      ## is the entire point — it is the only place in the lifecycle
      ## where new code becomes live, and a test that instead mutates its
      ## own source before ``applyReload`` is modelling an order no
      ## conforming agent implements. Optional: a patch that changes no
      ## body (a data-only or no-op patch) leaves it nil.
    loadFails*: bool
      ## **§ 3.3 step 38.** ``dlopen`` / ``LoadLibrary`` fails in Phase F,
      ## AFTER before-reload has fired. No code swap happens, nothing is
      ## marked applied — but after-reload callbacks **must still** run,
      ## with zero ``changed_types``, so the application can restore.
    loadDiagnostic*: string
      ## The load error the agent would report, e.g. an ``undefined
      ## symbol`` from ``dlerror()``.

  HcrStubRejection* = enum
    hsrNone
    hsrNoPatchPending      ## apply_reload with nothing queued — a no-op
    hsrPrepareFailed       ## provider refused during prepare
    hsrIncompatibleChange  ## § 7.4: a layout-changed type is unmanaged
    hsrLoadFailed          ## § 3.3 step 38: Phase F failed after Phase E fired

  HcrStubOutcome* = object
    ## What one ``applyReload`` did. Returned for convenience; the tests
    ## that matter assert on the observed tree, not on this.
    applied*: bool
    rejection*: HcrStubRejection
    unmanagedTypes*: seq[string]
      ## Populated for ``hsrIncompatibleChange``. § 7.4: the error
      ## "lists the unmanaged types".
    diagnostic*: string
    beforeCallbacksFired*: int
    afterCallbacksFired*: int
    codeSwapped*: bool
      ## Whether Phase G ran. False for every rejection AND for the
      ## § 3.3 step 38 late-load failure, which is the case in which
      ## after-reload callbacks fire over UNPATCHED code.

  HcrStubCallback = object
    callback: RbHcrReloadCallback
    userData: pointer

  HcrStubAgent* = ref object
    ## The double. One per test; installing a second one replaces the
    ## first, which is what a second agent in one process would do.
    beforeCallbacks: seq[HcrStubCallback]
    afterCallbacks: seq[HcrStubCallback]
    managed: seq[string]
    pending: seq[HcrStubPatch]
    appliedFiles: Table[string, bool]
    appliedTypes: Table[string, bool]
    installed: bool

    # ---- observation, for the gates ----
    lifecycle*: seq[string]
      ## Ordered trace, one entry per normative phase the stub reaches:
      ## "prepare" (C/D), "latch", "before" (E), "load" (F),
      ## "trampolines" (G), "after" (H), plus "reject:<reason>" and
      ## "load-failed". Lets a test assert the ORDER rather than just the
      ## counts — and the order is now the thing most worth asserting,
      ## since "before" landing on the wrong side of "trampolines" is the
      ## defect that made this file's first version wrong.
    applyCalls*: int
    beforeFired*: int
    afterFired*: int
    rejections*: int
    lastOutcome*: HcrStubOutcome
    droppedCallbacks*: int
    droppedManagedTypes*: int

# ---------------------------------------------------------------------------
# Registry operations — each one mirrors its C counterpart exactly.
# ---------------------------------------------------------------------------

proc indexOfCallback(list: seq[HcrStubCallback];
                     callback: RbHcrReloadCallback;
                     userData: pointer): int =
  ## The C loops match on BOTH fields. Matching on the function pointer
  ## alone would make two registrations of one callback with different
  ## user_data collide — which is exactly the shape IsoNim uses when a
  ## process runs two ``HmrRoot``s.
  for i, entry in list:
    if entry.callback == callback and entry.userData == userData:
      return i
  -1

proc stubRegisterManagedType(agent: HcrStubAgent; typeName: cstring) =
  if typeName == nil: return
  let name = $typeName
  for existing in agent.managed:
    if existing == name: return
  if agent.managed.len >= hcrStubMaxManagedTypes:
    inc agent.droppedManagedTypes
    return
  agent.managed.add(name)

proc stubUnregisterManagedType(agent: HcrStubAgent; typeName: cstring) =
  if typeName == nil: return
  let name = $typeName
  for i, existing in agent.managed:
    if existing == name:
      agent.managed.delete(i)
      return

proc stubBeforeReload(agent: HcrStubAgent; callback: RbHcrReloadCallback;
                      userData: pointer) =
  if callback == nil: return
  if indexOfCallback(agent.beforeCallbacks, callback, userData) >= 0: return
  if agent.beforeCallbacks.len >= hcrStubMaxCallbacks:
    inc agent.droppedCallbacks
    return
  agent.beforeCallbacks.add(HcrStubCallback(callback: callback,
                                            userData: userData))

proc stubAfterReload(agent: HcrStubAgent; callback: RbHcrReloadCallback;
                     userData: pointer) =
  if callback == nil: return
  if indexOfCallback(agent.afterCallbacks, callback, userData) >= 0: return
  if agent.afterCallbacks.len >= hcrStubMaxCallbacks:
    inc agent.droppedCallbacks
    return
  agent.afterCallbacks.add(HcrStubCallback(callback: callback,
                                           userData: userData))

proc stubRemoveBeforeReload(agent: HcrStubAgent;
                            callback: RbHcrReloadCallback;
                            userData: pointer) =
  if callback == nil: return
  let idx = indexOfCallback(agent.beforeCallbacks, callback, userData)
  if idx >= 0: agent.beforeCallbacks.delete(idx)

proc stubRemoveAfterReload(agent: HcrStubAgent;
                           callback: RbHcrReloadCallback;
                           userData: pointer) =
  if callback == nil: return
  let idx = indexOfCallback(agent.afterCallbacks, callback, userData)
  if idx >= 0: agent.afterCallbacks.delete(idx)

# ---------------------------------------------------------------------------
# Introspection
# ---------------------------------------------------------------------------

proc fileChanged*(agent: HcrStubAgent; filePath: string): bool =
  ## HLX-M8 deliverable 6: true iff the most recent **applied** reload
  ## listed this file. A queued-but-refused patch must not make this
  ## answer true — conflating requested with applied tells a program to
  ## migrate state it does not have.
  agent.appliedFiles.hasKey(filePath)

proc typeChanged*(agent: HcrStubAgent; typeName: string): bool =
  agent.appliedTypes.hasKey(typeName)

proc wantsReload*(agent: HcrStubAgent): bool =
  ## § 13.1: non-blocking, false when no patch is pending.
  agent.pending.len > 0

proc isManaged*(agent: HcrStubAgent; typeName: string): bool =
  for existing in agent.managed:
    if existing == typeName: return true
  false

proc managedTypes*(agent: HcrStubAgent): seq[string] = agent.managed
proc beforeCallbackCount*(agent: HcrStubAgent): int = agent.beforeCallbacks.len
proc afterCallbackCount*(agent: HcrStubAgent): int = agent.afterCallbacks.len
proc pendingCount*(agent: HcrStubAgent): int = agent.pending.len

# ---------------------------------------------------------------------------
# The lifecycle
# ---------------------------------------------------------------------------

proc queuePatch*(agent: HcrStubAgent; patch: HcrStubPatch) =
  ## Make a patch pending. ``rb_hcr_wants_reload`` answers true from here
  ## until it is applied or refused.
  agent.pending.add(patch)

proc fireCallbacks(agent: HcrStubAgent; list: seq[HcrStubCallback];
                   changedFiles: seq[string];
                   changedTypes: seq[HcrStubTypeChange];
                   codeSwapped: bool): int =
  ## Build a real C-shaped ``RbHcrReloadInfo`` and run every registered
  ## callback in registration order.
  ##
  ## The storage below is stack-local ON PURPOSE: HCR-Overview § 13.3
  ## says the agent owns it and the application must not retain pointers
  ## past the callback's return. A double that handed out heap storage
  ## with a longer lifetime would let a retain bug pass here and fail
  ## against the real agent.
  # Indexed, not `for f in …`: a loop variable over a seq[string] is a
  # COPY whose payload dies at the end of the iteration, so
  # `cstring(f)` would hand the callback a dangling pointer. Indexing
  # points at the parameter's own storage, which outlives the dispatch.
  var files: seq[cstring] = @[]
  for i in 0 ..< changedFiles.len:
    files.add(cstring(changedFiles[i]))
  var types: seq[RbHcrTypeChange] = @[]
  for i in 0 ..< changedTypes.len:
    types.add(RbHcrTypeChange(
      typeName: cstring(changedTypes[i].typeName),
      oldSize: changedTypes[i].oldSize,
      newSize: changedTypes[i].newSize))

  var info = RbHcrReloadInfo(
    changedFiles:
      (if files.len == 0: nil
       else: cast[ptr UncheckedArray[cstring]](addr files[0])),
    changedFilesCount: uint32(files.len),
    changedTypes:
      (if types.len == 0: nil
       else: cast[ptr UncheckedArray[RbHcrTypeChange]](addr types[0])),
    changedTypesCount: uint32(types.len),
    # OPEN-5, decided in Reprobuild 2026-09-20 and mirrored here because this
    # stub is the contract the real agent must present. The caller passes what
    # is TRUE AT THIS DISPATCH, not what the patch will eventually do: false in
    # Phase E, false on the step-38 after-dispatch, true on the Phase H
    # after-dispatch of a reload that committed. A stub that hardcoded it would
    # make the one case the field exists for — telling a late load failure apart
    # from a no-layout-change patch — untestable against the double.
    codeSwapped: (if codeSwapped: cint(1) else: cint(0)))

  # Iterate over a copy: a callback may register or remove callbacks,
  # and the C agent's array would not be re-read mid-dispatch either.
  let snapshot = list
  for entry in snapshot:
    if entry.callback != nil:
      entry.callback(addr info, entry.userData)
      inc result

proc applyReload*(agent: HcrStubAgent): HcrStubOutcome =
  ## ``rb_hcr_apply_reload`` (§ 13.1): blocks until the full lifecycle
  ## completes. The phases, in the order ``Patch-Loading-Lifecycle.md``
  ## § 3.1 requires: prepare (C/D) → **Phase E** before-reload callbacks
  ## → **Phase F** library load → **Phase G** trampoline installation,
  ## i.e. the code swap → **Phase H** after-reload callbacks.
  inc agent.applyCalls
  result = HcrStubOutcome(applied: false, rejection: hsrNone,
                          unmanagedTypes: @[], diagnostic: "",
                          codeSwapped: false)

  if agent.pending.len == 0:
    result.rejection = hsrNoPatchPending
    agent.lifecycle.add("reject:no-patch-pending")
    agent.lastOutcome = result
    return

  let patch = agent.pending[0]
  agent.pending.delete(0)
  agent.lifecycle.add("prepare")

  # ---- prepare: provider-side refusal -----------------------------------
  if patch.prepareFails:
    result.rejection = hsrPrepareFailed
    result.diagnostic =
      if patch.prepareDiagnostic.len > 0: patch.prepareDiagnostic
      else: "prepare-failed"
    inc agent.rejections
    agent.lifecycle.add("reject:" & result.diagnostic)
    agent.lastOutcome = result
    return

  # ---- prepare: § 7.4 layout-change acceptance rule ----------------------
  # "If all layout-changed types in a patch are managed, the patch is
  #  accepted; if any are unmanaged, the patch is rejected with
  #  IncompatibleChange listing the unmanaged types."
  var unmanaged: seq[string] = @[]
  for t in patch.changedTypes:
    if not agent.isManaged(t.typeName):
      unmanaged.add(t.typeName)
  if unmanaged.len > 0:
    result.rejection = hsrIncompatibleChange
    result.unmanagedTypes = unmanaged
    result.diagnostic = "IncompatibleChange: unmanaged layout-changed " &
      "types: " & unmanaged.join(", ")
    inc agent.rejections
    agent.lifecycle.add("reject:IncompatibleChange")
    agent.lastOutcome = result
    # HLX-M8 deliverable 3: nothing fired, nothing marked applied, the
    # process is untouched.
    return

  # ---- OPEN-1: latch the introspection window ---------------------------
  # Prepare has fully succeeded, so this patch WILL be applied and
  # before-reload callbacks may legitimately ask what changed (§ 13.6's
  # own example does exactly that; Patch-Loading-Lifecycle step 10
  # sequences the `changed_types` list as prepared in Phase C, before
  # Phase E, which is this point). A patch refused above never reaches
  # here, so "requested" and "applied" stay distinct.
  #
  # The latch is SAVED first, because Phase F can still fail below and
  # `rb_hcr_file_changed` is defined over the most recent APPLIED reload
  # (HLX-M8 deliverable 6). A patch that dies at `dlopen` was not applied,
  # so it must not move the answer — and by then the before-callbacks have
  # already run and may already have consulted it.
  let savedFiles = agent.appliedFiles
  let savedTypes = agent.appliedTypes
  agent.appliedFiles.clear()
  agent.appliedTypes.clear()
  for f in patch.changedFiles: agent.appliedFiles[f] = true
  for t in patch.changedTypes: agent.appliedTypes[t.typeName] = true
  agent.lifecycle.add("latch")

  # ---- Phase E (steps 12-15): before-reload callbacks --------------------
  # OLD code is still the only code in the process. Nothing has been
  # loaded and no trampoline exists.
  agent.lifecycle.add("before")
  result.beforeCallbacksFired = agent.fireCallbacks(
    agent.beforeCallbacks, patch.changedFiles, patch.changedTypes,
    codeSwapped = false)
  agent.beforeFired += result.beforeCallbacksFired

  # ---- Phase F (steps 16-20): load the patch library ---------------------
  agent.lifecycle.add("load")
  if patch.loadFails:
    # § 3.3 step 38. Before-reload has ALREADY fired, so the agent must
    # still invoke after-reload callbacks — with ZERO changed_types — so
    # the application can restore what it saved. No code swap happens and
    # nothing is marked applied.
    result.rejection = hsrLoadFailed
    result.diagnostic =
      if patch.loadDiagnostic.len > 0: patch.loadDiagnostic
      else: "dlopen-failed"
    inc agent.rejections
    agent.lifecycle.add("load-failed")
    # Un-latch: this reload was not applied.
    agent.appliedFiles = savedFiles
    agent.appliedTypes = savedTypes
    agent.lifecycle.add("after")
    result.afterCallbacksFired = agent.fireCallbacks(
      agent.afterCallbacks, patch.changedFiles, @[],
      codeSwapped = false)
    agent.afterFired += result.afterCallbacksFired
    agent.lastOutcome = result
    return

  # ---- Phase G (steps 21-27): trampolines. NEW CODE BECOMES LIVE HERE ----
  # Everything above ran against the old bodies; everything below runs
  # against the new ones. In a real agent this is the thread-suspended
  # prologue overwrite; here it is whatever the test says "the patched
  # source" means.
  if patch.applyCodeSwap != nil:
    patch.applyCodeSwap()
    result.codeSwapped = true
  agent.lifecycle.add("trampolines")

  # ---- Phase H (steps 28-29): after-reload callbacks ---------------------
  agent.lifecycle.add("after")
  result.afterCallbacksFired = agent.fireCallbacks(
    agent.afterCallbacks, patch.changedFiles, patch.changedTypes,
    codeSwapped = result.codeSwapped)
  agent.afterFired += result.afterCallbacksFired

  result.applied = true
  agent.lastOutcome = result

# ---------------------------------------------------------------------------
# Installation into the agent seam
# ---------------------------------------------------------------------------

proc uninstall*(agent: HcrStubAgent) =
  ## Restore the shim. Idempotent.
  if agent == nil or not agent.installed: return
  agent.installed = false
  if hcrAgentHooks != nil:
    hcrAgentHooks = nil

proc installHcrStub*(): HcrStubAgent =
  ## Put a fresh double in front of the ten ``rb_hcr_*`` procs, so an
  ## application's own call path — ``rbHcrBeforeReload(cb, ud)``,
  ## ``if rbHcrWantsReload(): rbHcrApplyReload()`` — reaches it unchanged.
  let agent = HcrStubAgent(
    beforeCallbacks: @[], afterCallbacks: @[], managed: @[], pending: @[],
    appliedFiles: initTable[string, bool](),
    appliedTypes: initTable[string, bool](),
    lifecycle: @[], installed: true)
  hcrAgentHooks = HcrAgentHooks(
    registerManagedType: proc(typeName: cstring) =
      agent.stubRegisterManagedType(typeName),
    unregisterManagedType: proc(typeName: cstring) =
      agent.stubUnregisterManagedType(typeName),
    beforeReload: proc(callback: RbHcrReloadCallback; userData: pointer) =
      agent.stubBeforeReload(callback, userData),
    afterReload: proc(callback: RbHcrReloadCallback; userData: pointer) =
      agent.stubAfterReload(callback, userData),
    removeBeforeReload: proc(callback: RbHcrReloadCallback;
                             userData: pointer) =
      agent.stubRemoveBeforeReload(callback, userData),
    removeAfterReload: proc(callback: RbHcrReloadCallback;
                            userData: pointer) =
      agent.stubRemoveAfterReload(callback, userData),
    wantsReload: proc(): bool = agent.wantsReload(),
    applyReload: proc() = discard agent.applyReload(),
    fileChanged: proc(filePath: cstring): bool =
      agent.fileChanged($filePath),
    typeChanged: proc(typeName: cstring): bool =
      agent.typeChanged($typeName))
  agent
