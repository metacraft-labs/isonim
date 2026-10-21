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
## CHRM-M5 removed the "Review this preview" button + the
## ``buildReviewPrompt`` helper it used. The
## ``test_review_this_preview_button_submits_context_loaded_prompt``
## case that previously exercised that helper was deleted alongside
## the button.
##
## The authored HTML preview hook is deterministic project data for the real
## context builder; it does not claim compiler or mounted-renderer success.
## Those boundaries are exercised by the real source GUI and Tailwind/HTTP suite.

import std/[unittest, strutils, json, sequtils]

import nim_agents
import nim_agents/activity
import isonim/core/[signals, owner]
import isonim/viewmodel
import isonim/theming/theme
import isonim/editor/design_review/browser_agent_client
import isonim/editor/design_review/editor_agent_adapter
import isonim/editor/types
import isonim/editor/viewmodels

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
      check chat.activity.val.entries.anyIt(it.role == arAssistant and it.status == "streaming")
      emitEnd(client)
      check chat.activity.val.entries.anyIt(it.role == arAssistant and it.status == "completed")
      check not chat.activity.val.entries.anyIt(it.role == arAssistant and it.status == "streaming")
      let completedEntries = chat.activity.val.entries.len
      emitEnd(client)
      check chat.activity.val.entries.len == completedEntries

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

      chat.connectionState.val = "streaming"
      check chat.cancelAsyncAdapter != nil
      chat.cancelAsyncAdapter()
      check chat.connectionState.val == "streaming"
      check chat.messages.val[^1].text.contains("does not support")
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

