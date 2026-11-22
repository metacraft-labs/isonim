## frame_renderer.nim — a renderer for a ViewModel core that cannot hold a DOM
## node: WebAssembly, or any core that runs apart from the document.
##
## ## WHAT IT IS
##
## A `RendererBackend` whose element handle is a **u32 index**, not a node.
## Every operation is appended to a flat byte frame in the core's own memory;
## the host reads the frame once per update and applies it to a real document
## with `frame_applier.js`, which holds the node table this module cannot.
##
## The boundary is **write-only**. IsoNim's reconciler keeps the node
## references it created instead of navigating back through the renderer, so
## `firstChild`, `nextSibling`, `parentNode` and `getAttribute` are never
## called on a rendering path. Each of them increments `readCrossings`, so a
## caller that starts relying on one is visible: a consumer that publishes a
## timing over this boundary should refuse to while the counter is non-zero.
##
## ## SAME-VALUE ELISION
##
## An effect that re-runs with the value it wrote last — a row whose class
## reads the selection, re-evaluated on every step — must not cross. The
## `WebRenderer` skips such a write by reading the DOM; this renderer cannot
## read the DOM, so it keeps a **shadow** of what it last wrote per handle:
## attributes, style properties and text. `setAttribute`, `setStyle` and
## `setTextContent` with the value already in the shadow put nothing in the
## frame. A Call Trace step over 600 rows crossed 1,800 operations without
## this, because every row's class effect re-ran.
##
## The shadow is exact only while the core is the one writer of the
## properties it tracks. It is invalidated where the DOM can diverge from it:
##
##   - `removeAttribute` drops the attribute from the shadow;
##   - `appendChild`, `insertBefore`, `removeChild`, `clearChildren` and
##     `setInnerHtml` change a node's `textContent`, so they drop the
##     PARENT's text shadow (the child keeps its own);
##   - a host that writes a tracked property itself (a decoration that sets
##     a style the core also sets) calls `forgetHandle` for that node.
##
## `elidedOps` / `elidedBytes` count what was skipped, so a byte meter that
## counts every operation the view ISSUED still balances:
## `wireBytes() + elidedBytes == meter.totalBytes()`.
## `setFrameElision(false)` turns the shadow off for a caller that wants the
## un-elided stream.
##
## ## THE WIRE
##
## Byte-for-byte the format `isonim/core/boundary_meter` counts: one `u8`
## opcode (`ord(BoundaryOp)`), then the operation's handles as little-endian
## `u32`s and its strings as `u32` length plus UTF-8 bytes.
##
## `writeOpManifest` replaces the frame with the opcode table — one record per
## `BoundaryOp`, its ordinal and its name — so the host builds its dispatch
## from the module instead of from a second copy of the enum.
##
## ## EVENTS
##
## A handler is a closure inside the core, so what crosses is a callback id.
## `AddEventListener` carries the node, the id and the event name. The host
## calls back in with `dispatchFrameEvent(id, eventType, value, key, deltaY,
## modifiers)`; the payload carries what a handler would otherwise have to
## read across the boundary:
##
##   - `value`: the target's current value for `input`, `change`, `blur`,
##     `focus` and `submit` (the form's first input), and the pasted text for
##     `paste`. It is recorded as the node's value, so `inputValue(node)` on
##     the target is answered in the core — no crossing;
##   - `key` for keyboard events, `deltaY` for `wheel`, and the modifier
##     keys as `FrameModifier` bits.
##
## The flags a handler sets — `preventDefault`, `stopPropagation` — are
## returned to the host, which applies them to the real event.
##
## ## HANDLES
##
## Allocated by a counter starting at 1, so 0 means "no node" (the host's
## mount point). The host allocates the matching slot when it applies a
## `CreateElement` / `CreateTextNode`, so the two tables agree by
## construction and this module never reads one back.

import std/tables

import ../core/boundary_meter

export boundary_meter.BoundaryOp

type
  FrameNode* = distinct int32
    ## A handle into the host's node table. `0` means "none".

  FrameRenderer* = object
    ## Stateless: the frame, the handle counter and the shadow are module
    ## state, because there is exactly one boundary per module instance.

  FrameModifier* = enum
    fmShift, fmCtrl, fmAlt, fmMeta

  FrameEvent* = ref object
    ## What crossed with an event, and what the handler asked the host to do.
    ## The browser `Event` itself stays in the host.
    `type`*: string
    value*: string
    key*: string
    deltaY*: float
    modifiers*: set[FrameModifier]
    defaultPrevented*: bool
    propagationStopped*: bool

