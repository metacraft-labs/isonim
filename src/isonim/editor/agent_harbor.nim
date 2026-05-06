## IsoNim-owned adapter from editor context to the shared agent client model.

import nim_agents
import isonim/core/signals
import isonim/viewmodel
import isonim/editor/agent_context
import isonim/editor/types
import isonim/editor/viewmodels

type
  EditorHarborConfig* = object
    enabled*: bool
    tenantId*: string
    projectId*: string
    workspaceRoot*: string
    repoMode*: string
    repoUrl*: string
    branch*: string
    commit*: string
    executionHostId*: string
    workingCopyMode*: string
    acpAgent*: HarborAcpAgentConfig

proc buildEditorHarborTaskRequest*(config: EditorHarborConfig; story: StoryRef;
    element: ElementRef; edits: seq[EditRecord]; userPrompt: string): CreateTaskRequest =
  buildHarborTaskRequest(HarborTaskConfig(
    workspace: AgentWorkspaceContext(
      tenantId: config.tenantId,
      projectId: config.projectId,
      cwd: config.workspaceRoot,
      repoMode: config.repoMode,
      repoUrl: config.repoUrl,
      branch: config.branch,
      commit: config.commit,
      executionHostId: config.executionHostId,
      workingCopyMode: config.workingCopyMode),
    prompt: editorContextToAcpContentBlocks(story, element, edits, userPrompt),
    acpAgent: config.acpAgent))

proc buildEditorHarborTaskRequest*(config: EditorHarborConfig;
    context: AgentPromptContext; userPrompt: string): CreateTaskRequest =
  buildHarborTaskRequest(HarborTaskConfig(
    workspace: AgentWorkspaceContext(
      tenantId: config.tenantId,
      projectId: config.projectId,
      cwd: config.workspaceRoot,
      repoMode: config.repoMode,
      repoUrl: config.repoUrl,
      branch: config.branch,
      commit: config.commit,
      executionHostId: config.executionHostId,
      workingCopyMode: config.workingCopyMode),
    prompt: editorPromptContextToAcpContentBlocks(context, userPrompt),
    acpAgent: config.acpAgent))

proc addContextMessage(chat: AgentChatVM; text: string) =
  if text.len == 0:
    return
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkContext, text: text, timestamp: 0.0)

proc addErrorMessage(chat: AgentChatVM; text: string) =
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkError, text: text, timestamp: 0.0)

proc fileEditRecord(event: AgentEvent): EditRecord =
  EditRecord(
    file: event.filePath,
    line: event.line,
    property: "source",
    oldValue: "-" & $event.linesRemoved & " lines",
    newValue: "+" & $event.linesAdded & " lines",
    origin: poConstant,
    originDetail: "agent-harbor:" & $event.kind,
    scope: pesLocal,
    isShared: false,
    editOrigin: peoAgent)

proc reviewSeverity(value: string): ViolationSeverity =
  case value
  of "error": vsError
  else: vsWarning

proc reviewCategory(value: string): ViolationCategory =
  case value
  of "accessibility": vcAccessibility
  of "direct_style": vcDirectStyle
  of "dry_tokens": vcDryTokens
  of "html_builder": vcHtmlBuilder
  of "story_coverage": vcStoryCoverage
  of "tailwind_preference": vcTailwindPreference
  of "viewmodel_boundary": vcViewModelBoundary
  else: vcMockCompleteness

proc addReviewViolation(review: ReviewResultsVM; event: AgentEvent) =
  review.violations.update proc(prev: seq[Violation]): seq[Violation] =
    result = prev
    result.add Violation(
      severity: reviewSeverity(event.reviewSeverity),
      category: reviewCategory(event.reviewCategory),
      message: event.text,
      file: event.filePath,
      line: event.line,
      autoFixable: event.kind == aekReview and event.status == "fixable")

proc applyAgentEvent*(chat: AgentChatVM; event: AgentEvent) =
  case event.kind
  of aekConnection:
    chat.connectionState.val = $event.state
    case event.state
    of acsDisconnected:
      chat.sessionStatus.val = asIdle
    of acsError:
      chat.sessionStatus.val = asError
      chat.addErrorMessage(event.text)
    of acsCompleted, acsCancelled:
      chat.sessionStatus.val = asReady
      chat.stopReason.val = $event.stopReason
    else:
      chat.sessionStatus.val = asLoading
  of aekMessageChunk:
    chat.addAgentResponse(event.text)
    chat.sessionStatus.val = asLoading
  of aekThoughtChunk:
    chat.addContextMessage(event.text)
    chat.sessionStatus.val = asLoading
  of aekPlan:
    chat.planEntries.val = event.planEntries
    chat.sessionStatus.val = asLoading
  of aekToolCall:
    chat.toolCalls.update proc(prev: seq[string]): seq[string] =
      result = prev
      result.add event.toolCallId & ":" & event.toolName & ":" & event.status
    chat.sessionStatus.val = asLoading
  of aekToolCallUpdate:
    chat.toolCalls.update proc(prev: seq[string]): seq[string] =
      result = prev
      result.add event.toolCallId & ":" & event.toolName & ":" & event.status
    if event.text.len > 0:
      chat.addContextMessage(event.text)
  of aekFileEdit:
    chat.recordEdit(event.fileEditRecord())
    let summary = event.filePath & " +" & $event.linesAdded & " -" & $event.linesRemoved
    chat.addContextMessage(summary)
    chat.sessionStatus.val = asLoading
  of aekDiff:
    chat.recordEdit(event.fileEditRecord())
    let summary =
      if event.text.len > 0: event.text
      elif event.diff.len > 0: event.filePath & " diff received"
      else: event.filePath & " changed"
    chat.addContextMessage(summary)
    chat.sessionStatus.val = asLoading
  of aekDelivery:
    if event.text.len > 0:
      chat.addContextMessage("delivery " & event.status & ": " & event.text)
    chat.sessionStatus.val = asLoading
  of aekReview:
    if event.text.len > 0:
      chat.addContextMessage("review: " & event.text)
    chat.sessionStatus.val = asLoading
  of aekLlmRequest, aekSubAgent:
    if event.text.len > 0:
      chat.addContextMessage(event.text)
    chat.sessionStatus.val = asLoading
  of aekStatus:
    if event.status.len > 0:
      chat.connectionState.val = event.status
    chat.sessionStatus.val = asLoading
  of aekError:
    chat.connectionState.val = $acsError
    chat.sessionStatus.val = asError
    chat.stopReason.val = $event.stopReason
    chat.addErrorMessage(event.text)
  of aekCancelled:
    chat.connectionState.val = $acsCancelled
    chat.sessionStatus.val = asReady
    chat.stopReason.val = $event.stopReason
  of aekCompleted:
    chat.connectionState.val = $acsCompleted
    chat.sessionStatus.val = asReady
    chat.stopReason.val = $event.stopReason

