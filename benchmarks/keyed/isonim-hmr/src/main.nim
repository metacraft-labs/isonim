## js-framework-benchmark implementation for IsoNim — HMR-enabled variant.
##
## Same workload as the baseline `keyed/isonim` entry, but compiled with
## `-d:isonimHmr` and importing the HMR machinery so the bundle includes
## the HMR runtime. Lets us quantify the bundle-size and steady-state
## runtime cost of having HMR compiled in.
##
## What it shows / does NOT show:
##   - Bundle size: includes the HMR slot registry, persistent reactive
##     owner, signal-shadow templates, and `globalThis.__isonim_hmr_root`
##     plumbing. Compare against the baseline `keyed/isonim` bundle.
##   - Steady-state runtime: NOT changed by HMR for this workload — the
##     benchmark's per-row signals are created via `signals.createSignal`
##     directly, which does not go through any HMR-wrapped path. Per-row
##     state via hmrSignal can't work in v1 of the design (it keys by
##     source location, so rows would all share one signal).

when not defined(js):
  {.error: "benchmark main.nim requires the JS backend".}

import isonim/core/js_collections
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/core/signals
import isonim/rxcore

# HMR machinery — imported so the runtime is linked into the bundle.
import isonim/web/hmr
import isonim/web/hmr_component

# ---- Data model ----

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

proc `&`(a, b: cstring): cstring {.importcpp: "(# + #)".}

proc jsRandom(max: int): int =
  {.emit: [result, " = (Math.random() * ", max, ") | 0;"].}

type
  Row = ref object
    id: int
    label: Signal[cstring]
  Rows = JsArray[Row]

var
  nextId = 1
  data: Signal[Rows]
  selected: Signal[int]

proc randomLabel(): cstring =
  adjectives[jsRandom(adjectives.len)] & cstring" " &
    colours[jsRandom(colours.len)] & cstring" " &
    nouns[jsRandom(nouns.len)]

proc buildData(count: int): Rows =
  result = newJsArray[Row](count)
  for i in 0 ..< count:
    result[i] = Row(id: nextId, label: signals.createSignal(randomLabel()))
    inc nextId

proc jsParseInt(s: cstring): int =
  {.emit: [result, " = parseInt(", s, ", 10) || 0;"].}

proc jsIntToStr(n: int): cstring =
  {.emit: [result, " = String(", n, ");"].}

let rowTmpl = tmpl(
  "<tr><td class='col-md-1'></td>" &
  "<td class='col-md-4'><a></a></td>" &
  "<td class='col-md-1'><a><span class='glyphicon glyphicon-remove' aria-hidden='true'></span></a></td>" &
  "<td class='col-md-6'></td></tr>"
)

proc createRowElement(row: Row): Node =
  let tr = rowTmpl()
  let td1 = tr.firstChild
  let td2 = td1.nextSibling
  let td3 = td2.nextSibling
  let selectLink = td2.firstChild
  let deleteLink = td3.firstChild

  td1.textContent = jsIntToStr(row.id)
  insert(selectLink, proc(): cstring = row.label.val)

  effect proc() =
    if selected.val == row.id:
      Element(tr).className = "danger"
    else:
      Element(tr).className = ""

  let rowIdStr = jsIntToStr(row.id)
  {.emit: [selectLink, ".$$rowId = ", rowIdStr, ";"].}
  {.emit: [deleteLink, ".$$rowId = ", rowIdStr, ";"].}

  selectLink.setJsPropHandler(cstring"$$click", proc(ev: Event) =
    var rowIdCstr: cstring
    {.emit: [rowIdCstr, " = ", ev.target, ".$$rowId || ", ev.target, ".parentNode.$$rowId || '';"].}
    let rowId = jsParseInt(rowIdCstr)
    if selected.val == rowId: selected.val = 0
    else: selected.val = rowId
  )

  deleteLink.setJsPropHandler(cstring"$$click", proc(ev: Event) =
    var rowIdCstr: cstring
    {.emit: [rowIdCstr, " = ", ev.target, ".$$rowId || ", ev.target, ".parentNode.$$rowId || '';"].}
    let rowId = jsParseInt(rowIdCstr)
    let rows = data.val
    var filtered: Rows
    {.emit: [filtered, " = ", rows, ".filter(function(r){ return r.id !== ", rowId, "; });"].}
    data.val = filtered
  )

  return tr