proc `==`*(a, b: FrameNode): bool {.borrow.}
proc `$`*(a: FrameNode): string {.borrow.}

const NoFrameNode* = FrameNode(0)

proc isNil*(n: FrameNode): bool {.inline.} = int32(n) == 0

template classesStyledByStylesheet*(r: FrameRenderer): bool =
  ## The frame is applied to a browser document that carries the app's
  ## stylesheet, so the `ui` macro sets a static `class` alone and does not
  ## expand its Tailwind utilities into `setStyle` calls, as it does not
  ## under JS. Without this a core compiled to WebAssembly drew
  ## `class="… hidden"` with an inline `display: none` the `nim js` build of
  ## the same core does not, and that inline style outranked every later
  ## class change the stylesheet should have shown.
  true

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

when defined(js):
  {.emit: """
var isonimFrame_enc = new TextEncoder();
var isonimFrame_buf = new Uint8Array(1 << 20);
var isonimFrame_len = 0;
function isonimFrame_ensure(n) {
  if (isonimFrame_len + n > isonimFrame_buf.length) {
    var grown = new Uint8Array(Math.max(isonimFrame_buf.length * 2, isonimFrame_len + n));
    grown.set(isonimFrame_buf);
    isonimFrame_buf = grown;
  }
}
function isonimFrame_reset() { isonimFrame_len = 0; }
function isonimFrame_flen() { return isonimFrame_len; }
function isonimFrame_u8(v) { isonimFrame_ensure(1); isonimFrame_buf[isonimFrame_len++] = v & 0xff; }
function isonimFrame_u32(v) {
  isonimFrame_ensure(4);
  isonimFrame_buf[isonimFrame_len++] = v & 0xff;
  isonimFrame_buf[isonimFrame_len++] = (v >>> 8) & 0xff;
  isonimFrame_buf[isonimFrame_len++] = (v >>> 16) & 0xff;
  isonimFrame_buf[isonimFrame_len++] = (v >>> 24) & 0xff;
}
function isonimFrame_str(s) {
  var bytes = isonimFrame_enc.encode(s);
  isonimFrame_u32(bytes.length);
  isonimFrame_ensure(bytes.length);
  isonimFrame_buf.set(bytes, isonimFrame_len);
  isonimFrame_len += bytes.length;
}
function isonimFrame_utf8len(s) { return isonimFrame_enc.encode(s).length; }
// The host reads the frame through this. Under `nim js` the frame IS a JS
// Uint8Array, so there is no address to hand over and no copy to make.
if (typeof globalThis !== 'undefined') {
  globalThis.isonimFrameBytes = function() { return isonimFrame_buf.subarray(0, isonimFrame_len); };
}
""".}
  proc wireResetRaw() {.importjs: "isonimFrame_reset()".}
  proc wireBytes*(): int {.importjs: "isonimFrame_flen()".}
  proc wirePutU8*(v: int) {.importjs: "isonimFrame_u8(#)".}
  proc wirePutU32*(v: int) {.importjs: "isonimFrame_u32(#)".}
  proc wirePutStrRaw(s: cstring) {.importjs: "isonimFrame_str(#)".}
  proc utf8LenRaw(s: cstring): int {.importjs: "isonimFrame_utf8len(#)".}
  proc wirePutStr*(s: string) {.inline.} = wirePutStrRaw(cstring(s))
  proc wireStrBytes(s: string): int {.inline.} = 4 + utf8LenRaw(cstring(s))
  proc wireBase*(): int {.inline.} = 0
    ## No address: the frame is a JS array. See `globalThis.isonimFrameBytes`.

  proc frameByteAt(i: int): int {.importjs: "isonimFrame_buf[#]".}

  proc frameBytes*(): seq[byte] =
    ## A copy of the current frame, for a Nim-side decoder (tests).
    let n = wireBytes()
    result = newSeq[byte](n)
    for i in 0 ..< n:
      result[i] = byte(frameByteAt(i))

