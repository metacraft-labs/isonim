## Genuine production full-shell mode/tab/view lifetime with MockRenderer.
## MockRenderer substitutes browser DOM only; real signals, shell controls,
## view disposal and VM admission run. Recording adapters record authorization
## requests (no closure ACK), not Harbor/process/filesystem/compiler outcomes.
## Retained callbacks are invoked directly; removed DOM listeners are not proven.
## The full-shell JS canvas boundary is separately unresolved; this entry is native.
import std/[unittest,tables,options]
import isonim/core/[signals,computation,owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels,types,stories]
import isonim/editor/views/shell
proc find(node:MockNode;key,value:string):MockNode =
  if node.attributes.getOrDefault(key)==value:return node
  for child in node.children:
    result=find(child,key,value)
    if result!=nil:return
suite "Current shell chat callback lifetime":
  test "mode reuse stays live; conversation replacement and revisit retire all old controls":
    createRoot do(dispose:proc()):
      let r=MockRenderer();let vm=createEditorVM()
      vm.sidebar.groups.val=buildStoryboard();vm.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
      vm.setEditMode(emEdit)
      var prompts:seq[string];var cancels=0;var closes=0
      proc configure(chat:AgentChatVM) =
        chat.configureAgentAdapters(proc(prompt:string;context:AgentPromptContext):bool =
          prompts.add prompt;check context.selectedStory.name=="Active task";true,
          proc():bool = inc cancels;true)
        chat.closeAdapter=proc(done:proc(ok:bool)) = inc closes
      vm.configureChat=configure;configure(vm.chat)
      let shell=renderEditorShell[MockRenderer,MockNode](r,vm)
      check find(shell,"aria-label","Agent prompt")==nil
      let view=find(shell,"data-choice-group-label","View");let edit=find(shell,"data-choice-group-label","Edit")
      view.fireEvent("click")
      let input=find(shell,"aria-label","Agent prompt");let send=find(shell,"aria-label","Send agent prompt")
      check input!=nil and send!=nil
      r.setInputValue(input,"first prompt");input.fireEvent("input");send.fireEvent("click")
      check prompts== @["first prompt"]
      r.setInputValue(input,"retained draft");input.fireEvent("input")
      let original=vm.chat;let originalId=vm.activeChatId.val
      edit.fireEvent("click");view.fireEvent("click")
      check find(shell,"aria-label","Agent prompt")==input;check vm.chat==original
      send.fireEvent("click");check prompts== @["first prompt","retained draft"]
      let stale= @[input.eventListeners["input"][0],input.eventListeners["change"][0],send.eventListeners["click"][0],
        find(shell,"aria-label","Cancel agent prompt").eventListeners["click"][0],
        find(shell,"aria-label","Close conversation").eventListeners["click"][0]]
      let newChat=find(shell,"data-ai-assistant-new-chat","true");check newChat!=nil
      newChat.fireEvent("click")
      let current=find(shell,"aria-label","Agent prompt");check current!=nil and current!=input
      let newVm=vm.chat;r.setInputValue(current,"new untouched draft");current.fireEvent("input")
      let beforeMessages=newVm.messages.val;let beforeGeneration=newVm.promptGeneration
      for callback in stale:callback()
      check newVm.inputText.val=="new untouched draft";check newVm.messages.val==beforeMessages
      check newVm.promptGeneration==beforeGeneration;check cancels==0 and closes==0
      find(shell,"aria-label","Send agent prompt").fireEvent("click")
      check prompts== @["first prompt","retained draft","new untouched draft"]
      discard vm.switchToChat(originalId)
      let returned=find(shell,"aria-label","Agent prompt");check returned!=nil and returned!=input
      original.inputText.val="returned untouched draft"
      for callback in stale:callback()
      check original.inputText.val=="returned untouched draft";check original.promptGeneration==2
      check cancels==0 and closes==0
      find(shell,"aria-label","Send agent prompt").fireEvent("click")
      check prompts[^1]=="returned untouched draft"
      let retiredNew=newChat.eventListeners["click"][0]
      let sessions=vm.chats.val;let generation=original.promptGeneration
      dispose();retiredNew()
      check vm.chats.val==sessions;check vm.chat==original;check original.promptGeneration==generation
      check cancels==0 and closes==0
