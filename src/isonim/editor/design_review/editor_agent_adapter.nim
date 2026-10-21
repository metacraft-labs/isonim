## Phase C — wire the editor's ``AgentChatVM`` to the daemon's
## ``/api/agent/*`` routes.
##
## This module installs an ``AgentPromptAdapter`` + ``AgentCancelAdapter``
## that:
##
##   1. On first prompt, mint a session via
##      ``POST /api/agent/sessions`` (the session id is cached on the
##      client for re-use).
##   2. ``POST /api/agent/prompts`` and stream ``session/update``
##      events back, translating each to an :type:`AgentEvent` and
##      pushing it through ``agent_harbor.applyAgentEvent`` so the
##      ``AgentChatVM`` signals update reactively.
##   3. Track ``connectionState`` reactively: ``connecting`` while
##      creating a session, ``streaming`` mid-prompt, ``ready`` once
##      ``event: end`` arrives, ``failed`` on transport error.
##
## VM tests inject the ``BrowserAgentClient`` directly via
## :proc:`configureAgentAdaptersWithClient` and skip the daemon URL
## resolution.  Production code path is
## :proc:`configureDaemonAgentAdapters` which resolves the daemon URL
## via :proc:`editor_daemon_url.resolveDaemonUrl` and then delegates
## to :proc:`configureAgentAdaptersWithClient`.

import std/[json, jsonutils]

import nim_agents
import isonim/core/signals
import isonim/editor/agent_harbor
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/viewmodel

import ./browser_agent_client
import ./editor_daemon_url

# --------------------------------------------------------------------------- #
#  SSE payload → AgentEvent.                                                  #
# --------------------------------------------------------------------------- #

proc agentEventFromSseJson*(node: JsonNode): AgentEvent =
  ## Decode one ``session/update`` JSON envelope (as produced by the
  ## daemon's ``sessionUpdateJson``) into an :type:`AgentEvent`.
  ## Mirrors :proc:`nim_agents.readAgentEvents`'s ACP branch but
  ## operates on a parsed ``JsonNode`` instead of a transport drain.
  if node.hasKey("kind"):
    return nim_agents.agentEventFromJson(node)
  result.sessionId = node{"sessionId"}.getStr("")
  result.raw = node
  let update = node{"update"}
  if update == nil:
    result.kind = aekStatus
    return
  let kindText = update{"sessionUpdate"}.getStr("custom")
  case kindText
  of "agent_message_chunk":
    result.kind = aekMessageChunk
    let content = update{"content"}
    if content != nil:
      result.text = content{"text"}.getStr("")
  of "agent_thought_chunk":
    result.kind = aekThoughtChunk
    let content = update{"content"}
    if content != nil:
      result.text = content{"text"}.getStr("")
  of "tool_call":
    result.kind = aekToolCall
    result.toolCallId = update{"toolCallId"}.getStr("")
    result.toolName = update{"title"}.getStr("")
    result.status = update{"status"}.getStr("")
  of "tool_call_update":
    result.kind = aekToolCallUpdate
    result.toolCallId = update{"toolCallId"}.getStr("")
    result.status = update{"status"}.getStr("")
  of "status":
    result.kind = aekStatus
    result.status = update{"status"}.getStr("")
  else:
    result.kind = aekStatus

proc agentEventFromSse*(payload: string): AgentEvent =
  ## Convenience wrapper that parses ``payload`` (the SSE ``data:``
  ## body) into a :type:`AgentEvent`.  Malformed payloads collapse to
  ## a benign ``aekStatus`` event so the stream keeps making progress.
  try:
    return agentEventFromSseJson(parseJson(payload))
  except JsonParsingError:
    result.kind = aekStatus
    result.status = "malformed_payload"

# --------------------------------------------------------------------------- #
#  Adapter installation.                                                      #
# --------------------------------------------------------------------------- #