else:
  var wireBuf: seq[byte] = newSeqOfCap[byte](1 shl 20)

  proc wireResetRaw() {.inline.} = wireBuf.setLen(0)
  proc wireBytes*(): int {.inline.} = wireBuf.len
  proc wirePutU8*(v: int) {.inline.} = wireBuf.add byte(v and 0xff)
  proc wirePutU32*(v: int) {.inline.} =
    wireBuf.add byte(v and 0xff)
    wireBuf.add byte((v shr 8) and 0xff)
    wireBuf.add byte((v shr 16) and 0xff)
    wireBuf.add byte((v shr 24) and 0xff)
  proc wirePutStr*(s: string) {.inline.} =
    wirePutU32(s.len)
    let at = wireBuf.len
    wireBuf.setLen(at + s.len)
    if s.len > 0:
      copyMem(addr wireBuf[at], unsafeAddr s[0], s.len)
  proc wireStrBytes(s: string): int {.inline.} = 4 + s.len
  proc wireBase*(): int {.inline.} =
    ## The frame's address in linear memory. The host reads
    ## `HEAPU8.subarray(base, base + len)` — no copy.
    ##
    ## Re-read it on every flush rather than caching it:
    ## `-sALLOW_MEMORY_GROWTH=1` can move the buffer.
    if wireBuf.len == 0: 0 else: cast[int](addr wireBuf[0])

  proc frameBytes*(): seq[byte] = wireBuf
    ## A copy of the current frame, for a Nim-side decoder (tests).

var wireOps = 0
  ## Operations WRITTEN into the current frame. The host's applier returns how
  ## many it APPLIED; a caller compares the two, so a frame the host stopped
  ## parsing halfway cannot pass as a complete update.

var elidedOps* = 0
  ## Writes skipped because the shadow already held the value, since the last
  ## `wireReset`.
var elidedBytes* = 0
  ## The wire size those writes would have had.

var elisionOn = true

proc setFrameElision*(on: bool) =
  ## `false` puts every write in the frame, as the un-elided stream a byte
  ## meter counts. The default is on.
  elisionOn = on

proc frameElision*(): bool = elisionOn

proc wireReset*() {.inline.} =
  ## Empties the frame and its counters together, so they always describe the
  ## same frame.
  wireResetRaw()
  wireOps = 0
  elidedOps = 0
  elidedBytes = 0

proc wireOpCount*(): int {.inline.} = wireOps

var nextHandle: int32 = 0
var readCrossings* = 0
  ## Operations that would have to be answered BACK across the boundary.

# ---------------------------------------------------------------------------
# The shadow
# ---------------------------------------------------------------------------

type
  Shadow = object
    attrs: Table[string, string]
    styles: Table[string, string]
    text: string
    textKnown: bool
    value: string
    valueKnown: bool

var shadows: seq[Shadow] = @[]
  ## Indexed by handle; slot 0 is the host's mount point and is never written.

proc shadowOf(n: FrameNode): ptr Shadow {.inline.} =
  let i = int(int32(n))
  if i <= 0 or i >= shadows.len: nil else: addr shadows[i]

proc forgetText(n: FrameNode) {.inline.} =
  let s = shadowOf(n)
  if s != nil: s.textKnown = false

proc forgetHandle*(n: FrameNode) =
  ## Drop everything the shadow knows about `n`. For a host that writes a
  ## property of a node this renderer also writes.
  let s = shadowOf(n)
  if s != nil: s[] = Shadow()

proc resetFrameRenderer*() =
  ## A fresh boundary: no frame, no handles, no shadow, no handlers.
  wireReset()
  nextHandle = 0
  readCrossings = 0
  shadows.setLen(1)

proc allocHandle(): FrameNode {.inline.} =
  inc nextHandle
  if shadows.len == 0: shadows.setLen(1)
  shadows.setLen(int(nextHandle) + 1)
  FrameNode(nextHandle)

proc handleCount*(): int = int(nextHandle)

template op(kind: BoundaryOp; body: untyped) =
  inc wireOps
  wirePutU8(ord(kind))
  body

template elide(bytes: int) =
  inc elidedOps
  elidedBytes += bytes

# ---------------------------------------------------------------------------
# RendererBackend — the write half
# ---------------------------------------------------------------------------

proc createElement*(r: FrameRenderer; tag: string): FrameNode =
  result = allocHandle()
  op(boCreateElement):
    wirePutU32(int(result))
    wirePutStr(tag)

proc createTextNode*(r: FrameRenderer; text: string): FrameNode =
  result = allocHandle()
  let s = shadowOf(result)
  s.text = text
  s.textKnown = true
  op(boCreateTextNode):
    wirePutU32(int(result))
    wirePutStr(text)

