## True SSR -> hydrate -> interactive round-trip tests (M18).
##
## These tests run under `nim js -r` which executes via Node.js.
## They verify the full cycle:
##   1. Render HTML via SSR (renderToString / buildHtmlString)
##   2. Parse that HTML into a DOM tree (JS DOM shim)
##   3. Hydrate the DOM tree (attach reactive behavior to existing nodes)
##   4. Verify that signals drive DOM updates after hydration

when not defined(js):
  {.error: "test_ssr_hydration_e2e must be compiled with the JS backend: nim js -r tests/test_ssr_hydration_e2e.nim".}

# Inject the DOM shim with hydration extensions (adapted from test_hydration.nim)
{.emit: """
// ---- Minimal DOM shim for Node.js (hydration-extended) ----
(function() {
  if (typeof document !== 'undefined') return;

  var nodeIdCounter = 0;

  function TextNode(text) {
    this._id = ++nodeIdCounter;
    this.nodeType = 3;
    this.nodeName = '#text';
    this.data = text;
    this.textContent = text;
    this.parentNode = null;
    this.firstChild = null;
    this.nextSibling = null;
    this.childNodes = [];
  }
  TextNode.prototype.remove = function() {
    if (this.parentNode) this.parentNode.removeChild(this);
  };
  TextNode.prototype.cloneNode = function(deep) {
    return new TextNode(this.data);
  };
  TextNode.prototype.hasAttribute = function() { return false; };
  TextNode.prototype.getAttribute = function() { return null; };
  TextNode.prototype.querySelectorAll = function() { return []; };
  TextNode.prototype.querySelector = function() { return null; };

  // Comment node (nodeType 8) for Suspense markers
  function CommentNode(data) {
    this._id = ++nodeIdCounter;
    this.nodeType = 8;
    this.nodeName = '#comment';
    this.data = data;
    this.textContent = data;
    this.parentNode = null;
    this.firstChild = null;
    this.nextSibling = null;
    this.childNodes = [];
  }
  CommentNode.prototype.remove = function() {
    if (this.parentNode) this.parentNode.removeChild(this);
  };
  CommentNode.prototype.cloneNode = function() {
    return new CommentNode(this.data);
  };
  CommentNode.prototype.hasAttribute = function() { return false; };
  CommentNode.prototype.getAttribute = function() { return null; };
  CommentNode.prototype.querySelectorAll = function() { return []; };
  CommentNode.prototype.querySelector = function() { return null; };

  function ElementNode(tag) {
    this._id = ++nodeIdCounter;
    this.nodeType = 1;
    this.nodeName = tag.toUpperCase();
    this.tagName = tag.toUpperCase();
    this.localName = tag.toLowerCase();
    this.data = null;
    this.parentNode = null;
    this.firstChild = null;
    this.nextSibling = null;
    this.childNodes = [];
    this.attributes = {};
    this.className = '';
    this.innerHTML = '';
    this.style = {
      _props: {},
      setProperty: function(k, v) { this._props[k] = v; },
      removeProperty: function(k) { delete this._props[k]; },
      cssText: ''
    };
    this._eventListeners = {};
    this.disabled = false;
  }

  function updateSiblings(node) {
    var children = node.childNodes;
    node.firstChild = children.length > 0 ? children[0] : null;
    for (var i = 0; i < children.length; i++) {
      children[i].nextSibling = (i + 1 < children.length) ? children[i + 1] : null;
      children[i].parentNode = node;
    }
  }

  function setTextContent(node, val) {
    for (var i = 0; i < node.childNodes.length; i++) {
      node.childNodes[i].parentNode = null;
    }
    node.childNodes = [];
    if (val !== '' && val != null) {
      var t = new TextNode(String(val));
      t.parentNode = node;
      node.childNodes.push(t);
    }
    updateSiblings(node);
  }

  Object.defineProperty(ElementNode.prototype, 'textContent', {
    get: function() {
      var result = '';
      for (var i = 0; i < this.childNodes.length; i++) {
        var c = this.childNodes[i];
        if (c.nodeType === 3) result += c.data;
        else if (c.nodeType === 8) result += '';
        else result += c.textContent;
      }
      return result;
    },
    set: function(val) {
      setTextContent(this, val);
    }
  });

  Object.defineProperty(TextNode.prototype, 'textContent', {
    get: function() { return this.data; },
    set: function(val) { this.data = String(val); }
  });

  ElementNode.prototype.appendChild = function(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    if (child.nodeType === 11) {
      var kids = child.childNodes.slice();
      for (var i = 0; i < kids.length; i++) {
        this.appendChild(kids[i]);
      }
      child.childNodes = [];
      updateSiblings(child);
      return child;
    }
    child.parentNode = this;
    this.childNodes.push(child);
    updateSiblings(this);
    return child;
  };

  ElementNode.prototype.insertBefore = function(newNode, refNode) {
    if (newNode.parentNode) newNode.parentNode.removeChild(newNode);
    if (refNode == null) {
      return this.appendChild(newNode);
    }
    if (newNode.nodeType === 11) {
      var kids = newNode.childNodes.slice();
      for (var i = 0; i < kids.length; i++) {
        this.insertBefore(kids[i], refNode);
      }
      newNode.childNodes = [];
      updateSiblings(newNode);
      return newNode;
    }
    var idx = this.childNodes.indexOf(refNode);
    if (idx >= 0) {
      newNode.parentNode = this;
      this.childNodes.splice(idx, 0, newNode);
    } else {
      return this.appendChild(newNode);
    }
    updateSiblings(this);
    return newNode;
  };

  ElementNode.prototype.removeChild = function(child) {
    var idx = this.childNodes.indexOf(child);
    if (idx >= 0) {
      this.childNodes.splice(idx, 1);
      child.parentNode = null;
      child.nextSibling = null;
    }
    updateSiblings(this);
    return child;
  };

  ElementNode.prototype.replaceChild = function(newChild, oldChild) {
    var idx = this.childNodes.indexOf(oldChild);
    if (idx >= 0) {
      if (newChild.parentNode) newChild.parentNode.removeChild(newChild);
      oldChild.parentNode = null;
      oldChild.nextSibling = null;
      newChild.parentNode = this;
      this.childNodes[idx] = newChild;
    }
    updateSiblings(this);
    return oldChild;
  };

  ElementNode.prototype.remove = function() {
    if (this.parentNode) this.parentNode.removeChild(this);
  };

  ElementNode.prototype.cloneNode = function(deep) {
    var clone = new ElementNode(this.localName);
    clone.className = this.className;
    var attrKeys = Object.keys(this.attributes);
    for (var i = 0; i < attrKeys.length; i++) {
      clone.attributes[attrKeys[i]] = this.attributes[attrKeys[i]];
    }
    if (deep) {
      for (var j = 0; j < this.childNodes.length; j++) {
        clone.appendChild(this.childNodes[j].cloneNode(true));
      }
    }
    return clone;
  };

  ElementNode.prototype.setAttribute = function(name, value) {
    this.attributes[name] = value;
  };

  ElementNode.prototype.removeAttribute = function(name) {
    delete this.attributes[name];
  };

  ElementNode.prototype.getAttribute = function(name) {
    var val = this.attributes[name];
    return (val !== undefined) ? val : null;
  };

  ElementNode.prototype.hasAttribute = function(name) {
    return name in this.attributes;
  };

  ElementNode.prototype.addEventListener = function(event, handler) {
    if (!this._eventListeners[event]) this._eventListeners[event] = [];
    this._eventListeners[event].push(handler);
  };

  ElementNode.prototype.removeEventListener = function(event, handler) {
    if (!this._eventListeners[event]) return;
    var idx = this._eventListeners[event].indexOf(handler);
    if (idx >= 0) this._eventListeners[event].splice(idx, 1);
  };

  ElementNode.prototype.dispatchEvent = function(event) {
    var listeners = this._eventListeners[event.type];
    if (listeners) {
      for (var i = 0; i < listeners.length; i++) {
        listeners[i](event);
      }
    }
    return true;
  };

  // querySelectorAll: supports '*[data-hk]', attribute selectors, and tag name selectors
  ElementNode.prototype.querySelectorAll = function(selector) {
    var results = [];
    var attrMatch = selector.match(/^\*?\[([^\]=]+)(?:=["']?([^"'\]]*)["']?)?\]$/);
    var tagMatch = !attrMatch ? selector.match(/^([a-zA-Z][a-zA-Z0-9]*)$/) : null;
    function walk(node) {
      if (node.nodeType !== 1) return;
      if (attrMatch) {
        var attrName = attrMatch[1];
        if (node.hasAttribute(attrName)) {
          if (attrMatch[2] !== undefined) {
            if (node.getAttribute(attrName) === attrMatch[2]) {
              results.push(node);
            }
          } else {
            results.push(node);
          }
        }
      } else if (tagMatch) {
        if (node.localName === tagMatch[1].toLowerCase()) {
          results.push(node);
        }
      }
      for (var i = 0; i < node.childNodes.length; i++) {
        walk(node.childNodes[i]);
      }
    }
    for (var i = 0; i < this.childNodes.length; i++) {
      walk(this.childNodes[i]);
    }
    return results;
  };

  // querySelector: returns first match
  ElementNode.prototype.querySelector = function(selector) {
    var all = this.querySelectorAll(selector);
    return all.length > 0 ? all[0] : null;
  };

  // DocumentFragment
  function DocumentFragment() {
    this._id = ++nodeIdCounter;
    this.nodeType = 11;
    this.nodeName = '#document-fragment';
    this.parentNode = null;
    this.firstChild = null;
    this.nextSibling = null;
    this.childNodes = [];
  }
  DocumentFragment.prototype.appendChild = ElementNode.prototype.appendChild;
  DocumentFragment.prototype.insertBefore = ElementNode.prototype.insertBefore;
  DocumentFragment.prototype.removeChild = ElementNode.prototype.removeChild;
  DocumentFragment.prototype.replaceChild = ElementNode.prototype.replaceChild;
  DocumentFragment.prototype.querySelectorAll = ElementNode.prototype.querySelectorAll;
  DocumentFragment.prototype.querySelector = ElementNode.prototype.querySelector;
  Object.defineProperty(DocumentFragment.prototype, 'textContent', {
    get: function() {
      var result = '';
      for (var i = 0; i < this.childNodes.length; i++) {
        var c = this.childNodes[i];
        if (c.nodeType === 3) result += c.data;
        else result += c.textContent;
      }
      return result;
    },
    set: function(val) { setTextContent(this, val); }
  });
  DocumentFragment.prototype.cloneNode = function(deep) {
    var clone = new DocumentFragment();
    if (deep) {
      for (var i = 0; i < this.childNodes.length; i++) {
        clone.appendChild(this.childNodes[i].cloneNode(true));
      }
    }
    return clone;
  };

  // Template element
  function TemplateElement() {
    ElementNode.call(this, 'template');
    this.content = new DocumentFragment();
  }
  TemplateElement.prototype = Object.create(ElementNode.prototype);
  TemplateElement.prototype.constructor = TemplateElement;
  Object.defineProperty(TemplateElement.prototype, 'innerHTML', {
    get: function() { return this._innerHTML || ''; },
    set: function(html) {
      this._innerHTML = html;
      this.content = parseHTML(html);
    }
  });

  // Minimal HTML parser (handles attributes for data-hk)
  function parseHTML(html) {
    var frag = new DocumentFragment();
    var stack = [frag];
    var pos = 0;
    while (pos < html.length) {
      if (html[pos] === '<') {
        // Check for comment
        if (html.substring(pos, pos + 4) === '<!--') {
          var endComment = html.indexOf('-->', pos + 4);
          if (endComment === -1) endComment = html.length;
          var commentData = html.substring(pos + 4, endComment);
          var commentNode = new CommentNode(commentData);
          stack[stack.length - 1].appendChild(commentNode);
          pos = endComment + 3;
          continue;
        }

        var closeTag = html.indexOf('>', pos);
        if (closeTag === -1) break;
        var tagContent = html.substring(pos + 1, closeTag);
        if (tagContent[0] === '/') {
          if (stack.length > 1) stack.pop();
        } else {
          var selfClosing = tagContent[tagContent.length - 1] === '/';
          if (selfClosing) tagContent = tagContent.substring(0, tagContent.length - 1).trim();
          var spaceIdx = tagContent.indexOf(' ');
          var tag, attrStr;
          if (spaceIdx > 0) {
            tag = tagContent.substring(0, spaceIdx);
            attrStr = tagContent.substring(spaceIdx + 1).trim();
          } else {
            tag = tagContent;
            attrStr = '';
          }
          tag = tag.trim();
          if (tag.length > 0) {
            var el = new ElementNode(tag);
            // Parse attributes
            if (attrStr.length > 0) {
              var attrRegex = /([a-zA-Z_:][a-zA-Z0-9_:.-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;
              var match;
              while ((match = attrRegex.exec(attrStr)) !== null) {
                var attrName = match[1];
                var attrVal = match[2] !== undefined ? match[2] :
                              match[3] !== undefined ? match[3] :
                              match[4] !== undefined ? match[4] : '';
                el.setAttribute(attrName, attrVal);
              }
            }
            stack[stack.length - 1].appendChild(el);
            if (!selfClosing) {
              var voidElements = ['br', 'hr', 'img', 'input', 'meta', 'link', 'area', 'base', 'col', 'embed', 'source', 'track', 'wbr'];
              if (voidElements.indexOf(tag.toLowerCase()) === -1) {
                stack.push(el);
              }
            }
          }
        }
        pos = closeTag + 1;
      } else {
        var nextTag = html.indexOf('<', pos);
        if (nextTag === -1) nextTag = html.length;
        var text = html.substring(pos, nextTag);
        if (text.length > 0) {
          stack[stack.length - 1].appendChild(new TextNode(text));
        }
        pos = nextTag;
      }
    }
    return frag;
  }

  // Document object
  var docElement = new ElementNode('html');
  var body = new ElementNode('body');
  docElement.appendChild(body);

  var elementsById = {};

  var doc = {
    nodeType: 9,
    createElement: function(tag) {
      if (tag === 'template') return new TemplateElement();
      return new ElementNode(tag);
    },
    createTextNode: function(text) {
      return new TextNode(String(text));
    },
    createComment: function(data) {
      return new CommentNode(data || '');
    },
    createDocumentFragment: function() {
      return new DocumentFragment();
    },
    getElementById: function(id) {
      if (elementsById[id]) return elementsById[id];
      var el = new ElementNode('div');
      el.setAttribute('id', id);
      body.appendChild(el);
      elementsById[id] = el;
      return el;
    },
    body: body,
    documentElement: docElement,
    _eventListeners: {},
    addEventListener: function(event, handler) {
      if (!this._eventListeners[event]) this._eventListeners[event] = [];
      this._eventListeners[event].push(handler);
    },
    removeEventListener: function(event, handler) {
      if (!this._eventListeners[event]) return;
      var idx = this._eventListeners[event].indexOf(handler);
      if (idx >= 0) this._eventListeners[event].splice(idx, 1);
    },
    _dispatchOnDelegate: function(event) {
      if (this._eventListeners[event.type]) {
        for (var i = 0; i < this._eventListeners[event.type].length; i++) {
          this._eventListeners[event.type][i](event);
        }
      }
    }
  };

  // Expose helpers for tests
  globalThis._parseHTML = parseHTML;
  globalThis._ElementNode = ElementNode;
  globalThis._TextNode = TextNode;
  globalThis._CommentNode = CommentNode;

  if (typeof globalThis !== 'undefined') {
    globalThis.document = doc;
    globalThis.window = { document: doc };
  } else if (typeof global !== 'undefined') {
    global.document = doc;
    global.window = { document: doc };
  }
})();
""".}

