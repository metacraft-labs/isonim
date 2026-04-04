## js-framework-benchmark implementation for IsoNim
## Keyed implementation using Signal-based reactive rows
## Uses SolidJS-style mapArray for efficient keyed DOM reconciliation.

when not defined(js):
  {.error: "benchmark main.nim requires the JS backend".}

import isonim/core/js_collections
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/core/signals
import isonim/rxcore

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

# Use Math.random() directly instead of std/random to avoid pulling in
# Nim's Rand value type (which triggers nimCopy for BigInt fields).
proc jsRandom(max: int): int =
  {.emit: [result, " = (Math.random() * ", max, ") | 0;"].}

type
  Row = ref object
    id: int
    label: Signal[cstring]

  Rows = JsArray[Row]
    ## Native JS array of Row refs. Assignment copies the reference
    ## (not the data), matching SolidJS behavior. Eliminates nimCopy
    ## on every signal read/write.

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
    result[i] = Row(id: nextId, label: createSignal(randomLabel()))
    inc nextId

# JS type conversion helpers — avoid Nim string intermediaries
proc jsParseInt(s: cstring): int =
  {.emit: [result, " = parseInt(", s, ", 10) || 0;"].}

proc jsIntToStr(n: int): cstring =
  {.emit: [result, " = String(", n, ");"].}

# ---- Row template ----

