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

import isonim/core/[signals, computation, owner, batch]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/preview_identity
import isonim/editor/types
import isonim/editor/views/preview_mount
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/section_box_model
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

const editablePreviewBridgeTemplate = block:
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
  /* The selection and hover outlines are drawn by these overlays, each
     placed on its element's border box, and not by the element: an outline
     on the page's own element is a change to its style, so a page
     `transition` on it animated the outline in and delivered `transitionrun`
     and `transitionend` to page code whenever the pointer crossed an element.
     The overlays draw the same outline the element used to (colour, style,
     width, offset), above the page's content. */
  #isonim-editor-selection-outline,
  #isonim-editor-hover-outline {
    position: fixed;
    z-index: 2147483644;
    pointer-events: none;
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    border: 0;
    background: transparent;
  }
  #isonim-editor-selection-outline {
    outline: 2px solid #3B82F6;
    outline-offset: 2px;
  }
  #isonim-editor-hover-outline {
    outline: 1px dashed rgba(59,130,246,.75);
    outline-offset: 3px;
  }
  /* The agent's highlight (`select --highlight` from the editor's control
     CLI), drawn the same way. On an element that also shows the selection
     or hover outline it moves out to 5px, so the indigo ring lies outside
     the blue one rather than on it. */
  #isonim-editor-agent-highlight {
    position: fixed;
    z-index: 2147483644;
    pointer-events: none;
    box-sizing: border-box;
    margin: 0;
    padding: 0;
    border: 0;
    background: transparent;
    outline: 2px solid #818cf8;
    outline-offset: 3px;
  }
  #isonim-editor-agent-highlight[data-beside-outline] {
    outline-offset: 5px;
  }
  /* Every piece of the editor's chrome lives in this one element, added to
     the page's body once, when the bridge starts: showing, moving and hiding
     the chrome adds and removes nothing in the page's own nodes, so a page
     MutationObserver sees no child-list change from a hover or a selection.
     It has no box of its own (`contents`), so the page's layout does not
     see it either. */
  #isonim-editor-chrome {
    display: contents !important;
  }
  /* The editor's chrome lives in the page's document, so the page's own
     rules match it too (`* { transition: all .4s }`): a transition there
     would animate the chrome as it follows the pointer and deliver its
     transition events to the page's listeners on the document. */
  #isonim-editor-selection-outline, #isonim-editor-hover-outline,
  #isonim-editor-agent-highlight, #isonim-editor-hover-label, #isonim-editor-selection-handles,
  #isonim-editor-selection-handles > span, #isonim-editor-selection-breadcrumb,
  #isonim-editor-selection-breadcrumb > span, .isonim-editor-layout-guide {
    transition: none !important;
    animation: none !important;
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
  /* The selection's halo is drawn by this overlay, which sits on the
     element's border box, and not by the element: an `!important`
     box-shadow on the element hid the element's own box-shadow -- the
     property the Effects section's Shadow row and shadow editor edit -- for
     as long as it was selected. */
  #isonim-editor-selection-handles {
    position: fixed;
    z-index: 2147483646;
    pointer-events: none;
    border: 1px solid rgba(59,130,246,.9);
    box-shadow: 0 0 0 4px rgba(59,130,246,.22);
  }
  #isonim-editor-selection-handles > span {
    position: absolute;
    width: 7px;
    height: 7px;
    border-radius: 2px;
    background: #3B82F6;
    border: 1px solid white;
    pointer-events: auto;
    cursor: ew-resize;
  }
  #isonim-editor-selection-handles > span[data-handle="height"] {
    cursor: ns-resize;
  }
  #isonim-editor-selection-handles > span[data-handle="spacing"] {
    width: 10px;
    height: 10px;
    border-radius: 5px;
    background: #22C55E;
    cursor: ns-resize;
  }
  /* Margin and padding handles: a bar on each side's margin edge (amber, as
     the box model's margin ring) and content edge (green, as its padding
     ring). */
  #isonim-editor-selection-handles > span[data-box-handle] {
    width: 16px;
    height: 5px;
    border-radius: 3px;
    cursor: ns-resize;
    outline: none;
  }
  #isonim-editor-selection-handles > span[data-box-handle$="-left"],
  #isonim-editor-selection-handles > span[data-box-handle$="-right"] {
    width: 5px;
    height: 16px;
    cursor: ew-resize;
  }
  #isonim-editor-selection-handles > span[data-box-handle^="margin-"] {
    background: #F59E0B;
  }
  #isonim-editor-selection-handles > span[data-box-handle^="padding-"] {
    background: #34D399;
  }
  #isonim-editor-selection-handles > span[data-box-handle]:hover,
  #isonim-editor-selection-handles > span[data-box-handle][data-dragging] {
    box-shadow: 0 0 0 2px rgba(15,23,42,.85), 0 0 0 4px rgba(255,255,255,.9);
  }
  #isonim-editor-box-drag-message {
    max-width: 280px;
    padding: 3px 6px;
    border-radius: 4px;
    background: rgba(127,29,29,.95);
    color: #FEE2E2;
    font: 11px/1.35 system-ui, sans-serif;
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
  // Watches the preview's own frame element (see the follow loop below).
  let frameObserver = null;
  function disposeParentBridge() {
    if (bridgeDisposed) return;
    // A document that goes away mid-drag ends the drag without an edit.
    try { cancelHandleDrag(); } catch (error) {}
    bridgeDisposed = true;
    if (frameObserver) { frameObserver.disconnect(); frameObserver = null; }
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
    'isonim-editor-selection-outline',
    'isonim-editor-hover-outline',
    'isonim-editor-agent-highlight',
    'isonim-editor-frame-probe',
    'isonim-editor-chrome',
    'isonim-editor-selection-handles',
    'isonim-editor-selection-breadcrumb',
    'isonim-editor-gap-overlay',
    'isonim-editor-snap-lines',
    'isonim-editor-spacing-measure',
    'isonim-editor-context-menu',
    'isonim-editor-comment-popup',
    'isonim-editor-box-drag-message',
    'isonim-editor-box-drag-preview'
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
  // The element every piece of chrome is added to (see
  // `#isonim-editor-chrome`). Page code that rewrites the body drops it; it
  // is put back, at the end of the body, when the chrome next needs it.
  let chromeContainer = null;
  function chromeRoot() {
    if (!chromeContainer) {
      chromeContainer = document.createElement('div');
      chromeContainer.id = 'isonim-editor-chrome';
    }
    if (chromeContainer.parentNode !== document.body) document.body.appendChild(chromeContainer);
    return chromeContainer;
  }
  chromeRoot();
  function ensureHoverLabel() {
    let label = document.getElementById('isonim-editor-hover-label');
    if (!label) {
      label = document.createElement('div');
      label.id = 'isonim-editor-hover-label';
      label.hidden = true;
      // Its text is one text node, rewritten in place (no child-list change).
      label.appendChild(document.createTextNode(''));
      chromeRoot().appendChild(label);
    }
    return label;
  }
  // The selection overlay's margin and padding handles, one per side, named
  // by the longhand each drags (editor spec "Visual box model": "drag
  // handles on canvas for live preview").
  const BOX_HANDLES = ['margin-top', 'margin-right', 'margin-bottom',
    'margin-left', 'padding-top', 'padding-right', 'padding-bottom',
    'padding-left'];
  // One drag of a selection handle at a time. Every handle follows the same
  // contract (editor spec "Planned interaction parity"): the drag holds
  // pointer capture and previews as it moves; releasing commits one edit; a
  // press without movement, Escape, pointer cancellation or a lost capture
  // ends it without one and puts the preview back; and a drag belongs to the
  // element it was started on, so selecting another one discards it.
  let handleDrag = null;
  function cancelHandleDrag() {
    const drag = handleDrag;
    if (!drag) return false;
    drag.cancel();
    return true;
  }
  // The used `width` and `height` of an element in the box they set
  // (`box-sizing`), and how many of the document's pixels one of the
  // element's own CSS pixels covers on each axis: a transform or `zoom` on
  // it or an ancestor scales its border box on screen. `width` is null where
  // it does not apply (https://www.w3.org/TR/CSS2/visudet.html#the-width-property:
  // non-replaced inline boxes, table rows and row groups, and boxes that are
  // not generated); the resolved value there is the computed value, which
  // nothing renders.
  const REPLACED = ['IMG', 'VIDEO', 'CANVAS', 'IFRAME', 'EMBED', 'OBJECT',
    'INPUT', 'TEXTAREA', 'SELECT', 'BUTTON', 'svg'];
  function widthApplies(el, style) {
    const display = style.display;
    if (display === 'none' || display === 'contents') return false;
    if (display === 'inline') return REPLACED.indexOf(el.tagName) >= 0;
    return ['table-row', 'table-row-group', 'table-header-group',
      'table-footer-group'].indexOf(display) < 0;
  }
  function boxSizeFor(el, style) {
    const n = function (name) { return parseFloat(style.getPropertyValue(name)) || 0; };
    // `height` applies where `width` does, apart from table columns.
    const applies = widthApplies(el, style);
    const width = applies ? parseFloat(style.width) : NaN;
    const height = applies ? parseFloat(style.height) : NaN;
    const content = style.boxSizing !== 'border-box';
    const outerW = (isFinite(width) ? width : 0) + (content
      ? n('padding-left') + n('padding-right') + n('border-left-width') + n('border-right-width')
      : 0);
    const outerH = (isFinite(height) ? height : 0) + (content
      ? n('padding-top') + n('padding-bottom') + n('border-top-width') + n('border-bottom-width')
      : 0);
    const rect = el.getBoundingClientRect();
    const ratio = function (shown, own) {
      const r = own > 0 && shown > 0 ? shown / own : 1;
      return isFinite(r) && r > 0 ? r : 1;
    };
    return {
      width: isFinite(width) ? width : null,
      height: isFinite(height) ? height : null,
      scaleX: ratio(rect.width, outerW),
      scaleY: ratio(rect.height, outerH)
    };
  }
  // Why the canvas handles cannot follow the pointer on `el`, or "": the
  // scale above is read from the bounding box, which is the element's own
  // scale only under scale, translate and `zoom`. A rotation, a skew, a
  // mirror or a perspective on it or an ancestor turns or flips its box, and
  // a drag along the screen's axes no longer moves its edges along them.
  function transformRefusal(el) {
    for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
      const style = window.getComputedStyle(node);
      const turned = (style.rotate && style.rotate !== 'none') ||
        (style.scale && style.scale !== 'none' &&
          style.scale.split(/\s+/).some(function (v) { return parseFloat(v) < 0; }));
      let bad = !!turned;
      const t = style.transform;
      if (!bad && t && t !== 'none') {
        const m = (t.match(/\(([^)]*)\)/) || [, ''])[1].split(',').map(parseFloat);
        if (t.indexOf('matrix3d') === 0) {
          // Only scale (0, 5, 10) and translation (12, 13, 14) may be set.
          bad = m.length !== 16 || m[0] <= 0 || m[5] <= 0 ||
            [1, 2, 3, 4, 6, 7, 8, 9, 11].some(function (i) { return Math.abs(m[i]) > 1e-6; });
        } else {
          bad = m.length !== 6 || m[0] <= 0 || m[3] <= 0 ||
            Math.abs(m[1]) > 1e-6 || Math.abs(m[2]) > 1e-6;
        }
      }
      if (bad) return 'The canvas handles cannot follow the pointer on a rotated, ' +
        'skewed or mirrored element; use the inspector fields.';
    }
    return '';
  }
  // Where the selection chrome's fixed-position elements are laid out: their
  // containing block is the viewport, or an ancestor with a transform or a
  // filter (`body { transform: ... }`), which also scales them
  // (https://www.w3.org/TR/css-transforms-1/#containing-block-for-all-descendants).
  // A probe at left/top 0 and 100px square says where that origin lands on
  // screen and how big one of its pixels is.
  //
  // The probe stays in the chrome, so measuring adds and removes nothing.
  let frameProbe = null;
  function fixedFrame() {
    if (!frameProbe) {
      frameProbe = document.createElement('div');
      frameProbe.id = 'isonim-editor-frame-probe';
      frameProbe.setAttribute('aria-hidden', 'true');
      frameProbe.style.cssText = 'position:fixed;left:0;top:0;width:100px;height:100px;' +
        'visibility:hidden;pointer-events:none;margin:0;padding:0;border:0';
    }
    const root = chromeRoot();
    if (frameProbe.parentNode !== root) root.appendChild(frameProbe);
    const r = frameProbe.getBoundingClientRect();
    return {
      x: r.left, y: r.top,
      sx: r.width > 0 ? r.width / 100 : 1,
      sy: r.height > 0 ? r.height / 100 : 1
    };
  }
  // Place a fixed-position `node` at client coordinates (x, y), with a size
  // in client pixels when given.
  function placeFixed(frame, node, x, y, width, height) {
    node.style.left = ((x - frame.x) / frame.sx) + 'px';
    node.style.top = ((y - frame.y) / frame.sy) + 'px';
    if (width !== undefined) node.style.width = (width / frame.sx) + 'px';
    if (height !== undefined) node.style.height = (height / frame.sy) + 'px';
  }
  // The selection and hover outlines: one overlay each, on the border box of
  // the element carrying `data-isonim-selected` / `data-isonim-hovered`,
  // laid out like the selection handles (`fixedFrame`, `placeFixed`), so it
  // follows scroll, resize, a transform or `zoom` as they do. The element
  // itself is not touched. While the pointer is over the selected element
  // only the hover outline shows, as when both were the element's own
  // outline and the hover rule came later.
  // Each overlay is made once and hidden when it has no element, so showing
  // and hiding it adds and removes nothing.
  function outlineNode(id) {
    let node = document.getElementById(id);
    if (!node) {
      node = document.createElement('div');
      node.id = id;
      node.hidden = true;
      node.setAttribute('aria-hidden', 'true');
      chromeRoot().appendChild(node);
    }
    return node;
  }
  function placeOutline(id, el, frame) {
    const node = outlineNode(id);
    if (!el || !el.isConnected || !el.getClientRects().length) {
      node.hidden = true;
      return frame;
    }
    if (!frame) frame = fixedFrame();
    const rect = el.getBoundingClientRect();
    placeFixed(frame, node, rect.left, rect.top, rect.width, rect.height);
    node.hidden = false;
    return frame;
  }
  // The agent's highlight target (`__isonimAgentHighlight`), or null.
  let agentTarget = null;
  function syncOutlines(frame) {
    const selected = document.querySelector('[data-isonim-selected="true"]');
    const hovered = document.querySelector('[data-isonim-hovered="true"]');
    frame = placeOutline('isonim-editor-selection-outline',
      selected && selected !== hovered ? selected : null, frame);
    frame = placeOutline('isonim-editor-hover-outline', hovered, frame);
    placeOutline('isonim-editor-agent-highlight', agentTarget, frame);
    const agent = outlineNode('isonim-editor-agent-highlight');
    const beside = !!agentTarget && (agentTarget === selected || agentTarget === hovered);
    if (beside !== agent.hasAttribute('data-beside-outline')) {
      if (beside) agent.setAttribute('data-beside-outline', '');
      else agent.removeAttribute('data-beside-outline');
    }
    if (selected || hovered || agentTarget) watchChrome();
  }
  // The chrome follows its element wherever the page moves it: a layout
  // shift, a margin, an animation or transition, a transform on an ancestor
  // -- none of which the pointer, a scroll or a resize reports. While an
  // element carries chrome, one requestAnimationFrame loop compares the
  // border boxes it is placed on (and the chrome's containing block) with
  // the last frame's, and places the chrome again when one changed.
  //
  // One loop, never more: `watchHandle` is non-zero for as long as the loop
  // exists, including while a tick runs (-1), so a placement inside the tick
  // (placeHandles -> syncOutlines -> watchChrome) does not start another.
  //
  // It stops when nothing connected is selected, hovered or highlighted, when
  // the bridge is disposed and when the preview's frame is not shown (the
  // resize that shows it again places the chrome and starts it).
  //
  // While the selected element only moves (same size, same containing
  // block, same margins, borders and paddings), the selection chrome already
  // placed is shifted by the distance,
  // and the full placement (computed style, every handle, the guides) runs
  // once, in the first frame it has stopped moving.
  let watchHandle = 0;
  let watchLast = null;
  let watchSettled = true;
  // Where placeHandles last put the selection chrome: the element and its
  // border box, in client pixels.
  let chromePlacedAt = null;
  const SHIFTED_CHROME = ['isonim-editor-selection-handles', 'isonim-editor-gap-overlay',
    'isonim-editor-snap-lines', 'isonim-editor-spacing-measure',
    'isonim-editor-selection-breadcrumb'];
  function frameShown() {
    if (!bridgeFrame) return true;
    try {
      return bridgeFrame.isConnected && bridgeFrame.getClientRects().length > 0 &&
        parent.getComputedStyle(bridgeFrame).visibility !== 'hidden';
    } catch (e) { return true; }
  }
  function chromeTargets() {
    // A highlighted element the page removed is no longer highlighted.
    if (agentTarget && !agentTarget.isConnected) {
      agentTarget = null;
      outlineNode('isonim-editor-agent-highlight').hidden = true;
    }
    const live = function (el) { return el && el.isConnected ? el : null; };
    return [live(window.__isonimSelectedElement),
      live(document.querySelector('[data-isonim-hovered="true"]')), live(agentTarget)];
  }
  // The used margins, borders and paddings the box handles are placed from:
  // a move that changes one of them (an element moved by its own margin)
  // moves those handles relative to the border box, so it is placed in full.
  const SPACING = ['margin', 'border', 'padding'].reduce(function (all, part) {
    return all.concat(['top', 'right', 'bottom', 'left'].map(function (side) {
      return part === 'border' ? 'border-' + side + '-width' : part + '-' + side;
    }));
  }, []);
  function spacingOf(style) {
    return SPACING.map(function (name) { return style.getPropertyValue(name); }).join(' ');
  }
  function boxOf(el) {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { left: r.left, top: r.top, width: r.width, height: r.height };
  }
  // Also the selected element's margins, borders and paddings: a change that
  // leaves its border box where it is (padding under border-box) still moves
  // its padding or margin handles.
  function chromeState(targets) {
    return { targets: targets, boxes: targets.map(boxOf), frame: fixedFrame(),
      spacing: targets[0] ? spacingOf(window.getComputedStyle(targets[0])) : '' };
  }
  function sameBox(a, b) {
    return a === b || (!!a && !!b && a.left === b.left && a.top === b.top &&
      a.width === b.width && a.height === b.height);
  }
  function sameState(a, b) {
    return a.targets.every(function (t, i) { return t === b.targets[i]; }) &&
      a.boxes.every(function (box, i) { return sameBox(box, b.boxes[i]); }) &&
      a.frame.x === b.frame.x && a.frame.y === b.frame.y &&
      a.frame.sx === b.frame.sx && a.frame.sy === b.frame.sy && a.spacing === b.spacing;
  }
  function shiftSelectionChrome(dx, dy, frame) {
    SHIFTED_CHROME.forEach(function (id) {
      const node = document.getElementById(id);
      if (!node) return;
      node.style.left = ((parseFloat(node.style.left) || 0) + dx / frame.sx) + 'px';
      node.style.top = ((parseFloat(node.style.top) || 0) + dy / frame.sy) + 'px';
    });
    chromePlacedAt.left += dx;
    chromePlacedAt.top += dy;
  }
  // The outlines from boxes already read this frame (writes only).
  function placeOutlinesAt(state) {
    const selected = state.targets[0], hovered = state.targets[1], agent = state.targets[2];
    const put = function (id, box) {
      const node = outlineNode(id);
      if (!box) { if (!node.hidden) node.hidden = true; return; }
      placeFixed(state.frame, node, box.left, box.top, box.width, box.height);
      if (node.hidden) node.hidden = false;
    };
    put('isonim-editor-selection-outline',
      selected && selected !== hovered ? state.boxes[0] : null);
    put('isonim-editor-hover-outline', hovered ? state.boxes[1] : null);
    put('isonim-editor-agent-highlight', agent ? state.boxes[2] : null);
  }
  function stopWatch() {
    watchHandle = 0;
    watchLast = null;
    watchSettled = true;
  }
  function watchTick() {
    watchHandle = -1;
    if (bridgeDisposed || !frameShown()) { stopWatch(); return; }
    const targets = chromeTargets();
    if (!targets.some(Boolean)) { stopWatch(); return; }
    const now = chromeState(targets);
    const selected = targets[0];
    if (!watchLast || !sameState(watchLast, now)) {
      const placed = chromePlacedAt;
      const box = now.boxes[0];
      if (selected && placed && placed.el === selected && box &&
          box.width === placed.width && box.height === placed.height &&
          now.frame.sx === placed.sx && now.frame.sy === placed.sy &&
          now.frame.x === placed.fx && now.frame.y === placed.fy &&
          now.spacing === placed.spacing) {
        // Moved, not resized: shift what is placed, place the outlines.
        if (box.left !== placed.left || box.top !== placed.top)
          shiftSelectionChrome(box.left - placed.left, box.top - placed.top, now.frame);
        placeOutlinesAt(now);
        watchSettled = false;
        // Placing fixed chrome moves no page box: the boxes just read stand,
        // and are not read again after the writes (that would force layout).
        watchLast = now;
      } else {
        if (selected) placeHandles(selected);
        else syncOutlines();
        watchSettled = true;
        watchLast = chromeState(targets);
      }
    } else if (!watchSettled) {
      // It has stopped moving: the full placement, once.
      if (selected) placeHandles(selected);
      watchSettled = true;
      watchLast = chromeState(targets);
    }
    watchHandle = requestAnimationFrame(watchTick);
  }
  function watchChrome() {
    if (!watchHandle && !bridgeDisposed) watchHandle = requestAnimationFrame(watchTick);
  }
  // The loop stops while the frame is not shown. Showing it again resizes
  // the frame element, which places the chrome and starts the loop.
  if (bridgeFrame) {
    try {
      frameObserver = new parent.ResizeObserver(function () {
        if (bridgeDisposed || !frameShown()) return;
        const selected = window.__isonimSelectedElement;
        if (selected && selected.isConnected) placeHandles(selected);
        else syncOutlines();
      });
      frameObserver.observe(bridgeFrame);
    } catch (e) {}
  }
  // The agent's highlight, set from the editor (`control_browser.nim`):
  // drawn as chrome over `el`, never on it. Null clears it.
  window.__isonimAgentHighlight = function (el) {
    agentTarget = el && el.nodeType === 1 && el.ownerDocument === document ? el : null;
    syncOutlines();
    return agentTarget !== null;
  };
  // The chrome a hover shows, made now: a hover then only moves, shows and
  // hides it.
  ['isonim-editor-selection-outline', 'isonim-editor-hover-outline',
    'isonim-editor-agent-highlight'].forEach(outlineNode);
  ensureHoverLabel();
  fixedFrame();
  // Selection and hover are marked by these attributes wherever they are
  // set (pointer, Layers panel, restore, clear); the outlines follow them.
  new MutationObserver(function () {
    if (!bridgeDisposed) syncOutlines();
  }).observe(document.documentElement, {
    subtree: true, attributes: true,
    attributeFilter: ['data-isonim-selected', 'data-isonim-hovered']
  });
  // The resize handles' axes: the property, its limits, the edge it moves.
  const RESIZE_AXES = {
    width: { min: 'min-width', max: 'max-width', edge: 'right', scale: 'scaleX',
      side: 'right' },
    height: { min: 'min-height', max: 'max-height', edge: 'bottom', scale: 'scaleY',
      side: 'bottom' }
  };
  function inlineSnapshot(el, names) {
    return names.map(function (name) {
      return [name, el.style.getPropertyValue(name), el.style.getPropertyPriority(name)];
    });
  }
  function inlineRestore(el, snapshot) {
    snapshot.forEach(function (entry) {
      if (entry[1]) el.style.setProperty(entry[0], entry[1], entry[2]);
      else el.style.removeProperty(entry[0]);
    });
  }
  // The scroll offsets of the document and of `el`'s scrolled ancestors. A
  // trial size can shorten the page and the browser then clamps an offset;
  // the trials put back what they found.
  function scrollSnapshot(el) {
    const out = [];
    for (let node = el.parentElement; node; node = node.parentElement)
      if (node.scrollTop || node.scrollLeft) out.push([node, node.scrollLeft, node.scrollTop]);
    const root = document.scrollingElement;
    if (root) out.push([root, root.scrollLeft, root.scrollTop]);
    return out;
  }
  function scrollRestore(snapshot) {
    snapshot.forEach(function (entry) {
      if (entry[0].scrollLeft !== entry[1]) entry[0].scrollLeft = entry[1];
      if (entry[0].scrollTop !== entry[2]) entry[0].scrollTop = entry[2];
    });
  }
  // A transition on the size would make the trials and the drag preview read
  // its current value, not the requested one, and would fire transition
  // events into page code. Every handle drag holds `transition: none` inline
  // from the press to its end; `release` puts back the inline transition
  // exactly, after the size it restores has been computed, so nothing
  // animates back.
  const TRANSITION_LONGHANDS = ['transition-property', 'transition-duration',
    'transition-timing-function', 'transition-delay', 'transition-behavior'];
  // Holds nest: a box handle's release that waits for a native project's
  // answer keeps its hold until the answer, and a later drag on the same
  // element holds too. The first hold on an element takes the snapshot, and
  // the last release puts it back.
  const transitionHolds = new WeakMap();
  function holdTransitions(el) {
    let entry = transitionHolds.get(el);
    if (entry) entry.count++;
    else {
      entry = { count: 1, snapshot: inlineSnapshot(el, TRANSITION_LONGHANDS) };
      transitionHolds.set(el, entry);
      el.style.setProperty('transition', 'none', 'important');
    }
    let held = true;
    return {
      release: function () {
        if (!held) return;
        held = false;
        if (--entry.count > 0) return;
        transitionHolds.delete(el);
        void window.getComputedStyle(el).width;
        void window.getComputedStyle(el).height;
        TRANSITION_LONGHANDS.forEach(function (name) { el.style.removeProperty(name); });
        inlineRestore(el, entry.snapshot);
      }
    };
  }
  // What renders when the preview sets `axis` to `px`: its used value and
  // where the edge the handle sits on lands. With `free`, `min-*` and
  // `max-*` are lifted, to tell their clamp from anything else that holds the
  // size; with `important`, the preview's declaration outranks an
  // `!important` one in a style rule. Inline style is left as it was found
  // by the caller (`inlineRestore`): nothing is painted in between.
  function tryAxis(el, axis, px, free, important) {
    const a = RESIZE_AXES[axis];
    el.style.setProperty(axis, px + 'px', important ? 'important' : '');
    if (free) {
      el.style.setProperty(a.min, '0px', 'important');
      el.style.setProperty(a.max, 'none', 'important');
    }
    return {
      used: boxSizeFor(el, window.getComputedStyle(el))[axis],
      edge: el.getBoundingClientRect()[a.edge]
    };
  }
  // Why the preview's `axis` does not follow a drag, from what holds it.
  function heldReason(el, axis, start) {
    // A CSS animation of the size overrides every declaration that is not
    // `!important`, the preview's included, and the forced trial below would
    // then name an `!important` rule that does not exist.
    const animations = el.getAnimations ? el.getAnimations().filter(function (an) {
      if (typeof CSSTransition !== 'undefined' && an instanceof CSSTransition) return false;
      const effect = an.effect;
      return !!(effect && effect.getKeyframes) && effect.getKeyframes().some(function (k) {
        return Object.prototype.hasOwnProperty.call(k, axis);
      });
    }) : [];
    if (animations.length) return axis + ' does not follow the drag: an animation (' +
      (animations[0].animationName || animations[0].id || 'scripted') + ') decides it.';
    const snapshot = inlineSnapshot(el, [axis, RESIZE_AXES[axis].min, RESIZE_AXES[axis].max]);
    const scroll = scrollSnapshot(el);
    let important = false;
    try {
      const forced = tryAxis(el, axis, start + 20, true, true);
      important = Math.abs(forced.used - (start + 20)) < 0.5;
    } finally { inlineRestore(el, snapshot); scrollRestore(scroll); }
    if (important) return axis + ' does not follow the drag: an !important ' +
      axis + ' declaration decides it.';
    const parentStyle = el.parentElement ? window.getComputedStyle(el.parentElement) : null;
    const display = parentStyle ? parentStyle.display : '';
    if (display === 'flex' || display === 'inline-flex') {
      const row = parentStyle.flexDirection.indexOf('row') === 0;
      if (row === (axis === 'width')) return axis + ' does not follow the drag: ' +
        'flex layout decides it (flex: ' + window.getComputedStyle(el).flex + ').';
    }
    if (display === 'grid' || display === 'inline-grid')
      return axis + ' does not follow the drag: grid layout decides it.';
    return axis + ' does not follow the drag: the layout decides it.';
  }
  // A press on a resize handle: where the drag starts and how the edge the
  // handle sits on moves with the property, or why it cannot start.
  //   - The start is the used value in the box the property sets
  //     (https://www.w3.org/TR/css-sizing-3/#box-sizing): the content box for
  //     `content-box`, the border box for `border-box`. The resolved value is
  //     that used value, after `min-*` and `max-*`
  //     (https://www.w3.org/TR/cssom-1/#resolved-values).
  //   - Two trial sizes, 20px either side with `min-*`/`max-*` lifted, say
  //     whether the preview's declaration decides the size at all (an
  //     `!important` rule or flex sizing can hold it) and how far the
  //     handle's edge moves per pixel: 1 for a box laid out from its other
  //     edge, 1/2 for a centred one, 0 for one laid out from this edge,
  //     where the handle cannot follow the pointer.
  //   The trials are synchronous and restored before the browser paints.
  function planResize(el, axis) {
    const style = window.getComputedStyle(el);
    const box = boxSizeFor(el, style);
    if (box[axis] === null)
      return { refusal: axis + ' does not apply to an element with display: ' + style.display + '.' };
    const turned = transformRefusal(el);
    if (turned) return { refusal: turned };
    const a = RESIZE_AXES[axis];
    const start = box[axis];
    const scale = box[a.scale];
    const snapshot = inlineSnapshot(el, [axis, a.min, a.max]);
    const scroll = scrollSnapshot(el);
    const edge0 = el.getBoundingClientRect()[a.edge];
    // A factor outside 0.25..1.05 is not the edge following the size: the
    // trial size moved the element (its line wrapped, as in a full
    // `flex-wrap` row or a line of inline blocks), so the other direction is
    // tried before the press is refused.
    let factor = null;
    let followed = false;
    let pinned = false;
    try {
      [20, -20].forEach(function (d) {
        if (factor !== null || start + d < 0) return;
        const trial = tryAxis(el, axis, start + d, true, false);
        inlineRestore(el, snapshot);
        if (Math.abs(trial.used - (start + d)) >= 0.5) return;
        followed = true;
        const f = (trial.edge - edge0) / (d * scale);
        if (f >= 0.25 && f <= 1.05) factor = f;
        else if (Math.abs(f) < 0.25) pinned = true;
      });
    } finally {
      inlineRestore(el, snapshot);
      scrollRestore(scroll);
    }
    if (factor !== null) return { start: start, scale: scale, factor: factor };
    if (!followed) return { refusal: heldReason(el, axis, start) };
    // In a line that wraps, a larger size can push the element onto the next
    // line and a smaller one pull it back, but not both: the element is at
    // the end of its line, or at the start of one. So a wrap seen one way is
    // decided by the other trial; where that trial cannot run (a size under
    // 20px has no smaller one), only the wrap was seen.
    if (!pinned) return { refusal: 'Resizing moves this element instead of its ' + a.side +
      ' edge (its line wraps). Set ' + axis + ' in the inspector.' };
    return { refusal: 'Resizing does not move the ' + a.side +
      ' edge of this element: its layout places it from that edge. Set ' + axis +
      ' in the inspector.' };
  }
  // The used gap the spacing handle starts from, in pixels: a percentage
  // resolves against the content box (column gaps against its width, row
  // gaps against its height, https://www.w3.org/TR/css-align-3/#column-row-gap).
  // The handle drags the gap between the items: the row gap in a column
  // flex container, the column gap otherwise.
  function usedGap(el, style) {
    const column = style.display.indexOf('flex') >= 0 &&
      style.flexDirection.indexOf('column') === 0;
    const text = style.getPropertyValue(column ? 'row-gap' : 'column-gap').trim();
    if (!text || text === 'normal') return 0;
    if (text.slice(-1) !== '%') return parseFloat(text) || 0;
    const n = function (name) { return parseFloat(style.getPropertyValue(name)) || 0; };
    const box = boxSizeFor(el, style);
    const border = style.boxSizing === 'border-box';
    const content = column
      ? (box.height || 0) - (border ? n('padding-top') + n('padding-bottom') +
        n('border-top-width') + n('border-bottom-width') : 0)
      : (box.width || 0) - (border ? n('padding-left') + n('padding-right') +
        n('border-left-width') + n('border-right-width') : 0);
    return (parseFloat(text) || 0) * Math.max(0, content) / 100;
  }
  function startHandleDrag(handleEl, event, gesture) {
    cancelHandleDrag();
    const drag = {
      pointerId: event.pointerId,
      startX: event.clientX,
      startY: event.clientY,
      element: window.__isonimSelectedElement,
      moved: false
    };
    function release() {
      if (handleDrag === drag) handleDrag = null;
      window.removeEventListener('pointermove', onMove, true);
      window.removeEventListener('pointerup', onUp, true);
      window.removeEventListener('pointercancel', onLost, true);
      handleEl.removeEventListener('lostpointercapture', onLost);
      handleEl.removeAttribute('data-dragging');
      try {
        if (handleEl.hasPointerCapture(drag.pointerId))
          handleEl.releasePointerCapture(drag.pointerId);
      } catch (error) {}
    }
    function onMove(moveEvent) {
      if (moveEvent.pointerId !== drag.pointerId) return;
      moveEvent.preventDefault();
      const dx = moveEvent.clientX - drag.startX;
      const dy = moveEvent.clientY - drag.startY;
      if (!drag.moved && !dx && !dy) return;
      drag.moved = true;
      if (gesture.move(dx, dy) === false) cancelHandleDrag();
    }
    function onUp(upEvent) {
      if (upEvent.pointerId !== drag.pointerId) return;
      release();
      if (drag.moved) gesture.commit(); else gesture.cancel();
    }
    function onLost(lostEvent) {
      if (lostEvent.pointerId !== drag.pointerId) return;
      if (handleDrag === drag) cancelHandleDrag();
    }
    drag.cancel = function () { release(); gesture.cancel(); };
    handleDrag = drag;
    window.addEventListener('pointermove', onMove, true);
    window.addEventListener('pointerup', onUp, true);
    window.addEventListener('pointercancel', onLost, true);
    handleEl.addEventListener('lostpointercapture', onLost);
    handleEl.setAttribute('data-dragging', 'true');
    // Capture keeps the drag on the handle when the pointer leaves it
    // (https://w3c.github.io/pointerevents/#pointer-capture); focus puts
    // Escape where the drag can hear it.
    try { handleEl.setPointerCapture(event.pointerId); } catch (error) {}
    try { handleEl.focus({ preventScroll: true }); } catch (error) {}
    event.preventDefault();
  }
  // Escape ends a drag before anything else sees it: in this document the
  // key would otherwise clear the selection.
  window.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape' || !handleDrag) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    cancelHandleDrag();
  }, true);
  bindParent('keydown', function (event) {
    if (event.key !== 'Escape' || !handleDrag) return;
    event.preventDefault();
    cancelHandleDrag();
  });
  // A margin or padding drag asks the editor, synchronously, what each step
  // means: the reply comes back on the event (`d.reply`). The editor decides
  // the value, keeps the drag in its box model's fields and commits it on
  // release through the box model's pipeline (`section_box_model`).
  function boxDragRequest(detail) {
    try {
      parent.dispatchEvent(new CustomEvent('isonim-preview-box-drag', { detail: detail }));
    } catch (error) { return ''; }
    return String(detail.reply || '');
  }
  // The live preview is an editor-owned rule, not an inline declaration: the
  // commit's own preview resolves the rule or inline owner the cascade uses
  // (`__isonimSetDeclaration`), and must not find the drag there. Each drag
  // has its own rule, keyed by a token on the element it previews: a release
  // still waiting for a native project's answer keeps its preview while a
  // newer drag shows another, and the late answer removes only its own.
  const boxPreviews = new Map();
  let boxPreviewSerial = 0;
  function renderBoxPreviews() {
    let sheet = document.getElementById('isonim-editor-box-drag-preview');
    if (!sheet) {
      if (!boxPreviews.size) return;
      sheet = document.createElement('style');
      sheet.id = 'isonim-editor-box-drag-preview';
      (document.head || document.documentElement).appendChild(sheet);
    }
    sheet.textContent = Array.from(boxPreviews.values(),
      function (entry) { return entry.rule; }).join('\n');
  }
  function showBoxPreview(owner, el, property, value) {
    let entry = boxPreviews.get(owner);
    if (!entry) {
      entry = { el: el, token: String(++boxPreviewSerial), rule: '' };
      boxPreviews.set(owner, entry);
    }
    el.setAttribute('data-isonim-box-drag-preview', entry.token);
    entry.rule = '[data-isonim-box-drag-preview="' + entry.token + '"] { ' +
      property + ': ' + value + ' !important; }';
    renderBoxPreviews();
  }
  // While a release commits (`commitOutcome`), whether every declaration the
  // commit set could be shown (`__isonimDeclarationOutcome`, from the
  // runtime). One that could not -- the preview cannot tell which rule the
  // edit belongs in -- leaves the drag's preview in place, `kept`, holding
  // that declaration (property, writer's rule, condition), so the box does
  // not snap back to the old value. It is released by whatever comes next
  // for it: the write's reload replaces the document; a later declaration of
  // the same property (its shorthand or a longhand included) in the same rule
  // and condition -- an edit or an undo -- takes over; and a write that does
  // not reload the preview (a failed write, a staging-only project) releases
  // every hold (`isonim-preview-release-held`), since no result is coming.
  let commitOutcome = null;
  window.__isonimDeclarationOutcome = function (property, shown, rule, condition, touches) {
    if (commitOutcome) {
      if (!shown && !commitOutcome.unshown) {
        commitOutcome.unshown = true;
        commitOutcome.held = { property: property, rule: rule || '', condition: condition || '' };
      }
      return;
    }
    const names = touches || [property];
    for (const [owner, entry] of Array.from(boxPreviews.entries())) {
      if (entry.kept && entry.held && names.indexOf(entry.held.property) >= 0 &&
          entry.held.rule === (rule || '') && entry.held.condition === (condition || '')) {
        clearBoxPreview(owner);
      }
    }
  };
  bindParent('isonim-preview-release-held', function () {
    for (const [owner, entry] of Array.from(boxPreviews.entries())) {
      if (entry.kept) clearBoxPreview(owner);
    }
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
  });
  function clearBoxPreview(owner) {
    const entry = boxPreviews.get(owner);
    if (!entry) return;
    boxPreviews.delete(owner);
    if (entry.el.getAttribute('data-isonim-box-drag-preview') === entry.token)
      entry.el.removeAttribute('data-isonim-box-drag-preview');
    renderBoxPreviews();
  }
  function hideBoxMessage() {
    const note = document.getElementById('isonim-editor-box-drag-message');
    if (note) note.remove();
  }
  function showBoxMessage(el, text) {
    const note = ensureLayoutGuide('isonim-editor-box-drag-message');
    note.setAttribute('role', 'alert');
    note.dataset.layoutGuide = 'box-drag-message';
    note.textContent = text;
    const rect = el.getBoundingClientRect();
    placeFixed(fixedFrame(), note, Math.max(6, Math.min(rect.left, window.innerWidth - 292)),
      Math.max(6, Math.min(window.innerHeight - 48, rect.bottom + 40)));
  }
  function startBoxSideDrag(handleEl, handle, selected, event) {
    hideBoxMessage();
    const turned = transformRefusal(selected);
    if (turned) { showBoxMessage(selected, turned); return; }
    const startStyle = window.getComputedStyle(selected);
    const startPx = parseFloat(startStyle.getPropertyValue(handle)) || 0;
    // The side follows the pointer: the distance is in the element's own CSS
    // pixels, the pointer's over its scale (a `zoom` or scale transform on
    // it or an ancestor).
    const scaled = boxSizeFor(selected, startStyle);
    // A side the drag cannot move (`auto`, a variable) is refused at the
    // press, with the reason beside the selection.
    const property = boxDragRequest({ phase: 'start', handle: handle,
      allSides: !!event.shiftKey, settle: function (ok, message) {
        if (!ok && message) showBoxMessage(selected, String(message));
      } });
    if (!property) return;
    // The preview shows the dragged value at once, as for the resize handles.
    const transitions = holdTransitions(selected);
    const owner = {};
    let value = '';
    startHandleDrag(handleEl, event, {
      move: function (dx, dy) {
        const next = boxDragRequest({ phase: 'move', start: startPx,
          dx: dx / scaled.scaleX, dy: dy / scaled.scaleY });
        if (!next) return false;
        value = next;
        if (handleDrag) handleDrag.readout = property + ': ' + value;
        showBoxPreview(owner, selected, property, value);
        placeHandles(selected);
      },
      cancel: function () {
        boxDragRequest({ phase: 'cancel' });
        clearBoxPreview(owner);
        transitions.release();
        if (window.__isonimSelectedElement === selected) placeHandles(selected);
      },
      commit: function () {
        // The preview stays until the editor has answered: a native project
        // answers later, and the commit's own preview replaces it.
        let settled = false;
        const outcome = { unshown: false };
        const settle = function (ok, message) {
          if (settled) return;
          settled = true;
          const entry = boxPreviews.get(owner);
          if (ok && outcome.unshown && entry) {
            entry.kept = true;
            entry.held = outcome.held;
          }
          else clearBoxPreview(owner);
          transitions.release();
          if (window.__isonimSelectedElement !== selected) return;
          placeHandles(selected);
          if (!ok && message) showBoxMessage(selected, String(message));
        };
        commitOutcome = outcome;
        let reply = '';
        try {
          reply = boxDragRequest({ phase: 'commit', settle: settle });
        } finally {
          commitOutcome = null;
        }
        if (!reply) settle(true, '');
      }
    });
  }
  // A resize or spacing release the editor refused at the act (its answer on
  // the event, `detail.refused`: the reason): the preview is put back to
  // what it showed before the drag -- what the file renders -- at once, under
  // a fresh transition hold (the drag's own was released before the
  // dispatch, so a transition on the property would otherwise animate the
  // snap-back), and the reason is shown beside the selection, as a box
  // handle's refusal is (editor spec "Saving": a refused change never
  // reaches the preview).
  // The late answer to a release the editor sent to a native project's
  // writer (`detail.pending`; editor spec "Edit Mode": the resize handles
  // edit width and height like the property's row): the preview keeps the
  // dragged value until then; a refusal puts it back with the reason, as an
  // act-time refusal does, and an accepted write is shown by the rebuilt
  // catalog's preview.
  function lateRelease(selected, restore) {
    return function (ok, message) {
      if (ok) return;
      const hold = holdTransitions(selected);
      restore();
      hold.release();
      if (window.__isonimSelectedElement === selected)
        showBoxMessage(selected, String(message || 'This canvas edit was refused.'));
    };
  }
  function refusedRelease(released, selected, restore) {
    const reason = released.detail && released.detail.refused;
    if (!reason) return;
    const hold = holdTransitions(selected);
    restore();
    hold.release();
    if (window.__isonimSelectedElement === selected) showBoxMessage(selected, String(reason));
  }
  // The selection's `width` (the corner handle) or `height` (the bottom
  // handle): the property its Layout row shows. The edge follows the
  // pointer: the property changes by the distance over the element's own
  // scale and over how far the edge moves per pixel (`planResize`).
  // `min-*`/`max-*` clamp the value, and the value written is the one the box
  // shows; anything else holding the size ends the drag with the reason.
  function startResizeDrag(handleEl, axis, selected, event) {
    hideBoxMessage();
    const transitions = holdTransitions(selected);
    const plan = planResize(selected, axis);
    if (plan.refusal) {
      transitions.release();
      showBoxMessage(selected, plan.refusal);
      return;
    }
    const a = RESIZE_AXES[axis];
    const source = parseSource(selected.getAttribute('data-isonim-src'));
    const marker = 'data-isonim-layout-resized';
    // What the drag replaces, for Escape and pointer cancellation.
    const before = {
      value: selected.style.getPropertyValue(axis),
      priority: selected.style.getPropertyPriority(axis),
      marked: selected.hasAttribute(marker)
    };
    const limits = inlineSnapshot(selected, [a.min, a.max]);
    let next = '';
    const restore = function () {
      if (before.value) selected.style.setProperty(axis, before.value, before.priority);
      else selected.style.removeProperty(axis);
      if (!before.marked) selected.removeAttribute(marker);
      transitions.release();
      if (window.__isonimSelectedElement === selected) placeHandles(selected);
    };
    const start = Math.round(plan.start);
    startHandleDrag(handleEl, event, {
      move: function (dx, dy) {
        // The preview's zoom scales the frame from outside, and its pointer
        // events already arrive in the document's pixels.
        const d = axis === 'width' ? dx : dy;
        const requested = Math.max(0, Math.round(plan.start + d / (plan.scale * plan.factor)));
        selected.style.setProperty(axis, requested + 'px');
        const shown = boxSizeFor(selected, window.getComputedStyle(selected))[axis];
        let note = '';
        if (Math.abs(shown - requested) >= 0.5) {
          // Only `min-*` and `max-*` may hold the value: lifted, the box
          // must take the request.
          const free = tryAxis(selected, axis, requested, true, false);
          inlineRestore(selected, limits);
          selected.style.setProperty(axis, requested + 'px');
          if (Math.abs(free.used - requested) >= 0.5) {
            showBoxMessage(selected, heldReason(selected, axis, plan.start));
            return false;
          }
          note = ' (clamped from ' + requested + 'px by ' +
            (shown < requested ? a.max : a.min) + ')';
        }
        const value = Math.round(shown);
        next = value === start ? '' : value + 'px';
        if (handleDrag) handleDrag.readout = axis + ': ' + value + 'px' + note;
        selected.setAttribute(marker, 'true');
        placeHandles(selected);
      },
      cancel: restore,
      // One edit, on release. A drag that ends on the value in place (or
      // that `min-*`/`max-*` held there) commits nothing.
      commit: function () {
        if (!next) { restore(); return; }
        transitions.release();
        const released = new CustomEvent('isonim-preview-direct-manipulation', {
          detail: {
            kind: 'resize',
            property: axis,
            value: next,
            sourceFile: source.file,
            sourceLine: source.line,
            handle: axis === 'width' ? 'se' : 'height',
            sourceKey: sourceKeyFor(selected),
            measurement: axis + '=' + next,
            settle: lateRelease(selected, restore)
          }
        });
        parent.dispatchEvent(released);
        refusedRelease(released, selected, restore);
      }
    });
  }
  // The spacing handle: `gap` in a flex or grid container, otherwise uniform
  // `padding`, from its used value in pixels (a percentage gap resolved,
  // `usedGap`), moved by the vertical distance over the element's scale.
  function startSpacingDrag(handleEl, selected, event) {
    hideBoxMessage();
    const turned = transformRefusal(selected);
    if (turned) { showBoxMessage(selected, turned); return; }
    const style = window.getComputedStyle(selected);
    const scaled = boxSizeFor(selected, style);
    const property =
      (style.display === 'flex' || style.display === 'grid' || style.gap !== 'normal')
        ? 'gap'
        : 'padding';
    const startSpacing = property === 'gap' ? usedGap(selected, style)
      : parseFloat(style.paddingTop) || 0;
    const source = parseSource(selected.getAttribute('data-isonim-src'));
    const marker = 'data-isonim-spacing-adjusted';
    // The preview shows the dragged value at once, as for the resize handles.
    const transitions = holdTransitions(selected);
    const before = {
      value: selected.style.getPropertyValue(property),
      priority: selected.style.getPropertyPriority(property),
      marked: selected.hasAttribute(marker)
    };
    let next = '';
    const restore = function () {
      if (before.value) selected.style.setProperty(property, before.value, before.priority);
      else selected.style.removeProperty(property);
      if (!before.marked) selected.removeAttribute(marker);
      transitions.release();
      if (window.__isonimSelectedElement === selected) placeHandles(selected);
    };
    startHandleDrag(handleEl, event, {
      move: function (dx, dy) {
        next = Math.max(0, Math.round(startSpacing + dy / scaled.scaleY)) + 'px';
        selected.style.setProperty(property, next);
        selected.setAttribute(marker, 'true');
        placeHandles(selected);
      },
      cancel: restore,
      commit: function () {
        if (!next) { restore(); return; }
        transitions.release();
        const released = new CustomEvent('isonim-preview-direct-manipulation', {
          detail: {
            kind: 'spacing',
            property: property,
            value: next,
            sourceFile: source.file,
            sourceLine: source.line,
            handle: 'spacing',
            sourceKey: sourceKeyFor(selected),
            measurement: property + '=' + next,
            settle: lateRelease(selected, restore)
          }
        });
        parent.dispatchEvent(released);
        refusedRelease(released, selected, restore);
      }
    });
  }
  function ensureHandles() {
    let box = document.getElementById('isonim-editor-selection-handles');
    if (!box) {
      box = document.createElement('div');
      box.id = 'isonim-editor-selection-handles';
      // The resize handles sit on the edges they move: the right edge
      // (`width`) and the bottom edge (`height`). A handle on the left or top
      // edge could move it only by moving the element (its position or a
      // margin), which a size does not do, so there is none.
      ['se','height','spacing'].forEach((name) => {
        const handle = document.createElement('span');
        handle.dataset.handle = name;
        box.appendChild(handle);
      });
      BOX_HANDLES.forEach((name) => {
        // `data-box-handle`, not `data-handle`: these edit the box model's
        // properties, apart from the resize and spacing handles.
        const handle = document.createElement('span');
        handle.dataset.boxHandle = name;
        handle.dataset.layoutHandle = name;
        handle.tabIndex = -1;
        const label = 'Adjust ' + name.replace('-', ' ');
        handle.setAttribute('aria-label', label);
        handle.title = label + ' (drag; Shift sets every side)';
        box.appendChild(handle);
      });
      chromeRoot().appendChild(box);
      box.addEventListener('pointerdown', function (event) {
        const data = event.target && event.target.dataset ? event.target.dataset : {};
        const selected = window.__isonimSelectedElement;
        if (!selected || event.button !== 0) return;
        if (data.boxHandle) {
          if (editorMode === 'edit') startBoxSideDrag(event.target, data.boxHandle, selected, event);
          return;
        }
        const handle = data.handle || '';
        if (!handle) return;
        if (handle === 'spacing') startSpacingDrag(event.target, selected, event);
        else startResizeDrag(event.target, handle === 'height' ? 'height' : 'width',
          selected, event);
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
      chromeRoot().appendChild(crumb);
    }
    return crumb;
  }
  function ensureLayoutGuide(id) {
    let guide = document.getElementById(id);
    if (!guide) {
      guide = document.createElement('div');
      guide.id = id;
      guide.className = 'isonim-editor-layout-guide';
      chromeRoot().appendChild(guide);
    }
    return guide;
  }
  function placeLayoutGuides(el, rect, frame) {
    const style = window.getComputedStyle(el);
    const gapOverlay = ensureLayoutGuide('isonim-editor-gap-overlay');
    gapOverlay.setAttribute('aria-label', 'Canvas gap overlay');
    gapOverlay.dataset.layoutGuide = 'gap-overlay';
    placeFixed(frame, gapOverlay, rect.right + 8, rect.top,
      Math.max(12, parseFloat(style.columnGap || style.gap || '0') || 12),
      Math.max(18, Math.min(rect.height, 64)));
    gapOverlay.textContent = (style.gap && style.gap !== 'normal' ? style.gap : 'gap');

    const snap = ensureLayoutGuide('isonim-editor-snap-lines');
    snap.setAttribute('aria-label', 'Canvas snap lines');
    snap.dataset.layoutGuide = 'snap-lines';
    placeFixed(frame, snap, rect.left, rect.top, Math.max(1, rect.width),
      Math.max(1, rect.height));

    const measure = ensureLayoutGuide('isonim-editor-spacing-measure');
    measure.setAttribute('aria-label', 'Canvas spacing measurement');
    measure.dataset.layoutGuide = 'spacing-measurement';
    placeFixed(frame, measure, Math.max(6, rect.left), Math.max(6, rect.top - 22));
    // While a margin or padding handle is dragged, the readout is its value.
    measure.textContent = (handleDrag && handleDrag.readout) ||
      (Math.round(rect.width) + ' x ' + Math.round(rect.height));
  }
  // Every handle keeps a point that a press reaches. On a small box the
  // handles meet (the bottom padding handle lies over the corner width
  // handle on a box under about 20px wide): a handle whose centre another
  // drawn above it covers (a press there reaches the other) is moved
  // outwards, along the direction it faces, in 3px steps, until its centre
  // is clear.
  const HANDLE_OUTWARDS = {
    se: [1, 1], height: [0, 1], spacing: [0, 1],
    'margin-top': [0, -1], 'padding-top': [0, -1],
    'margin-bottom': [0, 1], 'padding-bottom': [0, 1],
    'margin-left': [-1, 0], 'padding-left': [-1, 0],
    'margin-right': [1, 0], 'padding-right': [1, 0]
  };
  function separateHandles(box) {
    const nodes = Array.prototype.filter.call(box.children, function (node) {
      return node.offsetParent !== null || node.getClientRects().length > 0;
    });
    // The preview's viewport: a handle outside it cannot be pressed (a box
    // flush with an edge has its margin handles there).
    const vw = document.documentElement.clientWidth;
    const vh = document.documentElement.clientHeight;
    // The box the handles edit (the overlay sits on its border box).
    const edges = box.getBoundingClientRect();
    // From the top down, so each handle is tested against the final places
    // of those above it.
    for (let i = nodes.length - 1; i >= 0; i--) {
      const node = nodes[i];
      const way = HANDLE_OUTWARDS[node.dataset.handle || node.dataset.boxHandle] || [1, 1];
      node.style.translate = '';
      const base = node.getBoundingClientRect();
      // Offsets to try, in order: in place, then outwards in 3px steps (up to
      // 36px), then along the handle's edge either way (up to 72px: in a
      // viewport corner the handles of a small box crowd together), and for
      // a handle the viewport cuts off, inwards. Each is pulled back inside the
      // viewport, so a handle at a viewport edge moves inwards only as far
      // as it must.
      const tries = [[0, 0]];
      for (let k = 1; k <= 12; k++) tries.push([way[0] * 3 * k, way[1] * 3 * k]);
      // A corner handle has two edges: it tries up its right edge and left
      // along its bottom edge in turn, nearest first.
      const along = way[0] && way[1] ? [[0, -1], [-1, 0]]
        : [[way[1], way[0]], [-way[1], -way[0]]];
      for (let k = 1; k <= 24; k++) along.forEach(function (d) {
        tries.push([d[0] * 3 * k, d[1] * 3 * k]);
      });
      // A handle the viewport cuts off, with no room along its edge, moves
      // inwards as a last resort (a small box in a viewport corner).
      if (base.left < 1 || base.top < 1 || base.right > vw - 1 || base.bottom > vh - 1)
        for (let k = 1; k <= 12; k++) tries.push([-way[0] * 3 * k, -way[1] * 3 * k]);
      const inside = function (offset, start, end, size) {
        return offset + Math.max(0, 1 - (start + offset)) - Math.max(0, end + offset - (size - 1));
      };
      // A move along an edge stops at the far end of that edge: some of the
      // handle stays over the edge it edits, on the box's own side.
      const pastFarEnd = function (dx, dy) {
        const alongX = way[0] === 0 || (way[1] !== 0 && dx < 0);
        const alongY = way[1] === 0 || (way[0] !== 0 && dy < 0);
        return (alongX && ((dx < 0 && base.right + dx < edges.left) ||
            (dx > 0 && base.left + dx > edges.right))) ||
          (alongY && ((dy < 0 && base.bottom + dy < edges.top) ||
            (dy > 0 && base.top + dy > edges.bottom)));
      };
      let placed = false;
      for (let t = 0; t < tries.length && !placed; t++) {
        const dx = inside(tries[t][0], base.left, base.right, vw);
        const dy = inside(tries[t][1], base.top, base.bottom, vh);
        if ((dx || dy) && pastFarEnd(dx, dy)) continue;
        node.style.translate = dx || dy ? dx + 'px ' + dy + 'px' : '';
        const r = node.getBoundingClientRect();
        // What a press at the centre reaches: another handle, or other
        // selection chrome (the breadcrumb), covers it.
        const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        placed = !!hit && (hit === node || node.contains(hit));
      }
      if (!placed) node.style.translate = '';
    }
  }
  function placeHandles(el) {
    const box = ensureHandles();
    const rect = el.getBoundingClientRect();
    // Laid out in the overlay's containing block, which a transform on
    // `body` moves and scales (`fixedFrame`).
    const frame = fixedFrame();
    placeFixed(frame, box, rect.left, rect.top, rect.width, rect.height);
    chromePlacedAt = { el: el, left: rect.left, top: rect.top, width: rect.width,
      height: rect.height, sx: frame.sx, sy: frame.sy, fx: frame.x, fy: frame.y };
    // On the edges they move: `width` at the bottom-right corner, `height`
    // on the bottom edge left of the bottom margin and padding handles, the
    // spacing handle right of them.
    box.querySelector('[data-handle="se"]').style.cssText = 'right:-4px;bottom:-4px';
    // On a box narrower than about 64px those places lie past the ends of
    // the bottom edge, so each is held over the edge (`max`, `min`).
    box.querySelector('[data-handle="height"]').style.cssText = 'left:max(-4px, calc(50% - 32px));bottom:-4px';
    box.querySelector('[data-handle="spacing"]').style.cssText = 'left:min(calc(100% - 6px), calc(50% + 14px));bottom:-18px';
    box.querySelector('[data-handle="se"]').setAttribute('aria-label', 'Resize selected element');
    box.querySelector('[data-handle="se"]').dataset.layoutHandle = 'resize';
    box.querySelector('[data-handle="height"]').setAttribute('aria-label', 'Adjust selected element height');
    box.querySelector('[data-handle="height"]').dataset.layoutHandle = 'resize-height';
    box.querySelector('[data-handle="spacing"]').setAttribute('aria-label', 'Adjust selected spacing');
    box.querySelector('[data-handle="spacing"]').dataset.layoutHandle = 'spacing';
    // A padding handle sits on its side's content edge, inside the border and
    // the padding; a margin handle on the margin edge, outside. Both follow
    // the box as a drag previews it. Offsets are from the overlay's 1px
    // border, in the overlay's pixels: the element's used values times its
    // scale (`zoom` or a scale transform) over the overlay's. Editing, not
    // reviewing: shown in Edit mode only.
    const boxStyle = window.getComputedStyle(el);
    chromePlacedAt.spacing = spacingOf(boxStyle);
    const scaled = boxSizeFor(el, boxStyle);
    const used = function (name) { return parseFloat(boxStyle.getPropertyValue(name)) || 0; };
    BOX_HANDLES.forEach(function (name) {
      const node = box.querySelector('[data-box-handle="' + name + '"]');
      if (!node) return;
      const dash = name.indexOf('-');
      const side = name.slice(dash + 1);
      const across = (side === 'top' || side === 'bottom')
        ? scaled.scaleY / frame.sy : scaled.scaleX / frame.sx;
      const offset = name.slice(0, dash) === 'padding'
        ? (used('border-' + side + '-width') + used('padding-' + side)) * across - 1
        : -used('margin-' + side) * across - 7;
      const along = (side === 'top' || side === 'bottom')
        ? 'left:calc(50% - 8px)' : 'top:calc(50% - 8px)';
      node.style.cssText = along + ';' + side + ':' + offset + 'px' +
        (editorMode === 'edit' ? '' : ';display:none');
    });
    placeLayoutGuides(el, rect, frame);
    syncOutlines(frame);
    const crumb = ensureBreadcrumb();
    const stack = ancestorStack(el).reverse();
    // Where the repeat-click climb currently is. Without this the operator
    // has no way to tell a climb that has reached the outermost element
    // from a click that did nothing.
    const position = drillPosition(el);
    const chips = stack.map(stableSelector);
    const drillText = position > 0
      ? '↑ ' + (position + 1) + '/' + drill.chain.length +
        (position === drill.chain.length - 1 ? ' top' : '')
      : '';
    // Rebuilt only when it says something else: placing the chrome again (a
    // pointer move, the element moving) changes nothing in it.
    const crumbText = JSON.stringify([chips, drillText]);
    if (crumb.dataset.crumbText !== crumbText) {
      crumb.dataset.crumbText = crumbText;
      crumb.innerHTML = '';
      chips.forEach((text) => {
        const chip = document.createElement('span');
        chip.textContent = text;
        crumb.appendChild(chip);
      });
      if (drillText) {
        const chip = document.createElement('span');
        chip.dataset.drill = 'position';
        chip.textContent = drillText;
        crumb.appendChild(chip);
      }
    }
    placeFixed(frame, crumb, Math.max(6, Math.min(rect.left, window.innerWidth - 280)),
      Math.min(window.innerHeight - 30, rect.bottom + 8));
    crumb.hidden = false;
    // Last, after the guides and the breadcrumb are in place: a handle is
    // tested against where they are now.
    separateHandles(box);
  }
  // Which declaration block decides each side of a simple shorthand, measured
  // rather than inferred, without changing what the preview renders.
  //
  // The element's inline style is judged, not probed: it decides a side it
  // declares unless a matching rule declares the side `!important` over a
  // normal inline declaration (then the rules are probed). Writing it would
  // also hand every MutationObserver on the element a record.
  //
  // A rule is probed: given a probe value for the side, the one whose probe
  // moves the computed side is the one the cascade uses -- importance,
  // layers, specificity and order included. A rule is probed only when its
  // declarations round-trip exactly through their own text (re-parsed in a
  // scratch, unattached sheet: the same cssText, and every longhand with the
  // same value and priority), because putting it back is setting that text.
  // A `var()` shorthand partly overridden by a side does not round-trip --
  // Chromium serialises its other longhands as `padding-right: ;` -- so such
  // a rule is not touched and its sides stay unmeasured. Transitions are
  // switched off for the probe by an adopted, unattached sheet (no DOM
  // mutation), and the element's style is read back once more before it is
  // removed, so no transition starts from a probe value.
  //
  // A rule is named by its conditions (`@media`, `@supports`, `@container`,
  // `@layer`, `@scope`) and selector, as a writer's `ruleDeclarations` names
  // it. A name two matching rules share (the same selector in two sheets) is
  // ambiguous and reported unmeasured. One `side<TAB>rule[<TAB>specified]`
  // line per side -- `specified` being the deciding block's text for the side
  // when it is not a plain length (read into `authoredValue`, so a field and a
  // canvas handle see `var(--space)` rather than the `16px` it resolves to);
  // the rule is `style` for the inline style, `none` when nothing declares
  // the side. And one
  // `@matched<TAB>names` line with every matching rule's name, separated by
  // U+001F, so the editor can tell a writer's rule the capture does not know
  // from one that decides nothing. Read by `previewDomElementRef`.
  const ISONIM_SHORTHAND_SIDES = {
    'padding': ['padding-top', 'padding-right', 'padding-bottom', 'padding-left'],
    'margin': ['margin-top', 'margin-right', 'margin-bottom', 'margin-left'],
    'border-radius': ['border-top-left-radius', 'border-top-right-radius',
      'border-bottom-right-radius', 'border-bottom-left-radius']
  };
  function ruleIdentity(rule) {
    const parts = [rule.selectorText];
    for (let parent = rule.parentRule; parent; parent = parent.parentRule) {
      const kind = parent.constructor && parent.constructor.name;
      if (kind === 'CSSMediaRule') parts.unshift('@media ' + parent.conditionText);
      else if (kind === 'CSSSupportsRule') parts.unshift('@supports ' + parent.conditionText);
      else if (kind === 'CSSContainerRule') parts.unshift('@container ' + parent.conditionText);
      else if (kind === 'CSSLayerBlockRule') parts.unshift('@layer ' + parent.name);
      else if (kind === 'CSSScopeRule') parts.unshift('@scope (' + (parent.start || '') + ')' +
        (parent.end ? ' to (' + parent.end + ')' : ''));
      else if (kind === 'CSSStyleRule') parts.unshift(parent.selectorText);
      else parts.unshift('@' + (kind || 'unknown'));
    }
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }
  function matchingStyleRules(el, skip) {
    // `found.unreadable` counts the sheets whose rules could not be read (a
    // cross-origin sheet): their declarations are invisible here.
    const found = [];
    found.unreadable = 0;
    function visit(rules) {
      for (const rule of rules) {
        if (rule.type === CSSRule.MEDIA_RULE) {
          let holds = false;
          try { holds = matchMedia(rule.conditionText).matches; } catch (e) {}
          if (holds) visit(rule.cssRules);
        } else if (rule.type === CSSRule.STYLE_RULE) {
          let matches = false;
          try { matches = el.matches(rule.selectorText); } catch (e) {}
          if (matches) found.push(rule);
          if (rule.cssRules && rule.cssRules.length) visit(rule.cssRules);
        } else if (rule.cssRules) {
          visit(rule.cssRules);
        }
      }
    }
    const sheets = [...document.styleSheets, ...(document.adoptedStyleSheets || [])];
    for (const sheet of sheets) {
      if (sheet.disabled || sheet === skip) continue;
      let rules = null;
      try { rules = sheet.cssRules; } catch (e) { found.unreadable++; continue; }
      visit(rules);
    }
    return found;
  }
  function blockSnapshot(style) {
    const longhands = [];
    for (let i = 0; i < style.length; i++) {
      const name = style[i];
      longhands.push(name + ':' + style.getPropertyValue(name) + '!' + style.getPropertyPriority(name));
    }
    return style.cssText + '\n' + longhands.join(';');
  }
  function roundTrips(style) {
    try {
      const scratch = new CSSStyleSheet();
      scratch.replaceSync('x{' + style.cssText + '}');
      return blockSnapshot(scratch.cssRules[0].style) === blockSnapshot(style);
    } catch (e) { return false; }
  }
  window.__isonimShorthandBlockSnapshot = blockSnapshot;
  // Whether every condition a rule sits under is known to hold: `@media`
  // rules that do not hold are never collected, `@supports` is asked, and a
  // `@container` (or any other at-rule) condition is not known here.
  function conditionsHold(rule) {
    for (let parent = rule.parentRule; parent; parent = parent.parentRule) {
      const kind = parent.constructor && parent.constructor.name;
      if (kind === 'CSSMediaRule' || kind === 'CSSLayerBlockRule' || kind === 'CSSStyleRule') continue;
      if (kind === 'CSSSupportsRule') {
        let holds = false;
        try { holds = CSS.supports(parent.conditionText); } catch (e) {}
        if (holds) continue;
      }
      return false;
    }
    return true;
  }
  // What a rule's own source text declares for ``side``, for a side whose
  // CSSOM value is pending substitution (`padding: var(--s)` reads back as an
  // empty `padding-right`, and a partly overridden one loses its text
  // altogether). Read from the text of the `<style>` element that holds the
  // rule, when exactly one block there has the rule's selector: the side's
  // own declaration if it wins there, otherwise a single-value shorthand.
  // Whether any custom property declared where it could reach ``element``
  // uses ``name``. Custom properties inherit only from ancestors, so a rule
  // counts when its selector matches the element or one of its ancestors
  // (`:root` included), or cannot be judged (a selector `matches` rejects,
  // a pseudo-element); the element's and its ancestors' inline styles count;
  // and an unreadable sheet counts as one that might. Memoised per variable
  // for one capture (`aliasMemo`, set by `decidingSideRules`).
  let aliasMemo = null;
  function customPropertyUses(name, element) {
    if (aliasMemo && aliasMemo.has(name)) return aliasMemo.get(name);
    const answer = customPropertyUsesUncached(name, element);
    if (aliasMemo) aliasMemo.set(name, answer);
    return answer;
  }
  function customPropertyUsesUncached(name, element) {
    const chain = [];
    for (let node = element; node && node.nodeType === 1; node = node.parentElement) chain.push(node);
    // Shadow DOM: a custom property can reach a shadow host from its shadow
    // tree (`:host`), and a slotted element inherits from its slot inside
    // another tree, whose sheets (adopted ones included) are not scanned
    // here. Such an element cannot be judged.
    if (element.getRootNode() !== document ||
        chain.some((node) => node.shadowRoot || node.assignedSlot)) return true;
    const reaches = (selector) => {
      if (!selector || selector.indexOf('::') >= 0) return true;
      try {
        return chain.some((node) => node.matches(selector));
      } catch (e) { return true; }
    };
    const uses = new RegExp('var\\(\\s*' + name.replace(/[-]/g, '\\-') + '\\s*[,)]');
    const declares = (style) => {
      for (let i = 0; i < style.length; i++) {
        const property = style[i];
        if (property.startsWith('--') && uses.test(style.getPropertyValue(property))) return true;
      }
      return false;
    };
    let found = false;
    const visit = (rules) => {
      for (const rule of rules) {
        if (found) return;
        // A rule nested in a style rule (its selector is relative to the
        // parent's, `&` explicit or implicit) or under `@scope` cannot be
        // judged by its own selector.
        let nested = false;
        for (let parent = rule.parentRule; parent; parent = parent.parentRule) {
          const kind = parent.constructor && parent.constructor.name;
          if (kind === 'CSSStyleRule' || kind === 'CSSScopeRule') nested = true;
        }
        if (rule.style && declares(rule.style) &&
            (nested || rule.selectorText === undefined || reaches(rule.selectorText))) found = true;
        if (rule.cssRules && rule.cssRules.length) visit(rule.cssRules);
      }
    };
    const sheets = [...document.styleSheets, ...(document.adoptedStyleSheets || [])];
    for (const sheet of sheets) {
      let rules = null;
      try { rules = sheet.cssRules; } catch (e) { return true; }
      visit(rules);
      if (found) return true;
    }
    for (const node of chain) {
      if (declares(node.style)) return true;
    }
    return false;
  }
  function sourceSpecified(rule, shorthand, side, element) {
    try {
      const node = rule.parentStyleSheet && rule.parentStyleSheet.ownerNode;
      const raw = node && node.textContent;
      if (!raw || rule.parentRule) return '';
      // Comments out, so a selector or an unbalanced brace in one is not
      // read as a rule.
      const text = raw.replace(/\/\*[\s\S]*?\*\//g, (comment) => ' '.repeat(comment.length));
      const selector = rule.selectorText;
      // Top-level occurrences only (the rule has no parent): one inside an
      // at-rule block is another rule.
      const depthAt = (at) => {
        let depth = 0;
        for (let i = 0; i < at; i++) {
          if (text[i] === '{') depth++;
          else if (text[i] === '}') depth--;
        }
        return depth;
      };
      const starts = [];
      for (let at = text.indexOf(selector); at >= 0; at = text.indexOf(selector, at + 1)) {
        const after = text.slice(at + selector.length).match(/^\s*\{/);
        const before = at === 0 ? '' : text[at - 1];
        if (after && (before === '' || /[\s};]/.test(before)) && depthAt(at) === 0) {
          starts.push(at + selector.length + after[0].length);
        }
      }
      if (starts.length !== 1) return '';
      const body = text.slice(starts[0], text.indexOf('}', starts[0]));
      const declarations = [];
      let depth = 0, current = '';
      for (const c of body + ';') {
        if (c === '(') depth++;
        if (c === ')') depth--;
        if (c === ';' && depth === 0) { declarations.push(current); current = ''; }
        else current += c;
      }
      let winner = null;
      for (const declaration of declarations) {
        const colon = declaration.indexOf(':');
        if (colon < 0) continue;
        const name = declaration.slice(0, colon).trim().toLowerCase();
        if (name !== side && name !== shorthand) continue;
        let value = declaration.slice(colon + 1).trim();
        const important = /!\s*important\s*$/i.test(value);
        value = value.replace(/\s*!\s*important\s*$/i, '');
        if (!winner || important || !winner.important) winner = {name, value, important};
      }
      if (!winner) return '';
      const value = winner.name === side ? winner.value :
        (/\s/.test(winner.value.replace(/\([^()]*\)/g, '')) ? '' : winner.value);
      if (!value) return '';
      // The <style> text does not see CSSOM edits made since it was parsed,
      // and a pending side's live value cannot be read back (the CSSOM keeps
      // no text for it), so the text is not trusted; it is checked against
      // what renders. A pending side comes only from a substitution, so only
      // a `var(--name)` value is taken, and only when the side is measured to
      // depend on that very property: with `--name` given a probe value on
      // the element (an adopted sheet, scoped to it, no DOM mutation), the
      // side's computed value moves. Another property of the same value, a
      // different value, or a block changed by any route fails this.
      const reference = value.match(/^var\(\s*(--[\w-]+)\s*(,[^()]*)?\)$/);
      if (!reference) return '';
      const before = getComputedStyle(element).getPropertyValue(side);
      const probe = new CSSStyleSheet();
      probe.replaceSync('[data-isonim-selected="true"] { ' + reference[1] + ': 12345px !important; }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, probe];
      let depends = false;
      try {
        depends = getComputedStyle(element).getPropertyValue(side) !== before;
      } finally {
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => sheet !== probe);
      }
      if (!depends) return '';
      // Depending on `--name` is not being `var(--name)`: `calc(var(--name) *
      // 3)` depends on it too. The side must render exactly what `--name`
      // gives a side of its type -- measured the same way, the side set to
      // `var(--name)` on the element -- or the text is not the block's.
      const own = new CSSStyleSheet();
      own.replaceSync('[data-isonim-selected="true"] { ' + side + ': ' + value + ' !important; }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, own];
      let given = '';
      try {
        given = getComputedStyle(element).getPropertyValue(side);
      } finally {
        document.adoptedStyleSheets = document.adoptedStyleSheets.filter((sheet) => sheet !== own);
      }
      if (given !== before) return '';
      // And not through an alias: a custom property defined as `var(--name)`
      // (or using it) renders the same and depends on it, so wherever one is
      // declared -- any readable rule, the element's or an ancestor's inline
      // style -- which variable the block names cannot be told; nor while a
      // sheet cannot be read, which could declare one.
      if (customPropertyUses(reference[1], element)) return '';
      return value;
    } catch (e) { return ''; }
  }
  function decidingSideRules(el) {
    const lines = [];
    let calm = null;
    aliasMemo = new Map();
    // Which declaration decides each property the inspector shows, by the
    // preview runtime's own resolver (`__isonimCascadeAnswers`), asked before
    // anything below adopts a sheet: one `@cascade<TAB>answer` line each.
    try {
      const answers = window.__isonimCascadeAnswers ?
        window.__isonimCascadeAnswers(el, ISONIM_EDITABLE_PROPS) : '';
      for (const answer of answers.split('\n')) {
        if (answer) lines.push('@cascade\t' + answer);
      }
    } catch (e) {}
    try {
      // Transitions are switched off on the measured element only (it carries
      // `data-isonim-selected` while it is captured): a transition running on
      // another element of the page keeps running.
      calm = new CSSStyleSheet();
      calm.replaceSync('[data-isonim-selected="true"], [data-isonim-selected="true"]::before, ' +
        '[data-isonim-selected="true"]::after { transition: none !important; }');
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, calm];
      const rules = matchingStyleRules(el, calm);
      const names = rules.map(ruleIdentity);
      const counts = {};
      for (const name of names) counts[name] = (counts[name] || 0) + 1;
      lines.push('@matched\t' + names.join('\u001f'));
      for (const shorthand of Object.keys(ISONIM_SHORTHAND_SIDES)) {
        for (const side of ISONIM_SHORTHAND_SIDES[shorthand]) {
          // A side a `var()` shorthand sets is listed, pending substitution,
          // with an empty value.
          const declares = (style) => style.getPropertyValue(side) !== '' ||
            style.getPropertyValue(shorthand) !== '' ||
            Array.prototype.indexOf.call(style, side) >= 0;
          const important = (style) => style.getPropertyPriority(side) === 'important' ||
            style.getPropertyPriority(shorthand) === 'important';
          const declaring = rules.filter((rule) => declares(rule.style));
          let decided = '';
          if (declares(el.style) &&
              (important(el.style) || !declaring.some((rule) => important(rule.style)))) {
            decided = 'style';
          } else if (!declaring.length) {
            decided = 'none';
          } else if (declaring.length === 1 && !declares(el.style) &&
              !rules.unreadable && conditionsHold(declaring[0])) {
            // The one block that declares the side decides it; no probe --
            // only when every sheet could be read, since a sheet that cannot
            // (cross-origin) may declare the side too.
            const name = ruleIdentity(declaring[0]);
            decided = counts[name] > 1 ? '' : name;
          } else {
            const before = getComputedStyle(el).getPropertyValue(side);
            let unsafe = false;
            for (const rule of declaring) {
              const style = rule.style;
              if (!roundTrips(style)) { unsafe = true; continue; }
              const saved = style.cssText;
              const snapshot = blockSnapshot(style);
              style.setProperty(side, '12345px', important(style) ? 'important' : '');
              const moved = getComputedStyle(el).getPropertyValue(side) !== before;
              style.cssText = saved;
              if (blockSnapshot(style) !== snapshot) {
                // Cannot happen for a block that round-trips; never trust a
                // measurement that did not put its block back.
                unsafe = true;
                break;
              }
              if (moved) {
                const name = ruleIdentity(rule);
                decided = counts[name] > 1 ? '' : name;
                break;
              }
            }
            if (!decided && unsafe) decided = '';
          }
          // What the deciding block specifies for the side, when it is not a
          // plain length: a variable, function or keyword the computed value
          // has already resolved (`var(--space)` reads back as `16px`). The
          // side's own declaration, or a single-value shorthand's.
          let specified = '';
          const block = decided === 'style' ? el.style :
            (rules.find((rule) => decided && ruleIdentity(rule) === decided) || {}).style;
          if (block) {
            specified = block.getPropertyValue(side).trim();
            if (!specified) {
              const whole = block.getPropertyValue(shorthand).trim();
              if (whole && !/\s/.test(whole.replace(/\([^()]*\)/g, ''))) specified = whole;
            }
            if (!specified && block !== el.style) {
              const rule = rules.find((candidate) => ruleIdentity(candidate) === decided);
              if (rule) specified = sourceSpecified(rule, shorthand, side, el);
            }
            if (/^-?(\d+\.?\d*|\.\d+)(px|rem|em|%|vw|vh|vmin|vmax|ch|ex|pt|cm|mm|in|pc)?$/i.test(specified)) {
              specified = '';
            }
          }
          if (decided) lines.push(side + '\t' + decided + (specified ? '\t' + specified : ''));
        }
      }
      // Read back with transitions still off, so the next style change is
      // computed from the restored values, not from a probe value.
      getComputedStyle(el).getPropertyValue('padding-top');
    } catch (e) {
    } finally {
      aliasMemo = null;
      if (calm) document.adoptedStyleSheets =
        document.adoptedStyleSheets.filter((sheet) => sheet !== calm);
    }
    return lines.join('\n');
  }
  function selectElement(target) {
    const el = target;
    if (!el || el === document.documentElement || el === document.body) return;
    // A drag belongs to the element it was started on.
    if (handleDrag && handleDrag.element !== el) cancelHandleDrag();
    if (el !== window.__isonimSelectedElement) hideBoxMessage();
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
    // The selection and hover chrome are overlays (`syncOutlines`), so the
    // element's computed style is the document's own.
    let detail;
    {
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
            }).join(';'),
          sideRules: decidingSideRules(el)
      };
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
    const sent = new CustomEvent('isonim-preview-direct-manipulation', {
      detail: detail
    });
    parent.dispatchEvent(sent);
    return sent;
  }
  // A canvas command or gesture that changed the preview before asking (a
  // context command's Paste styles or Reset, inline text, a reorder): when
  // the editor refuses it at the act (`detail.refused`, as for a handle's
  // release, `refusedRelease`), `putBack` restores what the preview showed
  // before -- at once, transitions held -- and the reason is shown beside the
  // selection. One that changed nothing (Detach, Wrap, ...) only shows the
  // reason. Editor spec "Saving": a refused change never reaches the preview.
  function refusedCommand(sent, el, putBack) {
    const reason = sent && sent.detail && sent.detail.refused;
    if (!reason || !el) return false;
    if (putBack) {
      const hold = holdTransitions(el);
      putBack();
      hold.release();
    }
    if (window.__isonimSelectedElement === el) showBoxMessage(el, String(reason));
    return true;
  }
  // The element's own inline declaration of ``property`` (value and
  // priority), and a function that puts it back.
  function inlineKeeper(el, property) {
    const value = el.style.getPropertyValue(property);
    const priority = el.style.getPropertyPriority(property);
    return function () {
      if (value) el.style.setProperty(property, value, priority);
      else el.style.removeProperty(property);
    };
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
            const putBack = inlineKeeper(el, copied.property);
            el.style.setProperty(copied.property, copied.value);
            refusedCommand(dispatchContextCommand(command, copied), el, putBack);
          }
        } else if (command === 'reset') {
          const reset = firstEditableStyle(el);
          const value = reset.property === 'color' ? 'inherit' : '0px';
          const putBack = inlineKeeper(el, reset.property);
          el.style.setProperty(reset.property, value);
          refusedCommand(dispatchContextCommand(command,
            { property: reset.property, value: value, oldValue: reset.value }), el, putBack);
        } else {
          refusedCommand(dispatchContextCommand(command), el, null);
        }
        menu.remove();
      });
      menu.appendChild(button);
    });
    menu.style.left = Math.min(event.clientX, window.innerWidth - 206) + 'px';
    menu.style.top = Math.min(event.clientY, window.innerHeight - 316) + 'px';
    chromeRoot().appendChild(menu);
    const first = menu.querySelector('button');
    if (first) first.focus();
  }
  function clearSelection() {
    cancelHandleDrag();
    hideBoxMessage();
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
    chromeRoot().appendChild(popup);
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
    // The markup before editing, put back if the edit is refused.
    const beforeMarkup = selected.innerHTML;
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
      const sent = new CustomEvent('isonim-preview-direct-manipulation', {
        detail: {
          kind: 'inline-text',
          property: 'text',
          value: next,
          oldValue: before,
          sourceKey: sourceKeyFor(selected),
          measurement: 'text=' + next.length
        }
      });
      parent.dispatchEvent(sent);
      refusedCommand(sent, selected, function () { selected.innerHTML = beforeMarkup; });
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
      const putBack = inlineKeeper(selected, 'order');
      selected.style.order = String(toIndex);
      const sent = new CustomEvent('isonim-preview-direct-manipulation', {
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
      });
      parent.dispatchEvent(sent);
      refusedCommand(sent, selected, putBack);
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
  // The pointer leaving the preview ends the hover: its marker, outline and
  // label go, and the Layers panel is told. (A 'mouseleave' on the document
  // never fires; leaving the frame is a 'mouseout' with no element to go to.)
  function pointerLeft() {
    document.querySelectorAll('[data-isonim-hovered="true"]').forEach((node) => {
      node.removeAttribute('data-isonim-hovered');
    });
    const label = document.getElementById('isonim-editor-hover-label');
    if (label) label.hidden = true;
    if (lastHoverReported === '') return;
    lastHoverReported = '';
    parent.dispatchEvent(new CustomEvent('isonim-preview-element-hovered', {
      detail: { id: '' }
    }));
  }
  document.documentElement.addEventListener('mouseleave', pointerLeft);
  window.addEventListener('mouseout', function (event) {
    if (!event.relatedTarget) pointerLeft();
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
    const labelText = label.firstChild && label.firstChild.nodeType === 3 &&
      label.childNodes.length === 1 ? label.firstChild : null;
    const text = el.tagName.toLowerCase() + ' ' +
      Math.round(rect.width) + 'x' + Math.round(rect.height) +
      ' p:' + style.padding + ' • click selects, repeat-click climbs' +
      (position > 0
        ? ' (' + (position + 1) + '/' + drill.chain.length + ')'
        : '');
    if (labelText) { if (labelText.data !== text) labelText.data = text; }
    else label.textContent = text;
    label.style.left = Math.max(6, rect.left) + 'px';
    label.style.top = Math.max(18, rect.top - 6) + 'px';
    label.hidden = false;
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
    else syncOutlines();
  }, true);
  window.addEventListener('scroll', function () {
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
    else syncOutlines();
  }, true);
  window.addEventListener('resize', function () {
    if (window.__isonimSelectedElement) placeHandles(window.__isonimSelectedElement);
    else syncOutlines();
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
    // Short records rather than a stylesheet, and applying twice is a no-op.
    // The editor forgets them when this document is recomputed from a source
    // that carries them (`forgetPreviewDeclarations`), so none is put back
    // over a later write.
    try {
      const pending = parent.__isonimPreviewDeclarations;
      if (pending) {
        Object.keys(pending).forEach(function (key) {
          const d = pending[key];
          window.__isonimSetDeclaration(d.id, d.path, d.property, d.value, d.scope, d.condition || '', d.rule || '', d.removedFrom || '');
        });
      }
    } catch (e) {}
  })();
  // The resolver lives in the head script (see `declarationRuntime`), which
  // runs before this document is painted. This is only the channel.
  bindParent('isonim-preview-set-declaration', function (event) {
    const d = event.detail || {};
    // Whether it could be shown is handed back on the event: the editor
    // skips its post-write preview reload only for a preview that shows it.
    try {
      const shown = window.__isonimSetDeclaration(String(d.id || ''), String(d.path || ''),
                                    String(d.property || ''),
                                    String(d.value == null ? '' : d.value), String(d.scope || 'sskLocalInstance'),
                                    String(d.condition || ''), String(d.rule || ''),
                                    String(d.removedFrom || '')) === true;
      d.applied = d.applied === true || shown;
      // Where a removal was made, so the editor can record it (`applyPreviewStyle`).
      if (shown && !d.removedFrom) d.removedFrom = window.__isonimLastRemoval() || '';
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
  bridge.replace("__ISONIM_SCENE_GRAPH_WALK__", sceneGraphWalkJs)

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

  let injected = editablePreviewBridgeTemplate
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

  // Each shorthand's longhands (the inverse of SHORTHANDS, and the corners).
  var LONGHANDS = {
    'border-radius': ['border-top-left-radius', 'border-top-right-radius',
      'border-bottom-right-radius', 'border-bottom-left-radius']
  };
  Object.keys(SHORTHANDS).forEach(function (longhand) {
    SHORTHANDS[longhand].forEach(function (shorthand) {
      (LONGHANDS[shorthand] = LONGHANDS[shorthand] || []).push(longhand);
    });
  });

  // Which declaration block the cascade uses for this element and property.
  //
  // Resolved from the browser's own view rather than supplied by the editor:
  // it already knows which rules match and which media conditions hold at this
  // width, and asking it needs no project knowledge.
  //
  // The matching rules that declare the property -- through a shorthand that
  // sets it too, since a longhand written anywhere earlier would be reset by
  // it -- are ordered the way the cascade orders them
  // (https://www.w3.org/TR/css-cascade-5/#cascade-sort): importance, then
  // cascade layer (later layers win for normal declarations, earlier ones for
  // `!important`, and declarations outside every layer count as the last
  // layer), then selector specificity, then order of appearance. Only rules
  // whose conditions hold take part: `@media` and `@supports` are asked, and a
  // sheet's own `media` is too.
  //
  // A sheet whose rules cannot be read (cross-origin, such as a web font's
  // stylesheet linked without `crossorigin`) may declare the property too:
  // the answer is then the best rule among the readable ones, marked
  // `unread`, and the caller checks what the element renders
  // (`__isonimSetDeclaration`).
  //
  // What the cascade does here that this cannot see makes the answer unsound,
  // and an unsound answer is never used to pick a rule (`sound: false`):
  //
  //   * a declaring rule under a condition this cannot evaluate (`@container`,
  //     `@scope`'s proximity, an unknown at-rule) or nested in another style
  //     rule (its selector is relative to its parent's);
  //   * a selector whose specificity cannot be computed here, or that the
  //     browser cannot evaluate against the element (`matches` throws);
  //   * an element in a shadow tree, a shadow host or a slotted element: rules
  //     in another tree (`:host`, `::slotted`) can decide it;
  //   * the element's inline style deciding the property, for an edit of a
  //     shared rule: no rule decides it, so no rule is the edit's home.
  //
  // Rules that hold no declarations of an element's own style (`@font-face`,
  // `@keyframes`, `@page`, `@property`, `@counter-style`, ...) are skipped.
  //
  // Returns `{ rule, sound, inline, unread }`: the deciding rule (or, when no
  // rule declares the property, the matching rule the cascade ranks highest
  // -- any home for a declaration nothing makes wins), whether that answer is
  // sound, whether the inline style decides the property, and whether a
  // sheet could not be read.
  function isEditorSheet(sheet) {
    var owner = null;
    try { owner = sheet.ownerNode; } catch (e) {}
    // The bridge injects its own stylesheets (`#isonim-editor-selection-style`
    // and the rest), which style the editor's chrome. A stylesheet the editor
    // injected is never a home for a project edit.
    return !!(owner && owner.id && owner.id.indexOf('isonim-editor') === 0);
  }
  function declaresIn(style, property) {
    // Null when ``style`` does not declare ``property``, else its priority.
    var names = [property].concat(SHORTHANDS[property] || []);
    var declared = false, important = false;
    for (var r = 0; r < names.length; r++) {
      var name = names[r];
      if (style.getPropertyValue(name) !== '' ||
          Array.prototype.indexOf.call(style, name) >= 0) {
        declared = true;
        if (style.getPropertyPriority(name) === 'important') important = true;
      }
    }
    // A `var()` shorthand that a later side partly overrides is not listed,
    // and cannot be serialised: the block lists only its longhands, pending
    // substitution (an empty value). Such a longhand is the shorthand's own
    // declaration in this rule.
    var parts = LONGHANDS[property] || [];
    for (var q = 0; q < parts.length; q++) {
      if (Array.prototype.indexOf.call(style, parts[q]) >= 0 &&
          style.getPropertyValue(parts[q]) === '') {
        declared = true;
        if (style.getPropertyPriority(parts[q]) === 'important') important = true;
      }
    }
    return declared ? { important: important } : null;
  }
  // Selector specificity, as [a, b, c], or null when it cannot be computed
  // here (https://www.w3.org/TR/selectors-4/#specificity-rules).
  function splitSelectorList(text) {
    var parts = [], depth = 0, start = 0;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (ch === '\\') { i++; continue; }
      if (ch === '"' || ch === "'") {
        for (i++; i < text.length && text[i] !== ch; i++) if (text[i] === '\\') i++;
        continue;
      }
      if (ch === '(' || ch === '[') depth++;
      else if (ch === ')' || ch === ']') depth--;
      else if (ch === ',' && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
    }
    parts.push(text.slice(start));
    return parts.map(function (part) { return part.trim(); })
      .filter(function (part) { return part.length > 0; });
  }
  function laterSpecificity(x, y) {
    // True when ``x`` is greater than ``y``.
    for (var i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] > y[i];
    return false;
  }
  function listSpecificity(text) {
    // The most specific selector of a list (`:is()`, `:not()`, `:has()`).
    var best = [0, 0, 0];
    var parts = splitSelectorList(text);
    for (var i = 0; i < parts.length; i++) {
      var one = selectorSpecificity(parts[i]);
      if (!one) return null;
      if (laterSpecificity(one, best)) best = one;
    }
    return best;
  }
  function selectorSpecificity(s) {
    var a = 0, b = 0, c = 0, i = 0;
    // A CSS escape (https://www.w3.org/TR/css-syntax-3/#consume-escaped-code-point)
    // starting at the backslash ``s[at]``: up to six hex digits and one
    // whitespace after them, or any one other code point. Chromium writes a
    // class that starts with a digit this way (`2xl` is `.\32 xl`), so the
    // whitespace is part of the name, not a descendant combinator.
    function escapeEnd(at) {
      at++;
      if (at < s.length && /[0-9A-Fa-f]/.test(s[at])) {
        for (var digits = 0; digits < 6 && at < s.length && /[0-9A-Fa-f]/.test(s[at]); digits++) at++;
        if (at < s.length && /[ \t\n\r\f]/.test(s[at])) at++;
        return at;
      }
      return at + 1;
    }
    function identEnd(at) {
      while (at < s.length) {
        var ch = s[at];
        if (ch === '\\') { at = escapeEnd(at); continue; }
        if (/[A-Za-z0-9_\-]/.test(ch) || ch.charCodeAt(0) > 127) { at++; continue; }
        break;
      }
      return at;
    }
    function argumentsAt(at) {
      // ``s[at]`` is `(`: the text up to the matching `)`, and the index after.
      var depth = 0;
      for (var j = at; j < s.length; j++) {
        var ch = s[j];
        if (ch === '\\') { j++; continue; }
        if (ch === '"' || ch === "'") {
          for (j++; j < s.length && s[j] !== ch; j++) if (s[j] === '\\') j++;
          continue;
        }
        if (ch === '(') depth++;
        else if (ch === ')' && --depth === 0) return [s.slice(at + 1, j), j + 1];
      }
      return null;
    }
    while (i < s.length) {
      var ch = s[i];
      if (/\s/.test(ch) || ch === '>' || ch === '+' || ch === '~' || ch === '*') { i++; continue; }
      if (ch === '|') { i++; continue; }
      if (ch === '#') { a++; i = identEnd(i + 1); continue; }
      if (ch === '.') { b++; i = identEnd(i + 1); continue; }
      if (ch === '[') {
        b++;
        for (i++; i < s.length && s[i] !== ']'; i++) {
          if (s[i] === '\\') { i++; continue; }
          if (s[i] === '"' || s[i] === "'") {
            var quote = s[i];
            for (i++; i < s.length && s[i] !== quote; i++) if (s[i] === '\\') i++;
          }
        }
        i++;
        continue;
      }
      if (ch === ':') {
        var element = s[i + 1] === ':';
        var nameStart = i + (element ? 2 : 1);
        var nameEnd = identEnd(nameStart);
        var name = s.slice(nameStart, nameEnd).toLowerCase();
        i = nameEnd;
        var inner = null;
        if (s[i] === '(') {
          var found = argumentsAt(i);
          if (!found) return null;
          inner = found[0];
          i = found[1];
        }
        if (element) {
          // A pseudo-element never matches an element; one taking a
          // selector reaches into another tree.
          if (name === 'slotted' || name === 'part') return null;
          c++;
          continue;
        }
        if (name === 'host' || name === 'host-context') return null;
        if (inner === null) {
          if (name === 'before' || name === 'after' || name === 'first-line' ||
              name === 'first-letter') c++;
          else b++;
          continue;
        }
        if (name === 'is' || name === 'not' || name === 'has' || name === 'matches') {
          var most = listSpecificity(inner);
          if (!most) return null;
          a += most[0]; b += most[1]; c += most[2];
        } else if (name === 'where') {
          // Zero, whatever it holds.
        } else if (name === 'nth-child' || name === 'nth-last-child') {
          b++;
          var of = /\sof\s/i.exec(inner);
          if (of) {
            var nth = listSpecificity(inner.slice(of.index + of[0].length));
            if (!nth) return null;
            a += nth[0]; b += nth[1]; c += nth[2];
          }
        } else if (name === 'lang' || name === 'dir' || name === 'nth-of-type' ||
                   name === 'nth-last-of-type' || name === 'state') {
          b++;
        } else {
          return null;
        }
        continue;
      }
      if (ch === '&') return null;
      if (/[A-Za-z_\-]/.test(ch) || ch.charCodeAt(0) > 127 || ch === '\\') {
        var end = identEnd(i);
        // `ns|type`: the namespace prefix is not a type selector.
        if (s[end] === '|' && s[end + 1] !== '=') { i = end + 1; continue; }
        c++;
        i = end;
        continue;
      }
      return null;
    }
    return [a, b, c];
  }
  function compareLayers(x, y) {
    // A cascade layer's position as ordinals from the outermost layer down,
    // with `Infinity` for the declarations directly in it (they come after
    // its sublayers). Positive when ``x`` comes later.
    for (var i = 0; i < Math.min(x.length, y.length); i++) {
      if (x[i] !== y[i]) return x[i] > y[i] ? 1 : -1;
    }
    return x.length - y.length;
  }
  function cascadeWins(x, y) {
    // True when candidate ``x`` beats candidate ``y`` for one property.
    if (x.important !== y.important) return x.important;
    var layers = compareLayers(x.layer, y.layer);
    if (layers !== 0) return x.important ? layers < 0 : layers > 0;
    if (laterSpecificity(x.specificity, y.specificity)) return true;
    if (laterSpecificity(y.specificity, x.specificity)) return false;
    return x.order > y.order;
  }
  var NOT_ELEMENT_STYLE = {
    CSSFontFaceRule: true, CSSKeyframesRule: true, CSSKeyframeRule: true,
    CSSPageRule: true, CSSMarginRule: true, CSSPropertyRule: true,
    CSSCounterStyleRule: true, CSSFontFeatureValuesRule: true,
    CSSFontPaletteValuesRule: true, CSSNamespaceRule: true,
    CSSViewTransitionRule: true
  };
  // One walk over the element's style sheets, independent of the property:
  // the matching rules the cascade can rank (`candidates`, each with its
  // layer, specificity and order), the declaration blocks it cannot judge
  // (`unjudged`: a rule under a condition this cannot evaluate, nested in a
  // style rule, whose selector cannot be matched or ranked here, or with no
  // selector), and whether the element sits in or hosts a shadow tree
  // (`foreign`) or a sheet could not be read (`unread`). `resolveFrom` answers
  // one property from it, so the capture can ask every property it reports
  // with one walk (`__isonimCascadeAnswers`).
  function cascadeCandidates(el) {
    var walk = { candidates: [], unjudged: [], foreign: false, unread: false };
    if (el.getRootNode() !== document || el.shadowRoot || el.assignedSlot) {
      walk.foreign = true;
    }
    var ordinals = {}, counts = {}, anonymous = 0, order = 0;
    function layerName(parent, name) {
      // Registers a (possibly dotted) layer name, first appearance first, and
      // returns its full name.
      var full = parent;
      var parts = name === '' ? ['\u0000anonymous' + (anonymous++)] : name.split('.');
      for (var i = 0; i < parts.length; i++) {
        var next = full ? full + '.' + parts[i].trim() : parts[i].trim();
        if (!(next in ordinals)) {
          ordinals[next] = counts[full] || 0;
          counts[full] = ordinals[next] + 1;
        }
        full = next;
      }
      return full;
    }
    function layerPosition(full) {
      var position = [];
      if (full) {
        var parts = full.split('.'), name = '';
        for (var i = 0; i < parts.length; i++) {
          name = name ? name + '.' + parts[i] : parts[i];
          position.push(ordinals[name]);
        }
      }
      position.push(Infinity);
      return position;
    }
    function holds(test) {
      try { return test(); } catch (e) { return null; }
    }
    function visit(rules, layer, unknown) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        var kind = rule.constructor && rule.constructor.name;
        if (rule.type === CSSRule.STYLE_RULE) {
          var nested = rule.parentRule && rule.parentRule.type === CSSRule.STYLE_RULE;
          var judged = !unknown && !nested && rule.selectorText;
          var matching = [];
          if (judged) {
            var parts = splitSelectorList(rule.selectorText);
            for (var p = 0; p < parts.length; p++) {
              var matches = holds(function () { return el.matches(parts[p]); });
              if (matches === null) { judged = false; break; }
              if (matches) matching.push(parts[p]);
            }
          }
          if (!judged) {
            walk.unjudged.push(rule.style);
          } else if (matching.length) {
            var specificity = null;
            for (var m = 0; m < matching.length; m++) {
              var one = selectorSpecificity(matching[m]);
              if (!one) { specificity = null; break; }
              if (!specificity || laterSpecificity(one, specificity)) specificity = one;
            }
            if (!specificity) {
              walk.unjudged.push(rule.style);
            } else {
              walk.candidates.push({ rule: rule, layer: layerPosition(layer),
                specificity: specificity, order: order++ });
            }
          }
          // Rules nested in this one: their selectors are relative to it.
          if (rule.cssRules && rule.cssRules.length) visit(rule.cssRules, layer, true);
          continue;
        }
        if (rule.type === CSSRule.MEDIA_RULE) {
          var media = holds(function () { return matchMedia(rule.conditionText || rule.media.mediaText).matches; });
          if (media === false) continue;
          visit(rule.cssRules, layer, unknown || media === null);
          continue;
        }
        if (rule.type === CSSRule.SUPPORTS_RULE) {
          var supported = holds(function () { return CSS.supports(rule.conditionText); });
          if (supported === false) continue;
          visit(rule.cssRules, layer, unknown || supported === null);
          continue;
        }
        if (kind === 'CSSLayerStatementRule') {
          var names = rule.nameList || [];
          for (var n = 0; n < names.length; n++) layerName(layer, names[n]);
          continue;
        }
        if (kind === 'CSSLayerBlockRule') {
          visit(rule.cssRules, layerName(layer, rule.name || ''), unknown);
          continue;
        }
        if (rule.type === CSSRule.IMPORT_RULE) {
          var imported = null;
          try { imported = rule.styleSheet && rule.styleSheet.cssRules; } catch (e) {}
          if (!imported) { walk.unread = true; continue; }
          var importMedia = holds(function () {
            return !rule.media.mediaText || matchMedia(rule.media.mediaText).matches;
          });
          if (importMedia === false) continue;
          var importSupports = holds(function () {
            return !rule.supportsText || CSS.supports('(' + rule.supportsText + ')') ||
              CSS.supports(rule.supportsText);
          });
          if (importSupports === false) continue;
          var importLayer = rule.layerName === null || rule.layerName === undefined
            ? layer : layerName(layer, rule.layerName);
          visit(imported, importLayer, unknown || importMedia === null || importSupports === null);
          continue;
        }
        // `@starting-style` applies only before an element's first style, and
        // these hold no declarations an element's own style takes (a font
        // face's `font-weight`, a keyframe's `padding`, a page's margins).
        if (kind === 'CSSStartingStyleRule' || NOT_ELEMENT_STYLE[kind]) continue;
        // `@container`, `@scope` (proximity), and any grouping rule not known
        // here: whether its rules apply cannot be told.
        if (rule.cssRules) { visit(rule.cssRules, layer, true); continue; }
        // A declaration block with no selector of its own (`CSSNestedDeclarations`).
        if (rule.style) walk.unjudged.push(rule.style);
      }
    }
    var sheets = [].slice.call(document.styleSheets).concat(document.adoptedStyleSheets || []);
    for (var s = 0; s < sheets.length; s++) {
      var sheet = sheets[s];
      if (sheet.disabled || isEditorSheet(sheet)) continue;
      var applies = holds(function () {
        return !sheet.media || !sheet.media.mediaText || matchMedia(sheet.media.mediaText).matches;
      });
      if (applies === false) continue;
      var rules = null;
      try { rules = sheet.cssRules; } catch (e) { walk.unread = true; continue; }
      visit(rules, '', applies === null);
    }
    return walk;
  }
  // ``property`` answered from one walk (`cascadeCandidates`); `best` is the
  // deciding candidate (null when no rule declares the property).
  function resolveFrom(walk, el, property, shared) {
    var result = { rule: null, sound: !walk.foreign, inline: false, unread: walk.unread, best: null };
    for (var u = 0; u < walk.unjudged.length; u++) {
      if (walk.unjudged[u] && declaresIn(walk.unjudged[u], property)) { result.sound = false; break; }
    }
    var best = null, home = null;
    for (var c = 0; c < walk.candidates.length; c++) {
      var found = walk.candidates[c];
      var declared = declaresIn(found.rule.style, property);
      var candidate = { rule: found.rule, important: !!(declared && declared.important),
        layer: found.layer, specificity: found.specificity, order: found.order };
      if (declared && (!best || cascadeWins(candidate, best))) best = candidate;
      var normal = { rule: found.rule, important: false, layer: found.layer,
        specificity: found.specificity, order: found.order };
      if (!home || cascadeWins(normal, home)) home = normal;
    }
    var inline = declaresIn(el.style, property);
    if (inline && (inline.important || !best || !best.important)) {
      result.inline = true;
      if (shared) result.sound = false;
    }
    result.best = best;
    result.rule = best ? best.rule : home ? home.rule : null;
    return result;
  }
  function resolveRule(el, property, shared) {
    return resolveFrom(cascadeCandidates(el), el, property, shared);
  }
  // The at-rule conditions a rule applies under (`@media`, `@supports`,
  // `@container`, `@scope`, and any other grouping rule), outermost first,
  // as `ruleIdentity` writes them; a layer is not a condition. "" for a rule
  // that applies wherever its selector matches.
  function ruleConditions(rule) {
    var parts = [];
    for (var parent = rule.parentRule; parent; parent = parent.parentRule) {
      var kind = parent.constructor && parent.constructor.name;
      if (kind === 'CSSLayerBlockRule') continue;
      if (kind === 'CSSMediaRule') parts.unshift('@media ' + parent.conditionText);
      else if (kind === 'CSSSupportsRule') parts.unshift('@supports ' + parent.conditionText);
      else return '\u0000';
    }
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }
  // Which declaration decides each of ``properties`` for ``el``, and which
  // matching rules a normal declaration would decide it in, by the resolver
  // above -- the same answer an edit's preview uses. For the capture
  // (`decidingSideRules`): one `property<TAB>decider<TAB>conditions<TAB>homes`
  // line per property the answer is sound for, where `decider` names the
  // deciding rule as `ruleIdentity` does, or is `style` for the inline style;
  // `conditions` are the deciding rule's (`ruleConditions`); and `homes` are
  // the names, separated by U+001F, of the matching rules where a normal
  // declaration of the property would outrank the deciding one. A property
  // no rule and no inline style declares, or whose answer is unsound (a
  // sheet that cannot be read, a declaring block that cannot be judged, a
  // shadow tree) has no line. Read into `PropertyInfo.cascadeDecider`.
  // Whether a selector depends on a state of the page, so that it matches
  // only while that state holds. Inverted on purpose: only the pseudo-classes
  // known to depend on nothing but the document's structure and attributes
  // (STATIC_PSEUDO) leave a selector static; any other pseudo-class --
  // `:hover`, `:focus-within`, `:checked`, a vendor or future one such as
  // `:interest-source` or `:-webkit-drag` -- makes it stateful, wherever it
  // occurs (on the element, an ancestor, a sibling, inside `:is()`,
  // `:not()`, `:has()` or `:nth-child(... of S)`), so an unknown one never
  // grounds a refusal. The selector is read by CSS Syntax rules: an escape is
  // part of a name (`.hover\:p-4` is a class, not a state: such a rule can
  // ground a refusal), and a string or an attribute value is not a selector.
  // `:empty` is treated as stateful: inline text editing changes it.
  var STATIC_PSEUDO = {
    'is': 1, 'where': 1, 'not': 1, 'has': 1, 'matches': 1, '-webkit-any': 1,
    'first-child': 1, 'last-child': 1, 'only-child': 1, 'first-of-type': 1,
    'last-of-type': 1, 'only-of-type': 1, 'nth-child': 1, 'nth-last-child': 1,
    'nth-of-type': 1, 'nth-last-of-type': 1, 'root': 1, 'scope': 1,
    'lang': 1, 'dir': 1, 'defined': 1
  };
  function selectorDependsOnState(text) {
    text = String(text || '');
    var i = 0;
    function escapeEnd(at) {
      at++;
      if (at < text.length && /[0-9A-Fa-f]/.test(text[at])) {
        for (var digits = 0; digits < 6 && at < text.length && /[0-9A-Fa-f]/.test(text[at]); digits++) at++;
        if (at < text.length && /[ \t\n\r\f]/.test(text[at])) at++;
        return at;
      }
      return at + 1;
    }
    while (i < text.length) {
      var ch = text[i];
      if (ch === '\\') { i = escapeEnd(i); continue; }
      if (ch === '"' || ch === "'") {
        for (i++; i < text.length && text[i] !== ch; i++) if (text[i] === '\\') i++;
        i++;
        continue;
      }
      if (ch === '[') {
        // An attribute selector: its value is text, not a selector.
        for (i++; i < text.length && text[i] !== ']'; i++) {
          if (text[i] === '\\') { i++; continue; }
          if (text[i] === '"' || text[i] === "'") {
            var quote = text[i];
            for (i++; i < text.length && text[i] !== quote; i++) if (text[i] === '\\') i++;
          }
        }
        i++;
        continue;
      }
      if (ch === ':') {
        if (text[i + 1] === ':') {
          // A pseudo-element (`::before`): skip its name; its arguments, if
          // any (`::part()`, `::slotted()`), are read as selectors below.
          i += 2;
          while (i < text.length && /[A-Za-z0-9_\-]/.test(text[i])) i++;
          continue;
        }
        var start = i + 1, end = start;
        while (end < text.length && /[A-Za-z0-9_\-]/.test(text[end])) end++;
        var name = text.slice(start, end).toLowerCase();
        if (!STATIC_PSEUDO[name]) return true;
        i = end;
        continue;
      }
      i++;
    }
    return false;
  }
  window.__isonimSelectorDependsOnState = selectorDependsOnState;
  window.__isonimCascadeAnswers = function (el, properties) {
    var lines = [];
    try {
      var walk = cascadeCandidates(el);
      if (walk.foreign || walk.unread) return '';
      for (var i = 0; i < properties.length; i++) {
        var property = properties[i];
        var answer = resolveFrom(walk, el, property, false);
        if (!answer.sound) continue;
        var decider = '', conditions = '', homes = [];
        if (answer.inline) {
          decider = 'style';
        } else if (answer.best) {
          // A deciding rule whose selector depends on a state of the page
          // (`selectorDependsOnState`: any pseudo-class not known to be
          // static, anywhere in it) decides only while that state holds -- the
          // click that selects the element leaves it hovered -- so, like a
          // condition, it never grounds a refusal.
          if (selectorDependsOnState(answer.best.rule.selectorText)) continue;
          decider = ruleIdentity(answer.best.rule);
          conditions = ruleConditions(answer.best.rule);
          if (conditions === '\u0000') continue;
          for (var c = 0; c < walk.candidates.length; c++) {
            var found = walk.candidates[c];
            if (found.rule === answer.best.rule) continue;
            var normal = { rule: found.rule, important: false, layer: found.layer,
              specificity: found.specificity, order: found.order };
            if (cascadeWins(normal, answer.best)) homes.push(ruleIdentity(found.rule));
          }
        } else {
          continue;
        }
        lines.push(property + '\t' + decider + '\t' + conditions + '\t' + homes.join('\u001f'));
      }
    } catch (e) {
      return '';
    }
    return lines.join('\n');
  };
  function governingRule(el, property) {
    var resolved = resolveRule(el, property, false);
    return resolved.sound ? resolved.rule : null;
  }
  // The name a writer gives the rule it writes (`WorkspaceRuleDeclarations.
  // rule`, as the capture names a rule in `PropertyInfo.decidingRule`): its
  // at-rule conditions and selector, whitespace collapsed.
  function ruleIdentity(rule) {
    var parts = [rule.selectorText];
    for (var parent = rule.parentRule; parent; parent = parent.parentRule) {
      var kind = parent.constructor && parent.constructor.name;
      if (kind === 'CSSMediaRule') parts.unshift('@media ' + parent.conditionText);
      else if (kind === 'CSSSupportsRule') parts.unshift('@supports ' + parent.conditionText);
      else if (kind === 'CSSContainerRule') parts.unshift('@container ' + parent.conditionText);
      else if (kind === 'CSSLayerBlockRule') parts.unshift('@layer ' + parent.name);
      else if (kind === 'CSSScopeRule') parts.unshift('@scope (' + (parent.start || '') + ')' +
        (parent.end ? ' to (' + parent.end + ')' : ''));
      else if (kind === 'CSSStyleRule') parts.unshift(parent.selectorText);
      else parts.unshift('@' + (kind || 'unknown'));
    }
    return parts.join(' ').replace(/\s+/g, ' ').trim();
  }
  window.__isonimRuleIdentity = ruleIdentity;
  // The one rule named ``name`` that styles ``el``, or null when there is
  // none, or more than one rule carries the name.
  function namedRule(el, name) {
    var found = [];
    function visit(rules) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        if (rule.type === CSSRule.STYLE_RULE && ruleIdentity(rule) === name) found.push(rule);
        if (rule.cssRules && rule.cssRules.length) visit(rule.cssRules);
      }
    }
    var sheets = [].slice.call(document.styleSheets).concat(document.adoptedStyleSheets || []);
    for (var s = 0; s < sheets.length; s++) {
      if (isEditorSheet(sheets[s])) continue;
      var rules = null;
      try { rules = sheets[s].cssRules; } catch (e) { continue; }
      visit(rules);
    }
    if (found.length !== 1) return null;
    var rule = found[0];
    if (rule.parentRule && rule.parentRule.type === CSSRule.STYLE_RULE) return null;
    try { return el.matches(rule.selectorText) ? rule : null; } catch (e) { return null; }
  }

  // A removal, recorded so a frame rebuilt from a document that predates it
  // removes the same declaration again (`applyPreviewStyle` keeps the record):
  // the rule it was removed from, named and counted among the rules carrying
  // that name in document order, or 'inline' for the element's own style.
  // Replayed only there: re-resolving the deciding rule after the removal
  // would find a lower rule and remove a declaration nothing removed.
  function styleRulesNamed(name) {
    var found = [];
    function visit(rules) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        if (rule.type === CSSRule.STYLE_RULE && ruleIdentity(rule) === name) found.push(rule);
        if (rule.cssRules && rule.cssRules.length) visit(rule.cssRules);
      }
    }
    var sheets = [].slice.call(document.styleSheets).concat(document.adoptedStyleSheets || []);
    for (var s = 0; s < sheets.length; s++) {
      if (isEditorSheet(sheets[s])) continue;
      var rules = null;
      try { rules = sheets[s].cssRules; } catch (e) { continue; }
      visit(rules);
    }
    return found;
  }
  // A token's removal (``variable``) is made in the variable's own
  // declaration -- the rule that declares it, or the root element's style --
  // not in the element's: the place names it, and the replay removes the
  // variable there, not the property the record is kept under.
  function removalPlace(el, style, rule, variable) {
    if (variable) {
      if (style === document.documentElement.style)
        return JSON.stringify({ root: true, variable: variable });
      if (!rule) return '';
    } else {
      if (style === el.style) return 'inline';
      if (!rule) return '';
    }
    var name = ruleIdentity(rule);
    var same = styleRulesNamed(name);
    var index = same.indexOf(rule);
    if (index < 0) return '';
    var at = { name: name, index: index, count: same.length };
    if (variable) at.variable = variable;
    return JSON.stringify(at);
  }
  function removeAtPlace(id, path, property, place) {
    var el = elementFor(id, path);
    if (!el) return false;
    if (place === 'inline') { el.style.removeProperty(property); return true; }
    var at = null;
    try { at = JSON.parse(place); } catch (e) { return false; }
    if (!at) return false;
    // A token's removal is replayed on the variable (`removalPlace`).
    var removed = at.variable ? String(at.variable) : property;
    if (at.root) { document.documentElement.style.removeProperty(removed); return true; }
    var same = styleRulesNamed(String(at.name));
    // The document has the rules the removal saw, or it is not that document.
    // Assumed, not checked: a document with the same number of rules by
    // that name has them in the same order. The documents a record is
    // replayed into are the preview's own document before and after the
    // edits this session made, none of which reorders rules; a project
    // rebuild that did would be the write's reload, which forgets the
    // records (`previewSourceCaughtUp`).
    if (same.length !== at.count || !same[at.index]) return false;
    same[at.index].style.removeProperty(removed);
    return true;
  }
  var lastRemoval = '';
  window.__isonimLastRemoval = function () { return lastRemoval; };

  // A normal inline declaration cannot win against an active important rule.
  // Local edits must refuse that owner instead of mutating its shared rule.
  // This scans important precedence only, independently of `resolveRule`.
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

  // A responsive override: the element's rule repeated inside the `@media`
  // block `condition` names (an editor `ResponsiveBreakpoint.condition`, the
  // verbatim prelude). The rule the cascade uses outside any breakpoint names
  // the selector; the block and the rule are found by their text, and are
  // added to that rule's stylesheet when it has neither.
  function overrideRule(el, property, condition, create) {
    var wanted = String(condition || '').replace(/^\s*@media\s*/i, '').replace(/\s+/g, '');
    if (!wanted) return null;
    var base = governingRule(el, property);
    if (!base || !base.selectorText || !base.parentStyleSheet) return null;
    var selector = base.selectorText;
    var sheet = base.parentStyleSheet;
    var media = null;
    for (var i = 0; i < sheet.cssRules.length; i++) {
      var rule = sheet.cssRules[i];
      if (rule.type === CSSRule.MEDIA_RULE &&
          String(rule.conditionText || rule.media.mediaText).replace(/\s+/g, '') === wanted) {
        media = rule;
      }
    }
    if (!media) {
      if (!create) return null;
      try {
        var at = sheet.insertRule('@media ' + condition.replace(/^\s*@media\s*/i, '') + ' {}',
                                  sheet.cssRules.length);
        media = sheet.cssRules[at];
      } catch (e) { return null; }
    }
    for (var j = 0; j < media.cssRules.length; j++) {
      var inner = media.cssRules[j];
      if (inner.type === CSSRule.STYLE_RULE && inner.selectorText === selector) return inner;
    }
    if (!create) return null;
    try {
      var k = media.insertRule(selector + ' {}', media.cssRules.length);
      return media.cssRules[k];
    } catch (e) { return null; }
  }
  function elementFor(id, path) {
    var el = null;
    if (id) el = document.querySelector('[data-isonim-element-id="' + CSS.escape(id) + '"]');
    if (!el && path) { try { el = document.querySelector(path); } catch (e) {} }
    return el;
  }
  window.__isonimOverrideValue = function (id, path, property, condition) {
    var el = elementFor(id, path);
    if (!el || !property) return '';
    var rule = overrideRule(el, property, condition, false);
    return rule ? rule.style.getPropertyValue(property).trim() : '';
  };

  // Sets ``property`` to ``value`` where the edit is written, and says
  // whether it could: false leaves the preview as it was (see `applyPreviewStyle`:
  // the write's own reload then shows the result).
  //
  // ``rule``, when the editor knows it, names the rule the project's writer
  // writes (`WorkspaceRuleDeclarations.rule`): a shared edit is shown there, so
  // the preview renders what the write will, whichever rule the cascade
  // uses -- a rule another, more specific or more important rule overrides
  // shows no change, as the written file will not. Otherwise the declaration
  // goes to the rule the cascade uses (`resolveRule`), and nowhere when that
  // cannot be told soundly.
  function setDeclaration(id, path, property, value, scope, condition, rule) {
    if (!property) return false;
    if (condition) {
      var target = elementFor(id, path);
      if (!target) return false;
      var holder = overrideRule(target, property, condition, value !== '');
      if (!holder) return value === '';
      if (value === '') holder.style.removeProperty(property);
      else holder.style.setProperty(property, value);
      return true;
    }
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
    var tokenScope = scope === 'sskComponentToken' || scope === 'sskSemanticToken' ||
      scope === 'sskGlobalPrimitiveToken';
    if (local && window.__isonimLocalDeclarationRefusal(id, path, property)) return false;
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
    var style = null, verify = false, owner = null, tokenTarget = '';
    // What the element renders for the edited property (its longhands for a
    // shorthand), read to verify an edit that a sheet the resolver could not
    // read might override.
    var watched = LONGHANDS[property] || [property];
    // A local edit of the winning inline owner must not change a discarded
    // lower rule or siblings. Retain its priority; never manufacture important.
    // An important stylesheet declaration still outranks normal inline style.
    if (local && hasDeclaration(el.style)) {
      style = el.style;
    } else if (tokenScope && /^var\(\s*(--[\w-]+)(?:\s*,[^)]*)?\s*\)$/.test(
        el.style.getPropertyValue(property).trim())) {
      // A token edit through an inline `var()` use-site: the inline style is
      // read only for the variable it names, whose declaration is edited.
      style = el.style;
    } else {
      if (!local && !tokenScope && rule) {
        // The writer named its rule. Shown there or not at all: any other
        // rule may be one the write does not touch.
        var written = namedRule(el, String(rule));
        if (!written) return false;
        style = written.style;
        owner = written;
      } else {
        var resolved = resolveRule(el, property, !local);
        if (!resolved.sound) return false;
        style = resolved.rule ? resolved.rule.style : el.style;
        owner = resolved.rule || null;
        // A sheet that could not be read may decide the property: shown only
        // if the element is then seen to render it (`verify`).
        if (resolved.unread && resolved.rule) verify = true;
      }
    }
    // Token edits retain their var() use-sites, including inline references.
    // Resolve the directly referenced root declaration rather than detaching
    // the selected element from the binding. Other shared scopes keep their
    // stylesheet declaration owner.
    if (tokenScope) {
      var declared = el.style.getPropertyValue(property) || style.getPropertyValue(property);
      var token = /^var\(\s*(--[\w-]+)(?:\s*,[^)]*)?\s*\)$/.exec(declared.trim());
      if (token) {
        property = token[1];
        tokenTarget = property;
        var tokenRule = resolveRule(document.documentElement, property, false);
        if (!tokenRule.sound) return false;
        style = tokenRule.rule ? tokenRule.rule.style : document.documentElement.style;
        owner = tokenRule.rule || null;
        if (tokenRule.unread && tokenRule.rule) verify = true;
      }
    }
    var importance = priority(style);
    // A value may name its own priority (a shorthand side the source
    // declares `!important`, re-applied after its shorthand).
    var stated = /\s*!\s*important\s*$/i;
    if (stated.test(value)) {
      value = value.replace(stated, '');
      importance = 'important';
    }
    var saved = null, before = null, running = null;
    if (verify) {
      // Put back by its text, so only a block that survives being re-read from
      // its own text is touched.
      if (!roundTrips(style)) return false;
      saved = style.cssText;
      before = rendered(el, watched);
      running = el.getAnimations ? el.getAnimations() : [];
    }
    if (value === '') style.removeProperty(property);
    else style.setProperty(property, value, importance);
    if (verify) {
      var after = rendered(el, watched);
      var moved = after.some(function (v, i) { return v !== before[i]; });
      // A transition the edit started reads its start value: it moved.
      if (!moved && el.getAnimations) {
        moved = el.getAnimations().some(function (animation) {
          return running.indexOf(animation) < 0 && animation.transitionProperty &&
            (watched.indexOf(animation.transitionProperty) >= 0 ||
             animation.transitionProperty === property || animation.transitionProperty === 'all');
        });
      }
      if (!moved) {
        style.cssText = saved;
        rendered(el, watched);
        return false;
      }
    }
    // Where the removal was made, for its record (`removalPlace`): a token's
    // removal at the variable's declaration.
    if (value === '') lastRemoval = removalPlace(el, style, owner, tokenTarget);
    return true;
  }
  // ``removedFrom``: a recorded removal (`removalPlace`), replayed where it
  // was made and nowhere else.
  window.__isonimSetDeclaration = function (id, path, property, value, scope, condition, rule, removedFrom) {
    lastRemoval = '';
    var shown = (value === '' && !condition && removedFrom)
      ? removeAtPlace(id, path, property, String(removedFrom))
      : setDeclaration(id, path, property, value, scope, condition, rule) === true;
    // The editor's own frame script listens (a canvas drag's release keeps
    // its preview while the edit it committed could not be shown).
    try {
      if (typeof window.__isonimDeclarationOutcome === 'function') {
        window.__isonimDeclarationOutcome(property, shown, rule || '', condition || '',
          [property].concat(LONGHANDS[property] || [], SHORTHANDS[property] || []));
      }
    } catch (e) {}
    return shown;
  };
  function rendered(el, names) {
    var computed = getComputedStyle(el);
    return names.map(function (name) { return computed.getPropertyValue(name); });
  }
  function blockText(style) {
    var longhands = [];
    for (var i = 0; i < style.length; i++) {
      longhands.push(style[i] + ':' + style.getPropertyValue(style[i]) + '!' +
        style.getPropertyPriority(style[i]));
    }
    return style.cssText + '\n' + longhands.join(';');
  }
  function roundTrips(style) {
    try {
      var scratch = new CSSStyleSheet();
      scratch.replaceSync('x{' + style.cssText + '}');
      return blockText(scratch.cssRules[0].style) === blockText(style);
    } catch (e) { return false; }
  }

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
        styleBindings, computedStyles, sideRules: cstring) =
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
        $computedStyles,
        $sideRules)
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
            d.computedStyles || '', d.sideRules || ''
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
        toIndex: int): cstring =
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
      let outcome = vm.applyDirectCanvasOperation(DirectCanvasOperation(
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
      # The answer the frame reads on its event: why the commit was refused
      # ("" when it was accepted), so a refused resize or spacing release puts
      # its preview back and shows the reason (`refusedRelease`).
      if outcome.ok: cstring("")
      else:
        var reason = ""
        for d in outcome.diagnostics:
          if d.message.len > 0:
            reason = d.message
            break
        # A command that runs another editor command (Create variant,
        # Duplicate, Delete) says why in its command state.
        if reason.len == 0: reason = outcome.commandState.diagnostic
        if reason.len == 0: reason = "This canvas edit was refused."
        cstring(reason)
    # A native project writes through its worker, from the property's own
    # field (`inspectorSourceCommit`), and the margin and padding handles
    # already commit there through the box model's field pipeline. The
    # width, height and spacing handles do the same: their release commits
    # through the row pipeline of the property they drag
    # (`commitBoxModelField` over that property's `inspectorRowWiring`) --
    # the same scope, act-time refusals, history and native write -- instead
    # of staging a plan nothing in this composition can write. The frame
    # holds its preview until the worker answers (`detail.settle`).
    let nativeCanvasCommit = proc(kind, propName, value: cstring;
        settle: proc(ok: bool; message: cstring)): bool =
      if vm.inspectorSourceCommit == nil: return false
      let property = $propName
      if $kind notin ["resize", "spacing"] or
          property notin ["width", "height", "gap", "padding"]:
        return false
      var disposeWiring: proc()
      var wiring: InspectorRowWiring
      createRoot proc(dispose: proc()) =
        disposeWiring = dispose
        wiring = inspectorRowWiring(vm, property)
      discard commitBoxModelField(vm, property, wiring, $value,
        proc(outcome: BoxModelCommitOutcome) =
          settle(outcome.ok, cstring(outcome.message))
          if disposeWiring != nil: disposeWiring())
      true
    {.emit: ["""
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-direct-manipulation', function (event) {
          const d = event.detail || {};
          if (typeof d.settle === 'function' && """, nativeCanvasCommit, """(
              String(d.kind || ''), String(d.property || ''), String(d.value || ''),
              function (ok, message) {
                try { d.settle(ok, message); } catch (error) {}
              })) {
            d.refused = '';
            d.pending = true;
            return;
          }
          d.refused = """, directManipulationFromBrowser,
        """(
            d.kind || '', d.property || '', d.value || '', d.oldValue || '',
            d.handle || '', d.command || '', d.sourceKey || '',
            d.measurement || '', Number(d.fromIndex || 0),
            Number(d.toIndex || 0)
          );
      });
    """].}

    # The selection overlay's margin and padding handles (editor spec "Visual
    # box model": "drag handles on canvas for live preview"). The frame draws
    # the handles and previews the drag; what a step means, the fields that
    # show it and the commit on release are `section_box_model`'s, so a drag
    # commits through the box model field's pipeline. Each request is
    # answered on its event (`d.reply`): the property a press drags, the
    # value a move previews, or "" when the drag is over; a release that
    # commits answers "pending" and later calls `settle`.
    let boxDragFromBrowser = proc(phase, handle: cstring; allSides: bool;
        start, dx, dy: float;
        settle: proc(ok: bool; message: cstring) {.closure.}): cstring =
      case $phase
      of "start":
        let refusal = vm.boxCanvasDragRefusal($handle)
        if refusal.len > 0:
          settle(false, cstring(refusal))
          cstring("")
        else:
          cstring(vm.beginBoxCanvasDrag($handle, allSides))
      of "move":
        cstring(vm.moveBoxCanvasDrag(start, dx, dy))
      of "commit":
        let committing = vm.commitBoxCanvasDrag(
          proc(outcome: BoxModelCommitOutcome) =
            settle(outcome.ok, cstring(outcome.message)))
        if committing: cstring("pending") else: cstring("")
      else:
        vm.cancelBoxCanvasDrag()
        cstring("")
    {.emit: ["""
      globalThis.__isonimPreviewBridge(""", frame, """, 'isonim-preview-box-drag', function (event) {
          const d = event.detail || {};
          d.reply = """, boxDragFromBrowser,
        """(
            String(d.phase || ''), String(d.handle || ''), !!d.allSides,
            Number(d.start) || 0, Number(d.dx) || 0, Number(d.dy) || 0,
            function (ok, message) {
              try { if (typeof d.settle === 'function') d.settle(ok, message); } catch (error) {}
            });
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
    # A write that ends without reloading the preview (failed, or staged
    # only) releases a canvas drag's held value in the frame: no reload is
    # coming to replace it (`EditorVM.previewHoldRelease`).
    var lastHoldRelease = untrack(proc(): int = vm.previewHoldRelease.val)
    createRenderEffect proc() =
      let release = vm.previewHoldRelease.val
      if release == lastHoldRelease: return
      lastHoldRelease = release
      {.emit: "window.dispatchEvent(new CustomEvent('isonim-preview-release-held'));".}
    var lastPreviewRequest = 0
    createRenderEffect proc() =
      let request = vm.inspector.previewValueRequest.val
      if request.generation == 0 or request.generation == lastPreviewRequest:
        return
      lastPreviewRequest = request.generation
      var shown = applyPreviewStyle(request.elementId, request.domPath,
                        request.property, request.value, request.sourceScope,
                        request.condition, request.rule)
      # The shorthand sides the restored rule decides, as its source renders
      # them (`PreviewValueRequest.followers`).
      for (side, sideValue) in request.followers:
        if not applyPreviewStyle(request.elementId, request.domPath, side,
            sideValue, request.sourceScope, request.condition, request.rule):
          shown = false
      # The write that follows must not reload the preview out from under it,
      # for the same reason a commit sets this -- unless the preview could not
      # show it, when that reload is what shows the result.
      if shown: vm.previewShowsPendingEdits.val = true
      else: vm.previewMissesPendingEdits.val = true
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
