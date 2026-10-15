## Inspector search, property copy/paste and the colour picker's typed fields.
##
## isonim-pm issues 2026-10-14-the-section-inspector-has-no-search-field,
## 2026-10-14-property-copy-paste-is-unreachable-row-more-menu-is-inert-and-
## right-click-offers-no-copy and 2026-10-14-fill-colour-picker-rgb-and-
## swatches-do-not-commit. Editor spec "Section catalogue" (search field),
## "Universal Patterns" / "Property row pattern" (Copy property, Paste
## property, Reset, More), "Color Picker" and "Planned interaction parity".
##
## Mock justification: MockRenderer stands in for the browser DOM so the
## production views (the mounted inspector panel, property rows, the property
## actions menu, the colour popup and the Fill section) run natively and under
## strict Node JS, with real signals, owners and EditorVM. It records the
## nodes, attributes and listeners the views create; events are dispatched to
## the listeners the views registered. Where a test needs a commit to land,
## the property row's `onCommitValue` (or the Fill section's
## `inspectorSourceCommit` boundary) is a recording callback that accepts or
## refuses; it stands for the editor's source pipeline, which these views call
## and do not own, and no file write or compiler result is claimed here. The
## real browser, write bridge and consumer writer are exercised by the
## consumer GUI cases metacraft_inspector_search_filters_sections_by_name_and_
## property_label, metacraft_property_copy_paste_reachable_from_row_more_and_
## right_click and metacraft_fill_picker_rgb_and_hsl_fields_commit_on_enter.

import std/[options, strutils, tables, unittest]

import isonim/core/[computation, owner, signals]
import isonim/testing/mock_dom
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/shell
import isonim/editor/views/widgets/color_popover
import isonim/editor/views/widgets/property_actions
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_fill

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node == nil: return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(name) == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil: return found

proc press(node: MockNode; key: string) =
  node.fireEventWith("keydown", MockEvent(`type`: "keydown", target: node,
    currentTarget: node, key: key))

proc typeInto(r: MockRenderer; node: MockNode; value: string) =
  r.setInputValue(node, value)
  node.fireEvent("input")

template need(node: MockNode) {.dirty.} =
  ## A control the test drives must exist. A missing one fails here by
  ## assertion and ends the test, instead of crashing on a nil node later
  ## (which would abort every remaining case).
  check node != nil
  if node == nil:
    dispose()
    return

proc sectionRow(panel: MockNode; slug: string): MockNode =
  findByAttr(panel, "data-inspector-section-row", slug)

proc shown(panel: MockNode; slug: string): bool =
  sectionRow(panel, slug).styles.getOrDefault("display") != "none"

suite "inspector section search":
  test "the mounted inspector renders the search field":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = findByAttr(panel, "data-isonim-focus-id", "section-search")
      need(field)
      check field != nil
      check field.attributes.getOrDefault("aria-label") == "Search inspector sections"
      # Above the section list, below the pinned selection header.
      check findByAttr(field, "data-inspector-section-list", "true") == nil
      dispose()

  test "a property label shows and opens its section and highlights the row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = findByAttr(panel, "data-isonim-focus-id", "section-search")
      need(field)
      check isStroke notin vm.inspector.expandedSections.val
      let before = vm.inspector.expandedSections.val
      r.typeInto(field, "border-width")
      check vm.inspector.sectionSearch.val == "border-width"
      check panel.shown("stroke")
      check isStroke in vm.inspector.expandedSections.val
      for slug in ["position", "layout", "appearance", "fill", "typography", "source", "export"]:
        check not panel.shown(slug)
      let width = findByAttr(panel, "data-property-row-css-property", "border-width")
      need(width)
      let color = findByAttr(panel, "data-property-row-css-property", "border-color")
      need(color)
      check width.attributes.getOrDefault("data-inspector-search-match") == "true"
      check color.attributes.getOrDefault("data-inspector-search-match") == "false"
      # The user can still close a section the search opened.
      vm.inspector.toggleSectionExpanded(isStroke)
      check isStroke notin vm.inspector.expandedSections.val
      # Clearing restores every section and the pre-search open/closed state.
      r.typeInto(field, "")
      for slug in ["position", "layout", "appearance", "fill", "stroke", "typography", "source", "export"]:
        check panel.shown(slug)
      check vm.inspector.expandedSections.val == before
      check width.attributes.getOrDefault("data-inspector-search-match") == "false"
      dispose()

  test "a name-only match keeps its state; a row label matches case-insensitively":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = findByAttr(panel, "data-isonim-focus-id", "section-search")
      need(field)
      r.typeInto(field, "Export")
      check panel.shown("export")
      check isExport notin vm.inspector.expandedSections.val
      check not panel.shown("stroke")
      r.typeInto(field, "PAD TOP")
      check panel.shown("layout")
      check findByAttr(panel, "data-property-row", "pad-top").attributes.getOrDefault(
        "data-inspector-search-match") == "true"
      check findByAttr(panel, "data-property-row", "pad-left").attributes.getOrDefault(
        "data-inspector-search-match") == "false"
      r.typeInto(field, "no-such-property-anywhere")
      for (slug, _) in inspectorPlaceholderSections:
        check not panel.shown(slug)
      dispose()

  test "Escape clears an active query":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let vm = createEditorVM()
      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let field = findByAttr(panel, "data-isonim-focus-id", "section-search")
      need(field)
      r.typeInto(field, "border-width")
      check not panel.shown("layout")
      field.press("Escape")
      check vm.inspector.sectionSearch.val == ""
      check r.inputValue(field) == ""
      check panel.shown("layout")
      dispose()

  test "setSectionSearch restores the pre-search expansion on clear":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.inspector.expandedSections.val = @[isLayout, isFill]
      vm.inspector.setSectionSearch("stroke")
      vm.inspector.setSectionExpanded(isStroke, true)
      vm.inspector.setSectionSearch("strok")
      check isStroke in vm.inspector.expandedSections.val
      vm.inspector.setSectionSearch("  ")
      check vm.inspector.expandedSections.val == @[isLayout, isFill]
      dispose()

