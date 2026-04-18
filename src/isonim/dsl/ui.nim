## isonim/dsl/ui.nim
##
## ui macro -- Karax-style HTML DSL entry point.
## Transforms a DSL block into renderer-specific calls at compile time.
##
## Two modes:
## - `ui(renderer): body` -- client mode, creates element tree via renderer API
## - `uiString: body` -- SSR mode, generates HTML string concatenation

import std/macros
import transform
import tailwind

var gensymCounter {.compileTime.} = 0

proc attrNameStr(node: NimNode): string {.compileTime.} =
  ## Extract an attribute name from an ident or acc-quoted ident (e.g. `aria-label`).
  case node.kind
  of nnkAccQuoted:
    result = ""
    for child in node:
      result.add child.strVal
  else:
    result = node.strVal

proc genName(prefix: string): NimNode {.compileTime.} =
  inc gensymCounter
  result = ident(prefix & $gensymCounter)

# ---------------------------------------------------------------------------
# Void elements (shared between client and SSR modes)
# ---------------------------------------------------------------------------

const voidElements* = [
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "keygen", "link", "menuitem", "meta", "param",
  "source", "track", "wbr",
]

proc isVoidElement*(tag: string): bool {.compileTime.} =
  for v in voidElements:
    if tag == v: return true
  return false

# ---------------------------------------------------------------------------
# Client mode (renderer-based element creation)
# ---------------------------------------------------------------------------

proc processNode(rendererSym: NimNode; node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc processShowIf(rendererSym, parentSym: NimNode; children: NimNode;
                    idx: int; stmts: NimNode): int {.compileTime.}

proc processForIn(rendererSym, parentSym: NimNode; node: NimNode;
                  stmts: NimNode) {.compileTime.}

proc processChildren(rendererSym, parentSym: NimNode; body: NimNode;
    stmts: NimNode) {.compileTime.}

proc processIfStmt(rendererSym, parentSym: NimNode; node: NimNode;
    stmts: NimNode) {.compileTime.} =
  ## Process an if/elif/else statement, transforming DSL children in each branch.
  var newIf = newNimNode(nnkIfStmt)
  for branch in node:
    case branch.kind
    of nnkElifBranch:
      let cond = branch[0]
      let body = branch[1]
      let branchStmts = newStmtList()
      processChildren(rendererSym, parentSym, body, branchStmts)
      newIf.add(newNimNode(nnkElifBranch).add(cond, branchStmts))
    of nnkElse:
      let body = branch[0]
      let branchStmts = newStmtList()
      processChildren(rendererSym, parentSym, body, branchStmts)
      newIf.add(newNimNode(nnkElse).add(branchStmts))
    else:
      discard
  stmts.add(newIf)

proc processForStmt(rendererSym, parentSym: NimNode; node: NimNode;
    stmts: NimNode) {.compileTime.} =
  ## Process a for loop, transforming DSL children in the body.
  ## for x in collection: dslBody
  let body = node[^1]
  let bodyStmts = newStmtList()
  processChildren(rendererSym, parentSym, body, bodyStmts)
  var newFor = newNimNode(nnkForStmt)
  for i in 0 ..< node.len - 1:
    newFor.add(node[i])
  newFor.add(bodyStmts)
  stmts.add(newFor)

proc processCaseStmt(rendererSym, parentSym: NimNode; node: NimNode;
                    stmts: NimNode) {.compileTime.} =
  ## Process a case statement, transforming DSL children in each branch.
  var newCase = newNimNode(nnkCaseStmt)
  newCase.add(node[0])  # case expression
  for i in 1 ..< node.len:
    let branch = node[i]
    case branch.kind
    of nnkOfBranch:
      let body = branch[^1]
      let branchStmts = newStmtList()
      processChildren(rendererSym, parentSym, body, branchStmts)
      var newBranch = newNimNode(nnkOfBranch)
      for j in 0 ..< branch.len - 1:
        newBranch.add(branch[j])
      newBranch.add(branchStmts)
      newCase.add(newBranch)
    of nnkElse:
      let body = branch[0]
      let branchStmts = newStmtList()
      processChildren(rendererSym, parentSym, body, branchStmts)
      newCase.add(newNimNode(nnkElse).add(branchStmts))
    else:
      newCase.add(branch)
  stmts.add(newCase)

proc processChildren(rendererSym, parentSym: NimNode; body: NimNode; stmts: NimNode) {.compileTime.} =
  ## Process a statement list of DSL children.
  ## Handles element nodes, text nodes, control flow (if/for/case),
  ## and passes through arbitrary Nim statements.
  var i = 0
  while i < body.len:
    let child = body[i]
    case child.kind
    of nnkCall, nnkCommand:
      let name = if child[0].kind == nnkIdent: child[0].strVal else: ""
      if name == "showIf":
        i = processShowIf(rendererSym, parentSym, body, i, stmts)
        continue
      elif name == "forIn":
        processForIn(rendererSym, parentSym, child, stmts)
        inc i
        continue
      else:
        let childNode = processNode(rendererSym, child, stmts)
        if childNode != nil:
          stmts.add(newCall(newDotExpr(rendererSym, ident"appendChild"),
                            parentSym, childNode))
    of nnkIdent:
      # Bare identifier — check if it's a known HTML void element (e.g. `br`, `hr`)
      let tagName = resolveTagName(child.strVal)
      if isVoidElement(tagName):
        let elSym = genName("el")
        stmts.add(newLetStmt(elSym,
          newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode(tagName))))
        stmts.add(newCall(newDotExpr(rendererSym, ident"appendChild"),
                          parentSym, elSym))
      else:
        stmts.add(child)
    of nnkStmtList:
      processChildren(rendererSym, parentSym, child, stmts)
    of nnkIfStmt, nnkWhenStmt:
      processIfStmt(rendererSym, parentSym, child, stmts)
    of nnkForStmt:
      processForStmt(rendererSym, parentSym, child, stmts)
    of nnkCaseStmt:
      processCaseStmt(rendererSym, parentSym, child, stmts)
    else:
      # Pass through arbitrary Nim statements (let, var, discard, etc.)
      stmts.add(child)
    inc i

