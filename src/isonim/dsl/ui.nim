## isonim/dsl/ui.nim
##
## ui macro — Karax-style HTML DSL entry point.
## Transforms a DSL block into target-specific code at compile time.
##
## Three output modes:
##
## - ``ui(renderer): body`` — client mode. Creates a reactive element tree
##   via the renderer API (createElement, setAttribute, appendChild, etc.).
##   Dynamic attributes and text are wrapped in ``createRenderEffect`` for
##   fine-grained reactivity. Event handlers are attached via addEventListener.
##
## - ``ui: body`` — SSR string mode. Generates HTML via string concatenation
##   (``&`` operator chains). Nim's compiler already folds adjacent string
##   literals and optimises the concatenation in native code, so no
##   additional coalescing is needed here.
##
## - ``uiWrite(stream): body`` — streaming SSR mode. Emits ``stream.write()``
##   calls for each HTML fragment. Uses an intermediate representation
##   (``StreamOp``) with a coalescing pass that merges adjacent static
##   string writes into a single call. This IR-based pipeline is specific
##   to the streaming path because ``stream.write()`` calls are individually
##   costly (function call overhead) and benefit from batching, unlike
##   string concatenation which the Nim compiler handles, or element
##   creation which has no meaningful merge semantics.
##
## The three backends intentionally have separate codegen implementations
## rather than sharing an IR, because they have fundamentally different
## output structures:
## - String mode produces expression trees (``a & b & c``)
## - Client mode produces statement sequences with reactive effects
## - Stream mode produces flat write calls that benefit from coalescing
##
## Sharing an IR would add complexity without benefit — each backend's
## optimisations are specific to its output target.

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
    of nnkForStmt:
      # Handle plain `for` loops whose body contains DSL nodes.
      # Transform into: block: var res = ""; for vars in iter: res.add(childHtml); res
      let forBody = child[^1]
      let forIter = child[^2]
      let resSym = genName("forRes")
      let innerStmts = newStmtList()
      let childExpr = ssrChildrenExpr(forBody, innerStmts)

      let loopBody = newStmtList()
      for s in innerStmts:
        loopBody.add(s)
      loopBody.add(newCall(newDotExpr(resSym, ident"add"), childExpr))

      var forLoop = newNimNode(nnkForStmt)
      for j in 0 ..< child.len - 2:
        forLoop.add(child[j])
      forLoop.add(forIter)
      forLoop.add(loopBody)

      let blockBody = newStmtList(
        newVarStmt(resSym, newStrLitNode("")),
        forLoop,
        resSym
      )
      parts.add(newBlockStmt(blockBody))
    of nnkCaseStmt:
      # Handle plain `case` statements whose branches contain DSL nodes.
      # Transform into a case-expression that returns concatenated HTML.
      var caseExpr = newNimNode(nnkCaseStmt)
      caseExpr.add(child[0])  # case expression
      for j in 1 ..< child.len:
        let branch = child[j]
        case branch.kind
        of nnkOfBranch:
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
          var newBranch = newNimNode(nnkOfBranch)
          for k in 0 ..< branch.len - 1:
            newBranch.add(branch[k])
          newBranch.add(branchBlock)
          caseExpr.add(newBranch)
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
          caseExpr.add(newNimNode(nnkElse).add(branchBlock))
        else:
          caseExpr.add(branch)
      parts.add(caseExpr)
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
# Streaming SSR mode — IR-based pipeline
#
# This backend uses an intermediate representation (StreamOp) because
# stream.write() calls have per-call overhead that benefits from batching.
# The IR enables a coalescing pass that merges adjacent static string
# fragments into a single write call at compile time.
#
# The string-mode backend (above) does NOT use this IR because Nim's
# compiler already optimises string concatenation chains in native code,
# making a macro-level coalescing pass redundant. The client-mode backend
# (further above) also doesn't use it because createElement/appendChild
# calls have no meaningful merge semantics.
#
# Pipeline:
#   1. collect:  DSL → seq[StreamOp]
#   2. coalesce: merge adjacent sokStatic ops
#   3. emit:     seq[StreamOp] → NimNode AST (stream.write / writeEscapedHtml)
# ---------------------------------------------------------------------------

