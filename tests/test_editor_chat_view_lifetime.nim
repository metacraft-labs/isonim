## Production chat widget/view ownership under real signals and cleanup.
## MockRenderer supplies a renderer-independent tree/events only. Recording
## prompt/cancel/close adapters isolate request admission (close ACK is held),
## not Harbor transport, worker termination, filesystem/compiler or provider
## results. Saved closures test captured-callback safety, not DOM listener removal.
import std/[unittest,tables,options,strutils]
import isonim/core/[signals,computation,owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels,types]
import isonim/editor/views/chat_panel

proc find(node:MockNode;key,value:string):MockNode =
  if node.attributes.getOrDefault(key)==value:return node
  for child in node.children:
    result=find(child,key,value)
    if result!=nil:return
proc snapshot(vm:EditorVM):string =
  result = $vm.activeChatId.val & "/" & $vm.agentControlApproval.val & "/" & $vm.rightPanelWidth.val
  for session in vm.chats.val:
    let chat=session.vm
    result.add "|" & session.id & "/" & chat.inputText.val & "/" & $chat.messages.val & "/" &
      $chat.promptGeneration & "/" & $chat.sessionStatus.val & "/" & chat.connectionState.val & "/" &
      $chat.permissionRequests.val & "/" & $chat.proposedEdits.val & "/" & $chat.placeholdersDismissed.val

suite "Chat view callback ownership":
  test "current controls admit context and disposal never closes retained conversations":
    let vm=createEditorVM();let r=MockRenderer()
    vm.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
    let chat=vm.chat
    var prompts:seq[string];var cancels=0;var closes=0
    chat.configureAgentAdapters(proc(prompt:string;context:AgentPromptContext):bool =
      prompts.add prompt;check context.selectedStory.name=="Active task";true,
      proc():bool = inc cancels;true)
    chat.closeAdapter=proc(done:proc(ok:bool)) = inc closes
    var panel:MockNode;var disposeView:proc()
    createRoot do(dispose:proc()):
      disposeView=dispose;panel=renderChatPanel[MockRenderer,MockNode](r,vm)
    let input=find(panel,"aria-label","Agent prompt")
    let send=find(panel,"aria-label","Send agent prompt")
    let cancel=find(panel,"aria-label","Cancel agent prompt")
    let close=find(panel,"aria-label","Close conversation")
    check input!=nil and send!=nil and cancel!=nil and close!=nil
    # Backend identity initialization is not a new editor conversation.
    chat.controlConversationId.val="backend-initialized-later"
    r.setInputValue(input,"first prompt");input.fireEvent("input");send.fireEvent("click")
    check prompts== @["first prompt"];check chat.promptGeneration==1
    cancel.fireEvent("click");check cancels==1
    let approval=find(panel,"data-editor-control-approval","true")
    let beforeApproval=vm.agentControlApproval.val;approval.fireEvent("change")
    check vm.agentControlApproval.val!=beforeApproval
    let width=vm.rightPanelWidth.val;find(panel,"aria-label","Widen right panel").fireEvent("click")
    check vm.rightPanelWidth.val==width+40
    close.fireEvent("click");check closes==1
    r.setInputValue(input,"retained draft");input.fireEvent("input")
    let before=snapshot(vm)
    let stale= @[input.eventListeners["input"][0],input.eventListeners["change"][0],
      send.eventListeners["click"][0],cancel.eventListeners["click"][0],close.eventListeners["click"][0],
      find(panel,"data-editor-control-approval","true").eventListeners["change"][0],
      find(panel,"aria-label","Widen right panel").eventListeners["click"][0],
      find(panel,"aria-label","Insert suggested prompt").eventListeners["click"][0]]
    disposeView()
    r.setInputValue(input,"retired input")
    for callback in stale:callback()
    check snapshot(vm)==before;check prompts== @["first prompt"]
    check cancels==1 and closes==1;check vm.chat==chat

  test "foreign conversation or replaced object cannot authorize an old view":
    let vm=createEditorVM();let r=MockRenderer();let original=vm.chat;let id=vm.activeChatId.val
    var calls=0
    original.configureAgentAdapters(proc(prompt:string;context:AgentPromptContext):bool = inc calls;true)
    var panel:MockNode;var disposeView:proc()
    createRoot do(dispose:proc()):
      disposeView=dispose;panel=renderChatPanel[MockRenderer,MockNode](r,vm)
    let input=find(panel,"aria-label","Agent prompt");let send=find(panel,"aria-label","Send agent prompt")
    r.setInputValue(input,"old payload")
    discard vm.createNewChat();vm.chat.inputText.val="current untouched draft"
    let before=snapshot(vm);input.fireEvent("input");send.fireEvent("click")
    check snapshot(vm)==before;check calls==0
    let replacement=createAgentChatVM();replacement.inputText.val="replacement draft"
    vm.chats.val= @[ChatSession(id:id,vm:replacement,title:createSignal("Replacement"))]
    vm.activeChatId.val=id
    let replaced=snapshot(vm);input.fireEvent("change");send.fireEvent("click")
    check snapshot(vm)==replaced;check calls==0
    disposeView()

  test "replaced permission rows retire saved actions while new actions stay live":
    let vm=createEditorVM();let r=MockRenderer();let chat=vm.chat
    chat.permissionRequests.val= @[AgentPermissionRequest(id:"permission",title:"Original",status:apsPending)]
    createRoot do(dispose:proc()):
      let panel=renderChatPanel[MockRenderer,MockNode](r,vm)
      let old=find(panel,"aria-label","Allow agent permission permission")
      check old!=nil
      let saved=old.eventListeners["click"][0]
      chat.permissionRequests.val= @[AgentPermissionRequest(id:"permission",title:"Replacement",status:apsPending)]
      let current=find(panel,"aria-label","Allow agent permission permission")
      check current!=nil and current!=old
      saved();check chat.permissionRequests.val[0].status==apsPending
      current.fireEvent("click");check chat.permissionRequests.val[0].status==apsGranted
      dispose()
