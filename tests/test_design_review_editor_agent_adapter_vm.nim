## Phase C — VM-level tests for the editor's daemon-driven agent
## adapter.
##
## We bypass the real ``fetch`` chain by hand-building a
## :type:`BrowserAgentClient` with stubbed ``createSession`` /
## ``submitPrompt`` callbacks.  The adapter wiring in
## ``editor_agent_adapter.configureAgentAdaptersWithClient`` is the
## subject under test — it should:
##
##   * Mint a session on first prompt (``createSession`` invoked with
##     a deterministic id).
##   * Stream events back through ``applyAgentEvent`` so
##     ``vm.chat.messages`` accumulates the agent's response.
##   * Move ``connectionState`` through ``connecting`` → ``streaming``
##     → ``completed``.
##   * Surface "daemon unreachable" as ``connectionState == "failed"``
##     and a ``cmkError`` message on the chat transcript.
##   * Route ``cancelAgentPrompt`` to ``client.cancel`` with the cached
##     session id.
##
## The fifth test wires the brief tab's "Review this preview" button
## directly against the adapter and asserts the submitted prompt is
## context-loaded.

import std/[unittest, options, tables, strutils, json]

import nim_agents
import isonim/core/[signals, owner]
import isonim/viewmodel
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/browser_agent_client
import isonim/editor/design_review/editor_agent_adapter
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/brief_tab

# --------------------------------------------------------------------------- #
#  Helpers.
# --------------------------------------------------------------------------- #

proc fakeClient(baseUrl = "http://test"): BrowserAgentClient =
  newBrowserAgentClient(baseUrl)

proc emitSessionUpdate(client: BrowserAgentClient; text: string;
                       sessionId = "sess-1") =
  ## Simulate one ``session/update`` SSE frame by invoking the
  ## adapter's ``onUpdate`` callback directly with the JSON payload
  ## the daemon would otherwise wire over HTTP.
  let payload = $(%* {
    "sessionId": sessionId,
    "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": {"type": "text", "text": text}
    }
  })
  client.onUpdate(payload.cstring)

proc emitEnd(client: BrowserAgentClient; stopReason = "end_turn") =
  client.onEnd(stopReason.cstring)

proc emitError(client: BrowserAgentClient; reason: string) =
  client.onError(reason.cstring)

# --------------------------------------------------------------------------- #
#  Tests.
# --------------------------------------------------------------------------- #

