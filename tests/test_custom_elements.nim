## Tests for Web Components support (M28).
##
## Runs under `nim js -r`. Uses a DOM shim extended with
## customElements.define() support.

when not defined(js):
  {.error: "test_custom_elements must be compiled with the JS backend".}

# Inject DOM shim with customElements support
{.emit: """
(function() {
  if (typeof document !== 'undefined') return;

  var nodeIdCounter = 0;

  function TextNode(text) {
    this._id = ++nodeIdCounter;
    this.nodeType = 3;
    this.nodeName = '#text';
    this.data = text;
    this.parentNode = null;
    this.firstChild = null;
    this.nextSibling = null;
    this.childNodes = [];
  }
  TextNode.prototype.remove = function() {
    if (this.parentNode) this.parentNode.removeChild(this);
  };
  TextNode.prototype.cloneNode = function() { return new TextNode(this.data); };

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
    this._innerHTML = '';
    this.style = { _props: {}, setProperty: function(k,v){this._props[k]=v;}, removeProperty: function(k){delete this._props[k];}, cssText: '' };
    this._eventListeners = {};
    this.disabled = false;
    this._shadowRoot = null;
  }

  function updateSiblings(node) {
    var children = node.childNodes;
    node.firstChild = children.length > 0 ? children[0] : null;
    for (var i = 0; i < children.length; i++) {
      children[i].nextSibling = (i+1 < children.length) ? children[i+1] : null;
      children[i].parentNode = node;
    }
  }

  function setTextContent(node, val) {
    for (var i = 0; i < node.childNodes.length; i++) node.childNodes[i].parentNode = null;
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
      var r = '';
      for (var i = 0; i < this.childNodes.length; i++) {
        var c = this.childNodes[i];
        r += (c.nodeType === 3) ? c.data : c.textContent;
      }
      return r;
    },
    set: function(val) { setTextContent(this, val); }
  });

  Object.defineProperty(TextNode.prototype, 'textContent', {
    get: function() { return this.data; },
    set: function(val) { this.data = String(val); }
  });

  ElementNode.prototype.appendChild = function(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    if (child.nodeType === 11) {
      var kids = child.childNodes.slice();
      for (var i = 0; i < kids.length; i++) this.appendChild(kids[i]);
      child.childNodes = []; updateSiblings(child);
      return child;
    }
    child.parentNode = this;
    this.childNodes.push(child);
    updateSiblings(this);
    return child;
  };

  ElementNode.prototype.insertBefore = function(newNode, refNode) {
    if (newNode.parentNode) newNode.parentNode.removeChild(newNode);
    if (!refNode) return this.appendChild(newNode);
    if (newNode.nodeType === 11) {
      var kids = newNode.childNodes.slice();
      for (var i = 0; i < kids.length; i++) this.insertBefore(kids[i], refNode);
      newNode.childNodes = []; updateSiblings(newNode);
      return newNode;
    }
    var idx = this.childNodes.indexOf(refNode);
    if (idx >= 0) { newNode.parentNode = this; this.childNodes.splice(idx, 0, newNode); }
    else return this.appendChild(newNode);
    updateSiblings(this);
    return newNode;
  };

  ElementNode.prototype.removeChild = function(child) {
    var idx = this.childNodes.indexOf(child);
    if (idx >= 0) { this.childNodes.splice(idx, 1); child.parentNode = null; child.nextSibling = null; }
    updateSiblings(this);
    return child;
  };

  ElementNode.prototype.replaceChild = function(nc, oc) {
    var idx = this.childNodes.indexOf(oc);
    if (idx >= 0) {
      if (nc.parentNode) nc.parentNode.removeChild(nc);
      oc.parentNode = null; oc.nextSibling = null;
      nc.parentNode = this; this.childNodes[idx] = nc;
    }
    updateSiblings(this);
    return oc;
  };

  ElementNode.prototype.remove = function() {
    if (this.parentNode) this.parentNode.removeChild(this);
  };

  ElementNode.prototype.cloneNode = function(deep) {
    var clone = new ElementNode(this.localName);
    clone.className = this.className;
    var keys = Object.keys(this.attributes);
    for (var i = 0; i < keys.length; i++) clone.attributes[keys[i]] = this.attributes[keys[i]];
    if (deep) {
      for (var j = 0; j < this.childNodes.length; j++) clone.appendChild(this.childNodes[j].cloneNode(true));
    }
    return clone;
  };

  ElementNode.prototype.setAttribute = function(n, v) { this.attributes[n] = v; };
  ElementNode.prototype.removeAttribute = function(n) { delete this.attributes[n]; };
  ElementNode.prototype.getAttribute = function(n) { var v = this.attributes[n]; return v !== undefined ? v : null; };
  ElementNode.prototype.hasAttribute = function(n) { return n in this.attributes; };
  ElementNode.prototype.addEventListener = function(e, h) {
    if (!this._eventListeners[e]) this._eventListeners[e] = [];
    this._eventListeners[e].push(h);
  };
  ElementNode.prototype.removeEventListener = function(e, h) {
    if (!this._eventListeners[e]) return;
    var idx = this._eventListeners[e].indexOf(h);
    if (idx >= 0) this._eventListeners[e].splice(idx, 1);
  };
  ElementNode.prototype.dispatchEvent = function(event) {
    var listeners = this._eventListeners[event.type];
    if (listeners) for (var i = 0; i < listeners.length; i++) listeners[i](event);
    return true;
  };

  // Shadow DOM shim
  ElementNode.prototype.attachShadow = function(opts) {
    var shadow = new ElementNode('shadow-root');
    shadow._mode = opts.mode || 'open';
    this._shadowRoot = shadow;
    return shadow;
  };

  Object.defineProperty(ElementNode.prototype, 'shadowRoot', {
    get: function() { return this._shadowRoot; }
  });

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
  Object.defineProperty(DocumentFragment.prototype, 'textContent', {
    get: function() { var r = ''; for (var i = 0; i < this.childNodes.length; i++) { var c = this.childNodes[i]; r += (c.nodeType === 3) ? c.data : c.textContent; } return r; },
    set: function(val) { setTextContent(this, val); }
  });
  DocumentFragment.prototype.cloneNode = function(deep) {
    var clone = new DocumentFragment();
    if (deep) for (var i = 0; i < this.childNodes.length; i++) clone.appendChild(this.childNodes[i].cloneNode(true));
    return clone;
  };

  function TemplateElement() {
    ElementNode.call(this, 'template');
    this.content = new DocumentFragment();
  }
  TemplateElement.prototype = Object.create(ElementNode.prototype);
  TemplateElement.prototype.constructor = TemplateElement;
  Object.defineProperty(TemplateElement.prototype, 'innerHTML', {
    get: function() { return this._innerHTML || ''; },
    set: function(html) { this._innerHTML = html; this.content = parseHTML(html); }
  });

  function parseHTML(html) {
    var frag = new DocumentFragment();
    var stack = [frag];
    var pos = 0;
    while (pos < html.length) {
      if (html[pos] === '<') {
        var closeTag = html.indexOf('>', pos);
        if (closeTag === -1) break;
        var tc = html.substring(pos + 1, closeTag);
        if (tc[0] === '/') { if (stack.length > 1) stack.pop(); }
        else {
          var sc = tc[tc.length - 1] === '/';
          if (sc) tc = tc.substring(0, tc.length - 1).trim();
          var si = tc.indexOf(' ');
          var tag = si > 0 ? tc.substring(0, si) : tc;
          tag = tag.trim();
          if (tag.length > 0) {
            var el = new ElementNode(tag);
            stack[stack.length - 1].appendChild(el);
            if (!sc) {
              var ve = ['br','hr','img','input','meta','link','area','base','col','embed','source','track','wbr'];
              if (ve.indexOf(tag.toLowerCase()) === -1) stack.push(el);
            }
          }
        }
        pos = closeTag + 1;
      } else {
        var nt = html.indexOf('<', pos);
        if (nt === -1) nt = html.length;
        var txt = html.substring(pos, nt);
        if (txt.length > 0) stack[stack.length - 1].appendChild(new TextNode(txt));
        pos = nt;
      }
    }
    return frag;
  }

  // ---- HTMLElement base class shim ----
  function HTMLElement() {
    ElementNode.call(this, 'div');
  }
  HTMLElement.prototype = Object.create(ElementNode.prototype);
  HTMLElement.prototype.constructor = HTMLElement;

  if (typeof globalThis !== 'undefined') {
    globalThis.HTMLElement = HTMLElement;
  } else if (typeof global !== 'undefined') {
    global.HTMLElement = HTMLElement;
  }

  // ---- customElements registry shim ----
  var customElementsRegistry = {};

  var customElementsShim = {
    define: function(name, cls) {
      customElementsRegistry[name] = cls;
    },
    get: function(name) {
      return customElementsRegistry[name];
    },
    // Helper: create and connect an instance (for testing)
    create: function(name, attrs) {
      var Cls = customElementsRegistry[name];
      if (!Cls) throw new Error('Custom element not registered: ' + name);
      var instance = new Cls();
      // Set attributes before connecting
      if (attrs) {
        var keys = Object.keys(attrs);
        for (var i = 0; i < keys.length; i++) {
          instance.setAttribute(keys[i], attrs[keys[i]]);
        }
      }
      // Simulate connection
      if (instance.connectedCallback) instance.connectedCallback();
      return instance;
    }
  };

  var docElement = new ElementNode('html');
  var body = new ElementNode('body');
  docElement.appendChild(body);
  var elementsById = {};

  var doc = {
    nodeType: 9,
    createElement: function(tag) {
      // Check if it's a custom element
      if (customElementsRegistry[tag]) {
        return customElementsShim.create(tag);
      }
      if (tag === 'template') return new TemplateElement();
      return new ElementNode(tag);
    },
    createTextNode: function(text) { return new TextNode(String(text)); },
    createDocumentFragment: function() { return new DocumentFragment(); },
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
    addEventListener: function(e, h) {
      if (!this._eventListeners[e]) this._eventListeners[e] = [];
      this._eventListeners[e].push(h);
    },
    removeEventListener: function(e, h) {
      if (!this._eventListeners[e]) return;
      var idx = this._eventListeners[e].indexOf(h);
      if (idx >= 0) this._eventListeners[e].splice(idx, 1);
    },
    _dispatchOnDelegate: function(event) {
      if (this._eventListeners[event.type]) {
        for (var i = 0; i < this._eventListeners[event.type].length; i++) {
          this._eventListeners[event.type][i](event);
        }
      }
    }
  };

  if (typeof globalThis !== 'undefined') {
    globalThis.document = doc;
    globalThis.window = { document: doc };
    globalThis.customElements = customElementsShim;
  } else if (typeof global !== 'undefined') {
    global.document = doc;
    global.window = { document: doc };
    global.customElements = customElementsShim;
  }

  // Expose for testing
  globalThis._customElementsRegistry = customElementsRegistry;
  globalThis._customElementsShim = customElementsShim;
})();
""".}

