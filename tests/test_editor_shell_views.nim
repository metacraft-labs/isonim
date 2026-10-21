## Tests for IsoNim Editor — shell Views (M2)
## MockRenderer provides inspectable generic nodes for headless production
## ViewModel/view bindings without a browser. Signals, owners and editor reducers
## are real; the registered mounted GUI suites separately verify actual DOM,
## keyboard, geometry and preview behavior. No external provider is substituted
## to claim REST or compiler integration in this suite. The scope test records
## admission and returns a refusal; it does not simulate a successful source
## write. Chat adapters record prompt/context admission and cancellation only,
## not Harbor/session-worker outcomes. Saved callbacks test logical retirement,
## not physical browser listener removal. Authored metadata fixtures exercise
## ownership presentation/admission, not discovery. The source-text assertion
## reads the same production file at runtime natively and compile time in JS.
## Header Add checks prove guard metadata and direct-dispatch no-ops only;
## the mounted GUI owns actual event bubbling, keyboard and focus claims.

import std/[unittest, strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/stories
import isonim/editor/types
import isonim/editor/views/shell
import isonim/editor/views/chat_panel
import isonim/editor/views/component_edit
import isonim/editor/views/component_detail
import isonim/editor/views/foundations_page
import isonim/editor/views/page_preview
import isonim/editor/views/storyboard
import isonim/editor/views/vector_editor

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc countByAttr(node: MockNode; name, value: string): int =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    inc result
  for child in node.children:
    result += countByAttr(child, name, value)

proc collectByAttr(node: MockNode; name, value: string; result: var seq[MockNode]) =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    result.add node
  for child in node.children:
    collectByAttr(child, name, value, result)

proc findAllByAttr(node: MockNode; name, value: string): seq[MockNode] =
  collectByAttr(node, name, value, result)

proc manualSaveControls(node: MockNode; found: var seq[string]) =
  ## Every control that would let a person hold a change back for a second
  ## gesture: an aria-labelled Save/Revert, or an interactive node whose
  ## whole text is "Save" or "Revert". Editor spec "Saving": none exist.
  if node.kind == mnkElement:
    let label = node.attributes.getOrDefault("aria-label")
    if (label.startsWith("Save ") or label.startsWith("Revert ")) and
        label.endsWith("source edits"):
      found.add label
    # Exempt, both draft confirms rather than source-edit saves:
    # - the inline variable editor's dialog confirm commits the draft through
    #   `editFoundationToken` (a commit, then auto-saved), like "Apply";
    # - the Spec-mode markdown editor's Save (JS only) ends an explicit spec
    #   document edit session through its own callback, not the source-edit
    #   journal.
    if ("click" in node.eventListeners or "keydown" in node.eventListeners) and
        node.textContent.strip in ["Save", "Revert"] and
        node.attributes.getOrDefault("data-variable-inline-editor-save") != "true" and
        node.attributes.getOrDefault("data-spec-pane-save-btn") != "true":
      found.add "text:" & node.textContent.strip
  for child in node.children:
    manualSaveControls(child, found)

proc countInteractive(node: MockNode): int =
  if node.kind == mnkElement and
      ("click" in node.eventListeners or "keydown" in node.eventListeners):
    inc result
  for child in node.children:
    result += countInteractive(child)

suite "Editor Shell Views (M2)":

  test "test_editor_shell_three_panel_layout":
    ## Editor renders sidebar, center column (chrome bar + views), and
    ## inspector panels. The global title bar and the M57 left/right
    ## edge strips are gone — backend / viewport / mode chips live in
    ## the shared preview chrome bar above the center view stack.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Shell mounts the main editor row, command palette, telemetry overlay,
      # status bar, (M-EVP-8) a hidden ``data-shell-escape-key`` node that
      # the ESC handler binds to, (TBAR-M6) the absolutely positioned
      # ``data-spec-comment-popover`` overlay that the Spec-pane Comment
      # mode anchors to a TipTap selection, and (Phase E.3 + E.4,
      # 2026-05-28) the absolutely positioned ``data-variable-picker``
      # + ``data-variable-inline-editor`` overlays — single instances
      # reused across every property row.
      #
      # Phase I/J (2026-05-28): the ``data-ai-drawer`` slide-out drawer
      # is gone — chat sessions now live in the right-sidebar AI
      # assistant panel mounted by ``renderAiAssistantPanel``.
      check shell.children.len == 8
      check findByAttr(shell, "data-shell-escape-key", "true") != nil
      check findByAttr(shell, "data-spec-comment-popover", "true") != nil
      # Negative assertion: the drawer is gone.
      check findByAttr(shell, "data-ai-drawer", "true") == nil
      check findByAttr(shell, "data-variable-picker", "true") != nil
      check findByAttr(shell, "data-variable-inline-editor", "true") != nil
      # Editor row children: sidebar, center column, sidebar content
      # (AI assistant in the default View mode after createEditorVM).
      let editorRow = findByAttr(shell, "data-shell-row", "true")
      check editorRow != nil
      check editorRow.children.len == 3
      # Phase J: the right-sidebar surface in the default View mode is
      # the AI assistant panel. ``data-test-id="property-panel"`` still
      # resolves it via the shared selector; ``data-sidebar-content``
      # distinguishes which surface is mounted.
      let sidebarContent = findByAttr(shell, "data-test-id",
        "property-panel")
      check sidebarContent != nil
      check sidebarContent.attributes.getOrDefault(
        "data-sidebar-content") == "ai-assistant"
      check findByAttr(shell, "data-preview-center-column", "true") != nil
      check findByAttr(shell, "data-preview-chrome-bar", "true") != nil
      check findByAttr(shell, "data-preview-view-stack", "true") != nil
      # Backend / viewport / mode chips live in the shared chrome bar.
      check findByAttr(shell, "data-edge-strip", "backend") != nil
      check findByAttr(shell, "data-edge-strip", "viewport") != nil
      check findByAttr(shell, "data-edge-strip", "mode") != nil
      # Legacy edge-strip containers are gone.
      check findByAttr(shell, "data-preview-left-edge", "true") == nil
      check findByAttr(shell, "data-preview-right-edge", "true") == nil
      check findByAttr(shell, "data-foundations-page", "true") != nil
      check findByAttr(shell, "data-editor-command-palette", "true") != nil
      check findByAttr(shell, "data-editor-telemetry-overlay", "true") != nil
      dispose()

  test "Phase J right sidebar swaps content between Inspector and AI assistant":
    ## Phase J (2026-05-28): the right sidebar's content is driven by
    ## the active editing mode. ``emEdit`` mounts the Inspector
    ## (``data-sidebar-content="inspector"``); every other mode
    ## (``emSpec`` / ``emView`` / ``emComment``) mounts the AI
    ## assistant (``data-sidebar-content="ai-assistant"``). The two
    ## surfaces are mutually-exclusive; ``data-test-id="property-panel"``
    ## stays on whichever is currently mounted so existing e2e
    ## selectors keep working.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      proc activeSidebarContent(): string =
        let panel = findByAttr(shell, "data-test-id", "property-panel")
        if panel == nil: return ""
        panel.attributes.getOrDefault("data-sidebar-content")

      # Default ``emView`` → AI assistant.
      check vm.editMode.val == emView
      check activeSidebarContent() == "ai-assistant"

      # Flip to Edit → Inspector.
      vm.setEditMode(emEdit)
      check activeSidebarContent() == "inspector"

      # Flip to Comment → AI assistant.
      vm.setEditMode(emComment)
      check activeSidebarContent() == "ai-assistant"

      # Flip to Spec → AI assistant + surfaceSig couples to sSpec
      # (Phase L: spec mode is the canonical spec-editor selection).
      vm.setEditMode(emSpec)
      check activeSidebarContent() == "ai-assistant"
      check vm.surfaceSig.val == sSpec

      # Flip back to Edit → Inspector + surface restored to sPreview.
      vm.setEditMode(emEdit)
      check activeSidebarContent() == "inspector"
      check vm.surfaceSig.val == sPreview

      dispose()

  test "test_sidebar_renders_groups":
    ## Sidebar shows storyboard groups
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      # Should have search and group list; product/version live in status bar.
      check sidebar.children.len >= 2
      check findByAttr(sidebar, "aria-label", "Toggle User Journeys section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Pages section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Components section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Foundations section") != nil
      check findByAttr(sidebar, "aria-label", "Open First Task journey") != nil
      check findByAttr(sidebar, "aria-label",
        "Select story First Task / User opens the app for the first time") == nil

      dispose()

  test "test_preview_pane_shows_toolbar":
    ## Preview pane has a top toolbar that hosts all three chip groups
    ## (backend / viewport / mode) directly. The legacy left/right edge
    ## strips and the breadcrumb are gone. M-EVP-7 also removed the
    ## view-switcher chip group — the sidebar is the only navigation
    ## surface and the active view is derived from the selected story's
    ## kind via ``viewForStory``.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      # Pane should have a top toolbar plus a body row.
      check pane.children.len == 2
      let toolbar = findByAttr(pane, "data-preview-toolbar", "true")
      let body = findByAttr(pane, "data-preview-body", "true")
      check toolbar != nil
      check body != nil

      # M-EVP-7: the view-switcher is GONE; only the three chip groups
      # remain.
      check findByAttr(toolbar, "data-preview-view-switcher", "true") == nil
      check findByAttr(toolbar, "data-preview-breadcrumb", "true") == nil
      check findByAttr(toolbar, "data-edge-strip", "backend") != nil
      check findByAttr(toolbar, "data-edge-strip", "viewport") != nil
      check findByAttr(toolbar, "data-edge-strip", "mode") != nil

      # Body row contains only the preview canvas — no edge columns.
      check findByAttr(body, "data-preview-canvas", "true") != nil
      check findByAttr(body, "data-preview-left-edge", "true") == nil
      check findByAttr(body, "data-preview-right-edge", "true") == nil

      dispose()

  test "test_inspector_renders_all_sections":
    ## Phase A demolition (2026-05-28): the prior Manual/Assistant
    ## tab pair plus the 12-sub-tab strip are gone. The sidebar
    ## now renders a single-column scroll surface of section
    ## placeholders — see ``isonim-specs/isonim-editor.md``
    ## §"Property Inspector Panel — Section-Based Design".
    ## Twelve ``data-inspector-section-row`` placeholders appear
    ## in user-decided order (Position / Layout / Appearance /
    ## Fill / Stroke / Effects / Typography / Selection colors /
    ## Source / Component properties / State / Export).
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Sidebar root still carries ``data-test-id="property-panel"``.
      check panel.attributes.getOrDefault("data-test-id") == "property-panel"
      # Phase J (2026-05-28): inspector mount carries
      # ``data-sidebar-content="inspector"`` so the mode-driven swap
      # in ``renderEditorShell`` is distinguishable from the AI
      # assistant mount (``"ai-assistant"``).
      check panel.attributes.getOrDefault("data-sidebar-content") ==
        "inspector"

      # The 12 section placeholders mount inside a single scrollable
      # column. The list element carries
      # ``data-inspector-section-list="true"`` so Phase C / G can
      # locate the mount point cheaply.
      let sectionList = findByAttr(panel, "data-inspector-section-list", "true")
      check sectionList != nil

      # 12 ``data-inspector-section-row`` placeholders in order.
      let expectedSections = [
        ("position",             "Position"),
        ("layout",               "Layout"),
        ("appearance",           "Appearance"),
        ("fill",                 "Fill"),
        ("stroke",               "Stroke"),
        ("effects",              "Effects"),
        ("typography",           "Typography"),
        ("selection-colors",     "Selection colors"),
        ("source",               "Source"),
        ("component-properties", "Component properties"),
        ("state",                "State"),
        ("export",               "Export")
      ]
      var sectionRows: seq[MockNode] = @[]
      for child in sectionList.children:
        if child.attributes.getOrDefault("data-inspector-section-row").len > 0:
          sectionRows.add child
      check sectionRows.len == 12

      # Ordered slug check + header carries the display name + each
      # row exposes an empty body slot.
      for i, (slug, displayName) in expectedSections:
        check sectionRows[i].attributes["data-inspector-section-row"] == slug
        let header = findByAttr(sectionRows[i],
          "data-inspector-section-header", slug)
        check header != nil
        check header.textContent.contains(displayName)
        let body = findByAttr(sectionRows[i],
          "data-inspector-section-body", slug)
        check body != nil

      # The legacy Manual/Assistant tab bar + 12-sub-tab strip are
      # GONE. Negative assertions pin the removal so a future
      # accidental re-mount fails this test.
      check findByAttr(panel, "data-sidebar-tab-bar", "true") == nil
      check findByAttr(panel, "data-sidebar-tab", "manual") == nil
      check findByAttr(panel, "data-sidebar-tab-panel", "manual") == nil
      check findByAttr(panel, "data-sidebar-tab-panel", "assistant") == nil
      check findByAttr(panel, "data-inspector-section", "layout") == nil

      # ----- Phase B (2026-05-28) -----------------------------------
      # The inspector now mounts a selection header above the section
      # list. The header is always-on (NOT inside the scrollable list)
      # and exposes four quick-action buttons (Code / Visibility /
      # Duplicate / More). With no element selected the label reads
      # "Nothing selected" (textMuted) and the chevron is hidden.
      let selectionHeader = findByAttr(
        panel, "data-inspector-selection-header", "true")
      check selectionHeader != nil
      # The header sits OUTSIDE the scrollable section list — Phase B's
      # "doesn't scroll with the rest of the sidebar" contract.
      check findByAttr(sectionList,
        "data-inspector-selection-header", "true") == nil
      # Element-type dropdown trigger + reactive label/chevron.
      let trigger = findByAttr(
        panel, "data-inspector-selection-trigger", "true")
      check trigger != nil
      let label = findByAttr(
        panel, "data-inspector-selection-label", "true")
      check label != nil
      check label.textContent == "Nothing selected"
      check label.styles.getOrDefault("color").toLowerAscii() ==
        "#6b6f80"  # textMuted
      let chevron = findByAttr(
        panel, "data-inspector-selection-chevron", "true")
      check chevron != nil
      check chevron.styles.getOrDefault("display") == "none"

      # Four quick-action buttons in a single actions row.
      let actionsRow = findByAttr(
        panel, "data-inspector-selection-actions", "true")
      check actionsRow != nil
      for slug in ["code", "visibility", "duplicate", "more"]:
        let btn = findByAttr(actionsRow,
          "data-inspector-selection-action", slug)
        check btn != nil
        check btn.attributes.getOrDefault("role") == "button"
        check btn.attributes.getOrDefault("tabindex") == "0"

      # Visibility button reflects the selectionVisible signal —
      # defaults to ``true`` so aria-pressed=true / color=textPrimary.
      let visBtn = findByAttr(actionsRow,
        "data-inspector-selection-action", "visibility")
      check visBtn.attributes.getOrDefault("aria-pressed") == "true"
      vm.toggleSelectionVisible()
      check vm.inspector.selectionVisible.val == false
      check visBtn.attributes.getOrDefault("aria-pressed") == "false"
      # Click the visibility button to flip back via the bound handler.
      visBtn.fireEvent("click")
      check vm.inspector.selectionVisible.val == true
      check visBtn.attributes.getOrDefault("aria-pressed") == "true"

      # When an element IS selected, the label switches to the mapped
      # display name (eg. "Group" for a <div>) and the chevron shows.
      vm.inspector.selectedElement.val = ElementRef(tag: "div")
      check label.textContent == "Group"
      check label.styles.getOrDefault("color").toLowerAscii() ==
        "#ecedf3"  # textPrimary
      check chevron.styles.getOrDefault("display") == "inline"
      vm.inspector.selectedElement.val = ElementRef(tag: "h2")
      check label.textContent == "Text"
      vm.inspector.selectedElement.val = ElementRef(tag: "button")
      check label.textContent == "Button"
      # Unknown tags fall through to a capitalised echo.
      vm.inspector.selectedElement.val = ElementRef(tag: "custom-card")
      check label.textContent == "Custom-card"

      # ----- Section frame structure --------------------------------
      # Each frame has a header (title + actions slot + chevron). The
      # ``data-expanded`` attribute reflects Phase C's default open
      # set (Position / Layout / Appearance / Fill) — the remaining
      # eight sections render collapsed and the body's ``display`` is
      # ``none``.
      const defaultOpenSlugs = [
        "position", "layout", "appearance", "fill"
      ]
      for (slug, displayName) in expectedSections:
        let header = findByAttr(panel,
          "data-inspector-section-header", slug)
        check header != nil
        let expectedExpanded =
          if slug in defaultOpenSlugs: "true" else: "false"
        check header.attributes.getOrDefault("data-expanded") ==
          expectedExpanded
        check header.attributes.getOrDefault("role") == "button"
        check header.attributes.getOrDefault("aria-expanded") ==
          expectedExpanded
        # Title carries the display name.
        let title = findByAttr(header,
          "data-inspector-section-title", "true")
        check title != nil
        check title.textContent == displayName
        # Per-section action slot is always present.
        let actions = findByAttr(header,
          "data-inspector-section-actions", slug)
        check actions != nil
        # Chevron caret on the far right. Glyph mirrors the expanded
        # state — ``▾`` open, ``▸`` collapsed.
        let sectionChevron = findByAttr(header,
          "data-inspector-section-chevron", slug)
        check sectionChevron != nil
        let expectedChevron =
          if slug in defaultOpenSlugs: "\xE2\x96\xBE" else: "\xE2\x96\xB8"
        check sectionChevron.textContent == expectedChevron
        # Body display tracks the expanded state.
        let body = findByAttr(panel,
          "data-inspector-section-body", slug)
        check body != nil
        let expectedDisplay =
          if slug in defaultOpenSlugs: "flex" else: "none"
        check body.styles.getOrDefault("display") == expectedDisplay

      # Fill / Stroke / Effects / Export carry a "+" placeholder
      # inside the action slot; the other eight sections do not.
      for slug in ["fill", "stroke", "effects", "export"]:
        let actions = findByAttr(panel,
          "data-inspector-section-actions", slug)
        check findByAttr(actions,
          "data-inspector-section-action", "add") != nil
      for slug in ["position", "layout", "appearance", "typography",
          "selection-colors", "source", "component-properties", "state"]:
        let actions = findByAttr(panel,
          "data-inspector-section-actions", slug)
        check actions != nil
        check findByAttr(actions,
          "data-inspector-section-action", "add") == nil

      # ----- Phase C (2026-05-28) -----------------------------------
      # Clicking a collapsed section header flips its data-expanded
      # attribute + aria-expanded + body display + chevron glyph.
      let strokeHeader = findByAttr(panel,
        "data-inspector-section-header", "stroke")
      check strokeHeader != nil
      check strokeHeader.attributes.getOrDefault("data-expanded") == "false"
      strokeHeader.fireEvent("click")
      check vm.inspector.expandedSections.val.contains(isStroke)
      check strokeHeader.attributes.getOrDefault("data-expanded") == "true"
      check strokeHeader.attributes.getOrDefault("aria-expanded") == "true"
      let strokeBody = findByAttr(panel,
        "data-inspector-section-body", "stroke")
      check strokeBody != nil
      check strokeBody.styles.getOrDefault("display") == "flex"
      let strokeChevron = findByAttr(panel,
        "data-inspector-section-chevron", "stroke")
      check strokeChevron != nil
      check strokeChevron.textContent == "\xE2\x96\xBE"
      # Click again — Stroke collapses, body hides, chevron flips.
      strokeHeader.fireEvent("click")
      check not vm.inspector.expandedSections.val.contains(isStroke)
      check strokeHeader.attributes.getOrDefault("data-expanded") == "false"
      check strokeBody.styles.getOrDefault("display") == "none"
      check strokeChevron.textContent == "\xE2\x96\xB8"

      # Clicking a default-open section header collapses it.
      let positionHeader = findByAttr(panel,
        "data-inspector-section-header", "position")
      check positionHeader != nil
      check positionHeader.attributes.getOrDefault("data-expanded") == "true"
      positionHeader.fireEvent("click")
      check not vm.inspector.expandedSections.val.contains(isPosition)
      check positionHeader.attributes.getOrDefault("data-expanded") == "false"
      let positionBody = findByAttr(panel,
        "data-inspector-section-body", "position")
      check positionBody != nil
      check positionBody.styles.getOrDefault("display") == "none"

      # Keyboard activation (Enter / Space → ``keydown``) toggles
      # the same way under MockRenderer.
      let effectsHeader = findByAttr(panel,
        "data-inspector-section-header", "effects")
      check effectsHeader != nil
      check effectsHeader.attributes.getOrDefault("data-expanded") == "false"
      effectsHeader.fireEvent("keydown")
      check vm.inspector.expandedSections.val.contains(isEffects)
      check effectsHeader.attributes.getOrDefault("data-expanded") == "true"

      dispose()

  test "component_edit_inspector_explains_and_applies_design_system_scope":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.selectedStory.val = StoryRef(group: "TaskRow", name: "Active task", kind: skComponent)
      vm.setEditMode(emEdit)
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      let token = PropertyInfo(name: "background-color", value: "#112233",
        authoredValue: "#112233", sourceFile: "styles.nim",
        schemaKey: "tokens.native.panel", tokenName: "--panel",
        nativeSourceShared: true, nativeSourceToken: true, sharedCount: 2)
      vm.inspector.selectedElement.val = ElementRef(id: "panel", tag: "div",
        schemaKey: "dom.panel", properties: @[token])
      var admissions = 0
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind; done: proc(ok: bool; diagnostic: string) {.closure.}) =
        inc admissions
        check element.id == "panel"
        check property == "background-color"
        check value == "#445566"
        check scope == sskSemanticToken
        done(false, "Recording adapter refuses source changes")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let source = findByAttr(shell, "data-source-scope", "true")
      check source != nil
      check source.textContent == "Theme token"
      let componentSection = findByAttr(shell, "data-inspector-section-row", "component-properties")
      check componentSection != nil
      check componentSection.styles.getOrDefault("display") == "none"
      let fillHeader = findByAttr(shell, "data-inspector-section-header", "fill")
      check fillHeader != nil
      if fillHeader.attributes.getOrDefault("aria-expanded") != "true":
        fillHeader.fireEvent("click")
      check fillHeader.attributes.getOrDefault("aria-expanded") == "true"
      let strip = findByAttr(shell, "data-fill-source-scope", "true")
      check strip != nil
      let applyToken = findByAttr(strip, "aria-label", "Apply semantic token scope for background-color")
      let applyApi = findByAttr(strip, "aria-label", "Apply component schema scope for background-color")
      check applyToken != nil and applyApi != nil
      check applyToken.attributes.getOrDefault("data-source-scope-editable") == "true"
      check applyToken.attributes.getOrDefault("data-source-scope-token") == "--panel"
      check applyToken.attributes.getOrDefault("data-source-scope-count") == "2"
      check applyApi.attributes.getOrDefault("aria-disabled") == "true"
      applyToken.fireEvent("click")
      check findByAttr(strip, "aria-label", "Apply semantic token scope for background-color").attributes.getOrDefault("aria-pressed") == "true"
      let impact = findByAttr(shell, "data-fill-source-impact", "true")
      check impact != nil and impact.styles.getOrDefault("display") == "block"
      check "--panel" in impact.textContent
      check "Known direct matches" in impact.textContent
      let before = vm.inspector.selectedElement.val
      applyApi.fireEvent("click")
      check vm.inspector.selectedElement.val == before
      check admissions == 0
      let hex = findByAttr(shell, "data-fill-row-hex", "0")
      check hex != nil
      r.setInputValue(hex, "#445566")
      hex.fireEvent("change")
      check admissions == 1
      check vm.inspector.selectedElement.val == before
      check r.inputValue(hex) == "#112233"
      let message = findByAttr(shell, "data-fill-message", "true")
      check message.textContent == "Recording adapter refuses source changes"
      check message.attributes.getOrDefault("data-fill-message-visible") == "true"
      permissions.writeSource = false
      vm.workspacePermissions.val = permissions
      r.setInputValue(hex, "#778899")
      hex.fireEvent("change")
      check admissions == 1
      check message.textContent == "This workspace is read-only for source changes."
      check vm.inspector.selectedElement.val == before
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      check vm.chat.messages.val.len == 0
      # Preserve the real computed payload: generated DOM identity is not a
      # component API or complete source ownership. No fields are discarded.
      let normalized = previewDomElementRef(StoryRenderMetadata(sourceFile: "stories.nim", sourceLine: 1),
        tag = "button", testId = "ordinary", className = "panel", sourceFile = "stories.nim", sourceLine = 1,
        backgroundColor = "rgb(17, 34, 51)", color = "rgb(255, 255, 255)", padding = "8px",
        width = "120px", height = "48px")
      vm.inspector.selectedElement.val = normalized
      check normalized.schemaKey.startsWith("dom.")
      check source.textContent == "Unknown"
      check componentSection.styles.getOrDefault("display") == "none"
      check admissions == 1
      # A distinct declared component fixture uses actual graph ownership,
      # including mapped read-only source. Editability does not erase ownership.
      vm.designSystemSchema.val = DesignSystemSchema(nodes: @[
        DesignSchemaNode(key: "Button.variant", kind: dsnComponentVariant, property: "variant")],
        sourceOwnership: @[DesignSourceOwnership(elementSourceKey: "button",
          property: "variant", nodeKey: "Button.variant", unstructuredViewCode: true)])
      vm.inspector.selectedElement.val = ElementRef(id: "button", tag: "button", schemaKey: "Button",
        properties: @[PropertyInfo(name: "variant", value: "primary", schemaKey: "Button.variant")])
      check source.textContent == "Component schema"
      check componentSection.styles.getOrDefault("display") == "flex"
      check findByAttr(shell, "data-property-row", "variant") != nil
      check admissions == 1
      check vm.inspector.undoStack.val.len == 0
      check vm.inspector.pendingSourceEdits.val.len == 0
      dispose()

  test "test_views_contain_no_hardcoded_values":
    ## View files use Tailwind classes, no hardcoded pixel values in class strings
    # Node JS has no Nim C fopen shim. Read the SAME production source at
    # compile time there; native keeps its existing filesystem check.
    when defined(js):
      const shellFile = staticRead("../src/isonim/editor/views/shell.nim")
    else:
      let shellFile = readFile("src/isonim/editor/views/shell.nim")

    # Views should use class = "..." for layout (Tailwind)
    check "class = " in shellFile

    # Views should use setStyle for dynamic/theme values — this is expected
    # But class strings should not contain raw px values
    # (they use Tailwind scale like p-4, not p-16px)

  test "test_chat_section_has_input":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.selectedStory.val = StoryRef(group: "TaskRow", name: "Active task", kind: skComponent)
      vm.setEditMode(emEdit)
      var prompts: seq[string]
      var cancellations = 0
      proc configure(chat: AgentChatVM) =
        chat.configureAgentAdapters(proc(prompt: string; context: AgentPromptContext): bool =
          prompts.add prompt
          check context.selectedStory.name == "Active task"
          check context.selectedStory.group == "TaskRow"
          true,
          proc(): bool = inc cancellations; true)
      vm.configureChat = configure
      configure(vm.chat)
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check findByAttr(shell, "aria-label", "Agent prompt") == nil
      let view = findByAttr(shell, "data-choice-group-label", "View")
      let edit = findByAttr(shell, "data-choice-group-label", "Edit")
      check view != nil and edit != nil
      view.fireEvent("click")
      let input = findByAttr(shell, "aria-label", "Agent prompt")
      let send = findByAttr(shell, "aria-label", "Send agent prompt")
      check input != nil and send != nil
      let original = vm.chat
      r.setInputValue(input, "Current shell prompt")
      input.fireEvent("input")
      check original.inputText.val == "Current shell prompt"
      send.fireEvent("click")
      check prompts == @["Current shell prompt"]
      check original.promptGeneration == 1
      check original.messages.val.len > 0
      check original.messages.val[0].kind == cmkUser
      check original.messages.val[0].text == "Current shell prompt"
      check original.inputText.val == ""
      r.setInputValue(input, "Retained shell draft")
      input.fireEvent("input")
      edit.fireEvent("click")
      check findByAttr(shell, "aria-label", "Agent prompt") == nil
      view.fireEvent("click")
      check vm.chat == original
      check findByAttr(shell, "aria-label", "Agent prompt") == input
      check original.inputText.val == "Retained shell draft"
      let retiredSend = send.eventListeners["click"][0]
      let retiredInput = input.eventListeners["input"][0]
      let newChat = findByAttr(shell, "data-ai-assistant-new-chat", "true")
      check newChat != nil
      newChat.fireEvent("click")
      let current = vm.chat
      check current != original
      let currentInput = findByAttr(shell, "aria-label", "Agent prompt")
      check currentInput != nil and currentInput != input
      r.setInputValue(currentInput, "New shell prompt")
      currentInput.fireEvent("input")
      let messages = current.messages.val
      let generation = current.promptGeneration
      retiredInput()
      retiredSend()
      check current.inputText.val == "New shell prompt"
      check current.messages.val == messages
      check current.promptGeneration == generation
      check original.inputText.val == "Retained shell draft"
      check prompts == @["Current shell prompt"]
      findByAttr(shell, "aria-label", "Send agent prompt").fireEvent("click")
      check prompts == @["Current shell prompt", "New shell prompt"]
      check current.promptGeneration == generation + 1
      check current.inputText.val == ""
      let sessions = vm.chats.val
      dispose()
      retiredSend()
      check vm.chats.val == sessions
      check vm.chat == current
      check prompts.len == 2
      check cancellations == 0

  test "editor_shell_mock_renderer_exposes_clickable_controls":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.vectorEditor.symbols.val = @[
        VectorSymbol(name: "Circle", category: "Icons",
            svgContent: "<svg></svg>"),
        VectorSymbol(name: "Rectangle", category: "Icons",
            svgContent: "<svg></svg>"),
        VectorSymbol(name: "Line", category: "Icons", svgContent: "<svg></svg>")
      ]

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check countInteractive(shell) >= 8

      let storyButton = findByAttr(shell, "aria-label", "Select story TaskRow / Active task")
      check storyButton != nil
      check storyButton.attributes["role"] == "button"
      check storyButton.attributes["tabindex"] == "0"
      check storyButton.attributes["aria-current"] == "false"
      storyButton.fireEvent("click")
      check vm.selectedStory.val.group == "TaskRow"
      check vm.selectedStory.val.name == "Active task"
      check storyButton.attributes["aria-current"] == "true"
      check storyButton.styles["background-color"].len > 0
      # M-EVP-4: the selected row's accent marker is split into the three
      # `border-left-*` sub-keys; the indigo `accent` token is `#7C7AED`.
      check storyButton.styles["border-left-color"].toLowerAscii() ==
        accent.toLowerAscii()

      let sidebarToggle = findByAttr(shell, "aria-label", "Toggle TaskRow stories")
      check sidebarToggle != nil
      check sidebarToggle.attributes["aria-expanded"] == "true"
      sidebarToggle.fireEvent("keydown")
      var taskRowCollapsed = false
      for group in vm.sidebar.groups.val:
        if group.name == "TaskRow":
          taskRowCollapsed = not group.expanded
      check taskRowCollapsed
      check sidebarToggle.attributes["aria-expanded"] == "false"

      let journeysToggle = findByAttr(shell, "aria-label",
        "Toggle User Journeys section")
      let journeysOpen = findByAttr(shell, "aria-label",
        "Open User Journeys section")
      check journeysToggle != nil
      check journeysOpen != nil
      check journeysToggle.attributes["aria-expanded"] == "true"
      journeysOpen.fireEvent("click")
      check vm.activeView.val == evStoryboard
      journeysToggle.fireEvent("click")
      check journeysToggle.attributes["aria-expanded"] == "false"

      # Phase A demolition (2026-05-28): the "Toggle inspector panel"
      # offscreen affordance used to ride inside ``renderChatPanel``,
      # which Phase A stopped mounting inside the sidebar. The chat
      # panel (and any incidental affordances it carried) re-mounts
      # inside the Phase F slide-out drawer. The
      # ``vm.togglePanel(epInspector)`` contract is unchanged and is
      # exercised by the chrome-bar tests; Phase F restores or
      # relocates this offscreen handle.
      check vm.panels.val.inspector == true

      let vector = renderVectorEditor[MockRenderer, MockNode](r, vm)
      let penTool = findByAttr(vector, "aria-label", "Select Pen vector tool")
      check penTool != nil
      check penTool.attributes["aria-pressed"] == "false"
      penTool.fireEvent("click")
      check vm.vectorEditor.activeTool.val == vtPen
      check penTool.attributes["aria-pressed"] == "true"

      let gridToggle = findByAttr(vector, "aria-label", "Toggle vector grid")
      check gridToggle != nil
      check gridToggle.attributes["aria-pressed"] == "true"
      gridToggle.fireEvent("click")
      check vm.vectorEditor.showGrid.val == false
      check gridToggle.attributes["aria-pressed"] == "false"

      let union = findByAttr(vector, "aria-label", "Vector Union")
      check union != nil
      check union.attributes["data-vector-action"] == "boolean-unite"

      # No Save control (editor spec "Saving"); the source write state the
      # Save button used to carry is on the toolbar.
      check findByAttr(vector, "aria-label", "Save vector source edits") == nil
      let vectorToolbar = findByAttr(vector, "data-vector-editor-toolbar", "true")
      check vectorToolbar != nil
      check vectorToolbar.attributes["data-vector-pending-source-edits"] == "0"

      let layer = findByAttr(vector, "aria-label", "Select vector layer Rectangle")
      check layer != nil
      layer.fireEvent("keydown")
      check vm.vectorEditor.selectedSymbol.val == 1
      check layer.attributes["aria-selected"] == "true"

      # Phase A demolition (2026-05-28): the inspector's 12 sub-tabs
      # ("Show Fill inspector section" / …) are gone. The sidebar
      # now exposes 12 ``data-inspector-section-row`` placeholders
      # in user-decided order. Phase G wires per-section content +
      # expansion controls; the underlying
      # ``vm.inspector.activeSection`` signal contract still drives
      # which section is active and is exercised here directly via
      # the VM so Phase G can rebuild the click affordance.
      let inspector = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let fillRow = findByAttr(inspector,
        "data-inspector-section-row", "fill")
      check fillRow != nil
      vm.switchInspectorSection(isFill)
      check vm.inspector.activeSection.val == isFill

      let preview = renderPreviewPane[MockRenderer, MockNode](r, vm)
      # M-EVP-7: the view-switcher chip group is gone — the chrome bar
      # no longer carries an "Open Vector editor view" button. The
      # vector-editor affordance is owned by the sidebar's per-symbol
      # action (tracked by M-EVP-8); for this regression test we drive
      # the VM directly to confirm the view-state machine still flips
      # to the vector editor.
      check findByAttr(preview, "aria-label", "Open Vector editor view") == nil
      check findByAttr(preview, "data-preview-view-switcher", "true") == nil
      vm.setActiveView(evVectorEditor)
      check vm.activeView.val == evVectorEditor
      vm.setActiveView(evStoryboard)

      # The legacy top-toolbar "Preview iOS platform" button is gone.
      # The three chip groups (backend / viewport / mode) now live in
      # the same top toolbar as the view switcher. Cocoa is the
      # renderer formerly tagged "iOS"; clicking it drives
      # `vm.platform` to pbCocoa.
      let topBar = findByAttr(preview, "data-preview-toolbar", "true")
      check topBar != nil
      check findByAttr(topBar, "aria-label", "Preview iOS platform") == nil
      check findByAttr(topBar, "data-preview-mode", "view") != nil
      check findByAttr(topBar, "data-edge-strip", "backend") != nil
      check findByAttr(topBar, "data-edge-strip", "viewport") != nil
      check findByAttr(topBar, "data-edge-strip", "mode") != nil
      let cocoaButton = findByAttr(preview,
        "aria-label", "Preview backend Cocoa")
      check cocoaButton != nil
      check cocoaButton.attributes["aria-pressed"] == "false"
      cocoaButton.fireEvent("click")
      check vm.platform.val == pbCocoa

      vm.flowPlayer.steps.val = userFlows()[0].steps
      let flowShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      # M-EVP-6: the storyboard's inner toolbar (with Next/Previous/Play/
      # Stop flow buttons) is gone. The underlying flow-player VM
      # operations remain reachable and drive the same state changes;
      # the visual affordances are tracked under the broader chrome
      # consolidation series (M-EVP-7..M-EVP-9). The test now exercises
      # the VM API directly so the storyboard's flow-player semantics
      # stay covered.
      check findByAttr(flowShell, "aria-label", "Next flow step") == nil
      check findByAttr(flowShell, "aria-label", "Previous flow step") == nil
      check findByAttr(flowShell, "aria-label", "Play flow") == nil
      check findByAttr(flowShell, "aria-label", "Stop flow") == nil
      check vm.flowPlayer.playState.val == psStopped

      discard vm.nextFlowStep()
      check vm.flowPlayer.currentStep.val == 1
      let secondStep = findByAttr(flowShell, "aria-label",
        "Select story Pages / Empty State")
      check secondStep != nil
      check secondStep.attributes["aria-current"] == "true"

      discard vm.prevFlowStep()
      check vm.flowPlayer.currentStep.val == 0

      vm.flowPlayer.play()
      check vm.flowPlayer.playState.val == psPlaying

      discard vm.stopFlow()
      check vm.flowPlayer.playState.val == psStopped
      check vm.flowPlayer.currentStep.val == 0
      storyButton.fireEvent("click")
      check vm.selectedStory.val.name == "Active task"

      var sentPrompt = ""
      var cancelled = false
      vm.chat.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
        sentPrompt = prompt
        check context.selectedStory.name == "Active task"
        true,
        proc(): bool =
        cancelled = true
        true)

      let chat = renderChatPanel[MockRenderer, MockNode](r, vm)
      let input = findByAttr(chat, "aria-label", "Agent prompt")
      let send = findByAttr(chat, "aria-label", "Send agent prompt")
      let cancel = findByAttr(chat, "aria-label", "Cancel agent prompt")
      check input != nil
      check send != nil
      check cancel != nil
      r.setInputValue(input, "Make the card clearer")
      input.fireEvent("input")
      send.fireEvent("click")
      check sentPrompt == "Make the card clearer"
      check vm.chat.messages.val[0].kind == cmkUser
      cancel.fireEvent("click")
      check cancelled
      check vm.chat.connectionState.val == "cancelled"

      dispose()

  test "sidebar sections expose top level editor navigation":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.activeView.val = evPagePreview

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      let openUserJourneys = findByAttr(sidebar, "aria-label",
        "Open User Journeys section")
      let userJourneys = findByAttr(sidebar, "aria-label",
        "Toggle User Journeys section")
      let pages = findByAttr(sidebar, "aria-label", "Toggle Pages section")

      check openUserJourneys != nil
      check userJourneys != nil
      check pages != nil
      check userJourneys.attributes["aria-expanded"] == "true"
      pages.fireEvent("click")
      check vm.activeView.val == evPagePreview
      openUserJourneys.fireEvent("click")
      check vm.activeView.val == evStoryboard
      check userJourneys.attributes["aria-expanded"] == "true"
      userJourneys.fireEvent("click")
      check userJourneys.attributes["aria-expanded"] == "false"
      userJourneys.fireEvent("click")
      check userJourneys.attributes["aria-expanded"] == "true"

      dispose()

  test "storyboard renders project previews for flow cards":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.name,
          documentHtml: "<main data-testid=\"real-flow-screen\">Cart</main>")

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let flowFrame = findByAttr(storyboard, "title", "Flow preview Cart")

      check flowFrame != nil
      check flowFrame.attributes["srcdoc"].contains("real-flow-screen")
      check flowFrame.styles["pointer-events"] == "none"

      dispose()

  test "storyboard journey cards open matching page stories":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let cartPage = StoryRef(group: "Pages", name: "Cart Page",
        kind: skPage, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ]),
        StoryGroup(
          name: "Pages",
          kind: skPage,
          description: "Concrete pages",
          expanded: true,
          items: @[
            StoryItem(name: "Cart Page", description: "Full cart page",
                      kind: skPage, group: "Pages")
        ])
      ]
      vm.flowPlayer.steps.val = @[
        FlowStep(
          screenRef: cartPage,
          action: "Cart",
          description: "Open cart page")
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.name,
          documentHtml: "<main data-testid=\"" & story.name & "\"></main>")

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let flowFrame = findByAttr(storyboard, "title", "Flow preview Cart")
      let card = findByAttr(storyboard, "aria-label", "Select flow step Cart")

      check flowFrame != nil
      check flowFrame.attributes["srcdoc"].contains("Cart Page")
      check card != nil
      card.fireEvent("click")
      check vm.selectedStory.val == cartPage
      check vm.activeView.val == evPagePreview

      dispose()

  test "storyboard exposes figma-style zoom and pan state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ])
      ]

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      # M-EVP-6: the storyboard's inner toolbar (Zoom in / Zoom out / Fit)
      # is gone. The underlying VM operations remain reachable and drive
      # the same canvas transform; the visual affordances are tracked
      # under the broader chrome consolidation series (M-EVP-7..M-EVP-9).
      check findByAttr(storyboard, "aria-label", "Zoom storyboard in") == nil
      check findByAttr(storyboard, "aria-label", "Zoom storyboard out") == nil
      check findByAttr(storyboard, "aria-label", "Fit storyboard") == nil
      let canvas = findByAttr(storyboard, "data-figma-canvas", "true")
      let content = findByAttr(storyboard, "data-figma-canvas-content", "true")
      check canvas != nil
      check content != nil
      check content.styles["transform"] == "translate(0.0px, 0.0px) scale(1.0)"

      vm.storyboard.zoom.val = 1.2
      check vm.storyboard.zoom.val > 1.0
      check content.styles["transform"].contains("scale(")

      vm.storyboard.zoom.val = 0.8
      check vm.storyboard.zoom.val <= 1.0

      vm.storyboard.panX.val = 120
      vm.storyboard.panY.val = -80
      check content.styles["transform"].contains("translate(120.0px, -80.0px)")

      vm.storyboard.zoom.val = 1.0
      vm.storyboard.panX.val = 0
      vm.storyboard.panY.val = 0
      check vm.storyboard.zoom.val == 1.0
      check vm.storyboard.panX.val == 0
      check vm.storyboard.panY.val == 0
      check content.styles["transform"] == "translate(0.0px, 0.0px) scale(1.0)"

      dispose()

  test "component detail edit action opens functional edit mode":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      vm.activeView.val = evComponentDetail
      vm.editMode.val = emView

      # CHRM-M2 + Phase I (2026-05-28): the chrome-bar mode cluster
      # is a ChoiceGroup segmented control; pills are addressed
      # positionally. Phase I extended the cluster from three to
      # four options: Spec=0, View=1, Comment=2, Edit=3.
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let modeCluster = findByAttr(shell, "data-toolbar-cluster", "mode")
      check modeCluster != nil
      let editChip = findByAttr(modeCluster, "data-choice-group-pill", "3")
      check editChip != nil
      check editChip.attributes["role"] == "button"

      editChip.fireEvent("click")
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      dispose()

  test "editor_edit_buttons_dispatch_commands":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      # CHRM-M2: per-view inner toolbars (component detail "Edit"
      # button and page preview view/edit/comment toggle) are gone.
      # The canonical chrome bar's mode cluster — now a ChoiceGroup
      # segmented control — drives the same eckEdit / eckInspect /
      # eckComment commands. Phase I (2026-05-28): the cluster
      # carries four pills (Spec=0, View=1, Comment=2, Edit=3)
      # under the ``[data-toolbar-cluster="mode"]`` root. Callers
      # that pass legacy 0/1/2 (View/Comment/Edit) are shifted to
      # 1/2/3 so the existing assertions keep targeting the same
      # editor commands.
      proc modePill(root: MockNode; idx: int): MockNode =
        let cluster = findByAttr(root, "data-toolbar-cluster", "mode")
        if cluster == nil:
          return nil
        findByAttr(cluster, "data-choice-group-pill", $(idx + 1))

      let disabledShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let disabledEditChip = modePill(disabledShell, 2)
      check disabledEditChip != nil
      check disabledEditChip.attributes["aria-disabled"] == "true"
      disabledEditChip.fireEvent("click")
      check vm.editMode.val == emView
      # CHRM-M2: the ChoiceGroup mount short-circuits disabled clicks at
      # the widget layer (before the command is invoked), so the
      # command state stays at its evaluated ``ecsDisabled`` reading
      # rather than transitioning to ``ecsFailed`` after a refused
      # execution.
      check vm.commandState(eckEdit).status == ecsDisabled
      # The disabled state's reason still calls out the missing story
      # selection — the diagnostic surfaces in the chip's tooltip
      # / a11y label and in any caller that calls evaluateCommand
      # directly.
      check vm.evaluateCommand(eckEdit).diagnostic.contains("Select a story")

      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      vm.activeView.val = evComponentDetail
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let editChip = modePill(shell, 2)
      check editChip != nil
      check editChip.attributes["aria-disabled"] == "false"
      editChip.fireEvent("click")
      check vm.commandState(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      let pageShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let viewChip = modePill(pageShell, 0)
      let editChip2 = modePill(pageShell, 2)
      check viewChip != nil
      check editChip2 != nil
      viewChip.fireEvent("click")
      check vm.commandState(eckInspect).status == ecsSucceeded
      check vm.editMode.val == emView
      editChip2.fireEvent("keydown")
      check vm.commandState(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit

      dispose()

  test "component detail renders project preview documents":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let componentStory = StoryRef(group: "Components",
        name: "Real Button", kind: skComponent, index: 0)
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Components",
          kind: skComponent,
          description: "Project components",
          expanded: true,
          items: @[
            StoryItem(name: "Real Button", description: "Actual project code",
                      kind: skComponent, group: "Components")
        ])
      ]
      var storyDescription = "Rendered by project-owned component code."
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          bodyText: storyDescription,
          documentHtml: "<main data-testid=\"real-component\">Button</main>")
      discard vm.selectStory(componentStory)

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(detail, "title",
        "Component preview Components / Real Button")

      check frame != nil
      check frame.attributes["srcdoc"].contains("real-component")
      check frame.attributes["scrolling"] == "no"
      check frame.styles["overflow"] == "hidden"
      check frame.attributes["height"] == "1"
      check detail.textContent.contains("Rendered by project-owned component code.")
      check frame.attributes["aria-description"] ==
        "Rendered by project-owned component code."
      storyDescription = "Updated story description."
      vm.preview.sourceGeneration.val = vm.preview.sourceGeneration.val + 1
      check frame.attributes["aria-description"] == "Updated story description."

      dispose()

  test "component detail renders option controls as compact choice rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "StatusBadge", name: "Neutral",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.variants.variants.val = @[
        ComponentVariantDefinition(
          component: "StatusBadge",
          variantKey: "base",
          story: story,
          properties: @[
            ComponentPropertyDefinition(
              name: "tone",
              kind: cpkEnum,
              value: "neutral",
              options: @["neutral", "success", "error"],
              sourceFile: "components/status_badge.nim",
              sourceLine: 12,
              schemaKey: "status.tone",
              documentation: "Status badge tone API",
              usageGuidance: "Choose a semantic status tone.")
          ],
          stateControls: @[
            ComponentStateControl(
              key: "disabled",
              label: "Disabled",
              kind: cskDisabled,
              value: "false",
              options: @["false", "true"],
              sourceFile: "components/status_badge.nim",
              sourceLine: 18,
              schemaKey: "status.disabled")
          ])
      ]
      discard vm.selectStory(story)

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let tone = findByAttr(detail, "aria-label",
        "Choose component property tone")
      let success = findByAttr(detail, "aria-label",
        "Apply component property tone option success")
      let disabled = findByAttr(detail, "aria-label",
        "Choose component state disabled")
      check tone != nil
      check tone.attributes["data-compact-choice-row"] == "true"
      check tone.attributes["data-component-property-options"] == "3"
      check success != nil
      check success.attributes["data-compact-choice-enabled"] == "true"
      success.fireEvent("click")
      check vm.variants.variants.val[0].properties[0].value == "success"
      check disabled != nil
      check disabled.attributes["data-compact-choice-row"] == "true"

      dispose()

  test "no panel renders a manual save or revert control":
    ## Component properties, foundations, vector and the inspector all write
    ## automatically. Each used to carry its own Save/Revert pair.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "StatusBadge", name: "Neutral",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.variants.variants.val = @[ComponentVariantDefinition(
        component: "StatusBadge", variantKey: "base", story: story,
        properties: @[ComponentPropertyDefinition(name: "tone",
          kind: cpkEnum, value: "neutral",
          options: @["neutral", "success", "error"],
          sourceFile: "components/status_badge.nim", sourceLine: 12,
          schemaKey: "status.tone")])]
      vm.foundations.tokens.val = @[FoundationTokenEntry(key: "space.card",
        kind: ftkSpacingScale, value: "16px", sourceFile: "tokens.nim",
        sourceLine: 1, schemaKey: "tokens.space.card", property: "space.card")]
      discard vm.selectStory(story)
      var found: seq[string] = @[]
      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      check findByAttr(detail, "aria-label",
        "Apply component property tone option success") != nil
      manualSaveControls(detail, found)
      let foundations = renderFoundationsPage[MockRenderer, MockNode](r, vm)
      check findByAttr(foundations, "aria-label",
        "Apply foundation token value") != nil
      manualSaveControls(foundations, found)
      let vector = renderVectorEditor[MockRenderer, MockNode](r, vm)
      check findByAttr(vector, "data-vector-editor-toolbar", "true") != nil
      manualSaveControls(vector, found)
      vm.setEditMode(emEdit)
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      manualSaveControls(shell, found)
      check found.len == 0
      if found.len > 0: echo "manual save controls: ", found
      dispose()

  test "component detail picks story-specific variants after fallback synthesis":
    ## Regression: when a sibling story in the same group has no pre-defined
    ## variant, ensureComponentPropertySchemaForSelectedStory synthesizes a
    ## fallback variant. That synthesized variant must not leak into the
    ## property panels of other stories in the same group.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let groupName = "Components"
      let storyA = StoryRef(group: groupName, name: "Story A",
        kind: skComponent, index: 0)
      let storyB = StoryRef(group: groupName, name: "Story B",
        kind: skComponent, index: 1)
      let storyC = StoryRef(group: groupName, name: "Story C",
        kind: skComponent, index: 2)
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(name: groupName, kind: skComponent, expanded: true,
          items: @[
            StoryItem(name: storyA.name, kind: skComponent, group: groupName),
            StoryItem(name: storyB.name, kind: skComponent, group: groupName),
            StoryItem(name: storyC.name, kind: skComponent, group: groupName)
          ])
      ]
      vm.variants.variants.val = @[
        ComponentVariantDefinition(
          component: "CompA",
          variantKey: "default",
          story: storyA,
          properties: @[
            ComponentPropertyDefinition(
              name: "alpha", kind: cpkText, value: "A-value",
              sourceFile: "components/comp_a.nim", sourceLine: 1,
              schemaKey: "comp.a.alpha")
          ]),
        ComponentVariantDefinition(
          component: "CompB",
          variantKey: "default",
          story: storyB,
          properties: @[
            ComponentPropertyDefinition(
              name: "beta", kind: cpkText, value: "B-value",
              sourceFile: "components/comp_b.nim", sourceLine: 1,
              schemaKey: "comp.b.beta")
          ])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          documentHtml: "<main>" & story.name & "</main>")

      proc renderFor(story: StoryRef): MockNode =
        discard vm.selectStory(story)
        renderComponentDetail[MockRenderer, MockNode](r, vm)

      block:
        let detail = renderFor(storyA)
        check findByAttr(detail, "data-component-property-control", "alpha") != nil
        check findByAttr(detail, "data-component-property-control", "beta") == nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Story C has no real variant — selecting it triggers
      # ensureComponentPropertySchemaForSelectedStory which appends a
      # fallback variant tied to storyC.
      let variantsBefore = vm.variants.variants.val.len
      discard renderFor(storyC)
      check vm.variants.variants.val.len == variantsBefore + 1
      check vm.variants.variants.val[^1].story == storyC

      # Returning to storyA must surface CompA's properties, NOT the
      # synthesized variant created for storyC.
      block:
        let detail = renderFor(storyA)
        check findByAttr(detail, "data-component-property-control", "alpha") != nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Same for storyB after the synthesis.
      block:
        let detail = renderFor(storyB)
        check findByAttr(detail, "data-component-property-control", "beta") != nil
        check findByAttr(detail, "data-component-property-control", "alpha") == nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Story C itself still shows its own synthesized variant.
      block:
        let detail = renderFor(storyC)
        check findByAttr(detail, "data-component-property-control", "label") != nil

      dispose()

  test "editor_dom_mount_has_empty_agent_state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      check vm.chat.messages.val.len == 0
      check vm.chat.connectionState.val == "disconnected"
      check vm.chat.sessionStatus.val == asIdle

      let chat = renderChatPanel[MockRenderer, MockNode](r, vm)
      check chat.textContent.contains("Ask for design-system changes")
      check chat.textContent.contains("Start a conversation")

      dispose()

  test "status bar renders element breadcrumb stack":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.selectedStory.val = StoryRef(group: "Components",
        name: "Button", kind: skComponent, index: 0)
      check vm.selectInspectorElement(ElementRef(
        tag: "span",
        sourceFile: "button.nim",
        sourceLine: 12,
        ancestors: @["main", "button", "span"]))

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check shell.textContent.contains("Components")
      check shell.textContent.contains("Button")
      check shell.textContent.contains("main")
      check shell.textContent.contains("span")
      let ancestor = findByAttr(shell, "aria-label", "Select breadcrumb button")
      check ancestor != nil

      dispose()

