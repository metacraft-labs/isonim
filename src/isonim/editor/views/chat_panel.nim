## IsoNim Editor — AI Assistant Chat Panel.
##
## Ever-present panel on the right side of every screen.
## Renders explicit chat state from the editor ViewModel.

import std/strutils

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

proc inspectorPropertyEditHandler[R, E](r: R; vm: EditorVM; input: E;
    property: string): proc() =
  let capturedProperty = property
  let capturedInput = input
  result = proc() =
    discard vm.editCssProperty(capturedProperty, r.inputValue(capturedInput),
      pesLocal, peoInspector)

proc chatStatusText(vm: EditorVM): string =
  let label = case vm.chat.sessionStatus.val
    of asIdle: "Empty"
    of asLoading: "Loading"
    of asReady: "Connected"
    of asError: "Error"
  label & " / " & vm.chat.connectionState.val

proc proposalStatusText(status: AgentEditProposalStatus): string
proc permissionStatusText(status: AgentPermissionStatus): string

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

proc renderChatPanel*[R, E](r: R; vm: EditorVM): E =
  let messages = signals.val(vm.chat.messages)
  let agentState = signals.val(vm.chat.sessionStatus)
  let statusLabel = case agentState
    of asIdle: "Empty"
    of asLoading: "Loading"
    of asReady: "Connected"
    of asError: "Error"
  let connectionLabel = vm.chat.connectionState.val
  let statusColor = case agentState
    of asIdle: textDim
    of asLoading: gold
    of asReady: green
    of asError: gold

  let panel = ui(r):
    tdiv(
      class = "editor-chat",
      width = "280px",
      min_width = "280px",
      display = "flex",
      flex_direction = "column",
      height = "100%",
      background_color = bgSidebar,
      border_left = "1px solid " & border)

  var statusTextNode: E
  # Header
  let header = ui(r):
    tdiv(
      display = "flex",
      align_items = "center",
      justify_content = "space-between",
      padding = "10px 12px",
      border_bottom = "1px solid " & border,
      min_height = "40px"):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(font_size = "13px"):
          text "\xE2\x9C\xA8"
        span(
          font_size = "11px",
          font_weight = "600",
          color = textSecondary,
          text_transform = "uppercase",
          letter_spacing = "0.5px"):
          text "AI Assistant"
      # Status dot
      tdiv(display = "flex", align_items = "center", gap = "4px"):
        tdiv(
          width = "6px",
          height = "6px",
          border_radius = "3px",
          background_color = statusColor)
        span(ref = statusTextNode, font_size = "9px", color = textDim):
          text statusLabel & " / " & connectionLabel
        tdiv(
          `role` = "button",
          tabindex = "0",
          `aria-label` = "Toggle inspector panel",
          onclick = proc() = vm.togglePanel(epInspector),
          onkeydown = proc() = vm.togglePanel(epInspector),
          margin_left = "6px",
          width = "24px",
          height = "24px",
          display = "flex",
          align_items = "center",
          justify_content = "center",
          border_radius = "4px",
          color = textSecondary,
          cursor = "pointer"):
          text "\xE2\x9C\x95"
  r.appendChild(panel, header)

  if vm.inspector.hasElement.val:
    let inspectorArea = ui(r):
      tdiv(
        padding = "10px 12px",
        border_bottom = "1px solid " & borderFaint,
        display = "flex",
        flex_direction = "column",
        gap = "8px")

    let element = vm.inspector.selectedElement.val
    let selectionHeader = ui(r):
      tdiv(display = "flex", flex_direction = "column", gap = "2px"):
        span(
          font_size = "10px",
          font_weight = "600",
          color = textSecondary,
          text_transform = "uppercase",
          letter_spacing = "0.5px"):
          text "Inspector"
        span(font_size = "12px", color = textPrimary, font_family = "monospace"):
          text element.tag
        span(font_size = "10px", color = textDim):
          text element.sourceFile & ":" & $element.sourceLine
    r.appendChild(inspectorArea, selectionHeader)

    for prop in vm.inspector.properties.val:
      let propName = prop.name
      let propValue = prop.value
      let row = ui(r):
        tdiv(display = "flex", flex_direction = "column", gap = "4px")
      let label = ui(r):
        span(
          font_size = "10px",
          color = textDim,
          text_transform = "uppercase",
          letter_spacing = "0.4px"):
          text propName
      r.appendChild(row, label)

      let inputNode = ui(r):
        input(
          class = "editor-input",
          height = "28px",
          background_color = bgInput,
          border = "1px solid " & border,
          border_radius = "6px",
          padding = "0 8px",
          font_size = "12px",
          color = textPrimary,
          outline = "none")
      r.setAttribute(inputNode, "aria-label",
        "Edit inspector property " & propName)
      r.setInputValue(inputNode, propValue)
      let editProperty =
        inspectorPropertyEditHandler[R, E](r, vm, inputNode, propName)
      r.addEventListener(inputNode, "change", editProperty)
      r.addEventListener(inputNode, "keydown", editProperty)
      r.appendChild(row, inputNode)
      r.appendChild(inspectorArea, row)

    r.appendChild(panel, inspectorArea)

  # Messages area
  let messagesArea = ui(r):
    tdiv(
      flex = "1",
      overflow_y = "auto",
      padding = "12px",
      display = "flex",
      flex_direction = "column",
      gap = "10px")

  if messages.len == 0:
    let empty = ui(r):
      tdiv(
        display = "flex",
        align_items = "center",
        justify_content = "center",
        height = "100%"):
        span(font_size = "12px", color = textDim, font_style = "italic"):
          text "No agent messages"
    r.appendChild(messagesArea, empty)

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
      padding = "10px 12px",
      border_top = "1px solid " & borderFaint,
      display = "flex",
      flex_direction = "column",
      gap = "8px")
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
          proposalStatusText(proposal.status)
        let card = ui(r):
          tdiv(display = "flex", flex_direction = "column", gap = "6px")
        let summary = ui(r):
          span(font_size = "11px", color = textSecondary):
            text proposalSummary
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
        r.appendChild(actions, acceptBtn)
        r.appendChild(actions, rejectBtn)
        r.appendChild(actions, revertBtn)
        r.appendChild(card, actions)
        r.appendChild(reviewLoopArea, card)

  syncReviewLoop()
  createRenderEffect proc() =
    syncReviewLoop()
  r.appendChild(panel, reviewLoopArea)

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
      padding = "8px 12px 12px 12px",
      border_top = "1px solid " & borderFaint)

  let inputRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px")
  let promptInput = ui(r):
    input(
      class = "editor-input",
      flex = "1",
      height = "34px",
      background_color = bgInput,
      border = "1px solid " & border,
      border_radius = "8px",
      padding = "0 10px",
      font_size = "12px",
      color = textPrimary,
      outline = "none",
      placeholder = "Ask the AI\xE2\x80\xA6")
  r.setAttribute(promptInput, "aria-label", "Agent prompt")
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
