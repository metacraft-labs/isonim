import unittest
import std/tables
import isonim/rxcore
import isonim/testing/mock_dom

suite "rxcore API":
  test "root creates reactive root":
    var disposed = false
    root proc(dispose: proc()) =
      dispose()
      disposed = true
    check disposed == true

  test "effect tracks and re-runs":
    root proc(dispose: proc()) =
      let s = createSignal(0)
      var observed = -1
      effect proc() =
        observed = s.val
      check observed == 0
      s.val = 5
      check observed == 5

  test "memo creates cached accessor":
    root proc(dispose: proc()) =
      let s = createSignal(3)
      let doubled = memo(proc(): int = s.val * 2)
      check doubled() == 6
      s.val = 10
      check doubled() == 20

  test "createComponent invokes under untrack":
    root proc(dispose: proc()) =
      let s = createSignal(0)

      type Props = object
        value: int

      let result = createComponent(
        proc(p: Props): string =
          # Reading a signal here should NOT create a dependency
          # on the parent computation (because createComponent uses untrack)
          return "component:" & $p.value,
        Props(value: 42)
      )
      check result == "component:42"

  test "mergeProps returns overrides":
    type MyProps = object
      x: int
      y: string
    let base = MyProps(x: 1, y: "hello")
    let over = MyProps(x: 2, y: "world")
    let merged = mergeProps(base, over)
    check merged.x == 2
    check merged.y == "world"

suite "MockRenderer":
  test "createElement creates element node":
    let r = MockRenderer()
    let el = r.createElement("div")
    check el.kind == mnkElement
    check el.tag == "div"

  test "createTextNode creates text node":
    let r = MockRenderer()
    let t = r.createTextNode("hello")
    check t.kind == mnkText
    check t.text == "hello"

  test "appendChild builds tree":
    let r = MockRenderer()
    let parent = r.createElement("div")
    let child1 = r.createElement("span")
    let child2 = r.createTextNode("text")
    r.appendChild(parent, child1)
    r.appendChild(parent, child2)
    check parent.children.len == 2
    check parent.children[0] == child1
    check parent.children[1] == child2
    check child1.parent == parent

  test "insertBefore inserts at correct position":
    let r = MockRenderer()
    let parent = r.createElement("div")
    let first = r.createElement("first")
    let last = r.createElement("last")
    let middle = r.createElement("middle")
    r.appendChild(parent, first)
    r.appendChild(parent, last)
    r.insertBefore(parent, middle, last)
    check parent.children[0] == first
    check parent.children[1] == middle
    check parent.children[2] == last

  test "removeChild removes node":
    let r = MockRenderer()
    let parent = r.createElement("div")
    let child = r.createElement("span")
    r.appendChild(parent, child)
    check parent.children.len == 1
    r.removeChild(parent, child)
    check parent.children.len == 0
    check child.parent == nil

  test "setAttribute and removeAttribute":
    let r = MockRenderer()
    let el = r.createElement("div")
    r.setAttribute(el, "class", "container")
    check el.attributes["class"] == "container"
    r.removeAttribute(el, "class")
    check "class" notin el.attributes

  test "setStyle":
    let r = MockRenderer()
    let el = r.createElement("div")
    r.setStyle(el, "color", "red")
    check el.styles["color"] == "red"

  test "addEventListener and fireEvent":
    let r = MockRenderer()
    let btn = r.createElement("button")
    var clicked = false
    r.addEventListener(btn, "click", proc() = clicked = true)
    check clicked == false
    btn.fireEvent("click")
    check clicked == true

  test "firstChild and nextSibling navigation":
    let r = MockRenderer()
    let parent = r.createElement("div")
    let a = r.createElement("a")
    let b = r.createElement("b")
    let c = r.createElement("c")
    r.appendChild(parent, a)
    r.appendChild(parent, b)
    r.appendChild(parent, c)
    check r.firstChild(parent) == a
    check r.nextSibling(a) == b
    check r.nextSibling(b) == c
    check r.nextSibling(c) == nil

  test "textContent helper":
    let r = MockRenderer()
    let container = r.createElement("div")
    let span = r.createElement("span")
    let t1 = r.createTextNode("hello ")
    let t2 = r.createTextNode("world")
    r.appendChild(span, t1)
    r.appendChild(container, span)
    r.appendChild(container, t2)
    check container.textContent == "hello world"

  test "setTextContent on element replaces children":
    let r = MockRenderer()
    let container = r.createElement("div")
    let child = r.createElement("span")
    r.appendChild(container, child)
    check container.children.len == 1
    r.setTextContent(container, "replaced")
    check container.children.len == 1
    check container.children[0].kind == mnkText
    check container.children[0].text == "replaced"

suite "rxcore + MockRenderer integration":
  test "reactive text update via effect":
    let r = MockRenderer()
    root proc(dispose: proc()) =
      let name = createSignal("world")
      let container = r.createElement("div")
      let textNode = r.createTextNode("")
      r.appendChild(container, textNode)

      effect proc() =
        r.setTextContent(textNode, "hello " & name.val)

      check textNode.text == "hello world"
      name.val = "IsoNim"
      check textNode.text == "hello IsoNim"

  test "reactive attribute update via effect":
    let r = MockRenderer()
    root proc(dispose: proc()) =
      let cls = createSignal("primary")
      let el = r.createElement("div")

      effect proc() =
        r.setAttribute(el, "class", cls.val)

      check el.attributes["class"] == "primary"
      cls.val = "secondary"
      check el.attributes["class"] == "secondary"

  test "memo-driven rendering":
    let r = MockRenderer()
    root proc(dispose: proc()) =
      let count = createSignal(0)
      let label = memo(proc(): string = "Count: " & $count.val)
      let el = r.createElement("span")
      let textNode = r.createTextNode("")
      r.appendChild(el, textNode)

      effect proc() =
        r.setTextContent(textNode, label())

      check textNode.text == "Count: 0"
      count.val = 42
      check textNode.text == "Count: 42"