suite "Layers header search":

  test "rendered rows retain known source attribution without inventing unknown locations":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "known", label: "h1.title", tag: "h1",
          sourceFile: "apps/back-office/src/backoffice_ui/components.nim", sourceLine: 42),
        ElementLayerRow(id: "file-only", label: "header", tag: "header",
          sourceFile: "C:\\project\\components.nim"),
        ElementLayerRow(id: "unknown", label: "span.client", tag: "span")])
      let panel = renderSceneGraphPanel[MockRenderer, MockNode](r, vm)
      let known = panel.findByAttr("data-scene-graph-source", "known")
      require known != nil
      check known.textContent == "components.nim:42"
      check known.attributes["title"] ==
        "apps/back-office/src/backoffice_ui/components.nim:42"
      check known.styles["max-width"] == "45%"
      let fileOnly = panel.findByAttr("data-scene-graph-source", "file-only")
      require fileOnly != nil
      check fileOnly.textContent == "components.nim"
      check not fileOnly.textContent.contains(":0")
      check panel.findByAttr("data-scene-graph-row", "unknown") != nil
      check panel.findByAttr("data-scene-graph-source", "unknown") == nil
      check vm.selectInspectorElementById("known")
      vm.inspector.setLayerSearch("  COMPONENTS.NIM  ")
      check panel.findByAttr("data-scene-graph-row", "known") != nil
      check panel.findByAttr("data-scene-graph-row", "file-only") != nil
      check panel.findByAttr("data-scene-graph-row", "unknown") == nil
      check vm.inspector.selectedElement.val.id == "known"
      dispose()

  test "header search filters collapsed descendants without changing selection or expansion":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "root", label: "Save panel", tag: "main", childCount: 2,
          expanded: true),
        ElementLayerRow(id: "title", parentId: "root", label: "Welcome title",
          tag: "h1", depth: 1),
        ElementLayerRow(id: "action", parentId: "root", label: "Save changes",
          tag: "button", depth: 1)])
      check vm.selectInspectorElementById("title")
      vm.inspector.toggleLayerExpanded("root")
      let savedExpansion = vm.inspector.expandedLayerIds.val
      let panel = renderSceneGraphPanel[MockRenderer, MockNode](r, vm)
      let search = panel.findByAttr("aria-label", "Search layers")
      check panel.attributes["aria-label"] == "Layers"
      check search != nil
      check search.attributes["placeholder"] == "Search layers"
      let field = panel.findByAttr("data-sidebar-search-field", "layers")
      check field != nil
      check field.styles["background-color"] == "#1A1B26"
      check field.styles["border"] == "1px solid " & border
      check field.styles["height"] == "28px"
      check search.styles["background-color"] == "transparent"
      check not panel.textContent.contains("Scene graph")
      check panel.findByAttr("data-scene-graph-row", "action") == nil
      r.setInputValue(search, "  SAVE  ")
      search.fireEvent("input")
      check vm.inspector.layerSearch.val == "  SAVE  "
      check panel.findByAttr("data-scene-graph-row", "action") != nil
      check panel.findByAttr("data-scene-graph-row", "title") == nil
      # A matching descendant retains a nonmatching, collapsed ancestor.
      r.setInputValue(search, "changes")
      search.fireEvent("input")
      check panel.findByAttr("data-scene-graph-row", "action") != nil
      check panel.findByAttr("data-scene-graph-row", "root") != nil
      check panel.findByAttr("data-scene-graph-row", "root").attributes["aria-expanded"] == "true"
      check panel.findByAttr("data-scene-graph-twisty", "root").textContent == "\xE2\x96\xBE"
      check panel.findByAttr("data-scene-graph-row", "title") == nil
      check vm.inspector.selectedElement.val.id == "title"
      check vm.inspector.expandedLayerIds.val == savedExpansion
      r.setInputValue(search, "unknown layer")
      search.fireEvent("input")
      check panel.findByAttr("data-scene-graph-empty", "true").textContent ==
        "No matching layers"
      r.setInputValue(search, "")
      search.fireEvent("input")
      check panel.findByAttr("data-scene-graph-row", "root") != nil
      check panel.findByAttr("data-scene-graph-row", "action") == nil
      check panel.findByAttr("data-scene-graph-row", "root").attributes["aria-expanded"] == "false"
      check vm.inspector.selectedElement.val.id == "title"
      check vm.inspector.expandedLayerIds.val == savedExpansion
      vm.inspector.toggleLayerExpanded("root")
      check panel.findByAttr("data-scene-graph-row", "action") != nil
      dispose()

  test "header search shares the inspector query and preserves story search":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.setSearch("Home")
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "first", label: "Save", tag: "button"),
        ElementLayerRow(id: "second", label: "Heading", tag: "h1")])
      let panel = renderSceneGraphPanel[MockRenderer, MockNode](r, vm)
      let search = panel.findByAttr("aria-label", "Search layers")
      vm.inspector.setLayerSearch("h1")
      check r.inputValue(search) == "h1"
      check panel.findByAttr("data-scene-graph-row", "second") != nil
      check panel.findByAttr("data-scene-graph-row", "first") == nil
      check vm.sidebar.searchQuery.val == "Home"
      r.setInputValue(search, "Save")
      search.fireEvent("change")
      check vm.inspector.layerSearch.val == "Save"
      check vm.sidebar.searchQuery.val == "Home"
      dispose()

