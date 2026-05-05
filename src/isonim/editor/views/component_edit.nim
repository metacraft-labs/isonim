## IsoNim Editor — Component Edit View.
##
## Source-backed component editing: a real project preview iframe on the left
## and a functional inspector on the right.

import std/[strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgCard = "#151D2E"
  bgPreview = "#0D1525"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  green = "#22C55E"

proc editablePreviewDocument(documentHtml: string;
    metadata: StoryRenderMetadata): string =
  ## Injects editor-only click selection metadata into the project-owned
  ## document. The project document remains the rendered component source.
  func jsString(value: string): string =
    value
      .replace("\\", "\\\\")
      .replace("\"", "\\\"")
      .replace("\n", "\\n")
      .replace("\r", "\\r")

  let bridge = """
<style id="isonim-editor-selection-style">
  [data-isonim-selected="true"] {
    outline: 2px solid #3B82F6 !important;
    outline-offset: 2px !important;
    box-shadow: 0 0 0 4px rgba(59,130,246,.22) !important;
  }
</style>
<script>
(function () {
  const fallbackSource = "__ISONIM_SOURCE__";
  const fallbackLine = "__ISONIM_LINE__";
  function parseSource(value) {
    if (!value) return { file: fallbackSource, line: fallbackLine };
    const match = String(value).match(/^(.*?):(\d+)(?::\d+)?$/);
    if (!match) return { file: String(value), line: fallbackLine };
    return { file: match[1], line: match[2] };
  }
  function selectElement(target) {
    const el = target && target.closest && (
      target.closest('[data-isonim-src], [data-testid]') ||
      target.closest('[class]')
    );
    if (!el || el === document.documentElement || el === document.body) return;
    document.querySelectorAll('[data-isonim-selected="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-selected');
    });
    el.setAttribute('data-isonim-selected', 'true');
    const source = parseSource(el.getAttribute('data-isonim-src'));
    const style = window.getComputedStyle(el);
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-selected', {
      detail: {
        tag: el.tagName.toLowerCase(),
        testId: el.getAttribute('data-testid') || '',
        className: el.getAttribute('class') || '',
        sourceFile: source.file,
        sourceLine: source.line,
        backgroundColor: style.backgroundColor || '',
        color: style.color || '',
        padding: style.padding || '',
        width: style.width || '',
        height: style.height || ''
      }
    }));
  }
  document.addEventListener('click', function (event) {
    event.preventDefault();
    event.stopPropagation();
    selectElement(event.target);
  }, true);
})();
</script>
"""
  let injected = bridge
    .replace("__ISONIM_SOURCE__", metadata.sourceFile.jsString)
    .replace("__ISONIM_LINE__", $max(metadata.sourceLine, 1))
  if "</body>" in documentHtml:
    documentHtml.replace("</body>", injected & "</body>")
  else:
    documentHtml & injected

proc installPreviewSelectionBridge[R, E](r: R; frame: E; vm: EditorVM) =
  when defined(js):
    let selectFromBrowser = proc(tag, testId, className, sourceFile,
        sourceLine, backgroundColor, color, padding, width,
        height: cstring) =
      let line =
        try: parseInt($sourceLine)
        except ValueError: 0
      discard vm.selectInspectorElement(previewDomElementRef(
        vm.preview.current.val.metadata,
        $tag,
        $testId,
        $className,
        $sourceFile,
        line,
        $backgroundColor,
        $color,
        $padding,
        $width,
        $height))
      vm.inspector.activeSection.val =
        if ($backgroundColor).len > 0: isFill else: isSpacing
    {.emit: ["""
      if (!window.__isonimPreviewSelectionBridgeInstalled) {
        window.__isonimPreviewSelectionBridgeInstalled = true;
        window.addEventListener('isonim-preview-element-selected', function (event) {
          const d = event.detail || {};
          """, selectFromBrowser, """(
            d.tag || '', d.testId || '', d.className || '', d.sourceFile || '',
            String(d.sourceLine || ''), d.backgroundColor || '', d.color || '',
            d.padding || '', d.width || '', d.height || ''
          );
        });
      }
    """].}

    {.emit: ["""
      const frame = """, frame, """;
      if (frame && !frame.__isonimEditFrameAutoHeightInstalled) {
        frame.__isonimEditFrameAutoHeightInstalled = true;
        const resizeFrame = () => {
          try {
            const doc = frame.contentDocument;
            if (!doc) return;
            const body = doc.body;
            const html = doc.documentElement;
            const height = Math.max(
              body ? body.scrollHeight : 0,
              html ? html.scrollHeight : 0,
              320
            );
            frame.style.height = height + 'px';
          } catch (error) {}
        };
        frame.addEventListener('load', resizeFrame);
        setTimeout(resizeFrame, 0);
      }
    """].}

proc renderPropertyInput[R, E](r: R; vm: EditorVM; prop: PropertyInfo): E =
  let propName = prop.name
  var inputNode: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "4px"):
      label(font_size = "10px", color = textMuted,
            text_transform = "uppercase", letter_spacing = "0.4px"):
        text propName
      input(ref = inputNode,
            class = "editor-input",
            height = "30px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "0 8px",
            font_size = "12px",
            color = textPrimary,
            outline = "none")
  r.setAttribute(inputNode, "aria-label", "Edit inspector property " & propName)
  r.setInputValue(inputNode, prop.value)
  let commit = proc() =
    discard vm.editCssProperty(propName, r.inputValue(inputNode), pesLocal,
      peoInspector)
  r.addEventListener(inputNode, "change", commit)
  r.addEventListener(inputNode, "keydown", commit)