proc processShowIf(rendererSym, parentSym: NimNode; children: NimNode;
                    idx: int; stmts: NimNode): int {.compileTime.} =
  ## Process a showIf directive. Returns the next index to process.
  ## showIf(condition): body
  ## optionally followed by showElse: fallback
  let showNode = children[idx]
  # Extract condition expression (first arg after the name)
  let condExpr = showNode[1]
  # Extract body (the stmt list, last arg)
  let bodyBlock = showNode[^1]

  # Check for optional showElse following
  var fallbackBlock: NimNode = nil
  var nextIdx = idx + 1
  if nextIdx < children.len:
    let nextChild = children[nextIdx]
    if nextChild.kind in {nnkCall, nnkCommand}:
      let nextName = if nextChild[0].kind == nnkIdent: nextChild[0].strVal else: ""
      if nextName == "showElse":
        fallbackBlock = nextChild[^1]
        nextIdx = nextIdx + 1

  # Generate: show(renderer, parent, proc(): bool = condition, bodyProc, fallbackProc)
  # Body proc: creates child elements and returns root
  let bodyProcStmts = newStmtList()
  let bodyRootSym = genName("showBody")
  # Create a wrapper element for the body content
  bodyProcStmts.add(newLetStmt(bodyRootSym,
    newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode("span"))))
  processChildren(rendererSym, bodyRootSym, bodyBlock, bodyProcStmts)
  bodyProcStmts.add(bodyRootSym)

  # Use typeof to get the node type from the renderer
  let nodeType = newCall(ident"typeof",
    newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode("")))

  let bodyProc = newProc(
    params = [nodeType],
    body = bodyProcStmts
  )

  let condProc = newProc(
    params = [ident"bool"],
    body = newStmtList(condExpr)
  )

  if fallbackBlock != nil:
    let fallbackProcStmts = newStmtList()
    let fallbackRootSym = genName("showFallback")
    fallbackProcStmts.add(newLetStmt(fallbackRootSym,
      newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode("span"))))
    processChildren(rendererSym, fallbackRootSym, fallbackBlock, fallbackProcStmts)
    fallbackProcStmts.add(fallbackRootSym)

    let fallbackProc = newProc(
      params = [nodeType],
      body = fallbackProcStmts
    )

    stmts.add(newCall(ident"show", rendererSym, parentSym, condProc, bodyProc, fallbackProc))
  else:
    stmts.add(newCall(ident"show", rendererSym, parentSym, condProc, bodyProc))

  return nextIdx

