## boundary_meter.nim — what a renderer operation would COST to cross a
## module boundary.
##
## ## Why this exists
##
## `codetracer-specs/Architecture/Uniform-WASM-Core.md` §3 says the hazard in
## running a UI core as WebAssembly is **not** call overhead — engines have
## optimised the WASM↔JS boundary to tens of millions of calls per second, and
## a debugger's update rate is human-driven. The cost that does not disappear
## is **marshalling**: WASM linear memory has no JS string representation, so
## every string is encoded on one side and decoded on the other, and DOM nodes
## cannot be held by WASM at all — they live behind a handle table, so a node
## reference becomes an index plus a lookup.
##
## §6 step 1 therefore asks for the instrument on the **current** build first,
## because it "is useful regardless of the outcome and it establishes the
## baseline the whole comparison rests on".
##
## ## FOUR QUANTITIES, AND THEY ARE NOT THE SAME QUANTITY
##
## A bound, a claim and a measurement must describe the same thing
## (Verification-Harness-Traps.md §12). This module produces four numbers and
## they must never be quoted as one:
##
##   1. **crossings** — how many renderer operations were issued. Cheap, and
##      §3 says explicitly that this is the number that does NOT decide
##      anything. Recorded because it is free and because a reader will ask.
##   2. **bytes** — how many bytes the operation's arguments occupy in the
##      flat wire form below. This is a STRUCTURAL count; it is exact, it does
##      not depend on the host, and it is the same number on every backend.
##   3. **encodeNs** — how long it takes to WRITE those bytes into a flat
##      buffer, measured by actually writing them, in the runtime doing the
##      measuring.
##   4. **decodeNs** — how long it takes to READ them back out into runtime
##      strings, measured by actually reading them.
##
## On a `nim js` build nothing crosses anything: the core and the DOM are in
## one heap. So (3) and (4) there are **the cost the current build does not
## pay** — they are what a WASM core would add, measured in the same runtime,
## over exactly the bytes (2) counts. That is the only honest reading of them
## and this module's callers are required to quote it that way.
##
## ## THE WIRE FORM
##
## One flat byte frame, little-endian, appended to per operation:
##
##   * 1 byte   opcode
##   * 4 bytes  per node handle — a u32 index into the host's handle table,
##              which is what a node reference becomes when the core cannot
##              hold a DOM node (§3)
##   * 4 bytes  length prefix, then the UTF-8 payload, per string argument
##
## ## ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps.md §14)
##
## `frameBytesFor` computes the size and `encodeOp` writes the bytes, and
## they could drift. They are not allowed to: `noteOp` compares the encoder's
## actual advance against `frameBytesFor`'s answer on EVERY operation and sets
## `sizeMismatch`, which every consumer of this meter must refuse to publish a
## number over. A byte count that the encoder does not reproduce is not a
## measurement of the encoder.
##
## ## DISABLED IS OFF
##
## `meterEnabled` defaults to false and every entry point returns immediately
## when it is false, so a renderer carrying these hooks behaves exactly as it
## did before. That claim is falsifiable and is falsified: see
## `ci/test/marshalling-instrument.sh` contract 1 in the codetracer repo,
## which runs a suite with the hooks present and the meter off and requires
## byte-identical results.

import std/[monotimes, times]

type
  BoundaryOp* = enum
    ## Every operation `renderers/abstract_renderer.checkRendererBackend`
    ## requires, plus the four IsoNim renderers add beyond it. The enum is
    ## the opcode: one byte on the wire.
    boCreateElement
    boCreateTextNode
    boAppendChild
    boInsertBefore
    boRemoveChild
    boSetAttribute
    boRemoveAttribute
    boSetTextContent
    boSetStyle
    boSetInnerHtml
    boAddEventListener
    boFirstChild
    boNextSibling
    boParentNode
    boClearChildren
    boClearEventListeners
    boFocus
    boGetAttribute
    boInputValue
    boSetInputValue

  BoundaryMeter* = object
    ## A tally plus the flat frame the tally is checked against.
    ops*: array[BoundaryOp, int]
      ## crossings, per operation
    opcodeBytes*: int64
    handleBytes*: int64
    lengthBytes*: int64
      ## the 4-byte length prefixes — separated from `payloadBytes` because a
      ## boundary that carries many SHORT strings pays a different share of
      ## framing than one carrying few long ones, and the whole question §3
      ## asks is about a UI that is "overwhelmingly text"
    payloadBytes*: int64
      ## the UTF-8 string bytes themselves
    stringArgs*: int64
    handleArgs*: int64
    encodeNs*: int64
    decodeNs*: int64
    decodedStrings*: int64
      ## how many strings the decode actually reconstructed. A decode timing
      ## over zero reconstructed strings is a timing of a loop that did not
      ## run, which is the shape this whole campaign keeps meeting.
    decodedBytes*: int64
      ## the UTF-8 length of what came BACK out. A publisher requires
      ## `decodedBytes == payloadBytes`: a decode that returned short strings
      ## would otherwise be a fast decode rather than a wrong one, and "it
      ## got quicker" is the direction an instrument fails in silently.
    sizeMismatch*: int
      ## non-zero ⇒ `frameBytesFor` and `encodeOp` disagreed. Every publisher
      ## must refuse over this.