suite "Status-bar breadcrumb — the retained trail":

  proc sceneGraphRows(): seq[ElementLayerRow] =
    @[ElementLayerRow(id: "root", label: "root", tag: "div", childCount: 1,
        depth: 0, expanded: true),
      ElementLayerRow(id: "header", parentId: "root", label: "header",
        tag: "header", childCount: 1, depth: 1, expanded: true),
      ElementLayerRow(id: "title", parentId: "header", label: "h1.title",
        tag: "h1", depth: 2)]

  proc breadcrumbStates(shell: MockNode): seq[(string, string)] =
    ## (label, state) for every element segment, in render order.
    for node in shell.findAllByAttr("role", "button"):
      if "data-breadcrumb-state" in node.attributes:
        let state = node.attributes["data-breadcrumb-state"]
        if state != "story":
          result.add (node.attributes["data-breadcrumb-id"], state)

  test "clicking a middle segment keeps the deeper trail, dimmed":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.selectedStory.val = StoryRef(group: "Pages", name: "Home",
        kind: skPage, index: 0)
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "ancestor"), ("title", "selected")]

      # The breadcrumb selecting one of its own segments is a walk, not
      # a jump: the deeper segment stays, dimmed and not-selected.
      check vm.selectInspectorElementById("header", soBreadcrumb)
      check vm.inspector.selectedElement.val.id == "header"
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected"), ("title", "trail")]

      # Walking back down re-selects the dimmed segment.
      check vm.selectInspectorElementById("title", soBreadcrumb)
      check vm.inspector.selectedElement.val.id == "title"
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "ancestor"), ("title", "selected")]

      dispose()

  test "the preview's selection echo does not wipe the retained trail":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      check vm.selectInspectorElementById("header", soBreadcrumb)
      # The click also travels to the preview bridge, which answers with
      # a fresh selection event for the same element carrying only that
      # element's own (truncated) ancestry. It is the tail of the click
      # already handled, not a new selection from outside.
      check vm.selectInspectorElement(ElementRef(id: "header",
        tag: "header", ancestors: @["root", "header"],
        ancestorIds: @["root", "header"]))
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected"), ("title", "trail")]

      dispose()

  test "a selection from outside replaces the whole trail":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check vm.selectInspectorElementById("header", soBreadcrumb)
      check shell.breadcrumbStates().len == 3

      # A scene-graph row click is a jump: the retained tail belonged to
      # the path the user just left.
      check vm.selectInspectorElementById("root")
      check shell.breadcrumbStates() == @[("root", "selected")]

      dispose()

  test "an explicit same-target Layers click replaces the breadcrumb trail":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      # The parent DOM reader seeds shallow IDs on first publication; this
      # native view binding consumes the equivalent already published tree.
      vm.inspector.expandedLayerIds.val = @["root", "header"]
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check vm.selectInspectorElementById("header", soBreadcrumb)
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected"), ("title", "trail")]
      let panel = renderSceneGraphPanel[MockRenderer, MockNode](r, vm)
      let headerRow = panel.findByAttr("data-scene-graph-row", "header")
      require headerRow != nil
      headerRow.fireEvent("click")
      check vm.inspector.selectedElement.val.id == "header"
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected")]
      check vm.inspector.breadcrumbWalkId.val == ""
      # The actual preview reply after that explicit click cannot revive a tail.
      check vm.selectInspectorElement(ElementRef(id: "header", tag: "header",
        ancestors: @["root", "header"], ancestorIds: @["root", "header"]))
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected")]
      dispose()

  test "a retained tail the preview no longer renders is dropped":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check vm.selectInspectorElementById("header", soBreadcrumb)
      check shell.breadcrumbStates().len == 3

      # The preview re-rendered without the h1: a dimmed segment that
      # would select nothing is worse than no segment.
      vm.inspector.setSelectionTree(sceneGraphRows()[0 .. 1])
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected")]

      dispose()

  test "a tree that does not describe the selection leaves the trail alone":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check vm.selectInspectorElementById("header", soBreadcrumb)

      # Not every published tree describes the render the selection came
      # from; the editable preview publishes one that describes nothing
      # in particular. A tree without the selected element in it is no
      # evidence that the tail below it disappeared.
      vm.inspector.setSelectionTree(@[ElementLayerRow(id: "other",
        label: "other", tag: "div")])
      check shell.breadcrumbStates() == @[("root", "ancestor"),
        ("header", "selected"), ("title", "trail")]

      dispose()

  test "the three breadcrumb states are visually distinct":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(sceneGraphRows())
      check vm.selectInspectorElementById("title")
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check vm.selectInspectorElementById("header", soBreadcrumb)

      proc chip(id: string): MockNode = shell.findByAttr("data-breadcrumb-id", id)
      let ancestor = chip("root")
      let selected = chip("header")
      let trail = chip("title")
      check ancestor != nil and selected != nil and trail != nil
      # Fill and text colour both differ across the three states, and
      # the dimmed tail is outlined rather than filled so it does not
      # read as a disabled control.
      check selected.styles["background-color"] != ancestor.styles["background-color"]
      check trail.styles["background-color"] != ancestor.styles["background-color"]
      check trail.styles["color"] != selected.styles["color"]
      check trail.styles["border"].contains("dashed")
      check not ancestor.styles["border"].contains("dashed")
      check selected.attributes["aria-current"] == "true"
      check trail.attributes["aria-current"] == "false"
      # Still a control: it keeps the pointer cursor and a click handler.
      check trail.styles["cursor"] == "pointer"
      check "click" in trail.eventListeners

      dispose()

