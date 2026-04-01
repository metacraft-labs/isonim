## isonim/dsl/html.nim
##
## buildHtml macro -- Karax-style HTML DSL entry point.
## Transforms a DSL block into renderer-specific calls at compile time.
##
## Two modes:
## - `buildHtml(renderer): body` -- client mode, creates element tree via renderer API
## - `buildHtmlString: body` -- SSR mode, generates HTML string concatenation

import std/macros
import transform

var gensymCounter {.compileTime.} = 0

proc genName(prefix: string): NimNode {.compileTime.} =
  inc gensymCounter
  result = ident(prefix & $gensymCounter)

# ---------------------------------------------------------------------------
# Client mode (renderer-based element creation)
# ---------------------------------------------------------------------------

proc processNode(rendererSym: NimNode; node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc processChildren(rendererSym, parentSym: NimNode; body: NimNode; stmts: NimNode) {.compileTime.} =
  ## Process a statement list of DSL children.
  for child in body:
    case child.kind
    of nnkCall, nnkCommand:
      let childNode = processNode(rendererSym, child, stmts)
      if childNode != nil:
        stmts.add(newCall(newDotExpr(rendererSym, ident"appendChild"),
                          parentSym, childNode))
    of nnkStmtList:
      processChildren(rendererSym, parentSym, child, stmts)
    else:
      # Pass through arbitrary Nim statements (let, var, if, etc.)
      stmts.add(child)

proc processNode(rendererSym: NimNode; node: NimNode; stmts: NimNode): NimNode {.compileTime.} =
  ## Process a single DSL node. Returns the NimNode symbol for the created element,
  ## or nil for text nodes (which are appended by this proc directly).

  # Handle `text` calls
  if node.kind in {nnkCall, nnkCommand}:
    let name = if node[0].kind == nnkIdent: node[0].strVal else: ""

    if name == "text":
      # text "literal" or text $expr
      let arg = node[1]
      let txtSym = genName("txt")

      if not isDynamic(arg):
        # Static text
        stmts.add(newLetStmt(txtSym,
          newCall(newDotExpr(rendererSym, ident"createTextNode"), arg)))
        return txtSym
      else:
        # Dynamic text - create text node then wrap update in effect
        stmts.add(newLetStmt(txtSym,
          newCall(newDotExpr(rendererSym, ident"createTextNode"), newStrLitNode(""))))

        # Create render effect to update text content
        let rendererCopy = rendererSym
        let txtCopy = txtSym
        let effectBody = newProc(
          params = [newEmptyNode()],
          body = newStmtList(
            newCall(newDotExpr(rendererCopy, ident"setTextContent"), txtCopy, arg)
          )
        )
        stmts.add(newCall(ident"createRenderEffect", effectBody))
        return txtSym

  # Handle element nodes: tagName(...): body or tagName: body
  if node.kind in {nnkCall, nnkCommand}:
    let nameNode = node[0]
    var tagIdent: string

    if nameNode.kind == nnkIdent:
      tagIdent = nameNode.strVal
    else:
      # Not a recognized DSL node, pass through
      return nil

    let htmlTag = resolveTagName(tagIdent)
    let elSym = genName("el")

    stmts.add(newLetStmt(elSym,
      newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode(htmlTag))))

    # Process arguments (attributes, event handlers) and body
    for i in 1 ..< node.len:
      let arg = node[i]

      case arg.kind
      of nnkExprEqExpr:
        # attr = value
        let attrName = arg[0].strVal
        let attrVal = arg[1]

        if isEventHandler(attrName):
          # Event handler: onclick = proc() = ...
          let evName = eventName(attrName)
          stmts.add(newCall(
            newDotExpr(rendererSym, ident"addEventListener"),
            elSym, newStrLitNode(evName), attrVal))
        elif not isDynamic(attrVal):
          # Static attribute
          stmts.add(newCall(
            newDotExpr(rendererSym, ident"setAttribute"),
            elSym, newStrLitNode(attrName), attrVal))
        else:
          # Dynamic attribute - wrap in effect
          let effectBody = newProc(
            params = [newEmptyNode()],
            body = newStmtList(
              newCall(newDotExpr(rendererSym, ident"setAttribute"),
                      elSym, newStrLitNode(attrName), attrVal)
            )
          )
          stmts.add(newCall(ident"createRenderEffect", effectBody))

      of nnkStmtList:
        # Child block
        processChildren(rendererSym, elSym, arg, stmts)

      of nnkCall, nnkCommand:
        # Inline child element (no colon block form)
        let childNode = processNode(rendererSym, arg, stmts)
        if childNode != nil:
          stmts.add(newCall(newDotExpr(rendererSym, ident"appendChild"),
                            elSym, childNode))
      else:
        discard

    return elSym

  return nil