const HandleWidth* = 4
  ## bytes per node handle on the wire — a u32 index into the host's handle
  ## table. WASM's own pointers are 4 bytes on wasm32, and a handle table
  ## index is the same width, so this is not a choice.
const LengthWidth* = 4
  ## bytes per string length prefix

var meterEnabled* = false
  ## Off by default. A renderer with these hooks compiled in and this false
  ## must be byte-for-byte the renderer that had no hooks.
var meterCodec* = false
  ## Whether `noteOp` additionally ENCODES and DECODES the operation. Split
  ## from `meterEnabled` on purpose: counting bytes is free and timing an
  ## encode is not, so a caller measuring the view's own wall time can count
  ## without paying for the codec.
var meter*: BoundaryMeter


# ---------------------------------------------------------------------------
# THE CODEC, PER BACKEND — because the cost of encoding IS a property of the
# runtime, and modelling both runtimes with one loop measures neither.
# ---------------------------------------------------------------------------
#
# A JS runtime's `string` is UTF-16 and immutable, so a host at a real WASM
# boundary uses `TextEncoder` / `TextDecoder` against a `Uint8Array` — and the
# first draft of this module did NOT: it built the frame in a Nim `string`,
# which the JS backend represents as a JS string, so every `add` allocated a
# new one and the encode became quadratic. Measured on the 600-member fixture
# before the repair: **112 ms to encode 5,391 bytes** in the MOUNT phase, 20 µs
# per byte, against a 2.15 ms wall time for the phase that produced them. That
# figure was a measurement of Nim's JS string representation wearing the name
# of a marshalling cost, and it is exactly the shape
# Verification-Harness-Traps.md's common thread describes — an instrument
# reporting a state it did not reach.
#
# A C or WASM runtime's `string` already IS the UTF-8 bytes, so the same
# operation is a `copyMem` into linear memory. That asymmetry is the truth
# about the boundary rather than an unfairness in the instrument.

when defined(js):
  {.emit: """
var isonimBM_enc = new TextEncoder();
var isonimBM_dec = new TextDecoder('utf-8');
var isonimBM_buf = new Uint8Array(1 << 16);
var isonimBM_len = 0;
function isonimBM_ensure(n) {
  if (isonimBM_len + n > isonimBM_buf.length) {
    var grown = new Uint8Array(Math.max(isonimBM_buf.length * 2, isonimBM_len + n));
    grown.set(isonimBM_buf);
    isonimBM_buf = grown;
  }
}
function isonimBM_reset() { isonimBM_len = 0; }
function isonimBM_flen() { return isonimBM_len; }
function isonimBM_u8(v) { isonimBM_ensure(1); isonimBM_buf[isonimBM_len++] = v & 0xff; }
function isonimBM_u32(v) {
  isonimBM_ensure(4);
  isonimBM_buf[isonimBM_len++] = v & 0xff;
  isonimBM_buf[isonimBM_len++] = (v >>> 8) & 0xff;
  isonimBM_buf[isonimBM_len++] = (v >>> 16) & 0xff;
  isonimBM_buf[isonimBM_len++] = (v >>> 24) & 0xff;
}
function isonimBM_str(s) {
  var bytes = isonimBM_enc.encode(s);
  isonimBM_u32(bytes.length);
  isonimBM_ensure(bytes.length);
  isonimBM_buf.set(bytes, isonimBM_len);
  isonimBM_len += bytes.length;
  return bytes.length;
}
function isonimBM_u32at(at) {
  return (isonimBM_buf[at] | (isonimBM_buf[at+1] << 8) |
          (isonimBM_buf[at+2] << 16) | (isonimBM_buf[at+3] << 24)) >>> 0;
}
function isonimBM_decode(at, n) {
  return isonimBM_dec.decode(isonimBM_buf.subarray(at, at + n));
}
function isonimBM_utf8len(s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    var c = s.charCodeAt(i);
    if (c < 0x80) n += 1;
    else if (c < 0x800) n += 2;
    else if (c >= 0xD800 && c < 0xDC00) { n += 4; i++; }
    else n += 3;
  }
  return n;
}
""".}

  proc bmReset() {.importjs: "isonimBM_reset()".}
  proc bmPutU8(v: int) {.importjs: "isonimBM_u8(#)".}
  proc bmPutU32(v: int) {.importjs: "isonimBM_u32(#)".}
  proc bmPutStr(s: cstring): int {.importjs: "isonimBM_str(#)".}
  proc bmFrameLen(): int {.importjs: "isonimBM_flen()".}
  proc bmReadU32(at: int): int {.importjs: "isonimBM_u32at(#)".}
  proc bmDecodeRaw(at, n: int): cstring {.importjs: "isonimBM_decode(#, #)".}
  proc bmUtf8Len(s: cstring): int {.importjs: "isonimBM_utf8len(#)".}

  proc utf8ByteLen*(s: string): int {.inline.} =
    ## The number of UTF-8 bytes `s` occupies ON THE WIRE — NOT `s.len`, which
    ## on this backend counts UTF-16 code units. The bytes crossing a WASM
    ## boundary are UTF-8 whichever side is counting, so reporting code units
    ## here would make the SAME view over the SAME data report two different
    ## byte counts on the two backends being compared.
    bmUtf8Len(cstring(s))

  proc bmPutStrNim(s: string): int {.inline.} = bmPutStr(cstring(s))
  proc bmDecode(at, n: int): string {.inline.} = $bmDecodeRaw(at, n)

