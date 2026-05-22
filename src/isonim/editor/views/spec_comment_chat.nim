## TBAR-M6 — Spec-Comment → AI Assistant chat submission path.
##
## Single entry point :proc:`submitSpecComment` that:
##
##   1. Builds a structured prompt body from the
##      :type:`CommentDraft` + the active ``briefId``.
##   2. Writes the prompt into ``chatVm.inputText`` and dispatches
##      ``editor.sendAgentPrompt()``.  The prompt adapter (configured
##      by :proc:`design_review.editor_agent_adapter.configureDaemonAgentAdapters`)
##      mints a session via ``POST /api/agent/sessions`` on first
##      prompt and reuses it afterwards; the prompt itself is sent
##      via ``POST /api/agent/prompts``.
##   3. Reports success / failure through the supplied callback so
##      the popover VM can clear / surface an error.
##
## The wire format is a structured plain-text block prefixed by
## ``SPEC COMMENT`` so the AI Assistant's system prompt (see
## ``ai-assistant.md``) can detect and parse it without a custom
## tool-call payload.  Format:
##
## ::
##
##   SPEC COMMENT
##   briefId: <briefId>
##   selectedText: |
##     <each line indented two spaces>
##   userComment: |
##     <each line indented two spaces>
##
## The block ends with a trailing newline so it composes cleanly with
## any free-form text the chat input might already carry.

import std/strutils

import isonim/core/signals
import isonim/editor/viewmodels
import isonim/editor/views/spec_comment_popover

proc indentBlock(s: string): string =
  ## Render ``s`` as a multi-line YAML-style scalar value indented by
  ## two spaces.  Empty input collapses to a single empty line so the
  ## emitted block stays parseable.
  if s.len == 0:
    return "  "
  var lines = s.splitLines()
  if lines.len == 0:
    return "  "
  # ``splitLines`` returns a trailing empty entry if the input ends
  # with ``\n`` — drop it so we don't emit a stray indented blank line.
  if lines[^1].len == 0:
    lines.setLen(lines.len - 1)
  if lines.len == 0:
    return "  "
  var parts: seq[string] = @[]
  for line in lines:
    parts.add "  " & line
  parts.join("\n")

proc buildSpecCommentPrompt*(briefId: string; draft: CommentDraft): string =
  ## Compose the structured prompt body the AI Assistant chat will
  ## receive.  Exposed publicly so tests can assert the exact shape
  ## that flows over the wire without having to spawn the chat
  ## subprocess.  The function is pure — no signals, no HTTP.
  let bid = if briefId.len > 0: briefId else: "<unknown>"
  var lines: seq[string] = @[]
  lines.add "SPEC COMMENT"
  lines.add "briefId: " & bid
  lines.add "selectedText: |"
  lines.add indentBlock(draft.selectedText)
  lines.add "userComment: |"
  lines.add indentBlock(draft.userComment)
  lines.join("\n") & "\n"

proc submitSpecComment*(editor: EditorVM; briefId: string;
                        draft: CommentDraft;
                        cb: proc(success: bool; reason: string)) =
  ## TBAR-M6 — drive a comment-to-chat submission.  Builds the prompt
  ## body, writes it into ``editor.chat.inputText``, dispatches
  ## ``sendAgentPrompt`` (which routes through the configured
  ## :type:`AgentPromptAdapter` — i.e. ``POST /api/agent/sessions`` if
  ## no session is active, then ``POST /api/agent/prompts``), and
  ## reports the immediate dispatch outcome through ``cb``.
  ##
  ## ``cb(true, "")`` on a successful dispatch — the streaming
  ## response continues asynchronously through the chat VM's normal
  ## event pipeline.  ``cb(false, reason)`` when the adapter is
  ## missing or the dispatch returns false.
  if editor == nil:
    if cb != nil: cb(false, "editor unavailable")
    return
  let prompt = buildSpecCommentPrompt(briefId, draft)
  editor.chat.inputText.val = prompt
  let dispatched = editor.sendAgentPrompt()
  if dispatched:
    # ``sendAgentPrompt`` consumes ``inputText`` by writing the user
    # message + invoking the adapter; clear the slot so a follow-up
    # plain-text turn doesn't accidentally re-include the structured
    # block.
    editor.chat.inputText.val = ""
    if cb != nil: cb(true, "")
  else:
    let reason =
      if editor.chat.promptAdapter == nil: "no agent adapter configured"
      else: editor.chat.connectionState.val
    if cb != nil: cb(false, reason)