suite "EAC-M6 exact admission and complete project context":
  test "provider rejection restores draft and preserves submitted and newer edits":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let client = fakeClient()
      client.activeSessionId = "existing-real-transport-fixture"
      editor.chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      let submitted = EditRecord(file: "site.nim", property: "text", newValue: "first")
      let newer = EditRecord(file: "site.nim", property: "color", newValue: "next")
      editor.chat.accumulatedEdits.val = @[submitted]
      editor.chat.inputText.val = "  exact draft\n"
      check editor.sendAgentPrompt()
      check not editor.chat.promptAdmitted
      editor.chat.accumulatedEdits.val = @[submitted, newer]
      emitEnd(client, "error")
      check editor.chat.inputText.val == "  exact draft\n"
      check editor.chat.accumulatedEdits.val == @[submitted, newer]
      check editor.chat.lastPromptContext.val.accumulatedEdits == @[submitted]
      check not editor.chat.promptInFlight
      dispose()

  test "acknowledgement consumes exact submitted prefix and cannot mutate later turn":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let client = fakeClient()
      client.activeSessionId = "existing-real-transport-fixture"
      editor.chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      let submitted = EditRecord(file: "site.nim", property: "text", newValue: "first")
      let newer = EditRecord(file: "site.nim", property: "color", newValue: "next")
      editor.chat.accumulatedEdits.val = @[submitted]
      editor.chat.inputText.val = "first request"
      check editor.sendAgentPrompt()
      let oldAck = client.onAdmitted
      editor.chat.accumulatedEdits.val = @[submitted, newer]
      editor.chat.inputText.val = "new draft"
      client.onAdmitted()
      check editor.chat.promptAdmitted
      check editor.chat.accumulatedEdits.val == @[newer]
      check editor.chat.inputText.val == "new draft"
      emitEnd(client, "error") # admitted error must not resurrect the first request
      check editor.chat.inputText.val == "new draft"
      check editor.sendAgentPrompt()
      check not editor.chat.promptAdmitted
      oldAck()
      check not editor.chat.promptAdmitted
      check editor.chat.accumulatedEdits.val == @[newer]
      client.closed = true
      client.onAdmitted()
      check not editor.chat.promptAdmitted
      check editor.chat.accumulatedEdits.val == @[newer]
      dispose()

  test "changed submitted prefix is retained and rejection does not overwrite newer draft":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let client = fakeClient()
      client.activeSessionId = "existing-real-transport-fixture"
      editor.chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      editor.chat.accumulatedEdits.val = @[EditRecord(newValue: "original")]
      editor.chat.inputText.val = "request"
      check editor.sendAgentPrompt()
      editor.chat.accumulatedEdits.val = @[EditRecord(newValue: "changed")]
      editor.chat.inputText.val = "newer text"
      client.onAdmitted()
      check editor.chat.accumulatedEdits.val[0].newValue == "changed"
      emitEnd(client, "error")
      check editor.chat.inputText.val == "newer text"
      dispose()

  test "serialization retains typed fields and actual hierarchy and token values":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      editor.inspector.layers.val = @[
        ElementLayerRow(id: "root", tag: "main", childCount: 1),
        ElementLayerRow(id: "title", parentId: "root", depth: 1, tag: "h1", sourceFile: "site.nim", sourceLine: 9)]
      editor.foundations.tokens.val = @[FoundationTokenEntry(key: "surface", kind: ftkColorPalette, value: "#123456", sourceFile: "theme.nim")]
      let first = editor.buildAgentPromptContext().agentPromptContextJson
      check first["renderedComponentTree"][1]["parentId"].getStr == "root"
      check first["renderedComponentTree"][1]["sourceLine"].getInt == 9
      check first["themeTokens"][0]["value"].getStr == "#123456"
      for field in ["selectedStory", "selectedElement", "accumulatedEdits", "pendingSourceEdits", "sourceMap", "designSystemSchema", "selectedSchemaNodes", "tokenContext", "componentVariantContext", "reviewAnnotations", "screenshotRefs", "domSnapshots", "designSystemConstraints", "diagnostics", "currentFileDiffs", "platform", "backend", "availableTailwindClasses", "activeThemeContext"]:
        check first.hasKey(field)
      editor.foundations.tokens.val = @[FoundationTokenEntry(key: "surface", kind: ftkColorPalette, value: "#abcdef", sourceFile: "theme.nim")]
      let next = editor.buildAgentPromptContext().agentPromptContextJson
      check next["themeTokens"][0]["value"].getStr == "#abcdef"
      check first["themeTokens"][0]["value"].getStr == "#123456"
      dispose()

  test "current resolved theme values and native availability change with real theme":
    let originalTheme = activeTheme
    let originalDark = isDarkMode
    defer:
      setTheme(originalTheme)
      setDarkMode(originalDark)
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      setTheme(isoTheme())
      setDarkMode(false)
      let first = editor.buildAgentPromptContext()
      check ("color.primary=" & themeColor("primary")) in first.activeThemeContext
      check ("spacing.md=" & $themeSpacing("md")) in first.activeThemeContext
      check ("typography.body.size=" & $themeTypography("body").size) in first.activeThemeContext
      check not first.contextAvailability.anyIt(it.startsWith("activeThemeContext: native"))
      setTheme(warmTheme())
      setDarkMode(true)
      let followup = editor.buildAgentPromptContext()
      check ("color.primary=" & themeColor("primary")) in followup.activeThemeContext
      check followup.activeThemeContext != first.activeThemeContext
      check "dark=true" in followup.activeThemeContext
      setTheme(nativeTheme())
      let native = editor.buildAgentPromptContext()
      check "activeThemeContext: native platform defaults (no color/spacing override)" in native.contextAvailability
      check native.contextAvailability.anyIt(it.startsWith("activeThemeContext.typography.body:"))
      check not native.activeThemeContext.anyIt(it.startsWith("typography.body.size=0"))
      dispose()

  test "callbacks captured by completed transport cannot change the newer turn":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let client = fakeClient()
      client.activeSessionId = "persistent-session"
      editor.chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      editor.chat.inputText.val = "first"
      check editor.sendAgentPrompt()
      let oldEnd = client.onEnd
      let oldError = client.onError
      let oldInterrupted = client.onInterrupted
      let oldUpdate = client.onUpdate
      client.onAdmitted()
      client.onEnd("end_turn")
      editor.chat.inputText.val = "second"
      check editor.sendAgentPrompt()
      editor.chat.inputText.val = "newer unsent draft"
      let before = editor.chat.messages.val
      let beforeState = editor.chat.connectionState.val
      oldEnd("error")
      oldError("late HTTP failure")
      oldInterrupted("late EOF")
      oldUpdate("{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"late text\"}}")
      check editor.chat.promptInFlight
      check editor.chat.inputText.val == "newer unsent draft"
      check editor.chat.messages.val == before
      check editor.chat.connectionState.val == beforeState
      check not editor.chat.promptAdmitted
      dispose()

  test "actual HTML class tokens exclude inactive markup and decode attributes before relevance":
    let html = """<!doctype html><!-- <i class='flex'> -->
      <script>const fake="<i class='flex'>";</script>
      <style>body::before{content:"<i class='text-sm'>"}</style>
      <title><i class='flex'></title><textarea><i class='text-sm'></textarea>
      <noscript><i class='flex'></noscript>
      <template><i class='text-sm'></i><template class='flex'></template></template>
      <main title='1 > 0' =class='flex' CLASS='p&#45;4 w&#x2d;12' class='flex'>
      <b class='[&amp;&gt;svg]:p-4'></b></main>"""
    check previewClassNames(html) == @["p-4", "w-12", "[&>svg]:p-4"]
    check previewClassNames("<i =class='p-4' CLASS=w-12>") == @["w-12"]
    check previewClassNames("<div class='p&#45;4&Tab;w-12&NewLine;flex'>") == @["p-4", "w-12", "flex"]
    check previewClassNames("<i class='p&hyphen;4'>") == @["p‐4"]
    check previewClassNames("<i class='&OverBar; &UnderBar; &epsiv; &varepsilon; &phiv; &varphi; &epsi; &ohm; &angst; &race;'>") ==
      @["‾", "_", "ϵ", "ϕ", "ε", "Ω", "Å", "∽̱"]
    check previewClassNames("<b class='&fjlig; &NotEqualTilde; &amp &amp= &ampx &unknown; &#0; &#xD800; &#128;'>") ==
      @["fj", "≂̸", "&", "&amp=", "&ampx", "&unknown;", "�", "€"]
    check previewClassNames("<i class='p-4\vflex' CLASS='w-12'><b class class='text-sm'>") == @["p-4\vflex"]
    check previewClassNames("<i class='p-4><b class=flex>").len == 0
    check previewClassNames("<script><!-- <script><i class='flex'></script><i class='text-sm'> --></script><b class=w-12>") == @["w-12"]
    check previewClassNames("<style><i class=flex></stylex><i class=text-sm></STYLE><b class=p-4>") == @["p-4"]
    check previewClassNames("<!doctype html PUBLIC \"a > <i class='flex'>\"><b class=p-4>") == @["p-4"]
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let initial = editor.buildAgentPromptContext()
      for name in ["p-4", "w-12", "flex", "text-sm"]:
        check name in initial.availableTailwindClasses
      editor.preview.hook = proc(story: StoryRef; platform: Platform): ProjectPreview =
        ProjectPreview(status: ppsRendered, story: story, documentHtml: html)
      editor.selectedStory.val = StoryRef(group: "Actual relevance", name: "compiled preview")
      let current = editor.buildAgentPromptContext()
      check current.availableTailwindClasses[0 .. 1] == @["p-4", "w-12"]
      check current.availableTailwindClasses.find("flex") > 1
      check current.availableTailwindClasses.find("text-sm") > 1
      check current.tailwindClassTotal == initial.tailwindClassTotal
      check current.availableTailwindClasses.len >= min(128, initial.tailwindClassTotal)
      check current.designSystemConstraints == initial.designSystemConstraints
      check current.pendingSourceEdits == initial.pendingSourceEdits
      dispose()

  test "normalized preview classes and real late compiled selected classes retain priority":
    check previewClassNames("text class='ignored' <main DATA-CLASS='ignored' CLASS = 'p-4 w-12'><i class=flex></i><b class=\"text-sm p-4\"></b></main>") == @["p-4", "w-12", "flex", "text-sm"]
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      let initial = editor.buildAgentPromptContext()
      check "p-4" in initial.availableTailwindClasses
      check "w-12" in initial.availableTailwindClasses
      editor.inspector.selectedElement.val = ElementRef(id: "actual-selected", properties: @[
        PropertyInfo(name: "width", origin: poTailwindClass, originDetail: "class:w-12")])
      for i in 0 ..< 80:
        editor.workspaceEditDiagnostics.val = editor.workspaceEditDiagnostics.val & @[
          WorkspaceEditDiagnostic(kind: wedCompileFailed, message: "actual compiler diagnostic " & $i)]
      let current = editor.buildAgentPromptContext()
      check current.availableTailwindClasses[0] == "w-12"
      check "p-4" in current.availableTailwindClasses
      check current.tailwindClassTotal == initial.tailwindClassTotal
      check current.availableTailwindClasses.len >= min(128, initial.tailwindClassTotal)
      check current.diagnostics.len < editor.workspaceEditDiagnostics.val.len
      dispose()

  test "bounded Unicode context retains every field and exact pending edit snapshot":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      var original = editor.buildAgentPromptContext()
      original.designSystemConstraints = @["Пример: 保持 exact constraints 😀"]
      for i in 0 ..< 100:
        original.diagnostics.add AgentDiagnosticSnapshot(source: "compiler", severity: "warning",
          message: "Предупреждение 保持 😀 " & repeat("detail", 30), file: "src/app.nim", line: i + 1)
        original.designSystemSchema.add AgentDesignSystemSchemaEntry(key: "schema-" & $i,
          kind: "component", file: "src/app.nim", property: "Пример 保持 😀 " & repeat("value", 20))
      let bounded = boundAgentPromptContext(original)
      check bounded.diagnostics.len > 0
      check bounded.diagnostics.len < original.diagnostics.len
      check bounded.designSystemSchema.len > 0
      check bounded.designSystemSchema.len < original.designSystemSchema.len
      check bounded.diagnostics[0] == original.diagnostics[0]
      check bounded.designSystemConstraints == original.designSystemConstraints
      check original.diagnostics.len == 100
      check bounded.contextAvailability.join("\n").contains("complete records")
      let wire = agentPromptContextJson(bounded)
      for field in ["renderedComponentTree", "availableTailwindClasses", "themeTokens", "selectedStory", "selectedElement", "accumulatedEdits", "pendingSourceEdits", "sourceMap", "designSystemSchema", "selectedSchemaNodes", "tokenContext", "componentVariantContext", "reviewAnnotations", "screenshotRefs", "domSnapshots", "designSystemConstraints", "diagnostics", "currentFileDiffs", "platform", "backend"]:
        check wire.hasKey(field)
      check parseJson($wire) == wire
      for i in 0 ..< 50:
        original.accumulatedEdits.add EditRecord(file: "src/app.nim", line: i + 1,
          property: "text", oldValue: "original", newValue: repeat("保持😀", 100))
      original.currentFileDiffs = @[types.AgentFileDiff(file: "src/app.nim", beforeText: "old", afterText: repeat("保持😀", 1000))]
      let oversized = boundAgentPromptContext(original, 500)
      check oversized.accumulatedEdits == original.accumulatedEdits
      check oversized.currentFileDiffs == original.currentFileDiffs
      check oversized.designSystemConstraints == original.designSystemConstraints
      check oversized.contextAvailability.join("\n").contains("required context exceeds")
      let client = fakeClient()
      client.activeSessionId = "persistent-session"
      editor.chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      editor.chat.accumulatedEdits.val = original.accumulatedEdits
      editor.chat.inputText.val = "  exact 保持😀 draft  "
      check editor.sendAgentPrompt()
      let submitted = editor.chat.lastPromptContext.val
      editor.chat.accumulatedEdits.val = original.accumulatedEdits & @[EditRecord(file: "new.nim", property: "newer", newValue: "new")]
      client.onError("context_limit remainingChars=0; new conversation required")
      check editor.chat.inputText.val == "  exact 保持😀 draft  "
      check editor.chat.accumulatedEdits.val.len == 51
      check editor.chat.lastPromptContext.val == submitted
      check submitted.accumulatedEdits == original.accumulatedEdits
      check not editor.chat.promptAdmitted
      dispose()

  test "one huge optional diagnostic and DOM snapshot are truthfully Unicode bounded":
    var context: AgentPromptContext
    let message = "failure at start 保持😀" & repeat("Пример保持😀", 2000) & " actual ending"
    context.diagnostics = @[AgentDiagnosticSnapshot(source: "compiler", severity: "error",
      category: "compile", message: message, file: "src/actual.nim", line: 42)]
    context.domSnapshots = @["<html><body>" & repeat("保持😀", 5000) & "</body></html>"]
    let bounded = boundAgentPromptContext(context)
    check bounded.diagnostics.len == 1
    check bounded.diagnostics[0].file == "src/actual.nim"
    check bounded.diagnostics[0].line == 42
    check bounded.diagnostics[0].severity == "error"
    check bounded.diagnostics[0].message.startsWith("failure at start 保持😀")
    check bounded.diagnostics[0].message.endsWith(" actual ending")
    check bounded.diagnostics[0].message.contains("[truncated")
    check bounded.domSnapshots[0].startsWith("<html><body>")
    check bounded.domSnapshots[0].endsWith("</body></html>")
    check bounded.contextAvailability.join("\n").contains("within-record")
    check not bounded.contextAvailability.join("\n").contains("required context exceeds")
    check context.diagnostics[0].message == message
    check parseJson($agentPromptContextJson(bounded)) == agentPromptContextJson(bounded)
    var oversizedIdentity: AgentPromptContext
    oversizedIdentity.designSystemSchema = @[AgentDesignSystemSchemaEntry(key:repeat("actual-key-",2000))]
    let rejectedIdentity = boundAgentPromptContext(oversizedIdentity,1000)
    check rejectedIdentity.designSystemSchema == oversizedIdentity.designSystemSchema
    check rejectedIdentity.contextAvailability.join("\n").contains("optional context identities")
    check not rejectedIdentity.contextAvailability.join("\n").contains("required context exceeds")