proc applyAgentEvents*(chat: AgentChatVM; events: openArray[AgentEvent]) =
  for event in events:
    chat.applyAgentEvent(event)

proc applyAgentEvent*(chat: AgentChatVM; review: ReviewResultsVM; event: AgentEvent) =
  chat.applyAgentEvent(event)
  if event.kind == aekReview:
    review.addReviewViolation(event)

proc applyAgentEvents*(chat: AgentChatVM; review: ReviewResultsVM;
    events: openArray[AgentEvent]) =
  for event in events:
    chat.applyAgentEvent(review, event)

func agentEventSourceScopeChoices(event: AgentEvent): seq[SourceScopeChoice] =
  let impact = SourceScopeImpact(
    ownerLabel: "Agent Harbor proposal",
    sourceFile: event.filePath,
    sourceLine: event.line,
    usageCount: 1,
    riskLevel: ssrLow,
    summary: "updates the proposed source edit")
  @[SourceScopeChoice(
    kind: sskLocalInstance,
    label: sourceScopeChoiceLabel(sskLocalInstance),
    ownerLabel: impact.ownerLabel,
    sourceFile: impact.sourceFile,
    sourceLine: impact.sourceLine,
    editable: true,
    usageCount: impact.usageCount,
    riskLevel: impact.riskLevel,
    impact: impact,
    reason: "Agent Harbor event did not include a project-owned schema scope.")]

func proposalPlanFromEvent(event: AgentEvent): SourceEditPlan =
  let before =
    if event.linesRemoved > 0: "-" & $event.linesRemoved & " lines"
    else: ""
  let after =
    if event.diff.len > 0: event.diff
    elif event.text.len > 0: event.text
    elif event.linesAdded > 0: "+" & $event.linesAdded & " lines"
    else: "agent edit"
  SourceEditPlan(
    file: event.filePath,
    line: event.line,
    property: "source",
    oldValue: before,
    newValue: after,
    originDetail: "nim-agents:" & $event.kind,
    scope: pesLocal,
    sourceScope: sskLocalInstance,
    planKind: cspInlineStyleUpdate,
    sourceScopeChoices: agentEventSourceScopeChoices(event),
    reversible: true,
    previewBefore: before,
    previewAfter: after,
    conflictKey: event.filePath & ":" & $event.line & ":agent",
    expectedOldValue: before)

func proposalDiffFromEvent(event: AgentEvent): AgentFileDiff =
  AgentFileDiff(
    file: event.filePath,
    beforeText: "-" & $event.linesRemoved & " lines",
    afterText:
      if event.diff.len > 0: event.diff
      elif event.text.len > 0: event.text
      else: "+" & $event.linesAdded & " lines",
    summary: event.filePath & " +" & $event.linesAdded & " -" &
      $event.linesRemoved)

proc applyAgentEvent*(editor: EditorVM; event: AgentEvent) =
  editor.chat.applyAgentEvent(editor.review, event)
  case event.kind
  of aekFileEdit, aekDiff:
    if event.filePath.len > 0:
      discard editor.chat.addAgentEditProposal(AgentEditProposal(
        title: "Agent source edit",
        summary: proposalDiffFromEvent(event).summary,
        sourceEdits: @[proposalPlanFromEvent(event)],
        diffs: @[proposalDiffFromEvent(event)]))
  of aekReview:
    if editor.chat.proposedEdits.val.len > 0:
      var proposals = editor.chat.proposedEdits.val
      proposals[^1].reviewDiagnostics.add AgentDiagnosticSnapshot(
        source: "agent-review",
        severity: event.reviewSeverity,
        category: event.reviewCategory,
        message: event.text,
        file: event.filePath,
        line: event.line)
      editor.chat.proposedEdits.val = proposals
  of aekToolCall:
    if event.status == "permission_required":
      discard editor.chat.addAgentPermissionRequest(AgentPermissionRequest(
        title: event.toolName,
        detail: event.text,
        options: @["allow", "deny"]))
  else:
    discard

proc applyAgentEvents*(editor: EditorVM; events: openArray[AgentEvent]) =
  for event in events:
    editor.applyAgentEvent(event)
