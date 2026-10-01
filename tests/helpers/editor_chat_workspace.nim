## Mounted production editor for sidebar behavior/presentation verification.
## The fixture exposes only test-owned event injection and deterministic provider
## admission controls. These substitute external event timing, not the EditorVM,
## reducer, signals, DOM, preview renderer or keyboard/scroll implementation. Real
## REST/official-provider integration remains in the registered chat/control suites.
import std/json
import nim_agents
import isonim/editor
import isonim/editor/browser
import isonim/editor/agent_harbor
import isonim/editor/design_review/editor_agent_adapter
import isonim/core/signals
import isonim/viewmodel

proc preview(story: StoryRef; platform: Platform): ProjectPreview =
  ProjectPreview(status: ppsRendered, story: story, title: story.name,
    documentHtml: "<!doctype html><html><head><title>Chat preview</title></head><body><main><h1>Website preview</h1><button>Primary action</button></main></body></html>")

let vm = mountEditor(newEditorWorkspace("Chat acceptance", @[
  StoryGroup(name: "Pages", kind: skPage, items: @[
    StoryItem(name: "Home", group: "Pages", kind: skPage)])],
  id = "chat-acceptance", previewHook = preview))
discard vm.selectStory(StoryRef(kind: skPage, group: "Pages", name: "Home"))

proc event(payload: cstring) =
  vm.chat.applyAgentEvent(agentEventFromJson(parseJson($payload)))
proc harborEvent(payload: cstring) =
  let normalized = harborEventToAgentEvent("fixture-session", eventFromJson(parseJson($payload)))
  vm.chat.applyAgentEvent(agentEventFromSseJson(normalized.toJson()))
proc backend(accept: bool) =
  vm.chat.configureAgentAdapters(proc(prompt: string; context: AgentPromptContext): bool = accept, nil)
proc busy(value: bool) =
  vm.chat.asyncAgentAdapter = true
  vm.chat.promptInFlight = value
  vm.chat.sessionStatus.val = if value: asLoading else: asReady
proc newChat(): cstring = cstring(vm.createNewChat())
proc switchChat(id: cstring): bool = vm.switchToChat($id)
proc state(): cstring =
  var chats = newJArray()
  for session in vm.chats.val:
    chats.add %*{"id": session.id, "draft": session.vm.inputText.val}
  cstring($(%*{"active": vm.activeChatId.val, "chats": chats}))
proc width(value: int) = vm.setRightPanelWidth(value)
{.emit: ["window.__chatTest = {event:", event, ", harborEvent:", harborEvent, ", backend:", backend,
  ", busy:", busy, ", newChat:", newChat, ", switchChat:", switchChat,
  ", state:", state, ", width:", width, "};"].}