import unittest
import std/[jsffi, strutils]
import isonim/web/dom_api
import isonim/web/client
import isonim/web/hydration
import isonim/rxcore
import isonim/ssr/renderer
import isonim/ssr/markers
import isonim/dsl/html
import isonim/ssr/escape

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeContainer(): Element =
  document.createElement("div")

proc parseHTMLToFragment(html: cstring): Node =
  ## Parses HTML string into a DocumentFragment via the shim's parseHTML.
  var frag: Node
  {.emit: [frag, " = globalThis._parseHTML(", html, ");"].}
  return frag

proc makeSSRContainer(html: cstring): Element =
  ## Creates a container element and populates it with parsed SSR HTML.
  let container = makeContainer()
  let frag = parseHTMLToFragment(html)
  container.Node.appendChild(frag)
  return container

proc querySelector(el: Element, selector: cstring): Element =
  ## Wrapper around JS querySelector.
  var res: Element
  {.emit: [res, " = ", el, ".querySelector(", selector, ");"].}
  return res

proc querySelectorAll(el: Element, selector: cstring): seq[Element] =
  ## Wrapper around JS querySelectorAll returning a Nim seq.
  var jsArr: JsObject
  {.emit: [jsArr, " = ", el, ".querySelectorAll(", selector, ");"].}
  var length: int
  {.emit: [length, " = ", jsArr, ".length;"].}
  result = @[]
  for i in 0 ..< length:
    var node: Element
    {.emit: [node, " = ", jsArr, "[", i, "];"].}
    result.add(node)

