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
  #isonim-editor-selection-breadcrumb {
    position: fixed;
    z-index: 2147483647;
    pointer-events: none;
    display: flex;
    gap: 4px;
    max-width: min(92vw, 760px);
    overflow: hidden;
    padding: 4px;
    border-radius: 5px;
    background: rgba(15,23,42,.94);
    box-shadow: 0 6px 18px rgba(15,23,42,.28);
  }
  #isonim-editor-selection-breadcrumb > span {
    padding: 2px 5px;
    border-radius: 4px;
    background: rgba(30,41,59,.9);
    color: #CBD5E1;
    font: 10px/1.3 ui-monospace, SFMono-Regular, Menlo, monospace;
    white-space: nowrap;
  }
  #isonim-editor-selection-breadcrumb > span:last-child {
    background: rgba(59,130,246,.9);
    color: white;
  }
</style>
<script>
(function () {
  const fallbackSource = "__ISONIM_SOURCE__";
  const fallbackLine = "__ISONIM_LINE__";
  const editorIds = new Set([
    'isonim-editor-hover-label',
    'isonim-editor-selection-handles',
    'isonim-editor-selection-breadcrumb'
  ]);
  let lastClick = { x: -10000, y: -10000, index: 0, at: 0 };
  function isElement(node) {
    return node && node.nodeType === 1;
  }
  function isSelectable(el) {
    if (!isElement(el)) return false;
    if (el === document.documentElement || el === document.body) return false;
    if (editorIds.has(el.id)) return false;
    if (el.closest && el.closest('#isonim-editor-hover-label, #isonim-editor-selection-handles, #isonim-editor-selection-breadcrumb')) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }
  function stableSelector(el) {
    if (!isElement(el)) return '';
    const tag = el.tagName.toLowerCase();
    const testId = el.getAttribute('data-testid');
    if (testId) return tag + '[data-testid=' + testId + ']';
    const role = el.getAttribute('role');
    const cls = String(el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2);
    let text = tag;
    if (cls.length) text += '.' + cls.join('.');
    if (role) text += '[role=' + role + ']';
    return text;
  }
  function cssPath(el) {
    const parts = [];
    let node = el;
    while (isSelectable(node)) {
      let part = stableSelector(node);
      let index = 1;
      let sibling = node;
      while ((sibling = sibling.previousElementSibling)) {
        if (sibling.tagName === node.tagName) index += 1;
      }
      part += ':nth-of-type(' + index + ')';
      parts.unshift(part);
      node = node.parentElement;
    }
    return parts.join(' > ');
  }
  function ancestorStack(target) {
    const stack = [];
    let el = isElement(target) ? target : target && target.parentElement;
    while (isSelectable(el)) {
      stack.push(el);
      el = el.parentElement;
    }
    return stack;
  }
  function preferredElement(event) {
    const stack = ancestorStack(event.target);
    if (!stack.length) return null;
    if (event.shiftKey) {
      return stack.find((node) => node.hasAttribute('data-isonim-src') || node.hasAttribute('data-testid')) ||
        stack[Math.min(1, stack.length - 1)];
    }
    if (event.metaKey || event.ctrlKey || event.altKey) {
      return stack[Math.min(1, stack.length - 1)];
    }
    const now = Date.now();
    const close =
      Math.abs(event.clientX - lastClick.x) <= 3 &&
      Math.abs(event.clientY - lastClick.y) <= 3 &&
      now - lastClick.at < 900;
    if (close) {
      lastClick.index = Math.min(lastClick.index + 1, stack.length - 1);
    } else {
      lastClick.index = 0;
    }
    lastClick.x = event.clientX;
    lastClick.y = event.clientY;
    lastClick.at = now;
    return stack[Math.min(lastClick.index, stack.length - 1)];
  }
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
  function ensureBreadcrumb() {
    let crumb = document.getElementById('isonim-editor-selection-breadcrumb');
    if (!crumb) {
      crumb = document.createElement('div');
      crumb.id = 'isonim-editor-selection-breadcrumb';
      crumb.hidden = true;
      document.body.appendChild(crumb);
    }
    return crumb;
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
    const crumb = ensureBreadcrumb();
    const stack = ancestorStack(el).reverse();
    crumb.innerHTML = '';
    stack.forEach((node) => {
      const chip = document.createElement('span');
      chip.textContent = stableSelector(node);
      crumb.appendChild(chip);
    });
    crumb.style.left = Math.max(6, Math.min(rect.left, window.innerWidth - 280)) + 'px';
    crumb.style.top = Math.min(window.innerHeight - 30, rect.bottom + 8) + 'px';
    crumb.hidden = false;
  }
  function parseSource(value) {
    if (!value) return { file: fallbackSource, line: fallbackLine };
    const match = String(value).match(/^(.*?):(\d+)(?::\d+)?$/);
    if (!match) return { file: String(value), line: fallbackLine };
    return { file: match[1], line: match[2] };
  }
  function selectElement(target) {
    const el = target;
    if (!el || el === document.documentElement || el === document.body) return;
    document.querySelectorAll('[data-isonim-selected="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-selected');
    });
    el.setAttribute('data-isonim-selected', 'true');
    window.__isonimSelectedElement = el;
    placeHandles(el);
    const source = parseSource(el.getAttribute('data-isonim-src'));
    const style = window.getComputedStyle(el);
    const rect = el.getBoundingClientRect();
    const stack = ancestorStack(el).reverse().map(stableSelector);
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-selected', {
      detail: {
        tag: el.tagName.toLowerCase(),
        testId: el.getAttribute('data-testid') || '',
        className: el.getAttribute('class') || '',
        role: el.getAttribute('role') || '',
        elementPath: cssPath(el),
        ancestry: stack.join(' > '),
        sourceFile: source.file,
        sourceLine: source.line,
        display: style.display || '',
        position: style.position || '',
        backgroundColor: style.backgroundColor || '',
        color: style.color || '',
        padding: style.padding || '',
        margin: style.margin || '',
        width: style.width || '',
        height: style.height || '',
        borderRadius: style.borderRadius || '',
        borderWidth: style.borderWidth || '',
        borderStyle: style.borderStyle || '',
        borderColor: style.borderColor || '',
        fontSize: style.fontSize || '',
        fontWeight: style.fontWeight || '',
        lineHeight: style.lineHeight || '',
        boxShadow: style.boxShadow || '',
        opacity: style.opacity || '',
        rectWidth: String(Math.round(rect.width)),
        rectHeight: String(Math.round(rect.height))
      }
    }));
  }
  document.addEventListener('click', function (event) {
    event.preventDefault();
    event.stopPropagation();
    selectElement(preferredElement(event));
  }, true);
  document.addEventListener('mousemove', function (event) {
    const el = ancestorStack(event.target)[0];
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
      ' p:' + style.padding + ' • click selects, repeat-click climbs';
    label.style.left = Math.max(6, rect.left) + 'px';
    label.style.top = Math.max(18, rect.top - 6) + 'px';
    label.hidden = false;
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
  }, true);
  window.addEventListener('scroll', function () {
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
  }, true);
  window.addEventListener('resize', function () {
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
  });
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
    let selectFromBrowser = proc(tag, testId, className, role, elementPath,
        ancestry, sourceFile, sourceLine, display, position, backgroundColor,
        color, padding, margin, width, height, borderRadius, borderWidth,
        borderStyle, borderColor, fontSize, fontWeight, lineHeight, boxShadow,
        opacity, rectWidth, rectHeight: cstring) =
      let line =
        try: parseInt($sourceLine)
        except ValueError: 0
      discard vm.selectInspectorElement(previewDomElementRef(
        vm.preview.current.val.metadata,
        $tag,
        $testId,
        $className,
        $role,
        $elementPath,
        $ancestry,
        $sourceFile,
        line,
        $display,
        $position,
        $backgroundColor,
        $color,
        $padding,
        $margin,
        $width,
        $height,
        $borderRadius,
        $borderWidth,
        $borderStyle,
        $borderColor,
        $fontSize,
        $fontWeight,
        $lineHeight,
        $boxShadow,
        $opacity,
        $rectWidth,
        $rectHeight))
      if ($backgroundColor).len > 0 and ($backgroundColor) != "rgba(0, 0, 0, 0)":
        vm.inspector.activeSection.val = isFill
      elif ($padding).len > 0 or ($margin).len > 0:
        vm.inspector.activeSection.val = isSpacing
      else:
        vm.inspector.activeSection.val = isLayout
    {.emit: ["""
      if (!window.__isonimPreviewSelectionBridgeInstalled) {
        window.__isonimPreviewSelectionBridgeInstalled = true;
        window.addEventListener('isonim-preview-element-selected', function (event) {
          const d = event.detail || {};
          """, selectFromBrowser,
        """(
            d.tag || '', d.testId || '', d.className || '', d.role || '',
            d.elementPath || '', d.ancestry || '', d.sourceFile || '',
            String(d.sourceLine || ''), d.display || '', d.position || '',
            d.backgroundColor || '', d.color || '', d.padding || '',
            d.margin || '', d.width || '', d.height || '',
            d.borderRadius || '', d.borderWidth || '', d.borderStyle || '',
            d.borderColor || '', d.fontSize || '', d.fontWeight || '',
            d.lineHeight || '', d.boxShadow || '', d.opacity || '',
            d.rectWidth || '', d.rectHeight || ''
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

func isNumericProperty(propName: string): bool =
  propName in [
    "width", "height", "min-width", "min-height", "max-width", "max-height",
    "padding", "padding-top", "padding-right", "padding-bottom", "padding-left",
    "margin", "margin-top", "margin-right", "margin-bottom", "margin-left",
    "gap", "top", "right", "bottom", "left", "z-index", "border-width",
    "border-radius", "font-size", "font-weight", "line-height",
    "letter-spacing", "opacity", "transition-duration", "transition-delay",
    "brightness", "contrast", "saturate", "blur", "flex-grow"
  ]

func numericUnit(value: string; fallback = "px"): string =
  let text = value.strip()
  if text.len == 0:
    return fallback
  var i = 0
  if text[i] in {'+', '-'}:
    inc i
  while i < text.len and (text[i].isDigit or text[i] == '.'):
    inc i
  if i < text.len:
    text[i .. ^1]
  elif text in ["auto", "none", "normal", "inherit"]:
    ""
  else:
    fallback

func numericText(value: string; fallback = "0"): string =
  let text = value.strip()
  if text.len == 0:
    return fallback
  var i = 0
  if text[i] in {'+', '-'}:
    inc i
  while i < text.len and (text[i].isDigit or text[i] == '.'):
    inc i
  if i > 0 and (i > 1 or text[0] notin {'+', '-'}):
    text[0 ..< i]
  else:
    text

func numericStepValue(value: string; delta: int): string =
  let number = numericText(value)
  let unit = numericUnit(value)
  try:
    let next = parseFloat(number) + float(delta)
    let rendered =
      if abs(next - float(int(next))) < 0.0001: $int(next)
      else: $next
    rendered & unit
  except ValueError:
    value

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
    tdiv(display = "grid",
          `grid-template-columns` = "92px minmax(0, 1fr) 28px",
          align_items = "center", gap = "5px"):
      label(font_size = "10px", color = textMuted,
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis", cursor = "ew-resize"):
        text propName
      input(ref = inputNode,
            class = "editor-input",
            height = "24px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "0 6px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            min_width = "0")
      tdiv(height = "22px",
            display = "flex", align_items = "center",
            justify_content = "center",
            border = "1px solid " & border,
            border_radius = "4px",
            background_color = bgSurface,
            color = textMuted, font_size = "9px"):
        text "u"
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
    tdiv(display = "flex", align_items = "center", gap = "5px",
          padding = "4px 6px", border_radius = "4px",
          background_color = bgBase):
      span(font_size = "9px", font_weight = "700", color = color):
        text tone
      span(font_size = "9px", color = textMuted):
        text label
      span(font_size = "10px", color = textDim, font_family = "monospace",
            flex = "1", min_width = "0",
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

proc attachNumericScrubber[R, E](r: R; node: E; vm: EditorVM; frame: E;
    propName, value: string) =
  when defined(js):
    let scrub = proc(nextValue: cstring) =
      r.applyCssValue(vm, frame, propName, $nextValue)
    {.emit: ["""
      (function () {
        const node = """, node, """;
        if (!node || node.__isonimScrubberInstalled) return;
        node.__isonimScrubberInstalled = true;
        const initial = """, value, """;
        const toString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        function split(raw) {
          const text = toString(raw).trim();
          const match = text.match(/^([+-]?(?:\d+\.?\d*|\.\d+))(.*)$/);
          if (!match) return { number: 0, unit: 'px' };
          return { number: Number(match[1]), unit: match[2] || 'px' };
        }
        const parsed = split(initial);
        let dragging = false;
        let startX = 0;
        let start = parsed.number;
        function format(next, unit) {
          const rounded = Math.abs(next - Math.round(next)) < 0.001
            ? String(Math.round(next))
            : String(Math.round(next * 10) / 10);
          return rounded + unit;
        }
        function move(event) {
          if (!dragging) return;
          const speed = event.shiftKey ? 10 : (event.altKey ? 0.1 : 1);
          const next = start + (event.clientX - startX) * speed;
          """, scrub, """(format(next, parsed.unit));
          event.preventDefault();
        }
        function stop() {
          if (!dragging) return;
          dragging = false;
          document.body.style.cursor = '';
          window.removeEventListener('pointermove', move, true);
          window.removeEventListener('pointerup', stop, true);
        }
        node.addEventListener('pointerdown', (event) => {
          if (event.button !== 0) return;
          dragging = true;
          startX = event.clientX;
          start = split(initial).number;
          document.body.style.cursor = 'ew-resize';
          window.addEventListener('pointermove', move, true);
          window.addEventListener('pointerup', stop, true);
          event.preventDefault();
        });
      })();
    """].}

proc attachColorPlane[R, E](r: R; node: E; vm: EditorVM; frame: E;
    propName: string) =
  when defined(js):
    let choose = proc(nextValue: cstring) =
      r.applyCssValue(vm, frame, propName, $nextValue)
    {.emit: ["""
      (function () {
        const node = """, node, """;
        if (!node || node.__isonimColorPlaneInstalled) return;
        node.__isonimColorPlaneInstalled = true;
        function hslToHex(h, s, l) {
          s /= 100; l /= 100;
          const k = n => (n + h / 30) % 12;
          const a = s * Math.min(l, 1 - l);
          const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
          return '#' + [f(0), f(8), f(4)]
            .map(x => Math.round(255 * x).toString(16).padStart(2, '0'))
            .join('').toUpperCase();
        }
        function pick(event) {
          const rect = node.getBoundingClientRect();
          const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / Math.max(rect.width, 1)));
          const y = Math.max(0, Math.min(1, (event.clientY - rect.top) / Math.max(rect.height, 1)));
          const hue = Number(node.dataset.hue || 215);
          """, choose, """(hslToHex(hue, x * 100, (1 - y) * 68 + 16));
          event.preventDefault();
        }
        let dragging = false;
        node.addEventListener('pointerdown', (event) => {
          if (event.button !== 0) return;
          dragging = true;
          pick(event);
          window.addEventListener('pointermove', move, true);
          window.addEventListener('pointerup', stop, true);
        });
        function move(event) { if (dragging) pick(event); }
        function stop() {
          dragging = false;
          window.removeEventListener('pointermove', move, true);
          window.removeEventListener('pointerup', stop, true);
        }
      })();
    """].}

proc attachHueStrip[R, E](r: R; node: E; vm: EditorVM; frame: E;
    plane: E; propName: string) =
  when defined(js):
    let choose = proc(nextValue: cstring) =
      r.applyCssValue(vm, frame, propName, $nextValue)
    {.emit: ["""
      (function () {
        const node = """, node, """;
        const plane = """, plane, """;
        if (!node || node.__isonimHueStripInstalled) return;
        node.__isonimHueStripInstalled = true;
        function hslToHex(h, s, l) {
          s /= 100; l /= 100;
          const k = n => (n + h / 30) % 12;
          const a = s * Math.min(l, 1 - l);
          const f = n => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
          return '#' + [f(0), f(8), f(4)]
            .map(x => Math.round(255 * x).toString(16).padStart(2, '0'))
            .join('').toUpperCase();
        }
        function pick(event) {
          const rect = node.getBoundingClientRect();
          const x = Math.max(0, Math.min(1, (event.clientX - rect.left) / Math.max(rect.width, 1)));
          const hue = Math.round(x * 360);
          if (plane) plane.dataset.hue = String(hue);
          """, choose, """(hslToHex(hue, 72, 56));
          event.preventDefault();
        }
        let dragging = false;
        node.addEventListener('pointerdown', (event) => {
          if (event.button !== 0) return;
          dragging = true;
          pick(event);
          window.addEventListener('pointermove', move, true);
          window.addEventListener('pointerup', stop, true);
        });
        function move(event) { if (dragging) pick(event); }
        function stop() {
          dragging = false;
          window.removeEventListener('pointermove', move, true);
          window.removeEventListener('pointerup', stop, true);
        }
      })();
    """].}

proc renderPropertyActions[R, E](r: R; vm: EditorVM; frame: E;
    clipboard: StyleClipboard; propName, value, fallback: string): E =
  var copyButton: E
  var pasteButton: E
  var resetButton: E
  result = ui(r):
    tdiv(display = "flex", gap = "4px", align_items = "center"):
      tdiv(ref = copyButton, role = "button", tabindex = "0",
            padding = "2px 6px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", cursor = "pointer"):
        text "Copy"
      tdiv(ref = pasteButton, role = "button", tabindex = "0",
            padding = "2px 6px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", cursor = "pointer"):
        text "Paste"
      tdiv(ref = resetButton, role = "button", tabindex = "0",
            padding = "2px 6px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", cursor = "pointer"):
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

proc renderNumericAffordances[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): E =
  var scrubLabel: E
  var minusButton: E
  var plusButton: E
  let unit = numericUnit(value)
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        tdiv(ref = scrubLabel, role = "button", tabindex = "0",
              cursor = "ew-resize",
              padding = "4px 7px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", min_width = "78px",
              text_align = "center"):
          text "scrub"
        tdiv(ref = minusButton, role = "button", tabindex = "0",
              width = "26px", height = "24px", border_radius = "4px",
              display = "flex", align_items = "center",
              justify_content = "center",
              background_color = bgSurface, color = textPrimary,
              cursor = "pointer", font_size = "13px"):
          text "-"
        tdiv(ref = plusButton, role = "button", tabindex = "0",
              width = "26px", height = "24px", border_radius = "4px",
              display = "flex", align_items = "center",
              justify_content = "center",
              background_color = bgSurface, color = textPrimary,
              cursor = "pointer", font_size = "13px"):
          text "+"
        tdiv(display = "flex", gap = "3px", flex = "1",
              justify_content = "flex-end"):
          for candidate in ["px", "rem", "%", "auto"]:
            tdiv(role = "button", tabindex = "0",
                  padding = "3px 5px", border_radius = "4px",
                  background_color = (if unit == candidate: accent else: bgSurface),
                  color = (if unit == candidate: textPrimary else: textMuted),
                  font_size = "9px", cursor = "pointer"):
              text candidate
      span(font_size = "9px", color = textDim):
        text "drag label, use +/- or type math in the field"
  r.setAttribute(scrubLabel, "aria-label", "Scrub " & propName & " value")
  r.setAttribute(minusButton, "aria-label", "Decrease " & propName & " by one")
  r.setAttribute(plusButton, "aria-label", "Increase " & propName & " by one")
  let decrease = r.propertyActionHandler(vm, frame, propName,
    numericStepValue(value, -1))
  let increase = r.propertyActionHandler(vm, frame, propName,
    numericStepValue(value, 1))
  r.addEventListener(minusButton, "click", decrease)
  r.addEventListener(minusButton, "keydown", decrease)
  r.addEventListener(plusButton, "click", increase)
  r.addEventListener(plusButton, "keydown", increase)
  r.attachNumericScrubber(scrubLabel, vm, frame, propName, value)

proc renderFigmaColorAffordances[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): E =
  var saturation: E
  var hue: E
  var opacity: E
  var tokenButton: E
  let base =
    if value.startsWith("#"): value
    else: "#3B82F6"
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(ref = saturation, role = "button", tabindex = "0",
            height = "82px", border_radius = "5px",
            position = "relative", cursor = "crosshair",
            background = "linear-gradient(to right, white, " & base &
              "), linear-gradient(to top, black, transparent)",
            border = "1px solid " & border):
        tdiv(position = "absolute", left = "70%", top = "28%",
              width = "11px", height = "11px", border_radius = "6px",
              border = "2px solid white",
              box_shadow = "0 0 0 1px rgba(15,23,42,.75)")
      tdiv(ref = hue, role = "button", tabindex = "0",
            height = "12px", border_radius = "6px",
            cursor = "pointer",
            background = "linear-gradient(to right, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)")
      tdiv(ref = opacity, role = "button", tabindex = "0",
            height = "12px", border_radius = "6px",
            cursor = "pointer",
            background = "linear-gradient(to right, transparent, " & base &
              "), repeating-conic-gradient(#64748B 0% 25%, transparent 0% 50%) 50% / 8px 8px")
      tdiv(display = "flex", gap = "5px", align_items = "center"):
        tdiv(width = "24px", height = "24px", border_radius = "4px",
              background_color = base, border = "1px solid " & border)
        tdiv(ref = tokenButton, role = "button", tabindex = "0",
              flex = "1", padding = "5px 7px",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px", cursor = "pointer"):
          text "Use token"
        tdiv(role = "button", tabindex = "0",
              width = "24px", height = "24px",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "11px",
              display = "flex", align_items = "center",
              justify_content = "center"):
          text "pick"
  r.setAttribute(saturation, "aria-label",
    "Set " & propName & " from saturation brightness field")
  r.setAttribute(hue, "aria-label", "Set " & propName & " hue")
  r.setAttribute(opacity, "aria-label", "Set " & propName & " opacity")
  r.setAttribute(tokenButton, "aria-label", "Choose design token for " & propName)
  let setBlue = r.propertyActionHandler(vm, frame, propName, "#3B82F6")
  let setGreen = r.propertyActionHandler(vm, frame, propName, "#22C55E")
  r.addEventListener(saturation, "click", setBlue)
  r.addEventListener(saturation, "keydown", setBlue)
  r.addEventListener(hue, "click", setGreen)
  r.addEventListener(hue, "keydown", setGreen)
  r.attachColorPlane(saturation, vm, frame, propName)
  r.attachHueStrip(hue, vm, frame, saturation, propName)

proc renderBorderRadiusAffordances[R, E](r: R; vm: EditorVM; frame: E;
    value: string): E =
  var linkButton: E
  result = ui(r):
    tdiv(display = "flex", gap = "8px", align_items = "center",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(width = "58px", height = "58px",
            border = "2px solid " & accent,
            border_radius = value, background_color = bgSurface)
      tdiv(display = "grid",
            `grid-template-columns` = "1fr 1fr",
            gap = "4px", flex = "1"):
        for corner in ["top-left", "top-right", "bottom-left", "bottom-right"]:
          tdiv(role = "button", tabindex = "0",
                padding = "4px 5px", border_radius = "4px",
                background_color = bgSurface, color = textMuted,
                font_size = "9px", cursor = "pointer"):
            text corner
      tdiv(ref = linkButton, role = "button", tabindex = "0",
            width = "28px", height = "28px", border_radius = "4px",
            display = "flex", align_items = "center",
            justify_content = "center",
            background_color = accent, color = textPrimary,
            font_size = "11px", cursor = "pointer"):
        text "link"
  r.setAttribute(result, "aria-label", "Edit border radius corners")
  r.setAttribute(linkButton, "aria-label", "Toggle linked border radius corners")
  let setRadius = r.propertyActionHandler(vm, frame, "border-radius", "12px")
  r.addEventListener(linkButton, "click", setRadius)
  r.addEventListener(linkButton, "keydown", setRadius)

proc renderShadowAffordances[R, E](r: R; vm: EditorVM; frame: E;
    propName, value: string): E =
  var presetButton: E
  result = ui(r):
    tdiv(display = "flex", gap = "8px", padding = "8px",
          border_radius = "5px", background_color = bgBase):
      tdiv(width = "76px", height = "76px", position = "relative",
            border = "1px solid " & border,
            border_radius = "4px", background_color = bgSurface):
        tdiv(position = "absolute", left = "50%", top = "0",
              width = "1px", height = "100%",
              background_color = border)
        tdiv(position = "absolute", left = "0", top = "50%",
              width = "100%", height = "1px",
              background_color = border)
        tdiv(position = "absolute", left = "52px", top = "40px",
              width = "8px", height = "8px", border_radius = "5px",
              background_color = accent)
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            flex = "1"):
        for label in ["X 0px", "Y 8px", "Blur 24px", "Spread 0px"]:
          tdiv(height = "22px", display = "flex",
                align_items = "center", padding = "0 6px",
                border_radius = "4px", background_color = bgSurface,
                color = textMuted, font_size = "10px"):
            text label
        tdiv(ref = presetButton, role = "button", tabindex = "0",
              height = "24px", display = "flex",
              align_items = "center", justify_content = "center",
              border_radius = "4px", background_color = accent,
              color = textPrimary, font_size = "10px",
              cursor = "pointer"):
          text "soft"
  r.setAttribute(result, "aria-label", "Edit shadow with crosshair")
  r.setAttribute(presetButton, "aria-label", "Apply soft shadow preset")
  let preset = r.propertyActionHandler(vm, frame, propName,
    "0 8px 24px rgba(15, 23, 42, 0.18)")
  r.addEventListener(presetButton, "click", preset)
  r.addEventListener(presetButton, "keydown", preset)

proc renderBezierAffordances[R, E](r: R; vm: EditorVM; frame: E;
    propName, value: string): E =
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(height = "96px", position = "relative",
            border = "1px solid " & border, border_radius = "5px",
            background_color = bgSurface):
        tdiv(position = "absolute", left = "16px", bottom = "16px",
              width = "8px", height = "8px", border_radius = "5px",
              background_color = textMuted)
        tdiv(position = "absolute", right = "16px", top = "16px",
              width = "8px", height = "8px", border_radius = "5px",
              background_color = textMuted)
        tdiv(position = "absolute", left = "42px", top = "56px",
              width = "10px", height = "10px", border_radius = "6px",
              background_color = accent, border = "2px solid white")
        tdiv(position = "absolute", right = "42px", top = "26px",
              width = "10px", height = "10px", border_radius = "6px",
              background_color = accent, border = "2px solid white")
  r.setAttribute(result, "aria-label", "Edit transition timing curve")
  let presets = ui(r):
    tdiv(display = "flex", gap = "4px", flex_wrap = "wrap")
  for preset in ["linear", "ease", "ease-in", "ease-out", "ease-in-out"]:
    let nextValue = preset
    let button = ui(r):
      tdiv(role = "button", tabindex = "0",
            padding = "4px 6px", border_radius = "4px",
            background_color = (if value == nextValue: accent else: bgSurface),
            color = (if value == nextValue: textPrimary else: textMuted),
            font_size = "9px", cursor = "pointer"):
        text nextValue
    r.setAttribute(button, "aria-label",
      "Set transition timing to " & nextValue)
    let handler = r.propertyActionHandler(vm, frame, propName, nextValue)
    r.addEventListener(button, "click", handler)
    r.addEventListener(button, "keydown", handler)
    r.appendChild(presets, button)
  r.appendChild(result, presets)

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
    tdiv(display = "flex", flex_direction = "column", gap = "4px",
          padding = "6px", border = "1px solid " & border,
          border_radius = "5px", background_color = "#0F172A")
  r.appendChild(result, renderPropertyInput[R, E](r, vm, frame, prop.name,
    prop.value))
  let metaRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "5px")
  r.appendChild(metaRow, renderCascadeIndicator[R, E](r, prop))
  r.appendChild(metaRow, renderPropertyActions[R, E](r, vm, frame, clipboard,
    prop.name, prop.value, fallback))
  r.appendChild(result, metaRow)
  let advanced = ui(r):
    details(`aria-label` = "Show advanced " & prop.name & " controls"):
      summary(cursor = "pointer", color = textMuted, font_size = "10px",
              padding = "2px 0"):
        text "Advanced"
  if isNumericProperty(prop.name):
    r.appendChild(advanced, renderNumericAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if swatchesFor(prop.name).len > 0:
    r.appendChild(advanced, renderFigmaColorAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name == "border-radius":
    r.appendChild(advanced, renderBorderRadiusAffordances[R, E](r, vm, frame,
      prop.value))
  if prop.name == "box-shadow":
    r.appendChild(advanced, renderShadowAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name == "transition-timing-function":
    r.appendChild(advanced, renderBezierAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if quickValues(prop.name).len > 0:
    r.appendChild(result, renderQuickValues[R, E](r, vm, frame, prop.name,
      prop.value))
  if swatchesFor(prop.name).len > 0:
    r.appendChild(result, renderSwatches[R, E](r, vm, frame, prop.name,
      prop.value))
  r.appendChild(result, advanced)

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
        for detail in selected.children:
          let detailText = detail
          span(color = textDim, padding_left = "30px",
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text detailText
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
            padding = "0 7px", font_size = "10px", font_weight = "600",
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
    tdiv(class = "editor-manual-inspector",
          width = "300px", min_width = "220px", max_width = "520px",
          resize = "horizontal",
          display = "flex", flex_direction = "column",
          background_color = bgSidebar, overflow_y = "auto",
          border_left = "1px solid " & border):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            height = "34px", min_height = "34px",
            padding = "0 8px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        span(font_size = "12px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Inspector"
      tdiv(display = "flex", gap = "4px"):
          tdiv(ref = revertButton, role = "button", tabindex = "0",
                padding = "3px 7px", border_radius = "4px",
                font_size = "10px", cursor = "pointer",
                background_color = bgSurface, color = textMuted):
            text "Revert"
          tdiv(ref = saveButton, role = "button", tabindex = "0",
                padding = "3px 7px", border_radius = "4px",
                font_size = "10px", font_weight = "600", cursor = "pointer",
                background_color = accent, color = textPrimary):
            text "Save"

  let tabs = ui(r):
    tdiv(class = "editor-tabbar",
          display = "flex", align_items = "stretch",
          height = "30px", min_height = "30px",
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
          padding = "8px", overflow_y = "auto", gap = "8px")
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

  let inspectorPanel = renderInspector[R, E](r, vm, projectFrame)
  r.appendChild(container, preview)
  r.appendChild(container, inspectorPanel)

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
    r.setStyle(inspectorPanel, "display", if editing: "flex" else: "none")

  container