proc appendChild*(r: FrameRenderer; parent, child: FrameNode) =
  forgetText(parent)
  op(boAppendChild):
    wirePutU32(int(parent))
    wirePutU32(int(child))

proc insertBefore*(r: FrameRenderer; parent, child, reference: FrameNode) =
  forgetText(parent)
  op(boInsertBefore):
    wirePutU32(int(parent))
    wirePutU32(int(child))
    wirePutU32(int(reference))

proc removeChild*(r: FrameRenderer; parent, child: FrameNode) =
  forgetText(parent)
  op(boRemoveChild):
    wirePutU32(int(parent))
    wirePutU32(int(child))

proc setAttribute*(r: FrameRenderer; node: FrameNode; name, value: string) =
  let s = shadowOf(node)
  if elisionOn and s != nil and s.attrs.hasKey(name) and s.attrs[name] == value:
    elide(1 + 4 + wireStrBytes(name) + wireStrBytes(value))
    return
  if s != nil: s.attrs[name] = value
  op(boSetAttribute):
    wirePutU32(int(node))
    wirePutStr(name)
    wirePutStr(value)

proc removeAttribute*(r: FrameRenderer; node: FrameNode; name: string) =
  let s = shadowOf(node)
  if s != nil: s.attrs.del(name)
  op(boRemoveAttribute):
    wirePutU32(int(node))
    wirePutStr(name)

proc setTextContent*(r: FrameRenderer; node: FrameNode; text: string) =
  let s = shadowOf(node)
  if elisionOn and s != nil and s.textKnown and s.text == text:
    elide(1 + 4 + wireStrBytes(text))
    return
  if s != nil:
    s.text = text
    s.textKnown = true
  op(boSetTextContent):
    wirePutU32(int(node))
    wirePutStr(text)

proc setStyle*(r: FrameRenderer; node: FrameNode; prop, value: string) =
  let s = shadowOf(node)
  if elisionOn and s != nil and s.styles.hasKey(prop) and s.styles[prop] == value:
    elide(1 + 4 + wireStrBytes(prop) + wireStrBytes(value))
    return
  if s != nil: s.styles[prop] = value
  op(boSetStyle):
    wirePutU32(int(node))
    wirePutStr(prop)
    wirePutStr(value)

proc setInnerHtml*(r: FrameRenderer; node: FrameNode; html: string) =
  forgetText(node)
  op(boSetInnerHtml):
    wirePutU32(int(node))
    wirePutStr(html)

proc clearChildren*(r: FrameRenderer; node: FrameNode) =
  let s = shadowOf(node)
  if s != nil:
    s.text = ""
    s.textKnown = true
  op(boClearChildren):
    wirePutU32(int(node))

proc clearEventListeners*(r: FrameRenderer; node: FrameNode) =
  op(boClearEventListeners):
    wirePutU32(int(node))

proc setInputValue*(r: FrameRenderer; node: FrameNode; value: string) =
  ## Never elided: the user changes a control's value without the core, so
  ## the shadow cannot say the DOM already holds it.
  let s = shadowOf(node)
  if s != nil:
    s.value = value
    s.valueKnown = true
  op(boSetInputValue):
    wirePutU32(int(node))
    wirePutStr(value)

proc focus*(r: FrameRenderer; node: FrameNode) =
  op(boFocus):
    wirePutU32(int(node))

proc writeOpManifest*() =
  ## Replace the frame with the opcode table: per `BoundaryOp`, its ordinal
  ## as a `u8` and its name as a string. The host builds its dispatch from
  ## this and refuses a table that does not name every operation it applies.
  wireReset()
  for o in BoundaryOp:
    wirePutU8(ord(o))
    wirePutStr($o)

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

type
  HandlerKind = enum hkPlain, hkEvent
  Handler = object
    node: FrameNode
    case kind: HandlerKind
    of hkPlain: plain: proc()
    of hkEvent: withEvent: proc(ev: FrameEvent)

var handlers: seq[Handler] = @[]
var lastEvent*: FrameEvent
  ## The event the last dispatch delivered.

const
  FlagPreventDefault* = 1
  FlagStopPropagation* = 2

proc preventDefault*(ev: FrameEvent) =
  if not ev.isNil: ev.defaultPrevented = true

proc stopPropagation*(ev: FrameEvent) =
  if not ev.isNil: ev.propagationStopped = true

