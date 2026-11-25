## Owned roots: a `createRoot` made under an owner is one of that owner's
## children and is disposed with it, before the owner's own cleanups run
## (disposal unwinds); `createDetachedRoot` makes one that outlives its
## creator. A root disposed by hand is disposed once, whatever disposes its
## owner later, and errors raised under nested roots still reach the
## nearest handler above them.
##
## Real signals, effects, owners and flushes throughout; nothing in the
## graph is replaced. The boundary case renders into `MockRenderer`, the
## repository's in-memory renderer backend, because what it checks is which
## node the boundary shows, which needs a renderer but no real display (the
## same backend `test_error_routing` uses).

import unittest
import isonim/core/[graph, signals, owner, computation]
import isonim/testing/mock_dom
import isonim/dsl/components

suite "Owned roots":
  test "a child root is disposed with its parent":
    let s = createSignal(1)
    var seen: seq[int]
    var childCleanups = 0
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      createRoot proc(_: proc()) =
        onCleanup proc() = inc childCleanups
        createEffect proc() = seen.add s.val
    s.val = 2
    check seen == @[1, 2]
    disposeOuter()
    check childCleanups == 1
    s.val = 3
    check seen == @[1, 2]

  test "a detached root outlives its creator":
    let s = createSignal(1)
    var seen: seq[int]
    var detachedCleanups = 0
    var disposeOuter, disposeDetached: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      createDetachedRoot proc(dd: proc()) =
        disposeDetached = dd
        onCleanup proc() = inc detachedCleanups
        createEffect proc() = seen.add s.val
    disposeOuter()
    check detachedCleanups == 0
    s.val = 2
    check seen == @[1, 2]
    disposeDetached()
    check detachedCleanups == 1
    s.val = 3
    check seen == @[1, 2]

  test "dispose runs children before the owner's cleanups":
    var log: seq[string]
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      onCleanup proc() = log.add "outer-1"
      createEffect proc() =
        onCleanup proc() = log.add "effect"
      createRoot proc(_: proc()) =
        onCleanup proc() = log.add "child"
        createRoot proc(_: proc()) =
          onCleanup proc() = log.add "grandchild"
      onCleanup proc() = log.add "outer-2"
    disposeOuter()
    # Children first, the last created first (the grandchild before its
    # own owner's cleanup), then the owner's cleanups in the order they
    # were registered.
    check log == @["grandchild", "child", "effect", "outer-1", "outer-2"]

  test "a child root created inside an effect is disposed when it re-runs":
    let s = createSignal(1)
    var log: seq[string]
    var live = 0
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      createEffect proc() =
        let run = s.val
        createRoot proc(_: proc()) =
          inc live
          log.add "open " & $run
          onCleanup proc() =
            dec live
            log.add "close " & $run
    s.val = 2
    s.val = 3
    check log == @["open 1", "close 1", "open 2", "close 2", "open 3"]
    check live == 1
    disposeOuter()
    check live == 0
    check log[^1] == "close 3"

  test "a child root disposed by hand is not disposed again with its parent":
    var cleanups: array[3, int]
    var disposers: array[3, proc()]
    var outer: OwnerBase
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      outer = getOwner()
      for i in 0 .. 2:
        closureScope:
          let k = i
          createRoot proc(dd: proc()) =
            disposers[k] = dd
            onCleanup proc() = inc cleanups[k]
    check outer.owned.len == 3
    # Releasing the first moves the last into its place; releasing that
    # one next must still find it.
    disposers[0]()
    disposers[2]()
    check cleanups == [1, 0, 1]
    check outer.owned.len == 1
    disposers[0]()
    check cleanups == [1, 0, 1]
    disposeOuter()
    check cleanups == [1, 1, 1]
    # After the parent: no effect either.
    disposers[1]()
    disposers[2]()
    check cleanups == [1, 1, 1]

  test "a second dispose of a top-level or a detached root does nothing":
    var cleanups: array[2, int]
    var disposeTop, disposeDetached: proc()
    createRoot proc(d: proc()) =
      disposeTop = d
      onCleanup proc() = inc cleanups[0]
      createDetachedRoot proc(dd: proc()) =
        disposeDetached = dd
        onCleanup proc() = inc cleanups[1]
    disposeDetached()
    disposeDetached()
    check cleanups == [0, 1]
    disposeTop()
    disposeTop()
    check cleanups == [1, 1]

  test "a root released by a sibling's cleanup is disposed once":
    var cleanups: array[3, int]
    var disposers: array[3, proc()]
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      for i in 0 .. 2:
        closureScope:
          let k = i
          createRoot proc(dd: proc()) =
            disposers[k] = dd
            onCleanup proc() =
              inc cleanups[k]
              # The last child releases the first while its owner is being
              # disposed, which moves a sibling within the owner's list.
              if k == 2: disposers[0]()
    disposeOuter()
    check cleanups == [1, 1, 1]

  test "a re-run of the owner after a hand release keeps the list exact":
    let s = createSignal(0)
    var live = 0
    var disposers: seq[proc()]
    var owner: OwnerBase
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      createEffect proc() =
        discard s.val
        owner = getOwner()
        disposers.setLen(0)
        for i in 0 .. 3:
          createRoot proc(dd: proc()) =
            disposers.add dd
            inc live
            onCleanup proc() = dec live
    let first = disposers
    first[1]()
    check live == 3
    check owner.owned.len == 3
    s.val = 1
    check live == 4
    # Releasing a root of the previous run, whose slot a new root now
    # holds, leaves the new one alone.
    first[0]()
    first[3]()
    check live == 4
    check owner.owned.len == 4
    disposeOuter()
    check live == 0

  test "an error under nested owned roots reaches the nearest handler":
    let s = createSignal(1)
    let boom = newException(ValueError, "nested failure")
    var outerSaw, innerSaw: seq[ref CatchableError]
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      onError proc(e: ref CatchableError) = outerSaw.add e
      createRoot proc(_: proc()) =
        createRoot proc(_: proc()) =
          createEffect proc() =
            if s.val == 2: raise boom
        createRoot proc(_: proc()) =
          onError proc(e: ref CatchableError) = innerSaw.add e
          createEffect proc() =
            if s.val == 3: raise boom
    s.val = 2
    check outerSaw.len == 1
    check innerSaw.len == 0
    if outerSaw.len == 1: check outerSaw[0] == boom
    s.val = 3
    check outerSaw.len == 1
    check innerSaw.len == 1
    disposeOuter()

  test "a detached root still routes its errors to its creator's handler":
    let s = createSignal(1)
    var saw: seq[string]
    var disposeOuter, disposeDetached: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      onError proc(e: ref CatchableError) = saw.add e.msg
      createDetachedRoot proc(dd: proc()) =
        disposeDetached = dd
        createEffect proc() =
          if s.val == 2: raise newException(ValueError, "detached")
    s.val = 2
    check saw == @["detached"]
    disposeDetached()
    disposeOuter()

  test "a boundary catches a failure inside a nested root under its body":
    let r = MockRenderer()
    let host = r.createElement("div")
    let s = createSignal(1)
    var disposeOuter: proc()
    createRoot proc(d: proc()) =
      disposeOuter = d
      errorBoundary(r, host,
        body = proc(): MockNode =
          let content = r.createElement("p")
          createRoot proc(_: proc()) =
            createEffect proc() =
              if s.val == 2: raise newException(ValueError, "inner")
              r.setTextContent(content, "value " & $s.val)
          content,
        fallback = proc(err: ref CatchableError): MockNode =
          let n = r.createElement("span")
          r.setTextContent(n, "failed: " & err.msg)
          n)
    check host.children.len == 1
    check host.children[0].textContent == "value 1"
    s.val = 2
    check host.children.len == 1
    check host.children[0].textContent == "failed: inner"
    s.val = 3
    check host.children[0].textContent == "value 3"
    disposeOuter()
