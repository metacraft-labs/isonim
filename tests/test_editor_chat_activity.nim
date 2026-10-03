## Production chat VM + pure reducer and safe block parser, native and JS.
## Controlled admission closures substitute only external request dispatch to
## force rejection or latch an unresolved turn. The generic-backend compatibility case uses the
## real MockRenderer backend to prove production views need no browser globals;
## actual DOM focus/selection is covered by the mounted GUI suite. EditorVM and
## signals/reducer remain production code. The full public DTO corpus substitutes
## external transport timing with protocol data, not a fake service. Its frames
## traverse the real Harbor parser, safe projection, JSON codec, reducer and
## generic renderer; official Rust scenario E2E is separately registered.
import std/[unittest, strutils, tables, json, sets, sequtils]
import nim_agents
import nim_agents/[activity, activity_presentation]
import isonim/viewmodel
import isonim/core/[signals, computation, owner]
import isonim/editor/[viewmodels, agent_harbor]
import isonim/editor/views/[chat_activity, chat_panel]
import isonim/editor/views/chat_theme
import isonim/testing/mock_dom

proc activityNode(node: MockNode; role: string): MockNode =
  if node.attributes.getOrDefault("data-chat-role") == role: return node
  for child in node.children:
    result = activityNode(child, role)
    if result != nil: return


proc entryNode(node: MockNode; id: string): MockNode =
  if node.attributes.getOrDefault("data-chat-entry") == id: return node
  for child in node.children:
    result = entryNode(child, id)
    if result != nil: return

