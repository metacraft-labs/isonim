## isonim/web/client.nim
##
## Client-side rendering primitives: tmpl, insert, spread, assign.
## The DOM-specific rendering backend for browser environments.
##
## Port of dom-expressions client.js rendering logic.

when not defined(js):
  {.error: "isonim/web/client requires the JS backend".}

import isonim/web/dom_api
import isonim/rxcore

# Mutable cell for closure capture
type
  Cell[T] = ref object
    val: T

proc cell[T](v: T): Cell[T] = Cell[T](val: v)

# Forward declaration
proc insertExpression*(parent: Node, value: JsRoot, current: JsRoot,
    marker: Node = nil): JsRoot

# ---- tmpl ----

proc tmpl*(html: cstring): proc(): Node =
  ## Creates a template element, sets innerHTML, returns a factory
  ## that clones the parsed DOM tree each time it's called.
  var node: Node = nil
  let create = proc(): Node =
    let t = document.createElement("template")
    t.innerHTML = html
    return HTMLTemplateElement(t).content.firstChild
  result = proc(): Node =
    if node.isNodeNil:
      node = create()
    return node.cloneNode(true)

# ---- render ----

proc render*(code: proc(): Node, element: Element): proc() =
  ## Creates a reactive root and inserts the component tree into the target element.
  ## Returns a dispose function that cleans up the reactive tree and clears the element.
  ##
  ## The root component is routed through `insert` so the insertion site is a
  ## reactive seam. This lets HMR (`renderHot` under `-d:isonimHmr`) swap the
  ## root component in place via reconciliation in `insertExpression`, instead
  ## of disposing and re-mounting the reactive root.
  var disposer: proc()
  createRoot proc(dispose: proc()) =
    disposer = dispose
    # Route through insertExpression with a function accessor so the
    # insertion site participates in dom-expressions reconciliation. When
    # `accessor` returns a Node, insertExpression installs it inside a
    # createRenderEffect and the effect tracks no signals (untrack), so
    # the body runs exactly once. When the accessor returns a function
    # (e.g., the HMR proxy under `-d:isonimHmr`), insertExpression unwraps
    # and reactively reconciles in place.
    let accessor = proc(): Node = untrack(proc(): Node = code())
    # Nim's type system rejects a direct cast from a closure to JsRoot, but
    # at runtime a Nim closure compiled to JS *is* a JS function — exactly
    # what insertExpression's `typeof === 'function'` branch wants. Use an
    # emit to bypass the type check.
    var jsAccessor: JsRoot
    {.emit: [jsAccessor, " = ", accessor, ";"].}
    discard insertExpression(element.Node, jsAccessor, nil, nil)
  return proc() =
    if disposer != nil:
      disposer()
    element.textContent = ""

# ---- insert ----

proc insert*(parent: Node, accessor: JsRoot, marker: Node = nil,
    initial: JsRoot = nil) =
  ## Reactive content insertion. If accessor is a function, wraps in an effect
  ## so the DOM updates when reactive values change.
  ## For static values, calls insertExpression directly.
  var initVal = initial
  if not marker.isNodeNil and initVal.isNull:
    {.emit: [initVal, " = [];"].}

  var isFunc: bool
  {.emit: [isFunc, " = (typeof ", accessor, " === 'function');"].}

  if not isFunc:
    discard insertExpression(parent, accessor, initVal, marker)
  else:
    let cur = cell(initVal)
    createRenderEffect proc() =
      var val: JsRoot
      {.emit: [val, " = ", accessor, "();"].}
      cur.val = insertExpression(parent, val, cur.val, marker)

proc insert*(parent: Node, text: cstring) =
  ## Convenience overload: insert a static string.
  let textNode = document.createTextNode(text)
  parent.appendChild(textNode)

proc insert*(parent: Node, accessor: proc(): cstring) =
  ## Convenience overload: insert a reactive string accessor.
  let textNode = document.createTextNode("")
  parent.appendChild(textNode)
  createRenderEffect proc() =
    textNode.textContent = accessor()

