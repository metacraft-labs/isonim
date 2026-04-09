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
# Client mode (renderer-based element creation)
# ---------------------------------------------------------------------------

proc processNode(rendererSym: NimNode; node: NimNode; stmts: NimNode): NimNode {.compileTime.}

proc processShowIf(rendererSym, parentSym: NimNode; children: NimNode;
                    idx: int; stmts: NimNode): int {.compileTime.}

proc processForIn(rendererSym, parentSym: NimNode; node: NimNode;
                  stmts: NimNode) {.compileTime.}

proc processChildren(rendererSym, parentSym: NimNode; body: NimNode; stmts: NimNode) {.compileTime.} =
  ## Process a statement list of DSL children.
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
    of nnkStmtList:
      processChildren(rendererSym, parentSym, child, stmts)
    else:
      # Pass through arbitrary Nim statements (let, var, if, etc.)
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
          # Static class attribute — expand Tailwind utilities to setStyle calls
          # on native platforms. On JS, pass through as setAttribute.
          when defined(js):
            stmts.add(newCall(
              newDotExpr(rendererSym, ident"setAttribute"),
              elSym, newStrLitNode("class"), attrVal))
          else:
            let classStr = attrVal.strVal
            let styles = expandTailwindClassesCompileTime(classStr)
            if styles.len > 0:
              for (prop, val) in styles:
                stmts.add(newCall(
                  newDotExpr(rendererSym, ident"setStyle"),
                  elSym, newStrLitNode(prop), newStrLitNode(val)))
            else:
              # No recognized utilities — pass through as attribute
              stmts.add(newCall(
                newDotExpr(rendererSym, ident"setAttribute"),
                elSym, newStrLitNode("class"), attrVal))
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
