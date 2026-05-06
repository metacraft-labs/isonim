## isonim/web/hmr_ui_registry.nim
##
## Per-ui-block HMR registry — the runtime side of ui-as-boundary HMR.
## Active only under `-d:isonimHmr`.
##
## See `codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload.md`.
##
## Architecture (browser, JS target):
##
## - Each {.uiComponent.}-marked proc is identified by its source
##   location (file:line:col) and versioned by `symBodyHash` of the
##   body. The pragma emits both at the call site as string literals
##   and the registration call runs at module init.
##
## - At module init (when the bundle loads or reloads),
##   `hmrRegisterFactory` looks up or creates a slot. If the hash
##   matches an existing slot, nothing changes — the cached memo
##   keeps its previous Node value. If the hash differs, the slot's
##   factory signal is written, which invalidates the memo and
##   cascades up through any component that depends on it.
##
## - Memos are owned by a *persistent* HMR owner created here, not by
##   the parent render effect — so they survive `cleanNode` chains
##   when ancestor effects re-run. That's what makes "unchanged
##   blocks' DOM is literally untouched" actually true.

when not defined(js):
  {.error: "isonim/web/hmr_ui_registry requires the JS backend".}

when not defined(isonimHmr):
  {.error: "isonim/web/hmr_ui_registry requires `-d:isonimHmr` — it should not be imported in production builds".}

import std/[tables, jsffi, strutils]
import isonim/web/dom_api
import isonim/core/[signals, computation, owner, graph]

type
  UiSlot* = ref object
    ## A registry slot keyed by the source location of a `ui(...)` call.
    ## Versioned by the hash of the body proc's effective code.
    factory*: Signal[JsObject]   # type-erased proc(r: R, args...): Node
    hash*: string
    memo*: Memo[Node]            # cached output; owned by persistentHmrOwner
    hasMemo*: bool               # Memo[T] is a value type; track presence separately
    claimedGen*: int             # generation for prune
    lastGoodNode*: Node          # most recent successfully-produced value;
                                  # returned from the memo body when the
                                  # factory throws, so the cascade reports
                                  # the same Node ref → no DOM mutation

  UiSlotRegistry* = ref object
    entries*: Table[string, UiSlot]
    currentGen*: int
    persistentOwner*: OwnerBase   # memos hang off this owner
    rootDispose*: proc()          # disposes the persistent owner

# Global state. There's one registry per page; multi-tenant scenarios
# would need per-root registries, but in HMR development that's not a
# concern.
var globalUiRegistry* {.threadvar.}: UiSlotRegistry

var globalUiOnError*: proc(loc: string; err: ref Exception)
  ## Callback invoked when a slot's factory throws during memo
  ## evaluation. The error is contained at the memo boundary; the DOM
  ## stays at the previous good Node identity. Set this from the user's
  ## entry (typically inside main()) so the harness can surface
  ## errors without depending on the transport.

proc newUiSlotRegistry*(): UiSlotRegistry =
  result = UiSlotRegistry(
    entries: initTable[string, UiSlot](),
    currentGen: 0,
    persistentOwner: nil,
    rootDispose: nil,
  )
  # Build the persistent owner via createRoot. The disposeFn lets us
  # tear it down at app exit (rare in dev, but clean).
  var capturedDispose: proc()
  var capturedOwner: OwnerBase
  createRoot proc(dispose: proc()) =
    capturedDispose = dispose
    capturedOwner = getOwner()
  result.persistentOwner = capturedOwner
  result.rootDispose = capturedDispose

proc ensureUiRegistry*() =
  ## Lazy initialiser. Called from `renderHot` and from `bootstrapHmr`.
  if globalUiRegistry == nil:
    globalUiRegistry = newUiSlotRegistry()

# ---------------------------------------------------------------------------
# Focus capture / restore — small Nim wrappers around leaf-expression
# importjs calls so the registration path doesn't carry inline JS.
# ---------------------------------------------------------------------------