type
  StreamOpKind* = enum
    sokStatic         ## Literal string fragment (e.g. "<div class=\"x\">")
    sokEscapedHtml    ## Dynamic text content (needs HTML escaping)
    sokEscapedAttr    ## Dynamic attribute value (needs attr escaping)
    sokRaw            ## Raw expression (no escaping, e.g. raw "...")
    sokHydrationKey   ## Insert hydration key marker
    sokNimStmt        ## Pass-through Nim statement (let, var, discard, etc.)
    sokIf             ## if/elif/else control flow
    sokFor            ## for loop
    sokForIn          ## forIn DSL directive
    sokCase           ## case statement

  StreamOp* = ref object
    case kind*: StreamOpKind
    of sokStatic:
      text*: string
    of sokEscapedHtml, sokEscapedAttr, sokRaw:
      expr*: NimNode
    of sokHydrationKey:
      discard
    of sokNimStmt:
      stmt*: NimNode
    of sokIf:
      ifBranches*: seq[tuple[cond: NimNode, body: seq[StreamOp]]]
        ## cond is nil for the else branch
    of sokFor:
      forVars*: seq[NimNode]    ## loop variables
      forIter*: NimNode         ## iterator expression
      forBody*: seq[StreamOp]
    of sokForIn:
      seqExpr*: NimNode
      forInBody*: seq[StreamOp]
    of sokCase:
      caseExpr*: NimNode
      caseOfBranches*: seq[tuple[values: seq[NimNode], body: seq[StreamOp]]]
      caseElse*: seq[StreamOp]  ## empty if no else branch

# ---------------------------------------------------------------------------
# Phase 1: Collect DSL → seq[StreamOp]
# ---------------------------------------------------------------------------

proc escapeAttrCompileTime(s: string): string {.compileTime.} =
  ## Escape " and & for HTML attribute context at compile time.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '"': result.add "&quot;"
    of '&': result.add "&amp;"
    else: result.add c

proc collectNode(node: NimNode; ops: var seq[StreamOp]) {.compileTime.}

proc collectShowIf(children: NimNode; idx: int;
    ops: var seq[StreamOp]): int {.compileTime.}

proc collectForIn(node: NimNode; ops: var seq[StreamOp]) {.compileTime.}

proc collectChildren(body: NimNode; ops: var seq[StreamOp]) {.compileTime.} =
  var i = 0
  while i < body.len:
    let child = body[i]
    case child.kind
    of nnkCall, nnkCommand:
      let name = if child[0].kind == nnkIdent: child[0].strVal else: ""
      if name == "showIf":
        i = collectShowIf(body, i, ops)
        continue
      elif name == "forIn":
        collectForIn(child, ops)
      else:
        collectNode(child, ops)
    of nnkIdent:
      let tagName = resolveTagName(child.strVal)
      if isVoidElement(tagName):
        ops.add(StreamOp(kind: sokStatic, text: "<" & tagName & " />"))
      else:
        ops.add(StreamOp(kind: sokNimStmt, stmt: child))
    of nnkStmtList:
      collectChildren(child, ops)
    of nnkIfStmt:
      var branches: seq[tuple[cond: NimNode, body: seq[StreamOp]]]
      for branch in child:
        case branch.kind
        of nnkElifBranch:
          var branchOps: seq[StreamOp]
          collectChildren(branch[^1], branchOps)
          branches.add((cond: branch[0], body: branchOps))
        of nnkElse:
          var branchOps: seq[StreamOp]
          collectChildren(branch[^1], branchOps)
          branches.add((cond: NimNode(nil), body: branchOps))
        else: discard
      ops.add(StreamOp(kind: sokIf, ifBranches: branches))
    of nnkForStmt:
      var forBody: seq[StreamOp]
      collectChildren(child[^1], forBody)
      var forVars: seq[NimNode]
      for j in 0 ..< child.len - 2:
        forVars.add(child[j])
      ops.add(StreamOp(kind: sokFor,
        forVars: forVars,
        forIter: child[^2],
        forBody: forBody))
    of nnkCaseStmt:
      var ofBranches: seq[tuple[values: seq[NimNode], body: seq[StreamOp]]]
      var elseOps: seq[StreamOp]
      for j in 1 ..< child.len:
        let branch = child[j]
        case branch.kind
        of nnkOfBranch:
          var branchOps: seq[StreamOp]
          collectChildren(branch[^1], branchOps)
          var values: seq[NimNode]
          for k in 0 ..< branch.len - 1:
            values.add(branch[k])
          ofBranches.add((values: values, body: branchOps))
        of nnkElse:
          collectChildren(branch[^1], elseOps)
        else: discard
      ops.add(StreamOp(kind: sokCase,
        caseExpr: child[0],
        caseOfBranches: ofBranches,
        caseElse: elseOps))
    else:
      ops.add(StreamOp(kind: sokNimStmt, stmt: child))
    inc i

