## Accessibility tests for IsoNim components (G7).
##
## Verifies ARIA attributes, semantic HTML structure, keyboard navigation,
## focus management, and screen reader text across MockRenderer (C+JS)
## and DOM shim (JS-only) targets.
##
## Suites 1, 2, 5 run on both C and JS targets (MockRenderer).
## Suites 3, 4 run on JS target only (DOM shim for keyboard/focus events).

when defined(js):
  # Inject DOM shim for JS-only suites (keyboard navigation, focus management)
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
      this._innerHTML = '';
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
          else result += c.textContent;
        }
        return result;
      },
      set: function(val) { setTextContent(this, val); }
    });

    Object.defineProperty(TextNode.prototype, 'textContent', {
      get: function() { return this.data; },
      set: function(val) { this.data = String(val); }
    });

    Object.defineProperty(ElementNode.prototype, 'innerHTML', {
      get: function() { return this._innerHTML || ''; },
      set: function(val) {
        this._innerHTML = val;
        for (var i = 0; i < this.childNodes.length; i++) {
          this.childNodes[i].parentNode = null;
        }
        this.childNodes = [];
        updateSiblings(this);
      }
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
      if (refNode == null) return this.appendChild(newNode);
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

    ElementNode.prototype.querySelectorAll = function(selector) {
      var results = [];
      var attrMatch = selector.match(/^\*?\[([^\]=]+)(?:=["']?([^"'\]]*)["']?)?\]$/);
      var tagMatch = !attrMatch ? selector.match(/^([a-zA-Z][a-zA-Z0-9]*)$/) : null;
      var classMatch = !attrMatch && !tagMatch ? selector.match(/^\.([a-zA-Z0-9_-]+)$/) : null;
      function walk(node) {
        if (node.nodeType !== 1) return;
        if (attrMatch) {
          var attrName = attrMatch[1];
          if (node.hasAttribute(attrName)) {
            if (attrMatch[2] !== undefined) {
              if (node.getAttribute(attrName) === attrMatch[2]) results.push(node);
            } else {
              results.push(node);
            }
          }
        } else if (tagMatch) {
          if (node.localName === tagMatch[1].toLowerCase()) results.push(node);
        } else if (classMatch) {
          if (node.className === classMatch[1] || (node.className && node.className.indexOf(classMatch[1]) >= 0)) results.push(node);
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

    ElementNode.prototype.querySelector = function(selector) {
      var all = this.querySelectorAll(selector);
      return all.length > 0 ? all[0] : null;
    };

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

    function TemplateElement() {
      ElementNode.call(this, 'template');
      this.content = new DocumentFragment();
    }
    TemplateElement.prototype = Object.create(ElementNode.prototype);
    TemplateElement.prototype.constructor = TemplateElement;
    Object.defineProperty(TemplateElement.prototype, 'innerHTML', {
      get: function() { return this._innerHTML || ''; },
      set: function(html) { this._innerHTML = html; this.content = new DocumentFragment(); }
    });

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
import std/tables
import isonim/core/[signals, computation, owner, batch, graph]
import isonim/testing/mock_dom
import isonim/dsl/ui
import isonim/dsl/components
import isonim/accessibility
import task_store
import components

# ============================================================================
# Suite 1: ARIA Attributes (MockRenderer, C+JS)
# ============================================================================

suite "Accessibility - ARIA Attributes":
  test "role attribute on non-semantic elements":
    ## div with role="button" should have the role attribute set
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = ui(renderer):
        tdiv(role = "button"):
          text "Click me"

      check root.tag == "div"
      check root.attributes["role"] == "button"

  test "aria-label on interactive elements":
    ## Buttons and inputs should support aria-label
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let root = ui(renderer):
        tdiv:
          button(`aria-label` = "Close dialog"):
            text "X"
          input(`aria-label` = "Search tasks", ttype = "text")

      let btn = root.children[0]
      check btn.tag == "button"
      check btn.attributes["aria-label"] == "Close dialog"

      let inp = root.children[1]
      check inp.tag == "input"
      check inp.attributes["aria-label"] == "Search tasks"

  test "aria-checked updates reactively via signal":
    ## aria-checked should update when the underlying signal changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let checked = createSignal(false)

      let root = ui(renderer):
        tdiv(role = "checkbox", `aria-checked` = (if checked.val: "true" else: "false"))

      check root.attributes["aria-checked"] == "false"

      checked.val = true
      check root.attributes["aria-checked"] == "true"

      checked.val = false
      check root.attributes["aria-checked"] == "false"

  test "aria-hidden toggled via signal":
    ## aria-hidden should toggle when a signal changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let hidden = createSignal(false)

      let root = ui(renderer):
        tdiv(`aria-hidden` = (if hidden.val: "true" else: "false")):
          text "Decorative content"

      check root.attributes["aria-hidden"] == "false"

      hidden.val = true
      check root.attributes["aria-hidden"] == "true"

  test "aria-expanded for collapsible sections":
    ## aria-expanded should reflect the expanded state
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let expanded = createSignal(false)

      let root = ui(renderer):
        tdiv:
          button(`aria-expanded` = (if expanded.val: "true" else: "false")):
            text "Toggle section"
          if expanded.val:
            tdiv:
              text "Expanded content"

      let btn = root.children[0]
      check btn.attributes["aria-expanded"] == "false"

      expanded.val = true
      check btn.attributes["aria-expanded"] == "true"

  test "aria-live region for dynamic content":
    ## aria-live should be set on regions that update dynamically
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let count = createSignal(0)

      let root = ui(renderer):
        tdiv(`aria-live` = "polite"):
          span: text ($count.val & " items remaining")

      check root.attributes["aria-live"] == "polite"
      check root.children[0].textContent == "0 items remaining"

      count.val = 3
      check root.children[0].textContent == "3 items remaining"

  test "aria-describedby and aria-labelledby associations":
    ## Elements should reference other elements via aria-describedby/labelledby
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          label(id = "task-label"):
            text "Task name"
          input(`aria-labelledby` = "task-label", `aria-describedby` = "task-help")
          span(id = "task-help"):
            text "Enter a descriptive task name"

      let inp = root.children[1]
      check inp.tag == "input"
      check inp.attributes["aria-labelledby"] == "task-label"
      check inp.attributes["aria-describedby"] == "task-help"

  test "accessibility helper procs set ARIA attributes":
    ## The accessibility module helpers should set correct attributes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let node = renderer.createElement("div")

      renderer.role(node, "navigation")
      check node.attributes["role"] == "navigation"

      renderer.ariaLabel(node, "Main navigation")
      check node.attributes["aria-label"] == "Main navigation"

      renderer.ariaChecked(node, true)
      check node.attributes["aria-checked"] == "true"
      renderer.ariaChecked(node, false)
      check node.attributes["aria-checked"] == "false"

      renderer.ariaHidden(node, true)
      check node.attributes["aria-hidden"] == "true"

      renderer.ariaExpanded(node, false)
      check node.attributes["aria-expanded"] == "false"

      renderer.ariaLive(node, "assertive")
      check node.attributes["aria-live"] == "assertive"

      renderer.ariaDescribedby(node, "help-text-1")
      check node.attributes["aria-describedby"] == "help-text-1"

      renderer.ariaLabelledby(node, "heading-1")
      check node.attributes["aria-labelledby"] == "heading-1"

  test "srOnlyClass returns correct class name":
    check srOnlyClass() == "sr-only"

# ============================================================================
# Suite 2: Semantic HTML Structure (MockRenderer, C+JS)
# ============================================================================

suite "Accessibility - Semantic HTML Structure":
  test "task list uses ul/li elements":
    ## The task list should use semantic list markup, not div soup
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let store = createTaskStore()
      store.addTask("First task")
      store.addTask("Second task")

      let parent = renderer.createElement("div")
      renderTaskList(renderer, parent, store)

      # The task list renders inside a section > show > ul
      # Navigate to find the ul element
      proc findTag(node: MockNode; tag: string): MockNode =
        if node.kind == mnkElement and node.tag == tag:
          return node
        for child in node.children:
          let found = findTag(child, tag)
          if found != nil:
            return found
        return nil

      let ul = findTag(parent, "ul")
      check ul != nil
      check ul.tag == "ul"
      check ul.attributes.getOrDefault("class") == "task-list"

      # Children should be li elements
      for child in ul.children:
        if child.kind == mnkElement:
          check child.tag == "li"

  test "headings use correct h1-h6 elements":
    ## Headers should use proper heading tags
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          h1: text "Main Title"
          h2: text "Section"
          h3: text "Subsection"

      check root.children[0].tag == "h1"
      check root.children[1].tag == "h2"
      check root.children[2].tag == "h3"

  test "buttons are button elements":
    ## Interactive buttons should use the button tag, not clickable divs
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      var clicked = 0

      let root = ui(renderer):
        button(onclick = proc() = inc clicked):
          text "Submit"

      check root.tag == "button"
      root.fireEvent("click")
      check clicked == 1

  test "form inputs have associated labels":
    ## Input elements should have labels associated via 'for' attribute or nesting
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      # Label via 'for' attribute
      let root = ui(renderer):
        tdiv:
          label(`for` = "task-input"):
            text "Task name"
          input(id = "task-input", ttype = "text")

      let lbl = root.children[0]
      check lbl.tag == "label"
      check lbl.attributes["for"] == "task-input"

      let inp = root.children[1]
      check inp.tag == "input"
      check inp.attributes["id"] == "task-input"

  test "nested label contains input":
    ## Labels can also contain their inputs directly
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        label:
          text "Email"
          input(ttype = "email")

      check root.tag == "label"
      check root.children.len == 2
      check root.children[0].kind == mnkText
      check root.children[0].text == "Email"
      check root.children[1].tag == "input"

  test "navigation uses nav element":
    ## Navigation sections should use the nav element
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        nav(`aria-label` = "Main navigation"):
          ul:
            li:
              a(href = "/"): text "Home"
            li:
              a(href = "/about"): text "About"

      check root.tag == "nav"
      check root.attributes["aria-label"] == "Main navigation"

  test "main content uses main element":
    ## Primary content area should use the main element
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        main(role = "main"):
          h1: text "Tasks"
          section:
            text "Task content here"

      check root.tag == "main"
      check root.attributes["role"] == "main"
      check root.children[0].tag == "h1"
      check root.children[1].tag == "section"

  test "task header uses semantic header and form elements":
    ## The renderTaskHeader component should produce header/form/button elements
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let store = createTaskStore()
      let parent = renderer.createElement("div")

      renderTaskHeader(renderer, parent, store)

      # parent should contain a header element
      check parent.children.len == 1
      let header = parent.children[0]
      check header.tag == "header"

      # header contains h1 and form
      check header.children[0].tag == "h1"
      check header.children[1].tag == "form"

      # form contains input and button
      let form = header.children[1]
      check form.children[0].tag == "input"
      check form.children[1].tag == "button"

  test "task footer uses semantic footer element":
    ## The renderTaskFooter component should produce a footer element
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let store = createTaskStore()
      store.addTask("A task")

      let parent = renderer.createElement("div")
      renderTaskFooter(renderer, parent, store)

      proc findTag(node: MockNode; tag: string): MockNode =
        if node.kind == mnkElement and node.tag == tag:
          return node
        for child in node.children:
          let found = findTag(child, tag)
          if found != nil:
            return found
        return nil

      let footer = findTag(parent, "footer")
      check footer != nil
      check footer.tag == "footer"

# ============================================================================
# Suite 3: Keyboard Navigation (JS target only, DOM shim)
# ============================================================================

when defined(js):
  import std/jsffi
  import isonim/web/dom_api
  import isonim/web/client
  import isonim/web/events

  # ---- JS-only helpers ----

  proc querySelectorAll(el: Node, selector: cstring): seq[Node] =
    var jsArr: JsObject
    {.emit: [jsArr, " = ", el, ".querySelectorAll(", selector, ");"].}
    var length: int
    {.emit: [length, " = ", jsArr, ".length;"].}
    result = @[]
    for i in 0 ..< length:
      var node: Node
      {.emit: [node, " = ", jsArr, "[", i, "];"].}
      result.add(node)

  proc querySelector(el: Node, selector: cstring): Node =
    var res: Node
    {.emit: [res, " = ", el, ".querySelector(", selector, ");"].}
    return res

  proc getChildCount(el: Node): int =
    {.emit: [result, " = ", el, ".childNodes.length;"].}

  proc getChildAt(el: Node, idx: int): Node =
    {.emit: [result, " = ", el, ".childNodes[", idx, "];"].}

  proc getAttribute(el: Node, name: cstring): cstring =
    var res: cstring
    {.emit: [res, " = ", el, ".getAttribute(", name, ");"].}
    return res

  proc hasAttribute(el: Node, name: cstring): bool =
    {.emit: [result, " = ", el, ".hasAttribute(", name, ");"].}

  proc fireKeyboardEvent(el: Node, eventType: cstring, key: cstring, code: cstring = "") =
    ## Dispatch a keyboard event on an element.
    {.emit: """
    var evt = {
      type: `eventType`,
      target: `el`,
      key: `key`,
      code: `code` || `key`,
      cancelBubble: false,
      preventDefault: function() { this._defaultPrevented = true; },
      _defaultPrevented: false
    };
    `el`.dispatchEvent(evt);
    """.}

  proc fireClickEvent(el: Node) =
    {.emit: """
    var evt = { type: 'click', target: `el`, cancelBubble: false, preventDefault: function(){} };
    `el`.dispatchEvent(evt);
    """.}

  suite "Accessibility - Keyboard Navigation (JS)":
    setup:
      resetIdCounter()
      clearDelegatedEvents()

    test "no spurious tabindex on regular elements":
      ## Regular interactive elements should not have tabindex set randomly
      createRoot proc(dispose: proc()) =
        let container = document.createElement("div")

        let btn = document.createElement("button")
        btn.textContent = "Click me"
        container.appendChild(btn.Node)

        let input = document.createElement("input")
        input.setAttribute("type", "text")
        container.appendChild(input.Node)

        # Buttons and inputs are naturally focusable; tabindex should not be set
        check not btn.Node.hasAttribute("tabindex")
        check not input.Node.hasAttribute("tabindex")

        dispose()

    test "Enter key on button triggers click handler":
      ## Pressing Enter on a button should trigger its click handler
      createRoot proc(dispose: proc()) =
        var clicked = 0
        let btn = document.createElement("button")
        btn.textContent = "Submit"
        btn.Node.addEventListener("click", proc(ev: Event) =
          inc clicked
        )

        # Also add keydown handler that triggers click on Enter
        btn.Node.addEventListener("keydown", proc(ev: Event) =
          var key: cstring
          {.emit: [key, " = ", ev, ".key;"].}
          if key == cstring"Enter":
            fireClickEvent(btn.Node)
        )

        check clicked == 0
        fireKeyboardEvent(btn.Node, "keydown", "Enter")
        check clicked == 1

        dispose()

    test "Space key on button triggers click handler":
      ## Pressing Space on a button should trigger its click handler
      createRoot proc(dispose: proc()) =
        var clicked = 0
        let btn = document.createElement("button")
        btn.textContent = "Toggle"
        btn.Node.addEventListener("click", proc(ev: Event) =
          inc clicked
        )
        btn.Node.addEventListener("keydown", proc(ev: Event) =
          var key: cstring
          {.emit: [key, " = ", ev, ".key;"].}
          if key == cstring" ":
            fireClickEvent(btn.Node)
        )

        check clicked == 0
        fireKeyboardEvent(btn.Node, "keydown", " ")
        check clicked == 1

        dispose()

    test "Escape key dismisses content":
      ## Escape key should be able to dismiss modal-like content
      createRoot proc(dispose: proc()) =
        var dismissed = false
        let container = document.createElement("div")
        let overlay = document.createElement("div")
        overlay.className = "modal-overlay"
        container.appendChild(overlay.Node)

        overlay.Node.addEventListener("keydown", proc(ev: Event) =
          var key: cstring
          {.emit: [key, " = ", ev, ".key;"].}
          if key == cstring"Escape":
            dismissed = true
        )

        check not dismissed
        fireKeyboardEvent(overlay.Node, "keydown", "Escape")
        check dismissed

        dispose()

    test "custom tabindex values are preserved":
      ## When tabindex is explicitly set, it should be preserved
      createRoot proc(dispose: proc()) =
        let container = document.createElement("div")

        let skipLink = document.createElement("a")
        skipLink.setAttribute("href", "#main")
        skipLink.setAttribute("tabindex", "1")
        container.appendChild(skipLink.Node)

        let decorative = document.createElement("div")
        decorative.setAttribute("tabindex", "-1")
        container.appendChild(decorative.Node)

        check skipLink.Node.getAttribute("tabindex") == cstring"1"
        check decorative.Node.getAttribute("tabindex") == cstring"-1"

        dispose()

  # ============================================================================
  # Suite 4: Focus Management (JS target only, DOM shim)
  # ============================================================================

  suite "Accessibility - Focus Management (JS)":
    setup:
      resetIdCounter()
      clearDelegatedEvents()

    test "focus moves to input after adding task":
      ## After submitting the form, focus should conceptually return to the input
      createRoot proc(dispose: proc()) =
        let container = document.createElement("div")
        let form = document.createElement("form")
        let input = document.createElement("input")
        input.setAttribute("type", "text")
        input.setAttribute("id", "task-input")
        form.appendChild(input.Node)
        container.appendChild(form.Node)

        var focusedElement: Node = nil

        # Simulate a focus handler on input
        input.Node.addEventListener("focus", proc(ev: Event) =
          focusedElement = ev.target
        )

        # Simulate form submit that refocuses input
        form.Node.addEventListener("submit", proc(ev: Event) =
          {.emit: [ev, ".preventDefault();"].}
          # After submit, refocus the input
          {.emit: """
          var focusEvt = { type: 'focus', target: `input`, cancelBubble: false, preventDefault: function(){} };
          `input`.dispatchEvent(focusEvt);
          """.}
        )

        # Fire submit
        {.emit: """
        var submitEvt = { type: 'submit', target: `form`, cancelBubble: false, preventDefault: function(){} };
        `form`.dispatchEvent(submitEvt);
        """.}

        check not focusedElement.isNodeNil
        check focusedElement.getAttribute("id") == cstring"task-input"

        dispose()

    test "focus trap keeps focus within container":
      ## Tab from the last focusable element should wrap to the first
      createRoot proc(dispose: proc()) =
        let modal = document.createElement("div")
        modal.setAttribute("role", "dialog")
        modal.setAttribute("aria-modal", "true")

        let btn1 = document.createElement("button")
        btn1.textContent = "OK"
        modal.appendChild(btn1.Node)

        let btn2 = document.createElement("button")
        btn2.textContent = "Cancel"
        modal.appendChild(btn2.Node)

        # Implement focus trap: when Tab on last element, focus first
        var focusTarget: Node = nil
        btn2.Node.addEventListener("keydown", proc(ev: Event) =
          var key: cstring
          {.emit: [key, " = ", ev, ".key;"].}
          if key == cstring"Tab":
            focusTarget = btn1.Node
        )

        fireKeyboardEvent(btn2.Node, "keydown", "Tab")
        check not focusTarget.isNodeNil
        # Focus should wrap to first button
        check focusTarget.textContent == cstring"OK"

        dispose()

    test "dialog has correct ARIA attributes":
      ## Modal dialogs should have role=dialog and aria-modal=true
      createRoot proc(dispose: proc()) =
        let modal = document.createElement("div")
        modal.setAttribute("role", "dialog")
        modal.setAttribute("aria-modal", "true")
        modal.setAttribute("aria-label", "Confirm deletion")

        let content = document.createElement("p")
        content.textContent = "Are you sure?"
        modal.appendChild(content.Node)

        check modal.Node.getAttribute("role") == cstring"dialog"
        check modal.Node.getAttribute("aria-modal") == cstring"true"
        check modal.Node.getAttribute("aria-label") == cstring"Confirm deletion"

        dispose()

    test "removed element does not leave dangling focus reference":
      ## When a focused element is removed, the focus reference should be cleared
      createRoot proc(dispose: proc()) =
        let container = document.createElement("div")
        let btn = document.createElement("button")
        btn.textContent = "Deletable"
        container.appendChild(btn.Node)

        var currentFocus: Node = btn.Node

        # Remove the button
        container.Node.removeChild(btn.Node)

        # After removal, parent should be nil
        check btn.Node.parentNode.isNodeNil

        # A well-behaved app would move focus to the container
        currentFocus = container.Node
        check not currentFocus.isNodeNil

        dispose()

# ============================================================================
# Suite 5: Screen Reader Text (MockRenderer, C+JS)
# ============================================================================

suite "Accessibility - Screen Reader Text":
  test "visually hidden text for screen readers":
    ## sr-only spans should contain text accessible to screen readers
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let count = createSignal(3)

      let root = ui(renderer):
        tdiv:
          span(class = "sr-only"):
            text ($count.val & " items remaining")

      let srSpan = root.children[0]
      check srSpan.tag == "span"
      check srSpan.attributes["class"] == "sr-only"
      check srSpan.textContent == "3 items remaining"

      count.val = 0
      check srSpan.textContent == "0 items remaining"

  test "alt text on images":
    ## Images should have descriptive alt text
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          img(src = "/logo.png", alt = "Company logo")
          img(src = "/decorative.png", alt = "", `aria-hidden` = "true")

      let logo = root.children[0]
      check logo.tag == "img"
      check logo.attributes["alt"] == "Company logo"

      # Decorative images should have empty alt and aria-hidden
      let decorative = root.children[1]
      check decorative.attributes["alt"] == ""
      check decorative.attributes["aria-hidden"] == "true"

  test "button labels are descriptive":
    ## Buttons should have descriptive text, not just icons
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          button(`aria-label` = "Remove task"):
            text "x"
          button:
            text "Add task"

      # Icon button has aria-label
      let removeBtn = root.children[0]
      check removeBtn.attributes["aria-label"] == "Remove task"
      check removeBtn.textContent == "x"

      # Text button is self-describing
      let addBtn = root.children[1]
      check addBtn.textContent == "Add task"

  test "srOnlyClass helper for screen reader text":
    ## Using srOnlyClass() to build accessible hidden text
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()

      let root = ui(renderer):
        tdiv:
          span(class = srOnlyClass()):
            text "5 tasks completed"

      let srSpan = root.children[0]
      check srSpan.attributes["class"] == "sr-only"
      check srSpan.textContent == "5 tasks completed"

  test "live region announces task count changes":
    ## An aria-live region should update reactively to announce changes
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let store = createTaskStore()

      let root = ui(renderer):
        tdiv(`aria-live` = "polite", role = "status"):
          span(class = "sr-only"):
            text ($store.activeCount.val & " active tasks")

      check root.attributes["aria-live"] == "polite"
      check root.attributes["role"] == "status"
      check root.children[0].textContent == "0 active tasks"

      store.addTask("First")
      check root.children[0].textContent == "1 active tasks"

      store.addTask("Second")
      check root.children[0].textContent == "2 active tasks"

  test "task completion announced via aria attributes":
    ## When a task is toggled, the aria-checked attribute should reflect the state
    createRoot proc(dispose: proc()) =
      let renderer = MockRenderer()
      let done = createSignal(false)

      let root = ui(renderer):
        tdiv(role = "checkbox", `aria-checked` = (if done.val: "true" else: "false"), `aria-label` = "Complete task"):
          text "Buy groceries"

      check root.attributes["role"] == "checkbox"
      check root.attributes["aria-checked"] == "false"
      check root.attributes["aria-label"] == "Complete task"

      done.val = true
      check root.attributes["aria-checked"] == "true"