proc captureActiveElement*(): JsObject
  {.importjs: "((typeof document !== 'undefined' && document.activeElement) || null)".}
  ## Returns the currently focused element, or null when there's no
  ## document (headless test environments) or no element has focus.

proc isInDocument*(el: JsObject): bool
  {.importjs: "(typeof document !== 'undefined' && document.contains && document.contains(#))".}

proc isCurrentlyActive*(el: JsObject): bool
  {.importjs: "(typeof document !== 'undefined' && document.activeElement === #)".}

proc focusPreservingScroll*(el: JsObject)
  {.importjs: "#.focus({preventScroll: true})".}

proc restoreFocusIfDetached(el: JsObject) =
  ## If `el` is still attached but no longer the active element,
  ## refocus it. The focus would have been lost when an ancestor
  ## container was briefly detached during the swap cascade.
  if el.isNil or el.isUndefined: return
  if not isInDocument(el): return
  if isCurrentlyActive(el): return
  focusPreservingScroll(el)

# ---------------------------------------------------------------------------
# Module-init registration
# ---------------------------------------------------------------------------

proc hmrRegisterFactory*(loc, hash: string; factoryJs: JsObject) =
  ## Called from the module-init code emitted by `bootstrapHmr()`.
  ## On reload of a new bundle, this updates the slot's factory signal
  ## (which invalidates the slot's memo if the hash differs) WITHOUT
  ## going through the entry component. That is what lets unchanged ui
  ## blocks keep their DOM across a reload — the changes propagate
  ## through the slot signals only.
  ensureUiRegistry()
  let reg = globalUiRegistry
  inc reg.currentGen
  let existing = reg.entries.getOrDefault(loc)
  if existing == nil:
    let sig = signals.createSignal(factoryJs)
    let slot = UiSlot(factory: sig, hash: hash, hasMemo: false,
                      claimedGen: reg.currentGen)
    reg.entries[loc] = slot
  else:
    existing.claimedGen = reg.currentGen
    if existing.hash != hash:
      # Capture and restore focus around the cascade. An ancestor
      # memo invalidation may rebuild parent containers, which briefly
      # detaches the focused element from the document and clears
      # focus. Element identity and `<input>.value` survive naturally
      # (they're element-bound), so refocusing the same node is
      # well-defined.
      let prevActive = captureActiveElement()
      existing.factory.val = factoryJs
      existing.hash = hash
      restoreFocusIfDetached(prevActive)

proc pruneUnclaimed*() =
  ## Called after a batch of bootstrapHmr() registrations. Drops slots
  ## whose factories were not re-registered in the current generation —
  ## i.e., ui blocks deleted from the source.
  ensureUiRegistry()
  let reg = globalUiRegistry
  var toRemove: seq[string] = @[]
  for loc, slot in reg.entries:
    if slot.claimedGen != reg.currentGen:
      toRemove.add(loc)
  for loc in toRemove:
    reg.entries.del(loc)

# Note: there's no per-invocation invoke proc here — `hmr_component.nim`
# implements `hmrInvokeComponent` directly, since component invocation
# in v1 takes no captured arguments (top-level component procs only).
# Future work — components-with-props, lists-with-keyed-boundaries —
# will introduce richer invocation paths.

# ---------------------------------------------------------------------------
# Diagnostics — used by the Playwright fixture
# ---------------------------------------------------------------------------

proc registrySize*(): int =
  if globalUiRegistry == nil: 0
  else: globalUiRegistry.entries.len

proc currentGeneration*(): int =
  if globalUiRegistry == nil: 0
  else: globalUiRegistry.currentGen

proc findSlotEndingWith*(suffix: string): string =
  ## Returns the full slot key whose location ends with `suffix`, or
  ## raises Defect if there's no match. Useful for tests that want to
  ## name slots without depending on the absolute file path.
  if globalUiRegistry == nil:
    raise newException(Defect, "HMR registry not initialised")
  for loc in globalUiRegistry.entries.keys:
    if loc.len >= suffix.len and loc.endsWith(suffix):
      return loc
  raise newException(Defect, "no HMR slot found ending with: " & suffix)