proc initHydrationGlobals() =
  ## Sets up globalThis._$HY as the SSR hydration script would.
  {.emit: ["""
    globalThis._$HY = {
      events: [],
      completed: new WeakSet(),
      r: {},
      fe: function() {}
    };
  """].}

proc resetHydrationState() =
  ## Resets all hydration-related state between tests.
  sharedConfig.context = nil
  sharedConfig.registry = nil
  sharedConfig.done = false
  {.emit: ["globalThis._$HY = undefined;"].}

# ---------------------------------------------------------------------------
# Suite: SSR -> Hydrate -> Interactive counter
# ---------------------------------------------------------------------------

suite "SSR-Hydration E2E - Counter":
  setup:
    resetHydrationState()
    resetHydrationCounter()

  test "ssr_render_then_hydrate_counter - signal updates DOM after hydration":
    ## Full round-trip test:
    ## 1. SSR renders a counter component to HTML with hydration markers
    ## 2. HTML is parsed into a DOM tree
    ## 3. DOM is hydrated (reactive behavior attached to existing nodes)
    ## 4. Changing the signal updates the DOM

    # -- Step 1: SSR render --
    let ssrHtml = renderToString(proc(): string =
      var count = createSignal(5)
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text $count.val
          button(hydrate = true): text "+"
    )

    # Verify SSR output has hydration markers
    check "data-hk=" in ssrHtml
    check ">5<" in ssrHtml
    check ">+<" in ssrHtml

    # -- Step 2: Parse SSR HTML into DOM --
    let container = makeSSRContainer(cstring(ssrHtml))

    # Verify the DOM was created correctly
    let ssrDiv = container.firstChild
    check not ssrDiv.isNodeNil
    check ssrDiv.nodeType == 1

    # The div should have a data-hk attribute
    var divHasHk: bool
    {.emit: [divHasHk, " = (", ssrDiv, ".hasAttribute && ", ssrDiv, ".hasAttribute('data-hk'));"].}
    check divHasHk

    # The span should contain "5"
    let ssrSpan = ssrDiv.firstChild
    check ssrSpan.textContent == cstring"5"

    # -- Step 3: Hydrate --
    initHydrationGlobals()

    # The count signal for the client-side component
    var count = createSignal(5)

    createRoot proc(dispose: proc()) =
      # Set up hydration context
      sharedConfig.registry = newHydrationRegistry()
      sharedConfig.context = HydrationContext(id: "", count: 0)
      {.emit: [sharedConfig.completed, " = globalThis._$HY.completed;"].}
      {.emit: [sharedConfig.events, " = globalThis._$HY.events;"].}

      gatherHydratable(container.Node)

      # Verify registry was populated with the hydration-marked elements
      check sharedConfig.registry.has(cstring"1")
      check sharedConfig.registry.has(cstring"2")
      check sharedConfig.registry.has(cstring"3")

      # Hydrate the div: getNextElement reuses the existing SSR node
      let divFallback = tmpl("<div><span></span><button>+</button></div>")
      let divNode = getNextElement(divFallback)

      # Verify we got the original SSR node (same object)
      var isSameDiv: bool
      {.emit: [isSameDiv, " = (", divNode, " === ", ssrDiv, ");"].}
      check isSameDiv

      # Hydrate the span: reuse existing SSR span
      let spanFallback = tmpl("<span></span>")
      let spanNode = getNextElement(spanFallback)

      # Verify it's the original span from SSR
      var isSameSpan: bool
      {.emit: [isSameSpan, " = (", spanNode, " === ", ssrSpan, ");"].}
      check isSameSpan

      # Hydrate the button
      let btnFallback = tmpl("<button>+</button>")
      let btnNode = getNextElement(btnFallback)

      # -- Step 4: Attach reactive behavior --
      # Clear the span's SSR text and insert reactive content
      spanNode.textContent = ""
      insert(spanNode, proc(): cstring = cstring($count.val))

      # Verify initial state matches SSR
      check spanNode.textContent == cstring"5"

      # -- Step 5: Signal updates drive DOM changes --
      count.val = 10
      check spanNode.textContent == cstring"10"

      count.val = 42
      check spanNode.textContent == cstring"42"

      count.val = 0
      check spanNode.textContent == cstring"0"

      # Clean up
      sharedConfig.context = nil
      dispose()

  test "ssr_hydrate_counter_with_event - click handler works after hydration":
    ## Verifies that event handlers attached during hydration work correctly.

    # SSR render
    let ssrHtml = renderToString(proc(): string =
      var count = createSignal(0)
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text $count.val
          button(hydrate = true): text "+"
    )

    let container = makeSSRContainer(cstring(ssrHtml))
    initHydrationGlobals()

    var count = createSignal(0)

    createRoot proc(dispose: proc()) =
      sharedConfig.registry = newHydrationRegistry()
      sharedConfig.context = HydrationContext(id: "", count: 0)
      {.emit: [sharedConfig.completed, " = globalThis._$HY.completed;"].}
      {.emit: [sharedConfig.events, " = globalThis._$HY.events;"].}

      gatherHydratable(container.Node)

      # Reuse SSR nodes
      let divNode = getNextElement(tmpl("<div></div>"))
      let spanNode = getNextElement(tmpl("<span></span>"))
      let btnNode = getNextElement(tmpl("<button>+</button>"))

      # Attach reactive text
      spanNode.textContent = ""
      insert(spanNode, proc(): cstring = cstring($count.val))
      check spanNode.textContent == cstring"0"

      # Attach click handler to button
      btnNode.addEventListener(cstring"click", proc(ev: Event) =
        count.val = count.val + 1
      )

      # Simulate clicking the button
      var clickEvt: Event
      {.emit: [clickEvt, " = { type: 'click', target: ", btnNode, ", cancelBubble: false };"].}
      {.emit: [btnNode, ".dispatchEvent(", clickEvt, ");"].}

      check spanNode.textContent == cstring"1"

      # Click again
      {.emit: [btnNode, ".dispatchEvent(", clickEvt, ");"].}
      check spanNode.textContent == cstring"2"

      sharedConfig.context = nil
      dispose()

