## The backend element hook of renderer-mode `ui(r)`.
##
## A backend that declares `noteElement` typed on its own element handle is
## called once per element with that element and the element's source
## location ("file:line:column" in the template). Backends without such an
## overload are unaffected (every other DSL suite covers that).
##
## Run in both configurations (the Justfile's `test-dsl` does):
##
## - default: the backend overload sees every element with its line info;
## - `-d:isonimEditor`: the editor's scene-graph recording and the backend
##   overload BOTH run for every element. The scene graph must not lose
##   elements because a backend declared an overload, and the backend must
##   not lose its hook because the editor is on.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## `HookRenderer` forwards every backend call to MockRenderer, the
## framework's shipped in-memory `RendererBackend` (`isonim/testing/mock_dom`),
## because what is under test is the DSL's call into a backend hook, and the
## built tree only needs to be real enough to compare element identities.
## A production backend would test its own use of the location, not the
## seam that delivers it.
import std/[strutils, unittest]
import isonim/core/owner
import isonim/testing/mock_dom
import isonim/dsl/ui
when defined(isonimEditor):
  import isonim/dsl/scene_graph

type
  HookRenderer = object

  Noted = object
    el: MockNode
    tag, loc, parentId, id: string

var noted: seq[Noted] = @[]

proc createElement(r: HookRenderer; tag: string): MockNode =
  MockRenderer().createElement(tag)

proc createTextNode(r: HookRenderer; text: string): MockNode =
  MockRenderer().createTextNode(text)

proc appendChild(r: HookRenderer; parent, child: MockNode) =
  MockRenderer().appendChild(parent, child)

proc setAttribute(r: HookRenderer; node: MockNode; name, value: string) =
  MockRenderer().setAttribute(node, name, value)

proc setStyle(r: HookRenderer; node: MockNode; prop, value: string) =
  MockRenderer().setStyle(node, prop, value)

proc setTextContent(r: HookRenderer; node: MockNode; text: string) =
  MockRenderer().setTextContent(node, text)

proc noteElement(el: MockNode; id, tag, loc, parentId: string) =
  ## The backend overload under test: typed on the element handle.
  noted.add Noted(el: el, tag: tag, loc: loc, parentId: parentId, id: id)

proc locLine(loc: string): int =
  ## "file:line:column" -> line.
  let parts = loc.rsplit(':', maxsplit = 2)
  parseInt(parts[1])

template lineHere(): int =
  ## The line this template is called on.
  instantiationInfo(fullPaths = true).line

proc locFile(loc: string): string =
  loc.rsplit(':', maxsplit = 2)[0]

suite "backend element hook":
  test "a typed noteElement overload sees each element and its location":
    noted.setLen(0)
    when defined(isonimEditor):
      resetSceneGraph()
    createRoot do (dispose: proc()):
      let r = HookRenderer()
      const base = lineHere()
      let root = ui(r):
        tdiv(class = "outer"):
          span: text "a"
          tdiv(class = "inner"):
            p: text "b"

      # One call per element, in creation order, each with the element the
      # DSL built (identity, not just tag) and the element's own line.
      check noted.len == 4
      if noted.len == 4:
        check noted[0].el == root
        check noted[1].el == root.children[0]
        check noted[2].el == root.children[1]
        check noted[3].el == root.children[1].children[0]
        check noted[0].tag == "div"
        check noted[1].tag == "span"
        check noted[2].tag == "div"
        check noted[3].tag == "p"
        check locLine(noted[0].loc) == base + 2
        check locLine(noted[1].loc) == base + 3
        check locLine(noted[2].loc) == base + 4
        check locLine(noted[3].loc) == base + 5
        for n in noted:
          check locFile(n.loc).endsWith("test_dsl_element_hook.nim")
        # Parent linkage travels with the hook as well.
        check noted[0].parentId == ""
        check noted[1].parentId == noted[0].id
        check noted[3].parentId == noted[2].id

      when defined(isonimEditor):
        # The editor's recording is unaffected by the backend overload: the
        # same four elements, same ids, same locations.
        let g = sceneGraph()
        check g.nodes.len == 4
        if g.nodes.len == 4 and noted.len == 4:
          for i in 0 ..< 4:
            check g.nodes[i].id == noted[i].id
            check g.nodes[i].tag == noted[i].tag
            check g.nodes[i].line == locLine(noted[i].loc)
            check g.nodes[i].parentId == noted[i].parentId
