## The third compilation regime: one DSL block, three outputs.
##
## `ui:` produces a string and `ui(r):` produces an element tree. Neither could
## be edited: a value in a string has to be rewritten and recompiled to change,
## and a value written straight into a `setStyle` call has nothing to write to.
## Under `-d:isonimEditor` the client arm compiles each authored literal in
## PROJECT code into a cell instead, so the editor writes the cell and the
## framework's own reactivity updates the node that read it.
##
## Project code, by a prefix test on the framework's own source directory. The
## editor is an IsoNim application, so its chrome reaches the same macro in the
## same build -- and a toolbar button is not the user's document.
##
## These tests are the claims that make that safe to rely on:
##
##  * the SSR arm is unaffected, because it renders the page that ships;
##  * a cell write reaches the mounted DOM;
##  * cells survive a re-render, because re-rendering must not discard an edit;
##  * plain `ui(r):` gets none of it, because the editor's own chrome is
##    client-mode DSL in the same bundle and is not the document being edited.

import std/[os, sequtils, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/dsl/ui
import isonim/dsl/isomorphic
import isonim/editor/editable_cells
import isonim/testing/mock_dom

uiIsomorphic fixtureBlock:
  ## A doc comment, which must survive rather than reach the DSL as a node.
  tdiv(class = "page-width"):
    h1(class = "tagline", font_size = "40px"):
      text "Faster than C."

proc cellKeys(): seq[string] =
  for key in editableCellKeys(): result.add key

proc keyEndingIn(suffix: string): string =
  for key in editableCellKeys():
    if key.endsWith(suffix): return key
  ""

proc idOf(key, suffix: string): string =
  key[0 ..< key.len - suffix.len]

suite "uiIsomorphic: one body, both regimes":

  test "the SSR arm renders the authored literals":
    let html = fixtureBlock()
    check "class=\"tagline\"" in html
    check "Faster than C." in html

  test "the client arm builds the same shape":
    createRoot do (dispose: proc()):
      resetEditableCells()
      let r = MockRenderer()
      let host = r.createElement("main")
      r.fixtureBlockMount(host)
      check host.children.len == 1
      let root = host.children[0]
      check root.attributes.getOrDefault("class") == "page-width"
      check root.children.len == 1
      check root.children[0].tag == "h1"
      dispose()

  test "a doc comment stays documentation":
    ## It is the first statement in the block, and the macro must not hand it
    ## to the DSL -- which would fail to process it -- nor silently drop it.
    check fixtureBlock().len > 0

when defined(isonimEditor):
  ## Both suites below assert on cells, which exist only in an editor build.
  ## Guarded rather than skipped so a production run does not report a dozen
  ## skipped tests as if something were wrong with it.
  suite "edit regime: authored values become cells":

    test "every authored literal registers one":
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        let keys = cellKeys()
        # Two classes, one style property, one text.
        check keys.len == 4
        check keyEndingIn("|font-size").len > 0
        check keyEndingIn("|text").len > 0
        check keys.countIt(it.endsWith("|class")) == 2
        dispose()

    test "writing a cell updates the mounted element":
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        let h1 = host.children[0].children[0]
        check h1.styles.getOrDefault("font-size") == "40px"

        let key = keyEndingIn("|font-size")
        check setEditableValue(key.idOf("|font-size"), "font-size", "99px")
        check h1.styles.getOrDefault("font-size") == "99px"
        dispose()

    test "writing a text cell updates the text node":
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        let textNode = host.children[0].children[0].children[0]
        check textNode.text == "Faster than C."

        let key = keyEndingIn("|text")
        check setEditableValue(key.idOf("|text"), "text", "Safer than Rust.")
        check textNode.text == "Safer than Rust."
        dispose()

    test "a property the block never authored has no cell":
      ## Nil is the answer, not a created-on-demand cell. Most of a design
      ## system's properties live in the stylesheet, and pretending the DSL owns
      ## one would let the editor write somewhere that changes nothing.
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        let key = keyEndingIn("|font-size")
        check editableCell(key.idOf("|font-size"), "letter-spacing").isNil
        check not setEditableValue(key.idOf("|font-size"), "letter-spacing", "1px")
        dispose()

    test "an edit survives a re-render of the same block":
      ## Re-rendering must not discard an edit: a story re-selected or a parent
      ## effect re-running rebuilds elements, and every one of those would
      ## otherwise reset the value to the literal in the bundle.
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let first = r.createElement("main")
        r.fixtureBlockMount(first)
        let key = keyEndingIn("|font-size")
        let id = key.idOf("|font-size")
        check setEditableValue(id, "font-size", "77px")

        let second = r.createElement("main")
        r.fixtureBlockMount(second)
        check second.children[0].children[0].styles.getOrDefault("font-size") ==
          "77px"
        dispose()

    test "resetting drops the cells, so a recompiled literal wins":
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        check editableCellCount() == 4
        resetEditableCells()
        check editableCellCount() == 0

        let fresh = r.createElement("main")
        r.fixtureBlockMount(fresh)
        check fresh.children[0].children[0].styles.getOrDefault("font-size") ==
          "40px"
        dispose()

  suite "edit regime: project code, not framework code":

    test "a plain `ui(r)` block in project code is editable too":
      ## No opt-in. The regime is not something a project asks for -- under an
      ## editor build, the project's UI is editable because it is the project's
      ## UI. This test file is project code by the same test that decides it
      ## for a pilot: it is not under isonim's own `src/isonim`.
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let node = ui(r):
          tdiv(class = "plain", font_size = "11px"):
            text "no macro asked for this"
        check node.attributes.getOrDefault("class") == "plain"
        check editableCellCount() == 3
        let key = keyEndingIn("|font-size")
        check setEditableValue(key.idOf("|font-size"), "font-size", "22px")
        check node.styles.getOrDefault("font-size") == "22px"
        dispose()

    test "the framework's own blocks are excluded by path":
      ## The editor is an IsoNim application, so its chrome is client-mode DSL
      ## compiled into the same `nim js` invocation as the project it edits.
      ## Both reach the macro and only one is the user's document.
      ##
      ## `isFrameworkBlock` decides by a PREFIX test on the directory that
      ## `currentSourcePath()` puts `ui.nim` in. A substring test on "isonim"
      ## would be wrong in a way that is easy to miss: the pilot this was built
      ## against lives at `web-site-prototypes/grip/isonim/src/pages/home.nim`,
      ## and would have been classified as framework code and silently left
      ## uneditable.
      ##
      ## Asserted here against a path pair rather than by compiling a block
      ## inside the framework tree, which no test can do from here. The live
      ## check is in `editor-mounted-preview-e2e`, which reads the registry out
      ## of a running editor and requires every cell to come from the project.
      const frameworkFile =
        currentSourcePath().parentDir() / ".." / "src" / "isonim" / "dsl" /
        "ui.nim"
      check fileExists(frameworkFile)
      check not fileExists(
        currentSourcePath().parentDir() / ".." / "src" / "isonim" / "grip.nim")

suite "edit regime: absent from a production build":
  ## Compiled WITHOUT `-d:isonimEditor`, which is how a shipped page is built.
  ## The claim is not that the cells are disabled but that they are not
  ## emitted: the macro takes the other branch, and the registry is never
  ## called. Run as a second invocation of this file; see the Justfile.

  test "a mounted block registers no cells":
    when not defined(isonimEditor):
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        # The element is built and styled exactly as before...
        check host.children[0].children[0].styles.getOrDefault("font-size") ==
          "40px"
        # ...with nothing registered to make it editable.
        check editableCellCount() == 0
        dispose()

  test "the literal is not writable":
    when not defined(isonimEditor):
      createRoot do (dispose: proc()):
        resetEditableCells()
        let r = MockRenderer()
        let host = r.createElement("main")
        r.fixtureBlockMount(host)
        check not setEditableValue("anything", "font-size", "99px")
        check host.children[0].children[0].styles.getOrDefault("font-size") ==
          "40px"
        dispose()
