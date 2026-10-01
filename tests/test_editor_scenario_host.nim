## Native production EditorVM host for official Harbor Scenario-Format acceptance.
## This is a real HTTP/SSE host adapter, not NativeBrowserAgentClient's no-op or
## FakeClient. Requests traverse the real editor daemon/nim-agents/Harbor/SQLite
## and official Rust ACP process. Control deliveries call the production typed
## dispatcher; source jobs use the SAME launcher/durable native compiler worker
## as browser production. Only model choices/responses are scripted by YAML.
## Native capture is compiled SSR text/html; mounted DOM/keyboard/focus/highlight
## and PNG assertions belong exclusively to the companion real browser runner.
## SSE uses an unbuffered real socket: Nim2.2.4 AsyncHttpClient's close-delimited
## body reader fills 4000-byte blocks, withholding short live frames until EOF.
import std/[asyncdispatch, asyncnet, asynchttpserver, httpclient, json, net, os, strutils, tables, uri]
import isonim/viewmodel
import isonim/core/signals
import isonim/editor/[types, viewmodels, workspace, source_catalog, control, agent_harbor]
import isonim/editor/design_review/editor_agent_adapter

when declared(EditorScenarioProtocolTest):
  var origin = ""
else:
  var origin = paramStr(1)
let bootstrap = getEnv("ISONIM_EDITOR_BROWSER_BOOTSTRAP")
let base = newEditorWorkspace("Source project", @[], id = "source-project",
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let vm = createEditorVM(base)
var scope: JsonNode
var browserToken: string
var sessions = initTable[string, string]()
var transportErrors: seq[string]
var pollsPaused = false

proc request(url: string; data: JsonNode; token = ""): Future[JsonNode] {.async.} =
  let client = newAsyncHttpClient()
  defer: client.close()
  client.headers = newHttpHeaders({"Content-Type": "application/json", "X-IsoNim-Control": token})
  let response = await client.request(url, httpMethod = HttpPost, body = $data)
  let body = await response.body()
  if int(response.code) notin 200..299: raise newException(IOError, "HTTP " & $response.code & ": " & body)
  return parseJson(body)

proc rpc(methodName: string; params: JsonNode): Future[JsonNode] {.async.} =
  return await request(origin & "/api/editor/rpc", %*{"jsonrpc":"2.0", "id":1,
    "method":methodName, "params":params}, browserToken)

proc applyCatalog(data: JsonNode) =
  if data{"manifest", "workspace"}.getStr() != vm.workspaceId: raise newException(ValueError, "Workspace mismatch")
  vm.refreshWorkspaceCatalog(sourceCatalogWorkspace(data["catalog"], data["manifest"], base))
  vm.controlSourceFixtures = sourceFixtures(data["manifest"])
  vm.sourceAdapterReady.val = true

proc sourceJob(payload: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) {.async.} =
  vm.workspaceEditStage.val = wesCompiling
  try:
    var params = scope.copy()
    params["operationId"] = payload["commandId"]
    let data = await request(origin & "/api/editor/source/operation", params, browserToken)
    if data{"ok"}.getBool():
      applyCatalog(data)
      vm.workspaceEditStage.val = wesClean
      vm.workspaceEditDiagnostics.val = @[]
    else:
      vm.workspaceEditStage.val = wesFailed
      vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(kind: wedCompileFailed, message: data{"diagnostic"}.getStr())]
    done(data{"ok"}.getBool(), data)
  except CatchableError as error:
    vm.workspaceEditStage.val = wesFailed
    done(false, %*{"ok":false,"diagnostic":error.msg})

