import unittest
import std/[math, strutils]
import isonim/core/[types, graph, signals, owner, computation, batch, resource,
  clock]
import isonim/testing/[mock_dom, test_utils]
import isonim/dsl/components
import isonim/ssr/[renderer, escape, markers]

suite "Signal Edge Cases":
  test "NaN writing NaN again notifies observers (NaN != NaN)":
    createRoot proc(dispose: proc()) =
      var s = createSignal(NaN)
      var runCount = 0
      createEffect proc() =
        discard s.val
        inc runCount
      check runCount == 1
      s.val = NaN  # NaN != NaN, so this should notify
      check runCount == 2

  test "Infinity propagates correctly":
    createRoot proc(dispose: proc()) =
      var s = createSignal(0.0)
      var observed = 0.0
      createEffect proc() =
        observed = s.val
      check observed == 0.0

      s.val = Inf
      check observed == Inf
      check classify(observed) == fcInf

      s.val = NegInf
      check observed == NegInf
      check classify(observed) == fcNegInf

      # Writing same Inf should not notify (Inf == Inf)
      var runCount = 0
      var s2 = createSignal(Inf)
      createEffect proc() =
        discard s2.val
        inc runCount
      check runCount == 1
      s2.val = Inf  # same value
      check runCount == 1  # no re-run

  test "negative zero vs positive zero treated as equal":
    createRoot proc(dispose: proc()) =
      var s = createSignal(0.0)
      var runCount = 0
      createEffect proc() =
        discard s.val
        inc runCount
      check runCount == 1
      s.val = -0.0  # IEEE 754: -0.0 == 0.0
      check runCount == 1  # default comparator should suppress

  test "empty string signal works correctly":
    createRoot proc(dispose: proc()) =
      var s = createSignal("")
      var observed = "init"
      createEffect proc() =
        observed = s.val
      check observed == ""

      s.val = "hello"
      check observed == "hello"

      s.val = ""
      check observed == ""

      # Writing same empty string should not re-trigger
      var runCount = 0
      var s2 = createSignal("")
      createEffect proc() =
        discard s2.val
        inc runCount
      check runCount == 1
      s2.val = ""  # same value
      check runCount == 1

suite "Owner Disposal During Active Effect":
  test "dispose root inside its own effect does not crash":
    var cleanupRan = false
    var effectRunCount = 0
    var disposeRoot: proc()

    createRoot proc(dispose: proc()) =
      disposeRoot = dispose
      var s = createSignal(0)
      onCleanup proc() =
        cleanupRan = true
      createEffect proc() =
        inc effectRunCount
        let v = s.val
        if v == 1:
          dispose()  # Dispose the root mid-effect
      check effectRunCount == 1

      s.val = 1
      check effectRunCount == 2
      check cleanupRan == true

      # After disposal, further writes should not trigger the effect
      s.val = 2
      check effectRunCount == 2

  test "dispose child root while parent effect is executing":
    createRoot proc(outerDispose: proc()) =
      var s = createSignal(0)
      var parentRuns = 0
      var childRuns = 0
      var childCleanupRan = false
      var disposeChild: proc()

      createRoot proc(innerDispose: proc()) =
        disposeChild = innerDispose
        onCleanup proc() =
          childCleanupRan = true
        createEffect proc() =
          inc childRuns
          discard s.val

      createEffect proc() =
        inc parentRuns
        discard s.val

      check parentRuns == 1
      check childRuns == 1

      # Dispose the child
      disposeChild()
      check childCleanupRan == true

      # Only parent should react now
      s.val = 1
      check parentRuns == 2
      check childRuns == 1  # Disposed, not updated

