## IsoNim Editor — Component Edit View.
##
## Source-backed component editing: a real project preview iframe on the left
## and a functional inspector on the right.
##
## The inspector itself is the shell's section inspector (`shell.nim`,
## `views/widgets/*`). The older "Manual" inspector body that used to live
## here (`populateInspectorManualBody` and its row/affordance helpers,
## including a Save/Revert header) was never mounted by the current shell
## and has been removed; see the UX-M3 save-pipeline record.

import isonim/editor/views/view_lifecycle
import std/[strutils, math, strformat]

import isonim/core/[signals, computation, owner]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/preview_identity
import isonim/editor/types
import isonim/editor/views/preview_mount
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/scene_graph_walk
import isonim/editor/style_provenance_decode

const
  bgBase = "#0B1120"
  bgPreview = "#0D1525"

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

  # The inspector's editable-property list, as a JS array literal. Built from
  # the Nim const rather than typed twice: the bridge reads these off
  # `getComputedStyle` and the editor turns them back into properties, so the
  # two sides drifting would silently empty rows rather than fail.
  var editablePropsJs = "["
  for i, name in inspectorEditableCssProperties:
    if i > 0: editablePropsJs.add ","
    editablePropsJs.add "\"" & name & "\""
  editablePropsJs.add "]"

  let bridge = """
<script>var ISONIM_EDITABLE_PROPS = """ & editablePropsJs & """;</script>
<style id="isonim-editor-selection-paint-style">
  [data-isonim-selected="true"] {
    outline: 2px solid #3B82F6 !important;
    outline-offset: 2px !important;
    box-shadow: 0 0 0 4px rgba(59,130,246,.22) !important;
  }
  [data-isonim-hovered="true"] {
    outline: 1px dashed rgba(59,130,246,.75) !important;
    outline-offset: 3px !important;
  }
</style>
<style id="isonim-editor-selection-style">
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
  #isonim-editor-selection-breadcrumb > span[data-drill] {
    background: rgba(148,163,184,.28);
    color: #E2E8F0;
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
__ISONIM_SCENE_GRAPH_WALK__
</script>
<script>
(function () {
  const fallbackSource = "__ISONIM_SOURCE__";
  const fallbackLine = "__ISONIM_LINE__";
  const editorMode = "__ISONIM_MODE__";
  const bridgeDocument = document;
  const bridgeFrame = window.frameElement;
  const parentListeners = [];
  let bridgeDisposed = false;
  let releaseOwner = null;
  function disposeParentBridge() {
    if (bridgeDisposed) return;
    bridgeDisposed = true;
    for (const [type, listener] of parentListeners)
      parent.removeEventListener(type, listener);
    parentListeners.length = 0;
    window.removeEventListener('pagehide', disposeParentBridge);
    window.removeEventListener('unload', disposeParentBridge);
    if (releaseOwner) releaseOwner();
    if (bridgeFrame && bridgeFrame.__isonimEmbeddedBridgeCleanup === disposeParentBridge)
      delete bridgeFrame.__isonimEmbeddedBridgeCleanup;
  }
  function bindParent(type, callback) {
    if (bridgeDisposed) return;
    const listener = function (event) {
      if (bridgeDisposed || !bridgeFrame || !bridgeFrame.isConnected ||
          bridgeFrame.__isonimViewDisposed ||
          bridgeFrame.contentDocument !== bridgeDocument) {
        disposeParentBridge(); return;
      }
      if (!bridgeFrame.getClientRects().length ||
          parent.getComputedStyle(bridgeFrame).visibility === 'hidden') return;
      callback(event);
    };
    parentListeners.push([type, listener]);
    parent.addEventListener(type, listener);
  }
  if (bridgeFrame) {
    if (bridgeFrame.__isonimEmbeddedBridgeCleanup)
      bridgeFrame.__isonimEmbeddedBridgeCleanup();
    bridgeFrame.__isonimEmbeddedBridgeCleanup = disposeParentBridge;
    if (parent.__isonimViewCleanup)
      releaseOwner = parent.__isonimViewCleanup(bridgeFrame, disposeParentBridge);
  }
  window.addEventListener('pagehide', disposeParentBridge);
  window.addEventListener('unload', disposeParentBridge);
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
  // Repeat-click drill state. `target` is the element the pointer is
  // actually over (the deepest selectable node under it), `chain` is that
  // element's ancestor stack captured when the drill started, and `index`
  // is how far up `chain` the repeated clicks have walked (-1 = not
  // clicked yet).
  //
  // Two properties matter, and both used to be missing:
  //
  //  * The index is read against the chain it was captured with, never
  //    against a freshly walked one, so it can never end up pointing at an
  //    element from a different chain.
  //  * Nothing here is timed. The drill resets when the pointer moves to a
  //    different element -- not when clicks arrive more than N ms apart and
  //    not when the cursor wobbles by more than N px -- so which element a
  //    click selects depends only on where the pointer is, never on how
  //    fast the user is clicking.
  let drill = { target: null, chain: [], index: -1 };
  let styleClipboard = null;
  // SGR: the element walk is NOT defined here. One definition lives in
  // `scene_graph_walk.nim` and is injected above; this bridge and the
  // editor's parent-side scene-graph reader both instantiate THAT source, so
  // an element's id is the same string on both sides of the iframe boundary.
  // Two hand-matched copies is what made the panel disagree with itself.
  const walk = window.__isonimSceneGraphWalk(document, {
    fallbackSource: fallbackSource,
    fallbackLine: fallbackLine,
    editorIds: editorIds
  });
  const isElement = walk.isElement;
  const isSelectable = walk.isSelectable;
  const stableSelector = walk.stableSelector;
  const parseSource = walk.parseSource;
  const sourceKeyFor = walk.sourceKeyFor;
  const cssPath = walk.cssPath;
  const identityFor = walk.identityFor;
  const ancestorStack = walk.ancestorStack;
  const layerTree = walk.layerTree;
  const schemaKeyFor = walk.schemaKeyFor;
  function drillRestart(leaf) {
    drill = { target: leaf, chain: ancestorStack(leaf), index: -1 };
    return drill;
  }
  function drillAt(node) {
    const leaf = ancestorStack(node)[0] || null;
    if (!leaf) return null;
    // Restart when the pointer is over a different element, and also when
    // the captured chain has gone stale -- the preview re-renders on its
    // own (hot reload, a reactive update), and a retained index must never
    // resolve against detached nodes.
    if (drill.target !== leaf || !drill.chain.length ||
        !drill.chain[0].isConnected) return drillRestart(leaf);
    return drill;
  }
  function drillPosition(el) {
    // Where `el` sits in the live drill, or -1 when it is not part of it.
    return drill.chain.length > 1 ? drill.chain.indexOf(el) : -1;
  }
  function drillSync(el) {
    // Keep the drill honest about what is actually selected, whichever
    // route selected it (keyboard, scene graph, breadcrumb, restore).
    const at = drill.chain.indexOf(el);
    if (at >= 0) drill.index = at;
    else drill = { target: el, chain: ancestorStack(el), index: 0 };
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
    const state = drillAt(event.target);
    if (!state) return null;
    // `event.detail === 2` is the second click of a double-click. That
    // click belongs to the dblclick gesture (inline text editing), not to
    // the climb, so the climb does not consume it. Letting both handlers
    // act on it is what made rapid clicking oscillate: the click advanced
    // the climb while the dblclick yanked the selection back to the leaf.
    if (event.detail !== 2) {
      // The climb only ever moves outwards, and stops at the outermost
      // element rather than wrapping back to the leaf. Wrapping would put
      // an unrequested jump from the outermost element to the innermost
      // into the middle of a click burst -- the same "goes berserk" the
      // drill is supposed to avoid. The breadcrumb reports the position so
      // "nothing moved" reads as "you are at the top", not as a dead click.
      state.index = Math.min(state.index + 1, state.chain.length - 1);
    }
    return state.chain[Math.max(state.index, 0)];
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
    // Where the repeat-click climb currently is. Without this the operator
    // has no way to tell a climb that has reached the outermost element
    // from a click that did nothing.
    const position = drillPosition(el);
    if (position > 0) {
      const chip = document.createElement('span');
      chip.dataset.drill = 'position';
      chip.textContent = '↑ ' + (position + 1) + '/' + drill.chain.length +
        (position === drill.chain.length - 1 ? ' top' : '');
      crumb.appendChild(chip);
    }
    crumb.style.left = Math.max(6, Math.min(rect.left, window.innerWidth - 280)) + 'px';
    crumb.style.top = Math.min(window.innerHeight - 30, rect.bottom + 8) + 'px';
    crumb.hidden = false;
  }
  function selectElement(target) {
    const el = target;
    if (!el || el === document.documentElement || el === document.body) return;
    // Selecting something else ends inline text editing. The click handler
    // calls preventDefault, so the browser never moves focus by itself and
    // an element left editing by a double-click would otherwise stay
    // editable for the rest of the session. `blur` runs the commit path.
    document.querySelectorAll('[data-isonim-inline-editing]').forEach((node) => {
      if (node !== el && node.blur) node.blur();
    });
    document.querySelectorAll('[data-isonim-selected="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-selected');
    });
    el.setAttribute('data-isonim-selected', 'true');
    window.__isonimSelectedElement = el;
    drillSync(el);
    placeHandles(el);
    const source = parseSource(el.getAttribute('data-isonim-src'));
    // Selection/hover chrome is editor-owned CSS, not a document property.
    // Computed style objects are live: eagerly copy every value while that
    // paint stylesheet is disabled, retaining overlay layout, then restore it
    // before notifying the inspector.
    const chromeSheet = document.getElementById('isonim-editor-selection-paint-style').sheet;
    const chromeDisabled = chromeSheet.disabled;
    let detail;
    try {
      chromeSheet.disabled = true;
      const style = window.getComputedStyle(el);
      const rect = el.getBoundingClientRect();
      const stack = ancestorStack(el).reverse().map(stableSelector);
      const stackIds = ancestorStack(el).reverse().map(identityFor);
      const elementId = identityFor(el);
      // One definition, shared with the scene-graph walk: see `schemaKeyFor`
      // there for why the class list comes before the tag.
      const schemaKey = schemaKeyFor(el);
      detail = {
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
          layerTree: JSON.stringify(layerTree(el)),
          // The authored style provenance the `ui` DSL stamped at macro time.
          // Every other style field above is a COMPUTED value, and a computed
          // value has already lost the answer to "was this a binding?". This is
          // the only field in the payload that still knows.
          styleBindings: el.getAttribute('data-isonim-props') || '',
          // Every property the inspector has a row for, from the single list in
          // `style_provenance_decode`. The named fields above are a fixed 17;
          // the panel renders 51 rows, and a row whose property the selection
          // does not carry refuses the commit with "does not expose ...".
          computedStyles: ISONIM_EDITABLE_PROPS
            .map(function (p) {
              return p + '=' + (style.getPropertyValue(p) || '');
            }).join(';')
      };
    } finally {
      chromeSheet.disabled = chromeDisabled;
    }
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-selected', {detail: detail}));
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
    const state = drillAt(event.target);
    if (!state) return;
    const selected = state.chain[0];
    event.preventDefault();
    event.stopPropagation();
    // A double-click is the same gesture as the click that opened it, so
    // it must not move the selection: the repeat-click climb owns that,
    // and a dblclick that re-selected the leaf turned a burst of clicks
    // into a selection oscillating between the leaf and the outermost
    // element. It acts only while the climb is still on the element under
    // the pointer -- a deliberate double-click rather than two of the
    // clicks in a mash that has already walked halfway up the chain.
    if (state.index > 0) return;
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
      // Entering and leaving inline editing without typing is not an edit.
      // Reporting it staged a no-op source edit every time a click burst
      // passed through the double-click that opens the editor.
      if (next === before) return;
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
  let lastHoverReported = '';
  document.addEventListener('mouseleave', function () {
    if (lastHoverReported === '') return;
    lastHoverReported = '';
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-hovered', {
      detail: { id: '' }
    }));
  });
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
    // Moving onto a different element restarts the climb. This is the
    // only reset there is: pointer position, not elapsed time and not a
    // pixel threshold, is what decides where a click lands.
    if (el !== drill.target) drillRestart(el);
    const rect = el.getBoundingClientRect();
    const style = window.getComputedStyle(el);
    el.setAttribute('data-isonim-hovered', 'true');
    // Tell the editor which element the pointer is over, so the Layers
    // panel can show it softly. Only on CHANGE: mousemove fires per pixel
    // and the panel would re-render on every one of them.
    const hoveredId = identityFor(el);
    if (hoveredId !== lastHoverReported) {
      lastHoverReported = hoveredId;
      parent.dispatchEvent(new CustomEvent('isonim-preview-element-hovered', {
        detail: { id: hoveredId }
      }));
    }
    const position = drill.index;
    label.textContent = el.tagName.toLowerCase() + ' ' +
      Math.round(rect.width) + 'x' + Math.round(rect.height) +
      ' p:' + style.padding + ' • click selects, repeat-click climbs' +
      (position > 0
        ? ' (' + (position + 1) + '/' + drill.chain.length + ')'
        : '');
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
  bindParent('isonim-select-preview-ancestor', function (event) {
    if (editorMode === 'view') return;
    const selected = window.__isonimSelectedElement;
    const index = Number(event.detail && event.detail.index);
    if (!selected || Number.isNaN(index)) return;
    const stack = ancestorStack(selected).reverse();
    const target = stack[Math.max(0, Math.min(index, stack.length - 1))];
    if (target) selectElement(target);
  });
  bindParent('isonim-select-preview-element-id', function (event) {
    if (editorMode === 'view') return;
    const id = String(event.detail && event.detail.id || '');
    if (!id) return;
    layerTree(window.__isonimSelectedElement || document.body);
    const target = document.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (target) selectElement(target);
  });
  // Stamp this frame's elements with their identities, then re-apply anything
  // the editor changed since the project was last built.
  //
  // The stamping is UNCONDITIONAL and must stay that way. `identityFor`
  // assigns `data-isonim-element-id` lazily, as the walk visits each node, so
  // a frame that has just loaded carries no ids at all; selection then walks
  // up from the clicked element looking for one and lands on whatever
  // ancestor a previous walk happened to stamp. Clicking the heading selects
  // `div.page-width`.
  //
  // This used to sit BELOW the "no overrides, nothing to do" early return, and
  // got away with it only because an override always existed by the time it
  // mattered. When overrides began being cleared on every hot swap -- they are
  // obsolete once the rebuilt source carries the value -- the early return
  // started firing on every frame and took the stamping with it. The
  // dependency was invisible and the symptom looked like a selection bug.
  (function () {
    try { layerTree(null); } catch (e) {}
    // Re-apply the edits this document was built too early to know about.
    //
    // After the stamping above, because a declaration is addressed by element
    // and a freshly parsed document carries no `data-isonim-element-id` until
    // the walk assigns them. Before the parser paints, because this script is
    // the last thing in `<body>` -- which is why it is here rather than in the
    // head script that defines the resolver: there, the body does not exist
    // yet.
    //
    // Short records rather than a stylesheet, so there is nothing to cap or
    // expire, and applying twice is a no-op.
    try {
      const pending = parent.__isonimPreviewDeclarations;
      if (pending) {
        Object.keys(pending).forEach(function (key) {
          const d = pending[key];
          window.__isonimSetDeclaration(d.id, d.path, d.property, d.value, d.scope);
        });
      }
    } catch (e) {}
  })();
  // The resolver lives in the head script (see `declarationRuntime`), which
  // runs before this document is painted. This is only the channel.
  bindParent('isonim-preview-set-declaration', function (event) {
    const d = event.detail || {};
    try {
      window.__isonimSetDeclaration(String(d.id || ''), String(d.path || ''),
                                    String(d.property || ''),
                                    String(d.value == null ? '' : d.value), String(d.scope || 'sskLocalInstance'));
    } catch (e) {}
  });

  bindParent('isonim-preview-element-visibility', function (event) {
    const id = String(event.detail && event.detail.id || '');
    if (!id) return;
    const target = document.querySelector(
      '[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (!target) return;
    // `visibility`, not `display`: the element keeps its box, so hiding it
    // answers "what does this look like without this" without reflowing
    // everything around it into a different page.
    if (event.detail && event.detail.visible) {
      target.style.removeProperty('visibility');
    } else {
      target.style.setProperty('visibility', 'hidden', 'important');
    }
  });
  bindParent('isonim-hover-preview-element-id', function (event) {
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
  // SGR: the preview does NOT publish the element tree.
  //
  // It used to, on a MutationObserver, and the editor's parent-side reader
  // published one too. Two producers writing one signal is a race, and the
  // race is visible: whichever fired last won, so the panel's contents
  // depended on whether the user had just switched modes or just moved the
  // mouse. The reader is now the only producer (see
  // `installSceneGraphReader` in `shell.nim`) -- it polls the same
  // `contentDocument` this script would have walked, through the same
  // `scene_graph_walk.nim` source, and it works in View mode too, where this
  // script deliberately does not exist.
  //
  // `layerTree` stays because the bridge itself needs it: arrow-key
  // navigation and the selection payload's ancestor chain are computed here,
  // in the iframe, where the selection lives.
  setTimeout(function () {
    try {
      const request = window.frameElement?.__isonimSelectionRestore;
      if (request?.valid()) window.__isonimRestoreSelection(request.id);
    } catch (error) {}
  }, 0);
})();
</script>
"""
  let injected = bridge
    .replace("__ISONIM_SCENE_GRAPH_WALK__", sceneGraphWalkJs)
    .replace("__ISONIM_SOURCE__", metadata.sourceFile.jsString)
    .replace("__ISONIM_LINE__", $max(metadata.sourceLine, 1))
    .replace("__ISONIM_MODE__", (case mode
      of emSpec: "spec"
      of emView: "view"
      of emComment: "comment"
      of emEdit: "edit"))
  # Splice by index rather than `strutils.replace`. On the JS backend a
  # Nim `string` is an array of char codes and `replace` appends each
  # piece with `result.push.apply(result, piece)`; a piece longer than
  # the engine's argument limit (~121k entries in V8) raises
  # "Maximum call stack size exceeded". Real project documents cross
  # that limit easily (the GRIP home page is ~159k chars), so entering
  # Comment/Edit mode on any sizeable page threw here and the preview
  # never got its selection bridge. `&` compiles to `Array.concat`,
  # which has no such limit.
  # Spliced by index for the same reason as the bridge below: on the JS
  # backend `strutils.replace` pushes each piece with `apply`, which blows the
  # argument limit on a document this size.
  # Injected at the END OF HEAD, and the position is the whole point.
  #
  # The bridge below goes before `</body>`. That is right for everything else
  # it does and one frame too late for this: a rebuild always lags the edit
  # that caused it, so the document arriving after a save carries the PREVIOUS
  # rule values, and a re-apply that runs after the body has been painted shows
  # the user the value they just replaced first. Measured as a visible flash
  # 8655ms into a three-edit sequence, which is the rebuild landing, not the
  # edit.
  #
  # Running here, the rules exist (the stylesheet is above) and nothing has
  # rendered yet, so the document is correct the first time it is painted.
  #
  # It also owns the resolver, and the bridge calls back into it, so there is
  # one implementation of "which rule does the cascade use for this property"
  # rather than two that can disagree.
  const declarationRuntime = """
<script>
(function () {
  var SHORTHANDS = {
    'font-size': ['font'], 'font-family': ['font'], 'font-weight': ['font'],
    'font-style': ['font'], 'line-height': ['font'],
    'margin-top': ['margin'], 'margin-right': ['margin'],
    'margin-bottom': ['margin'], 'margin-left': ['margin'],
    'padding-top': ['padding'], 'padding-right': ['padding'],
    'padding-bottom': ['padding'], 'padding-left': ['padding'],
    'background-color': ['background'], 'background-image': ['background'],
    'border-width': ['border'], 'border-style': ['border'],
    'border-color': ['border'],
    'flex-grow': ['flex'], 'flex-shrink': ['flex'], 'flex-basis': ['flex'],
    'row-gap': ['gap'], 'column-gap': ['gap'],
    'overflow-x': ['overflow'], 'overflow-y': ['overflow']
  };

  // The rule the cascade is actually using for this element and property.
  //
  // Resolved from the browser's own view rather than supplied by the editor:
  // it already knows which rules match and which media conditions hold at this
  // width, and asking it needs no project knowledge. The same question is
  // answered in Nim (`editTargetAtWidth`) to decide where the FILE is patched,
  // so the instant path and the durable one agree by construction.
  //
  // Last match wins, because equal specificity is broken by document order. A
  // rule that sets the property through a shorthand counts: a longhand written
  // anywhere earlier would be reset by it.
  function governingRule(el, property) {
    var resetters = [property].concat(SHORTHANDS[property] || []);
    var winner = null, fallback = null;
    function visit(rules, holds) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        // Branch on TYPE. Chrome defines `cssRules` on CSSStyleRule too, for
        // CSS nesting, so duck-typing on it skips every style rule.
        if (rule.type === CSSRule.MEDIA_RULE) {
          var m = false;
          try { m = matchMedia(rule.conditionText).matches; } catch (e) {}
          visit(rule.cssRules, holds && m);
          continue;
        }
        if (rule.type === CSSRule.SUPPORTS_RULE) {
          visit(rule.cssRules, holds);
          continue;
        }
        if (rule.type !== CSSRule.STYLE_RULE || !rule.selectorText) continue;
        if (!holds) continue;
        var matches = false;
        try { matches = el.matches(rule.selectorText); } catch (e) {}
        if (!matches) continue;
        // Any matching rule is a home for a declaration nothing currently
        // makes; one that already decides the property is a better one.
        fallback = rule;
        for (var r = 0; r < resetters.length; r++) {
          var name = resetters[r];
          if (rule.style.getPropertyValue(name) !== '' ||
              Array.prototype.indexOf.call(rule.style, name) >= 0) {
            winner = rule;
            break;
          }
        }
      }
    }
    var sheets = document.styleSheets;
    for (var s = 0; s < sheets.length; s++) {
      // Skip the editor's own chrome.
      //
      // The bridge injects `#isonim-editor-selection-style` to draw the
      // selection outline, and it is injected LAST -- so its
      // `[data-isonim-selected="true"]` rule matches the selected element and
      // wins the last-match contest against the rule the author wrote. The
      // user's font-size went into the editor's outline rule, which is not
      // theirs to edit and is not where the file write goes: the Nim side
      // correctly chose `.tagline-clause` while this chose the outline. A
      // stylesheet the editor injected is never a home for a project edit.
      var owner = null;
      try { owner = sheets[s].ownerNode; } catch (e) {}
      if (owner && owner.id && owner.id.indexOf('isonim-editor') === 0) continue;
      var rules;
      try { rules = sheets[s].cssRules; } catch (e) { continue; }
      visit(rules, true);
    }
    return winner || fallback;
  }

  // A normal inline declaration cannot win against an active important rule.
  // Local edits must refuse that owner instead of mutating its shared rule.
  // This scans important precedence only, independently of the legacy last-match
  // rule resolver. It does not attempt a general specificity/cascade solver.
  window.__isonimLocalDeclarationRefusal = function (id, path, property) {
    var el = null;
    if (id) el = document.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (!el && path) { try { el = document.querySelector(path); } catch (e) {} }
    if (!el) return '';
    var names = [property].concat(SHORTHANDS[property] || []);
    if (!names.some(function (name) { return el.style.getPropertyValue(name) !== ''; })) return '';
    if (names.some(function (name) { return el.style.getPropertyPriority(name) === 'important'; })) return '';
    function important(rules) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        if (rule.type === CSSRule.MEDIA_RULE) {
          if (matchMedia(rule.conditionText).matches && important(rule.cssRules)) return true;
        } else if (rule.type === CSSRule.SUPPORTS_RULE) {
          if (CSS.supports(rule.conditionText) && important(rule.cssRules)) return true;
        } else if (typeof CSSLayerBlockRule !== 'undefined' && rule instanceof CSSLayerBlockRule) {
          if (important(rule.cssRules)) return true;
        } else if (rule.type === CSSRule.STYLE_RULE && rule.selectorText) {
          var matches = false;
          try { matches = el.matches(rule.selectorText); } catch (e) {}
          if (matches && names.some(function (name) {
            return rule.style.getPropertyPriority(name) === 'important';
          })) return true;
        }
      }
      return false;
    }
    for (var i = 0; i < document.styleSheets.length; i++) {
      var sheet = document.styleSheets[i], owner = sheet.ownerNode;
      if (sheet.disabled || (owner && owner.id && owner.id.indexOf('isonim-editor') === 0)) continue;
      if (sheet.media.mediaText && !matchMedia(sheet.media.mediaText).matches) continue;
      try { if (important(sheet.cssRules)) return 'Read-only: an important stylesheet declaration overrides this inline value; local editing is unavailable.'; } catch (e) {}
    }
    return '';
  };

  window.__isonimSetDeclaration = function (id, path, property, value, scope) {
    if (!property) return false;
    // Id first, DOM path second. On a freshly loaded document there are no
    // ids at all -- the scene-graph walk stamps them lazily and has not run
    // yet -- so the path is the only handle that works before the first paint,
    // which is the moment that matters here.
    var el = null;
    if (id) {
      el = document.querySelector(
        '[data-isonim-element-id="' + CSS.escape(id) + '"]');
    }
    if (!el && path) {
      try { el = document.querySelector(path); } catch (e) {}
    }
    if (!el) return false;
    var local = !scope || scope === 'sskLocalInstance';
    if (local && window.__isonimLocalDeclarationRefusal(id, path, property)) return false;
    var rule = governingRule(el, property);
    function priority(style) {
      var names = [property].concat(SHORTHANDS[property] || []);
      for (var i = 0; i < names.length; i++) {
        if (style.getPropertyPriority(names[i]) === 'important') return 'important';
      }
      return '';
    }
    function hasDeclaration(style) {
      var names = [property].concat(SHORTHANDS[property] || []);
      return names.some(function (name) { return style.getPropertyValue(name) !== ''; });
    }
    // A local edit of the winning inline owner must not change a discarded
    // lower rule or siblings. Retain its priority; never manufacture important.
    // An important stylesheet declaration still outranks normal inline style.
    var style = rule ? rule.style : el.style;
    if (local && hasDeclaration(el.style)) {
      style = el.style;
    }
    // Token edits retain their var() use-sites, including inline references.
    // Resolve the directly referenced root declaration rather than detaching
    // the selected element from the binding. Other shared scopes keep their
    // stylesheet declaration owner.
    if (scope === 'sskComponentToken' || scope === 'sskSemanticToken' ||
        scope === 'sskGlobalPrimitiveToken') {
      var declared = el.style.getPropertyValue(property) || style.getPropertyValue(property);
      var token = /^var\(\s*(--[\w-]+)(?:\s*,[^)]*)?\s*\)$/.exec(declared.trim());
      if (token) {
        property = token[1];
        var tokenRule = governingRule(document.documentElement, property);
        style = tokenRule ? tokenRule.style : document.documentElement.style;
      }
    }
    var importance = priority(style);
    if (value === '') style.removeProperty(property);
    else style.setProperty(property, value, importance);
    return true;
  };

  // The re-apply deliberately does NOT happen here, only the definition.
  //
  // This script sits at the end of `<head>`, so the body has not been parsed
  // yet and there is no element to resolve -- by stamped id or by DOM path,
  // both come back null. An earlier version tried it here and the preview
  // still flashed the previous value, which read as the re-apply being broken
  // rather than impossible. It runs from the bridge instead, at the end of
  // `<body>`, where the elements exist and the parser has not painted yet.
})();
</script>
"""
  var withRuntime = documentHtml
  let headClose = documentHtml.find("</head>")
  if headClose >= 0:
    withRuntime = documentHtml[0 ..< headClose] & declarationRuntime &
      documentHtml[headClose .. ^1]

  let closing = withRuntime.rfind("</body>")
  if closing >= 0:
    withRuntime[0 ..< closing] & injected & withRuntime[closing .. ^1]
  else:
    withRuntime & injected


