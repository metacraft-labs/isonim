## A static `class` under a renderer whose document carries the app's
## stylesheet (`classesStyledByStylesheet`).
##
## On the C backend the `ui` macro expands a static class's Tailwind
## utilities into `setStyle` calls, for a native renderer with no stylesheet.
## `web/frame_renderer`'s renderer is compiled to C or WebAssembly but its
## frame is applied to a browser document that has the stylesheet, so it
## must receive the class alone — exactly what the same view sends under
## `nim js`. Before the fix, a WebAssembly core drew a `class="… hidden"`
## element with an inline `display: none` that its `nim js` twin did not,
## and the inline style outranked every later class change.
##
## Run by `just test-dsl` and `just test-frame-renderer` with
## `-d:tailwindStylesPathOverride=tests/dsl/tailwind/stylesheet-styles.json`,
## a map with the `hidden` and `p-2` entries the Tailwind extractor emits,
## so the expansion is exercised whatever `build/tailwind-styles.json`
## holds on the host. C backend only: under JS there is no expansion to
## suppress.
##
## MOCK POLICY (workspace rule: every mock justified in the header). The
## frame renderer is the production renderer, and its output is asserted
## by decoding the frame it wrote. `MockRenderer` (IsoNim's shipped
## in-memory `RendererBackend`) is the negative control: a renderer
## WITHOUT the declaration, which must still get the expansion.
## `SheetMock` wraps it to declare `classesStyledByStylesheet` and
## implement `createFromTemplate`, because no production renderer
## implements templates yet and the templated arm must honour the
## declaration too.

import std/[tables, unittest]

import isonim/core/owner
import isonim/testing/mock_dom
import isonim/dsl/[ui, templates, tailwind]
import isonim/web/frame_renderer
import dsl/stylesheet_generic_view

when defined(js):
  {.error: "C backend only: under JS a static class is never expanded".}

# --- Decoding the frame ----------------------------------------------------

proc manifestTable(): Table[int, string] =
  writeOpManifest()
  let b = frameBytes()
  var at = 0
  while at < b.len:
    let o = int(b[at]); inc at
    let n = int(b[at]) or (int(b[at+1]) shl 8) or (int(b[at+2]) shl 16) or
            (int(b[at+3]) shl 24)
    at += 4
    var s = newString(n)
    for i in 0 ..< n: s[i] = char(b[at + i])
    at += n
    result[o] = s
  wireReset()

proc shape(op: string): (int, int) =
  ## (handles, strings) per operation — the wire format.
  case op
  of "boCreateElement", "boCreateTextNode", "boSetTextContent",
     "boSetInnerHtml", "boRemoveAttribute", "boSetInputValue": (1, 1)
  of "boAppendChild", "boRemoveChild": (2, 0)
  of "boInsertBefore": (3, 0)
  of "boSetAttribute", "boSetStyle": (1, 2)
  of "boAddEventListener": (2, 1)
  of "boClearChildren", "boClearEventListeners", "boFocus": (1, 0)
  else: (0, 0)

type Op = tuple[op: string, strs: seq[string]]

proc decode(t: Table[int, string]): seq[Op] =
  let b = frameBytes()
  var at = 0
  proc u32(): int =
    result = int(b[at]) or (int(b[at+1]) shl 8) or (int(b[at+2]) shl 16) or
             (int(b[at+3]) shl 24)
    at += 4
  while at < b.len:
    let name = t[int(b[at])]; inc at
    let (h, s) = shape(name)
    var d: Op = (name, @[])
    for i in 0 ..< h: discard u32()
    for i in 0 ..< s:
      let n = u32()
      var str = newString(n)
      for j in 0 ..< n: str[j] = char(b[at + j])
      at += n
      d.strs.add str
    result.add d
  doAssert at == b.len, "the frame did not decode exactly"

proc styleOps(ops: seq[Op]): seq[seq[string]] =
  for d in ops:
    if d.op == "boSetStyle": result.add d.strs

proc classOps(ops: seq[Op]): seq[string] =
  for d in ops:
    if d.op == "boSetAttribute" and d.strs[0] == "class": result.add d.strs[1]

