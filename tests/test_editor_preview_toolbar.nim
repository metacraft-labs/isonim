## MockRenderer substitutes only the renderer so native and executed-JS tests
## inspect generic production toolbar bindings without browser globals. EditorVM,
## signals, ownership and actual click callbacks remain real. CSS container sizing,
## visible bounds, keyboard and hit targets are tested by the mounted chat GUI.
import std/[unittest, tables]
import isonim/core/[computation, owner, signals]
import isonim/editor/[viewmodels, types]
import isonim/editor/views/shell
import isonim/testing/mock_dom

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    result = findByAttr(child, name, value)
    if result != nil: return

suite "Responsive preview toolbar":
  test "responsive toolbar preserves all viewport choices and reactive label":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      check bar.styles["height"] == "44px"
      let label = findByAttr(bar, "data-preview-viewport-current", "true")
      check label != nil
      for vp in pinnedViewports(pbWeb) & popupViewports(pbWeb):
        let option = findByAttr(bar, "data-preview-viewport-dropdown-option", vp.slug)
        check option != nil
        check option.attributes["data-preview-viewport-dropdown-option-label"] == vp.label
        option.fireEvent("click")
        check vm.viewport.val.slug == vp.slug
        check label.textContent == vp.label
      vm.changePlatform(pbTui)
      for vp in pinnedViewports(pbTui) & popupViewports(pbTui):
        let option = findByAttr(bar, "data-preview-viewport-dropdown-option", vp.slug)
        check option != nil
        option.fireEvent("click")
        check vm.viewport.val.slug == vp.slug
        check label.textContent == vp.label
      vm.changePlatform(pbWeb)
      check findByAttr(bar, "data-preview-viewport-dropdown-option", "desktop") != nil
      dispose()
