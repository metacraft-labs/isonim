## In-process micro-benchmark of the reactive core.
##
## The js-framework-benchmark harness (`benchmarks/run-comparison.sh`) drives a
## real browser, and its numbers swing widely on a loaded host because layout,
## paint and the browser's own scheduling dominate them. This benchmark runs
## the same reactive workload as the keyed benchmark app
## (`benchmarks/keyed/isonim/src/main.nim`) with no DOM at all, so what it
## measures is the core: signal writes, observer notification, effect
## re-execution, owner creation and disposal.
##
## Cases (one output line each):
##
## - `select`: 1000 rows, each with one render effect that reads the single
##   `selected` signal (exactly as the app's row highlight does), then 2000
##   writes to `selected` cycling through the row ids. Every write re-runs all
##   1000 row effects; this is the O(n) fan-out of the app's selection.
## - `rebuild`: a list effect that, for every row of the `data` signal,
##   creates the row's label effect and selection effect (the app's
##   `createRowElement` minus the DOM), then 20 writes of a fresh 1000-row
##   array. Each write disposes the previous 1000 rows' effects and creates
##   1000 new rows.
## - `memory_ready` / `memory_run` / `memory_clear`: JS heap in use after the
##   root and its list effect exist with no rows, after 1000 rows are
##   created, and after the list is cleared again, each measured after a
##   forced garbage collection.
##
## Determinism: labels come from a fixed-seed linear congruential generator,
## not `Math.random`, so every run does the same work. Each timed case runs
## several iterations after a warm-up; the line reports the median and the
## minimum. Compare medians between runs measured on the same host at similar
## load; the minimum shows the floor when the host is noisy.
##
## Build and run: `just core-bench` (compiled with `nim js -d:danger` and run
## with `node --expose-gc`, which the memory cases need).
##
## No mocks: the benchmark drives the real reactive core. The DOM is left out
## on purpose, because the point is to isolate the core's cost; the rows'
## effects write to plain JS objects instead, so they still have a side
## effect the engine cannot drop.

when not defined(js):
  {.error: "core_bench.nim measures the JS build of the core; compile with nim js".}

import std/algorithm
import isonim/core/js_collections
import isonim/core/signals
import isonim/rxcore

# ---- Host bindings (node) ----

proc nowMs(): float {.importjs: "performance.now()".}
proc hasGc(): bool {.importjs: "(typeof globalThis.gc === 'function')".}
proc forceGc() {.importjs: "globalThis.gc()".}
proc heapUsedBytes(): float {.importjs: "process.memoryUsage().heapUsed".}
proc envInt(name: cstring; default: int): int =
  {.emit: [result, " = parseInt((process.env[", name, "] || ''), 10) || ", default, ";"].}
proc printLine(s: cstring) {.importjs: "console.log(#)".}
proc fmt2(x: float): cstring {.importjs: "(#).toFixed(2)".}
proc fmtInt(x: int): cstring {.importjs: "String(#)".}
proc `&`(a, b: cstring): cstring {.importjs: "(# + #)".}
proc exitWith(code: int) {.importjs: "process.exit(#)".}

# ---- Data model (as in the keyed benchmark app) ----

const adjectives: array[25, cstring] = [
  cstring"pretty", "large", "big", "small", "tall", "short", "long", "handsome",
  "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful",
  "mushy", "odd", "unsightly", "adorable", "important", "inexpensive",
  "cheap", "expensive", "fancy"
]

const colours: array[11, cstring] = [
  cstring"red", "yellow", "blue", "green", "pink", "brown", "purple", "brown",
  "white", "black", "orange"
]

const nouns: array[13, cstring] = [
  cstring"table", "chair", "house", "bbq", "desk", "car", "pony", "cookie",
  "sandwich", "burger", "pizza", "mouse", "keyboard"
]

type
  Row = ref object
    id: int
    label: Signal[cstring]

  Rows = JsArray[Row]

  RowView = ref object
    ## Stands in for the row's DOM nodes: the effects write here, the way the
    ## app's effects write `className` and the link's text.
    className: cstring
    text: cstring

var
  seed = 12345
  nextId = 1

proc nextRand(max: int): int =
  ## Park-Miller minimal-standard generator: the product stays below 2^47, so
  ## it is exact in JS numbers (Nim's `int` is a JS double on this backend).
  seed = (seed * 48271) mod 2147483647
  seed mod max

proc randomLabel(): cstring =
  adjectives[nextRand(adjectives.len)] & cstring" " &
    colours[nextRand(colours.len)] & cstring" " &
    nouns[nextRand(nouns.len)]

proc buildData(count: int): Rows =
  result = newJsArray[Row](count)
  for i in 0 ..< count:
    result[i] = Row(id: nextId, label: createSignal(randomLabel()))
    inc nextId

proc resetData() =
  seed = 12345
  nextId = 1