let rowTmpl = tmpl(
  "<tr><td class='col-md-1'></td>" &
  "<td class='col-md-4'><a> </a></td>" &
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

  # Set the id column
  td1.textContent = jsIntToStr(row.id)

  # Single combined effect for label + selection (matches SolidJS pattern)
  let textNode = selectLink.firstChild  # the " " text node from template
  var prevClass: cstring
  var prevLabel: cstring

  createRenderEffect proc() =
    let cls = if selected.val == row.id: cstring"danger" else: cstring""
    let lbl = row.label.val
    if cls != prevClass:
      prevClass = cls
      if cls.len == 0:
        {.emit: [tr, ".removeAttribute('class');"].}
      else:
        Element(tr).className = cls
    if lbl != prevLabel:
      prevLabel = lbl
      {.emit: [textNode, ".data = ", lbl, ";"].}

  # Store row id for event delegation
  let rowIdStr = jsIntToStr(row.id)
  {.emit: [selectLink, ".$$rowId = ", rowIdStr, ";"].}
  {.emit: [deleteLink, ".$$rowId = ", rowIdStr, ";"].}

  # Click to select (delegated)
  selectLink.setJsPropHandler(cstring"$$click", proc(ev: Event) =
    var rowIdCstr: cstring
    {.emit: [rowIdCstr, " = ", ev.target, ".$$rowId || ", ev.target, ".parentNode.$$rowId || '';"].}
    let rowId = jsParseInt(rowIdCstr)
    if selected.val == rowId:
      selected.val = 0
    else:
      selected.val = rowId
  )

  # Click to delete (delegated) — SolidJS uses .toSpliced()
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

# ---- App ----

proc main() =
  # No randomize() needed — using Math.random() directly

  createRoot proc(dispose: proc()) =
    data = createSignal(newJsArray[Row](), equals = proc(a, b: Rows): bool = false)
    selected = createSignal(0)

    let tbody = document.getElementById("tbody")

    # Delegate click events at document level
    delegateEvents([cstring"click"])

    # Wire up buttons
    let runBtn = document.getElementById("run")
    let runlotsBtn = document.getElementById("runlots")
    let addBtn = document.getElementById("add")
    let updateBtn = document.getElementById("update")
    let clearBtn = document.getElementById("clear")
    let swaprowsBtn = document.getElementById("swaprows")

    runBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      data.val = buildData(1000)
    )

    runlotsBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      data.val = buildData(10000)
    )

    addBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      let rows = data.val
      let extra = buildData(1000)
      # Concat creates a new array — mapArray needs distinct refs
      var combined: Rows
      {.emit: [combined, " = ", rows, ".concat(", extra, ");"].}
      data.val = combined
    )

    updateBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      let rows = data.val
      var i = 0
      while i < rows.len:
        rows[i].label.val = rows[i].label.val & cstring" !!!"
        i += 10
    )

    clearBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      data.val = newJsArray[Row]()
    )

    swaprowsBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      let rows = data.val
      if rows.len > 998:
        # Must .slice() like SolidJS — mapArray compares old vs new arrays
        # by identity. In-place mutation on the same ref is invisible.
        var copy: Rows
        {.emit: [copy, " = ", rows, ".slice();"].}
        copy.swap(1, 998)
        data.val = copy
    )

    # SolidJS-style mapArray: keyed list rendering with persistent
    # items/mapped arrays. Only creates/moves/removes what changed.
    # Prefix/suffix scan makes swap O(1) DOM ops.
    block:
      var items = newJsArray[Row]()
      var mapped = newJsArray[Node]()

      createEffect proc() =
        let newItems = data.val
        let newLen = newItems.len
        let oldLen = items.len

        # Fast path: empty list — clear all
        if newLen == 0:
          for i in 0 ..< oldLen:
            tbody.Node.removeChild(mapped[i])
          items = newJsArray[Row]()
          mapped = newJsArray[Node]()
          return

        # Fast path: first run — create all
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

        # 1. Skip common prefix (identity match)
        var start = 0
        let minLen = if oldLen < newLen: oldLen else: newLen
        while start < minLen and items[start] == newItems[start]:
          temp[start] = mapped[start]
          start += 1

        # 2. Skip common suffix (identity match)
        var oldEnd = oldLen - 1
        var newEnd = newLen - 1
        while oldEnd >= start and newEnd >= start and items[oldEnd] == newItems[newEnd]:
          temp[newEnd] = mapped[oldEnd]
          oldEnd -= 1
          newEnd -= 1

        # 3. Reconcile the changed middle range.
        # Follows SolidJS's dom-expressions reconcile algorithm:
        # two-pointer walk with swap detection and lazy Map fallback.
        if start <= newEnd:
          var s = start       # old pointer (front)
          var l = oldEnd + 1  # old pointer (back, exclusive)
          var i = start       # new pointer (front)
          var o = newEnd + 1  # new pointer (back, exclusive)
          let sentinel = if l < oldLen: mapped[l].nextSibling else: nil
          var fallbackMap: JsMap[int, int]  # lazy: only built if needed

          while s < l or i < o:
            if s < l and i < o and items[s] == newItems[i]:
              # Match at front — no move needed
              temp[i] = mapped[s]
              s += 1; i += 1
            elif s < l and i < o and items[s] != newItems[i]:
              # Mismatch — shrink from back first
              while l > s and o > i and items[l - 1] == newItems[o - 1]:
                l -= 1; o -= 1
                temp[o] = mapped[l]

              if l == s:
                # Only insertions remain
                let refNode = if o < newEnd + 1:
                  (if i > start: temp[i - 1].nextSibling else: temp[o])
                else: sentinel
                while i < o:
                  temp[i] = createRowElement(newItems[i])
                  tbody.Node.insertBefore(temp[i], refNode)
                  i += 1
              elif o == i:
                # Only deletions remain
                while s < l:
                  tbody.Node.removeChild(mapped[s])
                  s += 1
              elif items[s] == newItems[o - 1] and newItems[i] == items[l - 1]:
                # *** SWAP DETECTION ***
                # Old front = new back AND new front = old back → swap
                let nextSib = mapped[s].nextSibling
                temp[i] = mapped[l - 1]
                tbody.Node.insertBefore(mapped[l - 1], nextSib)
                temp[o - 1] = mapped[s]
                let backRef = if o < newEnd + 1: temp[o].Node else: sentinel
                tbody.Node.insertBefore(mapped[s], backRef)
                s += 1; l -= 1; i += 1; o -= 1
              else:
                # General case — lazy Map fallback
                if fallbackMap.isNil:
                  fallbackMap = newJsMap[int, int]()
                  for idx in i ..< o:
                    fallbackMap[newItems[idx].id] = idx
                let targetIdx = if items[s].id in fallbackMap: fallbackMap[items[s].id] else: -1
                if targetIdx >= 0 and targetIdx >= i and targetIdx < o:
                  # Found in new list — check for contiguous run
                  var runLen = 1
                  var probe = s + 1
                  while probe < l and probe < o:
                    let pi = if items[probe].id in fallbackMap: fallbackMap[items[probe].id] else: -1
                    if pi == targetIdx + runLen:
                      runLen += 1; probe += 1
                    else: break
                  if runLen > targetIdx - i:
                    # Insert missing new nodes before the run
                    let refNode = mapped[s]
                    while i < targetIdx:
                      temp[i] = createRowElement(newItems[i])
                      tbody.Node.insertBefore(temp[i], refNode)
                      i += 1
                  else:
                    # Replace
                    temp[i] = mapped[s]
                    tbody.Node.replaceChild(mapped[s], temp[i])
                    s += 1; i += 1
                else:
                  # Not found — old item was removed
                  tbody.Node.removeChild(mapped[s])
                  s += 1
            elif s >= l:
              # Old exhausted — insert remaining new
              let refNode = if o <= newEnd: temp[o] else: sentinel
              while i < o:
                temp[i] = createRowElement(newItems[i])
                tbody.Node.insertBefore(temp[i], refNode)
                i += 1
            else:
              # New exhausted — remove remaining old
              while s < l:
                tbody.Node.removeChild(mapped[s])
                s += 1

        items = newItems  # JsArray ref copy — free
        mapped = temp

main()
