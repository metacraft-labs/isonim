## The shipped MockRenderer replaces display transport only; actual full app,
## TaskStore actions, input leaf and reactive keyed/conditional work execute.
## The companion Chromium gate separately tests native DOM/value/listener behavior.
import std/[unittest, tables]
import isonim/components/[task_app, branded_controls]
import isonim/core/[owner, signals, computation]
import isonim/testing/mock_dom

proc findElement(node: MockNode; tag: string; text = ""): MockNode =
  if node.tag == tag and (text.len == 0 or node.textContent == text): return node
  for child in node.children:
    let found = findElement(child, tag, text)
    if found != nil: return found

proc clickLabel(root: MockNode; text: string) =
  let label = findElement(root, "span", text)
  doAssert label != nil
  label.parent.fireEvent("click")

suite "actual branded task app":
  test "full app reads current input and drives actual task/filter actions":
    createRoot(proc(dispose: proc()) =
      let r = MockRenderer()
      let store = createTaskStore()
      let root = renderApp[MockRenderer, MockNode](r, store)
      let input = findElement(root, "input")
      let add = input.parent.children[1]
      check store.tasks.val.len == 0
      r.setAttribute(input, "value", "old default")
      r.setInputValue(input, "alpha")
      add.fireEvent("click")
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "alpha"
      check findElement(root, "span", "alpha") != nil
      check r.inputValue(input) == ""
      add.fireEvent("click")
      check store.tasks.val.len == 1
      r.setInputValue(input, "beta")
      add.fireEvent("click")
      let alphaRow = findElement(root, "span", "alpha").parent
      alphaRow.children[0].fireEvent("click")
      check store.tasks.val[0].completed
      check not store.tasks.val[1].completed
      clickLabel(root, "Active")
      check findElement(root, "span", "alpha") == nil
      check findElement(root, "span", "beta") != nil
      clickLabel(root, "Completed")
      check findElement(root, "span", "alpha") != nil
      check findElement(root, "span", "beta") == nil
      clickLabel(root, "All")
      findElement(root, "span", "beta").parent.children[2].fireEvent("click")
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "alpha"
      clickLabel(root, "Clear Completed")
      check store.tasks.val.len == 0
      check findElement(root, "span", "No tasks yet.\nTap + to add one.") != nil
      for text in ["gamma", "delta"]:
        r.setInputValue(input, text)
        add.fireEvent("click")
        check findElement(root, "span", text) != nil
      dispose()
    )

  test "input leaf preserves callback order and value when callback throws":
    createRoot(proc(dispose: proc()) =
      let r = MockRenderer()
      var calls = 0
      let row = createInputRow[MockRenderer, MockNode](r, "Controlled",
        proc(text: string) =
          inc calls
          check text == "preserve"
          raise newException(ValueError, "controlled callback failure")
      )
      let input = row.children[0]
      r.setInputValue(input, "preserve")
      expect ValueError: row.children[1].fireEvent("click")
      check calls == 1
      check r.inputValue(input) == "preserve"
      dispose()
    )
