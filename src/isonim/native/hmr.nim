## isonim/native/hmr.nim
##
## Hot Module Reload runtime for IsoNim's NATIVE targets (TUI, GPUI,
## Freya, Cocoa, Android). The native sibling of ``isonim/web/hmr.nim`` +
## ``isonim/web/hmr_ui_registry.nim``.
##
## Specs:
## - ``codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload-Native.md``
##   — "Reactive root reload sequence" and "Failure mode" are the two
##   sections this module implements literally.
## - ``…/Hot-Module-Reload-Native.milestones.org`` § NH-M2.
## - ``reprobuild-specs/HCR/HCR-Overview.md`` § 7.4, § 13.
##
## ## What is here
##
## - ``HmrRoot`` — owns the ui-slot registry and the two agent callbacks.
##   ``start`` registers the managed types and installs
##   ``rb_hcr_before_reload`` / ``rb_hcr_after_reload``.
## - ``mountUiHot`` — the mount seam. Built on NH-M1's ``renderNative``,
##   so the reactive root is opened exactly once and is NEVER disposed by
##   a reload.
## - ``hmrSignal`` — component state keyed by call site, preserved across
##   reloads.
## - ``swap`` — replace a slot's factory by hand (the web ``swap``'s
##   native equivalent; used by transports and by tests, and it is the
##   same code path a real patch takes).
##
## ## The dynamic-accessor rule, and why it is not negotiable here
##
## NH-M1 measured this against the real ``task_app`` TUI composition
## root: an accessor that TRACKS the root build re-runs — and swaps the
## root node — on every view-model mutation (``renders`` went 1 → 2 → 3
## for three unrelated VM writes), which strands the frame source, the
## element-tree provider and the hit-tester that the root handle
## captures. That is why every non-HMR launcher wraps its build proc in
## ``staticNativeRoot``.
##
## So the hot proxy may not be reached by tracking the root build. It is
## reached through a DYNAMIC ACCESSOR instead, exactly as web ``render``
## does it:
##
## - ``mountUiHot``'s accessor is tracked, but the only reactive thing it
##   is *supposed* to touch is ``hmrInvokeSlot``, which reads a per-slot
##   ``Memo``. So the mount seam's dependency set is "the set of slots
##   this mount reaches", and nothing else.
## - The user's component body runs INSIDE that memo, and inside an
##   ``untrack`` within it. The memo therefore depends on exactly one
##   thing — the slot's factory ``Signal`` — and a VM mutation cannot
##   invalidate it. This is the native correction to the web parametric
##   path, which has no ``untrack`` because the browser DOM builder
##   pushes its reads down into leaf effects; the measured native
##   composition roots do not.
##
## Consequence for app authors: everything reactive must live inside a
## ui slot. A ``factory`` that reads a view-model signal *itself*,
## outside any slot, re-creates NH-M1's pathology and this module cannot
## stop it.
##
## ## Compile-time gating
##
## ``-d:isonimHmr`` activates everything below. Without it the same names
## exist with build-once semantics (``mountUiHot`` is ``renderNative`` +
## ``staticNativeRoot``, ``hmrSignal`` is ``createSignal``, ``HmrRoot``
## is inert), so an app is written once and compiles both ways.
##
## ``-d:reprobuildHcr`` is orthogonal and governs only whether the
## ``rb_hcr_*`` calls bind the real agent. NH-M2 needs neither a running
## agent nor that flag: the reload lifecycle is driven through the agent
## seam in ``isonim/native/hcr.nim``, which
## ``isonim/tests/helpers/hcr_stub.nim`` fills.

when defined(js):
  {.error: "isonim/native/hmr is for native (nim c) targets only. " &
      "The JS HMR runtime lives in isonim/web/hmr.nim.".}

import isonim/renderers/native as native_root
import isonim/core/signals
import isonim/core/batch

export native_root.NativeRootAccessor, native_root.NativeRootMount,
       native_root.NativeRootHandle, native_root.renderNative,
       native_root.staticNativeRoot, native_root.dispose,
       native_root.isDisposed

