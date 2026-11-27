## Error routing in the reactive core: a computation that raises does not
## stop the rest of its flush; its error goes to the nearest handler above it
## (`onError` on an owner, an effect's error arm, an error boundary); with no
## handler, the flush finishes and then rethrows the first error, the same
## object that was raised.
##
## Real signals, memos, effects, owners and flushes throughout; nothing in
## the graph is replaced. The boundary cases render into `MockRenderer`, the
## repository's in-memory renderer backend, because what they check is which
## node the boundary shows, which needs a renderer but no real display
## (the same backend `test_dsl` uses for the other control-flow components).
##
## A programming defect (a `Defect`) is the exception: it reaches no handler
## and no boundary and propagates as the same object, from a memo, an effect
## or an async value's service call, while an ordinary error raised in the
## same places is routed (for the service call, to the value's own failed
## state). The async cases use the real async value with a service call
## written inline and the nim-everywhere fake clock (`FakeAsyncContext`,
## stepped by the async tests' helper), so no real timer runs; nothing else
## is replaced.

import std/[strutils, unittest]
import nim_everywhere
import isonim/core/[signals, owner, computation, batch]
import isonim/services/async_value
import isonim/testing/mock_dom
import isonim/dsl/components

import helpers/async_recording_service  # `step`: the fake clock, one ms at a time

proc shownText(n: MockNode): string = n.textContent

