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

type
  StyleClipboard = ref object
    property: string
    value: string

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
  [data-isonim-hovered="true"] {
    outline: 1px dashed rgba(59,130,246,.75) !important;
    outline-offset: 3px !important;
  }
  #isonim-editor-hover-label {
    position: fixed;
    z-index: 2147483647;
    pointer-events: none;
    padding: 3px 6px;
    border-radius: 4px;
    background: rgba(15,23,42,.94);
    color: #E2E8F0;
    font: 11px/1.3 ui-monospace, SFMono-Regular, Menlo, monospace;
    box-shadow: 0 4px 14px rgba(15,23,42,.28);
    transform: translateY(-100%);
  }
  #isonim-editor-selection-handles {
    position: fixed;
    z-index: 2147483646;
    pointer-events: none;
    border: 1px solid rgba(59,130,246,.9);
  }
  #isonim-editor-selection-handles > span {
    position: absolute;
    width: 7px;
    height: 7px;
    border-radius: 2px;
    background: #3B82F6;
    border: 1px solid white;
  }
</style>
<script>
(function () {
  const fallbackSource = "__ISONIM_SOURCE__";
  const fallbackLine = "__ISONIM_LINE__";
  function ensureHoverLabel() {
    let label = document.getElementById('isonim-editor-hover-label');
    if (!label) {
      label = document.createElement('div');
      label.id = 'isonim-editor-hover-label';
      label.hidden = true;
      document.body.appendChild(label);
    }
    return label;
  }
  function ensureHandles() {
    let box = document.getElementById('isonim-editor-selection-handles');
    if (!box) {
      box = document.createElement('div');
      box.id = 'isonim-editor-selection-handles';
      ['nw','ne','se','sw'].forEach((name) => {
        const handle = document.createElement('span');
        handle.dataset.handle = name;
        box.appendChild(handle);
      });
      document.body.appendChild(box);
    }
    return box;
  }
  function placeHandles(el) {
    const box = ensureHandles();
    const rect = el.getBoundingClientRect();
    box.style.left = rect.left + 'px';
    box.style.top = rect.top + 'px';
    box.style.width = rect.width + 'px';
    box.style.height = rect.height + 'px';
    box.querySelector('[data-handle="nw"]').style.cssText = 'left:-4px;top:-4px';
    box.querySelector('[data-handle="ne"]').style.cssText = 'right:-4px;top:-4px';
    box.querySelector('[data-handle="se"]').style.cssText = 'right:-4px;bottom:-4px';
    box.querySelector('[data-handle="sw"]').style.cssText = 'left:-4px;bottom:-4px';
  }
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
    window.__isonimSelectedElement = el;
    placeHandles(el);
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
  document.addEventListener('mousemove', function (event) {
    const el = event.target && event.target.closest && (
      event.target.closest('[data-isonim-src], [data-testid]') ||
      event.target.closest('[class]')
    );
    document.querySelectorAll('[data-isonim-hovered="true"]').forEach((node) => {
      if (node !== el) node.removeAttribute('data-isonim-hovered');
    });
    const label = ensureHoverLabel();
    if (!el || el === document.documentElement || el === document.body) {
      label.hidden = true;
      return;
    }
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    el.setAttribute('data-isonim-hovered', 'true');
    label.textContent = el.tagName.toLowerCase() + ' ' +
      Math.round(rect.width) + 'x' + Math.round(rect.height) +
      ' p:' + style.padding;
    label.style.left = Math.max(6, rect.left) + 'px';
    label.style.top = Math.max(18, rect.top - 6) + 'px';
    label.hidden = false;
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
  }, true);
  window.addEventListener('scroll', function () {
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
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
          """, selectFromBrowser,
        """(
            d.tag || '', d.testId || '', d.className || '', d.sourceFile || '',
            String(d.sourceLine || ''), d.backgroundColor || '', d.color || '',
            d.padding || '', d.width || '', d.height || ''
          );
        });
      }
    """].}

    {.emit: ["""
      const frame = """, frame,
        """;
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

const richSections = [
  isLayout, isSize, isSpacing, isPosition, isFill, isStroke, isTypography,
  isEffects, isTransitions, isFilters
]

const richSectionLabels = [
  "Layout", "Size", "Space", "Position", "Fill", "Stroke", "Type",
  "Effects", "Transitions", "Filters"
]

func fallbackPropertyValue(element: ElementRef; name,
    fallback: string): string =
  for prop in element.properties:
    if prop.name == name:
      return prop.value
  fallback

func sectionProperties(section: InspectorSection): seq[(string, string)] =
  case section
  of isLayout:
    @[
      ("display", "block"),
      ("flex-direction", "row"),
      ("justify-content", "flex-start"),
      ("align-items", "stretch"),
      ("gap", "0px"),
      ("overflow", "visible")
    ]
  of isSize:
    @[
      ("width", "auto"),
      ("height", "auto"),
      ("min-width", "0px"),
      ("min-height", "0px"),
      ("max-width", "none"),
      ("flex-grow", "0")
    ]
  of isSpacing:
    @[
      ("padding", "0px"),
      ("padding-top", "0px"),
      ("padding-right", "0px"),
      ("padding-bottom", "0px"),
      ("padding-left", "0px"),
      ("margin", "0px"),
      ("margin-top", "0px"),
      ("margin-bottom", "0px")
    ]
  of isPosition:
    @[
      ("position", "static"),
      ("top", "auto"),
      ("right", "auto"),
      ("bottom", "auto"),
      ("left", "auto"),
      ("z-index", "auto")
    ]
  of isFill:
    @[
      ("background-color", "transparent"),
      ("color", "inherit"),
      ("opacity", "1"),
      ("background-image", "none"),
      ("background-size", "auto")
    ]
  of isStroke:
    @[
      ("border-width", "0px"),
      ("border-color", "currentColor"),
      ("border-style", "solid"),
      ("border-radius", "0px"),
      ("outline-color", "transparent")
    ]
  of isTypography:
    @[
      ("font-size", "16px"),
      ("font-weight", "400"),
      ("line-height", "normal"),
      ("letter-spacing", "0px"),
      ("text-align", "left"),
      ("text-decoration", "none")
    ]
  of isEffects:
    @[
      ("box-shadow", "none"),
      ("filter", "none"),
      ("backdrop-filter", "none"),
      ("transform", "none"),
      ("mix-blend-mode", "normal")
    ]
  of isTransitions:
    @[
      ("transition-property", "all"),
      ("transition-duration", "150ms"),
      ("transition-timing-function", "ease"),
      ("transition-delay", "0ms")
    ]
  of isFilters:
    @[
      ("filter", "none"),
      ("brightness", "1"),
      ("contrast", "1"),
      ("saturate", "1"),
      ("blur", "0px")
    ]
  of isState:
    @[]

func quickValues(propertyName: string): seq[string] =
  case propertyName
  of "display": @["block", "flex", "grid", "none"]
  of "flex-direction": @["row", "column", "row-reverse", "column-reverse"]
  of "justify-content": @["flex-start", "center", "space-between", "flex-end"]
  of "align-items": @["stretch", "center", "flex-start", "flex-end"]
  of "overflow": @["visible", "hidden", "auto", "scroll"]
  of "position": @["static", "relative", "absolute", "sticky"]
  of "border-style": @["solid", "dashed", "dotted", "none"]
  of "font-weight": @["400", "500", "600", "700"]
  of "text-align": @["left", "center", "right", "justify"]
  of "text-decoration": @["none", "underline", "line-through"]
  of "transition-timing-function": @["linear", "ease", "ease-in", "ease-out"]
  of "mix-blend-mode": @["normal", "multiply", "screen", "overlay"]
  else: @[]

func swatchesFor(propertyName: string): seq[string] =
  if propertyName in ["background-color", "color", "border-color",
      "outline-color"]:
    @[
      "#0F172A", "#1E293B", "#3B82F6", "#22C55E", "#F59E0B", "#EF4444",
      "#FFFFFF", "transparent"
    ]
  else:
    @[]

func propertyInfo(element: ElementRef; name, fallback: string): PropertyInfo =
  for prop in element.properties:
    if prop.name == name:
      return prop
  PropertyInfo(
    name: name,
    value: fallback,
    origin: poInherited,
    originDetail: "inherited:" & name,
    sourceFile: element.sourceFile,
    sourceLine: element.sourceLine,
    schemaKey: "dom." & element.tag & "." & name,
    directStyleAllowed: true)

func originLabel(origin: PropertyOrigin): string =
  case origin
  of poTailwindClass: "class"
  of poSetStyle: "style"
  of poThemeToken: "token"
  of poConstant: "const"
  of poInherited: "inherited"

func originTone(origin: PropertyOrigin): string =
  case origin
  of poThemeToken, poConstant: "Shared"
  of poInherited: "Inherited"
  else: "Local"

func sectionCssText(element: ElementRef; section: InspectorSection): string =
  for (propName, fallback) in sectionProperties(section):
    let prop = propertyInfo(element, propName, fallback)
    result.add prop.name & ": " & prop.value & ";\n"

func parseRawCssLines(raw: string): seq[(string, string)] =
  for line in raw.splitLines:
    let text = line.strip()
    if text.len == 0 or text.startsWith("#") or text.startsWith("/*"):
      continue
    let colon = text.find(':')
    if colon <= 0:
      continue
    let propName = text[0 ..< colon].strip()
    var value = text[colon + 1 .. ^1].strip()
    if value.endsWith(";"):
      value = value[0 ..< value.len - 1].strip()
    if propName.len > 0:
      result.add (propName, value)

proc applyInspectorValue(vm: EditorVM; propName, value: string) =
  discard vm.editCssProperty(propName, value, pesLocal, peoInspector)

proc applyLivePreviewStyle[R, E](r: R; frame: E; propName, value: string) =
  when defined(js):
    {.emit: ["""
      (function () {
        const frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) return;
        const el =
          frame.contentDocument.querySelector('[data-isonim-selected="true"]') ||
          (frame.contentWindow && frame.contentWindow.__isonimSelectedElement);
        if (!el || !el.style) return;
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const prop = toJsString(""", propName,
        """);
        const value = toJsString(""", value,
        """);
        if (!el.__isonimOriginalInlineStyles) el.__isonimOriginalInlineStyles = {};
        if (!Object.prototype.hasOwnProperty.call(el.__isonimOriginalInlineStyles, prop)) {
          el.__isonimOriginalInlineStyles[prop] = {
            value: el.style.getPropertyValue(prop),
            priority: el.style.getPropertyPriority(prop)
          };
        }
        el.setAttribute('data-isonim-live-edited', 'true');
        if (value.length === 0) {
          el.style.removeProperty(prop);
        } else {
          el.style.setProperty(prop, value);
        }
      })();
    """].}

proc revertLivePreviewStyles[R, E](r: R; frame: E) =
  when defined(js):
    {.emit: ["""
      (function () {
        const frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) return;
        frame.contentDocument.querySelectorAll('[data-isonim-live-edited="true"]').forEach((el) => {
          const originals = el.__isonimOriginalInlineStyles || {};
          Object.keys(originals).forEach((prop) => {
            const original = originals[prop] || {};
            if ((original.value || '').length === 0) {
              el.style.removeProperty(prop);
            } else {
              el.style.setProperty(prop, original.value, original.priority || '');
            }
          });
          el.__isonimOriginalInlineStyles = {};
          el.removeAttribute('data-isonim-live-edited');
        });
      })();
    """].}

proc commitLivePreviewStyles[R, E](r: R; frame: E) =
  when defined(js):
    {.emit: ["""
      (function () {
        const frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) return;
        frame.contentDocument.querySelectorAll('[data-isonim-live-edited="true"]').forEach((el) => {
          el.__isonimOriginalInlineStyles = {};
          el.removeAttribute('data-isonim-live-edited');
        });
      })();
    """].}

proc applyCssValue[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string; commitSource = true) =
  if commitSource:
    vm.applyInspectorValue(propName, value)
  r.applyLivePreviewStyle(frame, propName, value)

proc applyRawCss[R, E](r: R; vm: EditorVM; frame: E; raw: string) =
  for (propName, value) in parseRawCssLines(raw):
    r.applyCssValue(vm, frame, propName, value)

proc inspectorLiveValueHandler[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): proc() =
  let capturedProp = propName
  let capturedValue = value
  result = proc() =
    r.applyCssValue(vm, frame, capturedProp, capturedValue)

proc renderPropertyInput[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): E =
  var inputNode: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "4px"):
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        label(font_size = "10px", color = textMuted,
              text_transform = "uppercase", letter_spacing = "0.4px",
              cursor = "ew-resize", flex = "1"):
          text propName
        span(font_size = "9px", color = textDim):
          text "drag"
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        input(ref = inputNode,
              class = "editor-input",
              height = "30px",
              background_color = bgSurface,
              border = "1px solid " & border,
              border_radius = "4px",
              padding = "0 8px",
              font_size = "12px",
              color = textPrimary,
              outline = "none",
              flex = "1")
        tdiv(min_width = "32px", height = "28px",
              display = "flex", align_items = "center",
              justify_content = "center",
              border = "1px solid " & border,
              border_radius = "4px",
              background_color = bgSurface,
              color = textMuted, font_size = "10px"):
          text "unit"
  r.setAttribute(inputNode, "aria-label", "Edit inspector property " & propName)
  r.setInputValue(inputNode, value)
  let commit = proc() =
    let nextValue = r.inputValue(inputNode)
    r.applyCssValue(vm, frame, propName, nextValue)
  let preview = proc() =
    r.applyCssValue(vm, frame, propName, r.inputValue(inputNode),
      commitSource = false)
  r.addEventListener(inputNode, "change", commit)
  r.addEventListener(inputNode, "blur", commit)
  r.addEventListener(inputNode, "input", preview)

