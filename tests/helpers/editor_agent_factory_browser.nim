## Mounted DOM fixture for explicit chat composition. No model/provider is used.
## Default adapter negative proof uses a genuinely closed production client;
## custom nonnil clients use the real adapter and control-bridge binding.
import std/[dom, json]
import isonim/core/signals
import isonim/core/owner
import isonim/editor/[browser, workspace, viewmodels, types]
import isonim/editor/design_review/[browser_agent_client, editor_agent_adapter]

var mode: cstring
{.emit: [mode, " = new URL(location.href).searchParams.get('mode') || 'default';"].}
let controlWorkspace = newEditorWorkspace(storyGroups = @[], title = "Agent factory control", id = "factory-control")
let vm = createEditorVM(controlWorkspace)
var factoryCalls = 0
var legacyCalls = 0
var localCalls = 0
var factoryError: ref ValueError
var priorConfigureCalls = 0
var activeFactoryBindings = 0
var cleanupFailures = 0
var activeLaterResources = 0
var activeTrackedRegistrations = 0
var unregisterFailures = 0
var configured: seq[AgentChatVM]
var clients: seq[BrowserAgentClient]
vm.chat.configureAgentAdapters(
  proc(prompt: string; context: AgentPromptContext): bool =
    inc legacyCalls
    true,
  proc(): bool = true, absAgentHarbor)
vm.configureChat = proc(chat: AgentChatVM) = inc priorConfigureCalls

proc factory(chat: AgentChatVM): BrowserAgentClient =
  inc factoryCalls
  configured.add chat
  inc activeFactoryBindings
  let bindingNumber = factoryCalls
  onCleanup proc() =
    dec activeFactoryBindings
    if ($mode in ["throws-new-cleanup", "throws-new-defect-cleanup"] and bindingNumber > 1) or
        ($mode in ["cleanup-failure", "unregister-throws"] and bindingNumber == 2):
      inc cleanupFailures
      if $mode == "throws-new-defect-cleanup":
        raise newException(AssertionDefect, "declared cleanup defect")
      raise newException(ValueError, "declared cleanup failure")
  if ($mode in ["throws-new-cleanup", "throws-new-defect-cleanup"] and bindingNumber > 1) or
      ($mode in ["cleanup-failure", "unregister-throws"] and bindingNumber == 2):
    inc activeLaterResources
    # Registered AFTER the callback that throws: old cleanNode leaks this.
    onCleanup proc() = dec activeLaterResources
  if $mode == "throws" or ($mode in ["throws-new", "throws-new-cleanup", "throws-new-defect-cleanup"] and factoryCalls > 1):
    factoryError = newException(ValueError, "declared factory failure")
    raise factoryError
  if $mode == "client":
    var ownedOrigin: cstring
    {.emit: [ownedOrigin, " = location.origin;"].}
    result = newBrowserAgentClient($ownedOrigin)
    chat.configureAgentAdaptersWithClient(result)
    clients.add result
  else:
    let captured = chat
    chat.configureAgentAdapters(
      proc(prompt: string; context: AgentPromptContext): bool =
        inc localCalls
        captured.addAgentResponse(prompt)
        true,
      proc(): bool = true, absAgentHarbor)
    # Deliberate explicit adapter-only result; no daemon client is claimed.
    result = nil

var caught = ""
var caughtSameError = false
try:
  if $mode == "default":
    discard mountEditor(vm, useHashRoute = false)
  else:
    discard mountEditor(vm, useHashRoute = false, configureAgentChat = factory)
except ValueError as error:
  caught = error.msg
  caughtSameError = error == factoryError

# Observe the actual production registration/unregistration handoff for NEW
# sessions. Initial ownership is independently exercised by close/binding tests.
if caught.len == 0:
  let actualTrack = vm.trackChatConfiguration
  vm.trackChatConfiguration = proc(dispose: ChatConfigurationDisposer): ChatConfigurationDisposer =
    let unregister = actualTrack(dispose)
    let throwOnUnregister = $mode == "unregister-throws" and factoryCalls == 2
    inc activeTrackedRegistrations
    var registered = true
    result = proc() =
      if registered:
        registered = false
        dec activeTrackedRegistrations
        unregister()
        if throwOnUnregister:
          inc unregisterFailures
          raise newException(ValueError, "declared unregister failure")

proc actualClient(chat: AgentChatVM): BrowserAgentClient =
  if $mode == "default":
    {.emit: [result, " = globalThis.__isonimEditorAgentClients?.get(", chat, ") || null;"].}
  else:
    for index, configuredChat in configured:
      if configuredChat == chat and index < clients.len:
        return clients[index]

proc snapshot(): cstring =
  let current = actualClient(vm.chat)
  var unique = true
  for i in 0 ..< configured.len:
    for j in 0 ..< i:
      if configured[i] == configured[j]: unique = false
  $(%*{"mode": $mode, "factoryCalls": factoryCalls, "legacyCalls": legacyCalls,
    "unregisterFailures": unregisterFailures, "activeTrackedRegistrations": activeTrackedRegistrations, "activeLaterResources": activeLaterResources, "cleanupFailures": cleanupFailures, "localCalls": localCalls, "chats": vm.chats.val.len, "uniqueChats": unique,
    "priorConfigureCalls": priorConfigureCalls, "activeFactoryBindings": activeFactoryBindings,
    "clientPresent": current != nil,
    "clientBound": current != nil and current.bindEditor != nil and current.onControlClosed != nil,
    "caught": caught, "caughtSameError": caughtSameError})

proc newChat() =
  try:
    discard vm.createNewChat()
  except ValueError as error:
    caught = error.msg
    caughtSameError = error == factoryError
proc closedClientNegative(): bool =
  let current = actualClient(vm.chat)
  if current == nil: return false
  current.closed = true
  not vm.chat.promptAdapter("must refuse closed client", AgentPromptContext())
proc localPrompt(text: cstring): bool =
  vm.chat.promptAdapter($text, AgentPromptContext())
proc reloadSameWorkspace() =
  # The real HMR overload returns the mounted VM and preserves composition.
  discard mountEditor(controlWorkspace, useHashRoute = false)
proc invokeRestoredConfigurator() = vm.configureChat(vm.chat)

proc selectInitial(): bool =
  vm.switchToChat(vm.chats.val[0].id)

proc deniedClose(): bool =
  let chat = vm.chat
  chat.closeAdapter = proc(done: proc(ok: bool) {.closure.}) = done(false)
  vm.closeChat(vm.activeChatId.val)

proc successfulClose(): bool =
  let chat = vm.chat
  chat.closeAdapter = proc(done: proc(ok: bool) {.closure.}) = done(true)
  vm.closeChat(vm.activeChatId.val)

proc disposeMountedRoot() =
  {.emit: "globalThis.__isonimEditorMount.dispose();".}

let initialFn = selectInitial
let deniedFn = deniedClose
let successfulFn = successfulClose
let disposeFn = disposeMountedRoot
let snapshotFn = snapshot
let newChatFn = newChat
let closedFn = closedClientNegative
let promptFn = localPrompt
let reloadFn = reloadSameWorkspace
let restoredFn = invokeRestoredConfigurator
{.emit: ["window.__agentFactoryProbe={snapshot:", snapshotFn, ",newChat:", newChatFn,
  ",closedClientNegative:", closedFn, ",prompt:", promptFn, ",reload:", reloadFn,
  ",invokeRestoredConfigurator:", restoredFn, ",selectInitial:", initialFn, ",deniedClose:", deniedFn,
  ",successfulClose:", successfulFn, ",disposeMountedRoot:", disposeFn, "};"].}
