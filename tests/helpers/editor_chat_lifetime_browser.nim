## Genuine production assistant panel and chat DOM lifecycle. Recording adapters
## isolate prompt/cancel/close request admission; close ACK is deliberately held.
## No Harbor/provider/worker outcome, filesystem/compiler or renderer is mocked.
## Public modes are covered separately by the native full-shell tests. The
## host width hook forwards to EditorVM.setRightPanelWidth, without RPC/bootstrap.
import std/[dom,json]
import isonim/editor/[browser,viewmodels,types]
import isonim/editor/dom_renderer
import isonim/editor/views/shell
import isonim/core/[signals,owner]
let editor=createEditorVM()
editor.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
var prompts:seq[string];var cancels=0;var closes=0
proc configure(chat:AgentChatVM) =
  chat.configureAgentAdapters(proc(prompt:string;context:AgentPromptContext):bool =
    prompts.add context.selectedStory.name & ":" & prompt;true,
    proc():bool = inc cancels;true)
  chat.closeAdapter=proc(done:proc(ok:bool)) = inc closes
editor.configureChat=configure;configure(editor.chat)
let originalId=editor.activeChatId.val
var disposeView:proc();var panel:Element
injectEditorStyles()
proc mountView() =
  createRoot do(dispose:proc()):
    disposeView=dispose
    panel=renderAiAssistantPanel[DomRenderer,Element](DomRenderer(),editor)
    document.body.appendChild(panel)
proc unmountView() =
  disposeView()
  if panel.parentNode!=nil:panel.parentNode.removeChild(panel)
proc state():cstring =
  var chats=newJArray()
  for session in editor.chats.val:
    let chat=session.vm
    chats.add %*{"id":session.id,"draft":chat.inputText.val,"messages": $chat.messages.val,
      "generation":chat.promptGeneration,"status": $chat.sessionStatus.val,"connection":chat.connectionState.val,
      "permissions": $chat.permissionRequests.val,"proposals": $chat.proposedEdits.val,
      "placeholdersDismissed":chat.placeholdersDismissed.val,"conversation":chat.controlConversationId.val}
  cstring($(%*{"active":editor.activeChatId.val,"original":originalId,"chats":chats,"prompts":prompts,
    "cancels":cancels,"closes":closes,"approval":editor.agentControlApproval.val,
    "width":editor.rightPanelWidth.val}))
proc backendIdentity() = editor.chat.controlConversationId.val="backend-initialized-after-render"
proc width(value:int) = editor.setRightPanelWidth(value)
mountView()
{.emit:["window.__isonimEditor={setRightPanelWidth:",width,"};"].}
{.emit:["window.__chatLifetime={state:",state,",unmount:",unmountView,",remount:",mountView,",backendIdentity:",backendIdentity,"};"].}