proc ownPreviewSelectionRestore[E](frame: E) =
  ## Bind once to the frame-construction owner, never the shorter selection
  ## computation. Each selection replaces the request, not its cleanup owner.
  when isDomViewHost(E):
    let lifetimeOwner = getOwner()
    var cleanupLifetime: proc()
    {.emit: ["""
      (function () {
        const frame = """, frame, """;
        frame.__isonimSelectionRestoreLifetime?.dispose();
        const lifetime = { disposed: false, owner: """, lifetimeOwner, """, dispose: () => {
          lifetime.disposed = true;
          if (frame.__isonimSelectionRestore?.lifetime === lifetime)
            frame.__isonimSelectionRestore.cancel();
        }};
        frame.__isonimSelectionRestoreLifetime = lifetime;
        """, cleanupLifetime, """ = lifetime.dispose;
      })();
    """].}
    onCleanup(cleanupLifetime)
  else:
    discard frame

proc installPreviewSelectionBridge*[R, E](r: R; frame: E; vm: EditorVM) =
  when isDomViewHost(E):
    ownPreviewSelectionRestore(frame)
    ownViewResources(frame)
    let selectFromBrowser = proc(elementId, sourceKey, schemaKey, tag, testId,
        className, role, elementPath, ancestry, ancestorIds, sourceFile,
        sourceLine, display, position, backgroundColor,
        color, padding, margin, width, height, borderRadius, borderWidth,
        borderStyle, borderColor, fontSize, fontWeight, lineHeight, boxShadow,
        opacity, rectWidth, rectHeight, textContent, layerTreeJson,
        styleBindings, computedStyles: cstring) =
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
        $layerTreeJson,
        $styleBindings,
        $computedStyles)
      # SGR: selecting does NOT republish the tree. `selectInspectorElement`
      # re-flags the rows the scene-graph reader already published, which is
      # the same tree walked from the same source. Publishing a second one
      # here is what let a click in the preview replace a complete tree with
      # a differently-built one whose ids the panel's expansion state did not
      # recognise -- the panel collapsed to its top-level rows on every click.
      # The payload is still carried: `previewDomElementRef` reads it for the
      # selection's ancestor chain.
      discard vm.selectInspectorElement(element)
      if ($backgroundColor).len > 0 and ($backgroundColor) != "rgba(0, 0, 0, 0)":
        vm.inspector.activeSection.val = isFill
      elif ($padding).len > 0 or ($margin).len > 0:
        vm.inspector.activeSection.val = isSpacing
      else:
        vm.inspector.activeSection.val = isLayout
    {.emit: ["""
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-element-selected', function (event) {
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
            d.layerTree || '', d.styleBindings || '',
            d.computedStyles || ''
          );
      });
    """].}

    # SGR: there is no `isonim-preview-layer-tree` listener any more. The
    # preview used to publish its own tree here and the parent-side reader in
    # `shell.nim` published another; the panel showed whichever arrived last.
    # The reader is the single producer now, in every mode.

    let clearFromBrowser = proc() =
      vm.clearInspectorSelection()
    {.emit: ["""
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-selection-cleared', function () {
          """, clearFromBrowser, """();
      });
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
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-direct-manipulation', function (event) {
          const d = event.detail || {};
          """, directManipulationFromBrowser,
        """(
            d.kind || '', d.property || '', d.value || '', d.oldValue || '',
            d.handle || '', d.command || '', d.sourceKey || '',
            d.measurement || '', Number(d.fromIndex || 0),
            Number(d.toIndex || 0)
          );
      });
    """].}

    let addCommentToPrompt = proc(selector, ancestry, text, domSnapshot,
        screenshotRef: cstring) =
      discard vm.addReviewAnnotation($text, selector = $selector,
        ancestry = $ancestry, domSnapshot = $domSnapshot,
        screenshotRef = $screenshotRef)
    {.emit: ["""
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-comment-added', function (event) {
          const d = event.detail || {};
          """, addCommentToPrompt,
        """(d.selector || '', d.ancestry || '', d.text || '', d.domSnapshot || '', d.screenshotRef || '');
      });
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
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-vector-edit', function (event) {
          const d = event.detail || {};
          """, openVectorFromBrowser,
        """(d.symbol || '', d.elementPath || '');
      });
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
        globalThis.__isonimDeferView(frame, resizeFrame, 0);
        globalThis.__isonimViewCleanup(frame, () => frame.removeEventListener('load', resizeFrame));
      }
    """].}

