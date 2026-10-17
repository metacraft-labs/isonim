## The ACP notify callback is substituted only to reenter the real registry
## synchronously. This exposes a lock held across transport IO deterministically;
## HTTP/provider lifetime and worker overlap are covered by the real route suites.
## Include the production implementation to exercise its private ownership paths
## without adding test hooks to the daemon API.
include ../src/isonim/editor/design_review/agent_routes
import std/unittest

test "idle cancellation permits transport notification to reenter registry":
  let reg = newAgentRegistry(primerEnabled = false)
  var notified = false
  let acp = newAcpClient(nil, notify = proc(raw: string) =
    check reg.getState("owned").isSome
    check parseJson(raw){"method"}.getStr == "session/cancel"
    notified = true)
  reg.sessions["owned"] = AgentSessionState(sessionId: "owned",
    client: fromAcp(acp), session: AgentSession(id: "backend", backend: abkAcp))
  cancelSession(reg, "owned")
  check notified
  reg.release("owned")

test "active cancellation borrows stable work while notification mutates registry":
  let reg = newAgentRegistry(primerEnabled = false)
  var notified = false
  let acp = newAcpClient(nil, notify = proc(raw: string) =
    check reg.getState("owned").isSome
    reg.release("owned")
    for index in 0..100:
      reg.sessions[$index] = AgentSessionState(sessionId: $index)
    check parseJson(raw){"params", "sessionId"}.getStr == "backend"
    notified = true)
  var workState = AgentSessionState(sessionId: "owned", client: fromAcp(acp),
    session: AgentSession(id: "backend", backend: abkAcp))
  reg.sessions["owned"] = workState
  reg.activePromptStates["owned"] = addr workState
  cancelSession(reg, "owned")
  check notified
  check workState.session.id == "backend"
  reg.activePromptStates.del("owned")
  reg.sessions.clear()
