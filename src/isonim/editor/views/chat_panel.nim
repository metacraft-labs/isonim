## IsoNim Editor — AI Assistant Chat Panel.
##
## Ever-present panel on the right side of every screen.
## Renders explicit chat state from the editor ViewModel.

import std/[json, sequtils, strutils]
import nim_agents/activity_presentation
import isonim/editor/control

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim/dsl/ui
import isonim/editor/viewmodels
import ./chat_activity

import ./chat_theme

proc rememberPanelFocus(vm: EditorVM; id: string): proc() =
  let captured = id
  result = proc() =
    vm.inspector.rememberInspectorFocus(captured)

proc chatStatusText(vm: EditorVM): string =
  let chat = vm.chat
  let reported = reportedActivityCondition(chat.activity.val)
  let state = chat.sessionStatus.val
  let connection = chat.connectionState.val
  let inFlight = chat.promptInFlight
  if chat.closingSession: return "Closing conversation"
  var progress = "Reply still open"
  if not inFlight:
    progress = case state
      of asIdle: "No active reply"
      of asLoading: "Reply still open"
      of asReady: "Ready for next message"
      of asError: "Reply failed"
  if state == asError: return "Reply failed"
  if reported.len > 0:
    return reported & "\n" & progress
  case state
  of asIdle: (if inFlight: "Waiting for reply" else: "Start a conversation")
  of asLoading: "Working"
  of asReady:
    if inFlight: "Finishing reply"
    elif connection == "cancelled": "Reply stopped"
    else: "Ready for next message"
  of asError: "Reply failed"

proc proposalStatusText(status: AgentEditProposalStatus): string
proc permissionStatusText(status: AgentPermissionStatus): string
proc annotationStateText(state: ReviewAnnotationState): string
proc proposalValidityText(validity: AgentEditProposalValidity): string

proc proposalStatusText(status: AgentEditProposalStatus): string =
  case status
  of aepsProposed: "proposed"
  of aepsAccepted: "accepted"
  of aepsPartiallyAccepted: "partially accepted"
  of aepsRejected: "rejected"
  of aepsReverted: "reverted"
  of aepsFailed: "failed"

proc permissionStatusText(status: AgentPermissionStatus): string =
  case status
  of apsPending: "pending"
  of apsGranted: "granted"
  of apsDenied: "denied"
  of apsCancelled: "cancelled"

proc annotationStateText(state: ReviewAnnotationState): string =
  case state
  of ransOpen: "open"
  of ransResolved: "resolved"
  of ransDismissed: "dismissed"

proc proposalValidityText(validity: AgentEditProposalValidity): string =
  case validity
  of aepvCurrent: "current"
  of aepvNeedsRebase: "needs rebase"
  of aepvStale: "stale"