proc carriesValue(eventType: string): bool =
  eventType in ["input", "change", "blur", "focus"]

proc modifierSet(bits: int): set[FrameModifier] =
  for m in FrameModifier:
    if (bits and (1 shl ord(m))) != 0: result.incl m

proc dispatchFrameEvent*(id: int; eventType, value, key: string;
                         deltaY: float; modifiers: int): int =
  ## The host's way back in. Returns `FlagPreventDefault` /
  ## `FlagStopPropagation` bits for the host to apply to the real event.
  ##
  ## An id out of range is ignored rather than trapped: a stale id from a node
  ## the host still holds is an ordinary race at a real boundary.
  if id < 1 or id > handlers.len:
    return 0
  let h = handlers[id - 1]
  if carriesValue(eventType):
    let s = shadowOf(h.node)
    if s != nil:
      s.value = value
      s.valueKnown = true
  lastEvent = FrameEvent(`type`: eventType, value: value, key: key,
                         deltaY: deltaY,
                         modifiers: modifierSet(modifiers))
  case h.kind
  of hkPlain: h.plain()
  of hkEvent: h.withEvent(lastEvent)
  result = (if lastEvent.defaultPrevented: FlagPreventDefault else: 0) or
           (if lastEvent.propagationStopped: FlagStopPropagation else: 0)

proc dispatchCallback*(id: int) =
  ## A dispatch with no payload: a click.
  discard dispatchFrameEvent(id, "click", "", "", 0.0, 0)

proc dispatchEventCallback*(id: int; eventType: string) =
  ## A dispatch with only the event's type.
  discard dispatchFrameEvent(id, eventType, "", "", 0.0, 0)

proc listenerCount*(): int = handlers.len

proc addEventListener*(r: FrameRenderer; node: FrameNode; event: string;
                       handler: proc()) =
  handlers.add Handler(node: node, kind: hkPlain, plain: handler)
  op(boAddEventListener):
    wirePutU32(int(node))
    wirePutU32(handlers.len)
    wirePutStr(event)

proc addEventListener*(r: FrameRenderer; node: FrameNode; event: string;
                       handler: proc(ev: FrameEvent)) =
  handlers.add Handler(node: node, kind: hkEvent, withEvent: handler)
  op(boAddEventListener):
    wirePutU32(int(node))
    wirePutU32(handlers.len)
    wirePutStr(event)

proc resetFrameHandlers*() =
  ## Drop every handler. Ids the host still holds dispatch to nothing.
  handlers.setLen(0)

# ---------------------------------------------------------------------------
# RendererBackend — the read half
# ---------------------------------------------------------------------------

proc firstChild*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc nextSibling*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc parentNode*(r: FrameRenderer; node: FrameNode): FrameNode =
  inc readCrossings
  NoFrameNode

proc getAttribute*(r: FrameRenderer; node: FrameNode; name: string): string =
  inc readCrossings
  ""

proc inputValue*(r: FrameRenderer; node: FrameNode): string =
  ## Answered in the core when the value is known — the last value the core
  ## set, or the one the host delivered with an `input` / `change` event.
  ## Otherwise it would have to cross, and counts as a read.
  let s = shadowOf(node)
  if s != nil and s.valueKnown:
    return s.value
  inc readCrossings
  ""

# ---------------------------------------------------------------------------
# The C ABI a WebAssembly host calls
# ---------------------------------------------------------------------------

when not defined(js):
  proc isonimFrameBase*(): int {.exportc.} = wireBase()
  proc isonimFrameLen*(): int {.exportc.} = wireBytes()
  proc isonimFrameOps*(): int {.exportc.} = wireOpCount()
  proc isonimFrameElided*(): int {.exportc.} = elidedOps
  proc isonimFrameReadCrossings*(): int {.exportc.} = readCrossings
  proc isonimFrameReset*() {.exportc.} = wireReset()
  proc isonimFrameManifest*() {.exportc.} = writeOpManifest()
  proc isonimFrameDispatch*(id: cint; eventType, value, key: cstring;
                            deltaY: cdouble; modifiers: cint): cint {.exportc.} =
    cint(dispatchFrameEvent(int(id), $eventType, $value, $key, float(deltaY),
                            int(modifiers)))
  proc isonimFrameForget*(handle: cint) {.exportc.} =
    forgetHandle(FrameNode(handle))
