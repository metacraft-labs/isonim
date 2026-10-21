## The actual editor VM reads/writes through a scripted backend. This is the
## deterministic backend contract, not a substitute browser storage adapter.
## Node has no localStorage: any reintroduced raw read loses the seeded state,
## and any raw write fails the backend's exact persisted-state assertions.
import std/[unittest, json, tables]
import isonim/core/[nondet, signals, owner]
import isonim/editor/[viewmodels, types]

suite "editor persistence boundary":
  test "drawer and inspector storage are routed through the selected backend":
    let previous = currentClock
    let selected = newTestBackend()
    install(selected)
    defer: install(previous)
    when defined(js):
      selected.script("storageGet", @[%"{\"open\":true,\"activeChatId\":\"chat-1\"}", %"layout,fill"])
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      when defined(js):
        check vm.aiDrawerOpen.val
        check vm.activeChatId.val == "chat-1"
        hydrateInspectorExpansionFromStorage(vm)
        check vm.inspector.expandedSections.val == @[isLayout, isFill]
        check selected.reads["storageGet"].len == 0
        check parseJson(selected.storage["isonim-editor-ai-drawer"])["open"].getBool()
        vm.aiDrawerOpen.val = false
        check not parseJson(selected.storage["isonim-editor-ai-drawer"])["open"].getBool()
        check parseJson(selected.storage["isonim-editor-ai-drawer"])["activeChatId"].getStr() == "chat-1"
      else:
        check not vm.aiDrawerOpen.val
        check selected.storage.len == 0
      dispose()