else:
  var bmBuf: seq[byte] = @[]

  proc bmReset() {.inline.} = bmBuf.setLen(0)
  proc bmPutU8(v: int) {.inline.} = bmBuf.add byte(v and 0xff)
  proc bmPutU32(v: int) {.inline.} =
    bmBuf.add byte(v and 0xff)
    bmBuf.add byte((v shr 8) and 0xff)
    bmBuf.add byte((v shr 16) and 0xff)
    bmBuf.add byte((v shr 24) and 0xff)
  proc bmFrameLen(): int {.inline.} = bmBuf.len
  proc bmReadU32(at: int): int {.inline.} =
    int(bmBuf[at]) or (int(bmBuf[at + 1]) shl 8) or
      (int(bmBuf[at + 2]) shl 16) or (int(bmBuf[at + 3]) shl 24)

  proc utf8ByteLen*(s: string): int {.inline.} =
    ## A Nim `string` on the C and WASM backends already IS its UTF-8 bytes.
    s.len

  proc bmPutStrNim(s: string): int {.inline.} =
    bmPutU32(s.len)
    let at = bmBuf.len
    bmBuf.setLen(at + s.len)
    if s.len > 0:
      copyMem(addr bmBuf[at], unsafeAddr s[0], s.len)
    s.len

  proc bmDecode(at, n: int): string {.inline.} =
    result = newString(n)
    if n > 0:
      copyMem(addr result[0], addr bmBuf[at], n)

proc frameBytesFor*(handles, strBytesTotal, strCount: int): int {.inline.} =
  ## The size of one operation's frame. THE size — the encoder below is
  ## checked against this on every single operation, so the two cannot drift
  ## (Verification-Harness-Traps.md §14: one predicate, one function).
  1 + handles * HandleWidth + strCount * LengthWidth + strBytesTotal

proc resetMeter*() =
  ## Zero every tally. Does not change `meterEnabled` / `meterCodec`.
  var fresh: BoundaryMeter
  meter = fresh
  bmReset()

proc totalBytes*(m: BoundaryMeter): int64 =
  m.opcodeBytes + m.handleBytes + m.lengthBytes + m.payloadBytes

proc totalCrossings*(m: BoundaryMeter): int =
  for op in BoundaryOp:
    result += m.ops[op]

proc nowNs(): int64 {.inline.} =
  (getMonoTime() - MonoTime()).inNanoseconds

proc noteOp*(op: BoundaryOp; handles: int; strs: varargs[string]) =
  ## Record one renderer operation.
  ##
  ## Returns immediately when the meter is off, which is what makes the
  ## instrumented renderers behave identically to the uninstrumented ones.
  if not meterEnabled:
    return
  inc meter.ops[op]
  var strBytes = 0
  for s in strs:
    strBytes += utf8ByteLen(s)
  meter.opcodeBytes += 1
  meter.handleBytes += int64(handles * HandleWidth)
  meter.lengthBytes += int64(strs.len * LengthWidth)
  meter.payloadBytes += int64(strBytes)
  meter.stringArgs += int64(strs.len)
  meter.handleArgs += int64(handles)

  if not meterCodec:
    return

  let expected = frameBytesFor(handles, strBytes, strs.len)

  # ---- encode ----
  bmReset()
  let encStart = nowNs()
  bmPutU8(ord(op))
  for h in 0 ..< handles:
    # A handle is an index the host assigns. Its VALUE does not change the
    # cost; its WIDTH does, and the width is what is being measured.
    bmPutU32(h + 1)
  for s in strs:
    discard bmPutStrNim(s)
  meter.encodeNs += nowNs() - encStart

  if bmFrameLen() != expected:
    inc meter.sizeMismatch
    return

  # ---- decode ----
  var decoded: seq[string] = @[]
  var at = 1 + handles * HandleWidth
  let decStart = nowNs()
  for _ in 0 ..< strs.len:
    let n = bmReadU32(at)
    at += LengthWidth
    decoded.add bmDecode(at, n)
    at += n
  meter.decodeNs += nowNs() - decStart

  # The tally over what came back is taken OUTSIDE the timed region: it is a
  # property of the result, not part of the work a host would do.
  meter.decodedStrings += int64(decoded.len)
  for s in decoded:
    meter.decodedBytes += int64(utf8ByteLen(s))
