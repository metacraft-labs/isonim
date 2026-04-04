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

  # Set the id column
  td1.textContent = jsIntToStr(row.id)

  # Set the label reactively
  insert(selectLink, proc(): cstring = row.label.val)

  # Highlight when selected
  effect proc() =
    if selected.val == row.id:
      Element(tr).className = "danger"
    else:
      Element(tr).className = ""

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

  # Click to delete (delegated)
  deleteLink.setJsPropHandler(cstring"$$click", proc(ev: Event) =
    var rowIdCstr: cstring
    {.emit: [rowIdCstr, " = ", ev.target, ".$$rowId || ", ev.target, ".parentNode.$$rowId || '';"].}
    let rowId = jsParseInt(rowIdCstr)
    let rows = data.val
    for i in 0 ..< rows.len:
      if rows[i].id == rowId:
        rows.splice(i, 1)
        break
    data.val = rows  # always fires (equals = false)
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
      for r in extra:
        rows.push(r)
      data.val = rows
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
        rows.swap(1, 998)
        data.val = rows  # always fires (equals = false)
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

        # 3. Process the changed middle range
        if start <= newEnd:
          # Build a map from old Row identity → old index
          var oldMap = newJsMap[int, int]()  # row.id → old index
          for i in start .. oldEnd:
            oldMap[items[i].id] = i

          for i in start .. newEnd:
            let rowId = newItems[i].id
            if rowId in oldMap:
              temp[i] = mapped[oldMap[rowId]]
              oldMap.del(rowId)
            else:
              # Genuinely new item — create DOM node
              temp[i] = createRowElement(newItems[i])

          # Remove DOM nodes for deleted items (remaining in oldMap)
          let removedKeys = oldMap.keysArray()
          for i in 0 ..< removedKeys.len:
            let idx = oldMap[removedKeys[i]]
            tbody.Node.removeChild(mapped[idx])

        # 4. Reconcile DOM order for the changed range.
        # Walk backwards, inserting before the next sibling.
        # The nextSibling check skips nodes already in position.
        for i in countdown(newEnd, start):
          let node = temp[i]
          let nextNode = if i + 1 < newLen: temp[i + 1] else: nil
          if node.nextSibling != nextNode:
            if nextNode.isNodeNil:
              tbody.Node.appendChild(node)
            else:
              tbody.Node.insertBefore(node, nextNode)

        items = newItems  # JsArray ref copy — free
        mapped = temp

main()