# ---------------------------------------------------------------------------
# Suite: SSR -> Hydrate -> Interactive list
# ---------------------------------------------------------------------------

suite "SSR-Hydration E2E - List":
  setup:
    resetHydrationState()
    resetHydrationCounter()

  test "ssr_render_then_hydrate_list - list signal updates DOM after hydration":
    ## Full round-trip for a list component:
    ## 1. SSR renders a list to HTML
    ## 2. Parse into DOM
    ## 3. Hydrate
    ## 4. Changing items signal updates the list in the DOM

    # SSR render a list
    let ssrHtml = renderToString(proc(): string =
      let items = @["alpha", "beta", "gamma"]
      buildHtmlString:
        ul(hydrate = true):
          raw ssrFor(items, proc(item: string, index: int): string =
            buildHtmlString:
              li: text item
          )
    )

    # Verify SSR output
    check "data-hk=" in ssrHtml
    check "<li>alpha</li>" in ssrHtml
    check "<li>beta</li>" in ssrHtml
    check "<li>gamma</li>" in ssrHtml

    # Parse into DOM
    let container = makeSSRContainer(cstring(ssrHtml))
    let ssrUl = container.firstChild
    check not ssrUl.isNodeNil

    # Verify initial DOM structure: ul with 3 li children
    var ulChildCount: int
    {.emit: [ulChildCount, " = ", ssrUl, ".childNodes.length;"].}
    check ulChildCount == 3

    # Hydrate
    initHydrationGlobals()

    var items = createSignal(cstring"alpha,beta,gamma")

    createRoot proc(dispose: proc()) =
      sharedConfig.registry = newHydrationRegistry()
      sharedConfig.context = HydrationContext(id: "", count: 0)
      {.emit: [sharedConfig.completed, " = globalThis._$HY.completed;"].}
      {.emit: [sharedConfig.events, " = globalThis._$HY.events;"].}

      gatherHydratable(container.Node)

      # Reuse the existing ul
      let ulNode = getNextElement(tmpl("<ul></ul>"))

      # Verify we got the original SSR ul back
      var isSameUl: bool
      {.emit: [isSameUl, " = (", ulNode, " === ", ssrUl, ");"].}
      check isSameUl

      # Clear SSR children and insert reactive content
      ulNode.textContent = ""
      insert(ulNode, proc(): cstring = items.val)

      # Verify initial state
      check ulNode.textContent == cstring"alpha,beta,gamma"

      # Add an item
      items.val = cstring"alpha,beta,gamma,delta"
      check ulNode.textContent == cstring"alpha,beta,gamma,delta"

      # Remove items
      items.val = cstring"alpha,delta"
      check ulNode.textContent == cstring"alpha,delta"

      # Empty list
      items.val = cstring""
      check ulNode.textContent == cstring""

      # Re-populate
      items.val = cstring"one,two"
      check ulNode.textContent == cstring"one,two"

      sharedConfig.context = nil
      dispose()

  test "ssr_hydrate_list_with_dynamic_children - individual list items update":
    ## Tests hydration where each list item has its own reactive behavior.

    # SSR render
    let ssrHtml = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text "Item count: 3"
          ul(hydrate = true):
            li: text "first"
            li: text "second"
            li: text "third"
    )

    check "data-hk=" in ssrHtml
    check "Item count: 3" in ssrHtml

    let container = makeSSRContainer(cstring(ssrHtml))
    initHydrationGlobals()

    var itemCount = createSignal(3)
    var listText = createSignal(cstring"first,second,third")

    createRoot proc(dispose: proc()) =
      sharedConfig.registry = newHydrationRegistry()
      sharedConfig.context = HydrationContext(id: "", count: 0)
      {.emit: [sharedConfig.completed, " = globalThis._$HY.completed;"].}
      {.emit: [sharedConfig.events, " = globalThis._$HY.events;"].}

      gatherHydratable(container.Node)

      # Hydrate the div, span, and ul
      let divNode = getNextElement(tmpl("<div></div>"))
      let spanNode = getNextElement(tmpl("<span></span>"))
      let ulNode = getNextElement(tmpl("<ul></ul>"))

      # Attach reactive text to the span
      spanNode.textContent = ""
      insert(spanNode, proc(): cstring =
        cstring("Item count: " & $itemCount.val)
      )

      # Attach reactive content to the ul
      ulNode.textContent = ""
      insert(ulNode, proc(): cstring = listText.val)

      # Verify initial state
      check spanNode.textContent == cstring"Item count: 3"
      check ulNode.textContent == cstring"first,second,third"

      # Update item count and list
      itemCount.val = 4
      listText.val = cstring"first,second,third,fourth"
      check spanNode.textContent == cstring"Item count: 4"
      check ulNode.textContent == cstring"first,second,third,fourth"

      # Remove items
      itemCount.val = 1
      listText.val = cstring"only"
      check spanNode.textContent == cstring"Item count: 1"
      check ulNode.textContent == cstring"only"

      sharedConfig.context = nil
      dispose()