proc mountRow(row: Row; selected: Signal[int]; views: JsArray[RowView]) =
  ## The reactive half of the app's `createRowElement`: one effect for the
  ## label, one for the selection highlight.
  let view = RowView(className: "", text: "")
  effect proc() =
    view.text = row.label.val
  effect proc() =
    if selected.val == row.id:
      view.className = "danger"
    else:
      view.className = ""
  views.push(view)

# ---- Measurement ----

type Stats = object
  median, min: float

proc stats(samples: seq[float]): Stats =
  var s = samples
  s.sort()
  result.min = s[0]
  result.median =
    if s.len mod 2 == 1: s[s.len div 2]
    else: (s[s.len div 2 - 1] + s[s.len div 2]) / 2.0

proc report(name: cstring; iterations: int; st: Stats; unit: cstring) =
  printLine(cstring"core-bench " & name & cstring" median_" & unit & "=" &
    fmt2(st.median) & cstring" min_" & unit & "=" & fmt2(st.min) &
    cstring" iterations=" & fmtInt(iterations))

const
  RowCount = 1000
  SelectWrites = 2000
  Rebuilds = 20

proc selectOnce(): float =
  ## One `select` sample: build 1000 row effects, then time 2000 writes.
  resetData()
  var elapsed = 0.0
  var checksum = 0
  createRoot proc(dispose: proc()) =
    let selected = createSignal(0)
    let views = newJsArray[RowView]()
    let rows = buildData(RowCount)
    for i in 0 ..< rows.len:
      mountRow(rows[i], selected, views)
    let t0 = nowMs()
    for k in 0 ..< SelectWrites:
      selected.val = (k mod RowCount) + 1
    elapsed = nowMs() - t0
    # Read the result back so the work is observable: exactly one row is
    # highlighted, the last one written.
    for i in 0 ..< views.len:
      if views[i].className == cstring"danger": inc checksum
    dispose()
  if checksum != 1:
    printLine(cstring"core-bench select: expected exactly one selected row, got " &
      fmtInt(checksum))
    exitWith(1)
  elapsed

proc rebuildOnce(): float =
  ## One `rebuild` sample: time 20 replacements of the 1000-row list.
  resetData()
  var elapsed = 0.0
  var mounted = 0
  createRoot proc(dispose: proc()) =
    let selected = createSignal(0)
    let data = createSignal(newJsArray[Row](),
      equals = proc(a, b: Rows): bool = false)
    var views = newJsArray[RowView]()
    createEffect proc() =
      let rows = data.val
      views = newJsArray[RowView]()
      for i in 0 ..< rows.len:
        mountRow(rows[i], selected, views)
    let t0 = nowMs()
    for k in 0 ..< Rebuilds:
      data.val = buildData(RowCount)
    elapsed = nowMs() - t0
    mounted = views.len
    dispose()
  if mounted != RowCount:
    printLine(cstring"core-bench rebuild: expected " & fmtInt(RowCount) &
      cstring" mounted rows, got " & fmtInt(mounted))
    exitWith(1)
  elapsed

proc measureMemory(): tuple[ready, run, clear: float] =
  ## Heap in use (MB) at the three points the memory cases name. A fresh
  ## root, so nothing from the timed cases is reachable.
  resetData()
  const mb = 1024.0 * 1024.0
  var ready, run, clear = 0.0
  createRoot proc(dispose: proc()) =
    let selected = createSignal(0)
    let data = createSignal(newJsArray[Row](),
      equals = proc(a, b: Rows): bool = false)
    var views = newJsArray[RowView]()
    createEffect proc() =
      let rows = data.val
      views = newJsArray[RowView]()
      for i in 0 ..< rows.len:
        mountRow(rows[i], selected, views)
    forceGc()
    ready = heapUsedBytes() / mb
    data.val = buildData(RowCount)
    forceGc()
    run = heapUsedBytes() / mb
    data.val = newJsArray[Row]()
    forceGc()
    clear = heapUsedBytes() / mb
    dispose()
  (ready, run, clear)

proc main() =
  let iterations = max(1, envInt("CORE_BENCH_ITERATIONS", 7))
  let warmup = max(0, envInt("CORE_BENCH_WARMUP", 2))
  if not hasGc():
    printLine(cstring"core-bench: run node with --expose-gc (the memory cases need it)")
    exitWith(2)

  for i in 0 ..< warmup: discard selectOnce()
  var sel: seq[float]
  for i in 0 ..< iterations: sel.add selectOnce()
  report("select", iterations, stats(sel), "ms")

  for i in 0 ..< warmup: discard rebuildOnce()
  var reb: seq[float]
  for i in 0 ..< iterations: reb.add rebuildOnce()
  report("rebuild", iterations, stats(reb), "ms")

  var ready, run, clear: seq[float]
  for i in 0 ..< iterations:
    let m = measureMemory()
    ready.add m.ready
    run.add m.run
    clear.add m.clear
  report("memory_ready", iterations, stats(ready), "mb")
  report("memory_run", iterations, stats(run), "mb")
  report("memory_clear", iterations, stats(clear), "mb")

main()
