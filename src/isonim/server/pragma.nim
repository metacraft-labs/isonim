## isonim/server/pragma.nim
##
## The {.server.} macro — marks a proc as a server function.
##
## On C target: the proc body compiles normally, and an RPC handler is
## registered at "/api/<procname>" during module init.
##
## On JS target: the proc body is replaced with a synchronous RPC call
## that serializes arguments to JSON, fetches from the server endpoint,
## and deserializes the result.
##
## Usage:
##   proc getUser(id: int): User {.server.} =
##     db.query("SELECT * FROM users WHERE id = ?", id)

import std/[macros, json]

proc endpointPath(procName: string): string =
  ## Derive the RPC endpoint path from the proc name.
  ## For M3, this is simply "/api/<procname>".
  "/api/" & procName

macro server*(prc: untyped): untyped =
  ## Marks a proc as a server function.
  ## On C target: compiles the proc body normally and registers an RPC handler.
  ## On JS target: replaces the body with an RPC fetch call.

  prc.expectKind(nnkProcDef)

  let procName = prc[0]
  let procNameStr = $procName
  let params = prc[3]       # formal params node
  let origBody = prc[6]     # original proc body

  # Extract return type (params[0] is the return type, can be empty)
  let returnType = params[0]
  if returnType.kind == nnkEmpty:
    error("Server functions must have a return type", prc)

  let endpoint = endpointPath(procNameStr)
  let endpointLit = newLit(endpoint)

  # Collect parameter names and types (skip params[0] which is return type)
  var paramNames: seq[NimNode] = @[]
  var paramTypes: seq[NimNode] = @[]
  for i in 1 ..< params.len:
    let identDefs = params[i]
    let pType = identDefs[^2]  # type is second to last
    for j in 0 ..< identDefs.len - 2:
      paramNames.add(identDefs[j])
      paramTypes.add(pType)

  # --- Build the JS body ---
  # let argsJson = %*{"param1": param1, "param2": param2, ...}
  # let responseJson = rpcFetchSync(endpoint, argsJson)
  # result = to(responseJson, ReturnType)
  var jsonPairs = newNimNode(nnkTableConstr)
  for i in 0 ..< paramNames.len:
    jsonPairs.add(newColonExpr(newLit($paramNames[i]), newCall(ident"%", paramNames[i])))

  let argsJsonExpr = newCall(bindSym"%*", jsonPairs)

  let jsBody = quote do:
    let argsJson = `argsJsonExpr`
    let responseJson = rpcFetchSync(`endpointLit`, argsJson)
    result = to(responseJson, typeof(result))

  # --- Build the C-side RPC handler registration ---
  # We build a handler proc that takes JsonNode args, extracts params,
  # calls the original body inline, and returns the JSON result.
  #
  # To avoid hygiene issues with `quote do`, we build the handler proc
  # AST manually.

  let implName = ident(procNameStr & "_serverImpl")

  # Build impl proc: same params, same return type, original body, no pragmas
  var implProc = prc.copy()
  implProc[0] = implName
  implProc[6] = origBody
  implProc[4] = newEmptyNode()  # clear pragmas

  # Build handler body manually:
  #   let param1 = to(argsNode["param1"], ParamType)
  #   ...
  #   result = %(implName(param1, param2, ...))
  let argsIdent = ident("argsNode")
  var handlerStmts = newStmtList()
  var implCallArgs: seq[NimNode] = @[]

  for i in 0 ..< paramNames.len:
    let localName = ident("p_" & $paramNames[i])
    let pType = paramTypes[i]
    let pNameStr = newLit($paramNames[i])
    handlerStmts.add(
      newLetStmt(localName,
        newCall(ident"to", newNimNode(nnkBracketExpr).add(argsIdent, pNameStr), pType))
    )
    implCallArgs.add(localName)

  var implCall = newCall(implName)
  for arg in implCallArgs:
    implCall.add(arg)

  handlerStmts.add(
    newAssignment(ident"result", newCall(bindSym"%", implCall))
  )

  # Build handler lambda: proc(argsNode: JsonNode): JsonNode = ...
  let handlerLambda = newProc(
    name = newEmptyNode(),
    params = [
      ident"JsonNode",
      newIdentDefs(argsIdent, ident"JsonNode"),
    ],
    body = handlerStmts,
    procType = nnkLambda
  )

  # --- Build the public proc with when/else body ---
  var publicProc = prc.copy()
  publicProc[4] = newEmptyNode()  # clear pragmas

  let whenStmt = newNimNode(nnkWhenStmt).add(
    newNimNode(nnkElifBranch).add(
      newCall(ident"defined", ident"js"),
      newStmtList(jsBody)
    ),
    newNimNode(nnkElse).add(
      newStmtList(origBody)
    )
  )
  publicProc[6] = whenStmt

  # --- Assemble the output ---
  result = newStmtList()

  # Emit the impl proc (C only, for handler dispatch)
  result.add(
    newNimNode(nnkWhenStmt).add(
      newNimNode(nnkElifBranch).add(
        newCall(ident"not", newCall(ident"defined", ident"js")),
        newStmtList(implProc)
      )
    )
  )

  # Emit the public proc
  result.add(publicProc)

  # Emit the registration (C only)
  result.add(
    newNimNode(nnkWhenStmt).add(
      newNimNode(nnkElifBranch).add(
        newCall(ident"not", newCall(ident"defined", ident"js")),
        newStmtList(
          newCall(ident"registerRpc", endpointLit, handlerLambda)
        )
      )
    )
  )
