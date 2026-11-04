## IsoNim Editor — the canonical scene-graph walk.
##
## ONE definition of "what is in this preview, and how is it nested".
##
## There used to be two, and they disagreed, which is the bug this module
## exists to make impossible:
##
##   * the preview bridge's in-iframe ``layerTree()`` walked ``body *``
##     filtered by ``isSelectable`` — the full rendered hierarchy — but was
##     injected only OUTSIDE View mode;
##   * the parent-side reader in ``shell.nim`` walked
##     ``[data-isonim-src]`` — which the SSR ``ui:`` DSL stamps only on the
##     elements IT generates — and worked in every mode.
##
## The second is structurally incomplete, and the numbers say so rather than
## an opinion: the grip pilot's home page renders 3465 elements, of which 70
## carry ``data-isonim-src``. Everything the page builds by string
## concatenation (``raw`` in the DSL: the example pane, the syntax
## highlighter's tokens, the claims prose, the name-section bodies) and
## everything its client script builds at runtime carries no attribute at all
## and no DSL change can make it: a compile-time stamp cannot reach markup the
## compiler never saw. Reading the rendered DOM can, and does.
##
## So the rendered DOM is the producer, and this is the walk. Both sides run
## THIS source text — the parent against the iframe's ``contentDocument``, the
## injected bridge against its own ``document`` — so element ids agree by
## construction rather than by two implementations happening to match. That
## agreement is load-bearing: the panel selects an element in the preview by
## ``data-isonim-element-id``, which the walk both computes and stamps.
##
## Zero production cost: the string is referenced only from editor views.