proc processForIn(rendererSym, parentSym: NimNode; node: NimNode;
                  stmts: NimNode) {.compileTime.} =
  ## Process a forIn directive.
  ## forIn(seq_expr): body
  ## Generates a call to forEachKeyed with injected `item` and `index` variables.
  let seqExpr = node[1]
  let bodyBlock = node[^1]

  # Generate: forEachKeyed(renderer, parent, proc(): auto = seqExpr,
  #   proc(item: proc(): auto, index: proc(): int): auto = ...)
  # Use typeof to get the seq element type and node type
  let nodeType = newCall(ident"typeof",
    newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode("")))

  let eachProc = newProc(
    params = [newCall(ident"typeof", seqExpr)],
    body = newStmtList(seqExpr)
  )

  # Body proc receives item accessor and index accessor
  let itemParam = ident"itemAccessor"
  let indexParam = ident"indexAccessor"

  let bodyProcStmts = newStmtList()
  let forBodyRootSym = genName("forBody")
  bodyProcStmts.add(newLetStmt(forBodyRootSym,
    newCall(newDotExpr(rendererSym, ident"createElement"), newStrLitNode("span"))))

  # Inject `item` template that calls the accessor, and `index` template
  # Use a template so `item` in the body expands to `itemAccessor()`
  bodyProcStmts.add(
    newNimNode(nnkTemplateDef).add(
      ident"item",
      newEmptyNode(), newEmptyNode(),
      newNimNode(nnkFormalParams).add(ident"untyped"),
      newEmptyNode(), newEmptyNode(),
      newStmtList(newCall(itemParam))
    )
  )
  bodyProcStmts.add(
    newNimNode(nnkTemplateDef).add(
      ident"index",
      newEmptyNode(), newEmptyNode(),
      newNimNode(nnkFormalParams).add(ident"untyped"),
      newEmptyNode(), newEmptyNode(),
      newStmtList(newCall(indexParam))
    )
  )

  processChildren(rendererSym, forBodyRootSym, bodyBlock, bodyProcStmts)
  bodyProcStmts.add(forBodyRootSym)

  # Build the element type for item accessor: typeof(seqExpr[0])
  let elemType = newCall(ident"typeof",
    newNimNode(nnkBracketExpr).add(seqExpr, newIntLitNode(0)))

  let bodyProc = newProc(
    params = [
      nodeType,
      newIdentDefs(itemParam, newNimNode(nnkProcTy).add(
        newNimNode(nnkFormalParams).add(elemType),
        newEmptyNode()
      )),
      newIdentDefs(indexParam, newNimNode(nnkProcTy).add(
        newNimNode(nnkFormalParams).add(ident"int"),
        newEmptyNode()
      ))
    ],
    body = bodyProcStmts
  )

  stmts.add(newCall(ident"forEachKeyed", rendererSym, parentSym, eachProc, bodyProc))

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
        let attrName = attrNameStr(arg[0])
        let attrVal = arg[1]

        if isEventHandler(attrName):
          # Event handler: onclick = proc() = ...
          let evName = eventName(attrName)
          stmts.add(newCall(
            newDotExpr(rendererSym, ident"addEventListener"),
            elSym, newStrLitNode(evName), attrVal))
        elif attrName == "class" and not isDynamic(attrVal):
          # Static class attribute — always set as attribute (for CSS/debugging),
          # AND expand recognized Tailwind utilities to setStyle calls on native.
          stmts.add(newCall(
            newDotExpr(rendererSym, ident"setAttribute"),
            elSym, newStrLitNode("class"), attrVal))
          when not defined(js):
            let classStr = attrVal.strVal
            let styles = expandTailwindClassesCompileTime(classStr)
            for (prop, val) in styles:
              stmts.add(newCall(
                newDotExpr(rendererSym, ident"setStyle"),
                elSym, newStrLitNode(prop), newStrLitNode(val)))
        elif isStyleProperty(attrName):
          # CSS style property: emit setStyle instead of setAttribute
          let cssName = toStyleName(attrName)
          if not isDynamic(attrVal):
            stmts.add(newCall(
              newDotExpr(rendererSym, ident"setStyle"),
              elSym, newStrLitNode(cssName), attrVal))
          else:
            let effectBody = newProc(
              params = [newEmptyNode()],
              body = newStmtList(
                newCall(newDotExpr(rendererSym, ident"setStyle"),
                        elSym, newStrLitNode(cssName), attrVal)
              )
            )
            stmts.add(newCall(ident"createRenderEffect", effectBody))
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

