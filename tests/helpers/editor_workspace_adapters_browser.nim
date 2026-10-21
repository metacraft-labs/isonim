## Explicit project adapter composition through the real production browser
## mount. The authored callback records admission and supplies a deterministic
## offline reply; it claims no provider/network result. A separate default-mode
## page observes the real daemon client requesting a naturally absent endpoint.
import std/[dom, json]
import isonim/core/signals
import isonim/editor/[browser, workspace, viewmodels, types]
var editor: EditorVM
var prompts: seq[string]
var defaultMode: bool
{.emit: [defaultMode, " = new URLSearchParams(location.search).has('default');"].}
var project = newEditorWorkspace("Adapter composition fixture", @[])
if not defaultMode:
  project.agentPromptAdapter = proc(prompt: string; context: AgentPromptContext): bool =
    prompts.add editor.activeChatId.val & ":" & prompt
    editor.chat.addAgentResponse("Authored reply: " & prompt)
    true
editor = mountEditor(project)
proc state(): cstring =
  var chats = newJArray()
  for session in editor.chats.val:
    chats.add %*{"id": session.id, "messages": session.vm.messages.val.len,
      "status": $session.vm.sessionStatus.val, "draft": session.vm.inputText.val}
  ($(%*{"prompts": prompts, "chats": chats, "active": editor.activeChatId.val})).cstring
proc unmount() = discard unmountEditor(editor)
proc remount() = discard mountEditor(editor)
proc newChat() = discard editor.createNewChat()
proc focusComposer(): bool =
  editor.controlFocusAdapter != nil and editor.controlFocusAdapter("composer")
{.emit: ["window.__adapterProbe={state:", state, ",unmount:", unmount,
  ",remount:", remount, ",newChat:", newChat, ",focusComposer:", focusComposer, "};"].}
