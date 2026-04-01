## End-to-end headless tests for the IsoNim demo app (M26).
##
## Runs the full demo app under a Node.js DOM shim.
## Tests user interaction flows: add, toggle, filter, remove tasks.
## Exercises the real web renderer + reactive system + task store.

when not defined(js):
  {.error: "test_app_e2e must be compiled with the JS backend: nim js -r tests/test_app_e2e.nim".}

# Inject DOM shim (same as test_web.nim)
{.emit: """
// ---- Minimal DOM shim for Node.js (E2E) ----
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
      // Clear children
      for (var i = 0; i < this.childNodes.length; i++) {
        this.childNodes[i].parentNode = null;
      }
      this.childNodes = [];
      if (val !== '' && val != null) {
        var parsed = parseHTML(val);
        var kids = parsed.childNodes.slice();
        for (var j = 0; j < kids.length; j++) {
          this.appendChild(kids[j]);
        }
      }
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
          if (stack.length > 1) stack.pop();
        } else {
          var selfClosing = tagContent[tagContent.length - 1] === '/';
          if (selfClosing) tagContent = tagContent.substring(0, tagContent.length - 1).trim();
          var spaceIdx = tagContent.indexOf(' ');
          var tag = spaceIdx > 0 ? tagContent.substring(0, spaceIdx) : tagContent;
          tag = tag.trim();
          if (tag.length > 0) {
            var el = new ElementNode(tag);
            // Parse attributes
            if (spaceIdx > 0) {
              var attrStr = tagContent.substring(spaceIdx + 1).trim();
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
import std/[jsffi, strutils]
import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/rxcore
import isonim/core/[signals, computation]
import task_store

# ---- Helpers ----

proc fireEvent(el: Node, eventType: cstring) =
  ## Dispatch an event directly on an element (non-delegated).
  {.emit: ["var evt = { type: ", eventType, ", target: ", el, ", cancelBubble: false, preventDefault: function(){} }; ", el, ".dispatchEvent(evt);"].}

proc fireDelegatedEvent(el: Node, eventType: cstring) =
  ## Dispatch an event through the document delegation system.
  {.emit: ["var evt = { type: ", eventType, ", target: ", el, ", currentTarget: document, cancelBubble: false, preventDefault: function(){} }; document._dispatchOnDelegate(evt);"].}

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

proc getClassName(el: Node): cstring =
  {.emit: [result, " = ", el, ".className || '';"].}

# ---- Build app (mirrors demos/isonim-replica/src/main.nim) ----

proc createDemoApp(store: TaskStore): Node =
  ## Builds the complete app DOM tree with reactive bindings.
  ## This mirrors the real demo app's main.nim but is testable.
  delegateEvents(["click", "input", "change", "submit"])

  let appDiv = document.createElement("div")
  appDiv.className = "app"

  # Header
  let header = document.createElement("header")
  appDiv.appendChild(header)
  let h1 = document.createElement("h1")
  h1.textContent = "Task Manager"
  header.appendChild(h1)
  let form = document.createElement("form")
  header.appendChild(form)
  let inputField = document.createElement("input")
  inputField.setAttribute("type", "text")
  inputField.setAttribute("placeholder", "What needs to be done?")
  form.appendChild(inputField)
  let addBtn = document.createElement("button")
  addBtn.setAttribute("type", "submit")
  addBtn.textContent = "Add"
  form.appendChild(addBtn)

  form.Node.addEventListener("submit", proc(ev: Event) =
    {.emit: [ev, ".preventDefault();"].}
    var inputVal: cstring
    {.emit: [inputVal, " = ", inputField, ".value;"].}
    store.addTask($inputVal)
    {.emit: [inputField, ".value = '';"].}
  )

  # Task list section
  let section = document.createElement("section")
  appDiv.appendChild(section)
  let emptyMsg = document.createElement("p")
  emptyMsg.className = "empty"
  emptyMsg.textContent = "No tasks"

  createRenderEffect proc() =
    let tasks = store.filteredTasks.val
    section.innerHTML = ""
    if tasks.len == 0:
      section.appendChild(emptyMsg.Node.cloneNode(true))
    else:
      let ul = document.createElement("ul")
      ul.className = "task-list"
      for t in tasks:
        let task = t
        let li = document.createElement("li")
        if task.done:
          li.className = "completed"
        let checkbox = document.createElement("input")
        checkbox.setAttribute("type", "checkbox")
        if task.done:
          checkbox.setAttribute("checked", "")
        checkbox.Node.addEventListener("change", proc(ev: Event) =
          store.toggleTask(task.id)
        )
        li.appendChild(checkbox)
        let span = document.createElement("span")
        span.textContent = cstring(task.text)
        li.appendChild(span)
        let removeBtn = document.createElement("button")
        removeBtn.className = "remove"
        removeBtn.textContent = cstring("x")
        removeBtn.Node.addEventListener("click", proc(ev: Event) =
          store.removeTask(task.id)
        )
        li.appendChild(removeBtn)
        ul.appendChild(li)
      section.appendChild(ul)

  # Footer
  let footerContainer = document.createElement("div")
  appDiv.appendChild(footerContainer)

  createRenderEffect proc() =
    footerContainer.innerHTML = ""
    if store.tasks.val.len > 0:
      let footer = document.createElement("footer")
      footer.className = "task-footer"
      let countSpan = document.createElement("span")
      let ac = store.activeCount.val
      let suffix = if ac != 1: "s" else: ""
      countSpan.textContent = cstring($ac & " item" & suffix & " left")
      footer.appendChild(countSpan)
      let filtersDiv = document.createElement("div")
      filtersDiv.className = "filters"
      for f in [fAll, fActive, fCompleted]:
        let filterVal = f
        let btn = document.createElement("button")
        btn.textContent = cstring($filterVal)
        if store.filter.val == filterVal:
          btn.className = "selected"
        btn.Node.addEventListener("click", proc(ev: Event) =
          store.setFilter(filterVal)
        )
        filtersDiv.appendChild(btn)
      footer.appendChild(filtersDiv)
      if store.completedCount.val > 0:
        let clearBtn = document.createElement("button")
        clearBtn.textContent = "Clear completed"
        clearBtn.Node.addEventListener("click", proc(ev: Event) =
          store.clearCompleted()
        )
        footer.appendChild(clearBtn)
      footerContainer.appendChild(footer)

  return appDiv.Node

# ---- Test suites ----

suite "App E2E - Headless":
  setup:
    resetIdCounter()
    clearDelegatedEvents()

  test "app renders initial empty state":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      # Header present
      let h1 = app.querySelector(cstring"h1")
      check h1.textContent == cstring"Task Manager"

      # Empty message shown
      let section = app.getChildAt(1)  # second child = section
      check section.textContent == cstring"No tasks"

      # No footer (no tasks)
      let footerContainer = app.getChildAt(2)
      check footerContainer.getChildCount() == 0

      dispose()

  test "app adds and displays tasks":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      store.addTask("Buy groceries")
      store.addTask("Write tests")

      # Task list should have 2 items
      let lis = app.querySelectorAll(cstring"li")
      check lis.len == 2

      # First task text
      let span0 = lis[0].querySelectorAll(cstring"span")
      check span0.len == 1
      check span0[0].textContent == cstring"Buy groceries"

      # Second task text
      let span1 = lis[1].querySelectorAll(cstring"span")
      check span1.len == 1
      check span1[0].textContent == cstring"Write tests"

      # Footer shows count
      let footer = app.querySelector(cstring"footer")
      check not footer.isNodeNil
      check ($footer.textContent).contains("2 items left")

      dispose()

  test "app toggles task completion":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      store.addTask("Task A")
      let taskId = store.tasks.val[0].id

      # Initially not completed
      var lis = app.querySelectorAll(cstring"li")
      check lis.len == 1
      check lis[0].getClassName() != cstring"completed"

      # Toggle task
      store.toggleTask(taskId)

      # After toggle, li should have "completed" class
      lis = app.querySelectorAll(cstring"li")
      check lis.len == 1
      check lis[0].getClassName() == cstring"completed"

      # Footer shows 0 items left
      let footer = app.querySelector(cstring"footer")
      check ($footer.textContent).contains("0 items left")

      dispose()

  test "app removes task":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      store.addTask("Task A")
      store.addTask("Task B")
      let idA = store.tasks.val[0].id

      check app.querySelectorAll(cstring"li").len == 2

      store.removeTask(idA)

      let lis = app.querySelectorAll(cstring"li")
      check lis.len == 1
      let span = lis[0].querySelectorAll(cstring"span")
      check span[0].textContent == cstring"Task B"

      dispose()

  test "app filters by active":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      store.addTask("Active task")
      store.addTask("Done task")
      store.toggleTask(store.tasks.val[1].id)

      # All filter: 2 tasks
      check app.querySelectorAll(cstring"li").len == 2

      # Switch to active filter
      store.setFilter(fActive)
      let lis = app.querySelectorAll(cstring"li")
      check lis.len == 1
      let span = lis[0].querySelectorAll(cstring"span")
      check span[0].textContent == cstring"Active task"

      # Switch to completed filter
      store.setFilter(fCompleted)
      let lisComp = app.querySelectorAll(cstring"li")
      check lisComp.len == 1
      let spanComp = lisComp[0].querySelectorAll(cstring"span")
      check spanComp[0].textContent == cstring"Done task"

      dispose()

  test "app clears completed tasks":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      store.addTask("Keep")
      store.addTask("Remove")
      store.addTask("Also remove")
      store.toggleTask(store.tasks.val[1].id)
      store.toggleTask(store.tasks.val[2].id)

      check app.querySelectorAll(cstring"li").len == 3

      store.clearCompleted()

      let lis = app.querySelectorAll(cstring"li")
      check lis.len == 1
      let span = lis[0].querySelectorAll(cstring"span")
      check span[0].textContent == cstring"Keep"

      dispose()

  test "app form submit adds task via event":
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      # Find the input and set its value
      let form = app.querySelector(cstring"form")
      let input = app.querySelectorAll(cstring"input")[0]
      {.emit: [input, ".value = 'From form';"].}

      # Fire submit event on the form
      form.fireEvent(cstring"submit")

      # Task should be added
      check store.tasks.val.len == 1
      check store.tasks.val[0].text == "From form"

      # Input should be cleared
      var inputVal: cstring
      {.emit: [inputVal, " = ", input, ".value;"].}
      check inputVal == cstring""

      dispose()

  test "app full user flow":
    ## Simulates a complete user session: add tasks, toggle, filter, clear.
    createRoot proc(dispose: proc()) =
      let store = createTaskStore()
      let app = createDemoApp(store)

      # 1. Add 3 tasks
      store.addTask("Learn Nim")
      store.addTask("Build IsoNim app")
      store.addTask("Deploy to production")
      check app.querySelectorAll(cstring"li").len == 3

      # 2. Complete first task
      store.toggleTask(store.tasks.val[0].id)
      var completedLis = app.querySelectorAll(cstring".completed")
      check completedLis.len == 1

      # 3. Filter to active only
      store.setFilter(fActive)
      check app.querySelectorAll(cstring"li").len == 2

      # 4. Filter to completed only
      store.setFilter(fCompleted)
      check app.querySelectorAll(cstring"li").len == 1

      # 5. Back to all
      store.setFilter(fAll)
      check app.querySelectorAll(cstring"li").len == 3

      # 6. Clear completed
      store.clearCompleted()
      check app.querySelectorAll(cstring"li").len == 2
      check store.tasks.val.len == 2

      # 7. Verify remaining tasks
      let lis = app.querySelectorAll(cstring"li")
      let s0 = lis[0].querySelectorAll(cstring"span")
      let s1 = lis[1].querySelectorAll(cstring"span")
      check s0[0].textContent == cstring"Build IsoNim app"
      check s1[0].textContent == cstring"Deploy to production"

      dispose()
