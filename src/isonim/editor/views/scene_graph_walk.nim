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
    // Visibility, not markup, decides membership. A zero-box element is not
    // something a designer can point at -- and it is also what keeps `head`,
    // `meta`, `style` and `script` out of the tree without a tag blocklist,
    // and what keeps the thousands of tokens inside an inactive (display:
    // none) code pane from burying the page structure.
    function isSelectable(el) {
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
    function cssPath(el) {
      var parts = [];
      var node = el;
      while (isSelectable(node)) {
        var part = stableSelector(node);
        var index = 1;
        var sibling = node;
        while ((sibling = sibling.previousElementSibling)) {
          if (sibling.tagName === node.tagName) index += 1;
        }
        part += ':nth-of-type(' + index + ')';
        parts.unshift(part);
        node = node.parentElement;
      }
      return parts.join(' > ');
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
          schemaKey: node.getAttribute('data-isonim-schema-key') ||
            ('dom.' + (node.getAttribute('data-testid') ||
                       node.tagName.toLowerCase())),
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
      isSelectable: isSelectable,
      stableSelector: stableSelector,
      parseSource: parseSource,
      sourceKeyFor: sourceKeyFor,
      cssPath: cssPath,
      identityFor: identityFor,
      ancestorStack: ancestorStack,
      labelFor: labelFor,
      layerTree: layerTree
    };
  };
})(typeof globalThis !== 'undefined' ? globalThis : window);
"""
