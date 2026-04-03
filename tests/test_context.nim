import unittest
import isonim/core/[types, graph, signals, owner, computation, batch, context,
  resource, suspense, transition, clock]
import isonim/testing/test_utils

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
      let source = createSignal(1)
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
      let s = createSignal(0)
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

suite "Resource with TestClock":
  test "deferred resource starts pending":
    createRoot proc(dispose: proc()) =
      let dr = createDeferredResource[int]()
      check dr.resource.state.val == rsPending
      check dr.resource.loading == true
      check dr.resource.val == 0  # default

  test "deferred resource resolves":
    createRoot proc(dispose: proc()) =
      let dr = createDeferredResource[int]()
      dr.resolve(42)
      check dr.resource.val == 42
      check dr.resource.state.val == rsReady
      check dr.resource.loading == false

  test "deferred resource rejects":
    createRoot proc(dispose: proc()) =
      let dr = createDeferredResource[int]()
      dr.reject("timeout")
      check dr.resource.state.val == rsErrored
      check dr.resource.error.val == "timeout"

  test "deferred resource with scheduled resolution":
    ## Resource resolves after simulated delay via TestClock
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let dr = createDeferredResource[string]()
        check dr.resource.state.val == rsPending

        # Schedule resolution after 500ms
        discard tc.schedule(proc() =
          dr.resolve("loaded data")
        , 500.0)

        # Time hasn't advanced yet
        check dr.resource.state.val == rsPending

        # Advance past the scheduled time
        tc.advance(500.0)
        check dr.resource.val == "loaded data"
        check dr.resource.state.val == rsReady

  test "deferred resource with scheduled rejection":
    ## Resource errors after simulated timeout
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let dr = createDeferredResource[int]()

        discard tc.schedule(proc() =
          dr.reject("request timeout")
        , 1000.0)

        tc.advance(500.0)
        check dr.resource.state.val == rsPending  # Not yet

        tc.advance(500.0)
        check dr.resource.state.val == rsErrored
        check dr.resource.error.val == "request timeout"

  test "multiple deferred resources with staggered resolution":
    ## Two resources resolve at different times
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let dr1 = createDeferredResource[string]()
        let dr2 = createDeferredResource[string]()

        discard tc.schedule(proc() = dr1.resolve("first"), 100.0)
        discard tc.schedule(proc() = dr2.resolve("second"), 300.0)

        tc.advance(100.0)
        check dr1.resource.state.val == rsReady
        check dr1.resource.val == "first"
        check dr2.resource.state.val == rsPending

        tc.advance(200.0)
        check dr2.resource.state.val == rsReady
        check dr2.resource.val == "second"

suite "Suspense with deferred resources":
  test "suspense boundary tracks deferred resources":
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let ctx = newSuspenseContext()
        let dr = createDeferredResource[string]()

        ctx.registerPending()
        check ctx.inSuspense == true

        discard tc.schedule(proc() =
          dr.resolve("data")
          ctx.resolvePending()
        , 200.0)

        check ctx.inSuspense == true
        tc.advance(200.0)
        check ctx.inSuspense == false
        check dr.resource.val == "data"

  test "suspense with multiple pending resources":
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let ctx = newSuspenseContext()
        let dr1 = createDeferredResource[int]()
        let dr2 = createDeferredResource[int]()

        ctx.registerPending()
        ctx.registerPending()
        check ctx.pendingCount.val == 2

        discard tc.schedule(proc() =
          dr1.resolve(1)
          ctx.resolvePending()
        , 100.0)

        discard tc.schedule(proc() =
          dr2.resolve(2)
          ctx.resolvePending()
        , 300.0)

        tc.advance(100.0)
        check ctx.inSuspense == true  # Still 1 pending
        check ctx.pendingCount.val == 1

        tc.advance(200.0)
        check ctx.inSuspense == false  # All resolved
        check dr1.resource.val == 1
        check dr2.resource.val == 2

suite "Transition with TestClock":
  test "transition pending tracks deferred work":
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let (pending, start) = useTransition()
        let s = createSignal(0)
        var completed = false

        # Start a transition that schedules deferred work
        start proc() =
          s.val = 1

        # Since useTransition is synchronous batch, pending goes true then false
        check pending() == false
        check s.val == 1

  test "effect observes deferred resource state changes":
    ## An effect tracking resource state fires when resource resolves
    withFakeTime:
      createRoot proc(dispose: proc()) =
        let dr = createDeferredResource[string]()
        var observedStates: seq[ResourceState] = @[]

        createEffect proc() =
          observedStates.add(dr.resource.state.val)

        check observedStates == @[rsPending]

        discard tc.schedule(proc() =
          dr.resolve("done")
        , 100.0)

        tc.advance(100.0)
        check observedStates == @[rsPending, rsReady]
        check dr.resource.val == "done"