proc restorePreviewSelection*[R, E](r: R; frame: E; id: string;
    isCurrent: proc(): bool) =
  ## One replaceable request belongs to each actual frame. Selection callbacks
  ## can publish another selection, so an obsolete request must never replay.
  when isDomViewHost(E):
    {.emit: ["""
      (function () {
        const frame = """, frame, """;
        const semanticCurrent = """, isCurrent, """;
        const selectedId = Array.isArray(""", id, """)
          ? String.fromCharCode.apply(null, """, id, """) : String(""", id, """ || '');
        if (!frame) return;
        frame.__isonimSelectionRestore?.cancel();
        const lifetime = frame.__isonimSelectionRestoreLifetime;
        if (!selectedId || !lifetime || lifetime.disposed || !semanticCurrent()) return;
        const source = frame.srcdoc;
        let timer = null;
        const request = {
          id: selectedId, lifetime,
          valid: () => frame.__isonimSelectionRestore === request &&
            frame.__isonimSelectionRestoreLifetime === lifetime &&
            !lifetime.disposed && frame.isConnected &&
            frame.srcdoc === source && semanticCurrent(),
          cancel: () => {
            if (timer !== null) clearTimeout(timer);
            timer = null;
            frame.removeEventListener('load', loaded);
            if (frame.__isonimSelectionRestore === request)
              delete frame.__isonimSelectionRestore;
            if (window.__isonimPendingPreviewSelection === request) {
              delete window.__isonimPendingPreviewSelection;
              window.__isonimPendingPreviewSelectionId = '';
            }
          }
        };
        const schedule = () => {
          if (timer !== null) clearTimeout(timer);
          const doc = frame.contentDocument;
          timer = setTimeout(() => {
            timer = null;
            if (!request.valid() || frame.contentDocument !== doc) return;
            try { frame.contentWindow?.__isonimRestoreSelection?.(selectedId); }
            catch (error) {}
          }, 0);
        };
        const loaded = () => {
          if (request.valid()) schedule();
          else request.cancel();
        };
        frame.__isonimSelectionRestore = request;
        window.__isonimPendingPreviewSelection = request;
        window.__isonimPendingPreviewSelectionId = selectedId;
        frame.addEventListener('load', loaded);
        schedule();
      })();
    """].}
  else:
    discard r
    discard frame
    discard id


