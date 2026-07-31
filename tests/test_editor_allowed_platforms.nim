## M1 — Per-project target platforms (backend/platform toolbar allow-list).
##
## Regression tests for `EditorWorkspace.allowedPlatforms`: a project may
## restrict which preview backends appear in the left-edge backend strip.
## An empty allow-list means ALL platforms (today's default behaviour), so
## every existing pilot is byte-unchanged. These tests drive the real
## editor VM through `applyWorkspace` and render the actual backend strip
## with the headless mock renderer — no behaviour mocks.

import std/[options, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/workspace
import isonim/editor/streaming_preview
import isonim/editor/views/shell

proc collectByAttrName(node: MockNode; name: string;
    result: var seq[MockNode]) =
  if node.kind == mnkElement and name in node.attributes:
    result.add node
  for child in node.children:
    collectByAttrName(child, name, result)

proc backendChipIds(node: MockNode): seq[string] =
  var nodes: seq[MockNode] = @[]
  collectByAttrName(node, "data-preview-backend", nodes)
  for n in nodes:
    result.add n.attributes["data-preview-backend"]

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc chromeBackendLabels(bar: MockNode): seq[string] =
  ## The short labels of the pills in the chrome-bar backend cluster
  ## (`renderPreviewChromeBar`), in DOM order. Each ChoiceGroup pill carries
  ## `data-choice-group-pill` (its index) and `data-choice-group-label` (the
  ## short label: "Web" / "TUI" / ...). Scoped to the `data-toolbar-cluster=
  ## "backend"` wrapper so the viewport/mode clusters are ignored.
  let cluster = findByAttr(bar, "data-toolbar-cluster", "backend")
  if cluster == nil:
    return
  var pills: seq[MockNode] = @[]
  collectByAttrName(cluster, "data-choice-group-pill", pills)
  for p in pills:
    result.add p.attributes["data-choice-group-label"]

suite "M1 per-project target platforms":

  test "empty allow-list yields all seven backends (unchanged default)":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "All platforms",
        storyGroups = @[])
      check workspace.allowedPlatforms.card == 0
      let vm = createEditorVM(workspace)
      check vm.allowedPlatforms.card == 0

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check strip != nil
      check backendChipIds(strip) ==
        @["web", "tui", "gpui", "freya", "cocoa", "android", "ios"]
      dispose()

  test "non-empty allow-list surfaces exactly the listed backends in order":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "Web + TUI only",
        storyGroups = @[],
        allowedPlatforms = {pbWeb, pbTui})
      let vm = createEditorVM(workspace)
      check vm.allowedPlatforms == {pbWeb, pbTui}

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check strip != nil
      # Canonical order preserved; excluded backends are absent.
      check backendChipIds(strip) == @["web", "tui"]
      check findByAttr(strip, "data-preview-backend", "gpui") == nil
      check findByAttr(strip, "data-preview-backend", "android") == nil
      dispose()

  test "single-platform docs allow-list shows only web":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "Docs (web only)",
        storyGroups = @[],
        allowedPlatforms = {pbWeb})
      let vm = createEditorVM(workspace)

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check strip != nil
      check backendChipIds(strip) == @["web"]
      dispose()

  test "active platform excluded by allow-list falls back to first allowed":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      # Declared platform (pbCocoa) is not permitted; the VM must snap to
      # the first allowed backend in canonical order (pbTui here).
      let workspace = newEditorWorkspace(
        title = "TUI + GPUI, cocoa requested",
        storyGroups = @[],
        platform = pbCocoa,
        allowedPlatforms = {pbTui, pbGpui})
      let vm = createEditorVM(workspace)
      check vm.platform.val == pbTui

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let strip = findByAttr(pane, "data-edge-strip", "backend")
      check backendChipIds(strip) == @["tui", "gpui"]
      dispose()

suite "M1 per-project target platforms (chrome-bar backend cluster)":
  ## The chrome-bar backend cluster (`renderPreviewChromeBar`) is the backend
  ## control the user actually operates once a preview item is selected. It
  ## must honour `allowedPlatforms` exactly like the left-edge strip above:
  ## empty = all seven backends; non-empty = only the listed platforms.

  test "empty allow-list yields all seven chrome-bar backend pills (default)":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "All platforms",
        storyGroups = @[])
      let vm = createEditorVM(workspace)
      check vm.allowedPlatforms.card == 0

      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      check chromeBackendLabels(bar) ==
        @["Web", "TUI", "GPUI", "Freya", "Cocoa", "Android", "iOS"]
      dispose()

  test "non-empty allow-list restricts the chrome-bar backend pills in order":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "Web + TUI only",
        storyGroups = @[],
        allowedPlatforms = {pbWeb, pbTui})
      let vm = createEditorVM(workspace)

      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      # Canonical order preserved; excluded backends are absent from the
      # chrome bar exactly as they are from the left-edge strip.
      check chromeBackendLabels(bar) == @["Web", "TUI"]
      dispose()

  test "single-platform docs allow-list shows only the web pill in the chrome bar":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let workspace = newEditorWorkspace(
        title = "Docs (web only)",
        storyGroups = @[],
        allowedPlatforms = {pbWeb})
      let vm = createEditorVM(workspace)

      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      check chromeBackendLabels(bar) == @["Web"]
      dispose()