suite "Error routing":
  test "a throwing memo does not stop an unrelated effect in the same flush":
    let a = createSignal(1)
    let boom = newException(ValueError, "memo failed")
    var unrelated: seq[int]
    var readerRuns = 0
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      let failing = createMemo(proc(): int =
        if a.val == 2: raise boom
        a.val * 10)
      # Queued ahead of the unrelated effect, so it fails first.
      createEffect proc() =
        inc readerRuns
        discard failing.val
      createEffect proc() =
        unrelated.add a.val
    unrelated = @[]
    var caught: ref Exception
    try:
      a.val = 2
    except ValueError as e:
      caught = e
    check caught == boom
    # The effect that does not read the memo saw the write.
    check unrelated == @[2]
    check readerRuns == 2
    a.val = 3
    check unrelated == @[2, 3]
    dispose()

  test "the error goes to the nearest handler; nested owners: nearest wins":
    let s = createSignal(0)
    var outerSeen, innerSeen: seq[string]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = outerSeen.add err.msg
      createEffect proc() =
        if s.val == 1: raise newException(ValueError, "outer effect")
      createRoot proc(_: proc()) =
        onError proc(err: ref CatchableError) = innerSeen.add err.msg
        createEffect proc() =
          if s.val == 1: raise newException(ValueError, "inner effect")
          # A computation owned by an effect: its owner chain passes
          # through the effect to the inner root's handler.
          createEffect proc() =
            if s.val == 2: raise newException(ValueError, "grandchild")
    s.val = 1
    check outerSeen == @["outer effect"]
    check innerSeen == @["inner effect"]
    s.val = 2
    check outerSeen == @["outer effect"]
    check innerSeen == @["inner effect", "grandchild"]
    dispose()

  test "an effect's error arm receives its errors before the owner's handler":
    let s = createSignal(0)
    var arm: seq[string]
    var rootSeen: seq[string]
    var values: seq[int]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = rootSeen.add err.msg
      proc run() =
        let v = s.val
        if v == 1: raise newException(ValueError, "effect run")
        values.add v
        createEffect proc() =
          if s.val == 2: raise newException(ValueError, "owned child")
      createEffectWithErrorArm(run, proc(err: ref CatchableError) = arm.add err.msg)
    s.val = 1
    s.val = 2
    check arm == @["effect run", "owned child"]
    check rootSeen.len == 0
    check values == @[0, 2]
    s.val = 3
    check values == @[0, 2, 3]
    check arm.len == 2
    dispose()

  test "with no handler the flush completes and rethrows the first error":
    let s = createSignal(0)
    let first = newException(ValueError, "first")
    let second = newException(IOError, "second")
    var runs: seq[string]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      createEffect proc() =
        if s.val == 1:
          runs.add "first"
          raise first
      createEffect proc() =
        if s.val == 1:
          runs.add "second"
          raise second
      createEffect proc() =
        if s.val == 1: runs.add "third"
    var caught: ref Exception
    try:
      s.val = 1
    except CatchableError as e:
      caught = e
    check caught == first
    check runs == @["first", "second", "third"]
    # The graph is usable afterwards, and a later flush has no stale error.
    s.val = 2
    check runs == @["first", "second", "third"]
    dispose()

  test "outside a flush, an error with no handler is raised at once":
    let failure = newException(ValueError, "initial run")
    var caught: ref Exception
    createRoot proc(dispose: proc()) =
      try:
        createEffect proc() = raise failure
      except ValueError as e:
        caught = e
      dispose()
    check caught == failure

  test "an error raised by a handler goes to the next handler above it":
    let s = createSignal(0)
    var outerSeen: seq[string]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = outerSeen.add err.msg
      createRoot proc(_: proc()) =
        onError proc(err: ref CatchableError) =
          raise newException(IOError, "handler failed on " & err.msg)
        createEffect proc() =
          if s.val == 1: raise newException(ValueError, "effect")
    s.val = 1
    check outerSeen == @["handler failed on effect"]
    dispose()

    # With nothing above it, the handler's error is the one rethrown.
    let t = createSignal(0)
    let handlerError = newException(IOError, "from the handler")
    var otherRan = false
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = raise handlerError
      createEffect proc() =
        if t.val == 1: raise newException(ValueError, "effect")
      createEffect proc() =
        if t.val == 1: otherRan = true
    var caught: ref Exception
    try:
      t.val = 1
    except IOError as e:
      caught = e
    check caught == handlerError
    check otherRan
    dispose()

  test "an error in a cleanup goes to the handler, and the run still happens":
    let s = createSignal(0)
    var seen: seq[string]
    var values: seq[int]
    var otherValues: seq[int]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = seen.add err.msg
      createEffect proc() =
        let v = s.val
        values.add v
        onCleanup proc() =
          if v == 0: raise newException(ValueError, "cleanup of run " & $v)
      createEffect proc() =
        otherValues.add s.val
    s.val = 1
    check seen == @["cleanup of run 0"]
    check values == @[0, 1]
    check otherValues == @[0, 1]
    s.val = 2
    check seen == @["cleanup of run 0"]
    check values == @[0, 1, 2]
    dispose()

  test "a memo that throws keeps the error and recovers on the next input":
    let a = createSignal(1)
    let boom = newException(ValueError, "no answer for 2")
    var seen: seq[int]
    var errors: seq[ref CatchableError]
    var m: Memo[int]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      m = createMemo(proc(): int =
        if a.val == 2: raise boom
        a.val * 10)
      proc run() = seen.add m.val
      createEffectWithErrorArm(run, proc(err: ref CatchableError) = errors.add err)
    a.val = 2
    check seen == @[10]
    check errors.len == 1
    check errors[0] == boom
    # Read outside any computation: the same object again.
    var direct: ref Exception
    try: discard m.val
    except ValueError as e: direct = e
    check direct == boom
    a.val = 3
    check seen == @[10, 30]
    check m.val == 30
    # Recovering to the value the memo had before it failed still counts as
    # a change for the readers that saw the error.
    a.val = 2
    a.val = 3
    check seen == @[10, 30, 30]
    check errors.len == 2
    dispose()

  test "a memo whose first run throws holds the error until it recovers":
    let a = createSignal(0)
    let boom = newException(ValueError, "not yet")
    var m: Memo[int]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      m = createMemo(proc(): int =
        if a.val == 0: raise boom
        a.val)
    var caught: ref Exception
    try: discard m.val
    except ValueError as e: caught = e
    check caught == boom
    a.val = 5
    check m.val == 5
    dispose()

  test "readers of an errored memo see the same error, and recover with it":
    let a = createSignal(1)
    let boom = newException(ValueError, "upstream")
    var armErrors: seq[ref CatchableError]
    var seen: seq[int]
    var downstream: Memo[int]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      let upstream = createMemo(proc(): int =
        if a.val == 2: raise boom
        a.val)
      downstream = createMemo(proc(): int = upstream.val + 100)
      proc run() = seen.add downstream.val
      createEffectWithErrorArm(run, proc(err: ref CatchableError) = armErrors.add err)
    a.val = 2
    # The error reached the effect through the memo that read the failing
    # one, as the same object, once.
    check armErrors.len == 1
    check armErrors[0] == boom
    var caught: ref Exception
    try: discard downstream.val
    except ValueError as e: caught = e
    check caught == boom
    check seen == @[101]
    a.val = 4
    check seen == @[101, 104]
    check armErrors.len == 1
    dispose()

  test "a Defect is not routed to handlers and still propagates unchanged":
    let s = createSignal(0)
    let defect = newException(AssertionDefect, "programming error")
    var handled = 0
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      onError proc(err: ref CatchableError) = inc handled
      createEffect proc() =
        if s.val == 1: raise defect
    var caught: ref Exception
    try:
      s.val = 1
    except AssertionDefect as e:
      caught = e
    check caught == defect
    check handled == 0
    dispose()

