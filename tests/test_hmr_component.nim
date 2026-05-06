## tests/test_hmr_component.nim
##
## Headless tests for the {.uiComponent.} pragma's registration and
## dispatch behaviour. Browser-side guarantees (DOM identity, focus,
## input value preservation) live in the Playwright spec.

when not defined(js):
  {.error: "test_hmr_component requires the JS backend".}

import std/[unittest, jsffi, tables]
import isonim/web/dom_api

when defined(isonimHmr):
  import isonim/web/hmr_component
  import isonim/web/hmr_ui_registry

  # We can't use real ui macros in a unit test (they need a renderer
  # and DOM). Instead, simulate what the {.uiComponent.} pragma emits:
  # a concrete proc, plus a registration. Then exercise the dispatcher.

  proc fakeNode(tag: cstring): Node =
    var n: Node
    {.emit: ["""
      """, n, """ = { nodeType: 1, tagName: """, tag, """, childNodes: [], appendChild: function(c){ this.childNodes.push(c); } };
    """].}
    n

  var componentACalls = 0
  var componentBCalls = 0

  proc realCompA(): Node =
    inc componentACalls
    fakeNode(cstring"A")

  proc realCompB(): Node =
    inc componentBCalls
    fakeNode(cstring"B")

  proc registerForTest(loc, hash: string; f: proc(): Node) =
    var fObj: JsObject
    {.emit: [fObj, " = ", f, ";"].}
    hmrRegisterFactory(loc, hash, fObj)

  suite "HMR component registry":
    test "register, invoke, memoise":
      ensureUiRegistry()
      registerForTest("test:compA", "h1", realCompA)
      let n1 = hmrInvokeComponent("test:compA")
      let n2 = hmrInvokeComponent("test:compA")
      check componentACalls == 1   # memoised — second invoke reads cached
      var same: bool
      {.emit: [same, " = (", n1, " === ", n2, ");"].}
      check same

    test "different location → independent slots":
      ensureUiRegistry()
      registerForTest("test:compA", "h1", realCompA)
      registerForTest("test:compB", "h2", realCompB)
      discard hmrInvokeComponent("test:compA")
      discard hmrInvokeComponent("test:compB")
      check componentBCalls == 1   # independent of A

    test "re-register same hash is a no-op":
      ensureUiRegistry()
      registerForTest("test:compA", "h1", realCompA)
      let n1 = hmrInvokeComponent("test:compA")
      let initialCalls = componentACalls
      # Simulate reload: register the same loc/hash again.
      registerForTest("test:compA", "h1", realCompA)
      let n2 = hmrInvokeComponent("test:compA")
      check componentACalls == initialCalls  # factory wasn't run again
      var same: bool
      {.emit: [same, " = (", n1, " === ", n2, ");"].}
      check same

    test "re-register changed hash invalidates the memo":
      ensureUiRegistry()
      registerForTest("test:compA", "h1", realCompA)
      let n1 = hmrInvokeComponent("test:compA")
      let beforeReload = componentACalls
      # Simulate reload with a *different* hash but the same factory
      # (in real life it'd be a new factory; here we reuse to keep the
      # test simple — the hash difference is what matters).
      registerForTest("test:compA", "h2", realCompA)
      let n2 = hmrInvokeComponent("test:compA")
      check componentACalls > beforeReload  # factory re-ran
      var differ: bool
      {.emit: [differ, " = (", n1, " !== ", n2, ");"].}
      check differ

    test "registry size accounting":
      ensureUiRegistry()
      registerForTest("test:slot1", "h", realCompA)
      registerForTest("test:slot2", "h", realCompB)
      check registrySize() >= 2

    test "generation counter advances on re-registration":
      ensureUiRegistry()
      let g0 = currentGeneration()
      registerForTest("test:gen", "h1", realCompA)
      let g1 = currentGeneration()
      registerForTest("test:gen", "h2", realCompA)
      let g2 = currentGeneration()
      check g1 > g0
      check g2 > g1

else:
  suite "HMR component pragma is a no-op without -d:isonimHmr":
    test "the module compiles without flag":
      check true