when defined(isonimHmr):
  import std/[tables, sets]
  import isonim/core/[computation, owner, graph]
  import isonim/native/hcr

  export hcr

  # NOTE on `except Exception` below. It is deliberate at every site in
  # this branch. Two of them are `{.cdecl.}` callbacks the C agent invokes
  # directly, where a Nim exception unwinding into a C frame is undefined
  # behaviour; the rest are never-blank-the-surface boundaries. Narrowing
  # to `CatchableError` would let a Defect — an index error in a freshly
  # patched ui block is exactly that — escape. Where the site is inside a
  # generic (whose warning settings come from the instantiating module,
  # not from here) the same set is spelled as two clauses so no consumer
  # repo has to silence a warning for us.

  # -------------------------------------------------------------------------
  # Types
  # -------------------------------------------------------------------------

  type
    UiNodeRef* = ref object of RootObj
      ## Type-erased handle on a renderer node. Erasure is what lets ONE
      ## registry serve the TUI, GPUI and Freya node types at once — the
      ## registry is process-global, and a registry generic in the node
      ## type would have to be instantiated per renderer.
      ##
      ## It is a BOX rather than a ``cast`` to ``RootRef``. Renderer node
      ## types (``NativeWidget``, ``TerminalNode``, …) are plain
      ## ``ref object``s that do not inherit ``RootObj``, so there is no
      ## legitimate cast; forcing one through ``pointer`` would both lose
      ## the reference for ORC (a ``pointer`` keeps nothing alive — a
      ## memoised node with no other owner would be collected under the
      ## renderer) and install wrong RTTI. The box owns a real reference
      ## and carries the concrete type.

    UiNodeBox[E] = ref object of UiNodeRef
      node: E

    UiSlotFactory* = proc(): UiNodeRef {.closure.}
      ## A ui block's body, type-erased through ``UiNodeRef``. Build one
      ## from a typed body with ``uiSlotFactory``.

    UiSlot* = ref object
      ## One registry entry, keyed by the source location of a ui block
      ## and versioned by ``symBodyHash`` of its body.
      loc*: string
      hash*: string
      factory*: Signal[UiSlotFactory]
        ## Written when — and only when — the hash changes. The write is
        ## the entire dispatch mechanism: it invalidates ``memo``, which
        ## invalidates every mount that read it.
      claimedGen*: int
      signalIds*: sets.HashSet[string]
        ## ``hmrSignal`` ids created while this slot's body ran. Used by
        ## pruning; see ``pruneStaleEntries``.
      memo: Memo[UiNodeRef]
      hasMemo: bool
      lastGood: UiNodeRef
      hasLastGood: bool

    PendingRegistration* = object
      ## A registration staged by the entry call but not yet applied.
      loc*: string
      hash*: string
      factory*: UiSlotFactory

    UiSlotRegistry* = ref object
      entries*: Table[string, UiSlot]
      signals*: Table[string, SignalStateBase]
      signalOwner*: Table[string, string]
        ## signal id → owning slot loc ("" when created outside a slot).
      currentGen*: int
      persistentOwner: OwnerBase
      rootDispose: proc()
      pending*: seq[PendingRegistration]
      staging*: bool
      currentSlotLoc: string
      onSlotError*: proc(loc: string; err: ref Exception) {.closure.}

    HmrTypeChange* = object
      ## Nim-owned copy of one ``RbHcrTypeChange``. A copy, not a view:
      ## the agent owns the C storage and IsoNim must not retain pointers
      ## past the callback's return (HCR-Overview § 13.3).
      typeName*: string
      oldSize*: uint32
      newSize*: uint32

    HmrReloadInfo* = object
      ## Nim-owned copy of one ``RbHcrReloadInfo``.
      changedFiles*: seq[string]
      changedTypes*: seq[HmrTypeChange]

    HmrEntry* = proc() {.closure.}
      ## The ui-block registration pass. Re-run inside
      ## ``rb_hcr_before_reload``: after a patch the trampolines are in
      ## place, so running the entry executes the NEW bodies, which call
      ## ``hmrRegisterFactory`` with the new hashes. This is the native
      ## stand-in for the browser's "the reloaded bundle re-runs module
      ## init" (design doc, "Reactive root reload sequence").

    HmrRoot* = ref object
      ## Handle on a running native HMR session.
      registry*: UiSlotRegistry
      entry*: HmrEntry
      onError*: proc(loc: string; err: ref Exception) {.closure.}
      onBeforeReload*: proc(info: HmrReloadInfo) {.closure.}
      onAfterReload*: proc(info: HmrReloadInfo) {.closure.}
      started*: bool
      beforeReloads*: int      ## times the before-reload callback ran
      afterReloads*: int       ## times the after-reload callback ran
      appliedReloads*: int     ## reloads whose entry call committed
      failedReloads*: int      ## reloads whose entry call raised
      lastReloadFailed*: bool
      lastError*: ref Exception
      lastReloadInfo*: HmrReloadInfo
      managedTypes*: seq[string]
        ## Held for the process lifetime ON PURPOSE: the agent's registry
        ## stores the ``const char*`` it was handed rather than copying it
        ## (``repro_hcr_agent.c::rb_hcr_register_managed_type``), so the
        ## caller owns the storage.

    HmrMount*[E] = ref object
      ## Handle returned by ``mountUiHot``.
      handle*: NativeRootHandle[E]
      onError*: proc(loc: string; err: ref Exception) {.closure.}
      errors*: int

  var activeUiRegistry* {.threadvar.}: UiSlotRegistry
    ## The registry ``hmrSignal`` / ``hmrRegisterFactory`` /
    ## ``hmrInvokeSlot`` act on. Set by ``HmrRoot.start`` and re-set at
    ## the head of both agent callbacks so a component body always sees
    ## the registry of the root that is reloading.

  var uiHotMounts*: int
    ## Total ``mountUiHot`` calls in this process. The NH-M2 gates assert
    ## this does NOT change across a reload — that is the operative form
    ## of "the tree updates without re-running the mount".

  # -------------------------------------------------------------------------
  # Registry
  # -------------------------------------------------------------------------

  proc newUiSlotRegistry*(): UiSlotRegistry =
    ## The persistent owner is the point of this constructor. Slot memos
    ## hang off an owner that no mount effect owns, so an ancestor effect
    ## re-running (``cleanNode`` walking its ``owned`` list) cannot
    ## dispose them. Without it "an unchanged ui block keeps its node"
    ## would be false the first time any parent re-rendered.
    result = UiSlotRegistry(
      entries: initTable[string, UiSlot](),
      signals: initTable[string, SignalStateBase](),
      signalOwner: initTable[string, string](),
      currentGen: 0,
      pending: @[],
      staging: false,
      currentSlotLoc: "")
    var capturedDispose: proc()
    var capturedOwner: OwnerBase
    createRoot proc(dispose: proc()) =
      capturedDispose = dispose
      capturedOwner = getOwner()
    result.persistentOwner = capturedOwner
    result.rootDispose = capturedDispose

  proc disposeRegistry*(reg: UiSlotRegistry) =
    if reg == nil: return
    if reg.rootDispose != nil:
      let d = reg.rootDispose
      reg.rootDispose = nil
      d()

  proc applyRegistration(reg: UiSlotRegistry; p: PendingRegistration) =
    let existing = reg.entries.getOrDefault(p.loc)
    if existing == nil:
      # The factory signal is created with an equality function that is
      # always false. The HASH is the authority on whether a body
      # changed; letting the signal's default `==` second-guess it would
      # silently swallow a real swap whenever the new closure happened to
      # compare equal to the old one.
      let sig = signals.createSignal(p.factory,
        proc(prev, next: UiSlotFactory): bool = false)
      reg.entries[p.loc] = UiSlot(
        loc: p.loc, hash: p.hash, factory: sig,
        claimedGen: reg.currentGen,
        signalIds: sets.initHashSet[string](),
        hasMemo: false, hasLastGood: false)
    else:
      existing.claimedGen = reg.currentGen
      if existing.hash != p.hash:
        existing.hash = p.hash
        existing.factory.val = p.factory

  proc commitPending*(reg: UiSlotRegistry) =
    ## Apply every staged registration. This is where the reload becomes
    ## visible: each hash-changed slot's factory signal is written, which
    ## invalidates its memo, which invalidates every mount that read it.
    for p in reg.pending:
      reg.applyRegistration(p)
    reg.pending.setLen(0)

  proc discardPending*(reg: UiSlotRegistry) =
    ## Drop every staged registration without applying any of them. The
    ## never-blank-the-surface guarantee is this proc: an entry call that
    ## raises half-way through has staged some registrations and not
    ## others, and applying that prefix would show the user a tree that
    ## no version of their source ever produced.
    reg.pending.setLen(0)

  proc hmrRegisterFactory*(loc, hash: string; factory: UiSlotFactory) =
    ## Called by a ui block's module-level registration. Outside a reload
    ## this applies immediately; inside one it is staged until the whole
    ## entry call has succeeded.
    let reg = activeUiRegistry
    if reg == nil:
      raise newException(Defect,
        "isonim native HMR: hmrRegisterFactory called with no active " &
        "registry. HmrRoot.start() must run before any ui-block " &
        "registration (loc: " & loc & ").")
    if factory == nil:
      raise newException(ValueError,
        "isonim native HMR: nil factory registered for ui slot " & loc)
    if reg.staging:
      reg.pending.add(PendingRegistration(loc: loc, hash: hash,
                                          factory: factory))
    else:
      reg.applyRegistration(PendingRegistration(loc: loc, hash: hash,
                                                factory: factory))

  proc pruneStaleEntries*(reg: UiSlotRegistry) =
    ## Drop slots not re-registered in the current generation — i.e. ui
    ## blocks deleted from the source — and the ``hmrSignal`` state they
    ## owned.
    ##
    ## PRUNING IS BY SLOT, NOT BY CLAIMED SIGNAL, and the difference is
    ## not cosmetic. Web's ``swap`` clears ``claimed`` and re-runs the
    ## whole factory tree, so every live signal is re-claimed before the
    ## sweep. Native memoises: a slot whose hash did not change does NOT
    ## re-run its body during a reload, so its signals are never
    ## re-claimed, and a claim-based sweep would delete exactly the state
    ## HMR exists to preserve. Ownership is recorded when the signal is
    ## created and a signal dies with its slot.
    var deadSlots: seq[string] = @[]
    for loc, slot in reg.entries:
      if slot.claimedGen != reg.currentGen:
        deadSlots.add(loc)
    for loc in deadSlots:
      reg.entries.del(loc)
    if deadSlots.len == 0: return
    var deadSignals: seq[string] = @[]
    for id, owner in reg.signalOwner:
      if owner.len > 0 and owner notin reg.entries:
        deadSignals.add(id)
    for id in deadSignals:
      reg.signals.del(id)
      reg.signalOwner.del(id)

  # -------------------------------------------------------------------------
  # Slot dispatch — the hot-component proxy
  # -------------------------------------------------------------------------

  proc boxUiNode*[E](node: E): UiNodeRef =
    ## Erase a renderer node's type while keeping a real reference to it.
    UiNodeBox[E](node: node)

  proc unboxUiNode*[E](box: UiNodeRef): E =
    ## Recover a renderer node. A mismatch is a loud error, not a nil:
    ## it means one slot loc was registered by two renderers, and the
    ## silent form of that is a mount that renders nothing.
    if box == nil:
      raise newException(Defect,
        "isonim native HMR: ui slot produced a nil node")
    if not (box of UiNodeBox[E]):
      raise newException(Defect,
        "isonim native HMR: ui slot produced a node of a different " &
        "renderer type than the one invoking it. One slot location " &
        "cannot be shared by two renderers.")
    UiNodeBox[E](box).node

  proc uiSlotFactory*[E](body: proc(): E): UiSlotFactory =
    ## Wrap a typed ui-block body as a registry factory. This is the
    ## call an app (or the ``{.uiComponent.}`` pragma, once it grows a
    ## native arm) makes when registering.
    if body == nil:
      raise newException(ValueError,
        "uiSlotFactory: body is nil — the slot would have nothing to build")
    result = proc(): UiNodeRef = boxUiNode(body())

  proc hmrInvokeSlot*[E](loc: string): E =
    ## The proxy. Call this where the ui block used to be called.
    ##
    ## Reads the slot's memo (tracked → the surrounding mount seam
    ## subscribes to this slot), and the memo reads the slot's factory
    ## signal (tracked by the memo → a hash change invalidates it). The
    ## body itself runs untracked, so nothing the body reads can
    ## invalidate the mount. See the dynamic-accessor rule at the top of
    ## this module.
    let reg = activeUiRegistry
    if reg == nil:
      raise newException(Defect,
        "isonim native HMR: hmrInvokeSlot(" & loc & ") called with no " &
        "active registry — HmrRoot.start() has not run on this thread.")
    let slot = reg.entries.getOrDefault(loc)
    if slot == nil:
      raise newException(Defect,
        "isonim native HMR: no factory registered for ui slot at " & loc &
        ". The entry call passed to HmrRoot.start() must register every " &
        "slot it later invokes.")
    slot.claimedGen = reg.currentGen
    if not slot.hasMemo:
      let s = slot
      let r = reg
      runWithOwner(reg.persistentOwner, proc() =
        s.memo = createMemo(proc(): UiNodeRef =
          let f = s.factory.val
          let prevSlot = r.currentSlotLoc
          r.currentSlotLoc = s.loc
          try:
            let n = untrack(proc(): UiNodeRef = f())
            s.lastGood = n
            s.hasLastGood = true
            return n
          except Exception as err:
            # Contain the failure at the memo boundary and report it.
            # Returning the previous node keeps the memo's value
            # reference-identical, so no observer is notified and the
            # surface does not change.
            if r.onSlotError != nil: r.onSlotError(s.loc, err)
            if s.hasLastGood: return s.lastGood
            raise
          finally:
            r.currentSlotLoc = prevSlot))
      slot.hasMemo = true
    unboxUiNode[E](slot.memo.val)

  proc swap*(root: HmrRoot; loc, hash: string; factory: UiSlotFactory) =
    ## Replace one slot's factory by hand. Same code path a reload takes
    ## — ``commitPending`` — so a transport that learns about a change
    ## out of band cannot drift from the agent-driven path.
    if root == nil or root.registry == nil:
      raise newException(ValueError, "swap: HmrRoot is not started")
    activeUiRegistry = root.registry
    root.registry.applyRegistration(
      PendingRegistration(loc: loc, hash: hash, factory: factory))

  proc slotCount*(root: HmrRoot): int =
    if root == nil or root.registry == nil: 0 else: root.registry.entries.len

  proc signalCount*(root: HmrRoot): int =
    if root == nil or root.registry == nil: 0 else: root.registry.signals.len

  proc currentGeneration*(root: HmrRoot): int =
    if root == nil or root.registry == nil: 0 else: root.registry.currentGen

  proc slotHash*(root: HmrRoot; loc: string): string =
    let slot = root.registry.entries.getOrDefault(loc)
    if slot == nil: "" else: slot.hash

  # -------------------------------------------------------------------------
  # hmrSignal
  # -------------------------------------------------------------------------

  proc hmrSignalImpl*[T](id: string; initial: T): Signal[T] =
    ## Look up or create a ``Signal[T]`` keyed by ``id``. With no active
    ## registry this degrades to a plain ``createSignal``, so a component
    ## written for HMR still works when mounted outside an ``HmrRoot``.
    let reg = activeUiRegistry
    if reg == nil:
      return signals.createSignal(initial)
    if reg.signals.hasKey(id):
      if reg.currentSlotLoc.len > 0:
        let owner = reg.entries.getOrDefault(reg.currentSlotLoc)
        if owner != nil: owner.signalIds.incl(id)
      return cast[Signal[T]](reg.signals[id])
    let s = signals.createSignal(initial)
    reg.signals[id] = SignalStateBase(s)
    reg.signalOwner[id] = reg.currentSlotLoc
    if reg.currentSlotLoc.len > 0:
      let owner = reg.entries.getOrDefault(reg.currentSlotLoc)
      if owner != nil: owner.signalIds.incl(id)
    return s

  template hmrSignal*[T](initial: T): Signal[T] =
    ## Reload-preserved component state. The id is the call site, so the
    ## same source line maps to the same registry entry across reloads —
    ## which is exactly what a patched function body reproduces, since a
    ## patch does not move the line.
    let info = instantiationInfo(-1, fullPaths = true)
    hmrSignalImpl[T](
      info.filename & ":" & $info.line & ":" & $info.column,
      initial)

  # -------------------------------------------------------------------------
  # Agent callbacks
  # -------------------------------------------------------------------------

  proc toHmrReloadInfo(info: ptr RbHcrReloadInfo): HmrReloadInfo =
    ## Copy the agent-owned reload context into Nim storage. Nothing here
    ## may outlive the callback (HCR-Overview § 13.3), so every cstring
    ## is turned into a ``string`` immediately.
    result = HmrReloadInfo(changedFiles: @[], changedTypes: @[])
    if info == nil: return
    if info.changedFiles != nil:
      for i in 0 ..< int(info.changedFilesCount):
        let p = info.changedFiles[i]
        if p != nil: result.changedFiles.add($p)
    if info.changedTypes != nil:
      for i in 0 ..< int(info.changedTypesCount):
        let tc = info.changedTypes[i]
        result.changedTypes.add(HmrTypeChange(
          typeName: (if tc.typeName == nil: "" else: $tc.typeName),
          oldSize: tc.oldSize, newSize: tc.newSize))

  proc hmrBeforeReloadCallback(info: ptr RbHcrReloadInfo;
                               userData: pointer) {.cdecl.} =
    ## ``rb_hcr_before_reload``. Flips the generation, re-runs the
    ## ui-block registration pass, and dispatches the updated factories.
    ##
    ## NOTHING MAY ESCAPE THIS PROC. The agent calls it from C; a Nim
    ## exception unwinding through a C frame is undefined behaviour, and
    ## the never-blank-the-surface guarantee is implemented HERE rather
    ## than by the agent — the agent's contract is only that a patch
    ## rejected during *prepare* never reaches this callback at all
    ## (Reprobuild HLX-M8).
    if userData == nil: return
    let root = cast[HmrRoot](userData)
    if root == nil or root.registry == nil: return
    inc root.beforeReloads
    let reg = root.registry
    activeUiRegistry = reg
    let info2 = toHmrReloadInfo(info)
    root.lastReloadInfo = info2

    let genBefore = reg.currentGen
    inc reg.currentGen
    reg.discardPending()
    reg.staging = true

    var failed = false
    try:
      if root.onBeforeReload != nil:
        root.onBeforeReload(info2)
      if root.entry != nil:
        root.entry()
    except Exception as err:
      failed = true
      root.lastError = err
      if root.onError != nil:
        try:
          root.onError("<hmr-entry>", err)
        except Exception:
          discard

    reg.staging = false
    if failed:
      # Design doc, "Failure mode": catch, roll the generation counter
      # back, leave the previous tree intact.
      reg.discardPending()
      reg.currentGen = genBefore
      root.lastReloadFailed = true
      inc root.failedReloads
    else:
      reg.commitPending()
      root.lastReloadFailed = false
      inc root.appliedReloads

  proc hmrAfterReloadCallback(info: ptr RbHcrReloadInfo;
                              userData: pointer) {.cdecl.} =
    ## ``rb_hcr_after_reload``. Prunes stale-generation entries and runs
    ## the user hook. Same no-escape rule as the before callback.
    if userData == nil: return
    let root = cast[HmrRoot](userData)
    if root == nil or root.registry == nil: return
    inc root.afterReloads
    let reg = root.registry
    activeUiRegistry = reg
    let info2 = toHmrReloadInfo(info)
    # A failed before-phase rolled the generation back, so EVERY slot now
    # looks stale. Pruning here would delete the entire registry on the
    # strength of a reload that was refused — the opposite of leaving the
    # previous tree intact.
    if not root.lastReloadFailed:
      reg.pruneStaleEntries()
    if root.onAfterReload != nil:
      try:
        root.onAfterReload(info2)
      except Exception as err:
        root.lastError = err
        if root.onError != nil:
          try:
            root.onError("<hmr-after-hook>", err)
          except Exception:
            discard

  # -------------------------------------------------------------------------
  # HmrRoot lifecycle
  # -------------------------------------------------------------------------

  const defaultManagedTypes*: seq[string] = @[
    # HCR-Overview § 7.4: the whitelist the patch generator checks when a
    # layout change is detected. These are the types a reload may resize
    # while live instances exist.
    "isonim.SignalState",
    "isonim.SignalStorage",
    "isonim.UiSlot",
    "isonim.UiSlotFactory",
  ]
    ## NOTE ON THE ``[*]`` SPELLING. The design doc and NH-M2's
    ## deliverable write these as ``isonim.SignalState[*]`` /
    ## ``isonim.SignalStorage[*]``. **The ABI has no wildcard.** Both the
    ## specified surface (HCR-Overview § 13.2, "the canonical type name
    ## as it appears in debug info") and the shipped implementation
    ## (``repro_hcr_agent.c``, whose registry is a ``strcmp`` whitelist)
    ## match names exactly, so a literal ``[*]`` would register a type
    ## that no debug-info name can ever equal — a whitelist entry that
    ## can never match is indistinguishable from not registering at all.
    ##
    ## Registered here are therefore the erased, non-generic names, plus
    ## ``registerManagedInstantiation`` below for the per-``T`` names an
    ## app actually instantiates. Whether the real agent will grow glob
    ## matching is NOT decided anywhere and is reported as open rather
    ## than assumed.

  proc registerManagedType*(root: HmrRoot; typeName: string) =
    ## Add one name to the agent's managed whitelist, keeping the string
    ## alive for the process lifetime because the agent stores the
    ## pointer rather than a copy.
    for existing in root.managedTypes:
      if existing == typeName: return
    root.managedTypes.add(typeName)
    rbHcrRegisterManagedType(cstring(root.managedTypes[^1]))

  proc registerManagedInstantiation*[T](root: HmrRoot; prefix: string) =
    ## Register the concrete instantiation name for one ``T``, e.g.
    ## ``isonim.SignalState[system.int]``. This is what the ``[*]`` in the
    ## design doc means in practice on an ABI that compares names with
    ## ``strcmp``.
    root.registerManagedType(prefix & "[" & $T & "]")

  proc newHmrRoot*(entry: HmrEntry;
                   onError: proc(loc: string; err: ref Exception) = nil): HmrRoot =
    ## Create (but do not start) a native HMR session.
    if entry == nil:
      raise newException(ValueError,
        "newHmrRoot: entry is nil — there would be no ui-block " &
        "registration pass to re-run on reload, so every reload would " &
        "be a silent no-op.")
    result = HmrRoot(registry: newUiSlotRegistry(), entry: entry,
                     onError: onError, managedTypes: @[])
    let r = result
    result.registry.onSlotError = proc(loc: string; err: ref Exception) =
      r.lastError = err
      if r.onError != nil: r.onError(loc, err)

  proc start*(root: HmrRoot) =
    ## Register the managed types, install the two agent callbacks, and
    ## run the entry call once so the registry is populated before the
    ## first mount.
    if root == nil:
      raise newException(ValueError, "HmrRoot.start: root is nil")
    if root.started: return
    activeUiRegistry = root.registry

    for name in defaultManagedTypes:
      root.registerManagedType(name)

    # The agent holds `userData` as an opaque pointer and has no idea it
    # is a GC'd ref, so the root must be kept alive by hand for exactly
    # as long as the callbacks are installed.
    GC_ref(root)
    let ud = cast[pointer](root)
    rbHcrBeforeReload(hmrBeforeReloadCallback, ud)
    rbHcrAfterReload(hmrAfterReloadCallback, ud)
    root.started = true

    root.registry.staging = true
    try:
      root.entry()
      root.registry.staging = false
      root.registry.commitPending()
    except Exception:
      root.registry.staging = false
      root.registry.discardPending()
      raise

  proc stop*(root: HmrRoot) =
    ## Remove the callbacks and release the reference ``start`` took.
    ## Idempotent.
    if root == nil or not root.started: return
    let ud = cast[pointer](root)
    rbHcrRemoveBeforeReload(hmrBeforeReloadCallback, ud)
    rbHcrRemoveAfterReload(hmrAfterReloadCallback, ud)
    for name in root.managedTypes:
      rbHcrUnregisterManagedType(cstring(name))
    root.started = false
    if activeUiRegistry == root.registry:
      activeUiRegistry = nil
    GC_unref(root)

  proc pumpReload*(root: HmrRoot): bool {.discardable.} =
    ## The synchronized-reload poll of HCR-Overview § 13.6: call it once
    ## per frame. Returns true when a patch was applied.
    if not rbHcrWantsReload(): return false
    rbHcrApplyReload()
    true

  # -------------------------------------------------------------------------
  # mountUiHot
  # -------------------------------------------------------------------------

  proc mountUiHot*[E](factory: proc(): E;
                      mount: NativeRootMount[E];
                      onError: proc(loc: string; err: ref Exception) = nil
                     ): HmrMount[E] =
    ## Mount a hot-reloading subtree through NH-M1's reactive-root seam.
    ##
    ## The accessor handed to ``renderNative`` is deliberately NOT
    ## ``staticNativeRoot``-wrapped: it has to track, or a slot swap
    ## could never reach the surface. What keeps that safe is that the
    ## only reactive reads on this path are ``hmrInvokeSlot``'s memo
    ## reads — see the dynamic-accessor rule at the top of this module.
    ##
    ## Failure containment: if the factory throws, the previously mounted
    ## node is returned, which trips ``renderNative``'s identity check so
    ## the surface is not mutated.
    if factory == nil:
      raise newException(ValueError,
        "mountUiHot: factory is nil — there is no subtree to mount")
    if mount == nil:
      raise newException(ValueError,
        "mountUiHot: mount is nil — a built subtree would never reach a surface")
    inc uiHotMounts
    let m = HmrMount[E](onError: onError, errors: 0)
    var lastGood: E
    var haveLastGood = false
    let userFactory = factory
    # One failure handler, two clauses: `CatchableError` + `Defect` is the
    # same set as `Exception` spelled so a consumer repo compiling this
    # generic does not get a BareExcept warning out of our module.
    let onFailure = proc(err: ref Exception): E =
      inc m.errors
      if m.onError != nil: m.onError("<hmr-mount>", err)
      if haveLastGood: return lastGood
      raise err
    let accessor = NativeRootAccessor[E](proc(): E =
      try:
        let n = userFactory()
        lastGood = n
        haveLastGood = true
        return n
      except CatchableError as err:
        return onFailure(err)
      except Defect as err:
        return onFailure(err))
    m.handle = renderNative(accessor, mount)
    m

  proc mountUiHot*[R, E](renderer: R; host: E;
                         factory: proc(): E;
                         onError: proc(loc: string; err: ref Exception) = nil
                        ): HmrMount[E] =
    ## ``mountUiHot`` for renderers whose surface is a parent element:
    ## the insert runs through the RendererBackend's own ``appendChild``
    ## / ``removeChild``, so the renderer's tree-mutation API stays the
    ## single reconciliation primitive.
    mixin appendChild, removeChild
    var mounted: E
    var haveMounted = false
    mountUiHot(factory, NativeRootMount[E](proc(node: E) =
      if haveMounted:
        if mounted == node: return
        renderer.removeChild(host, mounted)
      renderer.appendChild(host, node)
      mounted = node
      haveMounted = true), onError)

  proc renders*[E](m: HmrMount[E]): int =
    ## Times the mount seam's render effect ran. 1 after mounting.
    if m == nil or m.handle == nil: 0 else: m.handle.renders

  proc rootSwaps*[E](m: HmrMount[E]): int =
    if m == nil or m.handle == nil: 0 else: m.handle.rootSwaps

  proc dispose*[E](m: HmrMount[E]) =
    if m == nil: return
    native_root.dispose(m.handle)

  proc isDisposed*[E](m: HmrMount[E]): bool =
    m == nil or native_root.isDisposed(m.handle)

