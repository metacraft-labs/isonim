## Structural element identities. Source positions are lookup metadata only;
## neither line numbers nor compilation backend contribute to an identity.
import std/[macros, os, strutils, tables, json]

const stableIdsEnabled* = defined(isonimStableIds)
when stableIdsEnabled:
  import ./transform
const iidProjectRoot* {.strdefine.} = ""
const iidManifestDir* {.strdefine.} = ""
var callScopes {.compileTime.}: Table[string, string]
var scopeIdentities {.compileTime.}: Table[string, string]
var scopePositions {.compileTime.}: Table[string, string]
var identities {.compileTime.}: Table[string, string]
var emitted {.compileTime.}: Table[string, string]
var emittedPositions {.compileTime.}: Table[string, string]

proc stableIid*(identity: string): string {.compileTime.} =
  ## FNV-1a 64, encoded as the low 60 bits in twelve base32 characters.
  ## Fixed arithmetic makes C and JS compilation produce identical ids.
  var h = 14695981039346656037'u64
  for c in identity:
    h = (h xor uint64(ord(c))) * 1099511628211'u64
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567"
  result = newString(12)
  for i in countdown(11, 0):
    result[i] = alphabet[int(h and 31)]
    h = h shr 5

proc position(node: NimNode): string {.compileTime.} = node.lineInfo

proc relativeSource(file, root: string): string {.compileTime.} =
  # std/os.relativePath deliberately refuses the JS target even in the VM.
  # This is lexical source metadata; no filesystem canonicalization is needed.
  let f = file.replace('\\', '/').split('/')
  let r = root.replace('\\', '/').strip(leading = false, chars = {'/'}).split('/')
  var common = 0
  while common < min(f.len, r.len) and f[common] == r[common]: inc common
  var parts: seq[string]
  for i in common ..< r.len: parts.add("..")
  for i in common ..< f.len: parts.add(f[i])
  parts.join("/")

proc sourceComponent(body: NimNode): string {.compileTime.} =
  # Untyped DSL macros cannot query an enclosing proc symbol. Locate that
  # declaration in the original syntax instead; positions select syntax but
  # do not enter the identity. Templates retain their declaration identity.
  let info = body.lineInfoObj
  let root = if iidProjectRoot.len > 0: iidProjectRoot else: getProjectPath()
  let file = relativeSource(info.filename, root)
  let source = parseStmt(readFile(info.filename))
  var bestLine = -1
  var qualified = "module"
  var blockOrdinal = 0
  var counters: Table[string, int]
  proc walk(n: NimNode; parent: string) =
    var name = parent
    if n.kind in {nnkProcDef, nnkFuncDef, nnkMethodDef, nnkTemplateDef, nnkMacroDef}:
      name = parent & "." & n[0].repr.replace("*", "")
      # The last token's line bounds the enclosing declaration even if
      # parseStmt gives its parent only the declaration's starting line.
      proc lastLine(x: NimNode): int =
        result = x.lineInfoObj.line
        for c in x: result = max(result, lastLine(c))
      if n.lineInfoObj.line <= info.line and lastLine(n) >= info.line and
          n.lineInfoObj.line > bestLine:
        bestLine = n.lineInfoObj.line
        qualified = name
    if n.kind in {nnkCall, nnkCommand} and n.len > 0 and
        n[0].kind == nnkIdent and n[0].strVal in ["ui", "uiWrite", "uiString", "isomorphicUi"]:
      let index = counters.getOrDefault(name)
      counters[name] = index + 1
      proc lastLine(x: NimNode): int =
        result = x.lineInfoObj.line
        for c in x: result = max(result, lastLine(c))
      if n.lineInfoObj.line <= info.line and lastLine(n) >= info.line:
        blockOrdinal = index
    for child in n: walk(child, name)
  walk(source, "")
  file & ":" & qualified & "/ui:" & $blockOrdinal

var moduleFragments {.compileTime.}: Table[string, JsonNode]

proc writeIidFragment(iid, file, component, tag: string; line, col: int) {.compileTime.} =
  ## Called only from generated static blocks: metadata cannot survive into
  ## either executable. Each module starts from a fresh compiler-owned object.
  let fragment = iidManifestDir / (stableIid(file) & ".json")
  if fragment notin moduleFragments: moduleFragments[fragment] = newJObject()
  let metadata = %*{"file": file, "line": line, "col": col,
    "component": component, "tag": tag}
  if moduleFragments[fragment].hasKey(iid) and moduleFragments[fragment][iid] != metadata:
    error("duplicate stable iid: " & iid)
  moduleFragments[fragment][iid] = metadata
  writeFile(fragment, $moduleFragments[fragment])