proc populateInspectorContent[R, E](r: R; vm: EditorVM; content: E) =
  r.clearChildren(content)
  if vm.inspector.hasElement.val:
    let selected = vm.inspector.selectedElement.val
    let summary = ui(r):
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            padding = "10px", border = "1px solid " & border,
            border_radius = "6px", background_color = bgBase):
        span(font_size = "10px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Selection"
        span(font_size = "12px", color = textPrimary,
              font_family = "monospace"):
          text selected.tag
        span(font_size = "11px", color = textDim):
          text selected.sourceFile & ":" & $selected.sourceLine
    r.appendChild(content, summary)

    for prop in vm.inspector.properties.val:
      if prop.name in ["background-color", "color", "padding", "width",
          "height"]:
        r.appendChild(content, renderPropertyInput[R, E](r, vm, prop))

    if vm.inspector.pendingSourceEdits.val.len > 0:
      let dirty = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "4px",
              padding = "10px", border = "1px solid " & green,
              border_radius = "6px", background_color = "#052E1A"):
          span(font_size = "11px", font_weight = "700", color = "#BBF7D0"):
            text "Unsaved source edit"
          span(font_size = "11px", color = "#86EFAC"):
            text $vm.inspector.pendingSourceEdits.val.len &
              " source plan(s) staged"
      r.appendChild(content, dirty)
  else:
    let empty = ui(r):
      tdiv(flex = "1", display = "flex", flex_direction = "column",
            align_items = "center", justify_content = "center",
            padding = "24px 16px", text_align = "center"):
        span(font_size = "12px", color = textMuted):
          text "Select an element in the preview"
        span(font_size = "11px", color = textDim, margin_top = "4px"):
          text "Click real rendered DOM in the iframe"
    r.appendChild(content, empty)

proc renderInspector[R, E](r: R; vm: EditorVM): E =
  var saveButton: E
  var revertButton: E
  result = ui(r):
    tdiv(width = "340px", min_width = "340px",
          display = "flex", flex_direction = "column",
          background_color = bgSidebar, overflow_y = "auto",
          border_left = "1px solid " & border):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            height = "44px", min_height = "44px",
            padding = "0 12px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        span(font_size = "12px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Inspector"
        tdiv(display = "flex", gap = "6px"):
          tdiv(ref = revertButton, role = "button", tabindex = "0",
                padding = "4px 9px", border_radius = "4px",
                font_size = "11px", cursor = "pointer",
                background_color = bgSurface, color = textMuted):
            text "Revert"
          tdiv(ref = saveButton, role = "button", tabindex = "0",
                padding = "4px 9px", border_radius = "4px",
                font_size = "11px", font_weight = "600", cursor = "pointer",
                background_color = accent, color = textPrimary):
            text "Save"

  r.setAttribute(saveButton, "aria-label", "Save inspector source edits")
  r.setAttribute(revertButton, "aria-label", "Revert inspector source edits")
  r.addEventListener(saveButton, "click", proc() =
    discard vm.runEditorCommand(eckSave))
  r.addEventListener(saveButton, "keydown", proc() =
    discard vm.runEditorCommand(eckSave))
  r.addEventListener(revertButton, "click", proc() =
    discard vm.runEditorCommand(eckRevert))
  r.addEventListener(revertButton, "keydown", proc() =
    discard vm.runEditorCommand(eckRevert))

  let content = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          padding = "12px", overflow_y = "auto", gap = "12px")
  r.appendChild(result, content)

  createRenderEffect proc() =
    r.populateInspectorContent(vm, content)
    let save = vm.evaluateCommand(eckSave)
    let revert = vm.evaluateCommand(eckRevert)
    r.setAttribute(saveButton, "aria-disabled",
      if save.status == ecsDisabled: "true" else: "false")
    r.setAttribute(revertButton, "aria-disabled",
      if revert.status == ecsDisabled: "true" else: "false")
    r.setStyle(saveButton, "opacity",
      if save.status == ecsDisabled: "0.45" else: "1")
    r.setStyle(revertButton, "opacity",
      if revert.status == ecsDisabled: "0.45" else: "1")

