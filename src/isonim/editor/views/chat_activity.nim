## Thin conversation view over the opt-in renderer-free nim-agents reducer.
## Markdown is a safe block subset: headings, lists, fenced code and paragraphs.
## Content is always DOM text, never evaluated HTML or navigation markup.
import std/[strutils, tables]
import nim_agents
import nim_agents/activity
import nim_agents/activity_presentation
import isonim/core/[signals, computation, owner]
import isonim/editor/viewmodels
import ./chat_theme

type
  ChatMarkdownBlock* = object
    kind*, text*, language*: string

proc chatMarkdownBlocks*(text: string): seq[ChatMarkdownBlock] =
  var fenced = false
  var codeLines: seq[string]
  var language = ""
  for line in text.splitLines():
    if line.startsWith("```"):
      if fenced:
        result.add ChatMarkdownBlock(kind: "code", text: codeLines.join("\n"), language: language)
        codeLines.setLen(0)
      else: language = line[3 .. ^1].strip()
      fenced = not fenced
    elif fenced:
      codeLines.add line
    elif line.strip.len > 0:
      var kind = "paragraph"
      var value = line
      if line.startsWith("### "): kind = "heading"; value = line[4 .. ^1]
      elif line.startsWith("## "): kind = "heading"; value = line[3 .. ^1]
      elif line.startsWith("# "): kind = "heading"; value = line[2 .. ^1]
      elif line.len > 2 and line[0] in {'0'..'9'} and ". " in line:
        kind = "list"
      elif line.startsWith("- ") or line.startsWith("* "):
        kind = "list"; value = "• " & line[2 .. ^1]
      result.add ChatMarkdownBlock(kind: kind, text: value)
  if fenced: result.add ChatMarkdownBlock(kind: "code", text: codeLines.join("\n"), language: language)

proc activityTitle*(entry: ActivityEntry): string =
  if entry.role == arUser: return "You"
  if entry.role == arAssistant: return "Assistant"
  case entry.kind
  of aekToolCall, aekToolCallUpdate:
    if entry.title.len > 0: entry.title else: "Tool"
  of aekThoughtChunk: "Thinking"
  of aekPlan: "Plan"
  of aekFileEdit: "File change · " & entry.data.filePath
  of aekDiff: "Diff · " & entry.data.filePath
  of aekMilestoneProgress: "Progress"
  of aekWorkspaceReady: "Workspace ready"
  of aekDelivery: "Delivery"
  of aekReview: "Review · " & entry.data.reviewSeverity
  of aekLlmRequest: "Model request"
  of aekSubAgent: "Sub-agent"
  of aekError: "Error"
  of aekCancelled: "Turn stopped"
  of aekCompleted: "Turn complete"
  of aekConnection: "Session"
  of aekStatus:
    case entry.data.sourceType
    of "turn_complete": "Tool phase complete"
    of "file_read": "File read"
    of "delegation": "Delegation"
    of "orchestration": "Orchestration"
    of "context_files": "Context files"
    of "fleet_fence": "Workspace synchronization"
    of "fleet_host": "Host execution"
    of "session_started": "Session started"
    of "session_awaiting_input": "Waiting for input"
    of "session_resumed": "Session resumed"
    of "session_ended": "Session ended"
    of "proxy_credential_rotated": "Provider access recovered"
    of "proxy_rate_limit_absorbed": "Provider throttling recovered"
    of "dispatcher_restarted": "Agent restarted"
    of "anti_halting_resume_confirmed": "Agent progress resumed"
    of "session_leadership_migrated": "Session moved to another executor"
    of "agent_question": "Agent question"
    of "participant": "Participant activity"
    of "context_injection": "Session context"
    of "login_required": "Provider login required"
    of "link_spans": "Source references"
    else:
      if entry.data.sourceType.len > 0: "Session activity · " & entry.data.sourceType else: "Activity"
  of aekMessageChunk: "Assistant"

