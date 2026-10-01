## Production chat VM + pure reducer and safe block parser, native and JS.
## A synchronous admission closure substitutes only the external provider request
## boundary to force rejection. The generic-backend compatibility case uses the
## real MockRenderer backend to prove production views need no browser globals;
## actual DOM focus/selection is covered by the mounted GUI suite. EditorVM and
## signals/reducer remain production code.
import std/[unittest, strutils, tables]
import nim_agents
import isonim/viewmodel
import isonim/core/[signals, computation, owner]
import isonim/editor/[viewmodels, agent_harbor]
import isonim/editor/views/[chat_activity, chat_panel]
import isonim/testing/mock_dom

proc activityNode(node: MockNode; role: string): MockNode =
  if node.attributes.getOrDefault("data-chat-role") == role: return node
  for child in node.children:
    result = activityNode(child, role)
    if result != nil: return


suite "Chat activity and composition":
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