macro buildHtml*(renderer: untyped; body: untyped): untyped =
  ## Karax-style DSL macro (client mode). Takes a renderer and a body block,
  ## produces code that creates a tree of elements via the renderer API.
  ##
  ## Usage:
  ##   let root = buildHtml(myRenderer):
  ##     tdiv(class = "container"):
  ##       h1: text "Hello"
  ##       span: text $count.val
  ##       button(onclick = handler):
  ##         text "Click me"

  let stmts = newStmtList()
  var rootSym: NimNode = nil

  # The body is a statement list of top-level DSL nodes
  case body.kind
  of nnkStmtList:
    # Multiple top-level nodes or single node in stmtlist
    if body.len == 1:
      rootSym = processNode(renderer, body[0], stmts)
    else:
      # Multiple top-level nodes: wrap in a fragment (div)
      let fragSym = genName("frag")
      stmts.add(newLetStmt(fragSym,
        newCall(newDotExpr(renderer, ident"createElement"), newStrLitNode("div"))))
      for child in body:
        let childNode = processNode(renderer, child, stmts)
        if childNode != nil:
          stmts.add(newCall(newDotExpr(renderer, ident"appendChild"),
                            fragSym, childNode))
      rootSym = fragSym

  of nnkCall, nnkCommand:
    rootSym = processNode(renderer, body, stmts)

  else:
    error("buildHtml expects a DSL body block", body)

  # Return the root element
  if rootSym != nil:
    stmts.add(rootSym)

  result = newBlockStmt(stmts)

# ---------------------------------------------------------------------------
# SSR mode (string concatenation)
# ---------------------------------------------------------------------------

const ssrVoidElements = [
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "keygen", "link", "menuitem", "meta", "param",
  "source", "track", "wbr",
]

proc isVoidElement(tag: string): bool {.compileTime.} =
  for v in ssrVoidElements:
    if tag == v: return true
  return false