suite "property copy / paste / reset":
  proc colorRow(name, property, value: string;
      clipboard: Signal[PropertyClipboardEntry];
      commits: ref seq[string]): PropertyRowConfig =
    result = propertyRowColor(name, createSignal(value), createSignal(1.0))
    result.cssProperty = property
    result.clipboard = clipboard
    result.commitMessage = createSignal("")
    result.commitRejected = createSignal(0)
    result.onCommitValue = proc(v: string) = commits[].add v

  test "the row More button and a right-click open the property menu":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let clipboard = createSignal(PropertyClipboardEntry())
      var commits = new seq[string]
      let row = r.mountPropertyRow(host, colorRow("Color", "border-color",
        "#112233", clipboard, commits))
      check findByAttr(row, "data-property-actions-menu", "true") == nil
      findByAttr(row, "data-property-row-slot", "more").fireEvent("click")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check menu != nil
      check menu.attributes.getOrDefault("role") == "menu"
      check menu.attributes.getOrDefault("aria-label") == "Actions for Color"
      check menu.attributes.getOrDefault("data-property-actions-open") == "true"
      findByAttr(row, "data-property-row-slot", "more").fireEvent("click")
      check menu.attributes.getOrDefault("data-property-actions-open") == "false"
      row.fireEvent("contextmenu")
      check menu.attributes.getOrDefault("data-property-actions-open") == "true"
      dispose()

  test "copy then paste commits through the target row's own commit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let clipboard = createSignal(PropertyClipboardEntry())
      var sourceCommits = new seq[string]
      var targetCommits = new seq[string]
      let source = r.mountPropertyRow(host, colorRow("Fill", "background-color",
        "#F8FAFC", clipboard, sourceCommits))
      let targetCfg = colorRow("Color", "border-color", "#000000", clipboard,
        targetCommits)
      let target = r.mountPropertyRow(host, targetCfg)
      # Nothing copied yet: Paste is disabled with its reason.
      target.fireEvent("contextmenu")
      let targetMenu = findByAttr(target, "data-property-actions-menu", "true")
      need(targetMenu)
      let paste = findByAttr(targetMenu, "data-property-action", "paste")
      need(paste)
      check paste.attributes.getOrDefault("aria-disabled") == "true"
      check paste.attributes.getOrDefault("title") == "Copy a property first."
      paste.fireEvent("click")
      check targetCommits[].len == 0
      check findByAttr(targetMenu, "data-property-actions-message", "true").textContent ==
        "Copy a property first."
      # The More button toggles the open menu closed.
      findByAttr(target, "data-property-row-slot", "more").fireEvent("click")
      check targetMenu.attributes.getOrDefault("data-property-actions-open") == "false"

      source.fireEvent("contextmenu")
      let sourceMenu = findByAttr(source, "data-property-actions-menu", "true")
      need(sourceMenu)
      findByAttr(sourceMenu, "data-property-action", "copy").fireEvent("click")
      check clipboard.val == PropertyClipboardEntry(property: "background-color",
        value: "#F8FAFC")
      check sourceMenu.attributes.getOrDefault("data-property-actions-open") == "false"
      check sourceCommits[].len == 0

      findByAttr(target, "data-property-row-slot", "more").fireEvent("click")
      check paste.attributes.getOrDefault("aria-disabled") == "false"
      paste.fireEvent("click")
      check targetCommits[] == @["#F8FAFC"]
      check targetCfg.colorValue.val == "#F8FAFC"
      check targetMenu.attributes.getOrDefault("data-property-actions-open") == "false"
      dispose()

  test "a value the target cannot take is refused by the row":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let clipboard = createSignal(PropertyClipboardEntry(property: "background-color",
        value: "#F8FAFC"))
      var commits: seq[string]
      var cfg = propertyRowNumeric("Width", createSignal(1.0),
        createSignal(PropertyUnitOption(label: "px", code: "px")),
        units = @[PropertyUnitOption(label: "px", code: "px")])
      cfg.cssProperty = "border-width"
      cfg.clipboard = clipboard
      cfg.commitMessage = createSignal("")
      cfg.commitRejected = createSignal(0)
      cfg.onCommitValue = proc(v: string) = commits.add v
      let row = r.mountPropertyRow(host, cfg)
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      findByAttr(menu, "data-property-action", "paste").fireEvent("click")
      check commits.len == 0
      check cfg.numericValue.val == 1.0
      check cfg.commitMessage.val == "Cannot paste #F8FAFC into Width."
      # A compatible value pastes through the same numeric commit.
      clipboard.val = PropertyClipboardEntry(property: "gap", value: "12px")
      row.fireEvent("contextmenu")
      findByAttr(menu, "data-property-action", "paste").fireEvent("click")
      check commits == @["12px"]
      check cfg.numericValue.val == 12.0
      dispose()

  test "Reset is listed, disabled and says why; read-only rows refuse paste":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let host = r.createElement("div")
      let clipboard = createSignal(PropertyClipboardEntry(property: "color",
        value: "#112233"))
      var commits = new seq[string]
      var cfg = colorRow("Color", "border-color", "#000000", clipboard, commits)
      cfg.readOnlyReason = proc(): string = "This workspace is read-only for source changes."
      let row = r.mountPropertyRow(host, cfg)
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      let reset = findByAttr(menu, "data-property-action", "reset")
      need(reset)
      check reset.attributes.getOrDefault("aria-disabled") == "true"
      check reset.attributes.getOrDefault("title") == propertyResetUnavailableReason
      reset.fireEvent("click")
      check findByAttr(menu, "data-property-actions-message", "true").textContent ==
        propertyResetUnavailableReason
      let paste = findByAttr(menu, "data-property-action", "paste")
      need(paste)
      check paste.attributes.getOrDefault("aria-disabled") == "true"
      check paste.attributes.getOrDefault("title") == "This workspace is read-only for source changes."
      paste.fireEvent("click")
      check commits[].len == 0
      # Copy still works on a read-only row: reading a value is not an edit.
      findByAttr(menu, "data-property-action", "copy").fireEvent("click")
      check clipboard.val.value == "#000000"
      dispose()