suite "Safe context-budget status projection":
  test "typed status survives wire decoding and shared chat without admitting the submitted edits":
    createRoot do (dispose: proc()):
      let chat = createAgentChatVM()
      let client = fakeClient()
      chat.configureAgentAdaptersWithClient(client, absAgentHarbor)
      client.activeSessionId = "same-budget-session"
      let pending = EditRecord(file:"actual.nim",property:"text",newValue:"exact pending 保持😀")
      chat.accumulatedEdits.val = @[pending]
      chat.inputText.val = "exact pending draft"
      discard chat.promptAdapter("exact user", AgentPromptContext(accumulatedEdits: chat.accumulatedEdits.val))
      let event = AgentEvent(kind: aekStatus, sessionId: "same-budget-session",
        sourceType: "editor_context_budget",
        text: "Backend quota rejected this turn before delivery. Retrying once with bounded optional context; exact user text and pending edits are retained.",
        presentationFields: @[AgentPresentationField(name: "Remaining Unicode characters", value: "4260"),
          AgentPresentationField(name: "Optional context", value: "diagnostics: 1/80 records; quota truncated")],
        raw: %* {"private":"must never cross wire"})
      let wire = toJson(event)
      check not wire.hasKey("raw")
      check not ($wire).contains("must never cross wire")
      let decoded = nim_agents.agentEventFromJson(wire)
      check decoded.sourceType == "editor_context_budget"
      check decoded.presentationFields == event.presentationFields
      client.onUpdate(($wire).cstring)
      check chat.activity.val.entries.anyIt(it.text.contains("Backend quota rejected"))
      check chat.connectionState.val == $acsStreaming
      check not chat.promptAdmitted
      check chat.accumulatedEdits.val == @[pending]
      check chat.promptInFlight
      dispose()


