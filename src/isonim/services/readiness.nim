## Readiness marks: when each element of a screen first shows real data, and
## when it is complete.
##
## A ViewModel that loads data records, per load, two marks for each element
## it drives:
##
## - `<element>:first` — the element shows its first real content (a stream's
##   first chunk, the first rows of a list that is backfilled later);
## - `<element>` — the element is complete.
##
## Each mark is recorded once per load, in milliseconds since the load began,
## on nim-everywhere's clock (so fake time gives exact numbers in tests).
## `beginLoad` starts a new load and clears the previous marks. Marking an
## element complete also records its first content if that was not marked
## separately (a value that arrives in one piece is first and complete at
## once).
##
## The marks are a reactive signal, so a View or a developer tool can show
## them as a timeline; on the JS backend each mark is also written with
## `performance.mark` (named `<prefix><mark>`), where browser tooling and
## automated measurements pick it up. Recording costs one small sequence
## append per mark.

import nim_everywhere/time

import isonim/core/signals

type
  ReadinessMark* = object
    name*: string
    atMs*: int64  ## Since the start of the load.

  ReadinessMarks* = ref object
    prefix*: string            ## Prefix for `performance.mark` names.
    loadStartMs*: int64
    loads*: int                ## Number of `beginLoad` calls so far.
    marks*: Signal[seq[ReadinessMark]]

const FirstSuffix* = ":first"

proc newReadinessMarks*(prefix = "isonim:"): ReadinessMarks =
  ## A recorder with no load started. Call `beginLoad` when the load starts.
  ReadinessMarks(prefix: prefix, loadStartMs: monotonicNowMs(),
    marks: createSignal[seq[ReadinessMark]](@[]))

proc beginLoad*(r: ReadinessMarks) =
  ## Start a new load: clear the marks and reset the time origin.
  r.loadStartMs = monotonicNowMs()
  inc r.loads
  r.marks.val = @[]

proc has*(r: ReadinessMarks; name: string): bool =
  for m in r.marks.value:
    if m.name == name: return true

proc at*(r: ReadinessMarks; name: string): int64 =
  ## Milliseconds from the load's start to mark `name`, or -1.
  for m in r.marks.value:
    if m.name == name: return m.atMs
  -1

proc mark*(r: ReadinessMarks; name: string) =
  ## Record `name` now, unless it was already recorded in this load.
  if r.has(name): return
  let at = monotonicNowMs() - r.loadStartMs
  var next = r.marks.value
  next.add ReadinessMark(name: name, atMs: at)
  r.marks.val = next
  when defined(js):
    let full = (r.prefix & name).cstring
    {.emit: ["if (typeof performance !== 'undefined' && performance.mark) ",
             "{ try { performance.mark(", full, "); } catch (e) {} }"].}

proc markFirst*(r: ReadinessMarks; element: string) =
  ## `element` shows its first real content.
  r.mark(element & FirstSuffix)

proc markComplete*(r: ReadinessMarks; element: string) =
  ## `element` is complete (and, if not yet marked, shows its first content).
  r.markFirst(element)
  r.mark(element)

proc firstAt*(r: ReadinessMarks; element: string): int64 =
  r.at(element & FirstSuffix)

proc completeAt*(r: ReadinessMarks; element: string): int64 =
  r.at(element)