proc renderChatPanel*[R, E](r: R; vm: EditorVM): E =
  let chat = vm.chat
  let agentState = signals.val(chat.sessionStatus)
  # Idle uses textSecondary (not textDim) so the connection-status dot reads
  # as an actual indicator, not body text. Loading/ready/error keep their
  # semantic colours.
  let statusColor = case agentState
    of asIdle: textSecondary
    of asLoading: gold
    of asReady: green
    of asError: gold

  # The chat panel is now always embedded inside the right sidebar's
  # Assistant tab body (shell.nim::assistantBody). The tab body
  # provides width / border / background; the chat panel only renders
  # content. Filling its parent via flex:1 (instead of an absolute
  # height: 100%) ensures the messagesArea + reviewLoopArea + compose
  # form span the full available height when the sidebar is tall.
  let panel = ui(r):
    tdiv(
      class = "editor-chat",
      display = "flex",
      flex_direction = "column",
      flex = "1",
      min_height = "0",
      width = "100%",
      min_width = "0",
      max_width = "100%",
      overflow_x = "hidden")
  r.setAttribute(panel, "data-chat-local-id", vm.activeChatId.val)

  var statusTextNode: E
  var narrowButton: E
  var resetButton: E
  var widenButton: E
  # Per-user 2026-05-27: drop the visible "AI Assistant / Empty / Idle"
  # header. The Assistant tab label in the sidebar is the canonical
  # identifier; status moves there. Offscreen affordances kept for
  # behaviour tests that key off them.
  var inspectorToggleButton: E
  let header = ui(r):
    tdiv(
      position = "absolute", left = "-9999px",
      width = "1px", height = "1px",
      overflow = "hidden"):
      tdiv(ref = narrowButton, `role` = "button", tabindex = "0",
            `aria-label` = "Narrow right panel"):
        text "-"
      tdiv(ref = resetButton, `role` = "button", tabindex = "0",
            `aria-label` = "Reset right panel width"):
        text "w"
      tdiv(ref = widenButton, `role` = "button", tabindex = "0",
            `aria-label` = "Widen right panel"):
        text "+"
      tdiv(ref = inspectorToggleButton, `role` = "button", tabindex = "0",
            `aria-label` = "Toggle inspector panel",
            onclick = proc() = vm.togglePanel(epInspector),
            onkeydown = proc() = vm.togglePanel(epInspector)):
        text "\xE2\x9C\x95"
      span(ref = statusTextNode):
        text chatStatusText(vm)
  r.appendChild(panel, header)
  r.setAttribute(statusTextNode, "data-chat-session-summary", "true")
  createRenderEffect proc() =
    r.setTextContent(statusTextNode, chatStatusText(vm))
  var approvalSetting: E
  let controlSettings = ui(r):
    tdiv(padding = "8px 12px", border_bottom = "1px solid " & borderFaint):
      label(display = "flex", align_items = "center", gap = "8px", color = textSecondary, font_size = "12px"):
        input(ref = approvalSetting, `type` = "checkbox",
          `data-editor-control-approval` = "true",
          `aria-describedby` = "isonim-agent-navigation-help")
        text "Require approval for agent navigation"
      tdiv(id = "isonim-agent-navigation-help",
          `data-editor-control-approval-help` = "true",
          margin_top = "6px", font_size = "11px", line_height = "1.5",
          color = textSecondary):
        text "Turn off to let the agent focus, select, and highlight items automatically."
  r.addEventListener(approvalSetting, "change", proc() =
    vm.agentControlApproval.val = not vm.agentControlApproval.val
    discard vm.refreshControlRevision())
  createRenderEffect proc() =
    r.setAttribute(approvalSetting, "aria-checked", $vm.agentControlApproval.val)
    when defined(js) and compiles(panel.ownerDocument):
      let checked = vm.agentControlApproval.val
      {.emit: [approvalSetting, ".checked = ", checked, ";"].}
  r.appendChild(panel, controlSettings)
  var controlHistory: E
  controlHistory = ui(r):
    tdiv(`data-editor-control-history` = "true", max_height = "160px",
      flex_shrink = "0", overflow_y = "auto")
  # Control history is inserted into the conversation scroll area below.
  proc appendControlOperation(operation: JsonNode) =
    # Each row owns its callback scope; loop locals otherwise share a JS closure.
    let conversation = operation{"request", "conversation"}.getStr()
    let id = operation{"operationId"}.getStr()
    let status = operation{"status"}.getStr()
    let caption = (if conversation.len == 0: "Editor automation: " else: "This conversation: ") &
      operation{"request", "command"}.getStr() & " " &
      operation{"request", "target"}.getStr(operation{"request", "storyId"}.getStr())
    let row = ui(r):
      tdiv(`data-editor-control-operation` = id, `data-operation-status` = status,
           padding = "8px 12px", font_size = "12px", color = textSecondary,
           border_bottom = "1px solid " & borderFaint):
        text caption & " — " & status
    if status == "pending":
      let approveId = id
      let approve = ui(r):
        button(`data-editor-control-approve` = id, margin_top = "6px", margin_right = "8px",
          onclick = proc() =
            if vm.requestControlApproval != nil: vm.requestControlApproval(approveId, true)
            else: discard vm.resolveControlApproval(approveId, true)):
          text "Approve"
      let reject = ui(r):
        button(`data-editor-control-reject` = id, margin_top = "6px",
          onclick = proc() =
            if vm.requestControlApproval != nil: vm.requestControlApproval(approveId, false)
            else: discard vm.resolveControlApproval(approveId, false)):
          text "Reject"
      r.appendChild(row, approve)
      r.appendChild(row, reject)
    r.appendChild(controlHistory, row)
  createRenderEffect proc() =
    r.clearChildren(controlHistory)
    for operation in vm.controlActivity.val:
      let conversation = operation{"request", "conversation"}.getStr()
      # Scoped activity belongs to its originating chat. Explicit user automation
      # has no conversation owner and is labelled separately.
      if conversation.len > 0 and conversation != chat.controlConversationId.val:
        continue
      appendControlOperation(operation)
  # Suppress unused-warning for statusColor — still computed for the
  # Assistant tab status indicator wired in shell.nim.
  discard statusColor
  discard inspectorToggleButton
  r.setAttribute(narrowButton, "data-isonim-focus-id", "right-panel-narrow")
  r.setAttribute(resetButton, "data-isonim-focus-id", "right-panel-reset")
  r.setAttribute(widenButton, "data-isonim-focus-id", "right-panel-widen")
  r.setAttribute(narrowButton, "data-right-panel-resize-affordance", "narrow")
  r.setAttribute(resetButton, "data-right-panel-resize-affordance", "reset")
  r.setAttribute(widenButton, "data-right-panel-resize-affordance", "widen")
  r.addEventListener(narrowButton, "click", proc() = vm.adjustRightPanelWidth(-40))
  r.addEventListener(narrowButton, "keydown", proc() = vm.adjustRightPanelWidth(-40))
  r.addEventListener(narrowButton, "focus", rememberPanelFocus(vm,
    "right-panel-narrow"))
  r.addEventListener(resetButton, "click", proc() = vm.setRightPanelWidth(260))
  r.addEventListener(resetButton, "keydown", proc() = vm.setRightPanelWidth(260))
  r.addEventListener(resetButton, "focus", rememberPanelFocus(vm,
    "right-panel-reset"))
  r.addEventListener(widenButton, "click", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "keydown", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "focus", rememberPanelFocus(vm,
    "right-panel-widen"))

  # Messages area. Don't expand to fill the panel — at tall viewports that
  # leaves a huge empty band between the empty-state card and the composer.
  # When messages exist we cap the area and scroll internally.
  # M-EVP-14: tightened vertical padding + inter-card gap so the three
  # cards (intro / suggested prompts / activity) don't visually compete
  # with the preview pane.
  let messagesArea = ui(r):
    tdiv(
      flex = "1",
      min_height = "0",
      overflow_y = "auto",
      padding = "10px 10px 6px 10px",
      display = "flex",
      flex_direction = "column",
      gap = "8px",
      `data-chat-scroll` = "true")
  r.appendChild(messagesArea, controlHistory)

  # Empty guidance is local presentation, dismissed on attempted send.
  let empty = ui(r):
    tdiv(
      display = "flex",
      flex_direction = "column",
      gap = "8px",
      padding = "14px",
      border = "1px dashed " & borderFaint,
      border_radius = "8px",
      background_color = bgInput,
      color = textSecondary):
      span(font_size = "12px", font_weight = "700", color = textPrimary):
        text "Ask for design-system changes"
      span(font_size = "11px", line_height = "1.5", color = textSecondary):
        text "Use Comment mode to collect review notes, or describe token, variant, typography, spacing, radius, shadow, and state changes here."
      span(font_size = "11px", line_height = "1.5", color = textSecondary):
        text "Manual Edit mode opens the source-backed inspector in this same sidebar space."
  r.appendChild(messagesArea, empty)

  # Inserting a suggestion edits the draft; it does not submit a turn.
  let suggestionsHeading = ui(r):
    tdiv(
      display = "flex",
      align_items = "center",
      justify_content = "space-between",
      margin_top = "4px"):
      span(
        font_size = "10px",
        font_weight = "700",
        color = textSecondary,
        text_transform = "uppercase",
        letter_spacing = "0.5px"):
        text "Suggested prompts"
      span(font_size = "11px", color = textSecondary):
        text "tap to insert"
  r.appendChild(messagesArea, suggestionsHeading)

  let suggestions = [
    "Audit the selected component for accessibility regressions",
    "Suggest a calmer accent token for status badges",
    "Trace where this padding value is shared across the design system",
    "Generate a missing variant story for this component"
  ]
  var suggestionNodes: seq[E] = @[]
  for prompt in suggestions:
    let promptText = $prompt
    let chip = ui(r):
      button(
        `type` = "button",
        `role` = "button",
        tabindex = "0",
        `aria-label` = "Insert suggested prompt",
        display = "flex",
        align_items = "center",
        gap = "8px",
        padding = "8px 10px",
        border = "1px solid " & borderFaint,
        border_radius = "6px",
        background_color = bgInput,
        cursor = "pointer",
        transition = "border-color 0.12s, background-color 0.12s"):
        span(font_size = "11px", color = textDim):
          text "\xE2\x9C\xA8"
        span(font_size = "11px", line_height = "1.4",
              color = textPrimary,
              white_space = "normal",
              overflow = "hidden"):
          text promptText
    r.addEventListener(chip, "click", proc() =
      chat.inputText.val = promptText)
    r.appendChild(messagesArea, chip)
    suggestionNodes.add chip

  createRenderEffect proc() =
    let hidden = chat.placeholdersDismissed.val or chat.messages.val.len > 0
    r.setStyle(empty, "display", if hidden: "none" else: "flex")
    r.setStyle(suggestionsHeading, "display", if hidden: "none" else: "flex")
    for node in suggestionNodes:
      r.setStyle(node, "display", if hidden: "none" else: "flex")
  r.renderActivityTimeline(messagesArea, chat)
  # Adapter/admission errors that predate the normalized activity path remain
  # recognizable, without flattening assistant chunks or duplicating context.
  var errorCount = 0
  createRenderEffect proc() =
    let errors = chat.messages.val.filterIt(it.kind == cmkError and not it.activityRepresented)
    for index in errorCount ..< errors.len:
      let error = ui(r):
        tdiv(`data-chat-send-error` = "true", color = textError,
             font_size = "12px", padding = "8px 12px", white_space = "pre-wrap"):
          text errors[index].text
      r.appendChild(messagesArea, error)
    errorCount = errors.len

  r.appendChild(panel, messagesArea)

  # 2026-05-28: ``reviewLoopArea`` and ``bottomSpacer`` are now
  # display-toggled reactively. When the chat is empty AND there is no
  # review/permission/proposed-edit activity, both are hidden so the
  # Assistant tab reads as a single column of intro + suggestions
  # anchored at the top, with the composer pinned at the bottom — no
  # internal split. As soon as either a message or an activity item
  # appears, the corresponding section flips on.
  let reviewLoopArea = ui(r):
    tdiv(
      `data-chat-review-loop-area` = "true",
      padding = "6px 10px",
      border_top = "1px solid " & borderFaint,
      display = "none",
      flex_direction = "column",
      gap = "6px")
  proc appendReviewHeading(label: string) =
    let heading = ui(r):
      span(
        font_size = "10px",
        font_weight = "600",
        color = textSecondary,
        text_transform = "uppercase",
        letter_spacing = "0.5px"):
        text label
    r.appendChild(reviewLoopArea, heading)

  proc appendReviewSummary(label: string) =
    let summary = ui(r):
      span(font_size = "11px", color = textSecondary):
        text label
    r.appendChild(reviewLoopArea, summary)

  proc syncReviewLoop() =
    r.clearChildren(reviewLoopArea)
    let totalActivity = vm.review.annotations.val.len +
      chat.permissionRequests.val.len +
      chat.proposedEdits.val.len
    if totalActivity == 0:
      # Per-user 2026-05-27: drop the "Activity / No review comments…"
      # placeholder. The Assistant pane should not be split into upper
      # and lower halves; an empty activity placeholder created a
      # divider the user explicitly rejected. 2026-05-28: collapse the
      # reviewLoopArea entirely (``display: none``) so the border-top
      # rule above it doesn't paint a separator on an otherwise empty
      # body.
      r.setStyle(reviewLoopArea, "display", "none")
      return
    r.setStyle(reviewLoopArea, "display", "flex")
    appendReviewHeading("Design Review Comments")
    if vm.review.annotations.val.len == 0:
      appendReviewSummary("No review comments")
    else:
      for annotation in vm.review.annotations.val:
        let annotationId = annotation.id
        let included = annotation.includedInPrompt
        let state = annotation.state
        let annotationText = annotation.text
        let summaryText = annotation.id & " - " & annotationStateText(state) &
          " - " & (if included: "included" else: "excluded")
        let detailText =
          if annotation.ancestry.len > 0: annotation.ancestry
          elif annotation.selector.len > 0: annotation.selector
          else: annotation.elementId
        let card = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "6px",
              padding = "7px", border = "1px solid " & borderFaint,
              border_radius = "6px")
        let summary = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "3px"):
            span(font_size = "11px", color = textPrimary):
              text summaryText
            span(font_size = "10px", color = textSecondary):
              text detailText
            span(font_size = "11px", color = textSecondary):
              text annotationText
        r.appendChild(card, summary)
        let actions = ui(r):
          tdiv(display = "flex", gap = "6px", flex_wrap = "wrap")
        let includeBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = (if included:
              "Exclude review comment " & annotationId
            else:
              "Include review comment " & annotationId),
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textPrimary,
            cursor = "pointer"):
            text (if included: "Exclude" else: "Include")
        r.addEventListener(includeBtn, "click", proc() =
          discard vm.review.setReviewAnnotationPromptIncluded(annotationId,
            not included))
        let resolveBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Resolve review comment " & annotationId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Resolve"
        r.addEventListener(resolveBtn, "click", proc() =
          discard vm.review.resolveReviewAnnotation(annotationId))
        let dismissBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Dismiss review comment " & annotationId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Dismiss"
        r.addEventListener(dismissBtn, "click", proc() =
          discard vm.review.dismissReviewAnnotation(annotationId))
        r.appendChild(actions, includeBtn)
        if state == ransOpen:
          r.appendChild(actions, resolveBtn)
          r.appendChild(actions, dismissBtn)
        r.appendChild(card, actions)
        r.appendChild(reviewLoopArea, card)

    appendReviewHeading("Permission Requests")
    if chat.permissionRequests.val.len == 0:
      appendReviewSummary("No pending agent permissions")
    else:
      for request in chat.permissionRequests.val:
        let requestId = request.id
        let requestSummary = request.title & " - " &
          permissionStatusText(request.status)
        let row = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "6px")
        let summary = ui(r):
          span(font_size = "11px", color = textSecondary):
            text requestSummary
        r.appendChild(row, summary)
        let actions = ui(r):
          tdiv(display = "flex", gap = "6px")
        let allowBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Allow agent permission " & requestId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textPrimary,
            cursor = "pointer"):
            text "Allow"
        r.addEventListener(allowBtn, "click", proc() =
          discard chat.setAgentPermissionStatus(requestId, apsGranted))
        let denyBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Deny agent permission " & requestId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Deny"
        r.addEventListener(denyBtn, "click", proc() =
          discard chat.setAgentPermissionStatus(requestId, apsDenied))
        r.appendChild(actions, allowBtn)
        r.appendChild(actions, denyBtn)
        r.appendChild(row, actions)
        r.appendChild(reviewLoopArea, row)

    appendReviewHeading("Agent Proposed Edits")
    if chat.proposedEdits.val.len == 0:
      appendReviewSummary("No proposed agent edits")
    else:
      for proposal in chat.proposedEdits.val:
        let proposalId = proposal.id
        let proposalSummary = proposal.summary & " - " &
          proposalStatusText(proposal.status) & " - " &
          proposalValidityText(proposal.validity)
        let diffSummary =
          if proposal.diffs.len > 0:
            "Diff: " & proposal.diffs.mapIt(it.summary).join("; ")
          else:
            "Diff: " & proposal.sourceEdits.mapIt(it.property & " " &
              it.oldValue & " -> " & it.newValue).join("; ")
        let impactSummary =
          if proposal.impact.summary.len > 0: "Impact: " & proposal.impact.summary
          else: "Impact: " & $proposal.affectedStories.len & " affected story/stories"
        let storySummary =
          if proposal.affectedStories.len > 0:
            "Affected stories: " & proposal.affectedStories.mapIt(
              it.group & "/" & it.name).join(", ")
          else:
            "Affected stories: adapter-resolved"
        let testSummary = "Tests: " & proposal.tests.join(", ")
        let card = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "6px")
        let summary = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "3px"):
            span(font_size = "11px", color = textPrimary):
              text proposalSummary
            span(font_size = "10px", color = textSecondary):
              text diffSummary
            span(font_size = "10px", color = textSecondary):
              text impactSummary
            span(font_size = "10px", color = textSecondary):
              text storySummary
            span(font_size = "10px", color = textSecondary):
              text testSummary
        r.appendChild(card, summary)
        let actions = ui(r):
          tdiv(display = "flex", gap = "6px", flex_wrap = "wrap")
        let acceptBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Accept agent edit " & proposalId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textPrimary,
            cursor = "pointer"):
            text "Accept"
        r.addEventListener(acceptBtn, "click", proc() =
          discard vm.acceptAgentProposedEdit(proposalId))
        let rejectBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Reject agent edit " & proposalId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Reject"
        r.addEventListener(rejectBtn, "click", proc() =
          discard vm.rejectAgentProposedEdit(proposalId))
        let revertBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Revert agent edit " & proposalId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Revert"
        r.addEventListener(revertBtn, "click", proc() =
          discard vm.revertAgentProposedEdit(proposalId))
        let rerunBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Re-run agent edit " & proposalId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Re-run"
        r.addEventListener(rerunBtn, "click", proc() =
          discard vm.rerunAgentProposedEdit(proposalId))
        let rebaseBtn = ui(r):
          button(
            `type` = "button",
            `role` = "button",
            tabindex = "0",
            `aria-label` = "Rebase agent edit " & proposalId,
            padding = "5px 7px",
            border = "1px solid " & border,
            border_radius = "5px",
            font_size = "10px",
            color = textSecondary,
            cursor = "pointer"):
            text "Rebase"
        r.addEventListener(rebaseBtn, "click", proc() =
          discard vm.rebaseAgentProposedEdit(proposalId))
        r.appendChild(actions, acceptBtn)
        r.appendChild(actions, rejectBtn)
        r.appendChild(actions, revertBtn)
        r.appendChild(actions, rerunBtn)
        if proposal.validity != aepvCurrent:
          r.appendChild(actions, rebaseBtn)
        r.appendChild(card, actions)
        r.appendChild(reviewLoopArea, card)

  syncReviewLoop()
  createRenderEffect proc() =
    syncReviewLoop()
  r.appendChild(messagesArea, reviewLoopArea)
  # 2026-05-28: bottomSpacer (the "Ready when you are" placeholder
  # band) is gone. The user explicitly rejected the upper/lower split
  # it created — an empty chat now shows only intro + suggested
  # prompts in the messagesArea (flex:1), with the composer pinned at
  # the bottom. Once messages arrive, the transcript fills naturally.

  let latestButton = r.createElement("button")
  r.setAttribute(latestButton, "type", "button")
  r.setAttribute(latestButton, "data-chat-latest", "true")
  r.setTextContent(latestButton, "New output · Return to latest")
  r.setStyle(latestButton, "display", "none")
  r.setStyle(latestButton, "background-color", bgSurface)
  r.setStyle(latestButton, "color", textPrimary)
  r.setStyle(latestButton, "border", "1px solid " & border)
  r.setStyle(latestButton, "padding", "7px")
  r.setStyle(latestButton, "flex-shrink", "0")
  r.appendChild(panel, latestButton)
  when defined(js) and compiles(panel.ownerDocument):
    let target = messagesArea
    let latest = latestButton
    let savedPosition = chat.scrollPosition
    let followInitially = chat.followOutput
    {.emit: ["""
      (function(el, position, follow) {
        requestAnimationFrame(function() {
          if (el.isConnected && !follow) el.scrollTop = position;
        });
      })(""", target, ",", savedPosition, ",", followInitially, ");"].}
    r.addEventListener(messagesArea, "scroll", proc() =
      var position, remaining: float
      {.emit: [position, " = ", target, ".scrollTop;", remaining, " = ",
        target, ".scrollHeight - ", target, ".scrollTop - ", target, ".clientHeight;"].}
      chat.scrollPosition = position
      chat.followOutput = remaining <= 24
      if chat.followOutput: r.setStyle(latest, "display", "none"))
    r.addEventListener(latestButton, "click", proc() =
      chat.followOutput = true
      r.setStyle(latest, "display", "none")
      {.emit: [target, ".scrollTop = ", target, ".scrollHeight;"].})
    let isFollowing = proc(): bool = chat.followOutput
    var previousOutputRevision = -1
    var previousErrorCount = -1
    createRenderEffect proc() =
      let outputRevision = chat.activity.val.revision
      let errorCount = chat.messages.val.filterIt(it.kind == cmkError and not it.activityRepresented).len
      let initial = previousOutputRevision < 0
      let changed = outputRevision != previousOutputRevision or errorCount != previousErrorCount
      previousOutputRevision = outputRevision
      previousErrorCount = errorCount
      if not initial and not changed: return
      let notifyLatest = not initial and changed
      {.emit: ["""
        (function(el, latest, following, changed) {
          requestAnimationFrame(function () {
            if (!el.isConnected) return;
            if (following()) el.scrollTop = el.scrollHeight;
            else if (changed) latest.style.display = 'block';
          });
        })(""", target, ",", latest, ",", isFollowing, ",", notifyLatest, ");"].}


  # Input area
  let inputArea = ui(r):
    tdiv(
      padding = "10px 12px 12px 12px",
      border_top = "1px solid " & border,
      background_color = bgSidebar,
      box_shadow = "0 -8px 16px -8px rgba(15, 23, 42, 0.55)",
      flex_shrink = "0")

  let inputRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px")
  let promptInput = ui(r):
    textarea(
      class = "editor-input",
      `data-editor-control-focus` = "composer",
      flex = "1",
      min_height = "64px",
      max_height = "180px",
      resize = "vertical",
      min_width = "0",
      line_height = "1.5",
      background_color = bgInput,
      border = "1px solid " & borderFaint,
      border_radius = "8px",
      padding = "8px 10px",
      font_size = "12px",
      color = textPrimary,
      outline = "none",
      placeholder = "Ask the AI\xE2\x80\xA6")
  r.setAttribute(promptInput, "aria-label", "Agent prompt")
  r.setInputValue(promptInput, chat.inputText.val)
  createRenderEffect proc() =
    if r.inputValue(promptInput) != chat.inputText.val:
      r.setInputValue(promptInput, chat.inputText.val)
  r.addEventListener(promptInput, "input", proc() =
    chat.inputText.val = r.inputValue(promptInput))
  r.addEventListener(promptInput, "change", proc() =
    chat.inputText.val = r.inputValue(promptInput))

  let sendBtn = ui(r):
    button(
      `type` = "button",
      display = "flex",
      align_items = "center",
      justify_content = "center",
      width = "34px",
      height = "34px",
      border_radius = "8px",
      font_size = "16px",
      font_weight = "700",
      background_color = accent,
      color = textPrimary,
      cursor = "pointer"):
      text "\xE2\x86\x91"
  r.setAttribute(sendBtn, "role", "button")
  r.setAttribute(sendBtn, "tabindex", "0")
  r.setAttribute(sendBtn, "aria-label", "Send agent prompt")
  proc submitPrompt() =
    chat.inputText.val = r.inputValue(promptInput)
    let active = vm.chat
    let generation = active.promptGeneration
    let ready = active.agentPromptReady()
    let inFlight = active.promptInFlight
    let closing = active.closingSession
    let sameChat = active == chat
    let accepted = vm.sendAgentPrompt()
    when defined(js) and compiles(panel.ownerDocument):
      {.emit: ["if (typeof window.__isonimObserveAgentAdmission === 'function') window.__isonimObserveAgentAdmission({generation:", generation,
        ", ready:", ready, ", inFlight:", inFlight, ", closing:", closing,
        ", sameChat:", sameChat, ", accepted:", accepted, "});"].}
    r.setInputValue(promptInput, chat.inputText.val)
  r.addEventListener(sendBtn, "click", submitPrompt)
  createRenderEffect proc() =
    let busy = not chat.agentPromptReady()
    r.setAttribute(sendBtn, "aria-disabled", $busy)
    r.setStyle(sendBtn, "opacity", if busy: "0.45" else: "1")
    when defined(js) and compiles(panel.ownerDocument):
      {.emit: [sendBtn, ".disabled = ", busy, ";"].}
  when defined(js) and compiles(panel.ownerDocument):
    let submitCallback = submitPrompt
    {.emit: ["""
      (function(el, submit) {
        let composing = false;
        el.addEventListener('compositionstart', function() { composing = true; });
        el.addEventListener('compositionend', function() { composing = false; });
        el.addEventListener('keydown', function(event) {
          if (event.key === 'Enter' && !event.shiftKey && !event.isComposing && !composing && event.keyCode !== 229) {
            event.preventDefault(); submit();
          }
        });
      })(""", promptInput, ",", submitCallback, ");"].}

  let cancelBtn = ui(r):
    button(
      `type` = "button",
      display = "flex",
      align_items = "center",
      justify_content = "center",
      width = "34px",
      height = "34px",
      border_radius = "8px",
      font_size = "13px",
      font_weight = "700",
      background_color = bgSurface,
      color = textSecondary,
      cursor = "pointer"):
      text "\xE2\x8F\xB9"
  r.setAttribute(cancelBtn, "role", "button")
  r.setAttribute(cancelBtn, "tabindex", "0")
  r.setAttribute(cancelBtn, "aria-label", "Cancel agent prompt")
  r.addEventListener(cancelBtn, "click", proc() = discard vm.cancelAgentPrompt())

  r.appendChild(inputRow, promptInput)
  r.appendChild(inputRow, sendBtn)
  createRenderEffect proc() =
    let supported = chat.cancelSupported.val or chat.cancelAdapter != nil
    r.setStyle(cancelBtn, "display", if supported: "flex" else: "none")
  r.appendChild(inputRow, cancelBtn)
  r.appendChild(inputArea, inputRow)
  # Explicit closure is also recovery when a stream is interrupted. The VM
  # waits for acknowledgement before replacing the final conversation.
  let closeBtn = r.createElement("button")
  r.setAttribute(closeBtn, "type", "button")
  r.setAttribute(closeBtn, "aria-label", "Close conversation")
  r.setAttribute(closeBtn, "data-agent-close", "true")
  r.setTextContent(closeBtn, "Close conversation")
  r.setStyle(closeBtn, "margin-top", "8px")
  r.setStyle(closeBtn, "padding", "6px 10px")
  r.setStyle(closeBtn, "color", textSecondary)
  r.setStyle(closeBtn, "background-color", bgSurface)
  r.setStyle(closeBtn, "border", "1px solid " & border)
  r.addEventListener(closeBtn, "click", proc() =
    discard vm.closeChat(vm.activeChatId.val))
  r.setStyle(closeBtn, "font-size", "10px")
  let sessionLabel = r.createElement("div")
  r.setAttribute(sessionLabel, "data-chat-session-status", "true")
  r.setAttribute(sessionLabel, "role", "status")
  r.setAttribute(sessionLabel, "aria-live", "polite")
  r.setStyle(sessionLabel, "white-space", "pre-line")
  r.setStyle(sessionLabel, "line-height", "1.5")
  r.setStyle(sessionLabel, "margin-top", "8px")
  r.setStyle(sessionLabel, "color", textSecondary)
  r.setStyle(sessionLabel, "font-size", "10px")
  r.setStyle(sessionLabel, "margin-right", "8px")
  createRenderEffect proc() =
    r.setTextContent(sessionLabel, chatStatusText(vm))
  r.appendChild(inputArea, sessionLabel)
  r.appendChild(inputArea, closeBtn)
  r.appendChild(panel, inputArea)

  panel