proc collectShowIf(children: NimNode; idx: int;
    ops: var seq[StreamOp]): int {.compileTime.} =
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

  var bodyOps: seq[StreamOp]
  collectChildren(bodyBlock, bodyOps)

  var branches: seq[tuple[cond: NimNode, body: seq[StreamOp]]]
  branches.add((cond: condExpr, body: bodyOps))

  if fallbackBlock != nil:
    var fallbackOps: seq[StreamOp]
    collectChildren(fallbackBlock, fallbackOps)
    branches.add((cond: NimNode(nil), body: fallbackOps))

  ops.add(StreamOp(kind: sokIf, ifBranches: branches))
  return nextIdx

proc collectForIn(node: NimNode; ops: var seq[StreamOp]) {.compileTime.} =
  let seqExpr = node[1]
  let bodyBlock = node[^1]

  var bodyOps: seq[StreamOp]
  collectChildren(bodyBlock, bodyOps)

  ops.add(StreamOp(kind: sokForIn,
    seqExpr: seqExpr,
    forInBody: bodyOps))

proc collectNode(node: NimNode; ops: var seq[StreamOp]) {.compileTime.} =
  if node.kind in {nnkCall, nnkCommand}:
    let name = if node[0].kind == nnkIdent: node[0].strVal else: ""

    if name == "text":
      ops.add(StreamOp(kind: sokEscapedHtml, expr: node[1]))
      return
    if name == "raw":
      ops.add(StreamOp(kind: sokRaw, expr: node[1]))
      return

    let htmlTag = resolveTagName(name)
    let isVoid = isVoidElement(htmlTag)

    # Build opening tag, concatenating static attributes at compile time
    var openTag = "<" & htmlTag
    var childBody: NimNode = nil

    # We accumulate static parts into openTag and flush when a dynamic
    # part or hydration key is encountered.
    var pendingOps: seq[StreamOp]

    for i in 1 ..< node.len:
      let arg = node[i]
      case arg.kind
      of nnkExprEqExpr:
        let attrName = attrNameStr(arg[0])
        let attrVal = arg[1]

        if isEventHandler(attrName):
          discard  # Ignored in SSR
        elif attrName == "needsId" or attrName == "hydrate":
          # Flush accumulated static text, emit hydration key
          pendingOps.add(StreamOp(kind: sokStatic, text: openTag))
          openTag = ""
          pendingOps.add(StreamOp(kind: sokHydrationKey))
        elif not isDynamic(attrVal):
          # Static attribute — concatenate into the opening tag string
          # Escape the value at compile time for HTML attribute context
          openTag.add(" " & attrName & "=\"" & escapeAttrCompileTime(attrVal.strVal) & "\"")
        else:
          # Dynamic attribute — flush static, add escaped attr
          openTag.add(" " & attrName & "=\"")
          pendingOps.add(StreamOp(kind: sokStatic, text: openTag))
          openTag = ""
          pendingOps.add(StreamOp(kind: sokEscapedAttr, expr: attrVal))
          openTag = "\""
      of nnkStmtList:
        childBody = arg
      of nnkCall, nnkCommand:
        if childBody == nil:
          childBody = newStmtList(arg)
        else:
          childBody.add(arg)
      else: discard

    if isVoid:
      openTag.add(" />")
      pendingOps.add(StreamOp(kind: sokStatic, text: openTag))
      for op in pendingOps:
        ops.add(op)
    else:
      openTag.add(">")
      pendingOps.add(StreamOp(kind: sokStatic, text: openTag))
      for op in pendingOps:
        ops.add(op)

      if childBody != nil:
        collectChildren(childBody, ops)

      ops.add(StreamOp(kind: sokStatic, text: "</" & htmlTag & ">"))

# ---------------------------------------------------------------------------
# Phase 2: Optimize — coalesce adjacent sokStatic ops
# ---------------------------------------------------------------------------