proc ssrNodeExpr(node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc ssrChildrenExpr(body: NimNode; stmts: NimNode): NimNode {.compileTime.} =
  ## Generates a string expression for a list of SSR children.
  ## Returns a NimNode representing the concatenated HTML string.
  var parts: seq[NimNode] = @[]
  for child in body:
    case child.kind
    of nnkCall, nnkCommand:
      let expr = ssrNodeExpr(child, stmts)
      if expr != nil:
        parts.add(expr)
    of nnkStmtList:
      let expr = ssrChildrenExpr(child, stmts)
      if expr != nil:
        parts.add(expr)
    else:
      # Pass through arbitrary Nim statements
      stmts.add(child)

  if parts.len == 0:
    return newStrLitNode("")
  elif parts.len == 1:
    return parts[0]
  else:
    # Concatenate all parts with &
    result = parts[0]
    for i in 1 ..< parts.len:
      result = newCall(ident"&", result, parts[i])

proc ssrNodeExpr(node: NimNode; stmts: NimNode): NimNode {.compileTime.} =
  ## Generates a string expression for a single SSR node.

  if node.kind in {nnkCall, nnkCommand}:
    let name = if node[0].kind == nnkIdent: node[0].strVal else: ""

    # Handle `text` calls
    if name == "text":
      let arg = node[1]
      if not isDynamic(arg):
        return newCall(ident"escapeHtml", arg)
      else:
        return newCall(ident"escapeHtml", arg)

    # Handle `raw` calls - insert pre-rendered HTML without escaping
    if name == "raw":
      return node[1]

    # Handle element nodes
    let htmlTag = resolveTagName(name)
    let isVoid = isVoidElement(htmlTag)

    # Build the opening tag as a string expression
    var tagParts: seq[NimNode] = @[]
    tagParts.add(newStrLitNode("<" & htmlTag))

    # Collect attributes and children
    var childBody: NimNode = nil
    var hasHydrationKey = false

    for i in 1 ..< node.len:
      let arg = node[i]
      case arg.kind
      of nnkExprEqExpr:
        let attrName = arg[0].strVal
        let attrVal = arg[1]

        if isEventHandler(attrName):
          # Event handlers are ignored in SSR
          discard
        elif attrName == "needsId" or attrName == "hydrate":
          # Special: mark for hydration key
          hasHydrationKey = true
        elif not isDynamic(attrVal):
          # Static attribute
          tagParts.add(newStrLitNode(" " & attrName & "=\""))
          tagParts.add(newCall(ident"escapeAttr", attrVal))
          tagParts.add(newStrLitNode("\""))
        else:
          # Dynamic attribute
          tagParts.add(newStrLitNode(" " & attrName & "=\""))
          tagParts.add(newCall(ident"escapeAttr", attrVal))
          tagParts.add(newStrLitNode("\""))

      of nnkStmtList:
        childBody = arg

      of nnkCall, nnkCommand:
        # Inline child - treat as part of children
        if childBody == nil:
          childBody = newStmtList(arg)
        else:
          childBody.add(arg)
      else:
        discard

    # Add hydration key if needed
    if hasHydrationKey:
      tagParts.add(newCall(ident"ssrHydrationKey"))

    if isVoid:
      tagParts.add(newStrLitNode(" />"))
    else:
      tagParts.add(newStrLitNode(">"))

      # Process children
      if childBody != nil:
        let childExpr = ssrChildrenExpr(childBody, stmts)
        if childExpr != nil:
          tagParts.add(childExpr)

      tagParts.add(newStrLitNode("</" & htmlTag & ">"))

    # Concatenate all tag parts
    result = tagParts[0]
    for i in 1 ..< tagParts.len:
      result = newCall(ident"&", result, tagParts[i])

  else:
    return nil

macro buildHtmlString*(body: untyped): untyped =
  ## SSR-mode DSL macro. Produces an HTML string from the DSL block.
  ## No renderer needed -- generates string concatenation code.
  ##
  ## Usage:
  ##   let html = buildHtmlString:
  ##     tdiv(class = "container"):
  ##       h1: text "Hello"
  ##       span: text $count.val
  ##
  ## Dynamic expressions are evaluated inline (no effects).
  ## Event handlers are silently ignored.
  ## Use `hydrate = true` on elements that need `data-hk` markers.

  let stmts = newStmtList()
  var resultExpr: NimNode = nil

  case body.kind
  of nnkStmtList:
    if body.len == 1:
      resultExpr = ssrNodeExpr(body[0], stmts)
    else:
      # Multiple top-level nodes: wrap in a div
      var parts: seq[NimNode] = @[newStrLitNode("<div>")]
      for child in body:
        let expr = ssrNodeExpr(child, stmts)
        if expr != nil:
          parts.add(expr)
      parts.add(newStrLitNode("</div>"))
      resultExpr = parts[0]
      for i in 1 ..< parts.len:
        resultExpr = newCall(ident"&", resultExpr, parts[i])

  of nnkCall, nnkCommand:
    resultExpr = ssrNodeExpr(body, stmts)

  else:
    error("buildHtmlString expects a DSL body block", body)

  if resultExpr != nil:
    stmts.add(resultExpr)

  result = newBlockStmt(stmts)

macro isomorphicHtml*(renderer: untyped; body: untyped): untyped =
  ## Isomorphic DSL macro: compiles to `buildHtml` in client mode
  ## or `buildHtmlString` in SSR mode (when `-d:isServer` is defined).
  ##
  ## Usage:
  ##   proc myComponent(renderer: auto): auto =
  ##     isomorphicHtml(renderer):
  ##       tdiv: text "works everywhere"
  ##
  ## In client mode, returns a renderer element node.
  ## In SSR mode, returns an HTML string. The renderer param is ignored.
  result = newNimNode(nnkWhenStmt)

  # when defined(isServer): buildHtmlString: body
  let serverBranch = newNimNode(nnkElifBranch)
  serverBranch.add(newCall(ident"defined", ident"isServer"))
  serverBranch.add(newCall(ident"buildHtmlString", body))

  # else: buildHtml(renderer): body
  let clientBranch = newNimNode(nnkElse)
  clientBranch.add(newCall(ident"buildHtml", renderer, body))

  result.add(serverBranch)
  result.add(clientBranch)