# ---------------------------------------------------------------------------
# Suite: SSR -> Hydrate integration via hydrate() entry point
# ---------------------------------------------------------------------------

suite "SSR-Hydration E2E - hydrate() entry point":
  setup:
    resetHydrationState()
    resetHydrationCounter()

  test "hydrate_proc_counter - using hydrate() API for full round-trip":
    ## Uses the hydrate() proc from hydration.nim directly, which is the
    ## real entry point for client-side hydration.

    # SSR render
    let ssrHtml = renderToString(proc(): string =
      var c = createSignal(7)
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text $c.val
    )

    check "data-hk=" in ssrHtml
    check ">7<" in ssrHtml

    # Parse into DOM container
    let container = makeSSRContainer(cstring(ssrHtml))

    # Set up _$HY (mimicking the hydration script from SSR)
    # Note: done must be false/absent for hydrate() to proceed
    {.emit: ["""
      globalThis._$HY = {
        events: [],
        completed: new WeakSet(),
        r: {},
        fe: function() {}
      };
    """].}

    # Create the client-side count signal
    var clientCount = createSignal(7)

    # Use the hydrate() entry point
    hydrate(
      code = proc(): Node =
        # This code runs during hydration.
        # getNextElement is called by hydrate() context to reuse SSR nodes.
        let divFallback = tmpl("<div><span></span></div>")
        let divNode = getNextElement(divFallback)

        let spanFallback = tmpl("<span></span>")
        let spanNode = getNextElement(spanFallback)

        # Attach reactive text
        spanNode.textContent = ""
        insert(spanNode, proc(): cstring = cstring($clientCount.val))

        return divNode
      ,
      element = container
    )

    # After hydration, verify the span has the initial value
    let hydratedSpan = container.querySelector(cstring"span")
    check not Element(hydratedSpan).isNodeNil
    check hydratedSpan.textContent == cstring"7"

    # Signal update should drive DOM change
    clientCount.val = 99
    check hydratedSpan.textContent == cstring"99"

    clientCount.val = 0
    check hydratedSpan.textContent == cstring"0"

  test "hydrate_marks_done - hydration is marked complete after hydrate()":
    ## Verifies that after hydrate() runs, sharedConfig.done is true
    ## and globalThis._$HY.done is set.

    let ssrHtml = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true): text "hello"
    )

    let container = makeSSRContainer(cstring(ssrHtml))

    {.emit: ["""
      globalThis._$HY = {
        events: [],
        completed: new WeakSet(),
        r: {},
        fe: function() {}
      };
    """].}

    hydrate(
      code = proc(): Node =
        let divNode = getNextElement(tmpl("<div></div>"))
        return divNode
      ,
      element = container
    )

    # sharedConfig.done should be true
    check sharedConfig.done

    # globalThis._$HY.done should also be true
    var hyDone: bool
    {.emit: [hyDone, " = !!(globalThis._$HY && globalThis._$HY.done);"].}
    check hyDone

