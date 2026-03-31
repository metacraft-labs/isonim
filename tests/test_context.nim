import unittest
import isonim/core/[types, graph, signals, owner, computation, batch, context,
  resource, suspense, transition]

suite "Context":
  test "createContext and useContext with default":
    createRoot proc(dispose: proc()) =
      let theme = createContext("light")
      check useContext(theme) == "light"

  test "provide overrides default":
    createRoot proc(dispose: proc()) =
      let theme = createContext("light")
      provide(theme, "dark")
      check useContext(theme) == "dark"

  test "nested provider overrides outer":
    createRoot proc(dispose: proc()) =
      let theme = createContext("light")
      provide(theme, "outer")
      check useContext(theme) == "outer"
      createRoot proc(dispose: proc()) =
        provide(theme, "inner")
        check useContext(theme) == "inner"
      # Back in outer scope
      check useContext(theme) == "outer"

  test "child inherits parent context":
    createRoot proc(dispose: proc()) =
      let lang = createContext("en")
      provide(lang, "fr")
      createRoot proc(dispose: proc()) =
        # No provide here -- should inherit parent
        check useContext(lang) == "fr"

suite "Resource":
  test "resource fetch lifecycle - ready":
    createRoot proc(dispose: proc()) =
      let r = createResource[int](proc(): int = 42)
      check r.val == 42
      check r.state.val == rsReady

  test "resource fetch lifecycle - error":
    createRoot proc(dispose: proc()) =
      let r = createResource[int](proc(): int =
        raise newException(CatchableError, "network error")
      )
      check r.state.val == rsErrored
      check r.error.val == "network error"

  test "resource with source refetches":
    createRoot proc(dispose: proc()) =
      var source = createSignal(1)
      var fetchCount = 0
      let r = createResource[int, int](
        proc(): int = source.val,
        proc(s: int): int =
          inc fetchCount
          s * 10
      )
      check r.val == 10
      check fetchCount == 1
      source.val = 2
      check r.val == 20
      check fetchCount == 2

  test "resource loading state":
    createRoot proc(dispose: proc()) =
      let r = createResource[int](proc(): int = 42)
      check r.loading == false  # Already resolved (synchronous)
      check r.state.val == rsReady

suite "Suspense":
  test "suspense tracks pending count":
    let ctx = newSuspenseContext()
    check ctx.inSuspense == false
    ctx.registerPending()
    check ctx.inSuspense == true
    ctx.registerPending()
    check ctx.pendingCount.val == 2
    ctx.resolvePending()
    check ctx.pendingCount.val == 1
    check ctx.inSuspense == true
    ctx.resolvePending()
    check ctx.inSuspense == false

suite "Transition":
  test "startTransition batches updates":
    createRoot proc(dispose: proc()) =
      var s = createSignal(0)
      var runCount = 0
      createEffect proc() =
        discard s.val
        inc runCount
      check runCount == 1
      startTransition proc() =
        s.val = 1
        s.val = 2
        s.val = 3
      check runCount == 2  # Batched -- one re-run

  test "useTransition pending signal":
    createRoot proc(dispose: proc()) =
      let (pending, start) = useTransition()
      check pending() == false
      # After start completes, pending should be false
      start proc() =
        discard
      check pending() == false