suite "Current context priority under large unrelated inventory":
  test "published small hierarchy and selected ancestors beyond 512 survive actual VM context building":
    createRoot do (dispose: proc()):
      let editor = createEditorVM()
      editor.inspector.layers.val = @[
        ElementLayerRow(id:"root",tag:"main",childCount:1),
        ElementLayerRow(id:"branch",parentId:"root",depth:1,tag:"section",childCount:1),
        ElementLayerRow(id:"leaf",parentId:"branch",depth:2,tag:"button",schemaKey:"actual.label")]
      let small = editor.buildAgentPromptContext()
      check small.renderedComponentTree == editor.inspector.layers.val
      var rows = @[ElementLayerRow(id:"root",tag:"main",childCount:600)]
      for i in 0 ..< 600:
        rows.add ElementLayerRow(id:"unrelated." & $i,parentId:"root",depth:1,tag:"div")
      rows.add ElementLayerRow(id:"late-parent",parentId:"root",depth:1,tag:"section",childCount:1)
      rows.add ElementLayerRow(id:"late-selected",parentId:"late-parent",depth:2,tag:"button",selected:true,
        schemaKey:"actual.label",sourceFile:"actual.nim",sourceLine:91)
      editor.inspector.layers.val = rows
      editor.inspector.selectedElement.val = ElementRef(id:"late-selected",ancestorIds: @["root","late-parent"],depth:2)
      editor.inspector.pendingSourceEdits.val = @[SourceEditPlan(schemaKey:"actual.label",property:"ariaLabel")]
      let large = editor.buildAgentPromptContext()
      check large.renderedComponentTree.anyIt(it.id=="late-parent" and it.parentId=="root" and it.depth==1)
      check large.renderedComponentTree.anyIt(it.id=="late-selected" and it.parentId=="late-parent" and it.depth==2 and it.sourceLine==91)
      check large.renderedComponentTree.mapIt(it.id).find("late-parent") < large.renderedComponentTree.mapIt(it.id).find("late-selected")
      check large.contextAvailability.join("\n").contains("renderedComponentTree: truncated")
      check editor.inspector.layers.val == rows
      editor.inspector.layers.val = @[ElementLayerRow(id:"selected",parentId:"missing",depth:2,selected:true)]
      let missing = editor.buildAgentPromptContext()
      check missing.renderedComponentTree.len == 1
      check missing.contextAvailability.join("\n").contains("required ancestor is unavailable")
      dispose()

  test "edited schema at inventory tail and distinct actionable diagnostic sources survive":
    var context = AgentPromptContext()
    for i in 0 ..< 150:
      context.designSystemSchema.add AgentDesignSystemSchemaEntry(key:"unrelated." & $i,
        property:"other" & $i,file:"unrelated.nim",kind:"property")
      context.diagnostics.add AgentDiagnosticSnapshot(source:"compiler",category:"generic",
        message:"unrelated diagnostic " & $i,severity:"info")
    context.designSystemSchema.add AgentDesignSystemSchemaEntry(key:"components.button.ariaLabel",
      property:"ariaLabel",file:"actual.nim",kind:"property")
    context.pendingSourceEdits = @[SourceEditPlan(schemaKey:"components.button.ariaLabel",property:"ariaLabel")]
    context.accumulatedEdits = @[EditRecord(property:"ariaLabel",file:"actual.nim",newValue:"exact current")]
    context.diagnostics.add AgentDiagnosticSnapshot(source:"workspace",category:"conflict",message:"actual source conflict",severity:"error")
    context.diagnostics.add AgentDiagnosticSnapshot(source:"review",category:"accessibility",message:"actual warning",severity:"warning")
    let bounded=boundAgentPromptContext(context)
    check bounded.designSystemSchema.anyIt(it.key=="components.button.ariaLabel")
    check bounded.diagnostics.anyIt(it.source=="workspace" and it.message=="actual source conflict")
    check bounded.diagnostics.anyIt(it.source=="review" and it.message=="actual warning")
    check bounded.pendingSourceEdits==context.pendingSourceEdits
    check bounded.accumulatedEdits==context.accumulatedEdits
    check bounded.contextAvailability.join("\n").contains("truncated")
