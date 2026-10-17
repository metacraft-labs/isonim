## MockRenderer replaces display transport only. Production list accessors,
## filter callbacks and effects are exercised after loop construction finishes.
import std/[unittest, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/dsl/components
import isonim/components/[task_manager, branded_controls, native_android_controls]
when not defined(js):
  import isonim/components/native_controls

suite "Per-item environments":
  test "keyed item and index accessors survive construction and reordering":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let parent = r.createElement("div")
      let items = createSignal(@["a", "b", "c"])
      var values: seq[proc(): string]
      var indexes: seq[proc(): int]
      forEachKeyed(r, parent, proc(): seq[string] = items.val,
        proc(item: proc(): string; index: proc(): int): MockNode =
          values.add item
          indexes.add index
          r.createTextNode(item()))
      for i, expected in ["a", "b", "c"]:
        check values[i]() == expected
        check indexes[i]() == i
      items.val = @["c", "a", "b"]
      for i, expected in ["a", "b", "c"]:
        check values[i]() == expected
        check indexes[i]() == (i + 1) mod 3
      dispose()

  test "branded and Android filter callbacks and highlights retain each filter":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let selected = createSignal(fmAll)
      let getFilter = proc(): FilterMode = selected.val
      let setFilter = proc(f: FilterMode) = selected.val = f
      let branded = branded_controls.createFilterBar[MockRenderer, MockNode](r, getFilter, setFilter)
      let android = native_android_controls.createFilterBar[MockRenderer, MockNode](r, getFilter, setFilter)
      for bar in [branded, android]:
        for i in [1, 0, 2, 0]:
          bar.children[i].fireEvent("click")
          check selected.val == FilterMode(i)
          for j in 0 ..< 3:
            check android.children[j].attributes["selected"] == $(j == i)
            check (branded.children[j].styles["background-color"] != "transparent") == (j == i)
      dispose()

  when not defined(js):
    test "native filter callbacks retain each filter":
      var selected = fmAll
      let bar = native_controls.createFilterBar[MockRenderer, MockNode](
        MockRenderer(), selected, proc(f: FilterMode) = selected = f, nil)
      for i in [1, 0, 2]:
        bar.children[i].fireEvent("click")
        check selected == FilterMode(i)

import "../demos/isonim-replica/src/components" as demo_components
import "../demos/isonim-replica/src/task_store" as demo_store

suite "Demo filter handlers":
  test "every footer filter chooses and highlights its own item":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let root = r.createElement("div")
      let store = demo_store.createTaskStore()
      store.addTask("Task")
      demo_components.renderTaskFooter(r, root, store)
      let pills = root.children[0].children[1].children
      require pills.len == 3
      for i in [1, 0, 2, 0]:
        pills[i].fireEvent("click")
        check store.filter.val == demo_store.Filter(i)
        for j, pill in pills:
          check pill.attributes["class"] == (if j == i: "selected" else: "")
      dispose()
