## isonim/web/dom_api.nim
##
## {.importjs.} DOM API wrappers.
## Provides typed Nim bindings for browser DOM operations.
##
## These bindings are only available on the JS backend.

when not defined(js):
  {.error: "isonim/web/dom_api requires the JS backend".}


type
  Node* {.importc.} = ref object of JsRoot
    nodeType*: int
    nodeValue*: cstring
    textContent*: cstring
    firstChild*: Node
    nextSibling*: Node
    parentNode*: Node
    childNodes*: seq[Node]

  Element* {.importc.} = ref object of Node
    tagName*: cstring
    innerHTML*: cstring
    className*: cstring

  HTMLTemplateElement* {.importc.} = ref object of Element
    content*: Node  # DocumentFragment

  Document* {.importc.} = ref object of Node

  Event* {.importc.} = ref object of JsRoot
    `type`*: cstring
    target*: Node
    currentTarget*: Node
    cancelBubble*: bool

  EventHandler* = proc(ev: Event) {.closure.}

var document* {.importc, nodecl.}: Document

proc createElement*(d: Document, tag: cstring): Element {.importcpp: "#.createElement(#)".}
proc createTextNode*(d: Document, text: cstring): Node {.importcpp: "#.createTextNode(#)".}
proc createDocumentFragment*(d: Document): Node {.importcpp: "#.createDocumentFragment()".}
proc getElementById*(d: Document, id: cstring): Element {.importcpp: "#.getElementById(#)".}

proc appendChild*(p: Node, c: Node): Node {.importcpp: "#.appendChild(#)", discardable.}
proc insertBefore*(p: Node, newNode: Node, refNode: Node): Node {.importcpp: "#.insertBefore(#, #)", discardable.}
proc removeChild*(p: Node, c: Node): Node {.importcpp: "#.removeChild(#)", discardable.}
proc replaceChild*(p: Node, newChild: Node, oldChild: Node): Node {.importcpp: "#.replaceChild(#, #)", discardable.}
proc cloneNode*(n: Node, deep: bool): Node {.importcpp: "#.cloneNode(#)".}
proc remove*(n: Node) {.importcpp: "#.remove()".}

proc setAttribute*(e: Element, name, value: cstring) {.importcpp: "#.setAttribute(#, #)".}
proc removeAttribute*(e: Element, name: cstring) {.importcpp: "#.removeAttribute(#)".}
proc getAttribute*(e: Element, name: cstring): cstring {.importcpp: "#.getAttribute(#)".}

proc addEventListener*(e: Node, event: cstring, handler: EventHandler) {.importcpp: "#.addEventListener(#, #)".}
proc removeEventListener*(e: Node, event: cstring, handler: EventHandler) {.importcpp: "#.removeEventListener(#, #)".}

# Property access helpers (JS dynamic property access)
proc setJsProp*(n: Node, name: cstring, value: JsRoot) {.importcpp: "#[#] = #".}
proc getJsProp*(n: Node, name: cstring): JsRoot {.importcpp: "#[#]".}
proc setJsPropBool*(n: Node, name: cstring, value: bool) {.importcpp: "#[#] = #".}
proc setJsPropCstring*(n: Node, name: cstring, value: cstring) {.importcpp: "#[#] = #".}
proc setJsPropHandler*(n: Node, name: cstring, value: EventHandler) {.importcpp: "#[#] = #".}
proc getJsPropBool*(n: Node, name: cstring): bool {.importcpp: "#[#]".}
proc isNodeNil*(n: Node): bool {.importcpp: "(# == null)".}
proc isNull*(n: JsRoot): bool {.importcpp: "(# == null)".}
proc disabled*(n: Node): bool {.importcpp: "(#.disabled || false)".}