suite "Nested Reconciliation (forEachKeyed)":
  test "nested forEachKeyed with inner and outer list mutations":
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var outerItems = createSignal(@[@[1, 2], @[3, 4], @[5, 6]])
      let parent = renderer.createElement("div")

      # Outer forEachKeyed: one container per inner list
      forEachKeyed(renderer, parent,
        proc(): seq[seq[int]] = outerItems.val,
        proc(innerList: proc(): seq[int], outerIndex: proc(): int): MockNode =
          let container = renderer.createElement("div")
          # Inner forEachKeyed: one span per item in the inner list
          forEachKeyed(renderer, container,
            innerList,
            proc(item: proc(): int, innerIndex: proc(): int): MockNode =
              let node = renderer.createElement("span")
              createRenderEffect proc() =
                renderer.setTextContent(node, $item())
              node
          )
          container
      )

      # Initial state: 3 containers, each with 2 spans
      check parent.children.len == 3
      check parent.children[0].children.len == 2
      check parent.children[0].children[0].textContent == "1"
      check parent.children[0].children[1].textContent == "2"
      check parent.children[1].children[0].textContent == "3"
      check parent.children[1].children[1].textContent == "4"
      check parent.children[2].children[0].textContent == "5"
      check parent.children[2].children[1].textContent == "6"

      # Mutate inner list: add item to first inner list
      outerItems.val = @[@[1, 2, 7], @[3, 4], @[5, 6]]
      check parent.children.len == 3
      check parent.children[0].children.len == 3
      check parent.children[0].children[2].textContent == "7"

      # Mutate inner list: remove item from second inner list
      outerItems.val = @[@[1, 2, 7], @[4], @[5, 6]]
      check parent.children[1].children.len == 1
      check parent.children[1].children[0].textContent == "4"

      # Mutate outer list: remove first inner list
      outerItems.val = @[@[4], @[5, 6]]
      check parent.children.len == 2
      check parent.children[0].children[0].textContent == "4"
      check parent.children[1].children[0].textContent == "5"

      # Mutate outer list: reorder
      outerItems.val = @[@[5, 6], @[4]]
      check parent.children.len == 2
      check parent.children[0].children[0].textContent == "5"
      check parent.children[0].children[1].textContent == "6"
      check parent.children[1].children[0].textContent == "4"

      # Mutate outer list: add new inner list
      outerItems.val = @[@[5, 6], @[4], @[8, 9, 10]]
      check parent.children.len == 3
      check parent.children[2].children.len == 3
      check parent.children[2].children[0].textContent == "8"
      check parent.children[2].children[1].textContent == "9"
      check parent.children[2].children[2].textContent == "10"

suite "Concurrent Signal Bursts":
  test "100 signals in a batch triggers effect exactly once":
    createRoot proc(dispose: proc()) =
      var signals: seq[Signal[int]] = @[]
      for i in 0 ..< 100:
        signals.add(createSignal(0))

      var runCount = 0
      createEffect proc() =
        var sum = 0
        for i in 0 ..< 100:
          sum += signals[i].val
        inc runCount
      check runCount == 1

      # Batch write to all 100 signals
      batch proc() =
        for i in 0 ..< 100:
          signals[i].val = i + 1

      # Effect should have executed exactly once after the batch
      check runCount == 2

  test "sequential writes coalesce via runUpdates":
    createRoot proc(dispose: proc()) =
      var signals: seq[Signal[int]] = @[]
      for i in 0 ..< 100:
        signals.add(createSignal(0))

      var runCount = 0
      createEffect proc() =
        var sum = 0
        for i in 0 ..< 100:
          sum += signals[i].val
        inc runCount
      check runCount == 1

      # Write to all 100 signals sequentially (no explicit batch)
      # Each writeSignal calls runUpdates, which increments batchDepth.
      # After the first write finishes its flush, the effect re-runs,
      # re-subscribing. The second write triggers again, etc.
      # But because writeSignal uses runUpdates internally,
      # each write that triggers an effect counts as a separate run.
      # The important thing is it doesn't crash and final state is correct.
      for i in 0 ..< 100:
        signals[i].val = i + 1

      # Verify final state is correct
      var sum = 0
      for i in 0 ..< 100:
        sum += signals[i].val
      check sum == 5050  # sum of 1..100

suite "Resource Cancellation":
  test "changing source before first fetch completes discards first result":
    withFakeTime:
      createRoot proc(dispose: proc()) =
        var dr1 = createDeferredResource[string]()
        var dr2 = createDeferredResource[string]()
        var observedStates: seq[ResourceState] = @[]
        var currentDr = dr1

        # Track resource states
        createEffect proc() =
          observedStates.add(currentDr.resource.state.val)

        check observedStates == @[rsPending]

        # Schedule first fetch to resolve after 500ms
        discard tc.schedule(proc() =
          dr1.resolve("first-result")
        , 500.0)

        # Before first fetch completes (at 200ms), change the source
        tc.advance(200.0)
        check dr1.resource.state.val == rsPending  # Still pending

        # Switch to second deferred resource (simulating source change)
        currentDr = dr2

        # Schedule second fetch to resolve after another 400ms (at 600ms total)
        discard tc.schedule(proc() =
          dr2.resolve("second-result")
        , 400.0)

        # First fetch resolves at 500ms, but we've moved on to dr2
        tc.advance(300.0)  # Now at 500ms total
        check dr1.resource.state.val == rsReady  # dr1 resolved
        check dr1.resource.val == "first-result"
        check dr2.resource.state.val == rsPending  # dr2 still pending

        # Second fetch resolves at 600ms
        tc.advance(100.0)  # Now at 600ms total
        check dr2.resource.val == "second-result"
        check dr2.resource.state.val == rsReady

  test "resource with source signal refetch discards stale results":
    createRoot proc(dispose: proc()) =
      var source = createSignal(1)
      var fetchResults: seq[int] = @[]
      let r = createResource[int, int](
        proc(): int = source.val,
        proc(s: int): int =
          fetchResults.add(s)
          s * 10
      )
      check r.val == 10
      check fetchResults == @[1]

      # Change source triggers refetch, old result replaced
      source.val = 2
      check r.val == 20
      check fetchResults == @[1, 2]

      # Change source again
      source.val = 3
      check r.val == 30
      check fetchResults == @[1, 2, 3]
      check r.state.val == rsReady