proc main() =
  createRoot proc(dispose: proc()) =
    data = signals.createSignal(newJsArray[Row](),
                                equals = proc(a, b: Rows): bool = false)
    selected = signals.createSignal(0)

    let tbody = document.getElementById("tbody")
    delegateEvents([cstring"click"])

    document.getElementById("run").Node.addEventListener(cstring"click",
      proc(ev: Event) = data.val = buildData(1000))
    document.getElementById("runlots").Node.addEventListener(cstring"click",
      proc(ev: Event) = data.val = buildData(10000))
    document.getElementById("add").Node.addEventListener(cstring"click",
      proc(ev: Event) =
        let rows = data.val
        let extra = buildData(1000)
        var combined: Rows
        {.emit: [combined, " = ", rows, ".concat(", extra, ");"].}
        data.val = combined)
    document.getElementById("update").Node.addEventListener(cstring"click",
      proc(ev: Event) =
        let rows = data.val
        var i = 0
        while i < rows.len:
          rows[i].label.val = rows[i].label.val & cstring" !!!"
          i += 10)
    document.getElementById("clear").Node.addEventListener(cstring"click",
      proc(ev: Event) = data.val = newJsArray[Row]())
    document.getElementById("swaprows").Node.addEventListener(cstring"click",
      proc(ev: Event) =
        let rows = data.val
        if rows.len > 998:
          var copy: Rows
          {.emit: [copy, " = ", rows, ".slice();"].}
          copy.swap(1, 998)
          data.val = copy)

    block:
      var items = newJsArray[Row]()
      var mapped = newJsArray[Node]()

      createEffect proc() =
        let newItems = data.val
        let newLen = newItems.len
        let oldLen = items.len

        if newLen == 0:
          for i in 0 ..< oldLen:
            tbody.Node.removeChild(mapped[i])
          items = newJsArray[Row]()
          mapped = newJsArray[Node]()
          return

        if oldLen == 0:
          let newMapped = newJsArray[Node](newLen)
          for i in 0 ..< newLen:
            let node = createRowElement(newItems[i])
            newMapped[i] = node
            tbody.Node.appendChild(node)
          items = newItems
          mapped = newMapped
          return

        let temp = newJsArray[Node](newLen)

        var start = 0
        let minLen = if oldLen < newLen: oldLen else: newLen
        while start < minLen and items[start] == newItems[start]:
          temp[start] = mapped[start]
          start += 1

        var oldEnd = oldLen - 1
        var newEnd = newLen - 1
        while oldEnd >= start and newEnd >= start and
              items[oldEnd] == newItems[newEnd]:
          temp[newEnd] = mapped[oldEnd]
          oldEnd -= 1
          newEnd -= 1

        if start > newEnd and start <= oldEnd:
          for idx in start .. oldEnd:
            tbody.Node.removeChild(mapped[idx])
        elif start > oldEnd and start <= newEnd:
          let refNode = if newEnd + 1 < newLen: temp[newEnd + 1] else: nil
          for idx in start .. newEnd:
            temp[idx] = createRowElement(newItems[idx])
            if refNode.isNodeNil:
              tbody.Node.appendChild(temp[idx])
            else:
              tbody.Node.insertBefore(temp[idx], refNode)
        elif start <= newEnd:
          var s = start
          var l = oldEnd + 1
          var i = start
          var o = newEnd + 1
          let sentinel = if l < oldLen: mapped[l].nextSibling else: nil
          var fallbackMap: JsMap[int, int]

          while s < l or i < o:
            if s < l and i < o and items[s] == newItems[i]:
              temp[i] = mapped[s]
              s += 1; i += 1
            elif s < l and i < o and items[s] != newItems[i]:
              while l > s and o > i and items[l - 1] == newItems[o - 1]:
                l -= 1; o -= 1
                temp[o] = mapped[l]

              if l == s:
                let refNode = if o < newEnd + 1:
                  (if i > start: temp[i - 1].nextSibling else: temp[o])
                else: sentinel
                while i < o:
                  temp[i] = createRowElement(newItems[i])
                  tbody.Node.insertBefore(temp[i], refNode)
                  i += 1
              elif o == i:
                while s < l:
                  tbody.Node.removeChild(mapped[s])
                  s += 1
              elif items[s] == newItems[o - 1] and newItems[i] == items[l - 1]:
                let nodeA = mapped[s]
                let nodeB = mapped[l - 1]
                let refAfterB = nodeB.nextSibling
                tbody.Node.insertBefore(nodeB, nodeA.nextSibling)
                tbody.Node.insertBefore(nodeA, refAfterB)
                temp[i] = nodeB
                temp[o - 1] = nodeA
                s += 1; l -= 1; i += 1; o -= 1
              else:
                if fallbackMap.isNil:
                  fallbackMap = newJsMap[int, int]()
                  for idx in i ..< o:
                    fallbackMap[newItems[idx].id] = idx
                let targetIdx =
                  if items[s].id in fallbackMap: fallbackMap[items[s].id]
                  else: -1
                if targetIdx >= 0 and targetIdx >= i and targetIdx < o:
                  var runLen = 1
                  var probe = s + 1
                  while probe < l and probe < o:
                    let pi =
                      if items[probe].id in fallbackMap: fallbackMap[items[probe].id]
                      else: -1
                    if pi == targetIdx + runLen:
                      runLen += 1; probe += 1
                    else: break
                  if runLen > targetIdx - i:
                    let refNode = mapped[s]
                    while i < targetIdx:
                      temp[i] = createRowElement(newItems[i])
                      tbody.Node.insertBefore(temp[i], refNode)
                      i += 1
                  else:
                    temp[i] = mapped[s]
                    tbody.Node.replaceChild(mapped[s], temp[i])
                    s += 1; i += 1
                else:
                  tbody.Node.removeChild(mapped[s])
                  s += 1
            elif s >= l:
              let refNode = if o <= newEnd: temp[o] else: sentinel
              while i < o:
                temp[i] = createRowElement(newItems[i])
                tbody.Node.insertBefore(temp[i], refNode)
                i += 1
            else:
              while s < l:
                tbody.Node.removeChild(mapped[s])
                s += 1

        items = newItems
        mapped = temp

bootstrapHmr()
main()