proc prompt(chat: AgentChatVM; text: string) {.async.} =
  let socket = newAsyncSocket(buffered = false)
  defer: socket.close()
  var accepted = false
  try:
    var sid = sessions.getOrDefault(chat.controlConversationId.val)
    if sid.len == 0:
      let created = await request(origin & "/api/agent/sessions", %*{"editor":scope}, browserToken)
      sid = created["sessionId"].getStr()
      sessions[sid] = sid
      chat.controlConversationId.val = sid
      chat.cancelSupported.val = created{"sessionCapabilities", "cancelTurn"}.getBool()
    let endpoint = parseUri(origin)
    if endpoint.scheme != "http": raise newException(IOError,"Native host requires private HTTP endpoint")
    await socket.connect(endpoint.hostname, Port(parseInt(endpoint.port)))
    let body = $(%*{"sessionId":sid,"messages":[{"role":"user","content":[{"type":"text","text":text}]}]})
    await socket.send("POST /api/agent/prompts HTTP/1.1\r\nHost: " & endpoint.hostname & ":" & endpoint.port &
      "\r\nContent-Type: application/json\r\nAccept: text/event-stream\r\nConnection: close\r\nContent-Length: " & $body.len & "\r\n\r\n" & body)
    var headers = ""
    while not headers.endsWith("\r\n\r\n"):
      let byte = await socket.recv(1)
      if byte.len == 0: raise newException(IOError,"HTTP EOF before prompt headers")
      headers.add byte
      if headers.len > 65536: raise newException(IOError,"Oversize HTTP headers")
    let statusLine = headers.splitLines()[0].splitWhitespace()
    if statusLine.len < 2 or not statusLine[0].startsWith("HTTP/"):
      raise newException(IOError,"Malformed prompt HTTP status")
    let status = parseInt(statusLine[1])
    if status notin 200..299: raise newException(IOError,"Prompt HTTP " & $status)
    accepted = true
    var chunked = false
    for header in headers.splitLines():
      let lower = header.toLowerAscii()
      if lower.startsWith("transfer-encoding:"):
        chunked = lower.contains("chunked")
    var pending = ""
    var wire = ""
    var chunkRemaining = -1
    var transferEnded = false
    var terminal = false
    while not terminal and not transferEnded:
      let chunk = await socket.recv(65536)
      if chunk.len == 0: break
      if chunked:
        wire.add chunk
        while true:
          if chunkRemaining < 0:
            let lineEnd = wire.find("\r\n")
            if lineEnd < 0: break
            chunkRemaining = parseHexInt(wire[0..<lineEnd].split(';')[0])
            wire = wire[lineEnd+2..^1]
            if chunkRemaining == 0:
              transferEnded = true
              break
          if wire.len < chunkRemaining+2: break
          if wire[chunkRemaining..<chunkRemaining+2] != "\r\n":
            raise newException(IOError,"Malformed HTTP chunk terminator")
          pending.add wire[0..<chunkRemaining]
          wire = wire[chunkRemaining+2..^1]
          chunkRemaining = -1
      else: pending.add chunk
      while not terminal:
        let lfEnd = pending.find("\n\n")
        let crlfEnd = pending.find("\r\n\r\n")
        if lfEnd < 0 and crlfEnd < 0: break
        let useCrlf = crlfEnd >= 0 and (lfEnd < 0 or crlfEnd < lfEnd)
        let finish = if useCrlf: crlfEnd else: lfEnd
        let frame = pending[0..<finish]
        pending = pending[finish+(if useCrlf: 4 else: 2)..^1]
        var event = "session/update"
        var data = ""
        for line in frame.splitLines():
          if line.startsWith("event:"): event = line[6..^1].strip()
          elif line.startsWith("data:"):
            if data.len > 0: data.add "\n"
            data.add line[5..^1].strip()
        echo "SSE ", event, " ", data
        if event == "end":
          let reason = parseJson(data){"stopReason"}.getStr()
          if reason notin ["end_turn","cancelled","max_tokens","error"]: raise newException(ValueError,"Invalid terminal reason")
          terminal = true
          chat.promptInFlight = false
          chat.stopReason.val = reason
          chat.connectionState.val = if reason == "error": "error" else: "completed"
          chat.sessionStatus.val = if reason == "error": asError else: asReady
          if reason == "error": transportErrors.add "Provider returned terminal error"
        elif event == "error": raise newException(IOError,data)
        elif data.len > 0: chat.applyAgentEvent(agentEventFromSse(data))
    if not terminal: raise newException(IOError,"SSE EOF without terminal; provider state unknown")
  except CatchableError as error:
    transportErrors.add error.msg
    # Match the production browser's interrupted-stream contract: a successful
    # HTTP admission followed by EOF is not evidence of provider completion.
    chat.promptInFlight = accepted
    chat.connectionState.val = if accepted: "interrupted" else: "failed"
    if not accepted and chat.inputText.val.len == 0:
      chat.inputText.val = chat.pendingPromptText
    chat.sessionStatus.val = asError

proc configure(chat: AgentChatVM) =
  chat.configureAgentAdapters(proc(text: string; context: AgentPromptContext): bool =
    if chat.promptInFlight: return false
    chat.promptInFlight = true
    asyncCheck prompt(chat,text)
    true, nil, absAgentHarbor)
  chat.asyncAgentAdapter = true
vm.configureChat = configure
configure(vm.chat)
vm.controlAsyncCommandAdapter = proc(payload: JsonNode; done: proc(ok: bool; data: JsonNode) {.closure.}) =
  asyncCheck sourceJob(payload,done)