proc renderCascadeIndicator[R, E](r: R; prop: PropertyInfo): E =
  let tone = originTone(prop.origin)
  let label = originLabel(prop.origin)
  let color =
    case prop.origin
    of poThemeToken, poConstant: "#FBBF24"
    of poInherited: textDim
    else: accent
  let detail =
    if prop.originDetail.len > 0: prop.originDetail
    elif prop.schemaKey.len > 0: prop.schemaKey
    else: prop.sourceFile & ":" & $prop.sourceLine
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "4px",
          padding = "6px 8px", border_radius = "4px",
          background_color = bgBase):
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        span(font_size = "10px", font_weight = "700", color = color):
          text tone
        span(font_size = "10px", color = textMuted):
          text label
      span(font_size = "10px", color = textDim, font_family = "monospace",
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text detail
  r.setAttribute(result, "aria-label", "Cascade origin for " & prop.name)

proc propertyActionHandler[R, E](r: R; vm: EditorVM; frame: E;
    propName, value: string): proc() =
  let capturedProp = propName
  let capturedValue = value
  result = proc() =
    r.applyCssValue(vm, frame, capturedProp, capturedValue)

proc renderPropertyActions[R, E](r: R; vm: EditorVM; frame: E;
    clipboard: StyleClipboard; propName, value, fallback: string): E =
  var copyButton: E
  var pasteButton: E
  var resetButton: E
  result = ui(r):
    tdiv(display = "flex", gap = "4px", align_items = "center"):
      tdiv(ref = copyButton, role = "button", tabindex = "0",
            padding = "3px 7px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "10px", cursor = "pointer"):
        text "Copy"
      tdiv(ref = pasteButton, role = "button", tabindex = "0",
            padding = "3px 7px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "10px", cursor = "pointer"):
        text "Paste"
      tdiv(ref = resetButton, role = "button", tabindex = "0",
            padding = "3px 7px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "10px", cursor = "pointer"):
        text "Reset"
  r.setAttribute(copyButton, "aria-label", "Copy " & propName & " property")
  r.setAttribute(pasteButton, "aria-label", "Paste into " & propName & " property")
  r.setAttribute(resetButton, "aria-label", "Reset " & propName & " property")
  let copy = proc() =
    clipboard.property = propName
    clipboard.value = value
  let paste = proc() =
    if clipboard.value.len > 0:
      r.applyCssValue(vm, frame, propName, clipboard.value)
  let reset = r.propertyActionHandler(vm, frame, propName, fallback)
  r.addEventListener(copyButton, "click", copy)
  r.addEventListener(copyButton, "keydown", copy)
  r.addEventListener(pasteButton, "click", paste)
  r.addEventListener(pasteButton, "keydown", paste)
  r.addEventListener(resetButton, "click", reset)
  r.addEventListener(resetButton, "keydown", reset)

proc renderQuickValues[R, E](r: R; vm: EditorVM; frame: E; propName,
    current: string): E =
  let values = quickValues(propName)
  result = ui(r):
    tdiv(display = "flex", flex_wrap = "wrap", gap = "4px")
  for value in values:
    let nextValue = $value
    let chip = ui(r):
      tdiv(role = "button", tabindex = "0",
            padding = "4px 7px", border_radius = "4px",
            font_size = "10px", font_weight = "500",
            cursor = "pointer",
            background_color = (if current ==
                nextValue: accent else: bgSurface),
            color = (if current == nextValue: textPrimary else: textMuted),
            border = "1px solid " & (if current ==
                nextValue: accent else: border)):
        text nextValue
    r.setAttribute(chip, "aria-label",
      "Set " & propName & " to " & nextValue)
    let activate = r.inspectorLiveValueHandler(vm, frame, propName, nextValue)
    r.addEventListener(chip, "click", activate)
    r.addEventListener(chip, "keydown", activate)
    r.appendChild(result, chip)

proc renderSwatches[R, E](r: R; vm: EditorVM; frame: E; propName,
    current: string): E =
  let values = swatchesFor(propName)
  result = ui(r):
    tdiv(display = "flex", flex_wrap = "wrap", gap = "6px",
          align_items = "center")
  for value in values:
    let nextValue = $value
    let swatch = ui(r):
      tdiv(role = "button", tabindex = "0",
            width = "22px", height = "22px", border_radius = "4px",
            cursor = "pointer",
            background_color = nextValue,
            border = "2px solid " & (if current ==
                nextValue: accent else: border))
    r.setAttribute(swatch, "aria-label",
      "Set " & propName & " to " & nextValue)
    let activate = r.inspectorLiveValueHandler(vm, frame, propName, nextValue)
    r.addEventListener(swatch, "click", activate)
    r.addEventListener(swatch, "keydown", activate)
    r.appendChild(result, swatch)

proc renderRichPropertyControl[R, E](r: R; vm: EditorVM; frame: E;
    clipboard: StyleClipboard; prop: PropertyInfo; fallback: string): E =
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          padding = "8px", border = "1px solid " & border,
          border_radius = "6px", background_color = "#0F172A")
  r.appendChild(result, renderPropertyInput[R, E](r, vm, frame, prop.name,
    prop.value))
  r.appendChild(result, renderCascadeIndicator[R, E](r, prop))
  r.appendChild(result, renderPropertyActions[R, E](r, vm, frame, clipboard,
    prop.name, prop.value, fallback))
  if quickValues(prop.name).len > 0:
    r.appendChild(result, renderQuickValues[R, E](r, vm, frame, prop.name,
      prop.value))
  if swatchesFor(prop.name).len > 0:
    r.appendChild(result, renderSwatches[R, E](r, vm, frame, prop.name,
      prop.value))

proc sectionTitle(section: InspectorSection): string =
  for i, candidate in richSections:
    if candidate == section:
      return richSectionLabels[i]
  "Inspector"

proc renderBoxModelSummary[R, E](r: R; selected: ElementRef): E =
  let padding = fallbackPropertyValue(selected, "padding", "0px")
  let margin = fallbackPropertyValue(selected, "margin", "0px")
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          align_items = "center", gap = "4px",
          padding = "10px", border = "1px dashed " & border,
          border_radius = "6px", background_color = bgBase):
      span(font_size = "9px", color = textDim,
            text_transform = "uppercase"):
        text "Box Model"
      tdiv(width = "180px", border = "1px dashed " & textDim,
            border_radius = "4px", padding = "8px",
            display = "flex", flex_direction = "column",
            align_items = "center", gap = "4px"):
        span(font_size = "10px", color = textMuted):
          text "margin " & margin
        tdiv(width = "130px", border = "1px solid " & accent,
              border_radius = "3px", padding = "8px",
              text_align = "center", color = accent, font_size = "10px"):
          text "padding " & padding
        span(font_size = "9px", color = textDim):
          text "click fields below for uniform or per-side values"

proc renderRawCssEditor[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef; section: InspectorSection): E =
  var rawInput: E
  var applyButton: E
  let title = sectionTitle(section)
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          padding = "10px", border = "1px solid " & border,
          border_radius = "6px", background_color = bgBase):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between"):
        span(font_size = "10px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Raw CSS"
        tdiv(ref = applyButton, role = "button", tabindex = "0",
              padding = "3px 7px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", cursor = "pointer"):
          text "Apply"
      textarea(ref = rawInput,
            class = "editor-input",
            min_height = "92px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "8px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            font_family = "monospace",
            resize = "vertical")
  r.setAttribute(rawInput, "aria-label", "Edit raw CSS for " & title & " section")
  r.setAttribute(applyButton, "aria-label", "Apply raw CSS for " & title & " section")
  r.setInputValue(rawInput, sectionCssText(selected, section))
  let apply = proc() =
    r.applyRawCss(vm, frame, r.inputValue(rawInput))
  r.addEventListener(applyButton, "click", apply)
  r.addEventListener(applyButton, "keydown", apply)
  r.addEventListener(rawInput, "blur", apply)

proc renderElementTree[R, E](r: R; selected: ElementRef): E =
  let name =
    if selected.children.len > 0:
      selected.tag & " (" & $selected.children.len & " child nodes)"
    else:
      selected.tag
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          padding = "10px", border = "1px solid " & border,
          border_radius = "6px", background_color = bgBase):
      span(font_size = "10px", font_weight = "700", color = textSecondary,
            text_transform = "uppercase", letter_spacing = "0.5px"):
        text "Element Tree"
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            font_family = "monospace", font_size = "11px"):
        span(color = textDim):
          text "document"
        span(color = textDim, padding_left = "10px"):
          text "main"
        span(color = accent, padding_left = "20px",
              font_weight = "700"):
          text name & " selected"
  r.setAttribute(result, "aria-label", "Element tree selected " & selected.tag)