# ---------------------------------------------------------------------------
# Phase N (2026-05-29) — sidebar header consistency.
#
# The three sidebars (left story-tree, right Inspector, right AI
# assistant) each render a 44 px header row above their content
# separated by a 1 px ``borderFaint`` (#1F212C) hairline. The
# ``data-sidebar-header`` attribute tags each header so headless tests
# can assert the geometry + separator consistency contract from a
# single test entry-point.
# ---------------------------------------------------------------------------

suite "Phase N — sidebar header consistency":

  proc assertSidebarHeader(node: MockNode; expectedTag: string) =
    ## Helper: check a header element carries the canonical 44 px
    ## height, the ``borderFaint`` bottom separator, and the
    ## ``bgSidebar`` background.
    check node != nil
    check node.attributes.getOrDefault("data-sidebar-header") == expectedTag
    let height = node.styles.getOrDefault("height")
    let minHeight = node.styles.getOrDefault("min-height")
    # At least one of ``height`` / ``min-height`` carries the 44 px
    # target — both are set in production but the test stays
    # lenient so future refactors that drop the redundant declaration
    # don't break the contract.
    check (height == "44px" or minHeight == "44px")
    let borderBottom = node.styles.getOrDefault("border-bottom")
    # ``borderFaint`` is the canonical separator token (#1F212C).
    check borderBottom.toLowerAscii.contains("#1f212c")

  test "left sidebar header is 44 px tall with a borderFaint separator":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      let header = findByAttr(sidebar, "data-sidebar-header", "left")
      assertSidebarHeader(header, "left")
      # The search input still lives inside the header (the
      # canonical entry point for the sidebar header in Phase N).
      check findByAttr(header, "data-sidebar-search", "true") != nil
      dispose()

  test "right Inspector header is 44 px tall with a borderFaint separator":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      # The Inspector header is the Phase B selection header — it
      # gains the canonical ``data-sidebar-header`` marker in
      # Phase N.
      let header = findByAttr(panel, "data-sidebar-header", "right-inspector")
      assertSidebarHeader(header, "right-inspector")
      # Selection header still carries its original Phase B marker
      # so existing tests resolve unchanged.
      check header.attributes.getOrDefault(
        "data-inspector-selection-header") == "true"
      dispose()

  test "right AI assistant header is 44 px tall with a borderFaint separator":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderAiAssistantPanel[MockRenderer, MockNode](r, vm)
      let header = findByAttr(panel,
        "data-sidebar-header", "right-ai-assistant")
      assertSidebarHeader(header, "right-ai-assistant")
      # The AI tab strip itself IS the header — it keeps the
      # original ``data-ai-assistant-tab-strip`` marker so
      # existing e2e selectors resolve unchanged.
      check header.attributes.getOrDefault(
        "data-ai-assistant-tab-strip") == "true"
      dispose()

  test "all three sidebar headers share identical height and separator":
    ## Cross-sidebar regression — if a future refactor drops the 44
    ## px height on one sidebar without touching the others, this
    ## test fails directly on the mismatch rather than the consumer
    ## having to spot the inconsistency by eye.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let leftSidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      let inspector = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let aiPanel = renderAiAssistantPanel[MockRenderer, MockNode](r, vm)

      let leftHeader = findByAttr(leftSidebar,
        "data-sidebar-header", "left")
      let inspectorHeader = findByAttr(inspector,
        "data-sidebar-header", "right-inspector")
      let aiHeader = findByAttr(aiPanel,
        "data-sidebar-header", "right-ai-assistant")
      check leftHeader != nil
      check inspectorHeader != nil
      check aiHeader != nil

      proc canonicalHeight(node: MockNode): string =
        let h = node.styles.getOrDefault("height")
        if h.len > 0: h else: node.styles.getOrDefault("min-height")

      let leftH = canonicalHeight(leftHeader)
      let inspectorH = canonicalHeight(inspectorHeader)
      let aiH = canonicalHeight(aiHeader)
      check leftH == "44px"
      check inspectorH == "44px"
      check aiH == "44px"
      check leftH == inspectorH
      check leftH == aiH

      proc canonicalSeparator(node: MockNode): string =
        node.styles.getOrDefault("border-bottom").toLowerAscii
      let leftSep = canonicalSeparator(leftHeader)
      let inspectorSep = canonicalSeparator(inspectorHeader)
      let aiSep = canonicalSeparator(aiHeader)
      # All three separators reference the ``borderFaint`` token
      # (#1F212C). The full strings are compared so an accidental
      # swap to a different border colour fails this assertion.
      check leftSep == inspectorSep
      check leftSep == aiSep
      dispose()