suite "colour picker typed fields":
  test "HSL text round-trips the draft":
    check colorHslText(colorChannels("#3B82F6")) == "hsl(217 91% 60%)"
    check colorHslText(colorChannels("#3B82F680")) == "hsl(217 91% 60% / 50%)"
    check colorHslText(colorChannels("#FFFFFF")) == "hsl(0 0% 100%)"
    check hslDraftColor("hsl(0 100% 50%)") == "#FF0000"
    check hslDraftColor("hsl(0, 100%, 50%)") == "#FF0000"
    check hslDraftColor("0 100% 50%") == "#FF0000"
    check hslDraftColor("hsla(0, 100%, 50%, 0.5)") == "#FF000080"
    for raw in ["", "hsl(0 100%)", "rgb(1, 2, 3)", "#FF0000", "hsl(0 100% 50%) junk"]:
      check hslDraftColor(raw) == ""

  test "Enter in a channel or HSL field commits and keeps the picker open; Tab does not":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var value = "#00000000"
      var commits: seq[string]
      var closes: seq[bool]
      discard mountColorPopover(r, parent, invoker, state,
        proc(): string = value,
        proc(next: string): bool =
          commits.add next
          closes.add state.commitCloses
          value = next
          true)
      invoker.fireEvent("click")
      let red = findByAttr(parent, "data-color-channel", "Red")
      need(red)
      let green = findByAttr(parent, "data-color-channel", "Green")
      need(green)
      let hsl = findByAttr(parent, "data-color-hsl", "true")
      need(hsl)
      check hsl != nil
      check hsl.attributes.getOrDefault("aria-label") == "HSL color"
      # A typed channel on a fully transparent draft makes it opaque.
      r.setInputValue(red, "59")
      red.press("Enter")
      check commits == @["#3B0000"]
      check closes == @[false]
      check state.open.val
      # `change` (Tab, blur) only moves the draft.
      r.setInputValue(green, "130")
      green.fireEvent("change")
      check state.draft.val == "#3B8200"
      check commits.len == 1
      green.press("Enter")
      check commits == @["#3B0000", "#3B8200"]
      check r.inputValue(hsl) == colorHslText(colorChannels("#3B8200"))
      r.setInputValue(hsl, "hsl(0 100% 50%)")
      hsl.press("Enter")
      check commits[^1] == "#FF0000"
      check state.open.val
      # A malformed HSL value is refused with a reason; its text stays.
      r.setInputValue(hsl, "hsl(0 100%)")
      hsl.press("Enter")
      check commits.len == 3
      check state.diagnostic.val.contains("HSL")
      check r.inputValue(hsl) == "hsl(0 100%)"
      hsl.fireEvent("change")
      check state.diagnostic.val.contains("HSL")
      # A swatch sets the draft (and clears the stale reason); Apply commits
      # and closes.
      findByAttr(parent, "data-color-popover-swatch", "#22C55E").fireEvent("click")
      check state.draft.val == "#22C55E"
      check state.diagnostic.val == ""
      check commits.len == 3
      findByAttr(parent, "data-color-popover-apply", "true").fireEvent("click")
      check commits[^1] == "#22C55E"
      check closes[^1] == true
      check not state.open.val
      dispose()

  test "a Fill picker survives its own committed edit":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = true
      vm.workspacePermissions.val = permissions
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233",
          authoredValue: "#112233", directStyleAllowed: true)])
      var requests: seq[string]
      vm.inspectorSourceCommit = proc(element: ElementRef; property, value: string;
          scope: SourceScopeChoiceKind;
          done: proc(ok: bool; diagnostic: string) {.closure.}) =
        requests.add value
        done(true, "")
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let swatch = findByAttr(root, "data-fill-row-swatch", "0")
      need(swatch)
      swatch.fireEvent("click")
      let popup = findByAttr(root, "data-color-popover", "true")
      need(popup)
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      let blue = findByAttr(popup, "data-color-channel", "Blue")
      need(blue)
      r.setInputValue(blue, "255")
      blue.press("Enter")
      check requests == @["#1122FF"]
      check findByAttr(root, "data-fill-row-swatch", "0") == swatch
      check popup.attributes.getOrDefault("data-color-popover-open") == "true"
      check r.inputValue(findByAttr(root, "data-fill-row-hex", "0")) == "#1122FF"
      let green = findByAttr(popup, "data-color-channel", "Green")
      need(green)
      r.setInputValue(green, "0")
      green.press("Enter")
      check requests == @["#1122FF", "#1100FF"]
      dispose()

  test "right-click on a Fill entry copies its colour":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let root = r.createElement("div")
      let vm = createEditorVM()
      vm.inspector.selectedElement.val = ElementRef(id: "card", tag: "div",
        properties: @[PropertyInfo(name: "background-color", value: "#112233")])
      mountSectionFill[MockRenderer, MockNode](r, root, vm)
      let row = findByAttr(root, "data-fill-row", "0")
      need(row)
      row.fireEvent("contextmenu")
      let menu = findByAttr(row, "data-property-actions-menu", "true")
      need(menu)
      check menu.attributes.getOrDefault("aria-label") == "Actions for Fill"
      findByAttr(menu, "data-property-action", "copy").fireEvent("click")
      check vm.inspector.propertyClipboard.val == PropertyClipboardEntry(
        property: "background-color", value: "#112233")
      dispose()
