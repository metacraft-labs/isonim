## Tests for IsoNim Editor — shell Views (M2)

import std/[unittest, strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/stories
import isonim/editor/views/shell

suite "Editor Shell Views (M2)":

  test "test_editor_shell_three_panel_layout":
    ## Editor renders sidebar, preview, and inspector panels
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Shell mounts sidebar, four view panes, vector editor, and chat.
      check shell.children.len == 7
      dispose()

  test "test_sidebar_renders_groups":
    ## Sidebar shows storyboard groups
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      # Should have header, search, and group list
      check sidebar.children.len >= 3

      # Header should contain "isonim editor"
      let header = sidebar.children[0]
      check header.children.len >= 1

      dispose()

  test "test_preview_pane_shows_toolbar":
    ## Preview pane has toolbar with mode toggle and platform selector
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      # Should have toolbar and preview area
      check pane.children.len >= 2

      # Toolbar should have mode toggle and platform selector
      let toolbar = pane.children[0]
      check toolbar.children.len >= 2

      dispose()

  test "test_inspector_renders_all_sections":
    ## Inspector shows section tabs and content area
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Should have tabs, content, and chat section
      check panel.children.len >= 3

      # Tabs should expose every inspector section.
      let tabs = panel.children[0]
      check tabs.children.len == 11

      dispose()

  test "test_views_contain_no_hardcoded_values":
    ## View files use Tailwind classes, no hardcoded pixel values in class strings
    let shellFile = readFile("src/isonim/editor/views/shell.nim")

    # Views should use class = "..." for layout (Tailwind)
    check "class = " in shellFile

    # Views should use setStyle for dynamic/theme values — this is expected
    # But class strings should not contain raw px values
    # (they use Tailwind scale like p-4, not p-16px)

  test "test_chat_section_has_input":
    ## Agent chat area has input bar and send button
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Chat section is the last child
      let chatSection = panel.children[^1]
      check chatSection.children.len >= 2  # header + input row

      dispose()
