## isonim/web/hmr.nim
##
## Hot Module Reload runtime for IsoNim's JS browser target.
##
## See `codetracer-specs/Front-Ends/IsoNim/Hot-Module-Reload.md` for the
## full design and `Hot-Module-Reload.milestones.org` for the milestone
## tracker.
##
## Usage (app entry):
##
##   import isonim
##   import isonim/web/hmr
##
##   proc app(): Node = ...
##   let root = renderHot(app, document.getElementById("app"))
##
## Build with `-d:isonimHmr` to activate the HMR machinery. Without the
## flag, `renderHot` aliases `render`, `swap` is a no-op, `hmrSignal`
## aliases `createSignal`, and the generated JS contains no HMR-related
## symbols.

when not defined(js):
  {.error: "isonim/web/hmr requires the JS backend".}

import isonim/web/dom_api
import isonim/web/client
import isonim/rxcore
import isonim/core/signals

when defined(isonimHmr):
  import std/[tables, sets, jsffi]

  # `globalThis` as a typed JsObject lets us read/write JS globals via
  # ordinary indexing (`globalJs["foo"] = ...`) instead of raw {.emit.}.
  var globalJs* {.importjs: "globalThis".}: JsObject

  type
    HmrRegistry* = ref object
      ## Maps stable call-site ids to live reactive primitives. Survives
      ## across swaps so component-local state can be reused.
      entries*: Table[string, RootRef]
      currentGen*: int
      claimed*: HashSet[string]

    HmrRoot* = ref object
      ## The handle returned by `renderHot`. Hold this so the transport
      ## adapter can call `swap` on it.
      factory: Signal[proc(): Node]
      container: Element
      dispose*: proc()
      registry*: HmrRegistry
      onError*: proc(err: ref Exception)

  var activeHmrRegistry* {.threadvar.}: HmrRegistry
    ## The registry that `hmrSignal` claims into during component evaluation.
    ## Set by `renderHot` and (re)set by `swap` before re-evaluating the
    ## factory. Reading this from outside an HMR root yields nil — in which
    ## case `hmrSignal` falls back to a plain `createSignal`.

  proc newHmrRegistry*(): HmrRegistry =
    HmrRegistry(entries: initTable[string, RootRef](),
                currentGen: 0,
                claimed: initHashSet[string]())

  proc hmrSignalImpl*[T](id: string, initial: T): Signal[T] =
    ## Look up or create a Signal[T] keyed by `id`. Marks the id as claimed
    ## in the current generation so it survives the next pruning sweep.
    let reg = activeHmrRegistry
    if reg == nil:
      return createSignal(initial)
    reg.claimed.incl(id)
    if reg.entries.hasKey(id):
      return cast[Signal[T]](reg.entries[id])
    let s = createSignal(initial)
    reg.entries[id] = cast[RootRef](s)
    return s

  template hmrSignal*[T](initial: T): Signal[T] =
    ## Explicit HMR-preserved signal. The id is derived from the call-site
    ## `instantiationInfo()` at compile time, so the same source line maps
    ## to the same registry entry across swaps.
    let info = instantiationInfo(-1, fullPaths = true)
    hmrSignalImpl[T](
      info.filename & ":" & $info.line & ":" & $info.column,
      initial)

  template createSignal*[T](initial: T): Signal[T] =
    ## Shadowing template: under `-d:isonimHmr`, calls to `createSignal` in
    ## any module that imports `isonim/web/hmr` after `isonim/rxcore` are
    ## rewritten to `hmrSignal`. Internal isonim modules import
    ## `isonim/core/signals` directly and are not affected.
    let info = instantiationInfo(-1, fullPaths = true)
    hmrSignalImpl[T](
      info.filename & ":" & $info.line & ":" & $info.column,
      initial)

  proc renderHot*(
      code: proc(): Node, element: Element,
      onError: proc(err: ref Exception) = nil): HmrRoot =
    ## Like `render`, but installs a Hot-Component proxy at the root.
    ## The reactive root, parent owner, and any state declared via
    ## `hmrSignal` (or the shadowing `createSignal` template) survive
    ## subsequent `swap` calls. Effects are re-run on each swap.
    ##
    ## Reload-aware: if a previous renderHot already published a root
    ## on `globalThis.__isonim_hmr_root`, this is a bundle reload — we
    ## return the existing root and rely on module-init registration
    ## (emitted by each `{.uiComponent.}` pragma) to have already
    ## propagated factory updates through the existing reactive graph.
    let existing = globalJs["__isonim_hmr_root"]
    if not existing.isUndefined and not existing.isNull:
      return existing.to(HmrRoot)

    let root = HmrRoot(
      container: element,
      registry: newHmrRegistry(),
      onError: onError)
    # Use the underlying proc directly — our own `createSignal` template
    # shadows it within this module from its definition onward, and the
    # factory holder must not be registered in the user-facing HMR registry.
    root.factory = signals.createSignal(code)
    activeHmrRegistry = root.registry

    var lastGoodNode: Node = nil
    let factory = root.factory
    let onErr = onError
    let registry = root.registry

    var disposer: proc()
    createRoot proc(dispose: proc()) =
      disposer = dispose
      let accessor = proc(): Node =
        let f = factory.val
        # Make sure component bodies see the right registry. The user can
        # have only one HMR root at a time in practice, but this guards
        # against re-entrancy from concurrent swaps in tests.
        activeHmrRegistry = registry
        try:
          # No `untrack` here: with `{.uiComponent.}`-wrapped entries,
          # `f()` is a thin dispatcher that reads `slot.memo.val` —
          # we *want* the outer render effect to subscribe to that
          # memo signal so subsequent slot.factory writes invalidate
          # this effect and the new DOM gets installed. The user's
          # actual component body runs *inside* the memo, where
          # tracking is correctly scoped to the memo's computation.
          let n = f()
          lastGoodNode = n
          return n
        except Exception as err:
          if onErr != nil: onErr(err)
          # Returning the previously-rendered Node identity short-circuits
          # insertExpression's pointer-equality check, so the DOM does not
          # mutate. The user's previous render stays on screen.
          return lastGoodNode

      # Nim's checker rejects `cast[JsRoot](closure)` directly even
      # though a Nim closure is already a JS function at runtime. `toJs`
      # from std/jsffi lowers to `(#)` (a no-op pass-through), giving
      # us the typed JsObject we need without raw emit.
      discard insertExpression(element.Node, accessor.toJs.JsRoot, nil, nil)
    root.dispose = disposer

    # Publish the entry proc so transport adapters can rediscover it after
    # they finish evaluating a freshly-loaded bundle. Also publish the
    # HmrRoot itself so reload detection can reuse it.
    globalJs["__isonim_app__"] = toJs(code)
    globalJs["__isonim_hmr_root"] = toJs(root)
    return root

  proc swap*(root: HmrRoot, newCode: proc(): Node) =
    ## Replace the root component. The reactive root is preserved; only
    ## the subtree produced by the factory is reconciled in place.
    ## Failures in the new factory are caught at the accessor boundary —
    ## the previous DOM is preserved and `onError` is invoked.
    activeHmrRegistry = root.registry
    inc root.registry.currentGen
    root.registry.claimed.clear()
    root.factory.val = newCode
    # Prune entries not claimed in this generation. Done here so a swap
    # that *removes* a signal (e.g. user deleted a component) does not
    # leak the old SignalState.
    var toRemove: seq[string] = @[]
    for id in root.registry.entries.keys:
      if id notin root.registry.claimed:
        toRemove.add(id)
    for id in toRemove:
      root.registry.entries.del(id)
    globalJs["__isonim_app__"] = toJs(newCode)

  proc registrySize*(root: HmrRoot): int = root.registry.entries.len
  proc currentGeneration*(root: HmrRoot): int = root.registry.currentGen

  # ---------------------------------------------------------------------------
  # Multi-instance mount support (`mountUiHot`)
  #
  # `renderHot` is a singleton: it publishes `globalThis.__isonim_hmr_root`
  # and any subsequent call returns the existing root. That fits a single-app
  # entry point but does not fit apps that mount HMR-aware regions
  # independently (codetracer mounts one IsoNim view per panel, on demand,
  # into different DOM containers).
  #
  # `mountUiHot` is the multi-instance variant. Each call creates an
  # independent reactive root and is the reactive boundary for parametric
  # `{.uiComponent.}` calls inside `factory`: when a slot's factory signal
  # is rewritten on bundle reload, only mounts whose factory closure
  # transitively reads that slot re-run.
  # ---------------------------------------------------------------------------

  type
    HmrMount* = ref object
      ## Handle returned by `mountUiHot`. Disposing it tears down the
      ## reactive root and clears the container.
      container*: Element
      dispose*: proc()
      onError*: proc(err: ref Exception)

  proc mountUiHot*(
      container: Element;
      factory: proc(): Node;
      onError: proc(err: ref Exception) = nil): HmrMount =
    ## Mount a hot-reloading UI subtree into `container`.
    ##
    ## The factory closure is wrapped in a `createRenderEffect` (via
    ## `insertExpression`) so any reads of `slot.factory.val` made by
    ## parametric `{.uiComponent.}` calls subscribe the effect to slot
    ## swaps. When a slot's factory is rewritten (bundle reload, hash
    ## changed), every mount whose factory transitively reaches that
    ## slot re-runs and the DOM is reconciled in place by
    ## `insertExpression`. Mounts whose factory does not touch the
    ## changed slot are not re-evaluated; their DOM is literally
    ## untouched.
    ##
    ## Failure containment: if the factory throws (typically because a
    ## newly-loaded slot factory is broken), the previous Node identity
    ## is returned, which trips `insertExpression`'s pointer-equality
    ## short-circuit and leaves the DOM as-is. The error is reported
    ## via `onError` if provided. The next successful re-run clears
    ## the error state.
    let mount = HmrMount(container: container, onError: onError)
    var lastGoodNode: Node = nil
    let onErr = onError
    let userFactory = factory

    var disposer: proc()
    createRoot proc(dispose: proc()) =
      disposer = dispose
      let accessor = proc(): Node =
        try:
          let n = userFactory()
          lastGoodNode = n
          return n
        except Exception as err:
          if onErr != nil: onErr(err)
          return lastGoodNode

      discard insertExpression(container.Node, accessor.toJs.JsRoot, nil, nil)
    mount.dispose = disposer
    return mount