proc insert*(parent: Node, child: Node) =
  ## Convenience overload: insert a static child node.
  parent.appendChild(child)

# ---- insertExpression helpers ----

proc cleanChildren(parent: Node, current: JsRoot, marker: Node,
    replacement: Node = nil): JsRoot =
  ## Remove current children. If marker is undefined (JS-level), clears via textContent.
  ## Otherwise, removes nodes from the array and inserts replacement.
  var isUndefined: bool
  {.emit: [isUndefined, " = (", marker, " === undefined);"].}

  if isUndefined:
    parent.textContent = ""
    {.emit: ["return '';"].}

  let node =
    if not replacement.isNodeNil: replacement
    else: document.createTextNode("")

  var currentLen: int
  {.emit: [currentLen, " = (", current, " && ", current, ".length) || 0;"].}

  if currentLen > 0:
    var inserted = false
    for i in countdown(currentLen - 1, 0):
      var el: Node
      {.emit: [el, " = ", current, "[", i, "];"].}
      if cast[JsRoot](node) != cast[JsRoot](el):
        var isParent: bool
        {.emit: [isParent, " = (", el, ".parentNode === ", parent, ");"].}
        if not inserted and i == 0:
          if isParent:
            parent.replaceChild(node, el)
          else:
            parent.insertBefore(node, marker)
        elif isParent:
          el.remove()
      else:
        inserted = true
  else:
    parent.insertBefore(node, marker)

  var res: JsRoot
  {.emit: [res, " = [", node, "];"].}
  return res

proc appendNodes(parent: Node, arr: JsRoot, marker: Node = nil) =
  ## Append all nodes in arr to parent before marker.
  var len: int
  {.emit: [len, " = ", arr, ".length;"].}
  for i in 0 ..< len:
    var node: Node
    {.emit: [node, " = ", arr, "[", i, "];"].}
    parent.insertBefore(node, marker)

# ---- insertExpression ----

