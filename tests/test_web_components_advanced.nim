## Advanced tests for Web Components support (G6).
##
## Covers: attribute change reactivity, custom event dispatching,
## multiple independent instances, disconnectedCallback cleanup,
## and light DOM mode.
##
## Runs under `nim js -r`. Uses the same DOM shim as test_custom_elements.nim.

when not defined(js):
  {.error: "test_web_components_advanced must be compiled with the JS backend".}

# Inject DOM shim with customElements support + CustomEvent
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

  ElementNode.prototype.setAttribute = function(n, v) {
    var old = this.attributes[n];
    this.attributes[n] = v;
    // Trigger attributeChangedCallback if registered
    if (this.attributeChangedCallback) {
      this.attributeChangedCallback(n, old !== undefined ? old : null, v);
    }
  };
  ElementNode.prototype.removeAttribute = function(n) {
    var old = this.attributes[n];
    delete this.attributes[n];
    if (this.attributeChangedCallback) {
      this.attributeChangedCallback(n, old !== undefined ? old : null, null);
    }
  };
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

  // innerHTML setter clears children
  Object.defineProperty(ElementNode.prototype, 'innerHTML', {
    get: function() { return this._innerHTML || ''; },
    set: function(val) {
      for (var i = 0; i < this.childNodes.length; i++) this.childNodes[i].parentNode = null;
      this.childNodes = [];
      updateSiblings(this);
      this._innerHTML = val;
    }
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

  // ---- HTMLElement base class shim ----
  function HTMLElement() {
    ElementNode.call(this, 'div');
  }
  HTMLElement.prototype = Object.create(ElementNode.prototype);
  HTMLElement.prototype.constructor = HTMLElement;

  // ---- CustomEvent shim ----
  function CustomEvent(type, opts) {
    opts = opts || {};
    this.type = type;
    this.detail = opts.detail || null;
    this.bubbles = opts.bubbles || false;
    this.composed = opts.composed || false;
    this.cancelBubble = false;
    this.target = null;
    this.currentTarget = null;
  }

  if (typeof globalThis !== 'undefined') {
    globalThis.HTMLElement = HTMLElement;
    globalThis.CustomEvent = CustomEvent;
  } else if (typeof global !== 'undefined') {
    global.HTMLElement = HTMLElement;
    global.CustomEvent = CustomEvent;
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
    create: function(name, attrs) {
      var Cls = customElementsRegistry[name];
      if (!Cls) throw new Error('Custom element not registered: ' + name);
      var instance = new Cls();
      if (attrs) {
        var keys = Object.keys(attrs);
        for (var i = 0; i < keys.length; i++) {
          // Set directly on attributes without triggering callback yet
          instance.attributes[keys[i]] = attrs[keys[i]];
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
      if (customElementsRegistry[tag]) {
        return customElementsShim.create(tag);
      }
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

proc triggerAttributeChange(el: Element, name: cstring, value: cstring) =
  ## Simulates an external attribute change after connection.
  {.emit: [el, ".setAttribute(", name, ", ", value, ");"].}

proc triggerDisconnect(el: Element) =
  ## Simulates disconnection.
  {.emit: ["""
    if (""", el, """.disconnectedCallback) {
      """, el, """.disconnectedCallback();
    }
  """].}

proc triggerReconnect(el: Element) =
  ## Simulates reconnection by resetting _connected and calling connectedCallback.
  {.emit: ["""
    """, el, """._connected = false;
    if (""", el, """.connectedCallback) {
      """, el, """.connectedCallback();
    }
  """].}

# ---- Register test components ----

# A simple component that exposes its signal value via shadow DOM text,
# and dispatches a "value-changed" custom event on attribute change.
registerCustomElement(
  cstring"adv-reactive",
  [propDef(cstring"value", cstring"default")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    var current = createSignal(getProp(cstring"value"))

    let span = document.createElement("span")
    createRenderEffect proc() =
      span.textContent = current.val
    ctx.renderRoot.appendChild(span)

    # Wire up attribute change signal
    let setter = proc(v: cstring) =
      current.val = v
      # Dispatch custom event
      {.emit: ["""
        var ev = new CustomEvent('value-changed', {
          bubbles: true,
          detail: { value: """, v, """ }
        });
        """, ctx.element, """.dispatchEvent(ev);
      """].}
    {.emit: [ctx.element, "._propSignals['value'] = ", setter, ";"].}
)

# A component with a dispose callback that sets a flag
registerCustomElement(
  cstring"adv-lifecycle",
  [propDef(cstring"label", cstring"alive")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    let span = document.createElement("span")
    span.textContent = getProp(cstring"label")
    ctx.renderRoot.appendChild(span)

    # Set a dispose function
    {.emit: [ctx.element, """._disposeFn = function() {
      """, ctx.element, """._cleanedUp = true;
    };"""].}
)

# A light DOM component (no Shadow DOM)
registerCustomElement(
  cstring"adv-light",
  [propDef(cstring"msg", cstring"light-dom")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    var current = createSignal(getProp(cstring"msg"))
    let span = document.createElement("span")
    createRenderEffect proc() =
      span.textContent = current.val
    ctx.renderRoot.appendChild(span)

    let setter = proc(v: cstring) =
      current.val = v
    {.emit: [ctx.element, "._propSignals['msg'] = ", setter, ";"].}
  ,
  useShadow = false
)

# A component with multiple props for independent state testing
registerCustomElement(
  cstring"adv-multi",
  [propDef(cstring"a", cstring"1"), propDef(cstring"b", cstring"2")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    var sigA = createSignal(getProp(cstring"a"))
    var sigB = createSignal(getProp(cstring"b"))

    let span = document.createElement("span")
    createRenderEffect proc() =
      span.textContent = sigA.val & cstring"+" & sigB.val
    ctx.renderRoot.appendChild(span)

    let setA = proc(v: cstring) = sigA.val = v
    let setB = proc(v: cstring) = sigB.val = v
    {.emit: [ctx.element, "._propSignals['a'] = ", setA, ";"].}
    {.emit: [ctx.element, "._propSignals['b'] = ", setB, ";"].}
)

# ---- Tests ----

suite "Web Components Advanced - Attribute Reactivity":
  test "changing attribute after connection updates component":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-reactive", (cstring"value", cstring"initial"))
      check getShadowTextContent(el) == cstring"initial"

      # Change attribute externally
      triggerAttributeChange(el, cstring"value", cstring"updated")
      check getShadowTextContent(el) == cstring"updated"

      dispose()

  test "multiple attribute changes are all reflected":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-reactive")
      check getShadowTextContent(el) == cstring"default"

      triggerAttributeChange(el, cstring"value", cstring"first")
      check getShadowTextContent(el) == cstring"first"

      triggerAttributeChange(el, cstring"value", cstring"second")
      check getShadowTextContent(el) == cstring"second"

      triggerAttributeChange(el, cstring"value", cstring"third")
      check getShadowTextContent(el) == cstring"third"

      dispose()

  test "multi-prop component reacts to individual prop changes":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-multi",
        (cstring"a", cstring"X"), (cstring"b", cstring"Y"))
      check getShadowTextContent(el) == cstring"X+Y"

      triggerAttributeChange(el, cstring"a", cstring"Z")
      check getShadowTextContent(el) == cstring"Z+Y"

      triggerAttributeChange(el, cstring"b", cstring"W")
      check getShadowTextContent(el) == cstring"Z+W"

      dispose()

suite "Web Components Advanced - Custom Events":
  test "custom event is dispatched on attribute change":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-reactive", (cstring"value", cstring"start"))

      var receivedValue: cstring = cstring""
      let handler = proc(ev: Event) =
        {.emit: [receivedValue, " = ", ev, ".detail.value;"].}
      el.Node.addEventListener("value-changed", handler)

      triggerAttributeChange(el, cstring"value", cstring"changed")
      check receivedValue == cstring"changed"

      dispose()

  test "multiple event listeners receive the event":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-reactive")

      var count1 = 0
      var count2 = 0
      el.Node.addEventListener("value-changed", proc(ev: Event) =
        inc count1
      )
      el.Node.addEventListener("value-changed", proc(ev: Event) =
        inc count2
      )

      triggerAttributeChange(el, cstring"value", cstring"x")
      check count1 == 1
      check count2 == 1

      triggerAttributeChange(el, cstring"value", cstring"y")
      check count1 == 2
      check count2 == 2

      dispose()

  test "event detail contains correct payload":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-reactive")

      var detailValue: cstring = cstring""
      el.Node.addEventListener("value-changed", proc(ev: Event) =
        {.emit: [detailValue, " = ", ev, ".detail.value;"].}
      )

      triggerAttributeChange(el, cstring"value", cstring"payload-test")
      check detailValue == cstring"payload-test"

      dispose()

suite "Web Components Advanced - Multiple Instances":
  test "two instances of same component have independent state":
    createRoot proc(dispose: proc()) =
      let el1 = createCustomInstance(cstring"adv-reactive", (cstring"value", cstring"A"))
      let el2 = createCustomInstance(cstring"adv-reactive", (cstring"value", cstring"B"))

      check getShadowTextContent(el1) == cstring"A"
      check getShadowTextContent(el2) == cstring"B"

      # Changing one does not affect the other
      triggerAttributeChange(el1, cstring"value", cstring"A2")
      check getShadowTextContent(el1) == cstring"A2"
      check getShadowTextContent(el2) == cstring"B"

      triggerAttributeChange(el2, cstring"value", cstring"B2")
      check getShadowTextContent(el1) == cstring"A2"
      check getShadowTextContent(el2) == cstring"B2"

      dispose()

  test "events on one instance do not fire on another":
    createRoot proc(dispose: proc()) =
      let el1 = createCustomInstance(cstring"adv-reactive")
      let el2 = createCustomInstance(cstring"adv-reactive")

      var el1Events = 0
      var el2Events = 0
      el1.Node.addEventListener("value-changed", proc(ev: Event) = inc el1Events)
      el2.Node.addEventListener("value-changed", proc(ev: Event) = inc el2Events)

      triggerAttributeChange(el1, cstring"value", cstring"x")
      check el1Events == 1
      check el2Events == 0

      triggerAttributeChange(el2, cstring"value", cstring"y")
      check el1Events == 1
      check el2Events == 1

      dispose()

suite "Web Components Advanced - Lifecycle":
  test "disconnectedCallback calls dispose function":
    let el = createCustomInstance(cstring"adv-lifecycle")
    check getShadowTextContent(el) == cstring"alive"

    var cleanedUp: bool
    {.emit: [cleanedUp, " = !!(", el, "._cleanedUp);"].}
    check cleanedUp == false

    triggerDisconnect(el)

    {.emit: [cleanedUp, " = !!(", el, "._cleanedUp);"].}
    check cleanedUp == true

  test "disconnected element sets _disposed flag":
    let el = createCustomInstance(cstring"adv-lifecycle")

    var disposed: bool
    {.emit: [disposed, " = !!(", el, "._disposed);"].}
    check disposed == false

    triggerDisconnect(el)

    {.emit: [disposed, " = !!(", el, "._disposed);"].}
    check disposed == true

  test "reconnection re-renders the component":
    let el = createCustomInstance(cstring"adv-lifecycle", (cstring"label", cstring"first"))
    check getShadowTextContent(el) == cstring"first"

    # Disconnect
    triggerDisconnect(el)

    # Reconnect — connectedCallback should re-run
    triggerReconnect(el)

    # After reconnection, shadow root is re-created
    check getShadowTextContent(el) == cstring"first"

suite "Web Components Advanced - Light DOM":
  test "light DOM component renders into element itself":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-light")
      # No shadow root
      let sr = getShadowRoot(el)
      check sr.isNodeNil
      # Content is directly in the element
      check el.textContent == cstring"light-dom"
      dispose()

  test "light DOM component reacts to attribute changes":
    createRoot proc(dispose: proc()) =
      let el = createCustomInstance(cstring"adv-light", (cstring"msg", cstring"hello"))
      check el.textContent == cstring"hello"

      triggerAttributeChange(el, cstring"msg", cstring"world")
      check el.textContent == cstring"world"

      dispose()