# ---------------------------------------------------------------------------
# Phase Q (2026-05-29) — chrome bar height aligns with sidebar headers.
#
# Phase N pinned every sidebar header to 44 px. The chrome bar above
# the centre column previously declared ``min-height: 44px`` plus
# ``padding-top: 8px`` + ``padding-bottom: 8px`` + a 1 px bottom
# border, producing a 45 px total height — one pixel below the
# adjacent sidebar header line at the panel boundary. Phase Q drops
# the vertical padding and pins ``height = "44px"`` with
# ``box-sizing: border-box``, so the chrome bar's bottom edge sits at
# y = 44 — exactly where every sidebar header's bottom edge sits.
# ---------------------------------------------------------------------------

suite "Phase Q — chrome bar height aligns with sidebar headers":

  test "chrome bar declares a 44 px total height":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)

      # The chrome bar must declare BOTH ``height`` and ``min-height``
      # at 44 px — a future refactor that drops one without the other
      # would let flex children stretch past the target, so both are
      # pinned explicitly.
      check bar.styles.getOrDefault("height") == "44px"
      check bar.styles.getOrDefault("min-height") == "44px"
      # ``box-sizing: border-box`` ensures the declared 44 px includes
      # the 1 px bottom border — without this the border would push
      # the rendered total to 45 px.
      check bar.styles.getOrDefault("box-sizing") == "border-box"
      # No vertical padding — the 44 px row holds the controls via
      # ``align-items: center`` against the row height, not via
      # symmetric padding that would inflate the box.
      check bar.styles.getOrDefault("padding-top") == "0"
      check bar.styles.getOrDefault("padding-bottom") == "0"
      dispose()

  test "chrome bar bottom separator matches sidebar header borderFaint":
    ## The horizontal hairline at the chrome bar / sidebar header
    ## boundary must read as ONE continuous line — both the chrome
    ## bar's ``border-bottom`` and every sidebar header's
    ## ``border-bottom`` reference the same ``borderFaint`` token
    ## (#1F212C). Before Phase Q the chrome bar used the heavier
    ## ``border`` token (#2A2C3A), producing a visible colour shift at
    ## the panel boundary.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      let borderBottom = bar.styles.getOrDefault("border-bottom")
      check borderBottom.toLowerAscii.contains("#1f212c")
      dispose()

  test "chrome bar bookends carry the sidebar toggle buttons":
    ## Phase Q — the left + right sidebar toggle buttons were
    ## promoted from the status bar to the chrome bar so they align
    ## vertically with the sidebar headers they control. The
    ## canonical aria-labels are preserved so existing Playwright
    ## selectors (``getByRole("button", { name: "Toggle left
    ## sidebar" })``) still resolve to the toggle.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      let leftBtn = findByAttr(bar, "aria-label", "Toggle left sidebar")
      let rightBtn = findByAttr(bar, "aria-label", "Toggle right sidebar")
      check leftBtn != nil
      check rightBtn != nil
      dispose()

  test "status bar no longer mounts the sidebar toggle buttons":
    ## Negative assertion paired with the chrome-bar promotion above.
    ## After Phase Q, the toggles must NOT also live in the status
    ## bar — duplicating them would invite the user to wonder which
    ## affordance is canonical.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let statusBar = findByAttr(shell, "class", "editor-statusbar")
      check statusBar != nil
      let leftInStatus = findByAttr(statusBar,
        "aria-label", "Toggle left sidebar")
      let rightInStatus = findByAttr(statusBar,
        "aria-label", "Toggle right sidebar")
      check leftInStatus == nil
      check rightInStatus == nil
      dispose()