macro ui*(renderer: untyped; body: untyped): untyped =
  ## Karax-style DSL macro (client mode). Takes a renderer and a body block,
  ## produces code that creates a tree of elements via the renderer API.
  ##
  ## Usage:
  ##   let root = ui(myRenderer):
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
    error("ui expects a DSL body block", body)

  # Return the root element
  if rootSym != nil:
    stmts.add(rootSym)

  result = newBlockStmt(stmts)

# ---------------------------------------------------------------------------
# SSR mode (string concatenation)
# ---------------------------------------------------------------------------

proc ssrNodeExpr(node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc ssrShowIfExpr(children: NimNode; idx: int; stmts: NimNode): (NimNode, int) {.compileTime.}
proc ssrForInExpr(node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc ssrChildrenExpr(body: NimNode; stmts: NimNode): NimNode {.compileTime.} =
  ## Generates a string expression for a list of SSR children.
  ## Returns a NimNode representing the concatenated HTML string.
  var parts: seq[NimNode] = @[]
  var i = 0
  while i < body.len:
    let child = body[i]
    case child.kind
    of nnkCall, nnkCommand:
      let name = if child[0].kind == nnkIdent: child[0].strVal else: ""
      if name == "showIf":
        let (expr, nextIdx) = ssrShowIfExpr(body, i, stmts)
        if expr != nil:
          parts.add(expr)
        i = nextIdx
        continue
      elif name == "forIn":
        let expr = ssrForInExpr(child, stmts)
        if expr != nil:
          parts.add(expr)
        inc i
        continue
      else:
        let expr = ssrNodeExpr(child, stmts)
        if expr != nil:
          parts.add(expr)
    of nnkIdent:
      # Bare identifier — check if it's a known HTML void element (e.g. `br`, `hr`, `img`)
      let tagName = resolveTagName(child.strVal)
      if isVoidElement(tagName):
        parts.add(newStrLitNode("<" & tagName & " />"))
      else:
        # Not a void element — pass through as Nim code
        stmts.add(child)
    of nnkStmtList:
      let expr = ssrChildrenExpr(child, stmts)
      if expr != nil:
        parts.add(expr)
    of nnkIfStmt:
      # Handle plain `if` statements whose branches contain DSL nodes.
      # Transform into an if-expression that returns the concatenated HTML
      # string for each branch, so DSL nodes inside branches are rendered.
      var ifExpr = newNimNode(nnkIfExpr)
      for branch in child:
        case branch.kind
        of nnkElifBranch:
          let cond = branch[0]
          let branchBody = branch[^1]
          let branchStmts = newStmtList()
          let branchHtml = ssrChildrenExpr(branchBody, branchStmts)
          var branchBlock: NimNode
          if branchStmts.len > 0:
            branchBlock = newStmtList()
            for s in branchStmts:
              branchBlock.add(s)
            branchBlock.add(branchHtml)
          else:
            branchBlock = branchHtml
          ifExpr.add(newNimNode(nnkElifExpr).add(cond, branchBlock))
        of nnkElse:
          let branchBody = branch[^1]
          let branchStmts = newStmtList()
          let branchHtml = ssrChildrenExpr(branchBody, branchStmts)
          var branchBlock: NimNode
          if branchStmts.len > 0:
            branchBlock = newStmtList()
            for s in branchStmts:
              branchBlock.add(s)
            branchBlock.add(branchHtml)
          else:
            branchBlock = branchHtml
          ifExpr.add(newNimNode(nnkElseExpr).add(branchBlock))
        else:
          discard
      # If there's no else branch, add one that returns ""
      var hasElse = false
      for branch in child:
        if branch.kind == nnkElse:
          hasElse = true
          break
      if not hasElse:
        ifExpr.add(newNimNode(nnkElseExpr).add(newStrLitNode("")))
      parts.add(ifExpr)
    else:
      # Pass through arbitrary Nim statements
      stmts.add(child)
    inc i

  if parts.len == 0:
    return newStrLitNode("")
  elif parts.len == 1:
    return parts[0]
  else:
    # Concatenate all parts with &
    result = parts[0]
    for i in 1 ..< parts.len:
      result = newCall(ident"&", result, parts[i])

proc ssrShowIfExpr(children: NimNode; idx: int; stmts: NimNode): (NimNode, int) {.compileTime.} =
  ## Generates an if/else string expression for showIf/showElse in SSR mode.
  let showNode = children[idx]
  let condExpr = showNode[1]
  let bodyBlock = showNode[^1]

  # Check for optional showElse following
  var fallbackBlock: NimNode = nil
  var nextIdx = idx + 1
  if nextIdx < children.len:
    let nextChild = children[nextIdx]
    if nextChild.kind in {nnkCall, nnkCommand}:
      let nextName = if nextChild[0].kind == nnkIdent: nextChild[0].strVal else: ""
      if nextName == "showElse":
        fallbackBlock = nextChild[^1]
        nextIdx = nextIdx + 1

  let bodyExpr = ssrChildrenExpr(bodyBlock, stmts)

  if fallbackBlock != nil:
    let fallbackExpr = ssrChildrenExpr(fallbackBlock, stmts)
    # Generate: if condition: bodyHtml else: fallbackHtml
    let ifExpr = newNimNode(nnkIfExpr).add(
      newNimNode(nnkElifExpr).add(condExpr, bodyExpr),
      newNimNode(nnkElseExpr).add(fallbackExpr)
    )
    return (ifExpr, nextIdx)
  else:
    # Generate: if condition: bodyHtml else: ""
    let ifExpr = newNimNode(nnkIfExpr).add(
      newNimNode(nnkElifExpr).add(condExpr, bodyExpr),
      newNimNode(nnkElseExpr).add(newStrLitNode(""))
    )
    return (ifExpr, nextIdx)

proc ssrForInExpr(node: NimNode; stmts: NimNode): NimNode {.compileTime.} =
  ## Generates a loop string expression for forIn in SSR mode.
  ## forIn(seq_expr): body -> block: var res = ""; for index, item in seqExpr: res.add(childHtml); res
  let seqExpr = node[1]
  let bodyBlock = node[^1]

  let resSym = genName("forRes")
  # Use a local stmts list so that arbitrary Nim statements inside the forIn
  # body (let bindings, if-else, etc.) are emitted inside the for loop rather
  # than being hoisted to the outer scope where `item`/`index` aren't defined.
  let innerStmts = newStmtList()
  let childExpr = ssrChildrenExpr(bodyBlock, innerStmts)

  # Build the for-loop body: first the inner statements, then res.add(childExpr)
  let loopBody = newStmtList()
  for s in innerStmts:
    loopBody.add(s)
  loopBody.add(newCall(newDotExpr(resSym, ident"add"), childExpr))

  # Build: block: var res = ""; for index, item in seqExpr: <loopBody>; res
  let forLoop = newNimNode(nnkForStmt).add(
    ident"index",
    ident"item",
    seqExpr,
    loopBody
  )

  let blockBody = newStmtList(
    newVarStmt(resSym, newStrLitNode("")),
    forLoop,
    resSym
  )

  return newBlockStmt(blockBody)

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
        let attrName = attrNameStr(arg[0])
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

proc uiSsrImpl(body: NimNode): NimNode {.compileTime.} =
  ## Shared SSR implementation used by both `ui` (no renderer) and `uiString`.
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
    error("ui expects a DSL body block", body)

  if resultExpr != nil:
    stmts.add(resultExpr)

  result = newBlockStmt(stmts)

# ---------------------------------------------------------------------------
# Streaming SSR mode (direct OutputStream writes, no string concatenation)
# ---------------------------------------------------------------------------

proc streamWriteChildren(streamSym: NimNode; body: NimNode;
    stmts: NimNode) {.compileTime.}

proc streamWriteNode(streamSym: NimNode; node: NimNode;
    stmts: NimNode) {.compileTime.} =
  ## Generate stream.write() calls for a single node.

  if node.kind in {nnkCall, nnkCommand}:
    let name = if node[0].kind == nnkIdent: node[0].strVal else: ""

    if name == "text":
      let arg = node[1]
      # writeEscapedHtml(stream, arg) — zero allocation
      stmts.add(newCall(ident"writeEscapedHtml", streamSym, arg))
      return

    if name == "raw":
      # stream.write(arg) — no escaping
      stmts.add(newCall(newDotExpr(streamSym, ident"write"), node[1]))
      return

    # Element node
    let htmlTag = resolveTagName(name)
    let isVoid = isVoidElement(htmlTag)

    # Write opening tag start
    stmts.add(newCall(newDotExpr(streamSym, ident"write"),
      newStrLitNode("<" & htmlTag)))

    # Collect attributes and children
    var childBody: NimNode = nil

    for i in 1 ..< node.len:
      let arg = node[i]
      case arg.kind
      of nnkExprEqExpr:
        let attrName = attrNameStr(arg[0])
        let attrVal = arg[1]

        if isEventHandler(attrName):
          discard  # Ignored in SSR
        elif attrName == "needsId" or attrName == "hydrate":
          stmts.add(newCall(newDotExpr(streamSym, ident"write"),
            newCall(ident"ssrHydrationKey")))
        else:
          # writeEscapedAttr(stream, val) — zero allocation for attr values
          stmts.add(newCall(newDotExpr(streamSym, ident"write"),
            newStrLitNode(" " & attrName & "=\"")))
          stmts.add(newCall(ident"writeEscapedAttr", streamSym, attrVal))
          stmts.add(newCall(newDotExpr(streamSym, ident"write"),
            newStrLitNode("\"")))
      of nnkStmtList:
        childBody = arg
      of nnkCall, nnkCommand:
        if childBody == nil:
          childBody = newStmtList(arg)
        else:
          childBody.add(arg)
      else:
        discard

    if isVoid:
      stmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode(" />")))
    else:
      stmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode(">")))

      if childBody != nil:
        streamWriteChildren(streamSym, childBody, stmts)

      stmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode("</" & htmlTag & ">")))

