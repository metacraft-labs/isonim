## The Web Worker target's message codec and build guard
## (isonim/web/worker.nim; IsoNim.md § Web Worker Target), on the JS
## backend under Node. The bridge itself, across a real worker thread, is
## tests/browser/specs/web-worker.spec.ts.
##
## No mocks: `toWire` / `fromWire` are pure, and the values are checked as
## the structured clone sees them (plain JS objects and arrays).

when not defined(js):
  {.error: "test_web_worker must be compiled with the JS backend".}

import std/[unittest, jsffi]
import isonim/web/worker

type
  Kind = enum kA, kB, kC
  Inner = object
    name: string
    weight: float
  Node = ref object
    label: string
    next: Node
  Message = object
    rev: int
    text: string
    ok: bool
    kind: Kind
    tags: seq[string]
    pair: (int, string)
    fixed: array[3, int]
    inner: Inner
    items: seq[Inner]
    chain: Node
    nothing: Node

proc jsonOf(v: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc structuredCloneOf(v: JsObject): JsObject {.importjs: "structuredClone(#)".}

suite "worker wire format":
  test "a message survives toWire, a structured clone and fromWire":
    let m = Message(rev: 7, text: "héllo <b>", ok: true, kind: kC,
      tags: @["x", "", "z"], pair: (3, "three"), fixed: [1, 2, 3],
      inner: Inner(name: "in", weight: 2.5),
      items: @[Inner(name: "a", weight: 1.0), Inner(name: "b", weight: -0.5)],
      chain: Node(label: "1", next: Node(label: "2")))
    let back = fromWire(structuredCloneOf(toWire(m)), Message)
    check back.rev == 7
    check back.text == "héllo <b>"
    check back.ok
    check back.kind == kC
    check back.tags == @["x", "", "z"]
    check back.pair == (3, "three")
    check back.fixed == [1, 2, 3]
    check back.inner == Inner(name: "in", weight: 2.5)
    check back.items == m.items
    check back.chain.label == "1" and back.chain.next.label == "2"
    check back.chain.next.next.isNil
    check back.nothing.isNil

  test "on the wire a message is plain JS data":
    let wire = toWire(Inner(name: "n", weight: 1.5))
    check $jsonOf(wire) == """{"name":"n","weight":1.5}"""
    check $jsonOf(toWire(@[kA, kB])) == "[0,1]"
    check $jsonOf(toWire(Node(nil))) == "null"

  test "serveWorker exists only in a worker build":
    # The main bundle has no worker loop to serve from: calling it is a
    # compile error naming -d:isonimWebWorker, not a silent no-op.
    proc handler(x: int): int = x
    check declared(serveWorker)
    check not compiles(serveWorker(handler))
    check compiles(newInlineBridge[int, int](handler))
    check not inWorkerScope()