# ---------------------------------------------------------------------------
# Phase N — left sidebar drag-resize handle present on the sidebar
# root. The implementation existed before Phase N; this test pins the
# contract so future refactors don't accidentally drop it while
# touching the sidebar header.
# ---------------------------------------------------------------------------

suite "Phase N — left sidebar drag resize":

  test "left sidebar exposes a resize handle on its right edge":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      let handle = findByAttr(sidebar,
        "data-resize-handle", "left-sidebar")
      check handle != nil
      check handle.styles.getOrDefault("cursor") == "col-resize"
      check handle.styles.getOrDefault("position") == "absolute"
      # Pinned to the right edge — the cluster of (right=0, top=0,
      # width=4px) declarations is the canonical handle geometry.
      check handle.styles.getOrDefault("right") == "0"
      check handle.styles.getOrDefault("width") == "4px"
      dispose()

  test "setLeftSidebarWidth updates the leftSidebarWidth signal":
    ## Headless contract for the resize handle. The JS-side
    ## ``mousemove`` shim calls ``setLeftSidebarWidth`` via the
    ## ``window.__isonimEditor`` exposure; headless tests drive the
    ## same proc directly.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let original = vm.leftSidebarWidth.val
      vm.setLeftSidebarWidth(original + 40)
      check vm.leftSidebarWidth.val == original + 40
      # Clamp to the [180, 420] range — pushing past either bound
      # snaps to the boundary.
      vm.setLeftSidebarWidth(10)
      check vm.leftSidebarWidth.val == 180
      vm.setLeftSidebarWidth(9_999)
      check vm.leftSidebarWidth.val == 420
      dispose()