suite "Error boundary":
  test "a re-run failure shows the fallback; a new answer brings the content back":
    let r = MockRenderer()
    let s = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    var content: MockNode
    createRoot proc(stop: proc()) =
      dispose = stop
      r.appendChild(parent, r.createTextNode("before"))
      proc body(): MockNode =
        content = r.createElement("span")
        let label = r.createTextNode("")
        r.appendChild(content, label)
        createRenderEffect proc() =
          let v = s.val
          if v mod 2 == 1: raise newException(ValueError, "odd " & $v)
          r.setTextContent(label, "value " & $v)
        content
      proc fallback(err: ref CatchableError): MockNode =
        r.createTextNode("failed: " & err.msg)
      errorBoundary(r, parent, body, fallback)
      r.appendChild(parent, r.createTextNode("after"))
    check parent.children.len == 3
    check parent.children[1] == content
    check content.shownText == "value 0"
    s.val = 1
    check parent.children.len == 3
    check parent.children[1].shownText == "failed: odd 1"
    check parent.children[2].shownText == "after"
    s.val = 3
    check parent.children[1].shownText == "failed: odd 3"
    s.val = 4
    check parent.children.len == 3
    check parent.children[1] == content
    check content.shownText == "value 4"
    check parent.children[2].shownText == "after"
    dispose()

  test "a failure in the first run of a computation under it shows the fallback, then recovers":
    let r = MockRenderer()
    let a = createSignal(2)
    let parent = r.createElement("div")
    var dispose: proc()
    var answer: Memo[int]
    createRoot proc(stop: proc()) =
      dispose = stop
      # A memo outside the boundary (a ViewModel's, say) that fails; the
      # View inside the boundary reads it.
      answer = createMemo(proc(): int =
        if a.val == 2: raise newException(ValueError, "service down")
        a.val)
      proc body(): MockNode =
        let node = r.createElement("p")
        createRenderEffect proc() =
          r.setTextContent(node, "answer " & $answer.val)
        node
      proc fallback(err: ref CatchableError): MockNode =
        r.createTextNode("error: " & err.msg)
      errorBoundary(r, parent, body, fallback)
    check parent.children.len == 1
    check parent.children[0].shownText == "error: service down"
    a.val = 7
    check parent.children.len == 1
    check parent.children[0].tag == "p"
    check parent.children[0].shownText == "answer 7"
    a.val = 2
    check parent.children[0].shownText == "error: service down"
    dispose()

  test "an inner boundary takes a re-run failure before the outer one":
    let r = MockRenderer()
    let s = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    var outerFallbacks = 0
    createRoot proc(stop: proc()) =
      dispose = stop
      proc innerBody(): MockNode =
        let node = r.createElement("span")
        createRenderEffect proc() =
          if s.val == 1: raise newException(ValueError, "inner")
          r.setTextContent(node, "ok")
        node
      proc innerFallback(err: ref CatchableError): MockNode =
        r.createTextNode("inner caught " & err.msg)
      proc outerBody(): MockNode =
        let box = r.createElement("section")
        errorBoundary(r, box, innerBody, innerFallback)
        box
      proc outerFallback(err: ref CatchableError): MockNode =
        inc outerFallbacks
        r.createTextNode("outer caught " & err.msg)
      errorBoundary(r, parent, outerBody, outerFallback)
    s.val = 1
    check outerFallbacks == 0
    check parent.children[0].tag == "section"
    check parent.children[0].children[0].shownText == "inner caught inner"
    s.val = 2
    check parent.children[0].children[0].shownText == "ok"
    dispose()

  test "disposing the boundary disposes its content and its fallback":
    let r = MockRenderer()
    let s = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    var contentRuns, fallbackRuns = 0
    createRoot proc(stop: proc()) =
      dispose = stop
      proc body(): MockNode =
        createRenderEffect proc() =
          inc contentRuns
          if s.val == 1: raise newException(ValueError, "x")
        r.createElement("span")
      proc fallback(err: ref CatchableError): MockNode =
        createRenderEffect proc() =
          discard s.val
          inc fallbackRuns
        r.createTextNode("fallback")
      errorBoundary(r, parent, body, fallback)
    s.val = 1
    check contentRuns == 2
    check fallbackRuns == 1
    dispose()
    s.val = 0
    s.val = 1
    check contentRuns == 2
    check fallbackRuns == 1

  test "the content comes back only when every failed computation has recovered":
    let r = MockRenderer()
    let a = createSignal(0)
    let b = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    var fallbacks = 0
    var content: MockNode
    createRoot proc(stop: proc()) =
      dispose = stop
      proc body(): MockNode =
        content = r.createElement("p")
        createRenderEffect proc() =
          if a.val == 1: raise newException(ValueError, "a")
        createRenderEffect proc() =
          if b.val == 1: raise newException(ValueError, "b")
        content
      proc fallback(err: ref CatchableError): MockNode =
        inc fallbacks
        r.createTextNode("failed: " & err.msg)
      errorBoundary(r, parent, body, fallback)
    batch proc() =
      a.val = 1
      b.val = 1
    check parent.children[0].shownText == "failed: b"
    # One of the two recovers: the other still fails, so the fallback stays.
    a.val = 2
    check parent.children[0].shownText == "failed: b"
    b.val = 2
    check parent.children[0] == content
    check parent.children.len == 1
    check fallbacks == 2
    dispose()

  test "one failing memo read by several computations shows the fallback once":
    let r = MockRenderer()
    let a = createSignal(1)
    let parent = r.createElement("div")
    var dispose: proc()
    var fallbacks = 0
    createRoot proc(stop: proc()) =
      dispose = stop
      let answer = createMemo(proc(): int =
        if a.val == 2: raise newException(ValueError, "no answer")
        a.val)
      proc body(): MockNode =
        let node = r.createElement("p")
        createRenderEffect proc() = discard answer.val
        createRenderEffect proc() = discard answer.val
        createRenderEffect proc() = discard answer.val
        node
      proc fallback(err: ref CatchableError): MockNode =
        inc fallbacks
        r.createTextNode(err.msg)
      errorBoundary(r, parent, body, fallback)
    a.val = 2
    check fallbacks == 1
    check parent.children[0].shownText == "no answer"
    a.val = 3
    check parent.children[0].tag == "p"
    dispose()

  test "a failed computation that is disposed no longer holds the fallback":
    let r = MockRenderer()
    let showInner = createSignal(true)
    let a = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    var content: MockNode
    createRoot proc(stop: proc()) =
      dispose = stop
      proc body(): MockNode =
        content = r.createElement("p")
        createRenderEffect proc() =
          if showInner.val:
            createRenderEffect proc() =
              if a.val == 1: raise newException(ValueError, "inner")
        createRenderEffect proc() =
          if a.val == 1: raise newException(ValueError, "sibling")
        content
      proc fallback(err: ref CatchableError): MockNode =
        r.createTextNode(err.msg)
      errorBoundary(r, parent, body, fallback)
    a.val = 1
    check parent.children[0].shownText != ""
    # The inner effect goes away while failing; the sibling then recovers.
    showInner.val = false
    a.val = 2
    check parent.children[0] == content
    dispose()

  test "a fallback that raises passes its error to the boundary above":
    let r = MockRenderer()
    let s = createSignal(0)
    let parent = r.createElement("div")
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      proc innerBody(): MockNode =
        let node = r.createElement("span")
        createRenderEffect proc() =
          if s.val == 1: raise newException(ValueError, "inner")
        node
      proc innerFallback(err: ref CatchableError): MockNode =
        raise newException(IOError, "fallback failed on " & err.msg)
      proc outerBody(): MockNode =
        let box = r.createElement("section")
        errorBoundary(r, box, innerBody, innerFallback)
        box
      proc outerFallback(err: ref CatchableError): MockNode =
        r.createTextNode("outer caught " & err.msg)
      errorBoundary(r, parent, outerBody, outerFallback)
    s.val = 1
    check parent.children.len == 1
    check parent.children[0].shownText == "outer caught fallback failed on inner"
    # The failing computation recovers: both boundaries hear of it.
    s.val = 2
    check parent.children[0].tag == "section"
    dispose()

