## Phase C — sanity test that ``browser_agent_client.nim`` compiles
## under ``nim js`` without bringing the rest of the editor along.
##
## We can't drive real ``fetch`` calls from a headless test runner,
## but exercising the public surface compile-side catches every typo
## that the editor bundle's larger compile would also flag.  This is
## strictly a typing smoke; behavioural tests live in
## ``test_design_review_editor_agent_adapter_vm.nim``.

import std/json
import isonim/editor/design_review/browser_agent_client
import isonim/editor/design_review/editor_daemon_url
import isonim/editor/design_review/editor_agent_adapter

# Reference one symbol from each support module so the imports are
# not flagged as unused on either backend.  The bodies below exercise
# the rest.
const AdapterRoute = AgentSessionsPath
let probeEvent = agentEventFromSseJson(newJObject())
discard probeEvent
discard AdapterRoute

when defined(js):
  proc exerciseSurface() =
    let c = newBrowserAgentClient("http://example.test")
    c.onUpdate = proc(payload: cstring) {.closure.} = discard payload
    c.onEnd = proc(stop: cstring) {.closure.} = discard stop
    c.onError = proc(msg: cstring) {.closure.} = discard msg
    # createSession/submitPrompt/cancel just need to be callable.
    c.createSession(proc(sessionId: cstring) {.closure.} =
      c.submitPrompt($sessionId, "hello"))
    c.cancel("sid")
    # Daemon discovery returns a non-empty URL on every build path.
    doAssert resolveDaemonUrl().len > 0
    # The adapter helper installs an SSE dispatcher with no side
    # effects until called from a real fetch chain.
    installAgentDispatcher()

  exerciseSurface()
else:
  proc exerciseSurfaceNative() =
    # On native the module still compiles — the JS-only entry points
    # are gated and the proc bodies are no-ops.  Make sure that path
    # is wired.
    let c = newBrowserAgentClient("http://example.test")
    c.createSession(proc(sessionId: cstring) {.closure.} =
      discard sessionId)
    c.submitPrompt("sid", "hello")
    c.cancel("sid")
    doAssert resolveDaemonUrl().len > 0
    installAgentDispatcher()

  exerciseSurfaceNative()