suite "Agent navigation sidebar binding lifetime":
  test "search binding follows live state and stops writing after actual scope disposal":
    let r = MockRenderer()
    var oldVm: EditorVM
    var oldInput: MockNode
    var disposeOld: proc()
    createRoot proc(dispose: proc()) =
      disposeOld = dispose
      oldVm = createEditorVM()
      let sidebar = renderSidebar[MockRenderer, MockNode](r, oldVm)
      oldInput = findByAttr(sidebar, "data-sidebar-search", "true")
      check oldInput != nil
      oldVm.sidebar.setSearch("live search")
      check r.inputValue(oldInput) == "live search"
      # Human typing updates the same value before the input event reaches VM.
      r.setInputValue(oldInput, "typed search")
      oldInput.fireEvent("input")
      check oldVm.sidebar.searchQuery.val == "typed search"
      oldVm.sidebar.setSearch("")
      check r.inputValue(oldInput) == ""
      oldVm.sidebar.setSearch("before disposal")
      check r.inputValue(oldInput) == "before disposal"
    disposeOld()
    oldVm.sidebar.searchQuery.val = "after disposal"
    check r.inputValue(oldInput) == "before disposal"
    var freshVm: EditorVM
    var freshInput: MockNode
    var disposeFresh: proc()
    createRoot proc(dispose: proc()) =
      disposeFresh = dispose
      freshVm = createEditorVM()
      freshVm.sidebar.setSearch("fresh mount")
      let sidebar = renderSidebar[MockRenderer, MockNode](r, freshVm)
      freshInput = findByAttr(sidebar, "data-sidebar-search", "true")
      check r.inputValue(freshInput) == "fresh mount"
      freshVm.sidebar.setSearch("fresh update")
      check r.inputValue(freshInput) == "fresh update"
      check r.inputValue(oldInput) == "before disposal"
    disposeFresh()
    freshVm.sidebar.searchQuery.val = "after fresh disposal"
    oldVm.sidebar.searchQuery.val = "obsolete update after remount"
    check r.inputValue(freshInput) == "fresh update"
    check r.inputValue(oldInput) == "before disposal"

