## js-framework-benchmark implementation for IsoNim
## Keyed implementation using Signal-based reactive rows
## Uses reconcileArrays for efficient keyed DOM reconciliation.

when not defined(js):
  {.error: "benchmark main.nim requires the JS backend".}

import isonim/core/js_collections
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/core/signals
import isonim/core/reconcile
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

# ---- Minimal browser renderer for reconcileArrays ----

type BrowserRenderer = object

proc appendChild(r: BrowserRenderer, parent: Node, child: Node) =
  parent.appendChild(child)

proc insertBefore(r: BrowserRenderer, parent: Node, child: Node, refNode: Node) =
  parent.insertBefore(child, refNode)

proc removeChild(r: BrowserRenderer, parent: Node, child: Node) =
  parent.removeChild(child)

proc parentNode(r: BrowserRenderer, node: Node): Node =
  node.parentNode

proc nextSibling(r: BrowserRenderer, node: Node): Node =
  node.nextSibling

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
    # Filter out the deleted row — creates a new array so signal detects change
    var filtered: Rows
    {.emit: [filtered, " = ", rows, ".filter(function(r) { return r.id !== ", rowId, "; });"].}
    data.val = filtered
  )

  return tr

# ---- App ----

proc main() =
  # No randomize() needed — using Math.random() directly

  createRoot proc(dispose: proc()) =
    data = createSignal(newJsArray[Row]())
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

    # Node cache: row.id -> DOM node
    var nodeMap = newJsMap[int, Node]()
    # Current DOM nodes tracked for reconciliation
    var currentNodes = newJsArray[Node]()

    runBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      nodeMap.clear()
      data.val = buildData(1000)
    )

    runlotsBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      nodeMap.clear()
      data.val = buildData(10000)
    )

    addBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      let rows = data.val
      let extra = buildData(1000)
      # Concat: create new array with old + new rows
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
      nodeMap.clear()
      data.val = newJsArray[Row]()
    )

    swaprowsBtn.Node.addEventListener(cstring"click", proc(ev: Event) =
      let rows = data.val
      if rows.len > 998:
        # Shallow copy so signal detects change (ref identity differs)
        var copy: Rows
        {.emit: [copy, " = ", rows, ".slice();"].}
        copy.swap(1, 998)
        data.val = copy
    )

    # Render rows reactively using keyed reconciliation
    createEffect proc() =
      let rows = data.val

      # Build new node list, reusing existing DOM nodes for known rows
      var newNodes = newJsArray[Node](rows.len)
      for i in 0 ..< rows.len:
        let row = rows[i]
        if row.id in nodeMap:
          newNodes[i] = nodeMap[row.id]
        else:
          let node = createRowElement(row)
          nodeMap[row.id] = node
          newNodes[i] = node

      # Remove entries from nodeMap for rows no longer present
      var activeIds = newJsSet[int]()
      for row in rows:
        activeIds.incl(row.id)
      var toRemove = newJsArray[int]()
      for id in nodeMap.keys:
        if id notin activeIds:
          toRemove.add(id)
      for id in toRemove:
        nodeMap.del(id)

      # Reconcile the DOM - moves/inserts/removes only what changed
      # Cast JsArray → seq for the reconciler (zero-cost on JS, same underlying array)
      var curSeq = currentNodes.toSeq
      reconcileArrays(BrowserRenderer(), tbody.Node, curSeq, newNodes.toSeq)
      currentNodes = curSeq.toJsArray

main()
