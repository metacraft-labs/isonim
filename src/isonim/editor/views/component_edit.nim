## IsoNim Editor — Component Edit View.
##
## Source-backed component editing: a real project preview iframe on the left
## and a functional inspector on the right.

import std/[strutils, math, strformat]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/choice_row

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgCard = "#151D2E"
  bgPreview = "#0D1525"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  green = "#22C55E"
  gold = "#F59E0B"

func htmlEscape(value: string): string =
  value.replace("&", "&amp;")
    .replace("<", "&lt;")
    .replace(">", "&gt;")
    .replace("\"", "&quot;")

func previewSchemaKey(selected: ElementRef): string =
  func ownerPrefix(key, property: string): string =
    result = key
    let suffix = "." & property
    while result.endsWith(suffix):
      result = result[0 ..< result.len - suffix.len]
  for prop in selected.properties:
    if prop.name == "padding" and prop.schemaKey.len > 0:
      return ownerPrefix(prop.schemaKey, prop.name)
  if selected.schemaKey.len > 0:
    return ownerPrefix(selected.schemaKey, "padding")
  ""

func previewPadding(selected: ElementRef): string =
  for prop in selected.properties:
    if prop.name == "padding" and prop.value.len > 0:
      return prop.value
  "18px"

func componentEditPreviewDocument(preview: ProjectPreview;
    selected: ElementRef): string =
  if preview.documentHtml.len > 0:
    return preview.documentHtml
  if preview.bodyText.len == 0:
    return ""
  let metadata = preview.metadata
  let title =
    if preview.title.len > 0: preview.title
    else: preview.story.group & " / " & preview.story.name
  let source =
    if metadata.sourceFile.len > 0:
      metadata.sourceFile & ":" & $max(metadata.sourceLine, 1)
    else:
      "preview:" & preview.story.group & ":" & preview.story.name
  let schemaKey = previewSchemaKey(selected)
  let padding = previewPadding(selected)
  """
<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#F8FAFC;color:#111827;font:14px/1.5 system-ui,sans-serif">
    <article data-testid="component-edit-preview" data-isonim-src="$1" data-isonim-schema-key="$2" style="max-width:420px;border:1px solid #CBD5E1;border-radius:8px;background:white;padding:$3;box-shadow:0 8px 24px rgba(15,23,42,.12)">
      <h1 style="margin:0 0 8px;font-size:20px;line-height:1.2">$4</h1>
      <p style="margin:0;color:#475569">$5</p>
    </article>
  </body>
</html>
""" % [source.htmlEscape, schemaKey.htmlEscape, padding.htmlEscape,
    title.htmlEscape, preview.bodyText.htmlEscape]

type
  StyleClipboard = ref object
    property: string
    value: string

proc bindRightPanelWidth[R, E](r: R; node: E; vm: EditorVM) =
  createRenderEffect proc() =
    let width = $vm.rightPanelWidth.val & "px"
    r.setStyle(node, "width", width)
    r.setStyle(node, "flex-basis", width)
    r.setStyle(node, "min-width", "260px")
    r.setStyle(node, "max-width", "520px")
    r.setAttribute(node, "data-right-panel-width", $vm.rightPanelWidth.val)

proc rememberPanelFocus(vm: EditorVM; id: string): proc() =
  let captured = id
  result = proc() =
    vm.inspector.rememberInspectorFocus(captured)

proc restoreInspectorFocus[R, E](r: R; root: E; vm: EditorVM) =
  when defined(js):
    {.emit: ["""
      (function () {
        const root = """, root, """;
        const id = """, vm.inspector.focusedControlId.val,
        """;
        const toString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const focusId = toString(id);
        if (!root || !focusId) return;
        const target = root.querySelector('[data-isonim-focus-id="' +
          CSS.escape(focusId) + '"]');
        if (target && document.activeElement !== target) {
          setTimeout(() => target.focus({ preventScroll: true }), 0);
        }
      })();
    """].}
  else:
    discard r
    discard root
    discard vm

proc editablePreviewDocument*(documentHtml: string;
    metadata: StoryRenderMetadata; mode: EditMode): string =
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
    pointer-events: auto;
    cursor: nwse-resize;
  }
  #isonim-editor-selection-handles > span[data-handle="spacing"] {
    width: 10px;
    height: 10px;
    border-radius: 5px;
    background: #22C55E;
    cursor: ns-resize;
  }
  .isonim-editor-layout-guide {
    position: fixed;
    z-index: 2147483645;
    pointer-events: none;
    font: 10px/1.2 ui-monospace, SFMono-Regular, Menlo, monospace;
    color: #DBEAFE;
  }
  #isonim-editor-gap-overlay {
    border: 1px dashed rgba(34,197,94,.85);
    background: rgba(34,197,94,.14);
  }
  #isonim-editor-snap-lines {
    border-top: 1px solid rgba(245,158,11,.9);
    border-left: 1px solid rgba(245,158,11,.9);
  }
  #isonim-editor-spacing-measure {
    padding: 2px 5px;
    border-radius: 3px;
    background: rgba(15,23,42,.92);
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
  #isonim-editor-context-menu {
    position: fixed;
    z-index: 2147483647;
    min-width: 186px;
    padding: 5px;
    border: 1px solid #334155;
    border-radius: 6px;
    background: rgba(15,23,42,.98);
    box-shadow: 0 16px 40px rgba(15,23,42,.35);
    color: #E2E8F0;
    font: 12px/1.35 system-ui, sans-serif;
  }
  #isonim-editor-context-menu button {
    display: block;
    width: 100%;
    padding: 5px 7px;
    border: 0;
    border-radius: 4px;
    background: transparent;
    color: inherit;
    text-align: left;
    font: inherit;
    cursor: pointer;
  }
  #isonim-editor-context-menu button:hover,
  #isonim-editor-context-menu button:focus {
    background: rgba(59,130,246,.24);
    outline: none;
  }