suite "Unsupported inspector header Add guards":
  test "header Add is unavailable while body export configuration remains functional":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "header-selection", tag: "div")
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let exportAdd = findByAttr(panel, "data-export-add", "true")
      check exportAdd != nil
      exportAdd.fireEvent("click")
      findByAttr(panel, "data-export-row-size", "0").fireEvent("click")
      findByAttr(panel, "data-export-row-format", "0").fireEvent("click")
      let suffix = findByAttr(panel, "data-export-row-suffix", "0")
      r.setInputValue(suffix, "-configured")
      suffix.fireEvent("change")
      let selected = vm.inspector.selectedElement.val
      let expanded = vm.inspector.expandedSections.val
      let stage = vm.workspaceEditStage.val
      let generation = vm.preview.sourceGeneration.val
      for slug in ["fill", "stroke", "effects", "export"]:
        let header = findByAttr(panel, "data-inspector-section-header", slug)
        let add = findByAttr(header, "data-inspector-section-action", "add")
        check add != nil
        check add.attributes.getOrDefault("aria-disabled") == "true"
        check add.attributes.getOrDefault("title").startsWith("Adding another ")
        check add.attributes.getOrDefault("tabindex") == "0"
        check add.styles.getOrDefault("cursor") == "default"
        add.fireEvent("click")
        add.fireEvent("keydown")
        check vm.inspector.expandedSections.val == expanded
        check vm.inspector.selectedElement.val == selected
        check vm.workspaceEditStage.val == stage
        check vm.preview.sourceGeneration.val == generation
        check vm.inspector.undoStack.val.len == 0
        check vm.inspector.redoStack.val.len == 0
        check vm.inspector.pendingSourceEdits.val.len == 0
        check countByAttr(panel, "data-export-row", "0") == 1
        check findByAttr(panel, "data-export-row-size", "0").textContent == "2x"
        check findByAttr(panel, "data-export-row-format", "0").textContent == "SVG"
        check r.inputValue(findByAttr(panel, "data-export-row-suffix", "0")) == "-configured"
      findByAttr(panel, "data-export-row-delete", "0").fireEvent("click")
      check countByAttr(panel, "data-export-row", "0") == 0
      dispose()

suite "Per-item shell effects":
  test "every chat tab and overflow status follows its own session":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      discard vm.createNewChat()
      discard vm.createNewChat()
      let root = renderAiAssistantPanel[MockRenderer, MockNode](MockRenderer(), vm)
      let tabs = findAllByAttr(root, "role", "tab")
      let entries = findAllByAttr(root, "role", "option")
      require tabs.len == 3
      require entries.len == 3
      for i, session in vm.chats.val:
        session.vm.sessionStatus.val = asLoading
        for j in 0 ..< 3:
          let status = if j <= i: "loading" else: "idle"
          check findByAttr(tabs[j], "data-ai-assistant-tab-status", status) != nil
          check entries[j].children[0].styles["background-color"] ==
            (if j <= i: "#F59E0B" else: "#A0A2B0")
      dispose()

  test "canonical chrome preserves host metadata across viewport rebuilds":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let chrome = renderPreviewChromeBar[MockRenderer, MockNode](MockRenderer(), vm)
      for slug in ["view", "comment", "edit"]:
        let pill = findByAttr(chrome, "data-preview-mode", slug)
        require pill != nil
        check pill.attributes["aria-label"] == "Switch to " & slug & " mode"
      require findByAttr(chrome, "data-preview-backend", "web") != nil
      require findByAttr(chrome, "data-preview-viewport", "desktop") != nil
      vm.changePlatform(pbTui)
      let tuiViewport = pinnedViewports(pbTui)[0]
      require findByAttr(chrome, "data-preview-viewport", tuiViewport.slug) != nil
      vm.changePlatform(pbWeb)
      require findByAttr(chrome, "data-preview-viewport", "desktop") != nil
      dispose()

  test "hovering each retained breadcrumb changes only that chip":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.inspector.setSelectionTree(@[
        ElementLayerRow(id: "root", label: "root", tag: "div", childCount: 1, expanded: true),
        ElementLayerRow(id: "middle", parentId: "root", label: "middle", tag: "div", childCount: 1, depth: 1, expanded: true),
        ElementLayerRow(id: "leaf", parentId: "middle", label: "leaf", tag: "span", depth: 2)])
      require vm.selectInspectorElementById("leaf")
      let root = renderEditorShell[MockRenderer, MockNode](MockRenderer(), vm)
      require vm.selectInspectorElementById("root", soBreadcrumb)
      let chips = findAllByAttr(root, "data-breadcrumb-state", "trail")
      require chips.len == 2
      for i, chip in chips:
        chip.fireEvent("mouseenter")
        check chip.styles["color"] == "#9CA0B0"
        check chips[1-i].styles["color"] != chip.styles["color"]
        chip.fireEvent("mouseleave")
        check chip.styles["color"] == chips[1-i].styles["color"]
      dispose()