else:
  ## `-d:isonimHmr` not set — provide no-op stubs so app code can be
  ## written once and behave correctly in both modes. Generated JS contains
  ## no HMR machinery.
  type
    HmrRoot* = ref object
      dispose*: proc()
      onError*: proc(err: ref Exception)

  template hmrSignal*[T](initial: T): Signal[T] = createSignal(initial)

  proc renderHot*(
      code: proc(): Node, element: Element,
      onError: proc(err: ref Exception) = nil): HmrRoot =
    let root = HmrRoot(onError: onError)
    root.dispose = render(code, element)
    return root

  proc swap*(root: HmrRoot, newCode: proc(): Node) {.inline.} = discard

  proc registrySize*(root: HmrRoot): int = 0
  proc currentGeneration*(root: HmrRoot): int = 0

  type
    HmrMount* = ref object
      container*: Element
      dispose*: proc()
      onError*: proc(err: ref Exception)

  proc mountUiHot*(
      container: Element;
      factory: proc(): Node;
      onError: proc(err: ref Exception) = nil): HmrMount =
    ## Without `-d:isonimHmr`: route through the existing reactive
    ## `render` so the no-flag and with-flag mounts behave identically
    ## for the visible output. The HMR-specific machinery (slot
    ## subscriptions) is gone, so the factory is called once and any
    ## reactive reads inside it work exactly as in a hand-rolled mount.
    let mount = HmrMount(container: container, onError: onError)
    mount.dispose = render(factory, container)
    return mount