suite "Chat activity and composition":
  test "chat content fills the rail without a second width binding":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      for width in [200, 240, 320, 420]:
        vm.setRightPanelWidth(width)
        check vm.rightPanelWidth.val == width
        check panel.styles.getOrDefault("width") == "100%"
        check panel.styles.getOrDefault("min-width") == "0"
        check panel.styles.getOrDefault("max-width") == "100%"
        check panel.styles.getOrDefault("flex") == "1"
        check "flex-basis" notin panel.styles
        check "data-right-panel-width" notin panel.attributes
      dispose()

  test "rendered admission tracks flight and closure even when activity already looks ready":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      var dispatched: seq[string]
      vm.chat.configureAgentAdapters(proc(prompt: string; context: AgentPromptContext): bool =
        dispatched.add prompt
        vm.chat.promptInFlight = true
        true, nil)
      vm.chat.asyncAgentAdapter = true
      vm.chat.inputText.val = "exact next draft"
      vm.chat.promptInFlight = true
      vm.chat.sessionStatus.val = asReady
      let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      proc send(node: MockNode): MockNode =
        if node.attributes.getOrDefault("aria-label") == "Send agent prompt": return node
        for child in node.children:
          result = send(child)
          if result != nil: return
      let control = send(panel)
      check control != nil
      check control.attributes.getOrDefault("aria-disabled") == "true"
      check not vm.sendAgentPrompt()
      check dispatched.len == 0
      check vm.chat.inputText.val == "exact next draft"
      vm.chat.promptInFlight = false
      check control.attributes.getOrDefault("aria-disabled") == "false"
      vm.chat.closingSession = true
      check control.attributes.getOrDefault("aria-disabled") == "true"
      check not vm.sendAgentPrompt()
      vm.chat.closingSession = false
      check control.attributes.getOrDefault("aria-disabled") == "false"
      check vm.sendAgentPrompt()
      check dispatched == @["exact next draft"]
      vm.chat.inputText.val = "newer unsent draft"
      vm.chat.applyAgentEvent(AgentEvent(kind: aekCompleted, stopReason: srEndTurn))
      check control.attributes.getOrDefault("aria-disabled") == "true"
      vm.chat.sessionStatus.val = asError
      check control.attributes.getOrDefault("aria-disabled") == "true"
      check not vm.sendAgentPrompt()
      check vm.chat.inputText.val == "newer unsent draft"
      check dispatched.len == 1
      dispose()
  test "attempted missing-adapter send dismisses guidance and preserves retry draft":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.inputText.val = "draft to retry"
      check not vm.sendAgentPrompt()
      check vm.chat.placeholdersDismissed.val
      check vm.chat.inputText.val == "draft to retry"
      let first = vm.activeChatId.val
      discard vm.createNewChat()
      check not vm.chat.placeholdersDismissed.val
      vm.chat.inputText.val = "different draft"
      discard vm.switchToChat(first)
      check vm.chat.inputText.val == "draft to retry"
      check vm.chat.placeholdersDismissed.val
      dispose()
  test "rejected and busy sends preserve drafts and attempted state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.configureAgentAdapters(proc(prompt: string; context: AgentPromptContext): bool = false, nil)
      vm.chat.inputText.val = "rejected"
      check not vm.sendAgentPrompt()
      check vm.chat.inputText.val == "rejected"
      vm.chat.asyncAgentAdapter = true
      vm.chat.promptInFlight = true
      vm.chat.inputText.val = "next draft"
      check not vm.sendAgentPrompt()
      check vm.chat.inputText.val == "next draft"
      check vm.chat.placeholdersDismissed.val
      dispose()
  test "streaming chunks form an assistant turn while local input stays distinct":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.addUserMessage("hello")
      vm.chat.applyAgentEvent(AgentEvent(kind: aekMessageChunk, text: "First "))
      vm.chat.applyAgentEvent(AgentEvent(kind: aekMessageChunk, text: "second"))
      vm.chat.inputText.val = "next draft"
      vm.chat.applyAgentEvent(AgentEvent(kind: aekToolCall, toolCallId: "t", toolName: "build", status: "running"))
      check vm.chat.activity.val.entries.len == 3
      check vm.chat.activity.val.entries[1].text == "First second"
      check vm.chat.inputText.val == "next draft"
      dispose()
  test "safe Markdown keeps lists code and headings without interpreting HTML":
    let blocks = chatMarkdownBlocks("# Title\n- first\n- second\n```nim\nlet value = \"<script>\"\n```\n<script>alert(1)</script>")
    check blocks.len == 5
    check blocks[0].kind == "heading"
    check blocks[1].kind == "list"
    check blocks[3].kind == "code"
    check blocks[3].language == "nim"
    check blocks[4].text == "<script>alert(1)</script>"
  test "full REST wait login and lifecycle types have purposeful host presentations":
    for source in ["session_started", "session_awaiting_input", "session_resumed",
        "session_ended", "proxy_credential_rotated", "proxy_rate_limit_absorbed",
        "dispatcher_restarted", "anti_halting_resume_confirmed", "session_leadership_migrated",
        "participant", "context_injection", "fleet_host", "fleet_fence", "orchestration",
        "delegation", "file_read", "link_spans", "login_required", "context_files", "agent_question"]:
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.chat.applyAgentEvent(AgentEvent(kind: aekStatus, sourceType: source, text: "actual content"))
        check activityTitle(vm.chat.activity.val.entries[0]) != "Activity"
        dispose()

  test "replayed durable events cannot duplicate transcript or source edit context":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let edit = AgentEvent(sessionId: "s", eventId: "12", kind: aekFileEdit,
        filePath: "stories.nim", linesAdded: 2)
      vm.chat.applyAgentEvent(edit)
      vm.chat.applyAgentEvent(edit)
      check vm.chat.accumulatedEdits.val.len == 1
      let message = AgentEvent(sessionId: "s", eventId: "13", kind: aekMessageChunk, text: "once")
      vm.chat.applyAgentEvent(message)
      vm.chat.applyAgentEvent(message)
      check vm.chat.messages.val.len == 2
      check vm.chat.activity.val.entries.len == 2
      dispose()

  test "generic chat renderer under JS requires no browser globals":
    when defined(js):
      var noBrowserGlobals = false
      {.emit: [noBrowserGlobals, " = typeof document === 'undefined' && typeof window === 'undefined';"].}
      check noBrowserGlobals
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.addUserMessage("generic user prompt")
      vm.chat.inputText.val = "retained next draft"
      vm.chat.applyAgentEvent(AgentEvent(kind: aekMessageChunk, text: "partial"))
      let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      let user = activityNode(panel, "arUser")
      check user != nil
      check user.textContent.contains("generic user prompt")
      vm.chat.applyAgentEvent(AgentEvent(kind: aekMessageChunk, text: " completed"))
      let assistant = activityNode(panel, "arAssistant")
      check assistant != nil
      check assistant.textContent.contains("partial completed")
      check vm.chat.inputText.val == "retained next draft"
      dispose()