const sceneGraphWalkJs* = """
(function (root) {
  if (root.__isonimSceneGraphWalk) return;
  // The editor's own overlay chrome, by id. It lives in the same document as
  // the page under inspection, and a scene graph that lists the selection
  // handles is describing the editor, not the design.
  var EDITOR_IDS = [
    'isonim-editor-hover-label',
    'isonim-editor-selection-handles',
    'isonim-editor-selection-breadcrumb',
    'isonim-editor-gap-overlay',
    'isonim-editor-snap-lines',
    'isonim-editor-spacing-measure',
    'isonim-editor-context-menu',
    'isonim-editor-comment-popup'
  ];
  var EDITOR_CHROME = EDITOR_IDS.map(function (id) { return '#' + id; })
    .join(', ');
  root.__isonimSceneGraphWalk = function (doc, options) {
    var opts = options || {};
    var fallbackSource = opts.fallbackSource || '';
    var fallbackLine = opts.fallbackLine || '';
    var editorIds = opts.editorIds || new Set(EDITOR_IDS);

    function isElement(node) {
      return !!node && node.nodeType === 1;
    }
    function isEditorChrome(node) {
      var el = isElement(node) ? node : node && node.parentElement;
      return !!el && ((el.id && editorIds.has(el.id)) ||
        (el.closest && el.closest(EDITOR_CHROME)));
    }
    // Visibility, not markup, decides membership. A zero-box element is not
    // something a designer can point at -- and it is also what keeps `head`,
    // `meta`, `style` and `script` out of the tree without a tag blocklist,
    // and what keeps the thousands of tokens inside an inactive (display:
    // none) code pane from burying the page structure.
    // One walk's memo (see `layerTree`). Null outside a walk: the bridge
    // calls these one element at a time, between DOM changes, and must see
    // the document as it is now.
    var walkMemo = null;
    function isSelectable(el) {
      if (walkMemo && walkMemo.selectable.has(el)) return walkMemo.selectable.get(el);
      var result = isSelectableNow(el);
      if (walkMemo) walkMemo.selectable.set(el, result);
      return result;
    }
    function isSelectableNow(el) {
      if (!isElement(el)) return false;
      if (el === doc.documentElement || el === doc.body) return false;
      if (el.id && editorIds.has(el.id)) return false;
      if (el.closest && el.closest(EDITOR_CHROME)) return false;
      var rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    }
    function stableSelector(el) {
      if (!isElement(el)) return '';
      var tag = el.tagName.toLowerCase();
      var testId = el.getAttribute('data-testid');
      if (testId) return tag + '[data-testid=' + testId + ']';
      var role = el.getAttribute('role');
      var cls = String(el.getAttribute('class') || '').trim()
        .split(/\s+/).filter(Boolean).slice(0, 2);
      var text = tag;
      if (cls.length) text += '.' + cls.join('.');
      if (role) text += '[role=' + role + ']';
      return text;
    }
    function parseSource(value) {
      if (!value) return { file: fallbackSource, line: fallbackLine };
      var match = String(value).match(/^(.*?):(\d+)(?::\d+)?$/);
      if (!match) return { file: String(value), line: fallbackLine };
      return { file: match[1], line: match[2] };
    }
    function sourceKeyFor(el) {
      var source = parseSource(el.getAttribute('data-isonim-src'));
      var tag = el.tagName.toLowerCase();
      var testId = el.getAttribute('data-testid') || '';
      var cls = String(el.getAttribute('class') || '').trim()
        .split(/\s+/).filter(Boolean).slice(0, 2).join('.');
      var owned = testId ? 'testid:' + testId : (cls ? 'class:' + cls : 'tag:' + tag);
      return source.file + ':' + source.line + ':' + owned;
    }
    // The 1-based position of `el` among its parent's children of the same
    // tag, as `:nth-of-type` counts it.
    function nthOfType(el) {
      if (walkMemo && el.parentElement) {
        var counted = walkMemo.siblings.get(el.parentElement);
        if (!counted) {
          // Every child of this parent at once: a list of n siblings costs n,
          // not n * n / 2, however many of them the walk visits.
          counted = new Map();
          var perTag = new Map();
          for (var child = el.parentElement.firstElementChild; child;
               child = child.nextElementSibling) {
            var n = (perTag.get(child.tagName) || 0) + 1;
            perTag.set(child.tagName, n);
            counted.set(child, n);
          }
          walkMemo.siblings.set(el.parentElement, counted);
        }
        if (counted.has(el)) return counted.get(el);
      }
      var index = 1;
      var sibling = el;
      while ((sibling = sibling.previousElementSibling)) {
        if (sibling.tagName === el.tagName) index += 1;
      }
      return index;
    }
    // The selector path from the outermost selectable ancestor down to `el`.
    // Within a walk each element's path is computed once and its children
    // extend it, instead of every element re-walking (and re-measuring) all
    // of its ancestors: that made one walk of a 6,000-element preview cost
    // 110,000 layout reads and 1.6 million sibling steps, and the reader
    // repeats the walk every 700 ms.
    function cssPath(el) {
      if (!isSelectable(el)) return '';
      if (walkMemo && walkMemo.path.has(el)) return walkMemo.path.get(el);
      var part = stableSelector(el) + ':nth-of-type(' + nthOfType(el) + ')';
      var above = cssPath(el.parentElement);
      var path = above ? above + ' > ' + part : part;
      if (walkMemo) walkMemo.path.set(el, path);
      return path;
    }
    // The id is STAMPED as well as returned. The panel selects an element in
    // the preview by querying `[data-isonim-element-id]`, so whichever side
    // ran the walk first has to have left the id behind for the other.
    function identityFor(el) {
      if (!isElement(el)) return '';
      var existing = el.getAttribute('data-isonim-element-id');
      if (existing) return existing;
      var id = sourceKeyFor(el) + ':' + cssPath(el);
      try { el.setAttribute('data-isonim-element-id', id); } catch (e) {}
      return id;
    }
    // The element's schema key: what identifies it to the project's edit
    // adapter. Defined HERE because three places were computing it and two of
    // them disagreed with the third -- the walk and the preview bridge both
    // said `dom.<testid or tag>` while the editor's own fallback preferred
    // the class list. The editor then received `dom.h1` for an element whose
    // rule is `.tagline`, and the adapter went looking for a CSS rule named
    // `.h1`.
    //
    // Classes before the tag, because a class is what a stylesheet can be
    // addressed by and a tag generally is not.
    function schemaKeyFor(el) {
      if (!isElement(el)) return '';
      var declared = el.getAttribute('data-isonim-schema-key');
      if (declared) return declared;
      var testId = el.getAttribute('data-testid');
      if (testId) return 'dom.' + testId;
      var cls = String(el.getAttribute('class') || '').trim()
        .split(/\s+/).filter(Boolean);
      if (cls.length) return 'dom.' + cls.join('.');
      return 'dom.' + el.tagName.toLowerCase();
    }
    function ancestorStack(target) {
      var stack = [];
      var el = isElement(target) ? target : (target && target.parentElement);
      while (isSelectable(el)) {
        stack.push(el);
        el = el.parentElement;
      }
      return stack;
    }
    // A leaf's own text is usually the most recognisable thing about it --
    // `span.cl` tells you nothing, `span "Faster than C."` tells you which
    // one. Leaves only: an ancestor's text belongs to its descendants.
    function labelFor(el) {
      var base = stableSelector(el);
      if (!el.children || el.children.length === 0) {
        var t = String(el.textContent || '').trim().replace(/\s+/g, ' ');
        if (t) {
          if (t.length > 24) t = t.slice(0, 24) + '…';
          return base + '  “' + t + '”';
        }
      }
      return base;
    }
    function layerTree(selected) {
      // The memo lives for this one synchronous walk. Nothing the walk does
      // changes what it memoises: it stamps only `data-isonim-element-id`,
      // which neither layout nor `stableSelector` reads.
      var outer = walkMemo;
      walkMemo = {selectable: new Map(), path: new Map(), siblings: new Map()};
      try {
        return layerTreeNow(selected);
      } finally {
        walkMemo = outer;
      }
    }
    function layerTreeNow(selected) {
      var nodes = Array.prototype.slice.call(
        doc.querySelectorAll('body *')).filter(isSelectable);
      var nodeSet = new Set(nodes);
      var depthOf = function (el) {
        var d = 0, p = el.parentElement;
        while (p) { if (nodeSet.has(p)) d++; p = p.parentElement; }
        return d;
      };
      return nodes.map(function (node) {
        var id = identityFor(node);
        var parent = node.parentElement;
        while (parent && !nodeSet.has(parent)) parent = parent.parentElement;
        var kids = Array.prototype.filter.call(
          node.children || [], function (child) { return nodeSet.has(child); });
        var source = parseSource(node.getAttribute('data-isonim-src'));
        return {
          id: id,
          parentId: parent ? identityFor(parent) : '',
          label: labelFor(node),
          tag: node.tagName.toLowerCase(),
          sourceKey: sourceKeyFor(node),
          schemaKey: schemaKeyFor(node),
          domPath: cssPath(node),
          sourceFile: source.file,
          sourceLine: Number(source.line) || 0,
          depth: depthOf(node),
          childCount: kids.length,
          expanded: true,
          selected: selected === node,
          hovered: node.hasAttribute('data-isonim-hovered'),
          hidden: false,
          locked: false
        };
      });
    }
    return {
      isElement: isElement,
      isEditorChrome: isEditorChrome,
      isSelectable: isSelectable,
      stableSelector: stableSelector,
      parseSource: parseSource,
      sourceKeyFor: sourceKeyFor,
      cssPath: cssPath,
      identityFor: identityFor,
      ancestorStack: ancestorStack,
      labelFor: labelFor,
      schemaKeyFor: schemaKeyFor,
      layerTree: layerTree
    };
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
"""
