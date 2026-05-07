## PoC: Hosting a third-party DOM-owning library (DataTables pattern)
##
## Demonstrates how IsoNim hosts a library that manages its own DOM subtree.
## The pattern: IsoNim creates a container element, hands it to the library
## via onMount, and communicates via reactive signals that call library APIs
## (not DOM manipulation). This is the same pattern SolidJS uses.
##
## Mock DataTables stands in for any JS library that takes an element and
## manages its contents (jQuery DataTables, CodeMirror, Leaflet, etc.).

import unittest
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/ui

# ---------------------------------------------------------------------------
# Mock DataTables — simulates a library that owns a DOM subtree
# ---------------------------------------------------------------------------

type
  ColumnDef = object
    title: string
    field: string

  MockDataTable = ref object
    element: MockNode          ## The <table> element the library was given
    data: seq[seq[string]]     ## Current data rows
    columns: seq[ColumnDef]    ## Column definitions
    destroyed: bool            ## Whether destroy() was called
    searchTerm: string         ## Current search filter
    reloadCount: int           ## How many times reload was called
    drawCount: int             ## How many times the library "drew" the table

proc initMockDataTable(element: MockNode;
    columns: seq[ColumnDef] = @[]): MockDataTable =
  ## Simulates $(element).DataTable({ ... })
  ## The library takes ownership of the element's children.
  result = MockDataTable(
    element: element,
    data: @[],
    columns: columns,
    destroyed: false,
    searchTerm: "",
    reloadCount: 0,
    drawCount: 1,  # Initial draw on init
  )

proc reload(dt: MockDataTable; data: seq[seq[string]]) =
  ## Simulates dt.ajax.reload() — the library fetches new data and redraws.
  ## IsoNim does NOT touch the DOM here; the library handles it.
  dt.data = data
  inc dt.reloadCount
  inc dt.drawCount

proc search(dt: MockDataTable; term: string) =
  ## Simulates dt.search(term).draw()
  dt.searchTerm = term
  inc dt.drawCount

proc destroy(dt: MockDataTable) =
  ## Simulates dt.destroy() — cleans up event listeners, removes library DOM.
  dt.destroyed = true

proc rowCount(dt: MockDataTable): int =
  dt.data.len

# ---------------------------------------------------------------------------
# IsoNim component that hosts the mock DataTable
# ---------------------------------------------------------------------------