# DTO corpus is intentional boundary data, not an emulated Harbor service. Every
# frame traverses the real public parser, safe projection, wire codec, reducer and
# generic renderer; official Rust scenario E2E remains separately registered.
suite "Full public Harbor event presentation":
  test "actual file edit description and reported running status render without changing admission":
    const corpusText = staticRead("scenarios/chat-activity/public-session-events.json")
    let corpus = parseJson(corpusText)
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.inputText.val = "Retained next draft"
      vm.chat.asyncAgentAdapter = true
      vm.chat.promptInFlight = true
      let admitted = vm.chat.promptAdmitted
      let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      proc matching(node: MockNode; attribute, value: string): seq[MockNode] =
        var pending = @[node]
        while pending.len > 0:
          let child = pending.pop()
          if child.attributes.getOrDefault(attribute) == value: result.add child
          for nested in child.children: pending.add nested
      proc textContent(node: MockNode): string =
        var pending = @[node]
        while pending.len > 0:
          let child = pending.pop()
          result.add child.text
          for nested in child.children: pending.add nested
      let fileEvent = agentEventFromJson(harborEventToAgentEvent("s",
        eventFromJson(corpus["scenes"]["files"][0])).toJson())
      check fileEvent.text == "Use shared spacing and preserve the title."
      vm.chat.applyAgentEvent(fileEvent)
      let fileEntry = vm.chat.activity.val.entries[^1]
      let fileNode = entryNode(panel, fileEntry.id)
      let prose = matching(fileNode, "data-chat-markdown", "paragraph")
      check prose.len == 1
      check textContent(prose[0]) == "Use shared spacing and preserve the title."
      check prose[0].parent.parent == fileNode
      check prose[0].styles.getOrDefault("display") != "none"
      check matching(fileNode, "data-chat-fact", "File").len == 1
      check matching(fileNode, "data-chat-fact", "Changes").len == 1
      check textContent(fileNode).contains("stories/hero.nim")
      check textContent(fileNode).contains("+4 / −2 lines")
      let details = fileNode.children.filterIt(it.tag == "details")
      check details.len == 1
      check not details[0].attributes.hasKey("open")
      let running = agentEventFromJson(harborEventToAgentEvent("s",
        eventFromJson(corpus["scenes"]["error"][0])).toJson())
      check running.state == acsStreaming
      vm.chat.applyAgentEvent(running)
      let sessionEntry = vm.chat.activity.val.entries[^1]
      check sessionEntry.status == "streaming"
      check sessionEntry.data.status == "running"
      check vm.chat.connectionState.val == "streaming"
      check vm.chat.sessionStatus.val == asLoading
      let sessionNode = entryNode(panel, sessionEntry.id)
      let badge = matching(sessionNode, "data-chat-activity-status", "true")
      check badge.len == 1
      check textContent(badge[0]) == "running"
      check badge[0].styles.getOrDefault("display") == "inline-block"
      let revision = vm.chat.activity.val.revision
      vm.chat.applyAgentEvent(running)
      check vm.chat.activity.val.revision == revision
      check vm.chat.promptInFlight
      check vm.chat.promptAdmitted == admitted
      check not vm.sendAgentPrompt()
      check vm.chat.inputText.val == "Retained next draft"
      check vm.chat.accumulatedEdits.val.len == 1
      dispose()

  test "every public question mode preserves content without unsupported answer controls":
    const questionCorpusText = staticRead("scenarios/chat-activity/public-session-events.json")
    let corpus = parseJson(questionCorpusText)
    var modes = initHashSet[string]()
    for name in ["question", "question-free-form", "question-multi-choice", "question-confirmation"]:
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.chat.inputText.val = "Retained next draft"
        let payload = corpus["scenes"][name][0]
        let decoded = agentEventFromJson(harborEventToAgentEvent("question-session", eventFromJson(payload)).toJson())
        vm.chat.applyAgentEvent(decoded)
        modes.incl payload["kind"].getStr()
        let entry = vm.chat.activity.val.entries[^1]
        let presentation = activityPresentation(entry)
        check entry.data.question == payload["prompt"].getStr()
        check presentation.facts.anyIt(it.value == payload["kind"].getStr())
        check presentation.facts.anyIt(it.value == payload["request"].getStr())
        for option in payload["options"]:
          check presentation.facts.anyIt(it.label == "Choice" and it.value == option["label"].getStr())
        let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
        let node = entryNode(panel, entry.id)
        check activityDetail(entry).contains("This editor cannot answer this request.")
        let notice = node.children.filterIt(it.attributes.getOrDefault("data-chat-availability") == "true")
        check notice.len == 1
        check notice[0].parent == node
        check notice[0].tag == "p"
        check notice[0].children.len == 1
        check notice[0].children[0].text == "This editor cannot answer this request."
        check notice[0].styles.getOrDefault("display") == "block"
        let details = node.children.filterIt(it.tag == "details")
        check details.len == 1
        check not details[0].attributes.hasKey("open")
        check activityDetail(entry).contains(payload["request"].getStr())
        proc noAnswerControls(child: MockNode) =
          check child.tag notin ["button", "input", "textarea", "select"]
          for nested in child.children: noAnswerControls(nested)
        noAnswerControls(node)
        check vm.chat.inputText.val == "Retained next draft"
        dispose()
    check modes == ["free_form", "single_choice", "multi_choice", "confirmation"].toHashSet()

  test "login recovery stays visible before details with correlated request availability":
    const corpusText = staticRead("scenarios/chat-activity/public-session-events.json")
    let payload = parseJson(corpusText)["scenes"]["login"][0]
    for correlated in [false, true]:
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.chat.inputText.val = "Retained login draft"
        var decoded = agentEventFromJson(harborEventToAgentEvent("login-session", eventFromJson(payload)).toJson())
        if correlated: decoded.question = "Provider authentication request"
        vm.chat.applyAgentEvent(decoded)
        let entry = vm.chat.activity.val.entries[^1]
        let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
        let node = entryNode(panel, entry.id)
        let notice = node.children.filterIt(it.attributes.getOrDefault("data-chat-availability") == "true")
        check notice.len == 1
        check notice[0].parent == node
        check notice[0].styles.getOrDefault("display") == "block"
        check notice[0].children[0].text.contains("Sign in through the provider's supported login surface.")
        check notice[0].children[0].text.contains("This editor cannot answer this request.") == correlated
        let details = node.children.filterIt(it.tag == "details")
        check details.len == 1
        check not details[0].attributes.hasKey("open")
        var pending = @[node]
        while pending.len > 0:
          let child = pending.pop()
          check child.tag notin ["button", "input", "textarea", "select", "a"]
          for nested in child.children: pending.add nested
        check vm.chat.inputText.val == "Retained login draft"
        dispose()

  test "all 34 public discriminators traverse safe production presentation":
    const corpusText = staticRead("scenarios/chat-activity/public-session-events.json")
    let corpus = parseJson(corpusText)
    var sources = initHashSet[string]()
    for name, events in corpus["scenes"]:
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.chat.addUserMessage("Improve the hero spacing.")
        for payload in events.items:
          sources.incl payload["type"].getStr()
          # Unknown/private fields are projection negative controls, separate
          # from the production-serialized public DTO corpus.
          let contaminated = parseJson($payload)
          contaminated["config"] = %*{"token": "PRIVATE_CAMPAIGN_SECRET"}
          if contaminated["type"].getStr() == "tool_use":
            contaminated["tool_args"] = %*{"token": "PRIVATE_CAMPAIGN_SECRET", "path": "stories/hero.nim"}
          let privateProjection = harborEventToAgentEvent("presentation-session", eventFromJson(contaminated))
          check not ($privateProjection.toJson()).contains("PRIVATE_CAMPAIGN_SECRET")
          # Backend-local raw diagnostics remain before safe serialization;
          # the wire excludes private bytes and the timeline drops raw entirely.
          let privateDecoded = agentEventFromJson(privateProjection.toJson())
          check not ($privateDecoded.raw).contains("PRIVATE_CAMPAIGN_SECRET")
          var privateTimeline: ActivityTimeline
          discard privateTimeline.reduce(privateDecoded)
          for entry in privateTimeline.entries: check entry.data.raw == nil
          let projected = harborEventToAgentEvent("presentation-session", eventFromJson(payload))
          let wire = projected.toJson()
          check not ($wire).contains("PRIVATE_CAMPAIGN_SECRET")
          let decoded = agentEventFromJson(wire)
          # Inventory is checked after the real projection/codec, not merely
          # counted from incoming frames. Local user acknowledgement and
          # assistant/thought chunks intentionally coalesce in the timeline.
          check decoded.sourceType == payload["type"].getStr()
          vm.chat.applyAgentEvent(decoded)
          let rendered = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
          proc textTree(node: MockNode): string =
            result = node.textContent
            for child in node.children: result.add "\n" & textTree(child)
          let text = textTree(rendered)
          for field in decoded.presentationFields:
            check text.contains(field.value.replace("_", " ")) or text.contains(field.value)
          if decoded.filePath.len > 0: check text.contains(decoded.filePath)
          if decoded.model.len > 0: check text.contains(decoded.model)
          if decoded.question.len > 0: check text.contains(decoded.question)
          if decoded.toolName.len > 0: check text.contains(decoded.toolName)
          if decoded.kind in {aekToolCall, aekToolCallUpdate}:
            check vm.chat.activity.val.entries[^1].status == decoded.status
            check vm.chat.activity.val.entries[^1].data.sourceType == decoded.sourceType
            let tool = entryNode(rendered, vm.chat.activity.val.entries[^1].id)
            check tool != nil
            let expectedColor = if decoded.status == "started": gold
              elif decoded.status == "completed": green else: errorAccent
            check tool.styles.getOrDefault("border-left-color") == expectedColor

        let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
        check panel != nil
        for entry in vm.chat.activity.val.entries:
          check entry.data.raw == nil
          let presentation = activityPresentation(entry)
          check presentation.surface.len > 0
          if entry.kind == aekPlan:
            check presentation.facts.len == 3
            check presentation.facts[0].label == "completed"
            check presentation.facts[1].tone == "attention"
          if entry.kind == aekLlmRequest:
            check presentation.facts.anyIt(it.label == "Input tokens" and it.value == "1260")
            check presentation.facts.anyIt(it.label == "Output tokens" and it.value == "180")
          if entry.data.sourceType == "agent_question":
            check presentation.tone == "attention"
            if name == "question":
              check presentation.facts.anyIt(it.label == "Choice" and it.value == "Comfortable")
          if entry.data.sourceType == "file_read":
            check presentation.facts.anyIt(it.label == "From line" and it.value == "8")
          if entry.data.sourceType == "diff":
            check presentation.facts.anyIt(it.label == "Before" and it.value.contains("16px"))
            check presentation.facts.anyIt(it.label == "After" and it.value.contains("32px"))
          if name == "completed" and entry.role == arAssistant:
            check entry.status == "completed"
          if name == "conversation" and entry.kind == aekThoughtChunk:
            check entry.status == "streaming"
        dispose()
    check sources.len == 34
    for source in ["status", "log", "error", "thought", "tool_use", "tool_result",
        "file_edit", "file_read", "diff", "user_input", "plan", "turn_complete",
        "workspace", "sub_agent", "delegation", "orchestration", "llm_request",
        "context_files", "fleet_fence", "fleet_host", "session_started",
        "session_awaiting_input", "session_resumed", "session_ended",
        "proxy_credential_rotated", "proxy_rate_limit_absorbed", "dispatcher_restarted",
        "anti_halting_resume_confirmed", "session_leadership_migrated", "agent_question",
        "participant", "context_injection", "login_required", "link_spans"]:
      check source in sources

  test "normalized common tool states and settled thoughts remain distinct from REST DTOs":
    const corpusText = staticRead("scenarios/chat-activity/public-session-events.json")
    let corpus = parseJson(corpusText)
    for name, events in corpus["normalizedScenes"]:
      createRoot proc(dispose: proc()) =
        let vm = createEditorVM()
        vm.chat.addUserMessage("Inspect the hero")
        for payload in events.items:
          vm.chat.applyAgentEvent(agentEventFromJson(payload))
        if name == "tool-waiting": check vm.chat.activity.val.entries[^1].status == "pending"
        if name == "tool-running": check vm.chat.activity.val.entries[^1].status == "running"
        if name in ["tool-waiting", "tool-running"]:
          let panel = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
          let tool = entryNode(panel, vm.chat.activity.val.entries[^1].id)
          check tool != nil
          check tool.styles.getOrDefault("border-left-color") == gold
        if name == "thought-settled":
          check vm.chat.activity.val.entries[1].kind == aekThoughtChunk
          check vm.chat.activity.val.entries[1].status == "completed"
        dispose()