proc insertExpression*(parent: Node, value: JsRoot, current: JsRoot,
    marker: Node = nil): JsRoot =
  ## The core insertion logic handling strings, nodes, arrays, functions.
  ## Ported from dom-expressions client.js insertExpression.
  # JS-level reference equality short-circuit. `cast[pointer]` followed by
  # `==` is unreliable on the Nim JS backend for closure/tuple-shaped
  # JsRoot values: nim emits structural per-field comparison, which both
  # produces malformed JS for closures and misses the semantic meaning.
  # `===` is the right operator here regardless.
  var ptrEq: bool
  {.emit: [ptrEq, " = (", value, " === ", current, ");"].}
  if ptrEq:
    return current

  var t: cstring
  {.emit: [t, " = typeof ", value, ";"].}

  let multi = not marker.isNodeNil

  if t == "string" or t == "number":
    var strValue: cstring
    {.emit: [strValue, " = String(", value, ");"].}

    if multi:
      var firstNode: Node
      var firstNodeType: int
      {.emit: ["""
        if (""", current, """ && Array.isArray(""", current, """) && """, current, """.length > 0) {
          """, firstNode, """ = """, current, """[0];
          """, firstNodeType, """ = """, firstNode, """ ? """, firstNode, """.nodeType : 0;
        } else {
          """, firstNode, """ = null;
          """, firstNodeType, """ = 0;
        }
      """].}
      if not firstNode.isNodeNil and firstNodeType == 3:
        firstNode.textContent = strValue
      else:
        firstNode = document.createTextNode(strValue)
      return cleanChildren(parent, current, marker, firstNode)
    else:
      var curIsString: bool
      {.emit: [curIsString, " = (", current, " !== '' && typeof ", current, " === 'string');"].}
      if curIsString:
        parent.firstChild.textContent = strValue
        {.emit: ["return ", strValue, ";"].}
      else:
        parent.textContent = strValue
        {.emit: ["return ", strValue, ";"].}

  var isNullOrBool: bool
  {.emit: [isNullOrBool, " = (", value, " == null || ", t, " === 'boolean');"].}

  if isNullOrBool:
    return cleanChildren(parent, current, marker)

  var isFunc: bool
  {.emit: [isFunc, " = (", t, " === 'function');"].}

  if isFunc:
    let cur = cell(current)
    createRenderEffect proc() =
      var v: JsRoot
      {.emit: [v, " = ", value, "();"].}
      {.emit: ["while (typeof ", v, " === 'function') ", v, " = ", v, "();"].}
      cur.val = insertExpression(parent, v, cur.val, marker)
    {.emit: ["return function() { return ", cur, ".val; };"].}

  var isArray: bool
  {.emit: [isArray, " = Array.isArray(", value, ");"].}

  if isArray:
    var arrayLen: int
    {.emit: [arrayLen, " = ", value, ".length;"].}

    if arrayLen == 0:
      var res = cleanChildren(parent, current, marker)
      if multi:
        return res
    else:
      var currentIsArray: bool
      {.emit: [currentIsArray, " = (", current, " && Array.isArray(", current, "));"].}

      if currentIsArray:
        var currentLen: int
        {.emit: [currentLen, " = ", current, ".length;"].}
        if currentLen == 0:
          appendNodes(parent, value, marker)
        else:
          {.emit: ["// Simple reconciliation: remove old, add new\nfor (var _i = 0; _i < ", current, ".length; _i++) { var _el = ", current, "[_i]; if (_el.parentNode === ", parent, ") _el.remove(); }"].}
          appendNodes(parent, value, marker)
      else:
        var curExists: bool
        {.emit: [curExists, " = (", current, " != null && ", current, " !== '');"].}
        if curExists:
          discard cleanChildren(parent, current, marker)
        appendNodes(parent, value, marker)
    {.emit: ["return ", value, ";"].}

  # Must be a DOM node
  var hasNodeType: bool
  {.emit: [hasNodeType, " = (", value, " && ", value, ".nodeType);"].}

  if hasNodeType:
    var currentIsArray2: bool
    {.emit: [currentIsArray2, " = Array.isArray(", current, ");"].}

    if currentIsArray2:
      if multi:
        return cleanChildren(parent, current, marker, Node(value))
      discard cleanChildren(parent, current, nil, Node(value))
    else:
      var curIsEmpty: bool
      {.emit: [curIsEmpty, " = (", current, " == null || ", current,
          " === '' || !", parent, ".firstChild);"].}
      if curIsEmpty:
        parent.appendChild(Node(value))
      else:
        parent.replaceChild(Node(value), parent.firstChild)
    return value

  return current

# ---- Property setters ----

proc setProperty*(node: Element, name: cstring, value: JsRoot) =
  ## Sets a JS property on a DOM element.
  {.emit: [node, "[", name, "] = ", value, ";"].}

proc setAttributeWeb*(node: Element, name: cstring, value: cstring) =
  ## Sets or removes an attribute on a DOM element.
  if value.isNil:
    node.removeAttribute(name)
  else:
    node.setAttribute(name, value)

proc setBoolAttribute*(node: Element, name: cstring, value: bool) =
  ## Sets or removes a boolean attribute.
  if value:
    node.setAttribute(name, cstring(""))
  else:
    node.removeAttribute(name)

proc setClassName*(node: Element, value: cstring) =
  ## Sets or removes the class attribute.
  if value.isNil:
    node.removeAttribute(cstring("class"))
  else:
    node.className = value

proc setStyle*(node: Element, name: cstring, value: cstring) =
  ## Sets a single style property.
  {.emit: ["""
    if (""", value, """ != null) """, node, """.style.setProperty(""", name, """, """, value, """);
    else """, node, """.style.removeProperty(""", name, """);
  """].}