proc renderComponentEditView*[R, E](r: R; vm: EditorVM): E =
  var editModeButton: E
  var viewModeButton: E
  var titleNode: E
  var sourceNode: E
  var projectFrame: E
  var lastSrcdoc = ""

  let container = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex",
          min_width = "0", height = "100%",
          background_color = bgBase)

  let preview = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          min_width = "0"):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            height = "44px", min_height = "44px", padding = "0 16px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        tdiv(display = "flex", flex_direction = "column", gap = "2px",
              min_width = "0"):
          span(ref = titleNode, font_size = "13px", font_weight = "600",
                color = textPrimary, white_space = "nowrap",
                overflow = "hidden", text_overflow = "ellipsis"):
            text "Component edit"
          span(ref = sourceNode, font_size = "11px", color = textDim,
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text ""
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(ref = editModeButton,
                padding = "4px 12px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                cursor = "pointer",
                background_color = accent, color = textPrimary):
            text "Edit"
          tdiv(ref = viewModeButton,
                padding = "4px 12px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                cursor = "pointer",
                background_color = bgSurface, color = textMuted):
            text "View"
      tdiv(flex = "1", overflow = "auto", background_color = bgPreview,
            padding = "24px"):
        iframe(ref = projectFrame,
          title = "Editable component preview",
          width = "100%",
          height = "480",
          border = "0",
          background_color = "#FFFFFF")
      tdiv(display = "flex", align_items = "center", gap = "6px",
            height = "32px", padding = "0 16px",
            background_color = bgSurface,
            border_top = "1px solid " & border,
            font_size = "11px", color = textMuted):
        span: text "Click an element to select it"
        span(color = textDim): text "•"
        span: text "Edit color or spacing in the inspector"

  r.appendChild(container, preview)
  r.appendChild(container, renderInspector[R, E](r, vm))

  r.setAttribute(editModeButton, "role", "button")
  r.setAttribute(editModeButton, "tabindex", "0")
  r.setAttribute(editModeButton, "aria-label", "Switch to edit mode")
  r.setAttribute(viewModeButton, "role", "button")
  r.setAttribute(viewModeButton, "tabindex", "0")
  r.setAttribute(viewModeButton, "aria-label", "Switch to view mode")
  r.addEventListener(editModeButton, "click", proc() =
    discard vm.runEditorCommand(eckEdit))
  r.addEventListener(editModeButton, "keydown", proc() =
    discard vm.runEditorCommand(eckEdit))
  r.addEventListener(viewModeButton, "click", proc() =
    discard vm.runEditorCommand(eckInspect))
  r.addEventListener(viewModeButton, "keydown", proc() =
    discard vm.runEditorCommand(eckInspect))
  installPreviewSelectionBridge[R, E](r, projectFrame, vm)

  createRenderEffect proc() =
    let previewState = vm.preview.current.val
    let metadata = previewState.metadata
    let title =
      if previewState.title.len > 0: previewState.title
      elif vm.selectedStory.val.group.len > 0:
        vm.selectedStory.val.group & " / " & vm.selectedStory.val.name
      else:
        "Component edit"
    r.setTextContent(titleNode, title)
    r.setTextContent(sourceNode,
      if metadata.sourceFile.len > 0:
        metadata.sourceFile & ":" & $max(metadata.sourceLine, 1)
      else:
        "No source metadata")
    let nextSrcdoc = editablePreviewDocument(previewState.documentHtml, metadata)
    if nextSrcdoc != lastSrcdoc:
      lastSrcdoc = nextSrcdoc
      r.setAttribute(projectFrame, "srcdoc", nextSrcdoc)
    r.setStyle(projectFrame, "min-height", "320px")
    r.setStyle(projectFrame, "overflow", "hidden")

    let editing = vm.editMode.val == emEdit
    let editState = vm.evaluateCommand(eckEdit)
    let inspectState = vm.evaluateCommand(eckInspect)
    r.setAttribute(editModeButton, "aria-pressed",
      if editing: "true" else: "false")
    r.setAttribute(viewModeButton, "aria-pressed",
      if editing: "false" else: "true")
    r.setAttribute(editModeButton, "aria-disabled",
      if editState.status == ecsDisabled: "true" else: "false")
    r.setAttribute(viewModeButton, "aria-disabled",
      if inspectState.status == ecsDisabled: "true" else: "false")
    r.setStyle(editModeButton, "background-color",
      if editing: accent else: bgSurface)
    r.setStyle(editModeButton, "color",
      if editing: textPrimary else: textMuted)
    r.setStyle(viewModeButton, "background-color",
      if editing: bgSurface else: accent)
    r.setStyle(viewModeButton, "color",
      if editing: textMuted else: textPrimary)

  container