proc renderComponentEditView*[R, E](r: R; vm: EditorVM): E =
  ## M-EVP-6: per-view inner toolbar (breadcrumb + Edit/Comment/View
  ## mode buttons) and the inner status caption row removed. The
  ## canonical chrome bar (above the view stack) hosts the mode chips
  ## now; the component-edit body starts directly at the editable
  ## preview iframe.
  var projectFrame: E
  var lastSrcdoc = ""
  var lastRestoredSelection = ""
  let mountState = newPreviewMountState()

  let container = ui(r):
    tdiv(class = "editor-preview",
          `data-component-edit` = "true",
          flex = "1", display = "flex",
          min_width = "0", height = "100%",
          background_color = bgBase)

  # The editable preview is sized by the SCREEN-SIZE CHIPS, like the
  # read-only one in page_preview.nim already was.
  #
  # It was not, and the consequence was not cosmetic. The iframe was
  # `width:100%` of whatever the centre column left it -- about 840px -- so
  # Desktop, Laptop, Tablet and Phone all rendered identically, at a width
  # that happens to sit inside this project's `@media (max-width:1080px)`
  # block. The chips looked like they worked because the label changed. Every
  # responsive rule was permanently in its compact state and there was no way
  # to see, or edit, the wide one.
  #
  # Three nested elements, each with one job:
  #   * `scrollHost` -- the scrollable, padded area the frame sits in.
  #   * `fitHost`    -- carries the scale transform, so a 1440px viewport is
  #                     legible inside an 840px column instead of demanding a
  #                     horizontal scrollbar.
  #   * `deviceFrame`-- the viewport itself, at its true CSS width. The iframe
  #                     fills it, so the page inside is laid out at the
  #                     viewport's width whatever the transform does visually.
  #
  # Scaling rather than shrinking is what keeps this honest: the iframe's
  # layout width stays 1440 when 1440 is selected, so the media queries the
  # browser evaluates are the ones for 1440. A transform changes how big it
  # looks, never what it computes.
  var scrollHost: E
  var fitHost: E
  var deviceFrame: E
  let preview = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          min_width = "0"):
      tdiv(ref = scrollHost,
            flex = "1", overflow = "auto", background_color = bgPreview,
            padding = "24px",
            # Reserve the scrollbar's width whether or not it is showing.
            #
            # Without this the fit calculation oscillates and the tab locks
            # up. The chain: a taller preview makes this host overflow, the
            # vertical scrollbar appears, `clientWidth` drops by the
            # scrollbar's width, the scale is recomputed smaller, the frame
            # gets shorter, the scrollbar goes away, `clientWidth` grows back
            # -- and round again, forever, via the ResizeObserver below. It
            # needs a content-height change to enter that regime, which is
            # exactly what applying a stylesheet swap does, so it only showed
            # up once the fast path started editing the live preview's CSS.
            scrollbar_gutter = "stable",
            display = "flex", justify_content = "center",
            align_items = "flex-start"):
        tdiv(ref = fitHost,
              position = "relative",
              flex = "0 0 auto"):
          tdiv(ref = deviceFrame,
                position = "absolute", top = "0", left = "0",
                transform_origin = "top left",
                background_color = "#FFFFFF",
                border_radius = "8px",
                overflow = "hidden",
                `data-component-edit-device-frame` = "true"):
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

  # Size the viewport, fit it to the column, and report the width the page
  # inside is actually being laid out at.
  #
  # The reported width is `clientWidth`, NOT `getBoundingClientRect().width`:
  # the rect is post-transform, so a scaled-down 1440px viewport would report
  # ~820 and every breakpoint question would be answered for a width the page
  # inside is not using. `clientWidth` is the layout width, which is the one
  # the browser evaluates media queries against.
  when isDomViewHost(E):
    let reportWidth = proc(width: int) =
      if vm.previewRenderedWidth.val != width:
        vm.previewRenderedWidth.val = width

    createRenderEffect proc() =
      let vp = vm.viewport.val
      let width = max(vp.width, 1)
      r.setStyle(deviceFrame, "width", $width & "px")
      r.setStyle(deviceFrame, "min-width", $width & "px")
      r.setAttribute(deviceFrame, "data-preview-viewport-width", $width)
      # A cells-based (TUI) viewport has no pixel width to honour; leave it
      # filling the column rather than rendering an 80px-wide frame.
      if vp.isCells:
        r.setStyle(deviceFrame, "width", "100%")
        r.setStyle(deviceFrame, "min-width", "0")
      # Refit now that the device is its new size. The observer below watches
      # the scroll host, which a width change inside it does not necessarily
      # resize, so waiting for it would leave a 1440px frame unscaled in an
      # 840px column until something else moved.
      when isDomViewHost(E):
        {.emit: ["""
          (function (host) {
            if (host && host.__isonimApplyFit) host.__isonimApplyFit();
          })(""", scrollHost, ");"].}

    {.emit: ["""
      (function (host, fit, frame, device, report) {
        if (!host || host.__isonimViewportFitInstalled) return;
        host.__isonimViewportFitInstalled = true;
        // `device` is absolutely positioned inside `fit`, and `fit` is sized
        // to the SCALED box.
        //
        // The obvious arrangement -- device in normal flow, transform on the
        // wrapper -- does not work, and the way it fails is instructive. A
        // transform does not affect layout, so a 1440px device still claims
        // 1440px of width inside an 850px column. That overflow propagates up
        // the flex chain and squeezes the very element whose width is being
        // measured to compute the scale, so `available` came back as ~344
        // instead of ~850 and everything rendered at a fifth of its size.
        // Taking the device out of flow means nothing ever overflows and the
        // measurement is of the real column.
        //
        // Every write is also guarded by "did this actually change". Without
        // that, `apply` sets a size on `fit`, which resizes `host`, which
        // fires the observer, which calls `apply`: an infinite loop that
        // freezes the tab rather than merely looking wrong.
        let lastScale = null;
        let lastW = null;
        let lastH = null;
        let lastReported = 0;
        // Runaway guard. `scrollbar-gutter: stable` above removes the
        // oscillation this counts, and the counter stays because the failure
        // mode is a frozen tab rather than a visible glitch: a fit that cannot
        // settle must give up and leave the preview slightly wrong, not spin.
        // Reset on every settled frame, so ordinary resizing never trips it.
        let burst = 0;
        let burstFrame = 0;
        host.__isonimFitApplies = 0;
        const apply = function () {
          host.__isonimFitApplies++;
          const frame = Math.floor(performance.now() / 16);
          if (frame === burstFrame) {
            if (++burst > 30) return;
          } else {
            burstFrame = frame;
            burst = 0;
          }
          const style = getComputedStyle(host);
          const padding = parseFloat(style.paddingLeft || '0') +
                          parseFloat(style.paddingRight || '0');
          const available = host.clientWidth - padding;
          const natural = device.clientWidth;
          const naturalH = device.offsetHeight;
          if (!natural || available <= 0) return;
          // Only ever scale DOWN. Blowing a 390px phone up to fill the column
          // would misrepresent it as badly as cropping it.
          // Quantised so sub-pixel jitter cannot produce an endless series of
          // "changed" values that each retrigger the observer.
          const scale = Math.min(1, Math.floor(available / natural * 1000) / 1000);
          if (scale !== lastScale) {
            lastScale = scale;
            device.style.transform = scale < 1 ? 'scale(' + scale + ')' : '';
          }
          const w = Math.round(natural * scale);
          const h = Math.round(naturalH * scale);
          if (w !== lastW) { lastW = w; fit.style.width = w + 'px'; }
          if (h !== lastH) { lastH = h; fit.style.height = h + 'px'; }
          if (natural !== lastReported) {
            lastReported = natural;
            report(natural);
          }
        };
        if (typeof ResizeObserver !== 'undefined') {
          // `host` only. `device` and `fit` are both written to above, so
          // observing either is the shortest path back into the loop.
          const observer = new ResizeObserver(apply);
          observer.observe(host);
          globalThis.__isonimViewCleanup(host, () => observer.disconnect());
        } else {
          window.addEventListener('resize', apply);
          globalThis.__isonimViewCleanup(host, () => window.removeEventListener('resize', apply));
        }
        frame.addEventListener('load', apply);
        globalThis.__isonimViewCleanup(host, () => { frame.removeEventListener('load', apply); delete host.__isonimApplyFit; });
        // The viewport effect calls this after it changes the device width. A
        // polling timer would also work and would be worse: either slower than
        // the change, or still running long after it.
        host.__isonimApplyFit = apply;
        apply();
      })(""", scrollHost, ", ", fitHost, ", ", projectFrame, ", ",
      deviceFrame, ", ", reportWidth, ");"].}

  ownViewResources(scrollHost)

  # Why the selected element is NOT read in the srcdoc effect below.
  #
  # `componentEditPreviewDocument` ignores `selected` entirely whenever the
  # project supplies its own `documentHtml`, which every real project does;
  # the selection only feeds the SYNTHESIZED fallback document. Reading the
  # selection unconditionally therefore made every click rebuild the whole
  # preview document for no change in its bytes -- and on the JS backend a
  # Nim `string` is an array of char codes, so for the grip pilot's 650KB
  # document that meant copying a 650_000-element array several times per
  # click and then comparing two of them element by element. Measured cost:
  # ~1_000_000 `nimCopy` calls and 18-120 seconds of frozen main thread for a
  # single selection, a third of it in GC. Selecting an element is the most
  # common thing anyone does in this editor, so this is the one dependency
  # that had to go.
  #
  # The selection still has to reach the iframe, so it moves to its own
  # effect below, which depends on a memo over the element's `id` alone. That
  # keeps the ElementRef copy to once per selection instead of once per
  # reader, and leaves the 650KB document untouched.
  let selectedElementId = createMemo(proc(): string =
    vm.inspector.selectedElement.val.id)
  # Bumped whenever the iframe is actually reloaded, so the restore effect
  # below re-runs even when the selected id has not changed.
  let srcdocGeneration = createSignal(0)

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
        # Only the synthesized fallback needs the selection, and only that
        # branch reads it: dependencies here are dynamic, so NOT reading the
        # signal is what keeps this effect off the selection path.
        let previewDocument =
          if previewState.documentHtml.len > 0 or
              previewState.bodyText.len == 0:
            componentEditPreviewDocument(previewState, ElementRef())
          else:
            componentEditPreviewDocument(previewState,
              vm.inspector.selectedElement.val)
        if vm.editMode.val == emView:
          identifiedPreviewDocument(previewDocument, vm.selectedStory.val, reloadGeneration)
        else:
          identifiedPreviewDocument(editablePreviewDocument(previewDocument, metadata, vm.editMode.val), vm.selectedStory.val, reloadGeneration)
    # Length first: `!=` on a Nim string is an element-wise walk of two char
    # arrays, and two documents of different length cannot be equal.
    let srcdocChanged =
      nextSrcdoc.len != lastSrcdoc.len or nextSrcdoc != lastSrcdoc
    if srcdocChanged:
      lastSrcdoc = nextSrcdoc
      r.setAttribute(projectFrame, "srcdoc",
        requestedPreviewMountDocument(projectFrame, mountState, nextSrcdoc))
      # Reloading the frame drops the selection outline, so ask for a restore
      # even when the selected element itself did not change.
      # This is an output for selection restoration, not a dependency of
      # the document producer. Preserve notification without self-invalidation.
      srcdocGeneration.update(proc(previous: int): int = previous + 1)

    # Mount the project's UI into the frame, when the project offers one.
    #
    # The alternative -- and what this replaces -- is the project serialising
    # its UI to a string and the editor injecting it. A string cannot be
    # edited: changing a value in it means rewriting the source that produced
    # it and recompiling, which is why every fast path before this one was a
    # way of patching the rendered output behind the project's back.
    #
    # A mounted tree needs none of that. The values in it are cells (see
    # `dsl/isomorphic` and `editor/editable_cells`), so an edit is a signal
    # write and the framework's own reactivity updates the node that showed
    # it. The editor stops being a thing that rewrites the project's markup.
    #
    # Still inside the iframe, deliberately. The frame is what keeps the
    # project's CSS off the editor's chrome, and what makes the preview's width
    # the width media queries are evaluated against -- both of which a div in
    # the editor's own document would lose.
    # Only the ACTIVE view mounts and restores.
    #
    # Both preview views are mounted at once and display-toggled, so without
    # this the hidden one also mounts the story and also calls
    # `restorePreviewSelection` on its own frame. That frame's bridge answers
    # by dispatching a selection back into the same VM, the other view sees a
    # new selection and restores in turn, and the selection oscillates between
    # elements -- observed cycling between `h1.tagline` and two of its spans,
    # and eventually wedging the tab.
    #
    # Reading `activeView` also makes this effect re-run on a view switch,
    # which is what mounts the story into the view the user just moved to.
    if vm.platform.val == pbWeb and vm.activeView.val == evComponentEdit:
      let mountStory = vm.selectedStory.val
      mountPreviewInto(projectFrame, mountStory, vm.previewMount,
                       mountState, srcdocChanged, proc(): bool =
                         vm.platform.val == pbWeb and vm.activeView.val == evComponentEdit and
                         vm.selectedStory.val == mountStory)
    else:
      mountState.cancelPendingPreviewMount()
    r.setStyle(projectFrame, "min-height", "320px")
    r.setStyle(projectFrame, "overflow", "hidden")

  # Undo and redo change what the file should say; this is what makes the
  # preview follow.
  #
  # The ViewModels cannot touch a DOM, so `undoCssPropertyEdit` publishes a
  # request and this applies it -- through `applyPreviewStyle`, the same path a
  # fresh edit takes, so an undone value lands on the rule the cascade uses or
  # the cell it came from exactly as the original did.
  when isDomViewHost(E):
    var lastPreviewRequest = 0
    createRenderEffect proc() =
      let request = vm.inspector.previewValueRequest.val
      if request.generation == 0 or request.generation == lastPreviewRequest:
        return
      lastPreviewRequest = request.generation
      applyPreviewStyle(request.elementId, request.domPath,
                        request.property, request.value, request.sourceScope)
      # The write that follows must not reload the preview out from under it,
      # for the same reason a commit sets this.
      vm.previewShowsPendingEdits.val = true
      # And schedule the write. An undo that only moves the preview and the
      # inspector leaves the file saying what the user just took back -- which
      # is how this looked before: the value returned to 40px on screen while
      # the stylesheet still read 55px, and the next rebuild would have put it
      # back. Undoing after a save is itself an edit, so it saves like one.
      vm.noteCommitForAutoSave()

  # Selection restore, on its own. Reads a string memo and an int, so a click
  # costs one ElementRef copy rather than a rebuild of the whole document.
  createRenderEffect proc() =
    let selectedId = selectedElementId.val
    let generation = srcdocGeneration.val
    let stamp = selectedId & "@" & $generation
    # Active view only; see the note on the mount above.
    if vm.activeView.val == evComponentEdit and
        selectedId.len > 0 and stamp != lastRestoredSelection:
      lastRestoredSelection = stamp
      r.restorePreviewSelection(projectFrame, selectedId, proc(): bool =
        vm.activeView.val == evComponentEdit and
          selectedElementId.val == selectedId and srcdocGeneration.val == generation)
    elif vm.activeView.val != evComponentEdit or selectedId.len == 0:
      lastRestoredSelection = ""
      r.restorePreviewSelection(projectFrame, "", proc(): bool = false)

  container
