## Mounted production editor for sidebar behavior/presentation verification.
## The fixture exposes only test-owned event injection and deterministic provider
## admission controls. The control fixture delivers requests directly to the shared
## production admission/approval host instead of network polling. Production DOM
## focus, selection and highlight adapters stay installed; genuine CLI/RPC and
## official Rust REST integration remain separate mandatory suites. localApprovals
## explicitly owns the connected/disconnected transport state for this local host;
## it does not change the production approval guard or inject completion results.
## The mounted negative control proves a disconnected pending request cannot apply.
## Code-reading reconciliation also reseeds this synthetic transcript through the
## real activity signal for restored-block replacement/removal; append-only
## public provider events cannot exercise these view disposal paths. No new event
## discriminator or test-only rendered control is introduced.
## Refresh regression seeds a save diagnostic/pending plan to isolate error
## ownership; it calls the actual hot-bundle mount/recovery policies. Actual
## failed writes/compiler behavior remain covered by registered source suites.
## These substitute external event timing, not the EditorVM,
## reducer, signals, DOM, preview renderer or keyboard/scroll implementation. Real
## REST/official-provider integration remains in the registered chat/control suites.
import std/[json, tables]
import nim_agents
import nim_agents/activity
import isonim/editor
import isonim/editor/browser
import isonim/editor/control
import isonim/editor/agent_harbor
import isonim/editor/design_review/editor_agent_adapter
import isonim/core/signals
import isonim/viewmodel

proc preview(story: StoryRef; platform: Platform): ProjectPreview =
  ProjectPreview(status: ppsRendered, story: story, title: story.name,
    documentHtml: "<!doctype html><html><head><title>Chat preview</title></head><body><main><h1>Website preview</h1><button data-isonim-element-id='primary'>Primary action</button><button data-isonim-element-id='secondary'>Secondary action</button></main></body></html>")

let vm = mountEditor(newEditorWorkspace("Chat acceptance", @[
  StoryGroup(name: "Pages", kind: skPage, items: @[
    StoryItem(name: "Home", group: "Pages", kind: skPage),
    StoryItem(name: "Details", group: "Pages", kind: skPage)])],
  id = "chat-acceptance", previewHook = preview))
discard vm.selectStory(StoryRef(kind: skPage, group: "Pages", name: "Home"))

# Re-enter the production mount path, as a freshly evaluated bundle does.
# Only the project workspace is synthetic; no editor or refresh API is mocked.
proc remount(foreign: bool): cstring =
  let refreshed = mountEditor(newEditorWorkspace("Reloaded project", @[
    StoryGroup(name: "Pages", kind: skPage, items: @[
      StoryItem(name: "Home", group: "Pages", kind: skPage),
      StoryItem(name: "Details", group: "Pages", kind: skPage)])],
    id = (if foreign: "foreign-project" else: "chat-acceptance"),
    previewHook = preview))
  cstring($(%* {"sameVM": refreshed == vm, "workspace": vm.workspaceId,
    "instance": vm.controlInstanceId, "adapterReady": vm.chat.promptAdapter != nil,
    "stage": $vm.workspaceEditStage.val}))
proc recoverBuild(): cstring =
  vm.recoverProjectBuild()
  cstring($(%* {"stage": $vm.workspaceEditStage.val}))
proc seedSaveFailure() =
  # Isolate diagnostic ownership; real filesystem refusal is tested separately.
  vm.inspector.pendingSourceEdits.val = @[SourceEditPlan(file: "source.nim",
    property: "width", newValue: "12px")]
  vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(
    kind: wedWriteFailed, message: "Existing source write refusal.")]
  vm.workspaceEditStage.val = wesFailed
proc event(payload: cstring) =
  vm.chat.applyAgentEvent(agentEventFromJson(parseJson($payload)))
proc harborEvent(payload: cstring) =
  let normalized = harborEventToAgentEvent("fixture-session", eventFromJson(parseJson($payload)))
  vm.chat.applyAgentEvent(agentEventFromSseJson(normalized.toJson()))
proc replaceActivityText(text: cstring) =
  var state = vm.chat.activity.val
  for index in 0 ..< state.entries.len:
    if state.entries[index].role == arAssistant: state.entries[index].text = $text
  vm.chat.activity.val = state
proc removeActivityEntries() =
  var state = vm.chat.activity.val
  state.entries.setLen(0)
  vm.chat.activity.val = state

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
  cstring($(%*{"active": vm.activeChatId.val, "chats": chats,
    "busy":vm.chat.promptInFlight,"admitted":vm.chat.promptAdmitted,
    "connection":vm.chat.connectionState.val,"sessionStatus": $vm.chat.sessionStatus.val,
    "pendingEdits":vm.chat.accumulatedEdits.val}))
proc fixtureControlState(): cstring = cstring($vm.controlSnapshot())
proc fixtureCommand(payload: cstring): cstring =
  var request = parseJson($payload)
  let current = vm.controlSnapshot()
  request["workspace"] = current["workspace"]
  request["instance"] = current["instance"]
  if request{"expectedRevision"} == nil: request["expectedRevision"] = current["revision"]
  cstring($vm.admitControlOperation(request))
# Read-only diagnostics retain the actual stored request/outcome and connection.
# Looking up a pending record must never resolve, apply or deny it.
proc fixtureControlDiagnostics(id: cstring): cstring =
  let operation = if vm.controlOperations.hasKey($id): vm.controlOperations[$id] else: newJNull()
  cstring($(%* {"connected": vm.controlConnected, "operation": operation,
    "state": vm.controlState()}))
proc localApprovals(connected: bool = true) =
  vm.requestControlApproval = nil
  vm.controlConnected = connected
proc fixtureApproval(id: cstring; approve: bool): cstring =
  cstring($vm.resolveControlApproval($id, approve))
proc repeatStoryReveal() = vm.controlStoryRevealAdapter()
proc width(value: int) = vm.setRightPanelWidth(value)
{.emit: ["window.__chatTest = {event:", event, ", harborEvent:", harborEvent, ", backend:", backend,
  ", busy:", busy, ", newChat:", newChat, ", switchChat:", switchChat,
  ", remount:", remount, ", recoverBuild:", recoverBuild, ", seedSaveFailure:", seedSaveFailure, ", state:", state, ", controlState:", fixtureControlState, ", control:", fixtureCommand,
  ", controlDiagnostics:", fixtureControlDiagnostics, ", localApprovals:", localApprovals, ", approval:", fixtureApproval,
  ", replaceActivityText:", replaceActivityText, ", removeActivityEntries:", removeActivityEntries,
  ", repeatStoryReveal:", repeatStoryReveal, ", width:", width, "};"].}