proc agentPromptContextJson*(context: AgentPromptContext): JsonNode =
  ## Preserve every supported typed field. Human-facing enum metadata is named,
  ## avoiding ordinal values that lose platform/backend meaning on the wire.
  result = context.toJson
  result["platform"] = %($context.platform)
  result["backend"] = %($context.backend)

proc installAdapterCallbacks*(client: BrowserAgentClient; chat: AgentChatVM;
    generation = -1) =
  ## Wire ``client.onUpdate`` / ``onEnd`` / ``onError`` to push
  ## :type:`AgentEvent` instances through ``applyAgentEvent``.  Exposed
  ## so the VM tests can call this against a fake client.
  let capturedChat = chat
  client.onUpdate = proc(payload: cstring) {.closure.} =
    if client.closed or (generation >= 0 and capturedChat.promptGeneration != generation): return
    let evt = agentEventFromSse($payload)
    capturedChat.applyAgentEvent(evt)
  client.onEnd = proc(stopReason: cstring) {.closure.} =
    if client.closed or (generation >= 0 and capturedChat.promptGeneration != generation): return
    capturedChat.promptInFlight = false
    if not capturedChat.promptAdmitted and capturedChat.inputText.val.len == 0:
      capturedChat.inputText.val = capturedChat.pendingPromptText
    if capturedChat.promptAdmitted: capturedChat.pendingPromptText = ""
    capturedChat.stopReason.val = $stopReason
    capturedChat.sessionStatus.val = asReady
    if $stopReason == "cancelled":
      capturedChat.settleAgentReply(aekCancelled)
      capturedChat.connectionState.val = $acsCancelled
    elif $stopReason == "error":
      capturedChat.settleAgentReply(aekError)
      capturedChat.connectionState.val = $acsError
      capturedChat.sessionStatus.val = asError
    else:
      capturedChat.settleAgentReply(aekCompleted)
      capturedChat.connectionState.val = $acsCompleted
  client.onInterrupted = proc(message: cstring) {.closure.} =
    if client.closed or (generation >= 0 and capturedChat.promptGeneration != generation): return
    # EOF is not evidence that the backend turn ended. Keep prompt admission
    # blocked while allowing explicit chat closure through the normal adapter.
    capturedChat.promptInFlight = true
    capturedChat.connectionState.val = "interrupted"
    capturedChat.sessionStatus.val = asError
    capturedChat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
      result = prev
      result.add ChatMessage(kind: cmkError, text: $message, timestamp: 0.0)
  client.onError = proc(message: cstring) {.closure.} =
    if client.closed or (generation >= 0 and capturedChat.promptGeneration != generation): return
    capturedChat.promptInFlight = false
    if not capturedChat.promptAdmitted and capturedChat.inputText.val.len == 0:
      capturedChat.inputText.val = capturedChat.pendingPromptText
    capturedChat.connectionState.val = "failed"
    capturedChat.sessionStatus.val = asError
    capturedChat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
      result = prev
      result.add ChatMessage(kind: cmkError, text: $message, timestamp: 0.0)