proc populateInspectorContent[R, E](r: R; vm: EditorVM; frame, content: E;
    clipboard: StyleClipboard) =
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

    let active = vm.inspector.activeSection.val
    let heading = ui(r):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between"):
        span(font_size = "11px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text sectionTitle(active)
        span(font_size = "10px", color = accent, font_family = "monospace"):
          text "source-backed"
    r.appendChild(content, heading)

    if active == isSpacing:
      r.appendChild(content, renderBoxModelSummary[R, E](r, selected))

    for (propName, fallback) in sectionProperties(active):
      let prop = propertyInfo(selected, propName, fallback)
      r.appendChild(content,
        renderRichPropertyControl[R, E](r, vm, frame, clipboard, prop, fallback))

    r.appendChild(content, renderRawCssEditor[R, E](r, vm, frame, selected, active))
    r.appendChild(content, renderElementTree[R, E](r, selected))

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

proc populateSectionTabs[R, E](r: R; vm: EditorVM; frame, tabs, content: E;
    clipboard: StyleClipboard)

proc inspectorSectionHandler[R, E](r: R; vm: EditorVM; frame, tabs, content: E;
    clipboard: StyleClipboard; section: InspectorSection): proc() =
  let capturedSection = section
  result = proc() =
    vm.switchInspectorSection(capturedSection)
    r.populateSectionTabs(vm, frame, tabs, content, clipboard)
    r.populateInspectorContent(vm, frame, content, clipboard)

proc populateSectionTabs[R, E](r: R; vm: EditorVM; frame, tabs, content: E;
    clipboard: StyleClipboard) =
  r.clearChildren(tabs)
  for i, section in richSections:
    let label = richSectionLabels[i]
    let active = vm.inspector.activeSection.val == section
    let tab = ui(r):
      tdiv(role = "tab", tabindex = "0",
            display = "flex", align_items = "center",
            padding = "0 10px", font_size = "11px", font_weight = "600",
            cursor = "pointer", white_space = "nowrap",
            color = (if active: accent else: textMuted),
            box_shadow = (if active: "inset 0 -2px 0 " & accent else: "none")):
        text label
    r.setAttribute(tab, "aria-label", "Show " & label & " edit controls")
    let activate = r.inspectorSectionHandler(vm, frame, tabs, content,
      clipboard, section)
    r.addEventListener(tab, "click", activate)
    r.addEventListener(tab, "keydown", activate)
    r.appendChild(tabs, tab)

proc renderInspector[R, E](r: R; vm: EditorVM; frame: E): E =
  var saveButton: E
  var revertButton: E
  let clipboard = StyleClipboard()
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

  let tabs = ui(r):
    tdiv(class = "editor-tabbar",
          display = "flex", align_items = "stretch",
          height = "40px", min_height = "40px",
          border_bottom = "1px solid " & border,
          overflow_x = "auto", scrollbar_width = "none")
  r.appendChild(result, tabs)

  r.setAttribute(saveButton, "aria-label", "Save inspector source edits")
  r.setAttribute(revertButton, "aria-label", "Revert inspector source edits")
  let save = proc() =
    discard vm.runEditorCommand(eckSave)
    r.commitLivePreviewStyles(frame)
  let revert = proc() =
    r.revertLivePreviewStyles(frame)
    discard vm.runEditorCommand(eckRevert)
  r.addEventListener(saveButton, "click", save)
  r.addEventListener(saveButton, "keydown", save)
  r.addEventListener(revertButton, "click", revert)
  r.addEventListener(revertButton, "keydown", revert)

  let content = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          padding = "12px", overflow_y = "auto", gap = "12px")
  r.appendChild(result, content)
  r.populateSectionTabs(vm, frame, tabs, content, clipboard)

  createRenderEffect proc() =
    r.populateInspectorContent(vm, frame, content, clipboard)
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
  r.appendChild(container, renderInspector[R, E](r, vm, projectFrame))

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