proc activityAvailability*(entry: ActivityEntry): string =
  # Availability belongs to the editor view, not shared provider semantics.
  # This notice concerns the correlated request; ordinary chat remains available
  # under its existing turn/session admission rules. Harbor owns the durable
  # LOGIN REQUIRED card in WebUI task details/Inbox; the editor has no viewer
  # endpoint contract and never exposes the event's opaque login surface.
  if entry.kind == aekStatus:
    if entry.data.sourceType == "login_required":
      return "Open the matching LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available. This editor cannot open sign-in. If you cannot access Harbor, ask this editor's operator to open the request." &
        (if entry.data.question.len > 0: " This editor cannot answer this request." else: "")
    if entry.data.question.len > 0: return "This editor cannot answer this request."
    if entry.data.sourceType == "session_awaiting_input":
      return "Waiting for input. This editor cannot respond to this request."

proc detailContent(entry: ActivityEntry): string =
  let event = entry.data
  case entry.kind
  of aekFileEdit: "+" & $event.linesAdded & " / −" & $event.linesRemoved & " lines"
  of aekMilestoneProgress:
    if event.milestoneTotal > 0: $event.milestoneCompleted & " / " & $event.milestoneTotal else: ""
  of aekWorkspaceReady: event.workspacePath
  of aekReview: event.filePath & (if event.line > 0: ":" & $event.line else: "")
  of aekLlmRequest:
    event.model & (if event.hasUsage:
      " · " & (if event.inputTokens >= 0: $event.inputTokens else: "unknown") & " input / " &
      (if event.outputTokens >= 0: $event.outputTokens else: "unknown") & " output tokens" &
      (if event.usageSource.len > 0: " · " & event.usageSource else: "") else: "")
  of aekStatus:
    if event.question.len > 0: "This editor cannot answer this request."
    elif event.sourceType == "login_required": "Open the matching LOGIN REQUIRED card in Agent Harbor WebUI task details or Inbox, if available. This editor cannot open sign-in. If you cannot access Harbor, ask this editor's operator to open the request."
    elif event.sourceType == "session_awaiting_input": "Waiting for input. This editor cannot respond to this request."
    elif event.presentationFields.len == 0: event.sourceType
    else: ""
  else:
    if entry.role == arActivity and entry.text.len > 500:
      entry.detail & (if entry.detail.len > 0: "\n\n" else: "") & entry.text
    else: entry.detail

proc activityDetail*(entry: ActivityEntry): string =
  result = detailContent(entry)
  for field in entry.data.presentationFields:
    if result.len > 0: result.add '\n'
    result.add field.name.replace("_", " ") & ": " & field.value

proc activityBody(entry: ActivityEntry): string =
  if entry.role == arActivity and entry.text.len > 500:
    entry.text[0 ..< 240] & "…"
  else: entry.text

proc updateStableText[R, E](r: R; node: E; value: string) =
  when defined(js) and compiles(node.ownerDocument):
    let browserText = cstring(value)
    # Appending streaming content must preserve an existing selection. Updating
    # the same Text node, rather than replacing its subtree, preserves ranges.
    {.emit: ["""
      (function(el, text) {
        if (!el.firstChild) el.appendChild(el.ownerDocument.createTextNode(text));
        else if (el.firstChild.nodeType === 3 && el.childNodes.length === 1) {
          const old = el.firstChild.data;
          if (old === text) return;
          let common = 0;
          while (common < old.length && common < text.length && old[common] === text[common]) common++;
          el.firstChild.replaceData(common, old.length - common, text.slice(common));
        } else el.textContent = text;
      })(""", node, ",", browserText, ");"].}
  else: r.setTextContent(node, value)