else:
  # -----------------------------------------------------------------------
  # ``-d:isonimHmr`` off. The same names, with build-once semantics and no
  # registry, so an app is written once and the production binary carries
  # none of the machinery above.
  # -----------------------------------------------------------------------

  type
    HmrEntry* = proc() {.closure.}

    HmrRoot* = ref object
      entry*: HmrEntry
      onError*: proc(loc: string; err: ref Exception) {.closure.}
      started*: bool

    HmrMount*[E] = ref object
      handle*: NativeRootHandle[E]
      onError*: proc(loc: string; err: ref Exception) {.closure.}
      errors*: int

  var uiHotMounts*: int

  template hmrSignal*[T](initial: T): Signal[T] = createSignal(initial)

  proc hmrSignalImpl*[T](id: string; initial: T): Signal[T] =
    createSignal(initial)

  proc newHmrRoot*(entry: HmrEntry;
                   onError: proc(loc: string; err: ref Exception) = nil): HmrRoot =
    if entry == nil:
      raise newException(ValueError, "newHmrRoot: entry is nil")
    HmrRoot(entry: entry, onError: onError)

  proc start*(root: HmrRoot) =
    ## Runs the registration pass once, for symmetry with the active
    ## path (a ui block's registration may have user-visible side
    ## effects), then does nothing further — there is no agent, no
    ## registry and no callback.
    if root == nil or root.started: return
    root.started = true
    root.entry()

  proc stop*(root: HmrRoot) =
    if root != nil: root.started = false

  proc pumpReload*(root: HmrRoot): bool {.discardable.} = false
  proc slotCount*(root: HmrRoot): int = 0
  proc signalCount*(root: HmrRoot): int = 0
  proc currentGeneration*(root: HmrRoot): int = 0

  proc mountUiHot*[E](factory: proc(): E;
                      mount: NativeRootMount[E];
                      onError: proc(loc: string; err: ref Exception) = nil
                     ): HmrMount[E] =
    ## Build-once, exactly as a non-HMR caller mounts today: the accessor
    ## is wrapped in ``staticNativeRoot``, which is what NH-M1 measured
    ## as the only safe shape for a real composition root.
    if factory == nil:
      raise newException(ValueError, "mountUiHot: factory is nil")
    if mount == nil:
      raise newException(ValueError, "mountUiHot: mount is nil")
    inc uiHotMounts
    let m = HmrMount[E](onError: onError, errors: 0)
    m.handle = renderNative(staticNativeRoot(factory), mount)
    m

  proc mountUiHot*[R, E](renderer: R; host: E;
                         factory: proc(): E;
                         onError: proc(loc: string; err: ref Exception) = nil
                        ): HmrMount[E] =
    mixin appendChild, removeChild
    var mounted: E
    var haveMounted = false
    mountUiHot(factory, NativeRootMount[E](proc(node: E) =
      if haveMounted:
        if mounted == node: return
        renderer.removeChild(host, mounted)
      renderer.appendChild(host, node)
      mounted = node
      haveMounted = true), onError)

  proc renders*[E](m: HmrMount[E]): int =
    if m == nil or m.handle == nil: 0 else: m.handle.renders

  proc rootSwaps*[E](m: HmrMount[E]): int =
    if m == nil or m.handle == nil: 0 else: m.handle.rootSwaps

  proc dispose*[E](m: HmrMount[E]) =
    if m == nil: return
    native_root.dispose(m.handle)

  proc isDisposed*[E](m: HmrMount[E]): bool =
    m == nil or native_root.isDisposed(m.handle)