proc streamWriteShowIf(streamSym: NimNode; children: NimNode;
    idx: int; stmts: NimNode): int {.compileTime.} =
  let showNode = children[idx]
  let condExpr = showNode[1]
  let bodyBlock = showNode[^1]

  var fallbackBlock: NimNode = nil
  var nextIdx = idx + 1
  if nextIdx < children.len:
    let nextChild = children[nextIdx]
    if nextChild.kind in {nnkCall, nnkCommand}:
      let nextName = if nextChild[0].kind == nnkIdent: nextChild[0].strVal else: ""
      if nextName == "showElse":
        fallbackBlock = nextChild[^1]
        nextIdx = nextIdx + 1

  # Generate: if condition: <write body> else: <write fallback>
  let bodyStmts = newStmtList()
  streamWriteChildren(streamSym, bodyBlock, bodyStmts)

  if fallbackBlock != nil:
    let fallbackStmts = newStmtList()
    streamWriteChildren(streamSym, fallbackBlock, fallbackStmts)
    stmts.add(newNimNode(nnkIfStmt).add(
      newNimNode(nnkElifBranch).add(condExpr, bodyStmts),
      newNimNode(nnkElse).add(fallbackStmts)
    ))
  else:
    stmts.add(newNimNode(nnkIfStmt).add(
      newNimNode(nnkElifBranch).add(condExpr, bodyStmts)
    ))

  return nextIdx

