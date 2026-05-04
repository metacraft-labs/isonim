import unittest
import std/json
import std/sequtils
import std/strutils
import nim_everywhere
import nim_agents
import isonim/core/signals
import isonim/viewmodel
import isonim/editor/agent_harbor
import isonim/editor/types
import isonim/editor/viewmodels

proc editorHarborSseTransport(): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-1",
        "session_ids": ["session-editor"],
        "status": "queued"
      }))
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-editor/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"authenticating\",\"message\":\"checking token\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"thought\",\"thought\":\"Inspecting the component\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"plan\",\"entries\":[{\"content\":\"Inspect stories\"},{\"content\":\"Patch spacing\"}]}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_use\",\"tool_name\":\"edit\",\"tool_execution_id\":\"tool-1\",\"status\":\"started\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"file_edit\",\"file_path\":\"src/Button.nim\",\"line\":42,\"lines_added\":2,\"lines_removed\":1,\"message\":\"patched Button.nim\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"diff\",\"file_path\":\"src/Button.nim\",\"line_start\":42,\"lines_added\":2,\"lines_removed\":1,\"diff\":\"@@ -42 +42 @@\",\"message\":\"spacing diff\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"review\",\"file_path\":\"src/Button.nim\",\"line\":42,\"severity\":\"warning\",\"category\":\"accessibility\",\"message\":\"Button needs accessible label\",\"status\":\"fixable\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_result\",\"tool_name\":\"edit\",\"tool_execution_id\":\"tool-1\",\"status\":\"completed\",\"tool_output\":\"patched Button.nim\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"log\",\"message\":\"Done\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"retrying\",\"message\":\"retrying stream\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"cancelling\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"cancelled\"}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"error\",\"message\":\"stream failed\"}\n\n")
    HttpResponse(status: 404, body: "not found")

suite "editor Agent Harbor adapter":
  test "editor_agent_harbor_task_request_includes_workspace_context":
    let config = EditorHarborConfig(
      enabled: true,
      tenantId: "tenant-a",
      projectId: "isonim-demo",
      workspaceRoot: "/work/isonim",
      repoMode: "git",
      repoUrl: "git@example.com:isonim.git",
      branch: "feature/m22",
      commit: "abc123",
      executionHostId: "linux-build-01",
      workingCopyMode: "overlay",
      acpAgent: acpAgentConfig(
        "mock-agent",
        @["--scenario", "editor.yaml"],
        model = "scenario-agent"))
    let story = StoryRef(group: "TaskRow", name: "Active", kind: skComponent, index: 1)
    let element = ElementRef(
      tag: "button",
      sourceFile: "/work/isonim/src/Button.nim",
      sourceLine: 42)
    let edits = @[EditRecord(
      file: "/work/isonim/src/Button.nim",
      line: 42,
      property: "padding",
      oldValue: "8px",
      newValue: "12px")]

    let req = buildEditorHarborTaskRequest(config, story, element, edits, "Make it clearer")
    let node = taskToJson(req)

    check node["tenantId"].getStr() == "tenant-a"
    check node["projectId"].getStr() == "isonim-demo"
    check node["labels"]["cwd"].getStr() == "/work/isonim"
    check node["repo"]["url"].getStr() == "git@example.com:isonim.git"
    check node["repo"]["branch"].getStr() == "feature/m22"
    check node["repo"]["commit"].getStr() == "abc123"
    check node["workspace"]["executionHostId"].getStr() == "linux-build-01"
    check node["workspace"]["workingCopyMode"].getStr() == "overlay"
    check node["prompt"].getElems().anyIt(it{"text"}.getStr("").contains("Make it clearer"))
    check node["prompt"].getElems().anyIt(it{"text"}.getStr("").contains("story: TaskRow/Active"))
    check node["prompt"].getElems().anyIt(it{"uri"}.getStr("").contains("Button.nim#L42"))
    check node["agents"][0]["agent"]["software"].getStr() == "acp"
    check node["agents"][0]["acpStdioLaunchCommand"]["binary"].getStr() == "mock-agent"

  test "editor_agent_harbor_stream_updates_chat_state":
    let chat = createAgentChatVM()
    let review = createReviewResultsVM()
    var agents = fromHarbor(newHarborClient("http://localhost:18080",
      editorHarborSseTransport()))
    let session = agents.startSession("/work/isonim", @[textBlock("Make it clearer")])
    let events = agents.readAgentEvents(session)

    check events.anyIt(it.kind == aekConnection and it.state == acsRetrying)
    check events.anyIt(it.kind == aekConnection and it.state == acsCancelling)
    check events.anyIt(it.kind == aekCancelled)
    check events.anyIt(it.kind == aekError and it.text == "stream failed")
    check events.anyIt(it.kind == aekFileEdit and it.filePath == "src/Button.nim")
    check events.anyIt(it.kind == aekDiff and it.diff == "@@ -42 +42 @@")
    check events.anyIt(it.kind == aekReview and it.reviewCategory == "accessibility")

    chat.applyAgentEvents(review, events[0 .. 8])

    check chat.messages.val.anyIt(it.kind == cmkContext and it.text == "Inspecting the component")
    check chat.messages.val.anyIt(it.kind == cmkContext and it.text == "patched Button.nim")
    check chat.messages.val.anyIt(it.kind == cmkAgent and it.text == "Done")
    check chat.planEntries.val == @["Inspect stories", "Patch spacing"]
    check chat.toolCalls.val.anyIt(it.contains("tool-1:edit:started"))
    check chat.toolCalls.val.anyIt(it.contains("tool-1:edit:completed"))
    check chat.accumulatedEdits.val.len == 2
    check chat.accumulatedEdits.val[0].file == "src/Button.nim"
    check chat.accumulatedEdits.val[0].line == 42
    check chat.accumulatedEdits.val[0].editOrigin == peoAgent
    check review.violations.val.len == 1
    check review.violations.val[0].file == "src/Button.nim"
    check review.violations.val[0].category == vcAccessibility
    check review.violations.val[0].autoFixable

    chat.applyAgentEvent(review, events[9])
    check chat.connectionState.val == "retrying"
    check chat.sessionStatus.val == asLoading

    chat.applyAgentEvents(review, events[10 .. 11])
    check chat.connectionState.val == "cancelled"
    check chat.stopReason.val == "cancelled"

    chat.applyAgentEvent(review, events[12])
    check chat.sessionStatus.val == asError
    check chat.messages.val.anyIt(it.kind == cmkError and it.text == "stream failed")
