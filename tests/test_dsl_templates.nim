## Static subtree templates in the `ui` macro (`isonim/dsl/templates.nim`).
##
## A renderer that implements `createFromTemplate` is handed each fixed-shape subtree as one
## template; every other renderer receives one call per node. This suite builds the same fixtures
## both ways and checks that the trees, the reactive updates and the event handlers are the same,
## and that the templated build made one call per subtree.
##
## MOCK POLICY (workspace rule: every mock justified in the header). MockRenderer is IsoNim's
## shipped in-memory RendererBackend, the same boundary production renderers implement; these tests
## pin what the macro emits, which is a property of the macro and not of any one renderer. The
## templated build goes through `buildFromTemplate`, the contract-only implementation of the
## template call, so the two trees are made by the same 13 operations in a different order.

import std/[algorithm, sequtils, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/dsl/[ui, templates]
import dsl/template_plain

var templateCalls = 0
var lastTemplate: StaticTemplate

proc createFromTemplate(r: MockRenderer; tpl: StaticTemplate): seq[MockNode] =
  inc templateCalls
  lastTemplate = tpl
  buildFromTemplate[MockRenderer, MockNode](r, tpl)

include dsl/template_fixtures

proc dump(n: MockNode): string =
  if n.kind == mnkText:
    return "'" & n.text & "'"
  result = n.tag
  var attrs = toSeq(n.attributes.pairs).mapIt(it[0] & "=" & it[1])
  attrs.sort()
  var styles = toSeq(n.styles.pairs).mapIt(it[0] & ":" & it[1])
  styles.sort()
  result.add "[" & attrs.join(",") & "|" & styles.join(",") & "]"
  result.add "(" & n.children.mapIt(dump(it)).join(",") & ")"

suite "static subtree templates":
  test "a fixed subtree is one template call and the same tree":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      templateCalls = 0
      let templated = staticCard(r)
      check templateCalls == 1
      check lastTemplate.holes == 0
      check lastTemplate.nodes.len == 10
      check dump(templated) == dump(template_plain.staticCard(r))
      dispose()

  test "dynamic text, attributes and styles are holes, updated as before":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let index = createSignal(7)
      let label = createSignal("step")
      let tone = createSignal("red")
      let index2 = createSignal(7)
      let label2 = createSignal("step")
      let tone2 = createSignal("red")
      templateCalls = 0
      let templated = dynamicRow(r, index, label, tone)
      let plain = template_plain.dynamicRow(r, index2, label2, tone2)
      check templateCalls == 1
      check lastTemplate.holes == 3
      check dump(templated) == dump(plain)
      index.val = 8; index2.val = 8
      label.val = "next"; label2.val = "next"
      tone.val = "blue"; tone2.val = "blue"
      check dump(templated) == dump(plain)
      check templated.textContent == "8next"
      check templated.styles["background-color"] == "blue"
      dispose()

  test "handlers and refs reach the templated nodes":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let clicks = createSignal(0)
      var held: MockNode
      templateCalls = 0
      let templated = withHandlers(r, clicks, held)
      check templateCalls == 1
      check not held.isNil
      check held.tag == "button"
      held.fireEvent("click")
      held.fireEvent("click")
      check clicks.val == 2
      check templated.textContent == "+clicks: 2"
      let clicks2 = createSignal(0)
      var held2: MockNode
      let plain = template_plain.withHandlers(r, clicks2, held2)
      held2.fireEvent("click")
      held2.fireEvent("click")
      check dump(templated) == dump(plain)
      dispose()

  test "control flow keeps its parent per-node and templates what it nests":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      templateCalls = 0
      let items = @["a", "b", "c"]
      let templated = mixed(r, items)
      # The `ul` holds a loop, so it is built node by node; each `li` is a template.
      check templateCalls == 3
      check dump(templated) == dump(template_plain.mixed(r, items))