proc prepareStableIds*(body: NimNode; isElementCall: proc(name: string; node: NimNode): bool;
    attributeName: proc(node: NimNode): string): NimNode {.compileTime.} =
  ## Index a DSL block before code generation and return its static manifest
  ## registrations. The caller supplies the DSL's element predicate so identity
  ## discovery follows exactly the same vocabulary as its renderer.
  result = newStmtList()
  when stableIdsEnabled:
    var registrations = newStmtList()
    identities.clear()
    callScopes.clear()
    let component = sourceComponent(body)
    proc walk(n: NimNode; path: string) =
      var ordinal = 0
      for index in 0 ..< n.len:
        var child = n[index]
        # Only structural bodies are DSL. Attribute expressions (including
        # handlers), conditions and loop iterators are ordinary Nim code.
        if child.kind == nnkExprEqExpr: continue
        if n.kind in {nnkForStmt, nnkWhileStmt, nnkBlockStmt, nnkElifBranch,
            nnkOfBranch, nnkExceptBranch} and index != n.len - 1: continue
        if n.kind == nnkCaseStmt and index == 0: continue
        if n.kind in {nnkCall, nnkCommand} and index == 0: continue
        if n.kind == nnkStmtList and child.kind == nnkIdent and child.eqIdent("input"):
          # Normalize the bare void-control spelling into the ordinary
          # element path, so all three renderers stamp it consistently.
          child = newCall(child)
          child.copyLineInfo(n[index])
          n[index] = child
        if child.kind in {nnkCall, nnkCommand} and child.len > 0 and
            child[0].kind == nnkIdent and child[0].strVal in
              ["ui", "uiWrite", "uiString", "isomorphicUi"]:
          continue # A nested DSL macro owns its own component/block identity.
        var nextPath = path
        let element = child.kind in {nnkCall, nnkCommand} and child.len > 0 and
          child[0].kind == nnkIdent and isElementCall(child[0].strVal, child)
        let expressionSlot = child.kind in {nnkCall, nnkCommand} and child.len > 0 and
          (child[0].eqIdent("raw") or (not element and not child[0].eqIdent("text")))
        if expressionSlot:
          let scopeIdentity = component & path & "/call:" & $ordinal
          let scope = stableIid(scopeIdentity)
          if scope in scopeIdentities and (scopeIdentities[scope] != scopeIdentity or
              scopePositions[scope] != position(child)):
            error("stable caller-scope collision: " & scope, child)
          scopeIdentities[scope] = scopeIdentity
          scopePositions[scope] = position(child)
          callScopes[position(child)] = scope
          inc ordinal
          continue # The expression's implementation owns its own DSL blocks.
        if element:
          var segment = resolveTagName(child[0].strVal) & ":" & $ordinal
          inc ordinal
          for arg in child:
            # Generated identities are authoritative in every renderer, even
            # when an element only gains a handler in a later source edit.
            # HTML names are ASCII case insensitive, including setAttribute.
            if arg.kind == nnkExprEqExpr and attributeName(arg[0]).toLowerAscii == "data-iid":
              error("data-iid is reserved when isonimStableIds is enabled", arg)
            if arg.kind == nnkExprEqExpr and attributeName(arg[0]) == "key":
              if arg[1].kind notin {nnkStrLit..nnkTripleStrLit}:
                error("stable element key must be a string literal", arg)
              segment = resolveTagName(child[0].strVal) & ":key=" & arg[1].strVal
          nextPath = path & "/" & segment
          var stamp = resolveTagName(child[0].strVal) in ["input", "select", "textarea", "button"]
          for arg in child:
            if arg.kind == nnkExprEqExpr and isEventHandler(attributeName(arg[0])): stamp = true
          if stamp:
            let identity = component & nextPath
            let iid = stableIid(identity)
            if iid in emitted and (emitted[iid] != identity or emittedPositions[iid] != position(child)):
              error("stable iid collision: " & iid, child)
            emitted[iid] = identity
            emittedPositions[iid] = position(child)
            identities[position(child)] = iid
            if iidManifestDir.len > 0:
              let info = child[0].lineInfoObj
              let root = if iidProjectRoot.len > 0: iidProjectRoot else: getProjectPath()
              registrations.add(newCall(bindSym"writeIidFragment", newLit(iid),
                newLit(relativeSource(info.filename, root)),
                newLit(component), newLit(resolveTagName(child[0].strVal)),
                newLit(info.line), newLit(info.column)))
        elif child.kind in {nnkIfStmt, nnkWhenStmt, nnkCaseStmt, nnkElifBranch, nnkElse, nnkOfBranch, nnkForStmt, nnkWhileStmt, nnkBlockStmt, nnkTryStmt, nnkExceptBranch, nnkFinally}:
          nextPath = path & "/branch:" & $ordinal
          inc ordinal
        if element or child.kind in {nnkStmtList, nnkIfStmt, nnkWhenStmt,
            nnkCaseStmt, nnkElifBranch, nnkElse, nnkOfBranch, nnkForStmt,
            nnkWhileStmt, nnkBlockStmt, nnkTryStmt, nnkExceptBranch, nnkFinally}:
          walk(child, nextPath)
    walk(body, "")
    if registrations.len > 0:
      result.add(newNimNode(nnkStaticStmt).add(registrations))

