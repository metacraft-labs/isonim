## preview_compile.nim
##
## The web-worker fixture's "compiler" (tests/browser/specs/web-worker.spec.ts):
## a stand-in for the composer's preview compilation (isonim-composer.md
## §2.6). It splits the text into blank-line separated blocks, renders each
## as an escaped paragraph keyed by a content hash, and then, to make the
## work measurable, keeps its thread busy for `busyMs`.
##
## The same module is compiled into the worker chunk (preview.worker.nim)
## and, for the negative control, into the main bundle (main.nim with
## -d:previewInline).

import std/strutils
import isonim/web/worker

type
  PreviewRequest* = object
    text*: string
    busyMs*: int
    announce*: bool       ## say "busy" on the BroadcastChannel `isonim-busy`
                          ## as the busy loop starts (beacon.js relays it)

  PreviewBlock* = object
    hash*: string
    html*: string

  PreviewResult* = object
    blocks*: seq[PreviewBlock]
    inWorker*: bool
    busyFrom*, busyTo*: float   ## epoch ms (performance.timeOrigin + now())

const fnvPrime* = 16777619'u32
  ## The FNV-1a prime: a literal only this module's code contains, which
  ## web-worker.spec.ts looks for to see which chunk carries the compiler.

proc epochNow(): float =
  {.emit: [result, " = performance.timeOrigin + performance.now();"].}
proc announceBusy() =
  {.emit: "new BroadcastChannel('isonim-busy').postMessage('busy');".}

proc fnv1a(s: string): string =
  var h = 2166136261'u32
  for c in s:
    h = (h xor uint32(ord(c))) * fnvPrime
  toHex(h)

proc escapeText(s: string): string =
  for c in s:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    else: result.add c

proc compilePreview*(req: PreviewRequest): PreviewResult =
  result.inWorker = inWorkerScope()
  for raw in req.text.split("\n\n"):
    let blk = raw.strip()
    if blk.len > 0:
      result.blocks.add PreviewBlock(hash: fnv1a(blk),
        html: "<p>" & escapeText(blk) & "</p>")
  if req.announce:
    announceBusy()
  result.busyFrom = epochNow()
  while epochNow() - result.busyFrom < float(req.busyMs):
    discard
  result.busyTo = epochNow()
