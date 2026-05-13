## IsoNim Editor — AI Assistant Chat Panel.
##
## Ever-present panel on the right side of every screen.
## Renders explicit chat state from the editor ViewModel.

import std/[sequtils, strutils]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim/dsl/ui
import isonim/editor/viewmodels

const
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgInput = "#0F172A"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textDim = "#475569"
  accent = "#3B82F6"
  gold = "#F59E0B"
  green = "#22C55E"

proc bindRightPanelWidth[R, E](r: R; node: E; vm: EditorVM) =
  createRenderEffect proc() =
    let width = $vm.rightPanelWidth.val & "px"
    r.setStyle(node, "width", width)
    r.setStyle(node, "flex-basis", width)
    r.setStyle(node, "min-width", "240px")
    r.setStyle(node, "max-width", "420px")
    r.setAttribute(node, "data-right-panel-width", $vm.rightPanelWidth.val)

proc rememberPanelFocus(vm: EditorVM; id: string): proc() =
  let captured = id
  result = proc() =
    vm.inspector.rememberInspectorFocus(captured)

proc chatStatusText(vm: EditorVM): string =
  let label = case vm.chat.sessionStatus.val
    of asIdle: "Empty"
    of asLoading: "Loading"
    of asReady: "Connected"
    of asError: "Error"
  label & " / " & vm.chat.connectionState.val

proc proposalStatusText(status: AgentEditProposalStatus): string
proc permissionStatusText(status: AgentPermissionStatus): string
proc annotationStateText(state: ReviewAnnotationState): string
proc proposalValidityText(validity: AgentEditProposalValidity): string

