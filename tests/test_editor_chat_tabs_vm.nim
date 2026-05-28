## Multi-chat tabs ViewModel tests.
##
## Exercises the multi-chat machinery on ``EditorVM``:
##   * ``createEditorVM`` seeds exactly one ``"New chat"`` session
##     with id ``"chat-1"`` and marks it active.
##   * ``createNewChat`` appends a fresh session, returns its id, and
##     activates the new chat.
##   * ``switchToChat`` flips ``activeChatId`` and the backward-
##     compatible ``vm.chat`` accessor follows.
##   * ``closeChat`` removes the requested session, refuses to close
##     the final remaining chat, and reassigns ``activeChatId`` when
##     the active chat is removed.
##   * The alias accessor ``vm.chat`` always returns the
##     ``AgentChatVM`` of the active session — preserving the legacy
##     ``vm.chat.*`` access pattern that the rest of the editor relies
##     on.

import std/unittest

import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/editor/viewmodels

suite "Editor multi-chat tabs (Assistant tab)":

  test "createEditorVM seeds a single New chat session":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.chats.val.len == 1
      check vm.chats.val[0].id == "chat-1"
      check vm.chats.val[0].title.val == "New chat"
      check vm.activeChatId.val == "chat-1"
      # The alias accessor resolves to the active session's VM.
      check vm.chat == vm.chats.val[0].vm
      check vm.chat.messages.val.len == 0
      check vm.chat.sessionStatus.val == asIdle
      dispose()

  test "createNewChat appends, activates, and returns the new id":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let id = vm.createNewChat()
      check id == "chat-2"
      check vm.chats.val.len == 2
      check vm.chats.val[1].id == "chat-2"
      check vm.chats.val[1].title.val == "New chat 2"
      check vm.activeChatId.val == "chat-2"
      # Active alias follows the new chat — every existing
      # ``vm.chat.*`` call site now targets chat-2.
      check vm.chat == vm.chats.val[1].vm
      # Each session has its own messages — recording on the new chat
      # must not leak into the first chat.
      vm.chat.addUserMessage("Second chat hello")
      check vm.chats.val[1].vm.messages.val.len == 1
      check vm.chats.val[0].vm.messages.val.len == 0
      dispose()

  test "successive createNewChat assigns stable sequential ids":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let id2 = vm.createNewChat()
      let id3 = vm.createNewChat()
      let id4 = vm.createNewChat()
      check id2 == "chat-2"
      check id3 == "chat-3"
      check id4 == "chat-4"
      check vm.chats.val.len == 4
      check vm.chats.val[1].title.val == "New chat 2"
      check vm.chats.val[2].title.val == "New chat 3"
      check vm.chats.val[3].title.val == "New chat 4"
      check vm.activeChatId.val == "chat-4"
      dispose()

  test "switchToChat flips active id and the chat alias":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      discard vm.createNewChat()
      discard vm.createNewChat()
      check vm.activeChatId.val == "chat-3"
      check vm.switchToChat("chat-1") == true
      check vm.activeChatId.val == "chat-1"
      check vm.chat == vm.chats.val[0].vm
      # Switching to an unknown id leaves state alone.
      check vm.switchToChat("ghost-99") == false
      check vm.activeChatId.val == "chat-1"
      dispose()

  test "closeChat removes a session and reassigns active when needed":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      discard vm.createNewChat()  # chat-2
      discard vm.createNewChat()  # chat-3
      check vm.activeChatId.val == "chat-3"
      # Closing a non-active chat preserves the active id.
      check vm.closeChat("chat-2") == true
      check vm.chats.val.len == 2
      check vm.activeChatId.val == "chat-3"
      check vm.chats.val[0].id == "chat-1"
      check vm.chats.val[1].id == "chat-3"
      # Closing the active chat falls back to the previous neighbour.
      check vm.closeChat("chat-3") == true
      check vm.chats.val.len == 1
      check vm.activeChatId.val == "chat-1"
      check vm.chat == vm.chats.val[0].vm
      dispose()

  test "closeChat refuses to remove the last remaining chat":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      check vm.chats.val.len == 1
      # Closing the only chat must be a no-op so ``vm.chat`` always
      # resolves to something.
      check vm.closeChat("chat-1") == false
      check vm.chats.val.len == 1
      check vm.activeChatId.val == "chat-1"
      dispose()

  test "closeChat on unknown id is a no-op":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      discard vm.createNewChat()
      let snapshot = vm.chats.val
      let activeSnapshot = vm.activeChatId.val
      check vm.closeChat("does-not-exist") == false
      check vm.chats.val == snapshot
      check vm.activeChatId.val == activeSnapshot
      dispose()

  # -------------------------------------------------------------------------
  # Phase I/J demolition (2026-05-28) — the AI drawer open/close/toggle
  # tests were dropped. The drawer no longer exists; the AI assistant is
  # mounted in the right sidebar via ``renderAiAssistantPanel`` whenever
  # the active mode is not ``emEdit``. See
  # ``Front-Ends/IsoNim/isonim-editor.md`` §"Mode-driven right sidebar
  # (2026-05-28 revision)".
  # -------------------------------------------------------------------------

  test "vm.chat alias always resolves to the active chat":
    ## Regression guard: every existing ``vm.chat.*`` call site in the
    ## codebase must keep working. This pins the alias contract
    ## across chat creation, switching, and closing.
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.chat.addUserMessage("first chat msg")
      let chat2Id = vm.createNewChat()
      vm.chat.addUserMessage("second chat msg")
      # Each chat has the messages we sent into it via the alias.
      check vm.chats.val[0].vm.messages.val.len == 1
      check vm.chats.val[0].vm.messages.val[0].text == "first chat msg"
      check vm.chats.val[1].vm.messages.val.len == 1
      check vm.chats.val[1].vm.messages.val[0].text == "second chat msg"
      # Flipping active changes what ``vm.chat`` points at.
      check vm.switchToChat("chat-1") == true
      check vm.chat.messages.val.len == 1
      check vm.chat.messages.val[0].text == "first chat msg"
      check vm.switchToChat(chat2Id) == true
      check vm.chat.messages.val.len == 1
      check vm.chat.messages.val[0].text == "second chat msg"
      # Closing the active chat re-points the alias at the survivor.
      check vm.closeChat(chat2Id) == true
      check vm.chats.val.len == 1
      check vm.chat.messages.val[0].text == "first chat msg"
      dispose()