proc streamWriteForIn(streamSym: NimNode; node: NimNode;
    stmts: NimNode) {.compileTime.} =
  let seqExpr = node[1]
  let bodyBlock = node[^1]

  let loopBody = newStmtList()
  streamWriteChildren(streamSym, bodyBlock, loopBody)

  let forLoop = newNimNode(nnkForStmt).add(
    ident"index",
    ident"item",
    seqExpr,
    loopBody
  )
  stmts.add(forLoop)

proc streamWriteChildren(streamSym: NimNode; body: NimNode;
    stmts: NimNode) {.compileTime.} =
  var i = 0
  while i < body.len:
    let child = body[i]
    case child.kind
    of nnkCall, nnkCommand:
      let name = if child[0].kind == nnkIdent: child[0].strVal else: ""
      if name == "showIf":
        i = streamWriteShowIf(streamSym, body, i, stmts)
        continue
      elif name == "forIn":
        streamWriteForIn(streamSym, child, stmts)
        inc i
        continue
      else:
        streamWriteNode(streamSym, child, stmts)
    of nnkIdent:
      let tagName = resolveTagName(child.strVal)
      if isVoidElement(tagName):
        stmts.add(newCall(newDotExpr(streamSym, ident"write"),
          newStrLitNode("<" & tagName & " />")))
      else:
        stmts.add(child)
    of nnkStmtList:
      streamWriteChildren(streamSym, child, stmts)
    of nnkIfStmt:
      var newIf = newNimNode(nnkIfStmt)
      for branch in child:
        case branch.kind
        of nnkElifBranch:
          let branchStmts = newStmtList()
          streamWriteChildren(streamSym, branch[^1], branchStmts)
          newIf.add(newNimNode(nnkElifBranch).add(branch[0], branchStmts))
        of nnkElse:
          let branchStmts = newStmtList()
          streamWriteChildren(streamSym, branch[^1], branchStmts)
          newIf.add(newNimNode(nnkElse).add(branchStmts))
        else:
          discard
      stmts.add(newIf)
    of nnkForStmt:
      let forBody = newStmtList()
      streamWriteChildren(streamSym, child[^1], forBody)
      var newFor = newNimNode(nnkForStmt)
      for j in 0 ..< child.len - 1:
        newFor.add(child[j])
      newFor.add(forBody)
      stmts.add(newFor)
    of nnkCaseStmt:
      var newCase = newNimNode(nnkCaseStmt)
      newCase.add(child[0])
      for j in 1 ..< child.len:
        let branch = child[j]
        case branch.kind
        of nnkOfBranch:
          let branchStmts = newStmtList()
          streamWriteChildren(streamSym, branch[^1], branchStmts)
          var newBranch = newNimNode(nnkOfBranch)
          for k in 0 ..< branch.len - 1:
            newBranch.add(branch[k])
          newBranch.add(branchStmts)
          newCase.add(newBranch)
        of nnkElse:
          let branchStmts = newStmtList()
          streamWriteChildren(streamSym, branch[^1], branchStmts)
          newCase.add(newNimNode(nnkElse).add(branchStmts))
        else:
          newCase.add(branch)
      stmts.add(newCase)
    else:
      stmts.add(child)
    inc i