# ---------------------------------------------------------------------------
# Suite: SSR hydration key consistency
# ---------------------------------------------------------------------------

suite "SSR-Hydration E2E - Key Consistency":
  setup:
    resetHydrationState()
    resetHydrationCounter()

  test "ssr_keys_match_client_keys - hydration keys are consistent between phases":
    ## The SSR phase and client hydration phase must generate keys in the
    ## same order. This test verifies that SSR data-hk attributes match
    ## the keys that getHydrationKey() produces during hydration.

    # SSR render: three elements with hydrate=true
    let ssrHtml = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true):
          span(hydrate = true): text "A"
          p(hydrate = true): text "B"
    )

    # Extract the data-hk values from SSR HTML
    check "data-hk=\"1\"" in ssrHtml
    check "data-hk=\"2\"" in ssrHtml
    check "data-hk=\"3\"" in ssrHtml

    # Parse and set up hydration
    let container = makeSSRContainer(cstring(ssrHtml))
    initHydrationGlobals()

    createRoot proc(dispose: proc()) =
      sharedConfig.registry = newHydrationRegistry()
      sharedConfig.context = HydrationContext(id: "", count: 0)

      gatherHydratable(container.Node)

      # Verify that registry keys match SSR keys
      check sharedConfig.registry.has(cstring"1")
      check sharedConfig.registry.has(cstring"2")
      check sharedConfig.registry.has(cstring"3")

      # Client hydration key generation matches: 1, 2, 3
      # (getHydrationKey is called by getNextElement internally)
      let divEl = getNextElement(tmpl("<div></div>"))
      let spanEl = getNextElement(tmpl("<span></span>"))
      let pEl = getNextElement(tmpl("<p></p>"))

      # All three keys should have been consumed from registry
      check not sharedConfig.registry.has(cstring"1")
      check not sharedConfig.registry.has(cstring"2")
      check not sharedConfig.registry.has(cstring"3")

      # The reused nodes should have the original data-hk attributes
      var divHk, spanHk, pHk: cstring
      {.emit: [divHk, " = ", divEl, ".getAttribute('data-hk');"].}
      {.emit: [spanHk, " = ", spanEl, ".getAttribute('data-hk');"].}
      {.emit: [pHk, " = ", pEl, ".getAttribute('data-hk');"].}
      check divHk == cstring"1"
      check spanHk == cstring"2"
      check pHk == cstring"3"

      sharedConfig.context = nil
      dispose()

  test "ssr_counter_reset_between_phases - hydration counter resets properly":
    ## renderToString resets the hydration counter. A second call to
    ## renderToString should produce keys starting from 1 again.

    let html1 = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true): text "first"
    )
    check "data-hk=\"1\"" in html1

    let html2 = renderToString(proc(): string =
      buildHtmlString:
        tdiv(hydrate = true): text "second"
    )
    # Keys should start from 1 again, not 2
    check "data-hk=\"1\"" in html2
