## Tests for the web renderer (M7).
##
## These tests run under `nim js -r` which executes via Node.js.
## Since Node.js has no DOM, we inject a minimal DOM shim via {.emit.}.

when not defined(js):
  {.error: "test_web must be compiled with the JS backend: nim js -r tests/test_web.nim".}

# Inject a minimal DOM shim before any imports that use `document`
{.emit: """
// ---- Minimal DOM shim for Node.js ----
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
    // Remove all children
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
        else result += c.textContent;
      }
      return result;
    },
    set: function(val) {
      setTextContent(this, val);
    }
  });

  // Override textContent setter for TextNode too
  Object.defineProperty(TextNode.prototype, 'textContent', {
    get: function() { return this.data; },
    set: function(val) { this.data = String(val); }
  });

  ElementNode.prototype.appendChild = function(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    // Handle DocumentFragment
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
    // Handle DocumentFragment
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
    return this.attributes[name] || null;
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

  // Template element: parses innerHTML into content fragment
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

  // Minimal HTML parser (handles simple cases for testing)
  function parseHTML(html) {
    var frag = new DocumentFragment();
    var stack = [frag];
    var pos = 0;
    while (pos < html.length) {
      if (html[pos] === '<') {
        var closeTag = html.indexOf('>', pos);
        if (closeTag === -1) break;
        var tagContent = html.substring(pos + 1, closeTag);
        if (tagContent[0] === '/') {
          // Closing tag
          if (stack.length > 1) stack.pop();
        } else {
          // Opening tag (possibly self-closing)
          var selfClosing = tagContent[tagContent.length - 1] === '/';
          if (selfClosing) tagContent = tagContent.substring(0, tagContent.length - 1).trim();
          var spaceIdx = tagContent.indexOf(' ');
          var tag = spaceIdx > 0 ? tagContent.substring(0, spaceIdx) : tagContent;
          tag = tag.trim();
          if (tag.length > 0) {
            var el = new ElementNode(tag);
            stack[stack.length - 1].appendChild(el);
            if (!selfClosing) {
              // Check for void elements
              var voidElements = ['br', 'hr', 'img', 'input', 'meta', 'link', 'area', 'base', 'col', 'embed', 'source', 'track', 'wbr'];
              if (voidElements.indexOf(tag.toLowerCase()) === -1) {
                stack.push(el);
              }
            }
          }
        }
        pos = closeTag + 1;
      } else {
        // Text node
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
    createDocumentFragment: function() {
      return new DocumentFragment();
    },
    getElementById: function(id) {
      if (elementsById[id]) return elementsById[id];
      // Auto-create for testing
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
    // Helper for tests to dispatch events
    _dispatchOnDelegate: function(event) {
      if (this._eventListeners[event.type]) {
        for (var i = 0; i < this._eventListeners[event.type].length; i++) {
          this._eventListeners[event.type][i](event);
        }
      }
    }
  };

  // Make document globally available
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
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/rxcore

# Helper to get text content from a node tree
proc getTextContent(n: Node): cstring =
  n.textContent

# Helper to create a fresh container element for each test
proc makeContainer(): Element =
  document.createElement("div")

suite "Web Renderer - template":
  test "test_template_clone - template creates reusable DOM template; cloning produces identical subtree":
    let tmpl = tmpl("<div><span></span><p></p></div>")
    let a = tmpl()
    let b = tmpl()

    # Both should be element nodes
    check a.nodeType == 1
    check b.nodeType == 1

    # They should be distinct objects (cloned, not same reference)
    check cast[int](a) != cast[int](b)

    # Both should have the same structure: div > span + p
    check a.firstChild.nodeType == 1  # span
    check a.firstChild.nextSibling.nodeType == 1  # p
    check b.firstChild.nodeType == 1  # span
    check b.firstChild.nextSibling.nodeType == 1  # p

    # Tag names should match
    var aTag, bTag, aChildTag, bChildTag: cstring
    {.emit: [aTag, " = ", a, ".tagName;"].}
    {.emit: [bTag, " = ", b, ".tagName;"].}
    {.emit: [aChildTag, " = ", a, ".firstChild.tagName;"].}
    {.emit: [bChildTag, " = ", b, ".firstChild.tagName;"].}
    check aTag == bTag
    check aChildTag == bChildTag

suite "Web Renderer - insert":
  test "test_insert_reactive_text - insert with signal accessor updates DOM text node on signal change":
    let container = makeContainer()
    let count = createSignal(0)

    createRoot do (dispose: proc()):
      insert(container, proc(): cstring = cstring($count.val))

      # Initial value should be rendered
      check container.getTextContent() == "0"

      # Update the signal
      count.val = 42
      check container.getTextContent() == "42"

      # Update again
      count.val = -7
      check container.getTextContent() == "-7"

      dispose()

suite "Web Renderer - events":
  test "test_event_delegation - delegateEvents + click on child triggers delegated callback":
    let container = makeContainer()
    var clicked = false
    var clickCount = 0

    let button = document.createElement("button")
    container.Node.appendChild(button.Node)

    # Set up delegated event handler on the button
    addEventListenerWeb(button.Node, "click", proc(ev: Event) =
      clicked = true
      inc clickCount
    , delegate = true)

    # Register delegation for click events
    delegateEvents(["click"])

    # Simulate a click event by dispatching through the document's delegation handler
    # The eventHandler walks up from target looking for $$click property
    var evt: Event
    {.emit: [evt, " = { type: 'click', target: ", button, ", currentTarget: document, cancelBubble: false };"].}

    # Dispatch through document's registered listener
    {.emit: ["document._dispatchOnDelegate(", evt, ");"].}

    check clicked == true
    check clickCount == 1

    # Click again
    {.emit: [evt, " = { type: 'click', target: ", button, ", currentTarget: document, cancelBubble: false };"].}
    {.emit: ["document._dispatchOnDelegate(", evt, ");"].}

    check clickCount == 2

    clearDelegatedEvents()

suite "Web Renderer - render":
  test "test_render_mount - render mounts component tree into target element":
    # Get a fresh element (auto-created by our shim)
    let target = document.getElementById("test-mount-target")
    # Clear it
    target.textContent = ""

    let cleanup = render(
      proc(): Node =
        let el = tmpl("<div><h1></h1></div>")()
        let h1 = el.firstChild
        insert(h1, cstring"Mounted!")
        el
      ,
      target
    )

    # The target should now contain our rendered tree
    check target.firstChild.nodeType == 1  # div

    var h1Text: cstring
    {.emit: [h1Text, " = ", target, ".firstChild.firstChild.textContent;"].}
    check h1Text == "Mounted!"

    # Cleanup should clear the target
    cleanup()
    check target.firstChild.isNodeNil

suite "Web Renderer - counter demo compilation":
  test "test_counter_demo_works - counter component compiles and runs":
    # This test verifies that the counter pattern compiles and the
    # reactive wiring works correctly under Node.js with our DOM shim.
    let target = document.getElementById("test-counter-target")
    target.textContent = ""

    let count = createSignal(0)

    createRoot do (dispose: proc()):
      let el = tmpl("<div><span></span></div>")()
      let span = el.firstChild

      insert(span, proc(): cstring = cstring($count.val))
      target.Node.appendChild(el)

      # Check initial render
      check span.textContent == "0"

      # Simulate increment
      count.val = count.val + 1
      check span.textContent == "1"

      # Simulate decrement
      count.val = count.val - 1
      check span.textContent == "0"

      # Multiple updates
      count.val = 99
      check span.textContent == "99"

      dispose()