proc renderActivityTimeline*[R, E](r: R; host: E; chat: AgentChatVM) =
  type Reader = ref object
    alive, opened: bool
    entry: string
    index: int
    trigger, overlay, content, closeButton, title: E
  let reader = Reader(alive: true)
  reader.overlay = r.createElement("dialog")
  r.setAttribute(reader.overlay, "data-chat-code-reader", "true")
  r.setAttribute(reader.overlay, "role", "dialog")
  r.setAttribute(reader.overlay, "aria-modal", "true")
  r.setAttribute(reader.overlay, "aria-label", "Expanded code")
  for (key, value) in [("display", "none"), ("position", "fixed"),
      ("inset", "48px 24px 120px"), ("z-index", "60"),
      ("margin", "0"), ("width", "calc(100vw - 48px)"),
      ("height", "calc(100vh - 168px)"), ("max-width", "none"), ("max-height", "none"),
      ("box-sizing", "border-box"), ("padding", "20px"),
      ("background-color", bgSidebar), ("border", "1px solid " & border),
      ("border-radius", "10px"), ("box-shadow", "0 16px 64px rgba(0,0,0,.55)"),
      ("flex-direction", "column"), ("gap", "12px"), ("color", textPrimary)]:
    r.setStyle(reader.overlay, key, value)
  let header = r.createElement("div")
  r.setStyle(header, "display", "flex")
  r.setStyle(header, "justify-content", "space-between")
  r.setStyle(header, "align-items", "center")
  let title = r.createElement("strong")
  reader.title = title
  r.setTextContent(title, "Expanded code")
  r.appendChild(header, title)
  reader.closeButton = r.createElement("button")
  r.setAttribute(reader.closeButton, "type", "button")
  r.setAttribute(reader.closeButton, "data-chat-code-close", "true")
  r.setTextContent(reader.closeButton, "Close code")
  for (key, value) in [("color", textPrimary), ("background-color", bgInput),
      ("border", "1px solid " & border), ("border-radius", "5px"),
      ("padding", "8px 12px"), ("cursor", "pointer")]:
    r.setStyle(reader.closeButton, key, value)
  r.appendChild(header, reader.closeButton)
  r.appendChild(reader.overlay, header)
  reader.content = r.createElement("pre")
  r.setAttribute(reader.content, "data-chat-code-expanded-text", "true")
  r.setAttribute(reader.content, "tabindex", "0")
  for (key, value) in [("margin", "0"), ("padding", "16px"),
      ("white-space", "pre-wrap"), ("overflow-wrap", "anywhere"),
      ("overflow", "auto"), ("min-height", "0"), ("flex", "1"),
      ("font-family", "ui-monospace, monospace"), ("font-size", "14px"),
      ("line-height", "1.65"), ("background-color", bgInput)]:
    r.setStyle(reader.content, key, value)
  r.appendChild(reader.overlay, reader.content)
  r.appendChild(host, reader.overlay)
  proc closeReader(restore: bool) =
    if not reader.alive or not reader.opened: return
    reader.opened = false
    when defined(js) and compiles(reader.overlay.ownerDocument):
      let overlay = reader.overlay
      {.emit: [overlay, ".close();"].}
    r.setStyle(reader.overlay, "display", "none")
    if reader.trigger != default(E):
      r.setAttribute(reader.trigger, "aria-expanded", "false")
      if restore:
        when defined(js) and compiles(reader.trigger.ownerDocument):
          let trigger = reader.trigger
          let container = host
          {.emit: ["""
            (function(trigger,host) {
              const target = trigger.isConnected && trigger.getClientRects().length ? trigger :
                host.closest('.editor-chat')?.querySelector('textarea');
              if (target) target.focus({preventScroll:true});
            })(""", trigger, ",", container, ");"].}
        elif compiles(r.focus(reader.trigger)): r.focus(reader.trigger)
    reader.trigger = default(E)
    reader.entry = ""
    r.updateStableText(reader.content, "")
  r.addEventListener(reader.closeButton, "click", proc() = closeReader(true))
  when defined(js) and compiles(reader.overlay.ownerDocument):
    let overlay = reader.overlay
    let close = reader.closeButton
    {.emit: ["""
      (function(overlay,close) {
        overlay.addEventListener('cancel', function(event) { event.preventDefault(); close.click(); });
        overlay.addEventListener('keydown', function(event) {
          if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation(); close.click(); }
          if (event.key === 'Tab') {
            const targets = [close,overlay.querySelector('[data-chat-code-expanded-text]')];
            const index = targets.indexOf(overlay.ownerDocument.activeElement);
            event.preventDefault(); targets[index < 0 ? (event.shiftKey ? 1 : 0) : (index + 1) % 2].focus();
          }
        });
      })(""", overlay, ",", close, ");"].}
  onCleanup proc() =
    closeReader(false)
    reader.alive = false
    reader.trigger = default(E)
    r.removeChild(host, reader.overlay)
    reader.overlay = default(E)
    reader.content = default(E)
    reader.closeButton = default(E)
    reader.title = default(E)
  type Row = object
    node, title, body, detail, detailText, status, facts, header, availability: E
    factRows, factLabels, factValues: seq[E]
    blocks, expandButtons: seq[E]
    kinds: seq[string]
    expandInDetail: seq[bool]
  # Retain the registry through render-effect disposal, then release its rows
  # while the owner is still alive. The host's reference release can enter
  # native cycle collection; it must not trace partially destroyed row storage.
  let rows = newTable[string, Row]()
  onCleanup proc() = rows.clear()
  # A fresh activation owns each block index; loop locals are shared in the JS
  # backend and otherwise make every button open the final block.
  proc installExpansion(expand: E; entryId: string; blockIndex: int) =
    r.addEventListener(expand, "click", proc() =
      if not reader.alive: return
      if entryId notin rows or blockIndex >= rows[entryId].expandButtons.len or
          rows[entryId].expandButtons[blockIndex] != expand: return
      for current in chat.activity.val.entries:
        if current.id != entryId: continue
        let currentBlocks = chatMarkdownBlocks(current.text)
        if blockIndex >= currentBlocks.len or currentBlocks[blockIndex].kind != "code": return
        closeReader(false)
        reader.entry = entryId
        reader.index = blockIndex
        reader.trigger = expand
        reader.opened = true
        r.updateStableText(reader.content, currentBlocks[blockIndex].text)
        r.updateStableText(reader.title, "Expanded code" & (if currentBlocks[blockIndex].language.len > 0: " · " & currentBlocks[blockIndex].language else: ""))
        r.setAttribute(reader.overlay, "data-chat-code-language", currentBlocks[blockIndex].language)
        r.setAttribute(expand, "aria-expanded", "true")
        r.setStyle(reader.overlay, "display", "flex")
        when defined(js) and compiles(reader.overlay.ownerDocument):
          let overlay = reader.overlay
          let close = reader.closeButton
          {.emit: [overlay, ".showModal();", close, ".focus({preventScroll:true});"].}
        elif compiles(r.focus(reader.closeButton)): r.focus(reader.closeButton)
    )
  createRenderEffect proc() =
    var present = initTable[string, bool]()
    for entry in chat.activity.val.entries:
      present[entry.id] = true
      var row: Row
      if entry.id in rows:
        row = rows[entry.id]
      else:
        row.node = r.createElement("section")
        r.setAttribute(row.node, "data-chat-entry", entry.id)
        r.setAttribute(row.node, "data-chat-role", $entry.role)
        r.setAttribute(row.node, "data-chat-kind", $entry.kind)
        r.setAttribute(row.node, "data-chat-turn", $entry.turn)
        for (key, value) in [("min-width", "0"), ("flex-shrink", "0"),
            ("padding", "10px 12px"), ("border-radius", "8px"),
            ("overflow-wrap", "anywhere"), ("color", textBody),
            ("line-height", "1.65"), ("font-size", "12px")]:
          r.setStyle(row.node, key, value)
        if entry.role == arUser:
          r.setStyle(row.node, "background-color", bgSurface)
          r.setStyle(row.node, "border", "1px solid " & border)
        elif entry.role == arActivity:
          r.setStyle(row.node, "border-left", "2px solid " & border)
        row.header = r.createElement("div")
        r.setStyle(row.header, "display", "flex")
        r.setStyle(row.header, "align-items", "baseline")
        r.setStyle(row.header, "justify-content", "space-between")
        r.setStyle(row.header, "gap", "8px")
        r.appendChild(row.node, row.header)
        row.title = r.createElement("div")
        r.setStyle(row.title, "font-size", "11px")
        r.setStyle(row.title, "font-weight", "600")
        r.setStyle(row.title, "color", textSecondary)
        r.appendChild(row.header, row.title)
        row.status = r.createElement("span")
        r.setAttribute(row.status, "data-chat-activity-status", "true")
        r.setStyle(row.status, "font-size", "10px")
        r.setStyle(row.status, "border-radius", "4px")
        r.setStyle(row.status, "padding", "1px 5px")
        r.setStyle(row.status, "background-color", bgInput)
        r.setStyle(row.status, "color", textSecondary)
        r.appendChild(row.header, row.status)
        row.facts = r.createElement("div")
        r.setAttribute(row.facts, "data-chat-facts", "true")
        r.setStyle(row.facts, "display", "grid")
        r.setStyle(row.facts, "gap", "5px")
        r.setStyle(row.facts, "margin-top", "8px")
        r.appendChild(row.node, row.facts)
        row.body = r.createElement("div")
        r.appendChild(row.node, row.body)
        row.availability = r.createElement("p")
        r.setAttribute(row.availability, "data-chat-availability", "true")
        r.setStyle(row.availability, "margin", "8px 0 0")
        r.setStyle(row.availability, "color", textPrimary)
        r.setStyle(row.availability, "white-space", "pre-wrap")
        r.appendChild(row.node, row.availability)
        row.detail = r.createElement("details")
        let summary = r.createElement("summary")
        r.setTextContent(summary, "Details")
        r.setStyle(summary, "cursor", "pointer")
        r.setStyle(summary, "color", textSecondary)
        r.appendChild(row.detail, summary)
        let content = r.createElement("pre")
        row.detailText = content
        r.setAttribute(content, "data-chat-detail", "true")
        r.setStyle(content, "white-space", "pre-wrap")
        r.setStyle(content, "overflow-wrap", "anywhere")
        r.setStyle(content, "font-size", "11px")
        r.setStyle(content, "max-height", "240px")
        r.setStyle(content, "overflow-y", "auto")
        r.appendChild(row.detail, content)
        r.appendChild(row.node, row.detail)
        r.appendChild(host, row.node)
      r.setAttribute(row.node, "data-chat-source", entry.data.sourceType)
      let presentation = activityPresentation(entry)
      r.setAttribute(row.node, "data-chat-surface", presentation.surface)
      r.setStyle(row.node, "background-color", if entry.role == arUser: bgSurface
        elif entry.role == arActivity: "#151F31" else: "transparent")
      # Square human cards keep their border, fill and content while avoiding
      # unstable rounded-border edge rasterization in the pinned renderer.
      # Agent/activity surfaces retain their rounded visual hierarchy.
      r.setStyle(row.node, "border-radius", if entry.role == arUser: "0px" else: "10px")
      r.setStyle(row.node, "border-left-color", if presentation.tone == "error": errorAccent
        elif presentation.tone == "attention": gold
        elif presentation.tone == "success": green else: border)
      for index, fact in presentation.facts:
        if index >= row.factRows.len:
          let factRow = r.createElement("div")
          let label = r.createElement("span")
          let value = r.createElement("span")
          r.setStyle(factRow, "display", "flex")
          r.setStyle(factRow, "align-items", "baseline")
          r.setStyle(factRow, "gap", "8px")
          r.setStyle(factRow, "min-width", "0")
          r.setStyle(label, "color", textSecondary)
          r.setStyle(label, "font-size", "11px")
          r.setStyle(label, "flex-shrink", "0")
          r.setStyle(value, "color", textPrimary)
          r.setStyle(value, "font-size", "11px")
          r.setStyle(value, "overflow-wrap", "anywhere")
          r.setStyle(value, "white-space", "pre-wrap")
          r.setStyle(value, "flex", "1")
          r.setStyle(value, "min-width", "0")
          r.appendChild(factRow, label)
          r.appendChild(factRow, value)
          r.appendChild(row.facts, factRow)
          row.factRows.add factRow
          row.factLabels.add label
          row.factValues.add value
        r.setAttribute(row.factRows[index], "data-chat-fact", fact.label)
        r.updateStableText(row.factLabels[index], fact.label)
        r.updateStableText(row.factValues[index], fact.value)
        r.setStyle(row.factRows[index], "display", "flex")
        r.setStyle(row.factValues[index], "color", if fact.tone == "success": green
          elif fact.tone == "error": textError elif fact.tone == "attention": "#FCD34D" else: textPrimary)
      for index in presentation.facts.len ..< row.factRows.len:
        r.setStyle(row.factRows[index], "display", "none")
      r.setStyle(row.facts, "display", if presentation.facts.len > 0: "grid" else: "none")
      r.updateStableText(row.title, activityTitle(entry))
      r.updateStableText(row.status, presentation.status.replace("_", " "))
      r.setStyle(row.status, "display", if presentation.status.len > 0: "inline-block" else: "none")
      r.setStyle(row.status, "color", if presentation.status in ["failed", "error"] or
        entry.kind == aekError: textError else: textSecondary)
      let availability = activityAvailability(entry)
      r.updateStableText(row.availability, availability)
      r.setStyle(row.availability, "display", if availability.len > 0: "block" else: "none")
      r.setStyle(row.detail, "display", if activityDetail(entry).len > 0: "block" else: "none")
      r.updateStableText(row.detailText, activityDetail(entry))
      # Reader identity/content always comes from the complete safe entry. The
      # compact activity card keeps its existing excerpt; later fenced blocks
      # still get individually labelled controls in Details without expanding
      # the whole card.
      let hideBody = entry.kind == aekPlan and presentation.facts.len > 0
      let blocks = chatMarkdownBlocks(if hideBody: "" else: entry.text)
      let inlineBlocks = chatMarkdownBlocks(if hideBody: "" else: activityBody(entry))
      var codeOrdinal = 0
      for index, item in blocks:
        if item.kind == "code": inc codeOrdinal
        if index >= row.blocks.len:
          let node = r.createElement(if item.kind == "code": "pre" else: "div")
          r.setStyle(node, "white-space", "pre-wrap")
          r.setStyle(node, "overflow-wrap", "anywhere")
          r.setStyle(node, "margin-top", "5px")
          r.setStyle(node, "min-width", "0")
          r.setAttribute(node, "data-chat-markdown", item.kind)
          if item.kind == "code":
            r.setStyle(node, "padding", "9px")
            r.setStyle(node, "background-color", bgInput)
            r.setStyle(node, "border-radius", "6px")
            r.setStyle(node, "font-size", "11px")
          elif item.kind == "heading": r.setStyle(node, "font-weight", "700")
          r.appendChild(row.body, node)
          row.blocks.add node
          row.kinds.add item.kind
          row.expandButtons.add default(E)
          row.expandInDetail.add false
        if item.kind == "code" and row.expandButtons[index] == default(E):
          let expand = r.createElement("button")
          r.setAttribute(expand, "type", "button")
          r.setAttribute(expand, "data-chat-code-expand", $index)
          r.setAttribute(expand, "aria-label", "Expand code block " & $(index + 1))
          r.setAttribute(expand, "aria-haspopup", "dialog")
          r.setAttribute(expand, "aria-expanded", "false")
          r.setTextContent(expand, "Expand code")
          for (key, value) in [("color", textPrimary), ("background-color", bgInput),
              ("border", "1px solid " & border), ("border-radius", "5px"),
              ("padding", "6px 10px"), ("cursor", "pointer"), ("margin-top", "4px"), ("display", "inline-block")]:
            r.setStyle(expand, key, value)
          row.expandInDetail[index] = index >= inlineBlocks.len
          if row.expandInDetail[index]: r.appendChild(row.detail, expand)
          elif index + 1 < row.blocks.len:
            r.insertBefore(row.body, expand, row.blocks[index + 1])
          else: r.appendChild(row.body, expand)
          row.expandButtons[index] = expand
          installExpansion(expand, entry.id, index)
        if item.kind == "code":
          let expand = row.expandButtons[index]
          let inDetail = index >= inlineBlocks.len
          if row.expandInDetail[index] != inDetail:
            r.removeChild(if row.expandInDetail[index]: row.detail else: row.body, expand)
            if inDetail: r.appendChild(row.detail, expand)
            elif index + 1 < row.blocks.len: r.insertBefore(row.body, expand, row.blocks[index + 1])
            else: r.appendChild(row.body, expand)
            row.expandInDetail[index] = inDetail
          let label = "Expand code block " & $codeOrdinal & (if item.language.len > 0: " · " & item.language else: "")
          r.setAttribute(expand, "aria-label", label)
          r.setTextContent(expand, if inDetail: label else: "Expand code")
        r.setAttribute(row.blocks[index], "data-chat-markdown", item.kind)
        r.setAttribute(row.blocks[index], "data-chat-code-language", item.language)
        r.setStyle(row.blocks[index], "font-weight", if item.kind == "heading": "700" else: "400")
        r.setStyle(row.blocks[index], "font-family", if item.kind == "code": "ui-monospace, monospace" else: "inherit")
        r.setStyle(row.blocks[index], "background-color", if item.kind == "code": bgInput else: "transparent")
        r.setStyle(row.blocks[index], "padding", if item.kind == "code": "9px" else: "0")
        if item.kind != "code" and row.expandButtons[index] != default(E):
          r.removeChild(if row.expandInDetail[index]: row.detail else: row.body, row.expandButtons[index])
          row.expandButtons[index] = default(E)
        if reader.opened and reader.entry == entry.id and reader.index == index:
          if item.kind == "code":
            r.updateStableText(reader.content, item.text)
            r.updateStableText(reader.title, "Expanded code" & (if item.language.len > 0: " · " & item.language else: ""))
            r.setAttribute(reader.overlay, "data-chat-code-language", item.language)
          else: closeReader(true)
        row.kinds[index] = item.kind
        r.updateStableText(row.blocks[index], if index < inlineBlocks.len: inlineBlocks[index].text else: "")
        r.setStyle(row.blocks[index], "display", if index < inlineBlocks.len: "block" else: "none")
      for index in blocks.len ..< row.blocks.len:
        r.setStyle(row.blocks[index], "display", "none")
        if row.expandButtons[index] != default(E):
          r.removeChild(if row.expandInDetail[index]: row.detail else: row.body, row.expandButtons[index])
          row.expandButtons[index] = default(E)
        if reader.opened and reader.entry == entry.id and reader.index == index: closeReader(true)
      rows[entry.id] = row

    var removed: seq[string]
    for id, row in tables.pairs(rows):
      if not tables.hasKey(present, id):
        r.removeChild(host, row.node)
        if reader.opened and reader.entry == id: closeReader(true)
        removed.add id
    for id in removed: rows.del(id)