proc elementIid*(node: NimNode): string {.compileTime.} =
  when stableIdsEnabled: identities.getOrDefault(position(node))
  else: ""

when stableIdsEnabled:
  when defined(js):
    var stableKeyPath* = ""
    var stableInstancePath = ""
    var stableSeen: Table[string, bool]
    var stableRenderActive = false
  else:
    var stableKeyPath* {.threadvar.}: string
    var stableInstancePath {.threadvar.}: string
    var stableSeen {.threadvar.}: Table[string, bool]
    var stableRenderActive {.threadvar.}: bool
  type StableIdScope* = object
    instancePath, keyPath: string
  type StableRenderScope* = object
    seen: Table[string, bool]
    active: bool

  proc captureStableScope*(): StableIdScope =
    ## Reactive list callbacks retain the caller's identity scope on later runs.
    StableIdScope(instancePath: stableInstancePath, keyPath: stableKeyPath)

  template withStableScope*(scope: StableIdScope; body: untyped): untyped =
    block:
      let previous = captureStableScope()
      stableInstancePath = scope.instancePath
      stableKeyPath = scope.keyPath
      try: body
      finally:
        stableInstancePath = previous.instancePath
        stableKeyPath = previous.keyPath

  template withStableInstance*(scope: string; body: untyped): untyped =
    block:
      let previous = stableInstancePath
      stableInstancePath.add("@" & scope)
      try: body
      finally: stableInstancePath = previous

  proc beginStableRender*(): StableRenderScope =
    ## A render boundary owns collision detection; independent renders do not
    ## share claims, including on concurrent native server threads.
    result = StableRenderScope(seen: stableSeen, active: stableRenderActive)
    stableSeen = initTable[string, bool]()
    stableRenderActive = true

  proc endStableRender*(previous: StableRenderScope) =
    stableSeen = previous.seen
    stableRenderActive = previous.active

  template withStableKey*(key: string; body: untyped): untyped =
    ## Share a reconcile-key scope with SSR loops. Escape separators so
    ## nested keys cannot alias one another.
    block:
      let priorKey = stableKeyPath
      stableKeyPath.add("#" & key.replace("%", "%25").replace("#", "%23"))
      try:
        body
      finally:
        stableKeyPath = priorKey

  proc runtimeIid*(iid: string): string =
    ## The key context is restored in finally by keyed renderers, including
    ## nested lists and exceptions. No state exists in ordinary builds.
    iid & stableInstancePath & stableKeyPath

  proc ssrRuntimeIid*(iid: string): string =
    ## Each server target must be unique within its hydratable render.
    result = runtimeIid(iid)
    if stableRenderActive:
      if result in stableSeen:
        raise newException(ValueError, "duplicate live stable iid: " & result)
      stableSeen[result] = true
else:
  template withStableInstance*(scope: string; body: untyped): untyped = body
  template withStableKey*(key: string; body: untyped): untyped = body
  template runtimeIid*(iid: string): string = iid
  template ssrRuntimeIid*(iid: string): string = iid

proc scopedInstanceExpr*(site, expression: NimNode): NimNode {.compileTime.} =
  ## Evaluate a reusable component expression within its structural caller slot.
  ## The scope literal contains only a hash, never source metadata.
  when stableIdsEnabled:
    let scope = callScopes.getOrDefault(position(site))
    if scope.len > 0:
      return newCall(bindSym"withStableInstance", newLit(scope), expression)
  expression