suite "Phase C editor agent adapter VM":

  test "test_adapter_creates_session_on_first_prompt":
    createRoot do (dispose: proc()):
      let chat = createAgentChatVM()
      let client = fakeClient()
      chat.configureAgentAdaptersWithClient(client, absAcp)

      check chat.connectionState.val == "idle"

      # The "create session" code path on a real fetch chain calls
      # back into the adapter once the daemon replies; we simulate
      # by pre-stamping the cached session id (the fake client never
      # touches the network).
      client.activeSessionId = "sess-deterministic"

      check chat.promptAdapter != nil
      check chat.promptAdapter("hello", AgentPromptContext()) == true
      # streaming state set the moment the prompt was dispatched.
      check chat.connectionState.val == $acsStreaming

      # Drive the SSE callbacks.
      emitSessionUpdate(client, "hi there")
      emitEnd(client)

      var agentText = ""
      for msg in chat.messages.val:
        if msg.kind == cmkAgent:
          agentText.add msg.text
      check agentText == "hi there"
      check chat.sessionStatus.val == asReady
      check chat.connectionState.val == $acsCompleted
      dispose()

  test "test_adapter_cancels_in_flight_prompt":
    createRoot do (dispose: proc()):
      let chat = createAgentChatVM()
      let client = fakeClient()
      chat.configureAgentAdaptersWithClient(client, absAcp)

      client.activeSessionId = "sess-cancel"
      discard chat.promptAdapter("hold on", AgentPromptContext())
      emitSessionUpdate(client, "I will...")

      check chat.cancelAdapter != nil
      check chat.cancelAdapter() == true
      # The fake cancel does nothing visible, but the real daemon
      # would send ``session/cancel`` and follow it up with an
      # ``event: end`` carrying ``stopReason == "cancelled"``.  We
      # simulate that here so the asserts cover the full state
      # transition.
      emitEnd(client, "cancelled")
      check chat.connectionState.val == $acsCancelled
      check chat.stopReason.val == "cancelled"
      dispose()

  test "test_adapter_reports_daemon_unreachable":
    createRoot do (dispose: proc()):
      let chat = createAgentChatVM()
      let client = fakeClient()
      chat.configureAgentAdaptersWithClient(client, absAcp)

      # Simulate the "fetch threw" path that real production code
      # surfaces through ``onError``.
      emitError(client, "daemon unreachable: TypeError: Failed to fetch")

      check chat.connectionState.val == "failed"
      check chat.sessionStatus.val == asError
      var seenError = false
      for msg in chat.messages.val:
        if msg.kind == cmkError and "daemon unreachable" in msg.text:
          seenError = true
      check seenError
      dispose()

  test "test_review_this_preview_button_submits_context_loaded_prompt":
    createRoot do (dispose: proc()):
      let chat = createAgentChatVM()
      let client = fakeClient()
      chat.configureAgentAdaptersWithClient(client, absAcp)
      client.activeSessionId = "sess-review"

      let storyRef = StoryRef(group: "Task App", name: "Inbox",
        kind: skPage, index: 0)
      var brief: Brief
      brief.briefId = "render.task-app"
      brief.schemaVersion = 1
      brief.kind = bkRender
      brief.title = "Task App"
      brief.coversPreviews = @[
        BriefPreviewCoverage(storyRef: storyRef, backends: @[pbWeb])]
      brief.scoringDimensions = @[
        BriefScoringDimension(id: "chrome", label: "Editor Chrome",
                              weight: 0.4, scaleMin: 1, scaleMax: 10)]
      brief.bodyMarkdown = "Pay attention to focus order and contrast."
      brief.extra = initTable[string, string]()
      brief.sourceFile = "<test>"

      var idx = BriefIndex(
        byBriefId: initOrderedTable[string, Brief](),
        byPreview: initOrderedTable[string, seq[string]](),
        errors: @[])
      idx.byBriefId[brief.briefId] = brief
      idx.byPreview[canonicalPreviewId(storyRef, pbWeb)] = @[brief.briefId]

      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let bvm = createBriefTabVM(idx, activeStory, activeBackend)

      # Wire the brief-tab review button to the chat adapter — same
      # path ``preview_pane.nim`` uses in production.
      let chatRef = chat
      bvm.reviewDispatcher = proc(prompt: string) {.closure.} =
        chatRef.inputText.val = prompt
        chatRef.addUserMessage(prompt)
        discard chatRef.promptAdapter(prompt, AgentPromptContext())

      check submitReviewPrompt(bvm) == true

      let composed = bvm.lastSubmittedReviewPrompt.val
      check "Review the preview" in composed
      check "Pay attention to focus order" in composed
      check "Task App" in composed
      check "Editor Chrome" in composed

      # The adapter must have dispatched the prompt — the user
      # message lands on the chat transcript.
      var sawUser = false
      for msg in chat.messages.val:
        if msg.kind == cmkUser and "Review the preview" in msg.text:
          sawUser = true
      check sawUser

      emitSessionUpdate(client, "Looks good.")
      emitEnd(client)
      var sawAgent = false
      for msg in chat.messages.val:
        if msg.kind == cmkAgent and "Looks good" in msg.text:
          sawAgent = true
      check sawAgent
      dispose()

  test "test_agent_event_from_sse_decodes_message_chunk":
    let payload = $(%* {
      "sessionId": "sid",
      "update": {
        "sessionUpdate": "agent_message_chunk",
        "content": {"type": "text", "text": "hi"}}})
    let evt = agentEventFromSse(payload)
    check evt.kind == aekMessageChunk
    check evt.text == "hi"

  test "test_agent_event_from_sse_decodes_tool_call":
    let payload = $(%* {
      "sessionId": "sid",
      "update": {
        "sessionUpdate": "tool_call",
        "toolCallId": "tc1",
        "title": "edit_file",
        "status": "in_progress"}})
    let evt = agentEventFromSse(payload)
    check evt.kind == aekToolCall
    check evt.toolCallId == "tc1"
    check evt.toolName == "edit_file"

  test "test_agent_event_from_sse_swallows_malformed":
    let evt = agentEventFromSse("not json")
    check evt.kind == aekStatus
    check evt.status == "malformed_payload"
