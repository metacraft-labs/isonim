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

import std/json

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

proc installAdapterCallbacks*(client: BrowserAgentClient; chat: AgentChatVM) =
  ## Wire ``client.onUpdate`` / ``onEnd`` / ``onError`` to push
  ## :type:`AgentEvent` instances through ``applyAgentEvent``.  Exposed
  ## so the VM tests can call this against a fake client.
  let capturedChat = chat
  client.onUpdate = proc(payload: cstring) {.closure.} =
    let evt = agentEventFromSse($payload)
    capturedChat.applyAgentEvent(evt)
  client.onEnd = proc(stopReason: cstring) {.closure.} =
    capturedChat.stopReason.val = $stopReason
    capturedChat.sessionStatus.val = asReady
    if $stopReason == "cancelled":
      capturedChat.connectionState.val = $acsCancelled
    elif $stopReason == "error":
      capturedChat.connectionState.val = $acsError
      capturedChat.sessionStatus.val = asError
    else:
      capturedChat.connectionState.val = $acsCompleted
  client.onError = proc(message: cstring) {.closure.} =
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

  let promptAdapter: AgentPromptAdapter =
    proc(prompt: string; context: AgentPromptContext): bool {.closure.} =
      ## Session-on-demand: mint a session on first prompt, then
      ## reuse it for the rest of the editor's lifetime.  ``submitPrompt``
      ## is non-blocking; ``true`` is returned the moment the request is
      ## dispatched.
      if capturedClient.activeSessionId.len > 0:
        capturedChat.connectionState.val = $acsStreaming
        capturedClient.submitPrompt(
          capturedClient.activeSessionId, prompt)
        return true
      capturedChat.connectionState.val = $acsConnecting
      let promptCopy = prompt
      capturedClient.createSession(proc(sessionId: cstring) {.closure.} =
        let sid = $sessionId
        if sid.len == 0:
          # The error path was already invoked from inside
          # ``createSession`` (onError fired); we just have to leave the
          # VM in the failed state.
          return
        capturedClient.activeSessionId = sid
        capturedChat.connectionState.val = $acsStreaming
        capturedClient.submitPrompt(sid, promptCopy))
      true

  let cancelAdapter: AgentCancelAdapter =
    proc(): bool {.closure.} =
      if capturedClient.activeSessionId.len == 0:
        return false
      capturedClient.cancel(capturedClient.activeSessionId)
      true

  chat.configureAgentAdapters(promptAdapter, cancelAdapter, backend)
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
  chat.configureAgentAdaptersWithClient(client, absAcp)
  client
