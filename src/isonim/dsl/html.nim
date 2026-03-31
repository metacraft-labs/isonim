## isonim/dsl/html.nim
##
## buildHtml macro -- Karax-style HTML DSL entry point.
## Transforms a DSL block into renderer-specific calls at compile time.

import std/macros
import transform

var gensymCounter {.compileTime.} = 0

proc genName(prefix: string): NimNode {.compileTime.} =
  inc gensymCounter
  result = ident(prefix & $gensymCounter)

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
  ## Karax-style DSL macro. Takes a renderer and a body block, produces
  ## code that creates a tree of elements via the renderer API.
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