proc isStreamWriteStrLit(node: NimNode; streamSym: NimNode): bool {.compileTime.} =
  ## Check if a statement is `stream.write("literal")`.
  if node.kind != nnkCall: return false
  if node.len != 2: return false
  let callee = node[0]
  if callee.kind != nnkDotExpr: return false
  if callee[1].kind != nnkIdent or callee[1].strVal != "write": return false
  if node[1].kind != nnkStrLit: return false
  return true

proc getWriteStrLit(node: NimNode): string {.compileTime.} =
  ## Extract the string literal from a `stream.write("literal")` call.
  node[1].strVal

proc coalesceWrites*(stmts: NimNode; streamSym: NimNode): NimNode {.compileTime.} =
  ## Merge consecutive stream.write(strLit) calls into a single write call
  ## with the concatenated string literal. Non-write statements (dynamic
  ## content, control flow) act as barriers that flush the accumulated string.
  result = newStmtList()
  var accum = ""

  for i in 0 ..< stmts.len:
    let stmt = stmts[i]
    if isStreamWriteStrLit(stmt, streamSym):
      accum.add(getWriteStrLit(stmt))
    else:
      # Flush accumulated string before the non-write statement
      if accum.len > 0:
        result.add(newCall(newDotExpr(streamSym, ident"write"),
          newStrLitNode(accum)))
        accum = ""
      # Recursively coalesce inside control flow blocks
      case stmt.kind
      of nnkIfStmt:
        var newIf = newNimNode(nnkIfStmt)
        for branch in stmt:
          case branch.kind
          of nnkElifBranch:
            let coalesced = coalesceWrites(branch[^1], streamSym)
            newIf.add(newNimNode(nnkElifBranch).add(branch[0], coalesced))
          of nnkElse:
            let coalesced = coalesceWrites(branch[^1], streamSym)
            newIf.add(newNimNode(nnkElse).add(coalesced))
          else:
            newIf.add(branch)
        result.add(newIf)
      of nnkForStmt:
        let coalesced = coalesceWrites(stmt[^1], streamSym)
        var newFor = newNimNode(nnkForStmt)
        for j in 0 ..< stmt.len - 1:
          newFor.add(stmt[j])
        newFor.add(coalesced)
        result.add(newFor)
      of nnkCaseStmt:
        var newCase = newNimNode(nnkCaseStmt)
        newCase.add(stmt[0])
        for j in 1 ..< stmt.len:
          let branch = stmt[j]
          case branch.kind
          of nnkOfBranch:
            let coalesced = coalesceWrites(branch[^1], streamSym)
            var newBranch = newNimNode(nnkOfBranch)
            for k in 0 ..< branch.len - 1:
              newBranch.add(branch[k])
            newBranch.add(coalesced)
            newCase.add(newBranch)
          of nnkElse:
            let coalesced = coalesceWrites(branch[^1], streamSym)
            newCase.add(newNimNode(nnkElse).add(coalesced))
          else:
            newCase.add(branch)
        result.add(newCase)
      of nnkBlockStmt:
        if stmt.len == 2:
          let coalesced = coalesceWrites(stmt[1], streamSym)
          result.add(newNimNode(nnkBlockStmt).add(stmt[0], coalesced))
        else:
          result.add(stmt)
      else:
        result.add(stmt)

  # Final flush
  if accum.len > 0:
    result.add(newCall(newDotExpr(streamSym, ident"write"),
      newStrLitNode(accum)))

