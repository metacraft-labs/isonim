## test_renderer_element_nav.nim
##
## The element-navigation and form-state calls a view generic over its
## renderer uses to walk a subtree it built and to set a control's state:
## `firstElementChild`, `nextElementSibling`, `isNilNode`, `setChecked`
## (plus the existing `getAttribute`, `inputValue`, `setInputValue`).
## Driven through `MockRenderer`; `tests/test_web.nim` drives the same calls
## through `WebRenderer` over its DOM shim.

import std/unittest

import isonim/testing/mock_dom

suite "MockRenderer element navigation":

  test "firstElementChild skips text nodes; nil when there is no element":
    let r = MockRenderer()
    let parent = r.createElement("div")
    r.appendChild(parent, r.createTextNode("lead"))
    let first = r.createElement("span")
    r.appendChild(parent, first)
    check r.firstElementChild(parent) == first
    let empty = r.createElement("div")
    r.appendChild(empty, r.createTextNode("only text"))
    check r.isNilNode(r.firstElementChild(empty))

  test "nextElementSibling walks elements in order and ends in nil":
    let r = MockRenderer()
    let parent = r.createElement("ul")
    let a = r.createElement("li")
    let b = r.createElement("li")
    r.appendChild(parent, a)
    r.appendChild(parent, r.createTextNode(" "))
    r.appendChild(parent, b)
    check r.nextElementSibling(a) == b
    check r.isNilNode(r.nextElementSibling(b))
    check r.isNilNode(r.nextElementSibling(parent))   # detached: no siblings

  test "setChecked records the state as the checked attribute":
    let r = MockRenderer()
    let box = r.createElement("input")
    r.setChecked(box, true)
    check r.getAttribute(box, "checked") == "true"
    r.setChecked(box, false)
    check r.getAttribute(box, "checked") == "false"

  test "isNilNode is false for a node":
    let r = MockRenderer()
    check not r.isNilNode(r.createElement("div"))