suite "Handler registration":
  test "onError in an effect that re-runs replaces its handler, not adds one":
    let s = createSignal(0)
    var calls: seq[string]
    var dispose: proc()
    createRoot proc(stop: proc()) =
      dispose = stop
      createEffect proc() =
        let v = s.val
        onError proc(err: ref CatchableError) = calls.add($v & ":" & err.msg)
        createEffect proc() =
          if s.val == 2: raise newException(ValueError, "child")
    s.val = 1
    s.val = 2
    check calls == @["2:child"]
    dispose()

type
  Place = enum
    ## Where the exception is raised.
    inMemo = "a memo", inEffect = "an effect",
    inAsyncCall = "an async value's service call"
  Catcher = enum
    ## What would catch it if it were routed.
    byOnError = "an onError handler", byBoundary = "an error boundary"

suite "Defects are not routed":
  # The trigger `s` selects what is raised: 1 an ordinary error, 2 the
  # defect; any other value is a plain answer. Each case checks that the
  # ordinary error is routed, then recovers, then that the defect is not
  # routed and surfaces as the object that was raised, and that the graph
  # still answers afterwards.
  for place in Place:
    for catcher in Catcher:
      test "a Defect in " & $place & " does not reach " & $catcher &
          "; an ordinary error there is routed":
        let ctx = newFakeAsyncContext()
        ctx.install()
        defer: ctx.uninstall()
        let s = createSignal(0)
        let defect = newException(AssertionDefect, "programming error")
        var handled: seq[string]       # what onError or the fallback got
        var shownValues: seq[string]   # what the reading effect showed
        var av: AsyncValue[string]
        proc compute(n: int): string =
          if n == 1: raise newException(ValueError, "ordinary " & $n)
          if n == 2: raise defect
          "value " & $n
        proc build() =
          # The place, built under the current owner (the root with the
          # handler, or the boundary's body).
          case place
          of inMemo:
            let m = createMemo(proc(): string = compute(s.val))
            createEffect proc() = shownValues.add m.val
          of inEffect:
            createEffect proc() = shownValues.add compute(s.val)
          of inAsyncCall:
            av = createAsync(proc(): int = s.val,
              proc(n: int): PlatformFuture[string] =
                newCompletedFuture(compute(n)))
            createEffect proc() = shownValues.add av.val
        let r = MockRenderer()
        let parent = r.createElement("div")
        var dispose: proc()
        createRoot proc(stop: proc()) =
          dispose = stop
          case catcher
          of byOnError:
            onError proc(err: ref CatchableError) = handled.add err.msg
            build()
          of byBoundary:
            proc body(): MockNode =
              build()
              r.createTextNode("content")
            proc fallback(err: ref CatchableError): MockNode =
              handled.add err.msg
              r.createTextNode("fallback: " & err.msg)
            errorBoundary(r, parent, body, fallback)
        proc showsFallback(): bool =
          catcher == byBoundary and parent.children.len == 1 and
            parent.children[0].shownText.startsWith("fallback")
        ctx.step(1)
        check handled.len == 0
        check shownValues[^1] == "value 0"

        # An ordinary error is routed and the flush completes.
        var escaped: ref Exception
        try:
          s.val = 1
          ctx.step(1)
        except Exception as e:
          escaped = e
        check escaped == nil
        if place == inAsyncCall:
          # The primitive takes a failing call as the question's answer: a
          # failed state the View reads, not an error of the graph.
          check av.status == AsyncStatus.failed
          check av.error == "ordinary 1"
          check handled.len == 0
          check not showsFallback()
        else:
          check handled == @["ordinary 1"]
          check showsFallback() == (catcher == byBoundary)
        s.val = 0
        ctx.step(1)
        check shownValues[^1] == "value 0"
        check not showsFallback()
        let handledBefore = handled.len

        # A Defect is not routed: it leaves the write as the same object.
        var caught: ref Exception
        try:
          s.val = 2
          ctx.step(1)
        except AssertionDefect as e:
          caught = e
        check caught == defect
        check handled.len == handledBefore
        check not showsFallback()
        if place == inAsyncCall:
          # Nor is it taken as the question's failed answer.
          check av.status != AsyncStatus.failed
          check av.error == ""

        # The graph still answers the next change.
        s.val = 3
        ctx.step(1)
        check shownValues[^1] == "value 3"
        check handled.len == handledBefore
        check not showsFallback()
        dispose()