proc configureAgentAdaptersWithClient*(chat: AgentChatVM;
    client: BrowserAgentClient;
    backend = absAcp) =
  ## Install the adapter closures on ``chat`` that proxy through
  ## ``client``.  Pure DI — call sites are
  ## :proc:`configureDaemonAgentAdapters` and VM tests.
  installAdapterCallbacks(client, chat)
  let capturedClient = client
  let capturedChat = chat
  var creating = false
  var pendingClose: proc(ok: bool) {.closure.}
  proc operationError(message: cstring) =
    capturedChat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
      result = prev
      result.add ChatMessage(kind: cmkError, text: $message, timestamp: 0.0)
  proc closeBackend(done: proc(ok: bool) {.closure.}) =
    capturedClient.closeSession(capturedClient.activeSessionId,
      proc(ok: bool; message: cstring) =
        capturedChat.closingSession = false
        if not ok: operationError(message)
        done(ok))

  let promptAdapter: AgentPromptAdapter =
    proc(prompt: string; context: AgentPromptContext): bool {.closure.} =
      ## Session-on-demand: mint a session on first prompt, then
      ## reuse it for the rest of the editor's lifetime.  ``submitPrompt``
      ## is non-blocking; ``true`` is returned the moment the request is
      ## dispatched.
      if capturedClient.closed or capturedChat.promptInFlight or
          capturedChat.closingSession: return false
      capturedChat.promptInFlight = true
      let generation = capturedChat.promptGeneration
      installAdapterCallbacks(capturedClient, capturedChat, generation)
      var submitted: seq[EditRecord]
      for edit in context.accumulatedEdits: submitted.add edit
      capturedClient.onAdmitted = proc() =
        if capturedClient.closed: return
        capturedChat.acknowledgeAgentPrompt(generation, submitted)
      if capturedClient.activeSessionId.len > 0:
        capturedChat.connectionState.val = $acsStreaming
        capturedClient.submitPrompt(
          capturedClient.activeSessionId, prompt, $context.agentPromptContextJson)
        return true
      capturedChat.connectionState.val = $acsConnecting
      let promptCopy = prompt
      let contextCopy = $context.agentPromptContextJson
      creating = true
      capturedClient.createSession(proc(sessionId: cstring) {.closure.} =
        creating = false
        let sid = $sessionId
        if sid.len == 0:
          if pendingClose != nil:
            let done = pendingClose
            pendingClose = nil
            capturedChat.closingSession = false
            done(true)
          # The error path was already invoked from inside
          # ``createSession`` (onError fired); we just have to leave the
          # VM in the failed state.
          return
        capturedChat.backend.val =
          if capturedClient.backend == "harbor": absAgentHarbor
          elif capturedClient.backend == "acp": absAcp
          else: absUnconfigured
        capturedChat.cancelSupported.val = capturedClient.canCancelTurn
        capturedClient.activeSessionId = sid
        capturedChat.controlConversationId.val = sid
        if pendingClose != nil:
          capturedChat.promptInFlight = false
          let done = pendingClose
          pendingClose = nil
          closeBackend(done)
          return
        capturedChat.connectionState.val = $acsStreaming
        # Session metadata is authoritative even on the first turn, whose
        # context was collected before the asynchronous creation response.
        var delivered = parseJson(contextCopy)
        delivered["backend"] = %($capturedChat.backend.val)
        capturedClient.submitPrompt(sid, promptCopy, $delivered))
      true

  chat.configureAgentAdapters(promptAdapter, nil, backend)
  chat.asyncAgentAdapter = true
  chat.cancelAsyncAdapter = proc() =
    if capturedClient.activeSessionId.len == 0:
      operationError("No active agent session to cancel.")
      return
    capturedClient.cancel(capturedClient.activeSessionId,
      proc(ok: bool; message: cstring) =
        if not ok: operationError(message)
        elif capturedChat.connectionState.val == "streaming":
          capturedChat.connectionState.val = "cancelling"
        # Only the stream's terminal event establishes turn cancellation.
      )
  chat.closeAdapter = proc(done: proc(ok: bool) {.closure.}) =
    capturedChat.closingSession = true
    if creating:
      pendingClose = done
    elif capturedClient.activeSessionId.len > 0:
      closeBackend(done)
    else:
      capturedClient.closed = true
      capturedChat.closingSession = false
      done(true)
  chat.connectionState.val = "idle"

proc configureDaemonAgentAdapters*(chat: AgentChatVM): BrowserAgentClient
    {.discardable.} =
  ## Production entry point: resolve the daemon URL, allocate a
  ## :type:`BrowserAgentClient`, install the JS-side SSE dispatcher,
  ## and wire the adapter closures on ``chat``.  Returns the client
  ## so the caller can stash a reference if needed.
  installAgentDispatcher()
  let url = resolveDaemonUrl()
  let client = newBrowserAgentClient(url)
  chat.configureAgentAdaptersWithClient(client, absUnconfigured)
  client