proc coalesce(ops: seq[StreamOp]): seq[StreamOp] {.compileTime.} =
  ## Merge adjacent sokStatic ops into one. Recurse into control flow.
  result = @[]
  var accum = ""

  for op in ops:
    if op.kind == sokStatic:
      accum.add(op.text)
    else:
      if accum.len > 0:
        result.add(StreamOp(kind: sokStatic, text: accum))
        accum = ""
      case op.kind
      of sokIf:
        var newBranches: seq[tuple[cond: NimNode, body: seq[StreamOp]]]
        for branch in op.ifBranches:
          newBranches.add((cond: branch.cond, body: coalesce(branch.body)))
        result.add(StreamOp(kind: sokIf, ifBranches: newBranches))
      of sokFor:
        result.add(StreamOp(kind: sokFor,
          forVars: op.forVars, forIter: op.forIter,
          forBody: coalesce(op.forBody)))
      of sokForIn:
        result.add(StreamOp(kind: sokForIn,
          seqExpr: op.seqExpr,
          forInBody: coalesce(op.forInBody)))
      of sokCase:
        var newBranches: seq[tuple[values: seq[NimNode], body: seq[StreamOp]]]
        for branch in op.caseOfBranches:
          newBranches.add((values: branch.values, body: coalesce(branch.body)))
        result.add(StreamOp(kind: sokCase,
          caseExpr: op.caseExpr,
          caseOfBranches: newBranches,
          caseElse: coalesce(op.caseElse)))
      else:
        result.add(op)

  if accum.len > 0:
    result.add(StreamOp(kind: sokStatic, text: accum))

# ---------------------------------------------------------------------------
# Phase 3: Emit AST from optimized ops
# ---------------------------------------------------------------------------

proc emit(ops: seq[StreamOp]; streamSym: NimNode;
    stmts: NimNode) {.compileTime.} =
  for op in ops:
    case op.kind
    of sokStatic:
      stmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newStrLitNode(op.text)))
    of sokEscapedHtml:
      stmts.add(newCall(ident"writeEscapedHtml", streamSym, op.expr))
    of sokEscapedAttr:
      stmts.add(newCall(ident"writeEscapedAttr", streamSym, op.expr))
    of sokRaw:
      stmts.add(newCall(newDotExpr(streamSym, ident"write"), op.expr))
    of sokHydrationKey:
      stmts.add(newCall(newDotExpr(streamSym, ident"write"),
        newCall(ident"ssrHydrationKey")))
    of sokNimStmt:
      stmts.add(op.stmt)
    of sokIf:
      var ifNode = newNimNode(nnkIfStmt)
      for branch in op.ifBranches:
        let branchStmts = newStmtList()
        emit(branch.body, streamSym, branchStmts)
        if branch.cond != nil:
          ifNode.add(newNimNode(nnkElifBranch).add(branch.cond, branchStmts))
        else:
          ifNode.add(newNimNode(nnkElse).add(branchStmts))
      stmts.add(ifNode)
    of sokFor:
      let forBody = newStmtList()
      emit(op.forBody, streamSym, forBody)
      var forNode = newNimNode(nnkForStmt)
      for v in op.forVars:
        forNode.add(v)
      forNode.add(op.forIter)
      forNode.add(forBody)
      stmts.add(forNode)
    of sokForIn:
      let loopBody = newStmtList()
      emit(op.forInBody, streamSym, loopBody)
      let forLoop = newNimNode(nnkForStmt).add(
        ident"index", ident"item", op.seqExpr, loopBody)
      stmts.add(forLoop)
    of sokCase:
      var caseNode = newNimNode(nnkCaseStmt)
      caseNode.add(op.caseExpr)
      for branch in op.caseOfBranches:
        let branchStmts = newStmtList()
        emit(branch.body, streamSym, branchStmts)
        var ofBranch = newNimNode(nnkOfBranch)
        for v in branch.values:
          ofBranch.add(v)
        ofBranch.add(branchStmts)
        caseNode.add(ofBranch)
      if op.caseElse.len > 0:
        let elseStmts = newStmtList()
        emit(op.caseElse, streamSym, elseStmts)
        caseNode.add(newNimNode(nnkElse).add(elseStmts))
      stmts.add(caseNode)

# ---------------------------------------------------------------------------
# Pipeline entry point
# ---------------------------------------------------------------------------

proc uiStreamImpl*(streamSym: NimNode; body: NimNode): NimNode {.compileTime.} =
  ## Streaming SSR codegen pipeline: DSL → collect → coalesce → emit.
  ## Adjacent static string writes are coalesced into a single write call
  ## at compile time.
  var ops: seq[StreamOp]

  case body.kind
  of nnkStmtList:
    if body.len == 1:
      collectNode(body[0], ops)
    else:
      ops.add(StreamOp(kind: sokStatic, text: "<div>"))
      for child in body:
        collectNode(child, ops)
      ops.add(StreamOp(kind: sokStatic, text: "</div>"))
  of nnkCall, nnkCommand:
    collectNode(body, ops)
  else:
    error("ui expects a DSL body block", body)

  let optimized = coalesce(ops)

  let stmts = newStmtList()
  emit(optimized, streamSym, stmts)
  result = newBlockStmt(stmts)

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