</style>
<script>
(function () {
  const fallbackSource = "__ISONIM_SOURCE__";
  const fallbackLine = "__ISONIM_LINE__";
  const editorMode = "__ISONIM_MODE__";
  const editorIds = new Set([
    'isonim-editor-hover-label',
    'isonim-editor-selection-handles',
    'isonim-editor-selection-breadcrumb',
    'isonim-editor-gap-overlay',
    'isonim-editor-snap-lines',
    'isonim-editor-spacing-measure',
    'isonim-editor-context-menu',
    'isonim-editor-comment-popup'
  ]);
  let lastClick = { x: -10000, y: -10000, index: 0, at: 0 };
  let styleClipboard = null;
  function isElement(node) {
    return node && node.nodeType === 1;
  }
  function isSelectable(el) {
    if (!isElement(el)) return false;
    if (el === document.documentElement || el === document.body) return false;
    if (editorIds.has(el.id)) return false;
    if (el.closest && el.closest('#isonim-editor-hover-label, #isonim-editor-selection-handles, #isonim-editor-selection-breadcrumb, #isonim-editor-comment-popup')) return false;
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
  function sourceKeyFor(el) {
    const source = parseSource(el.getAttribute('data-isonim-src'));
    const tag = el.tagName.toLowerCase();
    const testId = el.getAttribute('data-testid') || '';
    const cls = String(el.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2).join('.');
    const owned = testId ? 'testid:' + testId : (cls ? 'class:' + cls : 'tag:' + tag);
    return source.file + ':' + source.line + ':' + owned;
  }
  function identityFor(el) {
    if (!isElement(el)) return '';
    const existing = el.getAttribute('data-isonim-element-id');
    if (existing) return existing;
    const id = sourceKeyFor(el) + ':' + cssPath(el);
    el.setAttribute('data-isonim-element-id', id);
    return id;
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
  function layerTree(selected) {
    const nodes = Array.from(document.querySelectorAll('body *')).filter(isSelectable);
    const nodeSet = new Set(nodes);
    return nodes.map((node) => {
      const id = identityFor(node);
      let parent = node.parentElement;
      while (parent && !nodeSet.has(parent)) parent = parent.parentElement;
      const directChildren = Array.from(node.children || []).filter((child) => isSelectable(child));
      const source = parseSource(node.getAttribute('data-isonim-src'));
      const label = stableSelector(node);
      return {
        id: id,
        parentId: parent ? identityFor(parent) : '',
        label: label,
        tag: node.tagName.toLowerCase(),
        sourceKey: sourceKeyFor(node),
      schemaKey: node.getAttribute('data-isonim-schema-key') ||
        ('dom.' + (node.getAttribute('data-testid') || node.tagName.toLowerCase())),
        domPath: cssPath(node),
        sourceFile: source.file,
        sourceLine: Number(source.line) || 0,
        depth: ancestorStack(node).length - 1,
        childCount: directChildren.length,
        expanded: true,
        selected: selected === node,
        hovered: node.hasAttribute('data-isonim-hovered'),
        hidden: false,
        locked: false
      };
    });
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
      ['nw','ne','se','sw','spacing'].forEach((name) => {
        const handle = document.createElement('span');
        handle.dataset.handle = name;
        box.appendChild(handle);
      });
      document.body.appendChild(box);
      box.addEventListener('pointerdown', function (event) {
        const handle = event.target && event.target.dataset ? event.target.dataset.handle : '';
        const selected = window.__isonimSelectedElement;
        if (!handle || !selected) return;
        const rect = selected.getBoundingClientRect();
        const startX = event.clientX;
        const startY = event.clientY;
        const startWidth = rect.width;
        const style = window.getComputedStyle(selected);
        const spacingProperty =
          (style.display === 'flex' || style.display === 'grid' || style.gap !== 'normal')
            ? 'gap'
            : 'padding';
        const startSpacing = parseFloat(
          spacingProperty === 'gap'
            ? (style.gap === 'normal' ? '0' : style.gap)
            : style.paddingTop
        ) || 0;
        const source = parseSource(selected.getAttribute('data-isonim-src'));
        function move(moveEvent) {
          let property = 'width';
          let next = Math.max(24, Math.round(startWidth + moveEvent.clientX - startX)) + 'px';
          if (handle === 'spacing') {
            property = spacingProperty;
            next = Math.max(0, Math.round(startSpacing + moveEvent.clientY - startY)) + 'px';
          }
          selected.style.setProperty(property, next);
          selected.setAttribute(handle === 'spacing'
            ? 'data-isonim-spacing-adjusted'
            : 'data-isonim-layout-resized', 'true');
          placeHandles(selected);
          parent.dispatchEvent(new CustomEvent('isonim-preview-direct-manipulation', {
            detail: {
              kind: handle === 'spacing' ? 'spacing' : 'resize',
              property: property,
              value: next,
              sourceFile: source.file,
              sourceLine: source.line,
              handle: handle,
              sourceKey: sourceKeyFor(selected),
              measurement: property + '=' + next
            }
          }));
          moveEvent.preventDefault();
        }
        function stop() {
          window.removeEventListener('pointermove', move, true);
          window.removeEventListener('pointerup', stop, true);
        }
        window.addEventListener('pointermove', move, true);
        window.addEventListener('pointerup', stop, true);
        event.preventDefault();
      });
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
  function ensureLayoutGuide(id) {
    let guide = document.getElementById(id);
    if (!guide) {
      guide = document.createElement('div');
      guide.id = id;
      guide.className = 'isonim-editor-layout-guide';
      document.body.appendChild(guide);
    }
    return guide;
  }
  function placeLayoutGuides(el, rect) {
    const style = window.getComputedStyle(el);
    const gapOverlay = ensureLayoutGuide('isonim-editor-gap-overlay');
    gapOverlay.setAttribute('aria-label', 'Canvas gap overlay');
    gapOverlay.dataset.layoutGuide = 'gap-overlay';
    gapOverlay.style.left = (rect.right + 8) + 'px';
    gapOverlay.style.top = rect.top + 'px';
    gapOverlay.style.width = Math.max(12, parseFloat(style.columnGap || style.gap || '0') || 12) + 'px';
    gapOverlay.style.height = Math.max(18, Math.min(rect.height, 64)) + 'px';
    gapOverlay.textContent = (style.gap && style.gap !== 'normal' ? style.gap : 'gap');

    const snap = ensureLayoutGuide('isonim-editor-snap-lines');
    snap.setAttribute('aria-label', 'Canvas snap lines');
    snap.dataset.layoutGuide = 'snap-lines';
    snap.style.left = rect.left + 'px';
    snap.style.top = rect.top + 'px';
    snap.style.width = Math.max(1, rect.width) + 'px';
    snap.style.height = Math.max(1, rect.height) + 'px';

    const measure = ensureLayoutGuide('isonim-editor-spacing-measure');
    measure.setAttribute('aria-label', 'Canvas spacing measurement');
    measure.dataset.layoutGuide = 'spacing-measurement';
    measure.style.left = Math.max(6, rect.left) + 'px';
    measure.style.top = Math.max(6, rect.top - 22) + 'px';
    measure.textContent = Math.round(rect.width) + ' x ' + Math.round(rect.height);
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
    box.querySelector('[data-handle="spacing"]').style.cssText = 'left:calc(50% - 5px);bottom:-18px';
    box.querySelector('[data-handle="se"]').setAttribute('aria-label', 'Resize selected element');
    box.querySelector('[data-handle="se"]').dataset.layoutHandle = 'resize';
    box.querySelector('[data-handle="spacing"]').setAttribute('aria-label', 'Adjust selected spacing');
    box.querySelector('[data-handle="spacing"]').dataset.layoutHandle = 'spacing';
    placeLayoutGuides(el, rect);
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
    const stackIds = ancestorStack(el).reverse().map(identityFor);
    const elementId = identityFor(el);
    const schemaKey = el.getAttribute('data-isonim-schema-key') ||
      ('dom.' + (el.getAttribute('data-testid') || el.tagName.toLowerCase()));
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-selected', {
      detail: {
        elementId: elementId,
        sourceKey: sourceKeyFor(el),
        schemaKey: schemaKey,
        tag: el.tagName.toLowerCase(),
        testId: el.getAttribute('data-testid') || '',
        className: el.getAttribute('class') || '',
        role: el.getAttribute('role') || '',
        elementPath: cssPath(el),
        ancestry: stack.join(' > '),
        ancestorIds: stackIds.join(' > '),
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
        rectHeight: String(Math.round(rect.height)),
        textContent: String(el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 240),
        layerTree: JSON.stringify(layerTree(el))
      }
    }));
  }
  function firstEditableStyle(el) {
    const style = window.getComputedStyle(el);
    const candidates = ['padding', 'gap', 'width', 'height', 'color', 'background-color'];
    for (const property of candidates) {
      const value = style.getPropertyValue(property);
      if (value && value !== 'normal' && value !== 'auto' && value !== 'rgba(0, 0, 0, 0)') {
        return { property, value };
      }
    }
    return { property: 'padding', value: '0px' };
  }
  function dispatchContextCommand(command, extra) {
    const selected = window.__isonimSelectedElement;
    if (!selected) return;
    const style = firstEditableStyle(selected);
    const detail = Object.assign({
      kind: 'context',
      command: command,
      property: style.property,
      value: style.value,
      oldValue: style.value,
      sourceKey: sourceKeyFor(selected),
      measurement: stableSelector(selected)
    }, extra || {});
    parent.dispatchEvent(new CustomEvent('isonim-preview-direct-manipulation', {
      detail: detail
    }));
  }
  function showContextMenu(event, el) {
    const existing = document.getElementById('isonim-editor-context-menu');
    if (existing) existing.remove();
    const menu = document.createElement('div');
    menu.id = 'isonim-editor-context-menu';
    menu.setAttribute('role', 'menu');
    menu.setAttribute('aria-label', 'Canvas selection context menu');
    const commands = [
      ['copy-styles', 'Copy styles'],
      ['paste-styles', 'Paste styles'],
      ['reset', 'Reset'],
      ['detach', 'Detach style'],
      ['promote', 'Promote style'],
      ['create-variant', 'Create variant'],
      ['wrap', 'Wrap selection'],
      ['duplicate', 'Duplicate'],
      ['delete', 'Delete'],
      ['open-source', 'Open source'],
      ['ask-ai', 'Ask AI about selection']
    ];
    commands.forEach(([command, label]) => {
      const button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'menuitem');
      button.textContent = label;
      button.addEventListener('click', () => {
        if (command === 'copy-styles') {
          styleClipboard = firstEditableStyle(el);
          dispatchContextCommand(command, styleClipboard);
        } else if (command === 'paste-styles') {
          const copied = styleClipboard || firstEditableStyle(el);
          if (copied) {
            el.style.setProperty(copied.property, copied.value);
            dispatchContextCommand(command, copied);
          }
        } else if (command === 'reset') {
          const reset = firstEditableStyle(el);
          const value = reset.property === 'color' ? 'inherit' : '0px';
          el.style.setProperty(reset.property, value);
          dispatchContextCommand(command, { property: reset.property, value: value, oldValue: reset.value });
        } else {
          dispatchContextCommand(command);
        }
        menu.remove();
      });
      menu.appendChild(button);
    });
    menu.style.left = Math.min(event.clientX, window.innerWidth - 206) + 'px';
    menu.style.top = Math.min(event.clientY, window.innerHeight - 316) + 'px';
    document.body.appendChild(menu);
    const first = menu.querySelector('button');
    if (first) first.focus();
  }
  function clearSelection() {
    document.querySelectorAll('[data-isonim-selected="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-selected');
    });
    const handles = document.getElementById('isonim-editor-selection-handles');
    const crumb = document.getElementById('isonim-editor-selection-breadcrumb');
    const gap = document.getElementById('isonim-editor-gap-overlay');
    const snap = document.getElementById('isonim-editor-snap-lines');
    const measure = document.getElementById('isonim-editor-spacing-measure');
    if (handles) handles.remove();
    if (crumb) crumb.hidden = true;
    if (gap) gap.remove();
    if (snap) snap.remove();
    if (measure) measure.remove();
    window.__isonimSelectedElement = null;
    parent.dispatchEvent(new CustomEvent('isonim-preview-selection-cleared'));
  }
  function showCommentPopup(el) {
    const existing = document.getElementById('isonim-editor-comment-popup');
    if (existing) existing.remove();
    const rect = el.getBoundingClientRect();
    const popup = document.createElement('div');
    popup.id = 'isonim-editor-comment-popup';
    popup.style.cssText =
      'position:fixed;z-index:2147483647;left:' + Math.max(8, Math.min(rect.left, window.innerWidth - 300)) +
      'px;top:' + Math.min(window.innerHeight - 150, rect.bottom + 10) +
      'px;width:280px;padding:8px;border:1px solid #334155;border-radius:6px;background:#111827;box-shadow:0 16px 40px rgba(15,23,42,.35);font:12px/1.4 system-ui,sans-serif;color:#E2E8F0';
    const label = document.createElement('div');
    label.textContent = 'Comment on ' + stableSelector(el);
    label.style.cssText = 'font-weight:700;margin-bottom:6px;color:#CBD5E1';
    const input = document.createElement('textarea');
    input.setAttribute('aria-label', 'Comment on selected element');
    input.placeholder = 'Leave a note for the AI assistant...';
    input.style.cssText = 'box-sizing:border-box;width:100%;height:68px;resize:vertical;border:1px solid #334155;border-radius:5px;background:#0F172A;color:#F8FAFC;padding:6px;outline:none';
    const actions = document.createElement('div');
    actions.style.cssText = 'display:flex;justify-content:flex-end;gap:6px;margin-top:7px';
    const dismiss = document.createElement('button');
    dismiss.type = 'button';
    dismiss.textContent = 'Dismiss';
    dismiss.style.cssText = 'border:1px solid #334155;border-radius:4px;background:#1E293B;color:#CBD5E1;padding:4px 7px';
    const add = document.createElement('button');
    add.type = 'button';
    add.textContent = 'Add';
    add.style.cssText = 'border:1px solid #3B82F6;border-radius:4px;background:#3B82F6;color:white;padding:4px 9px;font-weight:700';
    dismiss.addEventListener('click', function () { popup.remove(); });
    add.addEventListener('click', function () {
      const text = input.value.trim();
      if (!text) return;
      const target = ancestorStack(el).reverse().map(stableSelector).join(' > ') || stableSelector(el);
      const marker = document.createElement('button');
      marker.type = 'button';
      marker.setAttribute('aria-label', 'Design review comment marker');
      marker.setAttribute('data-isonim-review-comment', 'open');
      marker.textContent = String(document.querySelectorAll('[data-isonim-review-comment]').length + 1);
      marker.style.cssText =
        'position:fixed;z-index:2147483646;left:' + Math.max(8, rect.left - 8) +
        'px;top:' + Math.max(8, rect.top - 8) +
        'px;width:20px;height:20px;border-radius:10px;border:1px solid #F59E0B;background:#111827;color:#FDE68A;font:700 11px/18px system-ui,sans-serif;box-shadow:0 8px 22px rgba(15,23,42,.35)';
      marker.title = text;
      document.body.appendChild(marker);
      parent.dispatchEvent(new CustomEvent('isonim-preview-comment-added', {
        detail: {
          selector: stableSelector(el),
          ancestry: target,
          text: text,
          domSnapshot: el.outerHTML ? String(el.outerHTML).slice(0, 2000) : '',
          screenshotRef: 'viewport:' + window.innerWidth + 'x' + window.innerHeight + ':' + stableSelector(el)
        }
      }));
      popup.remove();
    });
    actions.appendChild(dismiss);
    actions.appendChild(add);
    popup.appendChild(label);
    popup.appendChild(input);
    popup.appendChild(actions);
    document.body.appendChild(popup);
    input.focus();
  }
  document.addEventListener('click', function (event) {
    if (editorMode === 'view') return;
    if (event.target && event.target.closest && event.target.closest('#isonim-editor-comment-popup, #isonim-editor-context-menu')) return;
    event.preventDefault();
    event.stopPropagation();
    const selected = preferredElement(event);
    selectElement(selected);
    if (editorMode === 'comment' && selected) showCommentPopup(selected);
  }, true);
  document.addEventListener('contextmenu', function (event) {
    if (editorMode === 'view') return;
    const selected = ancestorStack(event.target)[0];
    if (!selected) return;
    event.preventDefault();
    event.stopPropagation();
    selectElement(selected);
    showContextMenu(event, selected);
  }, true);
  document.addEventListener('dblclick', function (event) {
    if (editorMode === 'view') return;
    const selected = ancestorStack(event.target)[0];
    if (!selected) return;
    event.preventDefault();
    event.stopPropagation();
    // M-EVP-8: if the resolved element (or one of its ancestors) carries
    // the `data-isonim-vector-symbol` marker, forward the dblclick to
    // the host editor so it opens the vector editor instead of entering
    // inline text editing.
    var vectorEl = selected;
    while (vectorEl && vectorEl.getAttribute &&
        !vectorEl.getAttribute('data-isonim-vector-symbol')) {
      vectorEl = vectorEl.parentElement;
    }
    if (vectorEl && vectorEl.getAttribute) {
      var symbolName = vectorEl.getAttribute('data-isonim-vector-symbol');
      if (symbolName) {
        parent.dispatchEvent(new CustomEvent('isonim-preview-vector-edit', {
          detail: { symbol: symbolName,
                    elementPath: cssPath(vectorEl) }
        }));
        return;
      }
    }
    selectElement(selected);
    const before = String(selected.textContent || '').trim().replace(/\s+/g, ' ');
    selected.setAttribute('contenteditable', 'true');
    selected.setAttribute('data-isonim-inline-editing', 'true');
    selected.focus();
    try {
      const range = document.createRange();
      range.selectNodeContents(selected);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
    } catch (error) {}
    function commit() {
      selected.removeEventListener('blur', commit, true);
      selected.removeEventListener('keydown', keyCommit, true);
      selected.removeAttribute('contenteditable');
      selected.removeAttribute('data-isonim-inline-editing');
      const next = String(selected.textContent || '').trim().replace(/\s+/g, ' ');
      parent.dispatchEvent(new CustomEvent('isonim-preview-direct-manipulation', {
        detail: {
          kind: 'inline-text',
          property: 'text',
          value: next,
          oldValue: before,
          sourceKey: sourceKeyFor(selected),
          measurement: 'text=' + next.length
        }
      }));
    }
    function keyCommit(keyEvent) {
      if (keyEvent.key === 'Enter') {
        keyEvent.preventDefault();
        selected.blur();
      }
      if (keyEvent.key === 'Escape') {
        selected.textContent = before;
        selected.blur();
      }
    }
    selected.addEventListener('blur', commit, true);
    selected.addEventListener('keydown', keyCommit, true);
  }, true);
  document.addEventListener('pointerdown', function (event) {
    if (editorMode === 'view' || event.button !== 0) return;
    const selected = window.__isonimSelectedElement;
    if (!selected || !selected.contains(event.target)) return;
    const parentEl = selected.parentElement;
    if (!parentEl || parentEl.children.length < 2) return;
    const startX = event.clientX;
    const startY = event.clientY;
    const source = sourceKeyFor(selected);
    let dragging = false;
    function move(moveEvent) {
      if (Math.abs(moveEvent.clientX - startX) + Math.abs(moveEvent.clientY - startY) < 10) return;
      dragging = true;
      const siblings = Array.from(parentEl.children).filter(isSelectable);
      const index = siblings.indexOf(selected);
      const toIndex = moveEvent.clientY > startY ? Math.min(siblings.length - 1, index + 1) : Math.max(0, index - 1);
      selected.style.order = String(toIndex);
      parent.dispatchEvent(new CustomEvent('isonim-preview-direct-manipulation', {
        detail: {
          kind: 'reorder',
          property: 'order',
          value: String(toIndex),
          oldValue: String(index),
          fromIndex: index,
          toIndex: toIndex,
          sourceKey: source,
          measurement: 'order=' + toIndex
        }
      }));
      stop();
      moveEvent.preventDefault();
    }
    function stop() {
      window.removeEventListener('pointermove', move, true);
      window.removeEventListener('pointerup', stop, true);
    }
    window.addEventListener('pointermove', move, true);
    window.addEventListener('pointerup', stop, true);
  }, true);
  document.addEventListener('keydown', function (event) {
    if (editorMode === 'view') return;
    if (event.target && event.target.closest && event.target.closest('#isonim-editor-comment-popup')) return;
    const selected = window.__isonimSelectedElement;
    if (event.key === 'Escape') {
      event.preventDefault();
      clearSelection();
      return;
    }
    if (!selected || !['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    const rows = layerTree(selected);
    const selectedId = identityFor(selected);
    const index = rows.findIndex((row) => row.id === selectedId);
    let targetId = '';
    if (event.key === 'ArrowUp' && index > 0) targetId = rows[index - 1].id;
    if (event.key === 'ArrowDown' && index >= 0 && index + 1 < rows.length) targetId = rows[index + 1].id;
    if (event.key === 'ArrowLeft' && index >= 0) targetId = rows[index].parentId;
    if (event.key === 'ArrowRight' && index >= 0) {
      const child = rows.find((row) => row.parentId === selectedId);
      if (child) targetId = child.id;
    }
    if (!targetId) return;
    const target = document.querySelector('[data-isonim-element-id="' + CSS.escape(targetId) + '"]');
    if (target) {
      event.preventDefault();
      selectElement(target);
    }
  }, true);
  document.addEventListener('mousemove', function (event) {
    if (editorMode === 'view') return;
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
  parent.addEventListener('isonim-select-preview-ancestor', function (event) {
    if (editorMode === 'view') return;
    const selected = window.__isonimSelectedElement;
    const index = Number(event.detail && event.detail.index);
    if (!selected || Number.isNaN(index)) return;
    const stack = ancestorStack(selected).reverse();
    const target = stack[Math.max(0, Math.min(index, stack.length - 1))];
    if (target) selectElement(target);
  });
  parent.addEventListener('isonim-select-preview-element-id', function (event) {
    if (editorMode === 'view') return;
    const id = String(event.detail && event.detail.id || '');
    if (!id) return;
    layerTree(window.__isonimSelectedElement || document.body);
    const target = document.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (target) selectElement(target);
  });
  parent.addEventListener('isonim-hover-preview-element-id', function (event) {
    if (editorMode === 'view') return;
    const id = String(event.detail && event.detail.id || '');
    document.querySelectorAll('[data-isonim-hovered="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-hovered');
    });
    if (!id) return;
    layerTree(window.__isonimSelectedElement || document.body);
    const target = document.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (target) target.setAttribute('data-isonim-hovered', 'true');
  });
  window.__isonimRestoreSelection = function (id) {
    const selectedId = String(id || '');
    if (!selectedId) return;
    layerTree(window.__isonimSelectedElement || document.body);
    const target = document.querySelector('[data-isonim-element-id="' + CSS.escape(selectedId) + '"]');
    if (target) selectElement(target);
  };
  setTimeout(function () {
    try {
      window.__isonimRestoreSelection(parent.__isonimPendingPreviewSelectionId || '');
    } catch (error) {}
  }, 0);
})();
</script>
"""
  let injected = bridge
    .replace("__ISONIM_SOURCE__", metadata.sourceFile.jsString)
    .replace("__ISONIM_LINE__", $max(metadata.sourceLine, 1))
    .replace("__ISONIM_MODE__", (case mode
      of emSpec: "spec"
      of emView: "view"
      of emComment: "comment"
      of emEdit: "edit"))
  if "</body>" in documentHtml:
    documentHtml.replace("</body>", injected & "</body>")
  else:
    documentHtml & injected

proc applyInspectorValue(vm: EditorVM; propName, value: string;
    scope = pesLocal)

proc installPreviewSelectionBridge[R, E](r: R; frame: E; vm: EditorVM) =
  when defined(js):
    let selectFromBrowser = proc(elementId, sourceKey, schemaKey, tag, testId,
        className, role, elementPath, ancestry, ancestorIds, sourceFile,
        sourceLine, display, position, backgroundColor,
        color, padding, margin, width, height, borderRadius, borderWidth,
        borderStyle, borderColor, fontSize, fontWeight, lineHeight, boxShadow,
        opacity, rectWidth, rectHeight, textContent, layerTreeJson: cstring) =
      let line =
        try: parseInt($sourceLine)
        except ValueError: 0
      let element = previewDomElementRef(
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
        $rectHeight,
        $textContent,
        $elementId,
        $sourceKey,
        $schemaKey,
        $ancestorIds,
        $layerTreeJson)
      discard vm.selectInspectorElement(element)
      vm.inspector.setSelectionTree(previewDomLayerRows($layerTreeJson,
        element.id, vm.inspector.hoveredElementId.val,
        vm.inspector.expandedLayerIds.val))
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
            d.elementId || '', d.sourceKey || '', d.schemaKey || '',
            d.tag || '', d.testId || '', d.className || '', d.role || '',
            d.elementPath || '', d.ancestry || '', d.ancestorIds || '',
            d.sourceFile || '',
            String(d.sourceLine || ''), d.display || '', d.position || '',
            d.backgroundColor || '', d.color || '', d.padding || '',
            d.margin || '', d.width || '', d.height || '',
            d.borderRadius || '', d.borderWidth || '', d.borderStyle || '',
            d.borderColor || '', d.fontSize || '', d.fontWeight || '',
            d.lineHeight || '', d.boxShadow || '', d.opacity || '',
            d.rectWidth || '', d.rectHeight || '', d.textContent || '',
            d.layerTree || ''
          );
        });
      }
    """].}

    let clearFromBrowser = proc() =
      vm.clearInspectorSelection()
    {.emit: ["""
      if (!window.__isonimPreviewSelectionClearBridgeInstalled) {
        window.__isonimPreviewSelectionClearBridgeInstalled = true;
        window.addEventListener('isonim-preview-selection-cleared', function () {
          """, clearFromBrowser, """();
        });
      }
    """].}

    let directManipulationFromBrowser = proc(kind, propName, value, oldValue,
        handle, command, sourceKey, measurement: cstring; fromIndex,
        toIndex: int) =
      let opKind =
        case ($kind)
        of "resize": dcokResize
        of "spacing": dcokSpacing
        of "reorder": dcokReorder
        of "inline-text": dcokInlineText
        else: dcokContextCommand
      let contextCommand =
        case ($command)
        of "copy-styles": dcccCopyStyles
        of "paste-styles": dcccPasteStyles
        of "reset": dcccReset
        of "detach": dcccDetach
        of "promote": dcccPromote
        of "create-variant": dcccCreateVariant
        of "wrap": dcccWrap
        of "duplicate": dcccDuplicate
        of "delete": dcccDelete
        of "open-source": dcccOpenSource
        of "ask-ai": dcccAskAi
        else: dcccCopyStyles
      discard vm.applyDirectCanvasOperation(DirectCanvasOperation(
        kind: opKind,
        property: $propName,
        value: $value,
        oldValue: $oldValue,
        handle: $handle,
        command: contextCommand,
        sourceKey: $sourceKey,
        fromIndex: fromIndex,
        toIndex: toIndex,
        measurement: $measurement))
    {.emit: ["""
      if (!window.__isonimPreviewDirectManipulationBridgeInstalled) {
        window.__isonimPreviewDirectManipulationBridgeInstalled = true;
        window.addEventListener('isonim-preview-direct-manipulation', function (event) {
          const d = event.detail || {};
          """, directManipulationFromBrowser,
        """(
            d.kind || '', d.property || '', d.value || '', d.oldValue || '',
            d.handle || '', d.command || '', d.sourceKey || '',
            d.measurement || '', Number(d.fromIndex || 0),
            Number(d.toIndex || 0)
          );
        });
      }
    """].}

    let addCommentToPrompt = proc(selector, ancestry, text, domSnapshot,
        screenshotRef: cstring) =
      discard vm.addReviewAnnotation($text, selector = $selector,
        ancestry = $ancestry, domSnapshot = $domSnapshot,
        screenshotRef = $screenshotRef)
    {.emit: ["""
      if (!window.__isonimPreviewCommentBridgeInstalled) {
        window.__isonimPreviewCommentBridgeInstalled = true;
        window.addEventListener('isonim-preview-comment-added', function (event) {
          const d = event.detail || {};
          """, addCommentToPrompt,
        """(d.selector || '', d.ancestry || '', d.text || '', d.domSnapshot || '', d.screenshotRef || '');
        });
      }
    """].}

    # M-EVP-8: bridge for the iframe's vector-symbol dblclick handler.
    let openVectorFromBrowser = proc(symbol, elementPath: cstring) =
      let symName = $symbol
      if symName.len == 0:
        return
      # Resolve the symbol name to a sidebar story. The vector-symbols
      # group exposes one story per symbol — we look up by name.
      for group in vm.sidebar.groups.val:
        if group.kind == skVectorSymbol:
          var idx = 0
          for item in group.items:
            if item.name == symName:
              discard vm.openVectorEditor(StoryRef(
                group: item.group, name: item.name,
                kind: skVectorSymbol, index: idx))
              return
            inc idx
    {.emit: ["""
      if (!window.__isonimPreviewVectorEditBridgeInstalled) {
        window.__isonimPreviewVectorEditBridgeInstalled = true;
        window.addEventListener('isonim-preview-vector-edit', function (event) {
          const d = event.detail || {};
          """, openVectorFromBrowser,
        """(d.symbol || '', d.elementPath || '');
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
  isEffects, isTransitions, isFilters, isState, isSource
]

const richSectionLabels = [
  "Layout", "Size", "Space", "Position", "Fill", "Stroke", "Type",
  "Effects", "Transitions", "Filters", "State", "Source"
]

func fallbackPropertyValue(element: ElementRef; name,
    fallback: string): string =
  for prop in element.properties:
    if prop.name == name:
      return prop.value
  fallback

func filterSliderBackground(propName, value: string): string =
  ## Render a 0-200% slider track inside the value input on filter rows.
  ## Lets `brightness`, `contrast`, `saturate` read as scrubbers without
  ## changing the input control.
  if propName notin ["brightness", "contrast", "saturate"]:
    return "#0F172A"
  let raw = value.strip()
  var num = 1.0
  try: num = parseFloat(raw)
  except ValueError: discard
  let pct = max(0.0, min(100.0, num * 50.0))
  let pctStr = $int(pct)
  result =
    "linear-gradient(to right, rgba(59, 130, 246, 0.28) 0%, " &
    "rgba(59, 130, 246, 0.28) " & pctStr & "%, " &
    "#0F172A " & pctStr & "%, #0F172A 100%)"

func roundedPxValue(raw: string): string =
  ## Round a numeric CSS value (e.g. "50.8938px") to 1 decimal so the
  ## selection summary doesn't read like raw browser noise. Non-numeric
  ## inputs ("auto", "fit-content", "100%") pass through unchanged.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return raw
  var i = 0
  if i < trimmed.len and trimmed[i] in {'+', '-'}:
    inc i
  let numStart = i
  while i < trimmed.len and trimmed[i] in {'0'..'9', '.'}:
    inc i
  if i == numStart:
    return trimmed
  let suffix = trimmed[i .. ^1].strip()
  let n =
    try: parseFloat(trimmed[0 ..< i])
    except ValueError: return trimmed
  let rounded =
    if abs(n - round(n)) < 0.05: $int(round(n))
    else: fmt"{n:.1f}"
  if suffix.len > 0: rounded & suffix else: rounded

func sectionProperties(section: InspectorSection): seq[(string, string)] =
  case section
  of isLayout:
    @[
      ("display", "block"),
      ("flex-direction", "row"),
      ("flex-wrap", "nowrap"),
      ("justify-content", "flex-start"),
      ("align-items", "stretch"),
      ("align-content", "stretch"),
      ("align-self", "auto"),
      ("gap", "0px"),
      ("order", "0"),
      ("grid-template-columns", "none"),
      ("grid-template-rows", "none"),
      ("grid-template-areas", "none"),
      ("grid-auto-flow", "row"),
      ("grid-column", "auto"),
      ("grid-row", "auto"),
      ("overflow", "visible")
    ]
  of isSize:
    @[
      ("width", "auto"),
      ("height", "auto"),
      ("min-width", "0px"),
      ("min-height", "0px"),
      ("max-width", "none"),
      ("max-height", "none"),
      ("flex-grow", "0"),
      ("flex-shrink", "1"),
      ("flex-basis", "auto"),
      ("aspect-ratio", "auto")
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
      ("margin-right", "0px"),
      ("margin-bottom", "0px"),
      ("margin-left", "0px")
    ]
  of isPosition:
    @[
      ("position", "static"),
      ("top", "auto"),
      ("right", "auto"),
      ("bottom", "auto"),
      ("left", "auto"),
      ("z-index", "auto"),
      ("transform", "none"),
      ("transform-origin", "center")
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
      ("outline-color", "transparent"),
      ("outline-offset", "0px")
    ]
  of isTypography:
    @[
      ("font-size", "16px"),
      ("font-weight", "400"),
      ("line-height", "normal"),
      ("letter-spacing", "0px"),
      ("text-align", "left"),
      ("text-decoration", "none"),
      ("text-transform", "none"),
      ("white-space", "normal"),
      ("text-overflow", "clip")
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
  of isSource:
    @[]
  of isAppearance:
    # Phase C: appearance properties live in the new section-based
    # inspector and are not part of the legacy 12-section property
    # grid. Phase G extracts the real controls — for now,
    # ``sectionProperties`` returns an empty list so the legacy
    # populate path skips the section.
    @[]
  of isSelectionColors:
    @[]
  of isComponentProps:
    @[]
  of isExport:
    @[]

func quickValues(propertyName: string): seq[string] =
  case propertyName
  of "display": @["block", "flex", "grid", "none"]
  of "flex-direction": @["row", "column", "row-reverse", "column-reverse"]
  of "flex-wrap": @["nowrap", "wrap", "wrap-reverse"]
  of "justify-content": @["flex-start", "center", "space-between",
      "space-around", "space-evenly", "flex-end"]
  of "align-items": @["stretch", "center", "flex-start", "flex-end"]
  of "align-content": @["stretch", "center", "space-between", "flex-start"]
  of "align-self": @["auto", "stretch", "center", "flex-start", "flex-end"]
  of "grid-template-columns": @["none", "repeat(2, minmax(0, 1fr))", "240px 1fr"]
  of "grid-template-rows": @["none", "auto", "auto 1fr"]
  of "grid-auto-flow": @["row", "column", "dense", "row dense"]
  of "grid-column": @["auto", "1 / -1", "span 2"]
  of "grid-row": @["auto", "span 2"]
  of "overflow": @["visible", "hidden", "auto", "scroll"]
  of "position": @["static", "relative", "absolute", "sticky"]
  of "border-style": @["solid", "dashed", "dotted", "none"]
  of "font-weight": @["400", "500", "600", "700"]
  of "text-align": @["left", "center", "right", "justify"]
  of "text-decoration": @["none", "underline", "line-through"]
  of "white-space": @["normal", "nowrap", "pre-wrap"]
  of "text-overflow": @["clip", "ellipsis"]
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

func sourceScopeAbbrev(kind: SourceScopeChoiceKind): string =
  case kind
  of sskLocalInstance: "Loc"
  of sskStoryFixture: "Fix"
  of sskComponentSchemaApi: "API"
  of sskSharedClass: "Cls"
  of sskComponentToken: "Tok"
  of sskSemanticToken: "Sem"
  of sskGlobalPrimitiveToken: "Prim"

func sourceScopeRiskLabel(risk: SourceScopeRiskLevel): string =
  case risk
  of ssrNone: "none"
  of ssrLow: "low"
  of ssrMedium: "med"
  of ssrHigh: "high"

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
    "gap", "row-gap", "column-gap", "top", "right", "bottom", "left",
    "z-index", "order", "border-width",
    "border-radius", "font-size", "font-weight", "line-height",
    "letter-spacing", "opacity", "transition-duration", "transition-delay",
    "brightness", "contrast", "saturate", "blur", "flex-grow",
    "flex-shrink", "flex-basis"
  ]

func numericUnit(value: string; fallback = "px"): string =
  ## Extract a numeric unit (px, em, rem, %, fr, …) from a CSS value. Returns
  ## "" when the value isn't numeric — `rgb(...)`, `transparent`, `auto`,
  ## complex strings like `5.6px 10.4px` (we look at the first token only),
  ## etc. — so the unit chip in the inspector can hide for unitless props.
  let text = value.strip()
  if text.len == 0:
    return fallback
  var i = 0
  if i < text.len and text[i] in {'+', '-'}:
    inc i
  let numStart = i
  while i < text.len and (text[i].isDigit or text[i] == '.'):
    inc i
  if i == numStart:
    return ""
  let unitStart = i
  while i < text.len and (text[i].isAlphaAscii or text[i] == '%'):
    inc i
  if i > unitStart:
    return text[unitStart ..< i]
  if text in ["auto", "none", "normal", "inherit"]:
    return ""
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

proc applyInspectorValue(vm: EditorVM; propName, value: string;
    scope = pesLocal) =
  discard vm.editCssProperty(propName, normalizePrimitiveInputValue(propName, value),
    scope, peoInspector)

proc applyLivePreviewStyle[R, E](r: R; frame: E; propName, value: string) =
  when defined(js):
    {.emit: ["""
      (function () {
        let frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) {
          frame = document.querySelector('iframe[data-component-edit-frame="true"]');
        }
        if (!frame || !frame.contentDocument) return;
        const selected = Array.from(frame.contentDocument.querySelectorAll('[data-isonim-selected="true"]'));
        if (frame.contentWindow && frame.contentWindow.__isonimSelectedElement) {
          selected.push(frame.contentWindow.__isonimSelectedElement);
        }
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const prop = toJsString(""", propName,
        """);
        const value = toJsString(""", value,
        """);
        selected.forEach((el) => {
          if (!el || !el.style) return;
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
        });
      })();
    """].}

proc revertLivePreviewStyles[R, E](r: R; frame: E) =
  when defined(js):
    {.emit: ["""
      (function () {
        let frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) {
          frame = document.querySelector('iframe[data-component-edit-frame="true"]');
        }
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
        let frame = """, frame,
        """;
        if (!frame || !frame.contentDocument) {
          frame = document.querySelector('iframe[data-component-edit-frame="true"]');
        }
        if (!frame || !frame.contentDocument) return;
        frame.contentDocument.querySelectorAll('[data-isonim-live-edited="true"]').forEach((el) => {
          el.__isonimOriginalInlineStyles = {};
          el.removeAttribute('data-isonim-live-edited');
        });
      })();
    """].}

proc selectPreviewElementById[R, E](r: R; frame: E; id: string) =
  when defined(js):
    {.emit: ["""
      (function () {
      const toJsString = (raw) => Array.isArray(raw)
        ? String.fromCharCode.apply(null, raw)
        : String(raw || '');
      window.dispatchEvent(new CustomEvent('isonim-select-preview-element-id', {
        detail: { id: toJsString(""", id,
        """) }
      }));
      })();
    """].}
  else:
    discard r
    discard frame
    discard id

proc hoverPreviewElementById[R, E](r: R; frame: E; id: string) =
  when defined(js):
    {.emit: ["""
      (function () {
      const toJsString = (raw) => Array.isArray(raw)
        ? String.fromCharCode.apply(null, raw)
        : String(raw || '');
      window.dispatchEvent(new CustomEvent('isonim-hover-preview-element-id', {
        detail: { id: toJsString(""", id,
        """) }
      }));
      })();
    """].}
  else:
    discard r
    discard frame
    discard id

proc restorePreviewSelection[R, E](r: R; frame: E; id: string) =
  when defined(js):
    {.emit: ["""
      (function () {
        const frame = """, frame,
        """;
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const selectedId = toJsString(""", id,
        """);
        if (!frame || !selectedId) return;
        window.__isonimPendingPreviewSelectionId = selectedId;
        const restore = () => {
          try {
            if (frame.contentWindow && frame.contentWindow.__isonimRestoreSelection) {
              frame.contentWindow.__isonimRestoreSelection(selectedId);
            }
          } catch (error) {}
        };
        frame.addEventListener('load', () => setTimeout(restore, 0), { once: true });
        setTimeout(restore, 0);
      })();
    """].}
  else:
    discard r
    discard frame
    discard id

proc applyCssValue[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string; commitSource = true; scope = pesLocal) =
  if commitSource:
    vm.applyInspectorValue(propName, value, scope)
  r.applyLivePreviewStyle(frame, propName, value)

proc applyResponsiveCssValue[R, E](r: R; vm: EditorVM; frame: E; modeKey,
    propName, value: string) =
  let planned = vm.applyResponsiveLayoutOverride(modeKey, propName, value)
  if not planned.ok:
    vm.applyInspectorValue(propName, value)
  if modeKey == layoutModeKey(vm.viewport.val):
    r.applyLivePreviewStyle(frame, propName, value)

proc applyRawCss[R, E](r: R; vm: EditorVM; frame: E; raw: string) =
  for (propName, value) in parseRawCssLines(raw):
    r.applyCssValue(vm, frame, propName, value)

proc attachLiveInputPreview[R, E](r: R; inputNode, frame: E; propName: string) =
  when defined(js):
    {.emit: ["""
      (function () {
        const input = """, inputNode, """;
        const frame = """, frame,
        """;
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const prop = toJsString(""", propName,
        """);
        if (!input || input.__isonimLivePreviewInstalled) return;
        input.__isonimLivePreviewInstalled = true;
        input.addEventListener('input', () => {
          try {
            if (!frame || !frame.contentDocument) return;
            const selected = Array.from(frame.contentDocument.querySelectorAll('[data-isonim-selected="true"]'));
            if (frame.contentWindow && frame.contentWindow.__isonimSelectedElement) {
              selected.push(frame.contentWindow.__isonimSelectedElement);
            }
            const value = input.value || '';
            selected.forEach((el) => {
              if (!el || !el.style) return;
              if (!el.__isonimOriginalInlineStyles) el.__isonimOriginalInlineStyles = {};
              if (!Object.prototype.hasOwnProperty.call(el.__isonimOriginalInlineStyles, prop)) {
                el.__isonimOriginalInlineStyles[prop] = {
                  value: el.style.getPropertyValue(prop),
                  priority: el.style.getPropertyPriority(prop)
                };
              }
              el.setAttribute('data-isonim-live-edited', 'true');
              if (value.length === 0) el.style.removeProperty(prop);
              else el.style.setProperty(prop, value);
            });
          } catch (error) {}
        });
      })();
    """].}
  else:
    discard r
    discard inputNode
    discard frame
    discard propName

proc attachPrimitiveInputKeys[R, E](r: R; inputNode, frame: E;
    propName: string) =
  when defined(js):
    {.emit: ["""
      (function () {
        const input = """, inputNode,
        """;
        if (!input || input.__isonimPrimitiveKeysInstalled) return;
        input.__isonimPrimitiveKeysInstalled = true;
        function split(raw) {
          const text = String(raw || '').trim();
          const match = text.match(/^([+-]?(?:\d+\.?\d*|\.\d+))(.*)$/);
          if (!match) return null;
          return { number: Number(match[1]), unit: match[2] || 'px' };
        }
        function format(number, unit) {
          const rounded = Math.abs(number - Math.round(number)) < 0.0001
            ? String(Math.round(number))
            : String(Math.round(number * 100) / 100);
          return rounded + unit;
        }
        input.addEventListener('focus', () => {
          try { input.select(); } catch (error) {}
        });
        input.addEventListener('keydown', (event) => {
          if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return;
          const parsed = split(input.value);
          if (!parsed) return;
          const base = event.shiftKey ? 10 : (event.altKey ? 0.1 : 1);
          const delta = event.key === 'ArrowUp' ? base : -base;
          input.value = format(parsed.number + delta, parsed.unit);
          input.dispatchEvent(new Event('input', { bubbles: true }));
          input.dispatchEvent(new Event('change', { bubbles: true }));
          event.preventDefault();
        });
      })();
    """].}
  else:
    discard r
    discard inputNode
    discard frame
    discard propName

proc inspectorLiveValueHandler[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): proc() =
  let capturedProp = propName
  let capturedValue = value
  result = proc() =
    r.applyCssValue(vm, frame, capturedProp, capturedValue)

proc renderPropertyInput[R, E](r: R; vm: EditorVM; frame: E; prop: PropertyInfo;
    fallback: string): E =
  var labelNode: E
  var inputNode: E
  var resetNode: E
  var unitNode: E
  var moreNode: E
  var scopeNode: E
  var scopeHost: E
  var bindingNode: E
  let propName = prop.name
  let value = prop.value
  let unit = numericUnit(value, "")
  let scopeChoices = vm.sourceScopeChoices(prop)
  var selectedScopeIndex = 0
  var editableScopeCount = 0
  for i in 0 ..< scopeChoices.len:
    if scopeChoices[i].editable:
      inc editableScopeCount
    if scopeChoices[i].kind != sskLocalInstance and scopeChoices[i].editable and
        (prop.sharedCount > 0 or prop.tokenName.len > 0 or prop.schemaKey.len > 0):
      selectedScopeIndex = i
      break
  let selectedScope =
    if scopeChoices.len > 0: scopeChoices[selectedScopeIndex]
    else: SourceScopeChoice(kind: sskLocalInstance, label: "Local instance",
      editable: true)
  let binding = originLabel(prop.origin)
  proc commitScope(kind: SourceScopeChoiceKind) =
    let nextValue = normalizePrimitiveInputValue(propName, r.inputValue(inputNode))
    r.setInputValue(inputNode, nextValue)
    if kind == sskLocalInstance:
      r.applyCssValue(vm, frame, propName, nextValue, scope = pesLocal)
    else:
      discard vm.editSharedDesignProperty(propName, nextValue, kind)
      r.applyLivePreviewStyle(frame, propName, nextValue)
  proc scopeChoiceHandler(kind: SourceScopeChoiceKind; editable: bool): proc() =
    let capturedKind = kind
    let capturedEditable = editable
    result = proc() =
      if capturedEditable:
        commitScope(capturedKind)
  let commit = proc() =
    let nextValue = normalizePrimitiveInputValue(propName, r.inputValue(inputNode))
    r.setInputValue(inputNode, nextValue)
    r.applyCssValue(vm, frame, propName, nextValue)
  let preview = proc() =
    r.applyCssValue(vm, frame, propName, r.inputValue(inputNode),
      commitSource = false)
  var scopeOptions: seq[CompactChoiceOption] = @[]
  var orderedScopeIndexes: seq[int] = @[]
  for preferred in [sskLocalInstance, sskSharedClass]:
    for i in 0 ..< scopeChoices.len:
      if scopeChoices[i].kind == preferred and i notin orderedScopeIndexes:
        orderedScopeIndexes.add i
        break
  if selectedScopeIndex notin orderedScopeIndexes:
    orderedScopeIndexes.add selectedScopeIndex
  for i in 0 ..< scopeChoices.len:
    if i notin orderedScopeIndexes:
      orderedScopeIndexes.add i
  for i in orderedScopeIndexes:
    let choice = scopeChoices[i]
    let kind = choice.kind
    let editable = choice.editable
    let label = choice.label
    let risk = choice.riskLevel.sourceScopeRiskLabel()
    scopeOptions.add CompactChoiceOption(
      label: label & " " & risk,
      shortLabel: kind.sourceScopeAbbrev(),
      ariaLabel: "Apply " & label & " source scope for " & propName,
      selected: i == selectedScopeIndex,
      enabled: editable,
      dataAttrs: @[("data-source-scope-editable",
        if editable: "true" else: "false")],
      onChoose: scopeChoiceHandler(kind, editable))
  var sourceScopeRow = renderCompactChoiceRow[R, E](r, "",
    "Choose source scope for " & propName, scopeOptions, visibleLimit = 1,
    labelWidth = "0", minHeight = "22px")
  scopeNode = sourceScopeRow.root
  result = ui(r):
    tdiv(display = "grid",
          grid_template_columns = "136px minmax(0, 1fr) 30px 56px 22px",
          align_items = "center", gap = "3px",
          min_height = "22px", max_width = "100%", overflow = "visible"):
      label(ref = labelNode,
            font_size = "10px", color = textSecondary,
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis", cursor = "ew-resize",
            title = "Scrub " & propName & " value"):
        text propName
      tdiv(display = "flex", align_items = "center", gap = "4px",
            min_width = "0", overflow = "hidden",
            `data-inspector-row-slot` = "value-field"):
        if swatchesFor(propName).len > 0:
          tdiv(width = "14px", height = "14px",
                flex = "0 0 14px",
                border_radius = "3px",
                border = "1px solid " & borderFaint,
                box_shadow = "inset 0 0 0 1px rgba(255, 255, 255, 0.06)",
                background_color = value)
        input(ref = inputNode,
              class = "editor-input",
              height = "22px",
              background = filterSliderBackground(propName, value),
              border = "1px solid " & border,
              border_radius = "3px",
              padding = "0 6px",
              font_size = "11px",
              color = textPrimary,
              outline = "none",
              flex = "1",
              min_width = "0",
              oninput = preview,
              onchange = commit,
              onblur = commit)
      tdiv(ref = unitNode, role = "button", tabindex = "0",
            `aria-label` = "Cycle unit for " & propName,
            height = "22px",
            display = "flex",
            align_items = "center",
            justify_content = "center",
            border = (if unit.len > 0: "1px solid " & border
                      else: "1px solid transparent"),
            border_radius = "3px",
            background_color = (if unit.len > 0: "#0F172A" else: "transparent"),
            color = textMuted, font_size = "9px",
            white_space = "nowrap",
            overflow = "hidden",
            cursor = (if unit.len > 0: "pointer" else: "default")):
        text unit
      tdiv(ref = scopeHost, min_width = "0", overflow = "hidden"):
        discard
      tdiv(ref = moreNode, role = "button", tabindex = "0",
            `aria-label` = "More " & propName & " property actions",
            height = "22px",
            display = "flex", align_items = "center",
            justify_content = "center",
            border = "1px solid " & border,
            border_radius = "3px",
            background_color = "#0F172A",
            color = textMuted, font_size = "13px",
            cursor = "pointer"):
        text "..."
      # Hidden slots — kept in the DOM so accessibility tools, tests and the
      # row's More menu can still reach the binding indicator and the Reset
      # action, but display:none keeps the visible grid to a single 22px line.
      tdiv(ref = bindingNode,
            display = "none",
            `aria-label` = "Binding indicator for " & propName,
            font_size = "9px", color = textMuted,
            padding = "1px 6px", border = "1px solid " & border,
            border_radius = "3px",
            background_color = "#0F172A",
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text binding
      tdiv(ref = resetNode, role = "button", tabindex = "0",
            display = "none",
            `aria-label` = "Reset " & propName & " property",
            height = "22px",
            padding = "0 8px",
            border = "1px solid " & border,
            border_radius = "4px",
            background_color = bgSurface,
            color = textMuted, font_size = "10px",
            cursor = "pointer"):
        text "Reset"
  r.setAttribute(inputNode, "aria-label", "Edit inspector property " & propName)
  r.appendChild(scopeHost, sourceScopeRow.root)
  r.setAttribute(inputNode, "data-isonim-focus-id", "property-" & propName)
  r.setAttribute(result, "data-inspector-dense-row", "true")
  r.setAttribute(result, "data-inspector-property", propName)
  r.setAttribute(result, "data-inspector-property-source-key", prop.schemaKey)
  r.setAttribute(result, "data-inspector-row-slots",
    "label scrub-value unit binding scope reset more")
  r.setAttribute(labelNode, "data-inspector-row-slot", "label-scrubber")
  r.setAttribute(labelNode, "data-inspector-label-scrubber", "true")
  r.setAttribute(unitNode, "data-inspector-row-slot", "unit-picker")
  r.setAttribute(bindingNode, "data-inspector-row-slot", "binding-indicator")
  r.setAttribute(scopeNode, "data-inspector-row-slot", "scope-selector")
  r.setAttribute(scopeNode, "data-inspector-scope-selector", "true")
  r.setAttribute(scopeNode, "data-compact-choice-strip", "true")
  r.setAttribute(scopeNode, "data-source-scope-count", $scopeChoices.len)
  r.setAttribute(resetNode, "data-inspector-row-slot", "reset")
  r.setAttribute(moreNode, "data-inspector-row-slot", "actions")
  r.setInputValue(inputNode, roundedPxValue(value))
  r.addEventListener(inputNode, "change", commit)
  r.addEventListener(inputNode, "blur", commit)
  r.addEventListener(inputNode, "input", preview)
  r.addEventListener(inputNode, "keyup", preview)
  r.attachLiveInputPreview(inputNode, frame, propName)
  r.attachPrimitiveInputKeys(inputNode, frame, propName)
  r.addEventListener(inputNode, "focus", rememberPanelFocus(vm,
    "property-" & propName))
  let cycleUnit = proc() =
    let nextValue = cyclePrimitiveUnit(propName, r.inputValue(inputNode))
    r.setInputValue(inputNode, nextValue)
    r.applyCssValue(vm, frame, propName, nextValue)
  r.addEventListener(unitNode, "click", cycleUnit)
  r.addEventListener(unitNode, "keydown", cycleUnit)
  let applySelectedScope = proc() =
    commitScope(selectedScope.kind)
  r.addEventListener(scopeNode, "keydown", applySelectedScope)
  let reset = proc() = r.applyCssValue(vm, frame, propName, fallback)
  r.addEventListener(resetNode, "click", reset)
  r.addEventListener(resetNode, "keydown", reset)
  r.addEventListener(moreNode, "click", rememberPanelFocus(vm,
    "property-" & propName))
  r.addEventListener(moreNode, "keydown", rememberPanelFocus(vm,
    "property-" & propName))

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
    tdiv(display = "grid",
          grid_template_columns = "auto auto minmax(0, 1fr)",
          align_items = "center", gap = "4px",
          min_width = "0",
          padding = "1px 0",
          background_color = "transparent"):
      span(font_size = "8px", font_weight = "700", color = color):
        text tone
      span(font_size = "8px", color = textMuted):
        text label
      span(font_size = "8px", color = textDim, font_family = "monospace",
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
        const node = """, node,
        """;
        if (!node || node.__isonimScrubberInstalled) return;
        node.__isonimScrubberInstalled = true;
        const initial = """, value,
        """;
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
          """, scrub,
        """(format(next, parsed.unit));
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
        const node = """, node,
        """;
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
          """, choose,
        """(hslToHex(hue, x * 100, (1 - y) * 68 + 16));
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
        const plane = """, plane,
        """;
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
          """, choose,
        """(hslToHex(hue, 72, 56));
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
                  background_color = (if unit ==
                      candidate: accent else: bgSurface),
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
  var modeButton: E
  var rgbButton: E
  var hslButton: E
  var contrastButton: E
  var eyedropperButton: E
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
      tdiv(display = "grid",
            grid_template_columns = "repeat(3, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = rgbButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center",
              cursor = "pointer"):
          text "RGB"
        tdiv(ref = hslButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center",
              cursor = "pointer"):
          text "HSL"
        tdiv(ref = contrastButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center",
              cursor = "pointer"):
          text "AA"
      tdiv(display = "flex", gap = "5px", align_items = "center"):
        tdiv(width = "24px", height = "24px", border_radius = "4px",
              background_color = base, border = "1px solid " & border)
        tdiv(ref = tokenButton, role = "button", tabindex = "0",
              flex = "1", padding = "5px 7px",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px", cursor = "pointer"):
          text "Use token"
        tdiv(ref = modeButton, role = "button", tabindex = "0",
              padding = "5px 7px",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px",
              cursor = "pointer"):
          text "Mode"
        tdiv(ref = eyedropperButton, role = "button", tabindex = "0",
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
  r.setAttribute(modeButton, "aria-label", "Choose variable mode for " & propName)
  r.setAttribute(rgbButton, "aria-label", "Use RGB format for " & propName)
  r.setAttribute(hslButton, "aria-label", "Use HSL format for " & propName)
  r.setAttribute(contrastButton, "aria-label", "Preview contrast for " & propName)
  r.setAttribute(eyedropperButton, "aria-label", "Use browser eyedropper for " & propName)
  let setBlue = r.propertyActionHandler(vm, frame, propName, "#3B82F6")
  let setGreen = r.propertyActionHandler(vm, frame, propName, "#22C55E")
  let setRgb = r.propertyActionHandler(vm, frame, propName, "rgb(59, 130, 246)")
  let setHsl = r.propertyActionHandler(vm, frame, propName, "hsl(217, 91%, 60%)")
  let setOpacity = r.propertyActionHandler(vm, frame, propName, "rgba(59, 130, 246, 0.72)")
  let setToken = r.propertyActionHandler(vm, frame, propName, "token(semantic.text.primary)")
  r.addEventListener(saturation, "click", setBlue)
  r.addEventListener(saturation, "keydown", setBlue)
  r.addEventListener(hue, "click", setGreen)
  r.addEventListener(hue, "keydown", setGreen)
  r.addEventListener(opacity, "click", setOpacity)
  r.addEventListener(opacity, "keydown", setOpacity)
  r.addEventListener(rgbButton, "click", setRgb)
  r.addEventListener(rgbButton, "keydown", setRgb)
  r.addEventListener(hslButton, "click", setHsl)
  r.addEventListener(hslButton, "keydown", setHsl)
  r.addEventListener(tokenButton, "click", setToken)
  r.addEventListener(tokenButton, "keydown", setToken)
  r.attachColorPlane(saturation, vm, frame, propName)
  r.attachHueStrip(hue, vm, frame, saturation, propName)

proc renderGradientAffordances[R, E](r: R; vm: EditorVM; frame: E; propName,
    value: string): E =
  var linearButton: E
  var radialButton: E
  var angleButton: E
  var addStopButton: E
  var removeStopButton: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(height = "28px", border_radius = "5px",
            border = "1px solid " & border,
            background = (if value.contains("gradient("): value else:
        "linear-gradient(90deg, #3B82F6 0%, #22C55E 100%)"))
      tdiv(display = "grid",
            grid_template_columns = "repeat(5, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = linearButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "linear"
        tdiv(ref = radialButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "radial"
        tdiv(ref = angleButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "ew-resize"):
          text "90deg"
        tdiv(ref = addStopButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "+stop"
        tdiv(ref = removeStopButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "-stop"
      tdiv(display = "grid",
            grid_template_columns = "repeat(3, minmax(0, 1fr))",
            gap = "4px"):
        for stop in ["#3B82F6 0%", "token(semantic.accent) 48%",
            "#22C55E 100%"]:
          tdiv(role = "button", tabindex = "0",
                padding = "4px 5px", border_radius = "4px",
                background_color = bgSurface, color = textMuted,
                font_size = "9px", text_align = "center",
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text stop
  r.setAttribute(result, "aria-label", "Edit gradient stops")
  r.setAttribute(linearButton, "aria-label", "Set " & propName & " to linear gradient")
  r.setAttribute(radialButton, "aria-label", "Set " & propName & " to radial gradient")
  r.setAttribute(angleButton, "aria-label", "Scrub " & propName & " gradient angle")
  r.setAttribute(addStopButton, "aria-label", "Add " & propName & " gradient stop")
  r.setAttribute(removeStopButton, "aria-label", "Remove " & propName & " gradient stop")
  let linear = r.propertyActionHandler(vm, frame, propName,
    "linear-gradient(90deg, #3B82F6 0%, token(semantic.accent) 48%, #22C55E 100%)")
  let radial = r.propertyActionHandler(vm, frame, propName,
    "radial-gradient(circle, #3B82F6 0%, #22C55E 100%)")
  let angled = r.propertyActionHandler(vm, frame, propName,
    "linear-gradient(135deg, #3B82F6 0%, #22C55E 100%)")
  r.addEventListener(linearButton, "click", linear)
  r.addEventListener(linearButton, "keydown", linear)
  r.addEventListener(radialButton, "click", radial)
  r.addEventListener(radialButton, "keydown", radial)
  r.addEventListener(angleButton, "click", angled)
  r.addEventListener(angleButton, "keydown", angled)
  r.addEventListener(addStopButton, "click", linear)
  r.addEventListener(addStopButton, "keydown", linear)
  r.addEventListener(removeStopButton, "click", radial)
  r.addEventListener(removeStopButton, "keydown", radial)

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
            grid_template_columns = "1fr 1fr",
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
  var insetButton: E
  var elevationButton: E
  var multiButton: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(display = "flex", gap = "8px"):
        tdiv(width = "76px", height = "76px", position = "relative",
              border = "1px solid " & border,
              border_radius = "4px", background_color = bgSurface,
              box_shadow = value):
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
      tdiv(display = "grid",
            grid_template_columns = "repeat(4, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = presetButton, role = "button", tabindex = "0",
              height = "24px", display = "flex",
              align_items = "center", justify_content = "center",
              border_radius = "4px", background_color = accent,
              color = textPrimary, font_size = "10px",
              cursor = "pointer"):
          text "soft"
        tdiv(ref = insetButton, role = "button", tabindex = "0",
              height = "24px", display = "flex",
              align_items = "center", justify_content = "center",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px",
              cursor = "pointer"):
          text "inset"
        tdiv(ref = elevationButton, role = "button", tabindex = "0",
              height = "24px", display = "flex",
              align_items = "center", justify_content = "center",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px",
              cursor = "pointer"):
          text "token"
        tdiv(ref = multiButton, role = "button", tabindex = "0",
              height = "24px", display = "flex",
              align_items = "center", justify_content = "center",
              border_radius = "4px", background_color = bgSurface,
              color = textMuted, font_size = "10px",
              cursor = "pointer"):
          text "+layer"
  r.setAttribute(result, "aria-label", "Edit shadow with crosshair")
  r.setAttribute(presetButton, "aria-label", "Apply soft shadow preset")
  r.setAttribute(insetButton, "aria-label", "Toggle inset shadow")
  r.setAttribute(elevationButton, "aria-label", "Bind elevation token")
  r.setAttribute(multiButton, "aria-label", "Add shadow layer")
  let preset = r.propertyActionHandler(vm, frame, propName,
    "0 8px 24px rgba(15, 23, 42, 0.18)")
  let inset = r.propertyActionHandler(vm, frame, propName,
    "inset 0 1px 3px rgba(15, 23, 42, 0.24)")
  let elevation = r.propertyActionHandler(vm, frame, propName,
    "token(elevation.raised)")
  let multi = r.propertyActionHandler(vm, frame, propName,
    "0 1px 2px rgba(15, 23, 42, 0.18), 0 12px 32px rgba(15, 23, 42, 0.16)")
  r.addEventListener(presetButton, "click", preset)
  r.addEventListener(presetButton, "keydown", preset)
  r.addEventListener(insetButton, "click", inset)
  r.addEventListener(insetButton, "keydown", inset)
  r.addEventListener(elevationButton, "click", elevation)
  r.addEventListener(elevationButton, "keydown", elevation)
  r.addEventListener(multiButton, "click", multi)
  r.addEventListener(multiButton, "keydown", multi)

proc renderTypographyAffordances[R, E](r: R; vm: EditorVM; frame: E;
    propName, value: string): E =
  var styleButton: E
  var familyButton: E
  var weightButton: E
  var lineButton: E
  var responsiveButton: E
  var truncateButton: E
  var wrapButton: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px", border_radius = "5px",
          background_color = bgBase):
      tdiv(border = "1px solid " & border, border_radius = "5px",
            background_color = bgSurface, color = textPrimary,
            padding = "8px", font_size = (if propName ==
                "font-size": value else: "14px"),
            font_weight = (if propName == "font-weight": value else: "600"),
            line_height = (if propName == "line-height": value else: "1.35"),
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text "Typography preview"
      tdiv(display = "grid",
            grid_template_columns = "repeat(3, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = styleButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "body"
        tdiv(ref = familyButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "font"
        tdiv(ref = weightButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "700"
        tdiv(ref = lineButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "1.4"
        tdiv(ref = responsiveButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "fluid"
        tdiv(ref = truncateButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "truncate"
      tdiv(ref = wrapButton, role = "button", tabindex = "0",
            padding = "4px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", text_align = "center", cursor = "pointer"):
        text "wrap"
  r.setAttribute(result, "aria-label", "Edit typography details")
  r.setAttribute(styleButton, "aria-label", "Bind body text style")
  r.setAttribute(familyButton, "aria-label", "Set font family to system")
  r.setAttribute(weightButton, "aria-label", "Set font weight to 700")
  r.setAttribute(lineButton, "aria-label", "Set line height to 1.4")
  r.setAttribute(responsiveButton, "aria-label", "Set responsive text mode fluid")
  r.setAttribute(truncateButton, "aria-label", "Set text truncation")
  r.setAttribute(wrapButton, "aria-label", "Set text wrapping")
  let bindStyle = r.propertyActionHandler(vm, frame, propName,
    if propName == "font-size": "token(type.body.size)" else: value)
  let family = r.propertyActionHandler(vm, frame, "font-family",
    "Inter, ui-sans-serif, system-ui")
  let weight = r.propertyActionHandler(vm, frame, "font-weight", "700")
  let line = r.propertyActionHandler(vm, frame, "line-height", "1.4")
  let responsive = r.propertyActionHandler(vm, frame, "font-size",
    "clamp(14px, 2vw, 20px)")
  let truncate = r.propertyActionHandler(vm, frame, "text-overflow", "ellipsis")
  let wrap = r.propertyActionHandler(vm, frame, "white-space", "normal")
  r.addEventListener(styleButton, "click", bindStyle)
  r.addEventListener(styleButton, "keydown", bindStyle)
  r.addEventListener(familyButton, "click", family)
  r.addEventListener(familyButton, "keydown", family)
  r.addEventListener(weightButton, "click", weight)
  r.addEventListener(weightButton, "keydown", weight)
  r.addEventListener(lineButton, "click", line)
  r.addEventListener(lineButton, "keydown", line)
  r.addEventListener(responsiveButton, "click", responsive)
  r.addEventListener(responsiveButton, "keydown", responsive)
  r.addEventListener(truncateButton, "click", truncate)
  r.addEventListener(truncateButton, "keydown", truncate)
  r.addEventListener(wrapButton, "click", wrap)
  r.addEventListener(wrapButton, "keydown", wrap)

proc renderBezierAffordances[R, E](r: R; vm: EditorVM; frame: E;
    propName, value: string): E =
  var reducedMotionButton: E
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
      tdiv(ref = reducedMotionButton, role = "button", tabindex = "0",
            padding = "4px 6px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", cursor = "pointer"):
        text "reduced-motion check"
  r.setAttribute(result, "aria-label", "Edit transition timing curve")
  r.setAttribute(reducedMotionButton, "aria-label",
    "Run reduced-motion diagnostics")
  let reducedMotion = r.propertyActionHandler(vm, frame, propName, value)
  r.addEventListener(reducedMotionButton, "click", reducedMotion)
  r.addEventListener(reducedMotionButton, "keydown", reducedMotion)
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

func segmentedIcon(propName, value: string): string =
  ## Iconic glyph for visual layout/alignment property values, used to render
  ## Figma-style segmented strips. Empty result means "fall back to text label".
  case propName
  of "flex-direction":
    case value
    of "row": "\xE2\x86\x92"          # →
    of "column": "\xE2\x86\x93"       # ↓
    of "row-reverse": "\xE2\x86\x90"  # ←
    of "column-reverse": "\xE2\x86\x91" # ↑
    else: ""
  of "align-items", "align-self":
    case value
    of "stretch": "\xE2\x87\x95"      # ⇕
    of "center": "\xE2\x97\x8F"       # ● (mid-axis dot)
    of "flex-start": "\xE2\x86\xA5"   # ↥
    of "flex-end": "\xE2\x86\xA7"     # ↧
    of "baseline": "\xE2\x80\xBE"     # ‾
    of "auto": "\xE2\x97\x8B"         # ○
    else: ""
  of "align-content":
    case value
    of "stretch": "\xE2\x87\x95"      # ⇕
    of "center": "\xE2\x97\x8F"       # ●
    of "flex-start": "\xE2\x86\xA5"   # ↥
    of "flex-end": "\xE2\x86\xA7"     # ↧
    of "space-between": "\xE2\x86\x95" # ↕
    else: ""
  of "justify-content":
    case value
    of "flex-start": "\xE2\x87\xA4"   # ⇤
    of "center": "\xE2\x97\x8F"       # ●
    of "flex-end": "\xE2\x87\xA5"     # ⇥
    of "space-between": "\xE2\x87\x86" # ⇆
    of "space-around": "\xE2\x87\x8C" # ⇌
    of "space-evenly": "\xE2\x89\xA1" # ≡
    else: ""
  of "text-align":
    case value
    of "left": "\xE2\x87\xA4"         # ⇤
    of "center": "\xE2\x97\x8F"       # ●
    of "right": "\xE2\x87\xA5"        # ⇥
    of "justify": "\xE2\x98\xB0"      # ☰
    else: ""
  else: ""

func hasSegmentedIcons(propName: string): bool =
  ## True when at least one quickValue for this property has an iconic glyph.
  for value in quickValues(propName):
    if segmentedIcon(propName, value).len > 0:
      return true
  false

proc renderQuickValues[R, E](r: R; vm: EditorVM; frame: E; propName,
    current: string): E =
  ## All enum properties render as a Figma-style connected segmented strip:
  ## one outer 1px border around the whole group, hairline dividers between
  ## cells, no inter-cell gap. Visual layout properties (flex-direction,
  ## align-items, justify-content, text-align) use iconic glyphs; everything
  ## else uses tight text labels. Same shape, same row height, no stylistic
  ## seam between neighbouring rows.
  let values = quickValues(propName)
  let useIcons = hasSegmentedIcons(propName)
  result = ui(r):
    tdiv(display = "inline-flex", align_items = "stretch",
          border = "1px solid " & border,
          border_radius = "4px",
          background_color = bgSurface,
          overflow = "hidden", max_width = "100%")
  for i in 0 ..< values.len:
    let nextValue = $values[i]
    let isActive = current == nextValue
    let isLast = i == values.high
    let glyph = segmentedIcon(propName, nextValue)
    let display = if glyph.len > 0: glyph else: nextValue
    let cell = ui(r):
      tdiv(role = "button", tabindex = "0",
            flex = "1 1 0",
            min_width = "0",
            height = "22px",
            padding = (if useIcons: "0 6px" else: "0 7px"),
            display = "flex", align_items = "center",
            justify_content = "center",
            font_size = (if glyph.len > 0: "13px" else: "10px"),
            font_weight = (if isActive: "700" else: "600"),
            cursor = "pointer",
            white_space = "nowrap",
            overflow = "hidden",
            text_overflow = "ellipsis",
            background_color = (if isActive: accent else: "transparent"),
            color = (if isActive: textPrimary else: textSecondary),
            border_right = (if isLast: "none" else: "1px solid " & border),
            transition = "background-color 0.12s, color 0.12s"):
        text display
    r.setAttribute(cell, "aria-label",
      "Set " & propName & " to " & nextValue)
    r.setAttribute(cell, "title", nextValue)
    r.setAttribute(cell, "data-segmented-strip-cell", nextValue)
    r.setAttribute(cell, "data-segmented-strip-active",
      if isActive: "true" else: "false")
    let activate = r.inspectorLiveValueHandler(vm, frame, propName, nextValue)
    r.addEventListener(cell, "click", activate)
    r.addEventListener(cell, "keydown", activate)
    r.appendChild(result, cell)
  r.setAttribute(result, "data-segmented-strip", propName)

proc renderSwatches[R, E](r: R; vm: EditorVM; frame: E; propName,
    current: string): E =
  let values = swatchesFor(propName)
  result = ui(r):
    tdiv(display = "flex", flex_wrap = "wrap", gap = "4px",
          align_items = "center")
  for value in values:
    let nextValue = $value
    let isActive = current == nextValue
    let swatch = ui(r):
      tdiv(role = "button", tabindex = "0",
            width = "20px", height = "20px", border_radius = "4px",
            cursor = "pointer",
            background_color = nextValue,
            border = "1px solid " & (if isActive: accent else: borderFaint),
            box_shadow = (if isActive:
              "0 0 0 1px " & accent
            else: "inset 0 0 0 1px rgba(255,255,255,0.04)"))
    r.setAttribute(swatch, "aria-label",
      "Set " & propName & " to " & nextValue)
    let activate = r.inspectorLiveValueHandler(vm, frame, propName, nextValue)
    r.addEventListener(swatch, "click", activate)
    r.addEventListener(swatch, "keydown", activate)
    r.appendChild(result, swatch)

proc renderRichPropertyControl[R, E](r: R; vm: EditorVM; frame: E;
    clipboard: StyleClipboard; prop: PropertyInfo; fallback: string): E =
  ## Single-line dense row, Figma-style. Cascade origin, copy/paste/reset and
  ## the always-on swatch palette live behind an inline "More" disclosure so
  ## each row is one ~22-24px line by default. Short segmented strips
  ## (`quickValues`) stay inline because the reviewer flagged them as the
  ## clearest affordance in the pane.
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "0",
          padding = "1px 0",
          border_bottom = "1px solid " & borderFaint)
  r.setAttribute(result, "data-inspector-control", prop.name)
  r.appendChild(result, renderPropertyInput[R, E](r, vm, frame, prop, fallback))
  if quickValues(prop.name).len > 0:
    r.appendChild(result, renderQuickValues[R, E](r, vm, frame, prop.name,
      prop.value))
  let advanced = ui(r):
    details(`aria-label` = "Show " & prop.name & " more controls"):
      summary(cursor = "pointer", color = textDim, font_size = "9px",
              padding = "1px 0 1px 64px",
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis"):
        text "More"
  r.appendChild(advanced, renderCascadeIndicator[R, E](r, prop))
  r.appendChild(advanced, renderPropertyActions[R, E](r, vm, frame, clipboard,
    prop.name, prop.value, fallback))
  if swatchesFor(prop.name).len > 0:
    r.appendChild(advanced, renderSwatches[R, E](r, vm, frame, prop.name,
      prop.value))
  if isNumericProperty(prop.name):
    r.appendChild(advanced, renderNumericAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if swatchesFor(prop.name).len > 0:
    r.appendChild(advanced, renderFigmaColorAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name == "background-image" or prop.value.contains("gradient("):
    r.appendChild(advanced, renderGradientAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name == "border-radius":
    r.appendChild(advanced, renderBorderRadiusAffordances[R, E](r, vm, frame,
      prop.value))
  if prop.name == "box-shadow":
    r.appendChild(advanced, renderShadowAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name in ["font-family", "font-size", "font-weight", "line-height",
      "letter-spacing", "white-space", "text-overflow"]:
    r.appendChild(advanced, renderTypographyAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  if prop.name == "transition-timing-function":
    r.appendChild(advanced, renderBezierAffordances[R, E](r, vm, frame,
      prop.name, prop.value))
  r.appendChild(result, advanced)

proc sectionTitle(section: InspectorSection): string =
  for i, candidate in richSections:
    if candidate == section:
      return richSectionLabels[i]
  "Inspector"

func sectionFullTitle(section: InspectorSection): string =
  case section
  of isSpacing: "Spacing"
  of isTypography: "Typography"
  of isEffects: "Effects"
  of isTransitions: "Transitions"
  of isFilters: "Filters"
  of isState: "State"
  of isSource: "Source"
  else: sectionTitle(section)

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

proc renderLayoutControlSummary[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef): E =
  var rowButton: E
  var columnButton: E
  var wrapButton: E
  var gapButton: E
  var paddingButton: E
  var alignButton: E
  var justifyButton: E
  var distributionButton: E
  var hugButton: E
  var fillButton: E
  var fixedButton: E
  var orderButton: E
  var childAlignButton: E
  var gridTracksButton: E
  var gridGapButton: E
  var gridPlacementButton: E
  var gridFlowButton: E
  var gridAreasButton: E
  var constraintsButton: E
  var minMaxButton: E
  var intrinsicButton: E
  var aspectButton: E
  var overflowButton: E
  var mobileButton: E
  var tabletButton: E
  var customButton: E
  let mode = layoutModeKey(vm.viewport.val)
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "10px", border = "1px solid " & border,
          border_radius = "6px", background_color = bgBase):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between", gap = "8px"):
        span(font_size = "10px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Auto Layout"
        span(font_size = "10px", color = accent, font_family = "monospace"):
          text mode
      tdiv(display = "grid",
            grid_template_columns = "repeat(4, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = rowButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "row"
        tdiv(ref = columnButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "col"
        tdiv(ref = wrapButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "wrap"
        tdiv(ref = gapButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "gap"
        tdiv(ref = paddingButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "pad"
        tdiv(ref = alignButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "align"
        tdiv(ref = justifyButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "justify"
        tdiv(ref = distributionButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "dist"
        tdiv(ref = hugButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "hug"
        tdiv(ref = fillButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "fill"
        tdiv(ref = fixedButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "fixed"
        tdiv(ref = orderButton, role = "button", tabindex = "0",
              padding = "4px 5px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "order"
      tdiv(ref = childAlignButton, role = "button", tabindex = "0",
            padding = "4px 5px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "9px", text_align = "center", cursor = "pointer"):
        text "per-child alignment"
      tdiv(display = "grid",
            grid_template_columns = "repeat(5, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = gridTracksButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "tracks"
        tdiv(ref = gridGapButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "g-gap"
        tdiv(ref = gridPlacementButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "place"
        tdiv(ref = gridFlowButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "flow"
        tdiv(ref = gridAreasButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "areas"
      tdiv(display = "grid",
            grid_template_columns = "repeat(5, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = constraintsButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "L/R/T/B"
        tdiv(ref = minMaxButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "minmax"
        tdiv(ref = intrinsicButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "content"
        tdiv(ref = aspectButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "ratio"
        tdiv(ref = overflowButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "overflow"
      tdiv(display = "grid",
            grid_template_columns = "repeat(3, minmax(0, 1fr))",
            gap = "4px"):
        tdiv(ref = mobileButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "mobile gap"
        tdiv(ref = tabletButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "tablet gap"
        tdiv(ref = customButton, role = "button", tabindex = "0",
              padding = "4px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "9px", text_align = "center", cursor = "pointer"):
          text "custom"
      span(font_size = "9px", color = textDim):
        text "canvas shows spacing measurement, gap overlay, align handles, resize handles, snap lines, and diagnostics"
  let actions = [
    (rowButton, "Set flex direction to row", "flex-direction", "row"),
    (columnButton, "Set flex direction to column", "flex-direction", "column"),
    (wrapButton, "Enable flex wrap", "flex-wrap", "wrap"),
    (gapButton, "Set auto layout gap to 24px", "gap", "24px"),
    (paddingButton, "Set auto layout padding to 20px", "padding", "20px"),
    (alignButton, "Set align items to center", "align-items", "center"),
    (justifyButton, "Set justify content to space between", "justify-content",
        "space-between"),
    (distributionButton, "Set distribution to space evenly", "justify-content",
        "space-evenly"),
    (hugButton, "Set sizing to hug content", "width", "fit-content"),
    (fillButton, "Set sizing to fill container", "flex-grow", "1"),
    (fixedButton, "Set sizing to fixed width", "width", fallbackPropertyValue(
        selected, "width", "320px")),
    (orderButton, "Set child order to one", "order", "1"),
    (childAlignButton, "Set per-child alignment to center", "align-self",
        "center"),
    (gridTracksButton, "Set grid template tracks", "grid-template-columns",
        "repeat(2, minmax(0, 1fr))"),
    (gridGapButton, "Set grid gap to 24px", "gap", "24px"),
    (gridPlacementButton, "Set grid placement to span two", "grid-column",
        "span 2"),
    (gridFlowButton, "Set grid auto flow dense", "grid-auto-flow", "row dense"),
    (gridAreasButton, "Set grid named areas", "grid-template-areas",
        "\"main side\""),
    (constraintsButton, "Set left right top bottom constraints", "position",
        "relative"),
    (minMaxButton, "Set min max width constraints", "min-width", "240px"),
    (intrinsicButton, "Set intrinsic content sizing", "width", "max-content"),
    (aspectButton, "Set aspect ratio to sixteen nine", "aspect-ratio",
        "16 / 9"),
    (overflowButton, "Set overflow strategy to auto", "overflow", "auto")
  ]
  for (node, label, propName, value) in actions:
    r.setAttribute(node, "aria-label", label)
    let handler = r.inspectorLiveValueHandler(vm, frame, propName, value)
    r.addEventListener(node, "click", handler)
    r.addEventListener(node, "keydown", handler)
  r.setAttribute(mobileButton, "aria-label",
    "Set responsive override for Mobile mode")
  r.setAttribute(tabletButton, "aria-label",
    "Set responsive override for Tablet mode")
  r.setAttribute(customButton, "aria-label",
    "Set responsive override for project-defined mode")
  let mobile = proc() = r.applyResponsiveCssValue(vm, frame, "mobile", "gap", "28px")
  let tablet = proc() = r.applyResponsiveCssValue(vm, frame, "tablet", "gap", "18px")
  let custom = proc() = r.applyResponsiveCssValue(vm, frame,
    "modes.breakpoint.compact", "gap", "12px")
  r.addEventListener(mobileButton, "click", mobile)
  r.addEventListener(mobileButton, "keydown", mobile)
  r.addEventListener(tabletButton, "click", tablet)
  r.addEventListener(tabletButton, "keydown", tablet)
  r.addEventListener(customButton, "click", custom)
  r.addEventListener(customButton, "keydown", custom)

proc renderRawCssEditor[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef; section: InspectorSection): E =
  var rawInput: E
  var applyButton: E
  let title = sectionTitle(section)
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          padding = "8px 0"):
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

proc layerSearchHandler[R, E](r: R; vm: EditorVM; input: E): proc() =
  result = proc() =
    vm.inspector.setLayerSearch(r.inputValue(input))

proc sectionSearchHandler[R, E](r: R; vm: EditorVM; input: E): proc() =
  result = proc() =
    vm.inspector.setSectionSearch(r.inputValue(input))

proc populateInspectorContent[R, E](r: R; vm: EditorVM; frame, content: E;
    clipboard: StyleClipboard)
proc populateSectionTabs[R, E](r: R; vm: EditorVM; frame, tabs, content: E;
    clipboard: StyleClipboard)

proc layerSelectHandler[R, E](r: R; vm: EditorVM; frame: E; id: string): proc() =
  let captured = id
  result = proc() =
    discard vm.selectInspectorElementById(captured)
    r.selectPreviewElementById(frame, captured)

proc layerHoverHandler[R, E](r: R; vm: EditorVM; frame: E; id: string): proc() =
  let captured = id
  result = proc() =
    vm.inspector.setLayerHover(captured)
    r.hoverPreviewElementById(frame, captured)

proc layerToggleHandler(vm: EditorVM; id: string): proc() =
  let captured = id
  result = proc() =
    vm.inspector.toggleLayerExpanded(captured)

proc layerCommandHandler[R, E](r: R; vm: EditorVM; frame: E;
    command: string): proc() =
  let captured = command
  result = proc() =
    let changed =
      case captured
      of "parent": vm.selectParentInspectorElement()
      of "child": vm.selectChildInspectorElement()
      of "next": vm.selectNextInspectorElement()
      of "previous": vm.selectPreviousInspectorElement()
      of "clear":
        vm.clearInspectorSelection()
        true
      else:
        false
    if changed:
      let id = vm.inspector.selectedElement.val.id
      if id.len > 0:
        r.selectPreviewElementById(frame, id)

proc renderElementTree[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef): E =
  var searchInput: E
  var rowsNode: E
  var prevButton: E
  var parentButton: E
  var childButton: E
  var nextButton: E
  var clearButton: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "7px",
          padding = "8px 0"):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between", gap = "8px"):
        span(font_size = "10px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Layers"
        span(font_size = "10px", color = textDim):
          text $vm.inspector.filteredLayers.val.len & " rows"
      input(ref = searchInput,
            class = "editor-input",
            height = "26px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "0 7px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            min_width = "0",
            `aria-label` = "Search element layers",
            placeholder = "Search layers")
      tdiv(display = "grid",
            grid_template_columns = "repeat(5, 1fr)",
            gap = "4px"):
        tdiv(ref = prevButton, role = "button", tabindex = "0",
              `aria-label` = "Select previous element",
              padding = "3px", text_align = "center",
              border = "1px solid " & border,
              border_radius = "4px", color = textMuted,
              cursor = "pointer"):
          text "Prev"
        tdiv(ref = parentButton, role = "button", tabindex = "0",
              `aria-label` = "Select parent element",
              padding = "3px", text_align = "center",
              border = "1px solid " & border,
              border_radius = "4px", color = textMuted,
              cursor = "pointer"):
          text "Up"
        tdiv(ref = childButton, role = "button", tabindex = "0",
              `aria-label` = "Select child element",
              padding = "3px", text_align = "center",
              border = "1px solid " & border,
              border_radius = "4px", color = textMuted,
              cursor = "pointer"):
          text "Down"
        tdiv(ref = nextButton, role = "button", tabindex = "0",
              `aria-label` = "Select next element",
              padding = "3px", text_align = "center",
              border = "1px solid " & border,
              border_radius = "4px", color = textMuted,
              cursor = "pointer"):
          text "Next"
        tdiv(ref = clearButton, role = "button", tabindex = "0",
              `aria-label` = "Clear element selection",
              padding = "3px", text_align = "center",
              border = "1px solid " & border,
              border_radius = "4px", color = textMuted,
              cursor = "pointer"):
          text "Clear"
      tdiv(ref = rowsNode,
            display = "flex", flex_direction = "column", gap = "3px",
            font_family = "monospace", font_size = "11px"):
        discard
  r.setAttribute(result, "aria-label", "Element tree selected " & selected.tag)
  r.setInputValue(searchInput, vm.inspector.layerSearch.val)
  let search = r.layerSearchHandler(vm, searchInput)
  r.addEventListener(searchInput, "input", search)
  r.addEventListener(searchInput, "change", search)

  let commandButtons = [prevButton, parentButton, childButton, nextButton,
    clearButton]
  let commands = ["previous", "parent", "child", "next", "clear"]
  for i, button in commandButtons:
    let handler = r.layerCommandHandler(vm, frame, commands[i])
    r.addEventListener(button, "click", handler)
    r.addEventListener(button, "keydown", handler)

  for row in vm.inspector.filteredLayers.val:
    let rowId = row.id
    let label = row.label
    let selectedRow = row.selected
    let depth = row.depth
    let childCount = row.childCount
    let expanded = row.expanded
    let sourceLabel = row.sourceFile.split("/")[^1] & ":" & $row.sourceLine
    let hidden = row.hidden
    let locked = row.locked
    var toggleNode: E
    var selectNode: E
    let rowNode = ui(r):
      tdiv(display = "grid",
            grid_template_columns = "18px minmax(0, 1fr) auto",
            align_items = "center", gap = "4px",
            min_height = "22px",
            padding = "2px 4px",
            padding_left = $(4 + depth * 12) & "px",
            border_radius = "4px",
            background_color = (if selectedRow: "rgba(59,130,246,.22)" else: "transparent"),
            color = (if selectedRow: textPrimary else: textMuted)):
        tdiv(ref = toggleNode, role = "button", tabindex = "0",
              `aria-label` = "Toggle layer " & label,
              color = textDim, cursor = "pointer"):
          text (if childCount > 0: (if expanded: "v" else: ">") else: "")
        tdiv(ref = selectNode, role = "button", tabindex = "0",
              `aria-label` = "Select layer " & label,
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis", cursor = "pointer"):
          text label
        span(font_size = "10px", color = textDim,
              white_space = "nowrap"):
          text sourceLabel
    r.setAttribute(rowNode, "data-isonim-layer-id", rowId)
    r.setAttribute(rowNode, "data-isonim-layer-selected",
      if selectedRow: "true" else: "false")
    r.setAttribute(rowNode, "data-isonim-layer-hidden",
      if hidden: "true" else: "false")
    r.setAttribute(rowNode, "data-isonim-layer-locked",
      if locked: "true" else: "false")
    let toggle = layerToggleHandler(vm, rowId)
    r.addEventListener(toggleNode, "click", toggle)
    r.addEventListener(toggleNode, "keydown", toggle)
    let select = r.layerSelectHandler(vm, frame, rowId)
    r.addEventListener(selectNode, "click", select)
    r.addEventListener(selectNode, "keydown", select)
    let hover = r.layerHoverHandler(vm, frame, rowId)
    r.addEventListener(rowNode, "mouseenter", hover)
    r.addEventListener(rowNode, "mouseover", hover)
    r.appendChild(rowsNode, rowNode)

func stylePanelProperty(selected: ElementRef;
    section: InspectorSection): string =
  for (name, fallback) in sectionProperties(section):
    discard fallback
    for prop in selected.properties:
      if prop.name == name:
        return name
  if selected.properties.len > 0:
    selected.properties[0].name
  else:
    "color"

func demoScopeValue(propName, current: string;
    scope: StyleScopeChoiceKind): string =
  case propName
  of "padding", "padding-top", "padding-right", "padding-bottom",
      "padding-left", "gap":
    if scope == sscSharedClass: "24px" else: "20px"
  of "color":
    if scope == sscSemanticToken: "#3B82F6" else: "#F8FAFC"
  of "background-color", "background":
    if scope == sscSemanticToken: "#EFF6FF" else: "#F8FAFC"
  of "border-radius":
    if scope == sscSharedClass: "12px" else: "10px"
  else:
    if current.len > 0: current else: "1px"

proc renderStyleManagerPanel[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef): E =
  let propName = stylePanelProperty(selected, vm.inspector.activeSection.val)
  let snapshot = vm.styleManagerSnapshot(propName)
  var localScopeButton: E
  var sharedScopeButton: E
  var promoteButton: E
  var detachButton: E
  var createClassButton: E
  var renameClassButton: E
  var duplicateClassButton: E
  result = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
          padding = "8px 0"):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between", gap = "8px",
            min_width = "0"):
        span(font_size = "10px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px",
              flex_shrink = "0"):
          text "Style manager"
        span(font_size = "10px", color = accent, font_family = "monospace",
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis", min_width = "0"):
          text snapshot.property & " = " & snapshot.finalValue
      input(class = "editor-input",
            height = "26px",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "4px",
            padding = "0 7px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            min_width = "0",
            `aria-label` = "Search reusable styles",
            placeholder = "Search reusable styles")
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            `aria-label` = "Current class stack"):
        span(font_size = "10px", color = textMuted):
          text "Current class stack"
        if snapshot.currentClassStack.len == 0:
          span(font_size = "11px", color = textDim):
            text "No reusable class on this property"
        else:
          for i in 0 ..< snapshot.currentClassStack.len:
            let className = snapshot.currentClassStack[i].className
            let editable = snapshot.currentClassStack[i].editable
            tdiv(display = "grid",
                  grid_template_columns = "minmax(0, 1fr) auto",
                  gap = "6px", align_items = "center",
                  min_height = "24px",
                  padding = "3px 5px", border = "1px solid " & border,
                  border_radius = "4px"):
              span(font_size = "11px", color = textPrimary,
                    white_space = "nowrap", overflow = "hidden",
                    text_overflow = "ellipsis"):
                text className
              span(font_size = "10px", color = textDim):
                text if editable: "editable" else: "read-only"
      tdiv(display = "grid", grid_template_columns = "1fr 1fr",
            gap = "4px"):
        tdiv(ref = createClassButton, role = "button", tabindex = "0",
              `aria-label` = "Create reusable class for " & snapshot.property,
              padding = "5px 6px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", text_align = "center", cursor = "pointer"):
          text "Create"
        tdiv(ref = renameClassButton, role = "button", tabindex = "0",
              `aria-label` = "Rename reusable class for " & snapshot.property,
              padding = "5px 6px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", text_align = "center", cursor = "pointer"):
          text "Rename"
        tdiv(ref = duplicateClassButton, role = "button", tabindex = "0",
              `aria-label` = "Duplicate reusable class for " &
              snapshot.property,
              padding = "5px 6px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", text_align = "center", cursor = "pointer"):
          text "Duplicate"
        tdiv(ref = detachButton, role = "button", tabindex = "0",
              `aria-label` = "Detach reusable class for " & snapshot.property,
              padding = "5px 6px", border_radius = "4px",
              background_color = bgSurface, color = textMuted,
              font_size = "10px", text_align = "center", cursor = "pointer"):
          text "Detach"
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            `aria-label` = "Safe style scope choices"):
        tdiv(display = "grid", grid_template_columns = "72px minmax(0, 1fr)",
              align_items = "center", gap = "6px",
              min_height = "24px",
              `data-compact-choice-row` = "true"):
          span(font_size = "10px", color = textMuted,
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text "Scope"
          tdiv(display = "grid", grid_template_columns = "1fr 1fr auto",
                align_items = "center",
                border = "1px solid " & border,
                border_radius = "4px",
                overflow = "visible",
                background_color = "#0F172A",
                `data-compact-choice-strip` = "true"):
            tdiv(ref = localScopeButton, role = "button", tabindex = "0",
                  `aria-label` = "Apply local instance scope for " &
                  snapshot.property,
                  padding = "4px 6px",
                  background_color = accent, color = textPrimary,
                  border_right = "1px solid " & border,
                  font_size = "10px", text_align = "center",
                  cursor = "pointer"):
              text "Local"
            tdiv(ref = sharedScopeButton, role = "button", tabindex = "0",
                  `aria-label` = "Apply shared class scope for " &
                  snapshot.property,
                  padding = "4px 6px",
                  background_color = "transparent", color = textMuted,
                  border_right = "1px solid " & border,
                  font_size = "10px", text_align = "center",
                  cursor = "pointer"):
              text "Class"
            details(height = "22px",
                    position = "relative",
                    font_size = "10px",
                    color = textDim):
              summary(display = "flex", align_items = "center",
                      justify_content = "center",
                      width = "22px", height = "22px",
                      list_style = "none", cursor = "pointer",
                      `aria-label` = "More style scope choices for " &
                        snapshot.property):
                text "⌄"
              tdiv(position = "absolute", right = "0", top = "23px",
                    z_index = "20", min_width = "160px",
                    padding = "4px", border = "1px solid " & border,
                    border_radius = "5px", background_color = bgSidebar,
                    box_shadow = "0 8px 24px rgba(0,0,0,0.28)"):
                for i in 0 ..< snapshot.scopeChoices.len:
                  let choiceLabel = snapshot.scopeChoices[i].label
                  let editable = snapshot.scopeChoices[i].editable
                  span(font_size = "10px",
                        color = (if editable: textMuted else: textDim),
                        white_space = "nowrap", overflow = "hidden",
                        text_overflow = "ellipsis"):
                    text choiceLabel & (
                        if editable: " editable" else: " read-only")
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            `aria-label` = "Cascade source layers"):
        span(font_size = "10px", color = textMuted):
          text "Cascade / source"
        for i in 0 ..< snapshot.cascadeLayers.len:
          let layerKind = snapshot.cascadeLayers[i].kind
          let layerValue = snapshot.cascadeLayers[i].value
          let editable = snapshot.cascadeLayers[i].editable
          let zebraBg =
            if i mod 2 == 0: "rgba(255,255,255,0.015)" else: "transparent"
          tdiv(display = "grid",
                grid_template_columns = "82px minmax(0, 1fr) auto",
                gap = "5px", align_items = "center",
                min_height = "24px",
                padding = "3px 5px", border = "1px solid " & borderFaint,
                border_radius = "4px",
                background_color = zebraBg):
            span(font_size = "10px", color = textDim):
              text styleCascadeLayerLabel(layerKind)
            span(font_size = "10px", color = textPrimary,
                  white_space = "nowrap", overflow = "hidden",
                  text_overflow = "ellipsis"):
              text layerValue
            span(font_size = "9px", color = textDim):
              text if editable: "edit" else: "view"
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            `aria-label` = "Token manager"):
        span(font_size = "10px", color = textMuted):
          text "Token manager"
        for i in 0 ..< snapshot.tokenItems.len:
          let itemKey = snapshot.tokenItems[i].key
          let aliasOf = snapshot.tokenItems[i].aliasOf
          let usageCount = snapshot.tokenItems[i].impact.usageCount
          tdiv(display = "grid",
                grid_template_columns = "minmax(0, 1fr) auto",
                gap = "5px", align_items = "center",
                min_height = "24px",
                padding = "3px 5px", border = "1px solid " & border,
                border_radius = "4px"):
            span(font_size = "10px", color = textPrimary,
                  white_space = "nowrap", overflow = "hidden",
                  text_overflow = "ellipsis"):
              text itemKey & (if aliasOf.len > 0: " -> " & aliasOf else: "")
            span(font_size = "9px", color = textDim):
              text $usageCount & " uses"
      tdiv(display = "flex", flex_direction = "column", gap = "4px",
            `aria-label` = "Style diagnostics"):
        span(font_size = "10px", color = textMuted):
          text "Diagnostics"
        if snapshot.diagnostics.len == 0:
          span(font_size = "10px", color = textDim):
            text "No style diagnostics"
        else:
          for i in 0 ..< snapshot.diagnostics.len:
            let message = snapshot.diagnostics[i].message
            tdiv(display = "flex", align_items = "flex-start", gap = "6px",
                  padding = "4px 8px",
                  border_left = "2px solid " & gold,
                  background_color = "rgba(245,158,11,.08)",
                  border_radius = "0 4px 4px 0"):
              span(font_size = "10px", color = "#FCD34D",
                    line_height = "1.45"):
                text message
      tdiv(ref = promoteButton, role = "button", tabindex = "0",
            `aria-label` = "Promote local override for " & snapshot.property,
            padding = "5px 6px", border_radius = "4px",
            background_color = bgSurface, color = textMuted,
            font_size = "10px", text_align = "center", cursor = "pointer"):
        text "Promote local override"
  r.setAttribute(result, "aria-label", "Style class cascade token manager for " &
    snapshot.property)

  let localValue = demoScopeValue(snapshot.property, snapshot.finalValue,
    sscLocalInstance)
  let sharedValue = demoScopeValue(snapshot.property, snapshot.finalValue,
    sscSharedClass)
  let applyLocal = proc() = r.applyCssValue(vm, frame, snapshot.property,
    localValue)
  let applyShared = proc() = r.applyCssValue(vm, frame, snapshot.property,
    sharedValue)
  let createClass = proc() =
    discard vm.createStyleClass("preview-" & snapshot.property.replace("-", "-"),
      snapshot.property, snapshot.finalValue)
  let renameClass = proc() =
    let className =
      if snapshot.currentClassStack.len > 0: snapshot.currentClassStack[0].className
      else: "preview-" & snapshot.property
    discard vm.renameStyleClass(className, className & "-renamed")
  let duplicateClass = proc() =
    let className =
      if snapshot.currentClassStack.len > 0: snapshot.currentClassStack[0].className
      else: "preview-" & snapshot.property
    discard vm.duplicateStyleClass(className, className & "-copy")
  let detach = proc() = discard vm.detachStyleClass(snapshot.property)
  let promote = proc() =
    discard vm.promoteLocalOverride(snapshot.property, sscSharedClass)

  for button in [localScopeButton]:
    r.addEventListener(button, "click", applyLocal)
    r.addEventListener(button, "keydown", applyLocal)
  for button in [sharedScopeButton]:
    r.addEventListener(button, "click", applyShared)
    r.addEventListener(button, "keydown", applyShared)
  for button in [createClassButton]:
    r.addEventListener(button, "click", createClass)
    r.addEventListener(button, "keydown", createClass)
  for button in [renameClassButton]:
    r.addEventListener(button, "click", renameClass)
    r.addEventListener(button, "keydown", renameClass)
  for button in [duplicateClassButton]:
    r.addEventListener(button, "click", duplicateClass)
    r.addEventListener(button, "keydown", duplicateClass)
  for button in [detachButton]:
    r.addEventListener(button, "click", detach)
    r.addEventListener(button, "keydown", detach)
  for button in [promoteButton]:
    r.addEventListener(button, "click", promote)
    r.addEventListener(button, "keydown", promote)

proc renderDesignSystemImpactPanel[R, E](r: R; vm: EditorVM; frame: E;
    selected: ElementRef): E =
  type ImpactRow = object
    editor: CSSPropertyEditorVM
    impact: SourceScopeImpact

  var impactRows: seq[ImpactRow] = @[]
  for editor in vm.inspector.propertyEditors.val:
    if editor.impactSummaries.len > 0:
      impactRows.add ImpactRow(editor: editor, impact: editor.impactSummaries[0])
  let sharedEditors = vm.sharedDesignPropertyEditors()
  let commitPreviews = vm.sharedDesignCommitPreviews()
  discard frame
  discard selected
  result = ui(r):
    details(`aria-label` = "Source scope property impact"):
      summary(cursor = "pointer", color = textSecondary, font_size = "10px",
              font_weight = "600",
              padding = "4px 0"):
        text "Source impact"
      tdiv(display = "flex", flex_direction = "column", gap = "5px",
            padding = "6px", border = "1px solid " & border,
            border_radius = "5px", background_color = "#0F172A"):
        span(font_size = "9px", color = textDim):
          text "Scope impact: use the row scope selector for local, fixture, class, API, or token ownership."
        tdiv(display = "grid",
              grid_template_columns = "repeat(3, minmax(0, 1fr))",
              gap = "4px"):
          tdiv(display = "flex", flex_direction = "column", gap = "1px",
                padding = "4px", border = "1px solid " & borderFaint,
                border_radius = "4px"):
            span(font_size = "8px", color = textDim):
              text "Scoped props"
            span(font_size = "11px", font_weight = "700", color = textPrimary):
              text $impactRows.len
          tdiv(display = "flex", flex_direction = "column", gap = "1px",
                padding = "4px", border = "1px solid " & borderFaint,
                border_radius = "4px"):
            span(font_size = "8px", color = textDim):
              text "Shared"
            span(font_size = "11px", font_weight = "700", color = gold):
              text $sharedEditors.len
          tdiv(display = "flex", flex_direction = "column", gap = "1px",
                padding = "4px", border = "1px solid " & borderFaint,
                border_radius = "4px"):
            span(font_size = "8px", color = textDim):
              text "Staged"
            span(font_size = "11px", font_weight = "700", color = green):
              text $commitPreviews.len
        if impactRows.len == 0:
          span(font_size = "10px", color = textDim):
            text "This selection has no source-backed property scopes."
        else:
          for i in 0 ..< min(impactRows.len, 3):
            let row = impactRows[i]
            let editor = row.editor
            let impact = row.impact
            tdiv(display = "grid",
                  grid_template_columns = "minmax(0, 1fr) auto",
                  gap = "5px", align_items = "center",
                  padding = "3px 6px",
                  min_height = "22px",
                  border = "1px solid " & borderFaint,
                  border_radius = "4px",
                  background_color = bgCard):
              tdiv(display = "flex", flex_direction = "column", gap = "1px",
                    min_width = "0"):
                span(font_size = "11px", color = textPrimary,
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text editor.property & " = " & editor.value.canonical
                span(font_size = "10px", color = gold,
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text impact.summary
                span(font_size = "9px", color = textDim,
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text impact.ownerLabel & " | " &
                      impact.riskLevel.sourceScopeRiskLabel() &
                    " risk" & (
                      if impact.schemaKey.len > 0: " | " &
                      impact.schemaKey else: "")
              tdiv(role = "note",
                    `aria-label` = "Use the property row source scope selector for " &
                      editor.property,
                    padding = "3px 5px", border_radius = "4px",
                    background_color = bgSurface, color = gold,
                    font_size = "9px"):
                text $editor.sourceScopeChoices.len & " scopes"
        if impactRows.len > 3:
          span(font_size = "10px", color = textDim):
            text "+" & $(impactRows.len - 3) & " more source-backed properties"
        tdiv(display = "flex", flex_direction = "column", gap = "4px",
              `aria-label` = "Shared design-system editors"):
          span(font_size = "10px", font_weight = "600",
                color = textSecondary):
            text "Shared editors"
          if sharedEditors.len == 0:
            span(font_size = "10px", color = textDim):
              text "No shared design-system editor is available for this selection."
          else:
            for i in 0 ..< min(sharedEditors.len, 4):
              let editor = sharedEditors[i]
              let scope = editor.sourceScope.kind.sourceScopeChoiceLabel()
              tdiv(display = "grid",
                    grid_template_columns = "minmax(0, 1fr) auto",
                    gap = "6px", align_items = "center",
                    padding = "5px 6px",
                    border = "1px solid " & border,
                    border_radius = "5px",
                    background_color = bgSidebar):
                tdiv(display = "flex", flex_direction = "column", gap = "2px",
                      min_width = "0"):
                  span(font_size = "10px", color = textPrimary,
                        white_space = "nowrap", overflow = "hidden",
                        text_overflow = "ellipsis"):
                    text editor.property & " | " &
                      editor.category.sharedDesignCategoryLabel()
                  span(font_size = "9px", color = textDim,
                        white_space = "nowrap", overflow = "hidden",
                        text_overflow = "ellipsis"):
                    text scope & " | " &
                      (if editor.status ==
                          sdesEditable: "editable" else: editor.readOnlyReason)
                span(font_size = "9px",
                      color = (if editor.status ==
                          sdesEditable: green else: gold)):
                  text $editor.flowCapabilities.len & " flows"
        tdiv(display = "flex", flex_direction = "column", gap = "4px",
              `aria-label` = "Scope-specific commit previews"):
          span(font_size = "10px", font_weight = "600",
                color = textSecondary):
            text "Commit preview"
          if commitPreviews.len == 0:
            span(font_size = "10px", color = textDim):
              text "No shared source diff is staged."
          else:
            for i in 0 ..< commitPreviews.len:
              let preview = commitPreviews[i]
              tdiv(`data-shared-design-commit-preview` = preview.property,
                    display = "flex", flex_direction = "column", gap = "3px",
                    padding = "5px 6px",
                    border = "1px solid " & border,
                    border_radius = "5px",
                    background_color = bgSidebar):
                span(font_size = "10px", color = textPrimary,
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text preview.property & " | " &
                    preview.sourceScope.sourceScopeChoiceLabel()
                span(font_size = "9px", color = gold,
                      font_family = "monospace", white_space = "pre-wrap",
                      overflow_wrap = "anywhere"):
                  text preview.sourceDiff
                span(font_size = "9px", color = textDim):
                  text "Affected components: " & (
                    if preview.affectedComponents.len > 0:
                    preview.affectedComponents.join(", ")
                  else:
                    "none") & " | affected stories: " &
                    $preview.affectedStories.len
                span(font_size = "9px", color = textDim):
                  text preview.previewStateLabel
                span(font_size = "9px", color = textDim):
                  text "Regeneration: " &
                    (if preview.regenerationRequired: "required" else: "not required") &
                    " | reload: " &
                    (if preview.fullReloadRequired: "full"
                    elif preview.reloadRequired: "affected"
                    else: "not required")
  r.setAttribute(result, "data-design-system-impact", "true")
  r.setAttribute(result, "data-design-system-property-count", $impactRows.len)
  r.setAttribute(result, "data-source-scope-impact", "true")
  r.setAttribute(result, "data-source-scope-impact-count", $impactRows.len)
  r.setAttribute(result, "data-shared-design-editor-count", $sharedEditors.len)
  r.setAttribute(result, "data-shared-design-commit-preview-count",
    $commitPreviews.len)

proc populateInspectorContent[R, E](r: R; vm: EditorVM; frame, content: E;
    clipboard: StyleClipboard) =
  r.clearChildren(content)
  if vm.inspector.hasElement.val:
    let selected = vm.inspector.selectedElement.val
    let sourceLabel =
      if selected.sourceFile.len > 0:
        selected.sourceFile & ":" & $selected.sourceLine
      else:
        "runtime selection"
    let elementLabel =
      selected.tag
    let sizeLabel =
      if fallbackPropertyValue(selected, "width", "").len > 0:
        roundedPxValue(fallbackPropertyValue(selected, "width", "")) & " × " &
          roundedPxValue(fallbackPropertyValue(selected, "height", ""))
      else:
        "auto"
    let summary = ui(r):
      tdiv(display = "grid",
            grid_template_columns = "minmax(0, 1fr) auto",
            align_items = "center", gap = "8px",
            padding = "8px 10px",
            border = "1px solid " & borderFaint,
            border_radius = "6px",
            background_color = "#0F172A"):
        tdiv(display = "flex", flex_direction = "column", gap = "3px",
              min_width = "0"):
          span(font_size = "9px", font_weight = "700", color = textSecondary,
                letter_spacing = "0.5px",
                text_transform = "uppercase"):
            text "Selection"
          span(font_size = "13px", font_weight = "700",
                color = textPrimary, font_family = "monospace",
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text elementLabel
          span(font_size = "10px", color = textMuted,
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis"):
            text sourceLabel
        tdiv(display = "flex", flex_direction = "column",
              align_items = "flex-end", gap = "3px"):
          span(font_size = "10px", color = textSecondary,
                font_family = "monospace", font_weight = "600",
                line_height = "1.2"):
            text sizeLabel
          span(font_size = "9px", color = accent, font_weight = "700",
                letter_spacing = "0.5px",
                text_transform = "uppercase",
                padding = "2px 6px",
                border_radius = "10px",
                background_color = "rgba(59, 130, 246, 0.15)"):
            text "selected"
    r.appendChild(content, summary)

    let active = vm.inspector.activeSection.val
    let expanded = active in vm.inspector.expandedSections.val
    let heading = ui(r):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            position = "sticky", top = "0",
            z_index = "1",
            padding = "5px 0",
            background_color = bgSidebar,
            pointer_events = "none"):
        span(font_size = "11px", font_weight = "700", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text sectionTitle(active)
    r.setAttribute(heading, "aria-expanded", if expanded: "true" else: "false")
    r.setStyle(heading, "pointer-events", "none")
    r.appendChild(content, heading)

    if vm.inspector.editDiagnostics.val.len > 0:
      let diagnosticsBox = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "4px",
              padding = "8px", border = "1px solid #F97316",
              border_radius = "5px", background_color = "#2D1606"):
          for i in 0 ..< vm.inspector.editDiagnostics.val.len:
            let diagnostic = vm.inspector.editDiagnostics.val[i]
            span(font_size = "10px", color = "#FDBA74"):
              text diagnostic.property & ": " & diagnostic.message
      r.setAttribute(diagnosticsBox, "data-isonim-edit-diagnostics", "true")
      r.appendChild(content, diagnosticsBox)

    if not expanded:
      let collapsed = ui(r):
        tdiv(padding = "10px", border = "1px solid " & border,
              border_radius = "6px", background_color = bgBase,
              color = textDim, font_size = "11px"):
          text "Section collapsed"
      r.appendChild(content, collapsed)
      return

    if active == isLayout:
      let layoutAccordion = ui(r):
        details(`aria-label` = "Show layout auto grid constraint controls"):
          summary(cursor = "pointer", color = textMuted, font_size = "10px",
                  padding = "2px 0"):
            text "CSS Layout / Grid / Flex / Constraints"
      r.appendChild(layoutAccordion, renderLayoutControlSummary[R, E](r, vm,
        frame, selected))
      r.appendChild(content, layoutAccordion)

    if active == isSpacing:
      let boxAccordion = ui(r):
        details(open = "open", `aria-label` = "Show box model controls"):
          summary(cursor = "pointer", color = textMuted, font_size = "10px",
                  padding = "2px 0"):
            text "Box model"
      r.appendChild(boxAccordion, renderBoxModelSummary[R, E](r, selected))
      r.appendChild(content, boxAccordion)

    if active == isState:
      let pseudoStates = ["hover", "focus", "active", "disabled",
        "focus-visible", "focus-within"]
      let stateBox = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "6px",
              padding = "4px 0"):
          tdiv(font_size = "9px", color = textDim,
                text_transform = "uppercase", letter_spacing = "0.5px"):
            text "Pseudo-states"
          tdiv(display = "flex", flex_wrap = "wrap", gap = "3px"):
            for state in pseudoStates:
              tdiv(role = "button", tabindex = "0",
                    `aria-label` = "Toggle :" & state & " preview",
                    `data-inspector-pseudo-state` = state,
                    display = "inline-flex", align_items = "center",
                    justify_content = "center",
                    height = "22px", padding = "0 8px",
                    border = "1px solid " & border,
                    border_radius = "11px",
                    background_color = "#0F172A",
                    color = textMuted, font_size = "10px",
                    font_family = "monospace",
                    cursor = "pointer",
                    white_space = "nowrap"):
                text ":" & state
          tdiv(font_size = "10px", color = textDim,
                line_height = "1.4",
                padding_top = "2px"):
            text "Toggle a pseudo-state to preview hover, focus, active, " &
              "or disabled styling on the selected element."
          tdiv(font_size = "9px", color = textDim,
                text_transform = "uppercase", letter_spacing = "0.5px",
                padding_top = "12px"):
            text "Common combinations"
          tdiv(display = "flex", flex_direction = "column", gap = "4px",
                font_size = "10px"):
            for combo in [
              (":hover + :focus-visible", "Keyboard + pointer affordance"),
              (":active + :hover", "Pressed-while-hovered"),
              (":disabled", "Read-only / non-interactive"),
              (":focus-within", "Container holds focused descendant")
            ]:
              tdiv(display = "grid",
                    grid_template_columns = "168px minmax(0, 1fr)",
                    align_items = "center", gap = "8px",
                    padding = "3px 4px",
                    border_radius = "3px"):
                span(color = textSecondary,
                      font_family = "monospace",
                      white_space = "nowrap"):
                  text combo[0]
                span(color = textDim,
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text combo[1]
      r.appendChild(content, stateBox)

    if active == isSource:
      let cascadeBox = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "6px",
              padding = "4px 0"):
          tdiv(display = "grid",
                grid_template_columns = "116px minmax(0, 1fr) 56px",
                align_items = "center", gap = "6px",
                font_size = "9px", color = textDim,
                text_transform = "uppercase",
                letter_spacing = "0.5px"):
            span(): text "Property"
            span(): text "Computed"
            span(text_align = "right"): text "Origin"
          tdiv(display = "flex", flex_direction = "column", gap = "2px",
                font_size = "10px"):
            for i in 0 ..< selected.properties.len:
              let prop = selected.properties[i]
              let originColor =
                case prop.origin
                of poThemeToken: "#FBBF24"
                of poConstant: "#FBBF24"
                of poInherited: textDim
                else: accent
              let originBg =
                case prop.origin
                of poThemeToken: "rgba(251, 191, 36, 0.12)"
                of poConstant: "rgba(251, 191, 36, 0.08)"
                else: "rgba(59, 130, 246, 0.12)"
              tdiv(display = "grid",
                    grid_template_columns = "116px minmax(0, 1fr) 56px",
                    align_items = "center", gap = "6px",
                    padding = "3px 4px",
                    border_radius = "3px"):
                span(color = textSecondary,
                      font_family = "monospace",
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text prop.name
                span(color = textPrimary,
                      font_family = "monospace",
                      white_space = "nowrap", overflow = "hidden",
                      text_overflow = "ellipsis"):
                  text prop.value
                span(color = originColor,
                      background_color = originBg,
                      font_size = "9px",
                      font_weight = "700",
                      letter_spacing = "0.4px",
                      text_transform = "uppercase",
                      padding = "2px 6px",
                      border_radius = "10px",
                      text_align = "center",
                      white_space = "nowrap"):
                  text originLabel(prop.origin)
          tdiv(font_size = "10px", color = textDim,
                line_height = "1.4",
                padding_top = "2px"):
            text "Open Source / Cascade below for the full origin chain."
      r.appendChild(content, cascadeBox)

    for (propName, fallback) in sectionProperties(active):
      let prop = propertyInfo(selected, propName, fallback)
      r.appendChild(content,
        renderRichPropertyControl[R, E](r, vm, frame, clipboard, prop, fallback))

    let rawAccordion = ui(r):
      details(`aria-label` = "Show raw CSS controls"):
        summary(cursor = "pointer", color = textMuted, font_size = "10px",
                padding = "2px 0"):
          text "Raw CSS"
    r.appendChild(rawAccordion,
      renderRawCssEditor[R, E](r, vm, frame, selected, active))
    r.appendChild(content, rawAccordion)
    let sourceAccordion = ui(r):
      details(`aria-label` = "Show source and cascade controls"):
        summary(cursor = "pointer", color = textMuted, font_size = "10px",
                padding = "2px 0"):
          text "Source / Cascade"
    r.appendChild(sourceAccordion, renderStyleManagerPanel[R, E](r, vm,
      frame, selected))
    r.appendChild(sourceAccordion, renderElementTree[R, E](r, vm, frame, selected))
    r.appendChild(content, sourceAccordion)

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

proc populateInspectorImpact[R, E](r: R; vm: EditorVM; frame,
    impactContent: E) =
  r.clearChildren(impactContent)
  if vm.inspector.hasElement.val:
    let selected = vm.inspector.selectedElement.val
    r.appendChild(impactContent, renderDesignSystemImpactPanel[R, E](r, vm,
      frame, selected))

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
  for section in vm.inspector.visibleSections.val:
    let label = sectionTitle(section)
    let fullTitle = sectionFullTitle(section)
    let active = vm.inspector.activeSection.val == section
    let tab = ui(r):
      tdiv(role = "tab", tabindex = "0",
            display = "flex", align_items = "center",
            justify_content = "center",
            height = "26px",
            min_width = "40px",
            padding = "0 10px", font_size = "11px", font_weight = "600",
            cursor = "pointer", white_space = "nowrap",
            color = (if active: textPrimary else: textMuted),
            background_color = "transparent",
            border_bottom = "2px solid " &
              (if active: accent else: "transparent"),
            margin_bottom = "-1px",
            transition = "color 0.12s, border-color 0.12s"):
        text label
    r.setAttribute(tab, "aria-label", "Show " & label & " edit controls")
    r.setAttribute(tab, "data-inspector-section", fullTitle.toLowerAscii())
    let activate = r.inspectorSectionHandler(vm, frame, tabs, content,
      clipboard, section)
    r.addEventListener(tab, "pointerdown", activate)
    r.addEventListener(tab, "click", activate)
    r.addEventListener(tab, "keydown", activate)
    r.appendChild(tabs, tab)

proc populateInspectorManualBody*[R, E](r: R; target: E; vm: EditorVM;
    frame: E) =
  ## Fills ``target`` (the right-sidebar Manual tab body) with the rich
  ## inspector content — header (clipboard chip + Save/Revert + width
  ## controls + search), then the scroll-area with per-section content
  ## and the design-system-impact panel.
  ##
  ## The 12-section sub-tab bar (Layout / Size / Space / …) is owned
  ## by the caller (``shell.nim``) so the existing sidebar tab markup
  ## stays as ``target.children[0]`` — this helper appends AFTER the
  ## tab bar.
  ##
  ## ``frame`` is the editable preview iframe. For the sidebar mount
  ## this is a placeholder element; the live-preview helpers fall back
  ## to ``document.querySelector('iframe[data-component-edit-frame]')``
  ## at runtime when the explicit reference doesn't carry a
  ## ``contentDocument``.
  var saveButton: E
  var revertButton: E
  var narrowButton: E
  var resetWidthButton: E
  var widenButton: E
  var searchInput: E
  let clipboard = StyleClipboard()
  # Header row (Design/Proto/Inspect chip + narrow/reset/widen +
  # Revert/Save). The width buttons are the same control set the
  # Assistant tab's chat panel exposes — duplicated here so the
  # affordance is available from whichever tab the user is currently
  # looking at (only one tab body is visible at a time, so duplicate
  # ``data-isonim-focus-id`` markers don't collide in practice).
  let header = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          height = "32px", min_height = "32px",
          padding = "0 6px",
          background_color = bgCard,
          border_bottom = "1px solid " & border):
      tdiv(display = "flex", align_items = "center", gap = "2px",
            background_color = "#0F172A",
            border = "1px solid " & border,
            border_radius = "3px",
            padding = "1px"):
        span(padding = "2px 6px",
              border_radius = "3px",
              background_color = accent,
              color = textPrimary,
              font_size = "10px",
              font_weight = "700"):
          text "Design"
        span(padding = "2px 6px",
              color = textDim,
              font_size = "10px",
              font_weight = "600"):
          text "Proto"
        span(padding = "2px 6px",
              color = textDim,
              font_size = "10px",
              font_weight = "600"):
          text "Inspect"
      tdiv(display = "flex", gap = "3px", flex_wrap = "wrap",
            justify_content = "flex-end"):
        tdiv(ref = narrowButton, role = "button", tabindex = "0",
              `aria-label` = "Narrow right panel",
              width = "22px", height = "22px",
              display = "flex", align_items = "center",
              justify_content = "center",
              border_radius = "4px",
              font_size = "10px", cursor = "pointer",
              background_color = bgSurface, color = textMuted):
          text "-"
        tdiv(ref = resetWidthButton, role = "button", tabindex = "0",
              `aria-label` = "Reset right panel width",
              width = "22px", height = "22px",
              display = "flex", align_items = "center",
              justify_content = "center",
              border_radius = "4px",
              font_size = "10px", cursor = "pointer",
              background_color = bgSurface, color = textMuted):
          text "1"
        tdiv(ref = widenButton, role = "button", tabindex = "0",
              `aria-label` = "Widen right panel",
              width = "22px", height = "22px",
              display = "flex", align_items = "center",
              justify_content = "center",
              border_radius = "4px",
              font_size = "10px", cursor = "pointer",
              background_color = bgSurface, color = textMuted):
          text "+"
        tdiv(ref = revertButton, role = "button", tabindex = "0",
              padding = "3px 6px", border_radius = "4px",
              font_size = "10px", cursor = "pointer",
              background_color = bgSurface, color = textMuted):
          text "Revert"
        tdiv(ref = saveButton, role = "button", tabindex = "0",
              padding = "3px 6px", border_radius = "4px",
              font_size = "10px", font_weight = "600", cursor = "pointer",
              background_color = accent, color = textPrimary):
          text "Save"
  r.appendChild(target, header)

  let searchRow = ui(r):
    tdiv(display = "grid",
          grid_template_columns = "minmax(0, 1fr)",
          align_items = "center",
          gap = "3px",
          padding = "5px 6px",
          border_bottom = "1px solid " & border):
      input(ref = searchInput,
            class = "editor-input",
            height = "22px",
            background_color = "#0F172A",
            border = "1px solid " & border,
            border_radius = "3px",
            padding = "0 6px",
            font_size = "11px",
            color = textPrimary,
            outline = "none",
            min_width = "0",
            `aria-label` = "Search inspector sections",
            placeholder = "Search")
  r.appendChild(target, searchRow)

  r.setAttribute(saveButton, "aria-label", "Save inspector source edits")
  r.setAttribute(revertButton, "aria-label", "Revert inspector source edits")
  r.setAttribute(narrowButton, "data-isonim-focus-id", "right-panel-narrow")
  r.setAttribute(resetWidthButton, "data-isonim-focus-id", "right-panel-reset")
  r.setAttribute(widenButton, "data-isonim-focus-id", "right-panel-widen")
  r.setAttribute(narrowButton, "data-right-panel-resize-affordance", "narrow")
  r.setAttribute(resetWidthButton, "data-right-panel-resize-affordance", "reset")
  r.setAttribute(widenButton, "data-right-panel-resize-affordance", "widen")
  let save = proc() =
    discard vm.runEditorCommand(eckSave)
    r.commitLivePreviewStyles(frame)
  let revert = proc() =
    r.revertLivePreviewStyles(frame)
    discard vm.runEditorCommand(eckRevert)
  let search = r.sectionSearchHandler(vm, searchInput)
  r.setInputValue(searchInput, vm.inspector.sectionSearch.val)
  r.addEventListener(searchInput, "input", search)
  r.addEventListener(searchInput, "change", search)
  r.addEventListener(searchInput, "focus", rememberPanelFocus(vm,
    "section-search"))
  r.setAttribute(searchInput, "data-isonim-focus-id", "section-search")
  r.addEventListener(narrowButton, "click", proc() = vm.adjustRightPanelWidth(-40))
  r.addEventListener(narrowButton, "keydown", proc() = vm.adjustRightPanelWidth(-40))
  r.addEventListener(narrowButton, "focus", rememberPanelFocus(vm,
    "right-panel-narrow"))
  r.addEventListener(resetWidthButton, "click", proc() = vm.setRightPanelWidth(260))
  r.addEventListener(resetWidthButton, "keydown", proc() = vm.setRightPanelWidth(260))
  r.addEventListener(resetWidthButton, "focus", rememberPanelFocus(vm,
    "right-panel-reset"))
  r.addEventListener(widenButton, "click", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "keydown", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "focus", rememberPanelFocus(vm,
    "right-panel-widen"))
  r.addEventListener(saveButton, "click", save)
  r.addEventListener(saveButton, "keydown", save)
  r.addEventListener(revertButton, "click", revert)
  r.addEventListener(revertButton, "keydown", revert)

  let inspectorBody = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          padding = "6px", overflow_y = "auto", overflow_x = "hidden",
          gap = "6px", min_width = "0")
  r.appendChild(target, inspectorBody)

  let content = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "6px",
          min_width = "0")
  r.appendChild(inspectorBody, content)

  let impactContent = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          padding_top = "6px", min_width = "0",
          border_top = "1px solid " & border)
  r.appendChild(inspectorBody, impactContent)
  r.populateInspectorImpact(vm, frame, impactContent)

  let inspectorRoot = target
  createRenderEffect proc() =
    discard vm.activeView.val
    r.populateInspectorImpact(vm, frame, impactContent)
    r.populateInspectorContent(vm, frame, content, clipboard)
    r.restoreInspectorFocus(inspectorRoot, vm)
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
  ## M-EVP-6: per-view inner toolbar (breadcrumb + Edit/Comment/View
  ## mode buttons) and the inner status caption row removed. The
  ## canonical chrome bar (above the view stack) hosts the mode chips
  ## now; the component-edit body starts directly at the editable
  ## preview iframe.
  var projectFrame: E
  var lastSrcdoc = ""
  var lastRestoredSelection = ""

  let container = ui(r):
    tdiv(class = "editor-preview",
          `data-component-edit` = "true",
          flex = "1", display = "flex",
          min_width = "0", height = "100%",
          background_color = bgBase)

  let preview = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          min_width = "0"):
      tdiv(flex = "1", overflow = "auto", background_color = bgPreview,
            padding = "24px"):
        iframe(ref = projectFrame,
          title = "Editable component preview",
          width = "100%",
          height = "480",
          border = "0",
          background_color = "#FFFFFF",
          `data-component-edit-frame` = "true")

  # The rich property inspector now lives in the right sidebar's
  # Manual tab (``shell.nim``), not as a centre-column panel. The
  # component-edit view owns only the editable preview iframe; the
  # ``installPreviewSelectionBridge`` window-event handler still
  # routes ``isonim-preview-element-selected`` from the iframe into
  # ``vm.inspector``, which the sidebar inspector reads reactively.
  r.appendChild(container, preview)

  installPreviewSelectionBridge[R, E](r, projectFrame, vm)

  createRenderEffect proc() =
    let previewState = vm.preview.current.val
    let reloadGeneration = vm.livePreviewReloadGeneration.val
    let metadata = previewState.metadata
    # CHRM-M5b: the editable preview iframe is an HTML-only surface
    # (the editor injects an HTML selection bridge into the project
    # documentHtml via `editablePreviewDocument`). The HTML iframe
    # is meaningful only for the Web backend; for every non-Web
    # backend it would misrepresent the actual rendered output,
    # mirroring the CHRM-M5 invariant locked in for page_preview /
    # foundations_page / component_detail. Non-Web blanks the
    # srcdoc; the canvas-mounted editing surface lives in the
    # detail view (component_detail.nim) — the editable variant
    # is intentionally Web-only for now.
    let nextSrcdoc =
      if vm.platform.val != pbWeb:
        ""
      else:
        let previewDocument = componentEditPreviewDocument(previewState,
          vm.inspector.selectedElement.val)
        if vm.editMode.val == emView:
          previewDocument & "\n<!-- isonim-reload:" & $reloadGeneration & " -->"
        else:
          editablePreviewDocument(previewDocument, metadata, vm.editMode.val) &
            "\n<!-- isonim-reload:" & $reloadGeneration & " -->"
    var srcdocChanged = false
    if nextSrcdoc != lastSrcdoc:
      lastSrcdoc = nextSrcdoc
      srcdocChanged = true
      r.setAttribute(projectFrame, "srcdoc", nextSrcdoc)
    r.setStyle(projectFrame, "min-height", "320px")
    r.setStyle(projectFrame, "overflow", "hidden")
    let selectedId = vm.inspector.selectedElement.val.id
    if selectedId.len > 0 and (srcdocChanged or selectedId !=
        lastRestoredSelection):
      lastRestoredSelection = selectedId
      r.restorePreviewSelection(projectFrame, selectedId)

  container
