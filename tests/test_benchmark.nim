## Tests for the js-framework-benchmark data model (M8).
## These tests verify the benchmark logic on both C and JS backends.

import unittest
import std/[random, strutils]
import isonim/core/[signals, graph, batch]
import isonim/rxcore

# ---- Data model (duplicated from benchmark for backend-portable testing) ----

const adjectives = [
  "pretty", "large", "big", "small", "tall", "short", "long", "handsome",
  "plain", "quaint", "clean", "elegant", "easy", "angry", "crazy", "helpful",
  "mushy", "odd", "unsightly", "adorable", "important", "inexpensive",
  "cheap", "expensive", "fancy"
]

const colours = [
  "red", "yellow", "blue", "green", "pink", "brown", "purple", "brown",
  "white", "black", "orange"
]

const nouns = [
  "table", "chair", "house", "bbq", "desk", "car", "pony", "cookie",
  "sandwich", "burger", "pizza", "mouse", "keyboard"
]

type
  Row = ref object
    id: int
    label: Signal[string]

var nextId = 1

proc randomLabel(): string =
  adjectives[rand(adjectives.high)] & " " &
    colours[rand(colours.high)] & " " &
    nouns[rand(nouns.high)]

proc buildData(count: int): seq[Row] =
  result = newSeq[Row](count)
  for i in 0 ..< count:
    result[i] = Row(id: nextId, label: createSignal(randomLabel()))
    inc nextId

proc resetNextId() =
  nextId = 1

suite "Benchmark Data Model":
  setup:
    resetNextId()
    randomize(42)  # deterministic seed for tests

  test "buildData creates correct number of rows":
    let rows = buildData(1000)
    check rows.len == 1000

  test "buildData assigns unique sequential ids":
    let rows = buildData(100)
    for i in 0 ..< rows.len:
      check rows[i].id == i + 1

  test "buildData generates non-empty labels":
    let rows = buildData(10)
    for row in rows:
      check row.label.val.len > 0

  test "labels contain three words":
    let rows = buildData(50)
    for row in rows:
      var spaceCount = 0
      for c in row.label.val:
        if c == ' ':
          inc spaceCount
      check spaceCount == 2  # two spaces => three words

  test "ids are globally incrementing across calls":
    let batch1 = buildData(5)
    let batch2 = buildData(5)
    check batch1[^1].id < batch2[0].id
    check batch2[0].id == 6
    check batch2[^1].id == 10

suite "Benchmark Operations":
  setup:
    resetNextId()
    randomize(42)

  test "create replaces data with 1000 rows":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(1000)
    check data.val.len == 1000

  test "create 10k rows":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(10000)
    check data.val.len == 10000

  test "append adds 1000 rows to existing":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(1000)
    check data.val.len == 1000
    var rows = data.val
    rows.add(buildData(1000))
    data.val = rows
    check data.val.len == 2000

  test "update every 10th row appends exclamation marks":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(100)
    let rows = data.val
    var i = 0
    while i < rows.len:
      rows[i].label.val = rows[i].label.val & " !!!"
      i += 10
    # Check that updated rows end with " !!!"
    check rows[0].label.val.endsWith(" !!!")
    check rows[10].label.val.endsWith(" !!!")
    check rows[20].label.val.endsWith(" !!!")
    # Check that non-updated rows do not
    check not rows[1].label.val.endsWith(" !!!")
    check not rows[5].label.val.endsWith(" !!!")

  test "clear removes all rows":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(1000)
    check data.val.len == 1000
    data.val = newSeq[Row]()
    check data.val.len == 0

  test "swap exchanges rows at indices 1 and 998":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(1000)
    var rows = data.val
    let id1 = rows[1].id
    let id998 = rows[998].id
    let label1 = rows[1].label.val
    let label998 = rows[998].label.val

    let tmp = rows[1]
    rows[1] = rows[998]
    rows[998] = tmp
    data.val = rows

    check data.val[1].id == id998
    check data.val[998].id == id1
    check data.val[1].label.val == label998
    check data.val[998].label.val == label1

  test "swap is no-op when fewer than 999 rows":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(5)
    var rows = data.val
    let originalIds = @[rows[0].id, rows[1].id, rows[2].id, rows[3].id, rows[4].id]
    if rows.len > 998:
      let tmp = rows[1]
      rows[1] = rows[998]
      rows[998] = tmp
    data.val = rows
    # Should be unchanged
    for i in 0 ..< rows.len:
      check data.val[i].id == originalIds[i]

  test "remove deletes a single row by id":
    let data = createSignal(newSeq[Row]())
    data.val = buildData(10)
    var rows = data.val
    let targetId = rows[5].id
    for i in 0 ..< rows.len:
      if rows[i].id == targetId:
        rows.delete(i)
        break
    data.val = rows
    check data.val.len == 9
    for row in data.val:
      check row.id != targetId

  test "select toggles selection signal":
    let selected = createSignal(0)
    check selected.val == 0
    selected.val = 42
    check selected.val == 42
    # Toggle off by setting same id
    selected.val = 0
    check selected.val == 0

suite "Benchmark Reactive Integration":
  setup:
    resetNextId()
    randomize(42)

  test "signal labels are reactive":
    var effectCount = 0
    let row = Row(id: 1, label: createSignal("initial"))

    createRoot proc(dispose: proc()) =
      createEffect proc() =
        discard row.label.val
        inc effectCount

      check effectCount == 1
      row.label.val = "updated"
      check effectCount == 2
      row.label.val = "updated again"
      check effectCount == 3
      dispose()

  test "data signal triggers effect on replacement":
    var effectCount = 0
    let data = createSignal(newSeq[Row]())

    createRoot proc(dispose: proc()) =
      createEffect proc() =
        discard data.val
        inc effectCount

      check effectCount == 1
      data.val = buildData(10)
      check effectCount == 2
      data.val = newSeq[Row]()
      check effectCount == 3
      dispose()

  test "selected signal triggers effect":
    var effectCount = 0
    let selected = createSignal(0)

    createRoot proc(dispose: proc()) =
      createEffect proc() =
        discard selected.val
        inc effectCount

      check effectCount == 1
      selected.val = 5
      check effectCount == 2
      selected.val = 5  # same value — should NOT trigger
      check effectCount == 2
      selected.val = 0
      check effectCount == 3
      dispose()

  test "update operation triggers per-row label effects":
    var updates = 0

    createRoot proc(dispose: proc()) =
      let rows = buildData(30)
      # Track effect on a single row
      let trackedRow = rows[10]
      createEffect proc() =
        discard trackedRow.label.val
        inc updates

      check updates == 1  # initial effect run
      # Update the tracked row's label
      trackedRow.label.val = trackedRow.label.val & " !!!"
      check updates == 2  # effect should fire once more

      # Update a non-tracked row — should not affect our counter
      rows[5].label.val = rows[5].label.val & " !!!"
      check updates == 2

      dispose()
