## test_frame_renderer.nim — `isonim/web/frame_renderer`: the command-frame
## renderer a WebAssembly core draws through.
##
## Runs on the C backend and under `nim js` (`just test-frame-renderer`).
## No mocks: the renderer is driven directly and through real reactive
## effects, and every assertion about what crossed is made by DECODING the
## frame it wrote, with the opcode table read from its own manifest — the
## same table the host applier builds from.

import std/[tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/web/frame_renderer

type
  DecodedOp = object
    op: string
    handles: seq[int]
    strs: seq[string]

proc manifestTable(): Table[int, string] =
  writeOpManifest()
  let b = frameBytes()
  var at = 0
  proc u32(): int =
    result = int(b[at]) or (int(b[at+1]) shl 8) or (int(b[at+2]) shl 16) or (int(b[at+3]) shl 24)
    at += 4
  while at < b.len:
    let ord = int(b[at]); inc at
    let n = u32()
    var s = newString(n)
    for i in 0 ..< n: s[i] = char(b[at + i])
    at += n
    result[ord] = s
  wireReset()

proc shape(op: string): (int, int) =
  ## (handles, strings) per operation — the wire format.
  case op
  of "boCreateElement", "boCreateTextNode", "boSetTextContent", "boSetInnerHtml",
     "boRemoveAttribute", "boSetInputValue": (1, 1)
  of "boAppendChild", "boRemoveChild": (2, 0)
  of "boInsertBefore": (3, 0)
  of "boSetAttribute", "boSetStyle": (1, 2)
  of "boAddEventListener": (2, 1)
  of "boClearChildren", "boClearEventListeners", "boFocus": (1, 0)
  else: (0, 0)

proc decode(table: Table[int, string]): seq[DecodedOp] =
  let b = frameBytes()
  var at = 0
  proc u32(): int =
    result = int(b[at]) or (int(b[at+1]) shl 8) or (int(b[at+2]) shl 16) or (int(b[at+3]) shl 24)
    at += 4
  while at < b.len:
    let name = table[int(b[at])]; inc at
    let (h, s) = shape(name)
    var d = DecodedOp(op: name)
    for i in 0 ..< h: d.handles.add u32()
    for i in 0 ..< s:
      let n = u32()
      var str = newString(n)
      for j in 0 ..< n: str[j] = char(b[at + j])
      at += n
      d.strs.add str
    result.add d
  doAssert at == b.len, "the frame did not decode exactly"

proc ops(t: Table[int, string]): seq[string] =
  for d in decode(t): result.add d.op

let r = FrameRenderer()

suite "the op manifest":
  test "names every BoundaryOp at its ordinal":
    let t = manifestTable()
    check t.len == ord(high(BoundaryOp)) + 1
    for o in BoundaryOp:
      check t[ord(o)] == $o

  test "leaves the frame empty for the next update":
    discard manifestTable()
    check wireBytes() == 0
    check wireOpCount() == 0

suite "same-value elision":
  setup:
    resetFrameRenderer()
    setFrameElision(true)
    let t = manifestTable()

  test "an attribute written twice with one value crosses once":
    let n = r.createElement("div")
    r.setAttribute(n, "class", "row selected")
    wireReset()
    r.setAttribute(n, "class", "row selected")
    check wireOpCount() == 0
    check wireBytes() == 0
    check elidedOps == 1
    r.setAttribute(n, "class", "row")
    check ops(t) == @["boSetAttribute"]
    check decode(t)[0].strs == @["class", "row"]

  test "removing an attribute makes the next write of it cross":
    let n = r.createElement("div")
    r.setAttribute(n, "title", "x")
    r.removeAttribute(n, "title")
    wireReset()
    r.setAttribute(n, "title", "x")
    check ops(t) == @["boSetAttribute"]

  test "attributes are tracked per node and per name":
    let a = r.createElement("div")
    let b = r.createElement("div")
    r.setAttribute(a, "class", "x")
    wireReset()
    r.setAttribute(b, "class", "x")
    r.setAttribute(a, "id", "x")
    check ops(t) == @["boSetAttribute", "boSetAttribute"]

  test "a style written twice with one value crosses once":
    let n = r.createElement("span")
    r.setStyle(n, "width", "12px")
    wireReset()
    r.setStyle(n, "width", "12px")
    check wireOpCount() == 0
    r.setStyle(n, "width", "13px")
    r.setStyle(n, "height", "13px")
    check ops(t) == @["boSetStyle", "boSetStyle"]

  test "text written twice crosses once; a text node starts known":
    let n = r.createElement("span")
    r.setTextContent(n, "42")
    let tn = r.createTextNode("abc")
    wireReset()
    r.setTextContent(n, "42")
    r.setTextContent(tn, "abc")
    check wireOpCount() == 0
    check elidedOps == 2
    r.setTextContent(tn, "abd")
    check ops(t) == @["boSetTextContent"]

  test "a child change makes the parent's next text write cross":
    for change in ["append", "insert", "remove", "html"]:
      let p = r.createElement("div")
      let c = r.createElement("b")
      r.setTextContent(p, "same")
      case change
      of "append": r.appendChild(p, c)
      of "insert": r.insertBefore(p, c, NoFrameNode)
      of "remove": r.removeChild(p, c)
      else: r.setInnerHtml(p, "<i>x</i>")
      wireReset()
      r.setTextContent(p, "same")
      check ops(t) == @["boSetTextContent"]

  test "clearChildren leaves the parent known to be empty":
    let p = r.createElement("div")
    r.setTextContent(p, "x")
    r.clearChildren(p)
    wireReset()
    r.setTextContent(p, "")
    check wireOpCount() == 0

  test "forgetHandle makes every tracked write cross again":
    let n = r.createElement("div")
    r.setAttribute(n, "class", "a")
    r.setStyle(n, "left", "1px")
    r.setTextContent(n, "t")
    forgetHandle(n)
    wireReset()
    r.setAttribute(n, "class", "a")
    r.setStyle(n, "left", "1px")
    r.setTextContent(n, "t")
    check ops(t) == @["boSetAttribute", "boSetStyle", "boSetTextContent"]

  test "an input's value is never elided":
    let n = r.createElement("input")
    r.setInputValue(n, "v")
    wireReset()
    r.setInputValue(n, "v")
    check ops(t) == @["boSetInputValue"]

  test "the mount point (handle 0) is never shadowed":
    r.setAttribute(NoFrameNode, "class", "x")
    r.setAttribute(NoFrameNode, "class", "x")
    check wireOpCount() == 2

  test "elided bytes plus written bytes equal the un-elided stream":
    proc scene(n: FrameNode) =
      r.setAttribute(n, "class", "row")
      r.setAttribute(n, "class", "row")
      r.setStyle(n, "padding-left", "16px")
      r.setStyle(n, "padding-left", "16px")
      r.setTextContent(n, "Record(id=1, stage='parse') — ünïcode")
      r.setTextContent(n, "Record(id=1, stage='parse') — ünïcode")
    setFrameElision(false)
    let a = r.createElement("div")
    wireReset()
    scene(a)
    let full = wireBytes()
    let fullOps = wireOpCount()
    setFrameElision(true)
    let b = r.createElement("div")
    wireReset()
    scene(b)
    check elidedOps == 3
    check wireOpCount() + elidedOps == fullOps
    check wireBytes() + elidedBytes == full

  test "with elision off every write crosses":
    setFrameElision(false)
    let n = r.createElement("div")
    wireReset()
    r.setAttribute(n, "class", "a")
    r.setAttribute(n, "class", "a")
    check wireOpCount() == 2
    check elidedOps == 0
    setFrameElision(true)

suite "a reactive row whose effect re-runs with its last value":
  test "crosses only for the rows whose value changed":
    resetFrameRenderer()
    let t = manifestTable()
    var rows: seq[FrameNode] = @[]
    let selected = createSignal(0)
    proc row(idx: int) =
      # A proc per row, so each effect closes over its own node and index.
      let n = r.createElement("div")
      rows.add n
      # Every row's class reads the selection, so every row's effect
      # re-runs on every step — the Call Trace shape.
      createRenderEffect proc() =
        let cls = if selected.val == idx: "call-line selected" else: "call-line"
        r.setAttribute(n, "class", cls)
    createRoot proc(dispose: proc()) =
      for i in 0 ..< 600: row(i)
    wireReset()
    selected.val = 1
    let d = decode(t)
    check d.len == 2
    check elidedOps == 598
    check d[0].handles == @[int(rows[0])]
    check d[0].strs == @["class", "call-line"]
    check d[1].handles == @[int(rows[1])]
    check d[1].strs == @["class", "call-line selected"]

suite "events":
  setup:
    resetFrameRenderer()
    resetFrameHandlers()
    let t = manifestTable()

  test "a listener crosses as node, callback id and event name":
    let n = r.createElement("button")
    wireReset()
    var clicks = 0
    r.addEventListener(n, "click", proc() = inc clicks)
    let d = decode(t)
    check d.len == 1
    check d[0].op == "boAddEventListener"
    check d[0].handles == @[int(n), 1]
    check d[0].strs == @["click"]
    check dispatchFrameEvent(1, "click", "", "", 0.0, 0) == 0
    check clicks == 1

  test "an input event's value answers inputValue without a crossing":
    let input = r.createElement("input")
    var seen = ""
    r.addEventListener(input, "input", proc() = seen = r.inputValue(input))
    discard dispatchFrameEvent(1, "input", "hello", "", 0.0, 0)
    check seen == "hello"
    check readCrossings == 0

  test "a value the core set answers inputValue too":
    let input = r.createElement("input")
    r.setInputValue(input, "draft")
    check r.inputValue(input) == "draft"
    check readCrossings == 0

  test "an unknown value is a read crossing":
    let input = r.createElement("input")
    discard r.inputValue(input)
    check readCrossings == 1

  test "the handler's flags go back to the host":
    let n = r.createElement("div")
    var got: FrameEvent
    r.addEventListener(n, "keydown", proc(ev: FrameEvent) =
      got = ev
      ev.preventDefault()
      ev.stopPropagation())
    let flags = dispatchFrameEvent(1, "keydown", "", "Enter", 0.0, 1 or 2)
    check flags == (FlagPreventDefault or FlagStopPropagation)
    check got.key == "Enter"
    check got.`type` == "keydown"
    check got.modifiers == {fmShift, fmCtrl}

  test "wheel and paste payloads reach the handler":
    let n = r.createElement("pre")
    var delta = 0.0
    var pasted = ""
    r.addEventListener(n, "wheel", proc(ev: FrameEvent) = delta = ev.deltaY)
    r.addEventListener(n, "paste", proc(ev: FrameEvent) = pasted = ev.value)
    check dispatchFrameEvent(1, "wheel", "", "", -120.0, 0) == 0
    check dispatchFrameEvent(2, "paste", "ls -la", "", 0.0, 0) == 0
    check delta == -120.0
    check pasted == "ls -la"

  test "a stale or out-of-range id dispatches nothing":
    let n = r.createElement("div")
    var calls = 0
    r.addEventListener(n, "click", proc() = inc calls)
    check dispatchFrameEvent(0, "click", "", "", 0.0, 0) == 0
    check dispatchFrameEvent(2, "click", "", "", 0.0, 0) == 0
    check calls == 0

suite "the read half":
  test "the tree reads count as crossings and answer nothing":
    resetFrameRenderer()
    let n = r.createElement("div")
    check r.firstChild(n).isNil
    check r.nextSibling(n).isNil
    check r.parentNode(n).isNil
    check r.getAttribute(n, "class") == ""
    check readCrossings == 4