# --- A templating renderer that declares the stylesheet --------------------

type SheetMock = object
  m: MockRenderer

var lastTemplate: StaticTemplate

template classesStyledByStylesheet(r: SheetMock): bool = true
proc createElement(r: SheetMock; tag: string): MockNode = r.m.createElement(tag)
proc createTextNode(r: SheetMock; t: string): MockNode = r.m.createTextNode(t)
proc appendChild(r: SheetMock; p, c: MockNode) = r.m.appendChild(p, c)
proc setAttribute(r: SheetMock; n: MockNode; k, v: string) = r.m.setAttribute(n, k, v)
proc setStyle(r: SheetMock; n: MockNode; k, v: string) = r.m.setStyle(n, k, v)
proc createFromTemplate(r: SheetMock; tpl: StaticTemplate): seq[MockNode] =
  lastTemplate = tpl
  buildFromTemplate[MockRenderer, MockNode](r.m, tpl)

var plainTemplate: StaticTemplate
proc createFromTemplate(r: MockRenderer; tpl: StaticTemplate): seq[MockNode] =
  plainTemplate = tpl
  buildFromTemplate[MockRenderer, MockNode](r, tpl)

proc errorOverlayStyles(tpl: StaticTemplate): seq[(string, string)] =
  for n in tpl.nodes:
    if n.classes == "pane-error-overlay hidden": return n.styles
  doAssert false, "the template has no error overlay node"

# --- The tests -------------------------------------------------------------

suite "a static class under a renderer drawn through a stylesheet":
  test "the fixture map is the one loaded":
    check tailwindStyles["hidden"] == @[(prop: "display", val: "none")]

  test "FrameRenderer: the class crosses, its Tailwind expansion does not":
    let r = FrameRenderer()
    resetFrameRenderer()
    let t = manifestTable()
    createRoot proc(dispose: proc()) =
      discard ui(r):
        tdiv(class = "filesystem-error-overlay hidden p-2", role = "alert"):
          discard
      dispose()
    let ops = decode(t)
    check classOps(ops) == @["filesystem-error-overlay hidden p-2"]
    check styleOps(ops).len == 0

  test "FrameRenderer: an authored style attribute still crosses":
    let r = FrameRenderer()
    resetFrameRenderer()
    let t = manifestTable()
    createRoot proc(dispose: proc()) =
      discard ui(r):
        tdiv(class = "hidden", width = "12px"):
          discard
      dispose()
    check styleOps(decode(t)) == @[@["width", "12px"]]

  test "FrameRenderer: a generic view from a module with no renderer import":
    let r = FrameRenderer()
    resetFrameRenderer()
    let t = manifestTable()
    createRoot proc(dispose: proc()) =
      discard overlayView[FrameRenderer, FrameNode](r)
      dispose()
    let ops = decode(t)
    check "pane-error-overlay hidden" in classOps(ops)
    check styleOps(ops).len == 0

  test "control: a renderer without the declaration still gets the expansion":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = ui(r):
        tdiv(class = "filesystem-error-overlay hidden", role = "alert"):
          discard
      check root.attributes["class"] == "filesystem-error-overlay hidden"
      check root.styles["display"] == "none"
      dispose()

  test "templates: the declaring renderer gets the template without the expansion":
    createRoot proc(dispose: proc()) =
      let r = SheetMock(m: MockRenderer())
      let root = ui(r):
        tdiv(class = "pane"):
          tdiv(class = "pane-error-overlay hidden", role = "alert")
          tdiv(class = "pane-list"):
            text "rows"
      check errorOverlayStyles(lastTemplate).len == 0
      check root.children[0].attributes["class"] == "pane-error-overlay hidden"
      check root.children[0].styles.len == 0
      dispose()

  test "templates control: a renderer without the declaration keeps it":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = ui(r):
        tdiv(class = "pane"):
          tdiv(class = "pane-error-overlay hidden", role = "alert")
          tdiv(class = "pane-list"):
            text "rows"
      check errorOverlayStyles(plainTemplate) == @[("display", "none")]
      check root.children[0].styles["display"] == "none"
      dispose()
