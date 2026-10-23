## test_dsl_helper_calls.nim
##
## A call inside a `ui` block that is not an element is a helper: its value
## is the child node, appended where the call appears. Two spellings used
## to vanish from the generated code without a diagnostic:
##
## - a generic instantiation, `renderRow[R, N](r, item)` — its head is a
##   bracket expression, not a name;
## - ANY helper call inside a generic proc — the generic pre-pass binds the
##   helper's name to a symbol before the macro reads it, and only
##   identifier heads were recognised.
##
## Both now render, and a helper returning nothing is a compile error
## instead of a dropped statement. Driven through `MockRenderer`.

import std/[tables, unittest]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

proc genericChild[R, N](r: R; label: string): N =
  ui(r):
    span(class = "generic-child"):
      text label

proc plainChild(r: MockRenderer; label: string): MockNode =
  ui(r):
    span(class = "plain-child"):
      text label

proc nothing(r: MockRenderer) = discard

proc genericParent[R, N](r: R): N =
  ui(r):
    tdiv(class = "parent"):
      genericChild[R, N](r, "generic")
      plainChild(r, "plain")

proc plainParent(r: MockRenderer): MockNode =
  ui(r):
    tdiv(class = "parent"):
      genericChild[MockRenderer, MockNode](r, "generic")
      plainChild(r, "plain")

proc childClasses(node: MockNode): seq[string] =
  for c in node.children:
    result.add c.attributes.getOrDefault("class")

suite "ui helper calls":

  test "a generic proc renders generic and plain helper children":
    let r = MockRenderer()
    check childClasses(genericParent[MockRenderer, MockNode](r)) ==
      @["generic-child", "plain-child"]

  test "a plain proc renders an explicitly instantiated generic child":
    let r = MockRenderer()
    check childClasses(plainParent(r)) == @["generic-child", "plain-child"]

  test "a helper returning nothing does not compile as a child":
    let r = MockRenderer()
    template voidChild(): untyped =
      ui(r):
        tdiv:
          nothing(r)
    template nodeChild(): untyped =
      ui(r):
        tdiv:
          plainChild(r, "x")
    check not compiles(voidChild())
    check compiles(nodeChild())