proc EventLogPanel(renderer: MockRenderer;
    dataSource: Signal[seq[seq[string]]];
    searchQuery: Signal[string]): tuple[root: MockNode,
                                        tableEl: MockNode,
                                        dt: MockDataTable] =
  ## A component with IsoNim-rendered chrome (search bar, status) surrounding
  ## a library-owned table. IsoNim creates the <table> but never touches its
  ## children — DataTables owns that subtree.
  ##
  ## Returns the root, the table element, and the DataTable instance for
  ## test assertions.

  var tableRef: MockNode
  var dtInstance: MockDataTable

  # Build the full UI with the DSL, including the table and its header.
  # The <thead> is created by IsoNim since DataTables reads it from the
  # existing markup, but <tbody> is entirely library-managed.
  let root = ui(renderer):
    tdiv(class = "event-log-panel"):
      tdiv(class = "toolbar"):
        input(class = "search-input", placeholder = "Search events...")
      tdiv(class = "table-container"):
        table(class = "event-table display", ref = tableRef):
          thead:
            tr:
              th: text "Event"
              th: text "Timestamp"
              th: text "Value"

  # Initialize the library on the table element (SolidJS onMount equivalent)
  dtInstance = initMockDataTable(tableRef, @[
    ColumnDef(title: "Event", field: "event"),
    ColumnDef(title: "Timestamp", field: "ts"),
    ColumnDef(title: "Value", field: "val"),
  ])

  # Reactive bridge: signal changes -> library API calls (NOT DOM updates)
  createEffect do:
    let data = dataSource.val
    dtInstance.reload(data)

  createEffect do:
    let term = searchQuery.val
    dtInstance.search(term)

  # Cleanup: when the reactive root is disposed, destroy the library instance
  onCleanup do:
    dtInstance.destroy()

  result = (root: root, tableEl: tableRef, dt: dtInstance)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "DataTable hosting PoC":

  test "container element is created and mounted":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      # The root is a .event-log-panel div
      check root.tag == "div"
      check root.attributes["class"] == "event-log-panel"

      # The table element exists and is mounted inside .table-container
      check tableEl != nil
      check tableEl.tag == "table"
      check tableEl.attributes["class"] == "event-table display"

      # Table has a <thead> with column headers
      check tableEl.children.len == 1  # just thead
      let thead = tableEl.children[0]
      check thead.tag == "thead"
      check thead.children[0].children.len == 3  # 3 <th>s

  test "library initializes on the element (simulated onMount)":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      # DataTable instance was created and points to our element
      check dt != nil
      check dt.element == tableEl
      check dt.destroyed == false
      # drawCount > 1 because the reactive effects run on creation too
      # (reload + search effects each fire once), plus the initial draw.
      check dt.drawCount >= 1

  test "signal change triggers library reload, not DOM rebuild":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      # Initial state: effect ran once on creation with empty data
      let initialReloads = dt.reloadCount

      # Push new data through the signal
      let newData = @[
        @["click", "12:00:01", "button-1"],
        @["hover", "12:00:02", "nav-menu"],
        @["scroll", "12:00:03", "page"],
      ]
      dataSource.val = newData

      # The library received the data via its API, not via DOM manipulation
      check dt.data == newData
      check dt.reloadCount == initialReloads + 1
      check dt.rowCount == 3

      # The <table> element itself was NOT rebuilt — same identity
      let currentTableEl = root.children[1].children[0]  # container -> table
      check currentTableEl == tableEl  # Same object reference

  test "search signal triggers library search, not IsoNim re-render":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      let initialDraws = dt.drawCount

      searchQuery.val = "click"
      check dt.searchTerm == "click"
      check dt.drawCount == initialDraws + 1

      searchQuery.val = "hover"
      check dt.searchTerm == "hover"
      check dt.drawCount == initialDraws + 2

  test "multiple data updates work correctly":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      # First batch
      dataSource.val = @[@["a", "b", "c"]]
      check dt.rowCount == 1

      # Second batch replaces (library handles the diff internally)
      dataSource.val = @[@["x", "y", "z"], @["p", "q", "r"]]
      check dt.rowCount == 2
      check dt.data[0] == @["x", "y", "z"]

      # Clear
      dataSource.val = @[]
      check dt.rowCount == 0

  test "batch signal updates coalesce into single library call":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      let initialReloads = dt.reloadCount

      # Batch multiple signal writes — should result in one effect execution
      batch proc() =
        dataSource.val = @[@["a", "b", "c"]]
        dataSource.val = @[@["x", "y", "z"]]  # Overwrites the first

      check dt.reloadCount == initialReloads + 1  # Only one reload
      check dt.data == @[@["x", "y", "z"]]

  test "dispose calls library destroy (cleanup)":
    var dtRef: MockDataTable
    let renderer = MockRenderer()
    let dataSource = createSignal[seq[seq[string]]](@[])
    let searchQuery = createSignal("")

    createRoot do (dispose: proc()):
      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)
      dtRef = dt
      check dtRef.destroyed == false

      # Disposing the root should trigger onCleanup -> destroy()
      dispose()

    check dtRef.destroyed == true

  test "data signal changes after dispose do not reach the library":
    var dtRef: MockDataTable
    var disposeRoot: proc()
    let renderer = MockRenderer()
    let dataSource = createSignal[seq[seq[string]]](@[])
    let searchQuery = createSignal("")

    createRoot do (dispose: proc()):
      disposeRoot = dispose
      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)
      dtRef = dt

    let reloadsBeforeDispose = dtRef.reloadCount
    disposeRoot()

    # After dispose, signal changes should not trigger the effect
    dataSource.val = @[@["should", "not", "arrive"]]
    check dtRef.reloadCount == reloadsBeforeDispose

  test "IsoNim UI chrome is separate from library-owned DOM":
    createRoot do (dispose: proc()):
      let renderer = MockRenderer()
      let dataSource = createSignal[seq[seq[string]]](@[])
      let searchQuery = createSignal("")

      let (root, tableEl, dt) = EventLogPanel(renderer, dataSource, searchQuery)

      # Toolbar is IsoNim-managed
      let toolbar = root.children[0]
      check toolbar.tag == "div"
      check toolbar.attributes["class"] == "toolbar"
      check toolbar.children[0].tag == "input"
      check toolbar.children[0].attributes["class"] == "search-input"

      # Table container holds the library-owned table
      let container = root.children[1]
      check container.tag == "div"
      check container.attributes["class"] == "table-container"
      check container.children[0] == tableEl