proc uiStreamImpl*(streamSym: NimNode; body: NimNode): NimNode {.compileTime.} =
  ## Streaming SSR codegen: emits stream.write() calls for each HTML fragment.
  ## Adjacent static string writes are coalesced into a single write call
  ## at compile time.
  let rawStmts = newStmtList()

  case body.kind
  of nnkStmtList:
    if body.len == 1:
      streamWriteNode(streamSym, body[0], rawStmts)
    else:
      rawStmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode("<div>")))
      for child in body:
        streamWriteNode(streamSym, child, rawStmts)
      rawStmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode("</div>")))
  of nnkCall, nnkCommand:
    streamWriteNode(streamSym, body, rawStmts)
  else:
    error("ui expects a DSL body block", body)

  # Coalesce adjacent string literal writes into single calls
  let coalescedStmts = coalesceWrites(rawStmts, streamSym)
  result = newBlockStmt(coalescedStmts)

macro uiWrite*(stream: untyped; body: untyped): untyped =
  ## Streaming SSR macro. Writes HTML directly to a FastStreams OutputStream.
  ## No intermediate string allocation — each HTML fragment is written via
  ## stream.write() as it is generated.
  ##
  ## Usage:
  ##   var output = memoryOutput()
  ##   uiWrite(output):
  ##     tdiv(class = "container"):
  ##       h1: text "Hello"
  ##       p: text $someVar
  ##
  ## Generates:
  ##   output.write("<div class=\"container\">")
  ##   output.write("<h1>")
  ##   writeEscapedHtml(output, "Hello")
  ##   output.write("</h1>")
  ##   output.write("<p>")
  ##   writeEscapedHtml(output, $someVar)
  ##   output.write("</p>")
  ##   output.write("</div>")
  ##
  ## Text content and attribute values are escaped directly to the stream
  ## via writeEscapedHtml/writeEscapedAttr — no intermediate string for
  ## the escaped result.
  result = uiStreamImpl(stream, body)

macro ui*(body: untyped): untyped =
  ## SSR-mode DSL macro. When `ui` is called without a renderer argument,
  ## it produces an HTML string from the DSL block.
  ##
  ## Usage:
  ##   proc myPage(): string =
  ##     ui:
  ##       tdiv(class = "container"):
  ##         h1: text "Hello"
  ##         p: text $someVar
  ##
  ## This is the same DSL syntax as `ui(renderer): body`, but targeting
  ## string output instead of a renderer element tree. Dynamic expressions
  ## are evaluated inline (no reactive effects). Event handlers are ignored.
  result = uiSsrImpl(body)

macro uiString*(body: untyped): untyped {.deprecated: "use `ui` instead".} =
  ## Deprecated: use `ui` without a renderer argument instead.
  result = uiSsrImpl(body)

macro isomorphicUi*(renderer: untyped; body: untyped): untyped =
  ## Isomorphic DSL macro: compiles to `ui(renderer)` in client mode
  ## or `ui` (SSR string mode) when `-d:isServer` is defined.
  ##
  ## Usage:
  ##   proc myComponent(renderer: auto): auto =
  ##     isomorphicUi(renderer):
  ##       tdiv: text "works everywhere"
  ##
  ## In client mode, returns a renderer element node.
  ## In SSR mode, returns an HTML string. The renderer param is ignored.
  result = newNimNode(nnkWhenStmt)

  # when defined(isServer): ui: body  (SSR string mode)
  let serverBranch = newNimNode(nnkElifBranch)
  serverBranch.add(newCall(ident"defined", ident"isServer"))
  serverBranch.add(uiSsrImpl(body))

  # else: ui(renderer): body  (client renderer mode)
  let clientBranch = newNimNode(nnkElse)
  clientBranch.add(newCall(ident"ui", renderer, body))

  result.add(serverBranch)
  result.add(clientBranch)

# Backward-compatible aliases (deprecated)
template buildHtml*(renderer: untyped; body: untyped): untyped {.deprecated: "use `ui` instead".} =
  ui(renderer, body)

template buildHtmlString*(body: untyped): untyped {.deprecated: "use `ui` instead".} =
  ui(body)

template isomorphicHtml*(renderer: untyped; body: untyped): untyped {.deprecated: "use `isomorphicUi` instead".} =
  isomorphicUi(renderer, body)