import unittest
import std/[jsffi]
import isonim/web/dom_api
import isonim/web/custom_element
import isonim/core/[signals, computation]
import isonim/rxcore

# ---- Helpers ----

proc createCustomInstance(tagName: cstring, attrs: varargs[(cstring, cstring)]): Element =
  ## Creates a custom element instance via the shim's create helper.
  var instance: Element
  if attrs.len == 0:
    {.emit: [instance, " = globalThis._customElementsShim.create(", tagName, ", {});"].}
  else:
    let obj = newJsObject()
    for (k, v) in attrs:
      obj[k] = v
    {.emit: [instance, " = globalThis._customElementsShim.create(", tagName, ", ", obj, ");"].}
  return instance

proc getShadowRoot(el: Element): Element =
  var sr: Element
  {.emit: [sr, " = ", el, "._shadowRoot;"].}
  return sr

proc getShadowTextContent(el: Element): cstring =
  let sr = getShadowRoot(el)
  if sr.isNodeNil:
    return cstring""
  return sr.textContent

proc isRegistered(tagName: cstring): bool =
  {.emit: [result, " = !!(globalThis._customElementsRegistry[", tagName, "]);"].}

# ---- Tests ----

suite "Web Components - Registration":
  test "registerCustomElement registers the tag":
    registerCustomElement(
      cstring"test-reg",
      [propDef(cstring"value", cstring"default")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let el = document.createElement("span")
        el.textContent = cstring"registered"
        ctx.renderRoot.appendChild(el)
    )
    check isRegistered(cstring"test-reg")

  test "custom element renders into shadow root":
    registerCustomElement(
      cstring"test-shadow",
      [propDef(cstring"label", cstring"hello")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let span = document.createElement("span")
        span.textContent = getProp(cstring"label")
        ctx.renderRoot.appendChild(span)
      ,
      useShadow = true
    )

    let el = createCustomInstance(cstring"test-shadow")
    let shadowContent = getShadowTextContent(el)
    check shadowContent == cstring"hello"

  test "custom element reads attributes":
    registerCustomElement(
      cstring"test-attrs",
      [propDef(cstring"name", cstring"World")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let span = document.createElement("span")
        span.textContent = cstring"Hello, " & getProp(cstring"name")
        ctx.renderRoot.appendChild(span)
    )

    let el = createCustomInstance(cstring"test-attrs", (cstring"name", cstring"IsoNim"))
    check getShadowTextContent(el) == cstring"Hello, IsoNim"

  test "custom element uses default prop values":
    registerCustomElement(
      cstring"test-defaults",
      [propDef(cstring"count", cstring"42")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let span = document.createElement("span")
        span.textContent = cstring"Count: " & getProp(cstring"count")
        ctx.renderRoot.appendChild(span)
    )

    let el = createCustomInstance(cstring"test-defaults")
    check getShadowTextContent(el) == cstring"Count: 42"

suite "Web Components - Reactive":
  test "custom element with reactive signal":
    # We test reactivity by having the render function store a setter
    # on the element, then calling it from outside.
    registerCustomElement(
      cstring"test-reactive",
      [propDef(cstring"initial", cstring"0")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        var initVal = 0
        let initStr = getProp(cstring"initial")
        {.emit: [initVal, " = parseInt(", initStr, ") || 0;"].}

        var count = createSignal(initVal)

        let span = document.createElement("span")
        createRenderEffect proc() =
          span.textContent = cstring($count.val)
        ctx.renderRoot.appendChild(span)

        # Store a setter closure on the element for test access
        let setter = proc(v: int) =
          count.val = v
        {.emit: [ctx.element, "._setCount = ", setter, ";"].}
    )

    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"test-reactive", (cstring"initial", cstring"5"))
      check getShadowTextContent(el) == cstring"5"

      # Update the signal via the stored setter
      {.emit: [el, "._setCount(10);"].}
      check getShadowTextContent(el) == cstring"10"

      dispose()

  test "custom element without shadow DOM":
    registerCustomElement(
      cstring"test-noshadow",
      [propDef(cstring"msg", cstring"no shadow")],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let span = document.createElement("span")
        span.textContent = getProp(cstring"msg")
        ctx.renderRoot.appendChild(span)
      ,
      useShadow = false
    )

    let el = createCustomInstance(cstring"test-noshadow")
    # Without shadow DOM, content is in the element itself
    check el.textContent == cstring"no shadow"

  test "custom element with multiple props":
    registerCustomElement(
      cstring"test-multiprops",
      [
        propDef(cstring"first", cstring"John"),
        propDef(cstring"last", cstring"Doe")
      ],
      proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
        let span = document.createElement("span")
        span.textContent = getProp(cstring"first") & cstring" " & getProp(cstring"last")
        ctx.renderRoot.appendChild(span)
    )

    let el = createCustomInstance(cstring"test-multiprops",
      (cstring"first", cstring"Jane"), (cstring"last", cstring"Smith"))
    check getShadowTextContent(el) == cstring"Jane Smith"