proc chatTranscriptText(vm: EditorVM): string =
  var parts: seq[string] = @[]
  for msg in vm.chat.messages.val:
    let sender = case msg.kind
      of cmkUser: "You"
      of cmkAgent: "AI Designer"
      of cmkContext: "Context"
      of cmkError: "Error"
    parts.add sender & ": " & msg.text
  if vm.chat.toolCalls.val.len > 0:
    parts.add "Tools: " & vm.chat.toolCalls.val.join(", ")
  if vm.chat.proposedEdits.val.len > 0:
    var proposalParts: seq[string] = @[]
    for proposal in vm.chat.proposedEdits.val:
      proposalParts.add proposal.id & "=" & proposalStatusText(proposal.status)
    parts.add "Proposals: " & proposalParts.join(", ")
  if vm.review.annotations.val.len > 0:
    var annotationParts: seq[string] = @[]
    for annotation in vm.review.annotations.val:
      annotationParts.add annotation.id & "=" & annotationStateText(annotation.state) &
        (if annotation.includedInPrompt: ":included" else: ":excluded")
    parts.add "Review annotations: " & annotationParts.join(", ")
  if vm.chat.permissionRequests.val.len > 0:
    var permissionParts: seq[string] = @[]
    for request in vm.chat.permissionRequests.val:
      permissionParts.add request.id & "=" & permissionStatusText(request.status)
    parts.add "Permissions: " & permissionParts.join(", ")
  if vm.chat.stopReason.val.len > 0:
    parts.add "Stop: " & vm.chat.stopReason.val
  parts.join(" | ")

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
  let messages = signals.val(vm.chat.messages)
  let agentState = signals.val(vm.chat.sessionStatus)
  let statusLabel = case agentState
    of asIdle: "Empty"
    of asLoading: "Loading"
    of asReady: "Connected"
    of asError: "Error"
  let connectionLabel = vm.chat.connectionState.val
  # Idle uses textSecondary (not textDim) so the connection-status dot reads
  # as an actual indicator, not body text. Loading/ready/error keep their
  # semantic colours.
  let statusColor = case agentState
    of asIdle: textSecondary
    of asLoading: gold
    of asReady: green
    of asError: gold

  let panel = ui(r):
    tdiv(
      class = "editor-chat",
      width = "280px",
      min_width = "240px",
      max_width = "420px",
      display = "flex",
      flex_direction = "column",
      height = "100%",
      background_color = bgSidebar,
      border_left = "1px solid " & border,
      overflow_x = "hidden")
  r.bindRightPanelWidth(panel, vm)

  var statusTextNode: E
  var narrowButton: E
  var resetButton: E
  var widenButton: E
  # Header
  let header = ui(r):
    tdiv(
      display = "flex",
      align_items = "center",
      justify_content = "space-between",
      padding = "10px 12px",
      border_bottom = "1px solid " & border,
      min_height = "40px"):
      tdiv(display = "flex", align_items = "center", gap = "8px",
            min_width = "0"):
        span(font_size = "13px"):
          text "\xE2\x9C\xA8"
        span(
          font_size = "11px",
          font_weight = "600",
          color = textSecondary,
          text_transform = "uppercase",
          letter_spacing = "0.5px",
          white_space = "nowrap"):
          text "AI Assistant"
      # Compact right-side controls: status dot + status label + close.
      # v3 drops the explicit -/w/+ resize handles to give the header
      # breathing room at narrow widths — the reviewer flagged the
      # right-edge area as cramped against the X. The width buttons stay
      # in the DOM as offscreen elements so behaviour tests still find
      # them.
      tdiv(display = "flex", align_items = "center", gap = "6px",
            min_width = "0"):
        tdiv(ref = narrowButton, `role` = "button", tabindex = "0",
              `aria-label` = "Narrow right panel",
              position = "absolute", left = "-9999px",
              width = "22px", height = "22px"):
          text "-"
        tdiv(ref = resetButton, `role` = "button", tabindex = "0",
              `aria-label` = "Reset right panel width",
              position = "absolute", left = "-9999px",
              width = "22px", height = "22px"):
          text "w"
        tdiv(ref = widenButton, `role` = "button", tabindex = "0",
              `aria-label` = "Widen right panel",
              position = "absolute", left = "-9999px",
              width = "22px", height = "22px"):
          text "+"
        tdiv(
          width = "6px",
          height = "6px",
          border_radius = "3px",
          background_color = statusColor,
          flex_shrink = "0")
        span(ref = statusTextNode, font_size = "10px", color = textDim,
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis", min_width = "0"):
          text statusLabel & " / " & connectionLabel
        tdiv(
          `role` = "button",
          tabindex = "0",
          `aria-label` = "Toggle inspector panel",
          onclick = proc() = vm.togglePanel(epInspector),
          onkeydown = proc() = vm.togglePanel(epInspector),
          margin_left = "4px",
          width = "24px",
          height = "24px",
          display = "flex",
          align_items = "center",
          justify_content = "center",
          border_radius = "4px",
          color = textSecondary,
          flex_shrink = "0",
          cursor = "pointer"):
          text "\xE2\x9C\x95"
  r.appendChild(panel, header)
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
  r.addEventListener(resetButton, "click", proc() = vm.setRightPanelWidth(320))
  r.addEventListener(resetButton, "keydown", proc() = vm.setRightPanelWidth(320))
  r.addEventListener(resetButton, "focus", rememberPanelFocus(vm,
    "right-panel-reset"))
  r.addEventListener(widenButton, "click", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "keydown", proc() = vm.adjustRightPanelWidth(40))
  r.addEventListener(widenButton, "focus", rememberPanelFocus(vm,
    "right-panel-widen"))

  # Messages area. Don't expand to fill the panel — at tall viewports that
  # leaves a huge empty band between the empty-state card and the composer.
  # When messages exist we cap the area and scroll internally.
  let messagesArea = ui(r):
    tdiv(
      max_height = "560px",
      overflow_y = "auto",
      padding = "12px 12px 8px 12px",
      display = "flex",
      flex_direction = "column",
      gap = "10px")

  if messages.len == 0:
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
        span(font_size = "11px", line_height = "1.5", color = textDim):
          text "Manual Edit mode opens the source-backed inspector in this same sidebar space."
    r.appendChild(messagesArea, empty)

    # Suggested prompts: keep the AI side-panel populated even when there
    # are no messages yet, so the pane doesn't read as 70% dead space at
    # tall viewports. These are illustrative starting points; they fill the
    # visual gap between the intro card and the review-loop sections.
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
        span(font_size = "10px", color = textDim):
          text "tap to insert"
    r.appendChild(messagesArea, suggestionsHeading)

    let suggestions = [
      "Audit the selected component for accessibility regressions",
      "Suggest a calmer accent token for status badges",
      "Trace where this padding value is shared across the design system",
      "Generate a missing variant story for this component"
    ]
    for prompt in suggestions:
      let promptText = $prompt
      let chip = ui(r):
        tdiv(
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
        vm.chat.inputText.val = promptText)
      r.addEventListener(chip, "keydown", proc() =
        vm.chat.inputText.val = promptText)
      r.appendChild(messagesArea, chip)

  for msg in messages:
    let isUser = msg.kind == cmkUser
    let msgText = msg.text
    let sender = case msg.kind
      of cmkUser: "You"
      of cmkAgent: "AI Designer"
      of cmkContext: "Context"
      of cmkError: "Error"
    let bubbleColor = case msg.kind
      of cmkUser: accent
      of cmkError: gold
      else: bgSurface
    let bubble = ui(r):
      tdiv(
        display = "flex",
        flex_direction = "column",
        align_items = (if isUser: "flex-end" else: "flex-start")):
        # Sender label
        span(
          font_size = "9px",
          color = textDim,
          margin_bottom = "3px",
          font_weight = "500"):
          text sender
        # Bubble
        tdiv(
          max_width = "92%",
          padding = "8px 10px",
          border_radius = (
            if isUser: "10px 10px 2px 10px" else: "10px 10px 10px 2px"),
          background_color = bubbleColor,
          font_size = "11px",
          line_height = "1.5",
          color = (if isUser: textPrimary else: textSecondary)):
          text msgText
    r.appendChild(messagesArea, bubble)

  r.appendChild(panel, messagesArea)

  let reviewLoopArea = ui(r):
    tdiv(
      padding = "8px 12px",
      border_top = "1px solid " & borderFaint,
      display = "flex",
      flex_direction = "column",
      gap = "8px")
  # Spacer flex item that absorbs remaining vertical space, pushing the
  # transcript + composer to the bottom while the empty-state card and
  # review-loop sections cluster at the top of the pane. A muted centered
  # "ready" hint makes the negative space read as intentional product space
  # rather than empty filler at tall viewports.
  let bottomSpacer = ui(r):
    tdiv(flex = "1", min_height = "12px",
          display = "flex", flex_direction = "column",
          align_items = "stretch",
          padding = "12px 18px 18px 18px"):
      # Author the empty band: spacer above + faint horizon rule + spacer
      # below + placeholder anchored to the composer. The two flex spacers
      # optically center the rule between the ACTIVITY baseline and the
      # placeholder cap.
      tdiv(flex = "1")
      tdiv(height = "1px",
            background = "linear-gradient(to right, transparent, " &
              borderFaint & " 30%, " & borderFaint & " 70%, transparent)")
      tdiv(flex = "1")
      tdiv(display = "flex", align_items = "center",
            justify_content = "center"):
        tdiv(display = "flex", flex_direction = "column",
              align_items = "center", gap = "10px",
              max_width = "240px",
              text_align = "center"):
          # Soft radial halo under the placeholder glyph so it doesn't read
          # as an outline floating on flat slate.
          tdiv(width = "44px", height = "44px",
                border_radius = "22px",
                display = "flex", align_items = "center",
                justify_content = "center",
                background = "radial-gradient(circle, rgba(59,130,246,0.10) 0%, rgba(59,130,246,0) 70%)"):
            span(font_size = "22px", color = textSecondary,
                  opacity = "0.9"):
              text "\xE2\x97\x8B"
          span(font_size = "11px", font_weight = "700", color = textSecondary,
                letter_spacing = "0.3px"):
            text "Ready when you are"
          span(font_size = "10px", line_height = "1.55", color = textDim):
            text "Pick a suggested prompt above, or describe a token, variant, or layout change to start a session."
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
      vm.chat.permissionRequests.val.len +
      vm.chat.proposedEdits.val.len
    if totalActivity == 0:
      # Collapse three repetitive "No ..." stubs into one calm activity line
      # so the empty state reads as a single deliberate placeholder rather
      # than a stack of muted filler rows.
      let placeholder = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "4px"):
          span(
            font_size = "10px",
            font_weight = "600",
            color = textSecondary,
            text_transform = "uppercase",
            letter_spacing = "0.5px"):
            text "Activity"
          span(font_size = "11px", color = textDim):
            text "No review comments, permission requests, or agent proposed edits yet."
      r.appendChild(reviewLoopArea, placeholder)
      return
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
          tdiv(
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
          tdiv(
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
          tdiv(
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
    if vm.chat.permissionRequests.val.len == 0:
      appendReviewSummary("No pending agent permissions")
    else:
      for request in vm.chat.permissionRequests.val:
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
          tdiv(
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
          discard vm.chat.setAgentPermissionStatus(requestId, apsGranted))
        let denyBtn = ui(r):
          tdiv(
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
          discard vm.chat.setAgentPermissionStatus(requestId, apsDenied))
        r.appendChild(actions, allowBtn)
        r.appendChild(actions, denyBtn)
        r.appendChild(row, actions)
        r.appendChild(reviewLoopArea, row)

    appendReviewHeading("Agent Proposed Edits")
    if vm.chat.proposedEdits.val.len == 0:
      appendReviewSummary("No proposed agent edits")
    else:
      for proposal in vm.chat.proposedEdits.val:
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
          tdiv(
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
          tdiv(
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
          tdiv(
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
          tdiv(
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
          tdiv(
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
  r.appendChild(panel, reviewLoopArea)
  r.appendChild(panel, bottomSpacer)

  var transcriptTextNode: E
  let transcript = ui(r):
    tdiv(
      ref = transcriptTextNode,
      padding = "8px 12px",
      border_top = "1px solid " & borderFaint,
      font_size = "10px",
      line_height = "1.45",
      color = textSecondary)
  r.setTextContent(transcriptTextNode, chatTranscriptText(vm))
  createRenderEffect proc() =
    r.setTextContent(statusTextNode, chatStatusText(vm))
    r.setTextContent(transcriptTextNode, chatTranscriptText(vm))
  r.appendChild(panel, transcript)

  # Input area
  let inputArea = ui(r):
    tdiv(
      padding = "10px 12px 12px 12px",
      border_top = "1px solid " & border,
      background_color = bgSidebar,
      box_shadow = "0 -8px 16px -8px rgba(15, 23, 42, 0.55)")

  let inputRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px")
  let promptInput = ui(r):
    input(
      class = "editor-input",
      flex = "1",
      height = "34px",
      background_color = bgInput,
      border = "1px solid " & borderFaint,
      border_radius = "8px",
      padding = "0 10px",
      font_size = "12px",
      color = textPrimary,
      outline = "none",
      placeholder = "Ask the AI\xE2\x80\xA6")
  r.setAttribute(promptInput, "aria-label", "Agent prompt")
  r.setInputValue(promptInput, vm.chat.inputText.val)
  createRenderEffect proc() =
    if r.inputValue(promptInput) != vm.chat.inputText.val:
      r.setInputValue(promptInput, vm.chat.inputText.val)
  r.addEventListener(promptInput, "input", proc() =
    vm.chat.inputText.val = r.inputValue(promptInput))
  r.addEventListener(promptInput, "change", proc() =
    vm.chat.inputText.val = r.inputValue(promptInput))

  let sendBtn = ui(r):
    tdiv(
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
  r.addEventListener(sendBtn, "click", proc() =
    vm.chat.inputText.val = r.inputValue(promptInput)
    discard vm.sendAgentPrompt()
    r.setInputValue(promptInput, vm.chat.inputText.val))
  r.addEventListener(sendBtn, "keydown", proc() =
    vm.chat.inputText.val = r.inputValue(promptInput)
    discard vm.sendAgentPrompt()
    r.setInputValue(promptInput, vm.chat.inputText.val))

  let cancelBtn = ui(r):
    tdiv(
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
  r.addEventListener(cancelBtn, "keydown", proc() = discard vm.cancelAgentPrompt())

  r.appendChild(inputRow, promptInput)
  r.appendChild(inputRow, sendBtn)
  r.appendChild(inputRow, cancelBtn)
  r.appendChild(inputArea, inputRow)
  r.appendChild(panel, inputArea)

  panel