vm.controlCaptureAdapter = proc(): JsonNode =
  let rendered = vm.preview.hook(vm.selectedStory.val, pbWeb)
  %*{"ready":rendered.status == ppsRendered,"format":"text/html",
    "documentHtml":rendered.documentHtml,"storyId":controlStoryId(vm.selectedStory.val),
    "captureBoundary":"compiled-SSR","previewGeneration":vm.livePreviewReloadGeneration.val}

proc pollHost() {.async.} =
  while true:
    if pollsPaused:
      await sleepAsync(30)
      continue
    var params = scope.copy()
    params["state"] = vm.controlSnapshot()
    let reply = await rpc("editor.poll",params)
    if reply{"error"} != nil: raise newException(IOError,$reply["error"])
    for delivery in reply{"result","commands"}:
      let applied = vm.deliverControlOperation(delivery)
      var ack = scope.copy()
      ack["operation"] = applied
      ack["state"] = vm.controlSnapshot()
      discard await rpc("editor.ack",ack)
    for applied in vm.controlActivity.val:
      if applied{"status"}.getStr() in ["applied","failed","rejected"]:
        var ack = scope.copy()
        ack["operation"] = applied
        ack["state"] = vm.controlSnapshot()
        discard await rpc("editor.ack",ack)
    await sleepAsync(30)

proc handle(req: Request) {.async, gcsafe.} =
  {.cast(gcsafe).}:
    let input = if req.body.len == 0: newJObject() else: parseJson(req.body)
    case input{"action"}.getStr()
    of "active-status":
      # Observe the same production flags without serializing growing tool logs.
      await req.respond(Http200,$(%*{"id":vm.activeChatId.val,
        "busy":vm.chat.promptInFlight,"backend":vm.chat.controlConversationId.val}))
      return
    of "send":
      vm.chat.inputText.val = input["text"].getStr()
      discard vm.sendAgentPrompt()
    of "draft": vm.chat.inputText.val = input["text"].getStr()
    of "new-chat": discard vm.createNewChat()
    of "switch": discard vm.switchToChat(input["id"].getStr())
    of "approval": vm.agentControlApproval.val = input["value"].getBool()
    of "pause-polls": pollsPaused = input["value"].getBool()
    of "source-permission":
      var permissions = vm.workspacePermissions.val
      permissions.writeSource = input["value"].getBool()
      vm.workspacePermissions.val = permissions
    of "decision":
      var params = scope.copy()
      params["operationId"] = input["id"]
      params["approve"] = input["value"]
      let approved = await rpc("editor.approve",params)
      discard vm.deliverControlOperation(approved["result"])
    else: discard
    var chats = newJArray()
    for session in vm.chats.val:
      var messages = newJArray()
      for message in session.vm.messages.val: messages.add %*{"kind": $message.kind,"text":message.text}
      chats.add %*{"id":session.id,"draft":session.vm.inputText.val,"busy":session.vm.promptInFlight,
        "backend":session.vm.controlConversationId.val,"messages":messages,"tools":session.vm.toolCalls.val,
        "placeholdersDismissed":session.vm.placeholdersDismissed.val}
    await req.respond(Http200,$(%*{"state":vm.controlSnapshot(),"active":vm.activeChatId.val,"chats":chats,"errors":transportErrors}))

proc main() {.async.} =
  let client = newAsyncHttpClient()
  let initial = await client.getContent(origin & "/api/editor/source/catalog")
  client.close()
  applyCatalog(parseJson(initial))
  let registered = await request(origin & "/api/editor/rpc", %*{"jsonrpc":"2.0","id":1,"method":"editor.register",
    "params":{"workspace":vm.workspaceId,"state":vm.controlSnapshot()}},bootstrap)
  let registration = registered["result"]
  browserToken = registration["browserToken"].getStr()
  scope = %*{"workspace":registration["workspace"],"instance":registration["instance"],"epoch":registration["epoch"]}
  vm.controlInstanceId = registration["instance"].getStr()
  vm.controlConnected = true
  # Private test-owned registration file, never transcript or stdout.
  writeFile(paramStr(2),$registration)
  setFilePermissions(paramStr(2),{fpUserRead,fpUserWrite})
  asyncCheck pollHost()
  let server = newAsyncHttpServer()
  server.listen(Port(0),"127.0.0.1")
  echo "HOST_READY " & $server.getPort().uint16
  while true: await server.acceptRequest(handle)
when not declared(EditorScenarioProtocolTest):
  waitFor main()