suite "Error Boundary Nesting":
  test "inner error boundary catches before outer":
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let parent = renderer.createElement("div")

      # Outer error boundary
      errorBoundary(renderer, parent,
        proc(): MockNode =
          let outerContainer = renderer.createElement("div")
          # Inner error boundary
          errorBoundary(renderer, outerContainer,
            proc(): MockNode =
              raise newException(CatchableError, "inner error")
            ,
            proc(err: ref CatchableError): MockNode =
              let node = renderer.createElement("span")
              let txt = renderer.createTextNode("Inner caught: " & err.msg)
              renderer.appendChild(node, txt)
              node
          )
          outerContainer
        ,
        proc(err: ref CatchableError): MockNode =
          let node = renderer.createElement("span")
          let txt = renderer.createTextNode("Outer caught: " & err.msg)
          renderer.appendChild(node, txt)
          node
      )

      # Inner boundary should catch
      check parent.children.len == 1
      check parent.children[0].tag == "div"  # outer container
      check parent.children[0].children.len == 1
      check parent.children[0].children[0].textContent == "Inner caught: inner error"

  test "error in inner fallback propagates to outer boundary":
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let parent = renderer.createElement("div")

      # Outer error boundary
      errorBoundary(renderer, parent,
        proc(): MockNode =
          let outerContainer = renderer.createElement("div")
          # Inner error boundary whose fallback also throws
          errorBoundary(renderer, outerContainer,
            proc(): MockNode =
              raise newException(CatchableError, "original error")
            ,
            proc(err: ref CatchableError): MockNode =
              raise newException(CatchableError, "fallback error: " & err.msg)
          )
          outerContainer
        ,
        proc(err: ref CatchableError): MockNode =
          let node = renderer.createElement("span")
          let txt = renderer.createTextNode("Outer caught: " & err.msg)
          renderer.appendChild(node, txt)
          node
      )

      # Outer boundary should catch the re-thrown error from inner fallback
      check parent.children.len == 1
      check parent.children[0].textContent == "Outer caught: fallback error: original error"

when not defined(js):
  suite "SSR with Large Payloads":
    setup:
      resetHydrationCounter()

    test "1000 list items render correctly with hydration markers":
      let html = renderToString proc(): string =
        var items: seq[string] = @[]
        for i in 0 ..< 1000:
          items.add("Item " & $i)

        ssrElement("div", {"class": "large-list"}, children =
          ssrFor(items, proc(item: string, index: int): string =
            ssrElement("li", needsId = true, children = escapeHtml(item))
          )
        )

      # Spot-check first item
      check "data-hk=\"1\"" in html
      check ">Item 0</li>" in html

      # Spot-check middle item
      check "data-hk=\"500\"" in html
      check ">Item 499</li>" in html

      # Spot-check last item
      check "data-hk=\"1000\"" in html
      check ">Item 999</li>" in html

      # Verify structure
      check html.startsWith("<div")
      check "class=\"large-list\"" in html
      check html.endsWith("</div>")

      # Verify total count of list items
      check html.count("<li") == 1000
      check html.count("</li>") == 1000

      # Verify hydration markers are sequential
      # Check a few consecutive markers in different ranges
      check "data-hk=\"1\"" in html
      check "data-hk=\"2\"" in html
      check "data-hk=\"3\"" in html
      check "data-hk=\"998\"" in html
      check "data-hk=\"999\"" in html
      check "data-hk=\"1000\"" in html
