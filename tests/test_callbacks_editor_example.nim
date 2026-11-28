## A worked example, not a port: the editor's agent-turn callbacks
## (`editor/design_review/editor_agent_adapter.nim`, `installAdapterCallbacks`)
## expressed through `fromCallbacks`, under fake time.
##
## The adapter installs four callbacks on its client per prompt (`onUpdate`,
## `onEnd`, `onInterrupted`, `onError`), and each begins with the same
## liveness test: return if the client is closed or the chat has moved on to
## a later prompt. Here a turn is the question of an async value, each turn
## is one flight of `fromCallbacks`, and every callback is passed through
## `sink.wrap`. The callback bodies below keep the adapter's writes (the
## reply, the connection state, the stop reason, the draft restored on a
## refusal, the error message) and none of the four tests: `installTurn`
## contains no comparison with a prompt number and no check of `closed`. The
## tests are the adapter's own cases for stale callbacks, made against this
## shape: a finished turn's transport, an interrupted turn's open transport,
## a closed chat and a disposed one cannot change the chat any more.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## `FakeAgentClient` stands in for the browser agent client, whose
## transport is the browser's event stream and does not exist on the C
## backend or in node. It keeps the real client's shape: one set of four
## callbacks on the client, captured by the transport of each prompt when
## the prompt is submitted (as the real `submitPrompt` does), and a
## `closed` flag. The test fires the transport's events itself, at chosen
## times on the fake clock, because the cases are events arriving after
## their turn stopped. The chat state is a small object of real signals in
## place of the editor's chat ViewModel, which the real port (a later step)
## changes; the async value, the adapter, the stream protocol and the owner
## are the real ones.

import std/[options, unittest]

import nim_everywhere
import isonim/core/[signals, owner, computation]
import isonim/services/[async_value, callbacks]

import helpers/async_recording_service

type
  AgentCallback = proc(text: cstring) {.closure.}

  AgentCallbacks = object
    onUpdate, onEnd, onInterrupted, onError: AgentCallback

  FakeAgentClient = ref object
    callbacks: AgentCallbacks
    closed: bool
    transports: seq[AgentCallbacks]   ## Captured per submitted prompt.
    prompts: seq[string]

  Turn = object
    ## The question: a prompt and its place, so a repeated prompt is a new
    ## question.
    number: int
    prompt: string

  Chat = ref object
    ## The parts of the editor's chat state the adapter's callbacks write.
    messages: Signal[seq[string]]
    connectionState: Signal[string]
    stopReason: Signal[string]
    inputText: Signal[string]
    pendingPromptText: string
    asked: Signal[Option[Turn]]
    turns: int
    turn: AsyncValue[seq[string]]
    disposeRoot: proc()

proc submitPrompt(c: FakeAgentClient; prompt: string) =
  ## Like the real client: the transport keeps the callbacks set now.
  c.prompts.add prompt
  c.transports.add c.callbacks

proc addMessage(chat: Chat; text: string) =
  chat.messages.update proc(prev: seq[string]): seq[string] =
    result = prev
    result.add text

proc installTurn(chat: Chat; client: FakeAgentClient; turn: Turn):
    ServiceStream[string] =
  ## One turn's callbacks. Compare `installAdapterCallbacks`: the same
  ## writes, without its four `if client.closed or ... promptGeneration ...:
  ## return` lines.
  fromCallbacks(proc(sink: Sink[string]): Uninstall =
    let previous = client.callbacks
    client.callbacks = AgentCallbacks(
      onUpdate: sink.wrap(proc(payload: cstring) =
        chat.addMessage("agent: " & $payload)),
      onEnd: sink.wrap(proc(stopReason: cstring) =
        if chat.inputText.value.len == 0:
          chat.inputText.val = chat.pendingPromptText
        chat.stopReason.val = $stopReason
        chat.connectionState.val =
          if $stopReason == "cancelled": "cancelled"
          elif $stopReason == "error": "error"
          else: "completed"
        sink.emit($stopReason)
        sink.finish()),
      onInterrupted: sink.wrap(proc(message: cstring) =
        # The transport ended without the turn's end: the turn stays in
        # flight until the chat ends it.
        chat.connectionState.val = "interrupted"
        chat.addMessage("error: " & $message)),
      onError: sink.wrap(proc(message: cstring) =
        if chat.inputText.value.len == 0:
          chat.inputText.val = chat.pendingPromptText
        chat.connectionState.val = "failed"
        chat.addMessage("error: " & $message)
        sink.fail($message)))
    chat.connectionState.val = "streaming"
    client.submitPrompt(turn.prompt)
    result = proc() = client.callbacks = previous)

proc newChat(client: FakeAgentClient): Chat =
  let chat = Chat()
  createRoot proc(dispose: proc()) =
    chat.disposeRoot = dispose
    chat.messages = createSignal(newSeq[string]())
    chat.connectionState = createSignal("idle")
    chat.stopReason = createSignal("")
    chat.inputText = createSignal("")
    chat.asked = createSignal(none(Turn))
    chat.turn = createAsyncStream(proc(): Option[Turn] = chat.asked.val,
      proc(turn: Option[Turn]): ServiceStream[string] =
        # `none` asks nothing, so the call always receives `some`.
        chat.installTurn(client, turn.get))
  chat

proc send(chat: Chat; prompt: string) =
  inc chat.turns
  chat.pendingPromptText = prompt
  chat.addMessage("user: " & prompt)
  chat.asked.val = some(Turn(number: chat.turns, prompt: prompt))

proc endTurn(chat: Chat) =
  ## Ends the turn in flight (as closing the chat, or the chat's end of an
  ## interrupted turn, does).
  chat.asked.val = none(Turn)

proc inFlight(chat: Chat): bool =
  chat.turn.loading or chat.turn.pending or
    (chat.turn.ready and not chat.turn.done)

proc fireAll(cb: AgentCallbacks; text: cstring) =
  cb.onUpdate(text)
  cb.onEnd(text)
  cb.onInterrupted(text)
  cb.onError(text)

suite "the agent-turn callbacks through fromCallbacks":
  test "a turn streams its reply and ends":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let client = FakeAgentClient()
    let chat = newChat(client)
    chat.send("hello")
    check chat.connectionState.val == "streaming"
    check chat.inFlight
    discard scheduleAt(5, proc() = client.transports[0].onUpdate("Hi"))
    discard scheduleAt(10, proc() = client.transports[0].onEnd("end_turn"))
    ctx.step(10)
    check chat.messages.val == @["user: hello", "agent: Hi"]
    check chat.stopReason.val == "end_turn"
    check chat.connectionState.val == "completed"
    check not chat.inFlight
    check client.callbacks.onUpdate == nil   # the client's set is restored
    chat.disposeRoot()

  test "callbacks captured by a completed transport cannot change the newer turn":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let client = FakeAgentClient()
    let chat = newChat(client)
    chat.send("one")
    client.transports[0].onEnd("end_turn")
    chat.send("two")
    check chat.connectionState.val == "streaming"
    let messages = chat.messages.value
    discard scheduleAt(5, proc() = client.transports[0].fireAll("late"))
    ctx.step(5)
    check chat.messages.val == messages
    check chat.connectionState.val == "streaming"
    check chat.stopReason.val == "end_turn"
    check chat.inFlight
    client.transports[1].onEnd("end_turn")
    check not chat.inFlight
    chat.disposeRoot()

  test "a turn ended while its transport is still open cannot change the next turn":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let client = FakeAgentClient()
    let chat = newChat(client)
    chat.send("one")
    client.transports[0].onInterrupted("connection lost")
    check chat.connectionState.val == "interrupted"
    check chat.inFlight                       # still open
    chat.endTurn()
    check not chat.inFlight
    chat.send("two")
    let messages = chat.messages.value
    discard scheduleAt(5, proc() = client.transports[0].fireAll("late"))
    ctx.step(5)
    check chat.messages.val == messages
    check chat.connectionState.val == "streaming"
    check chat.stopReason.val == ""
    check chat.inFlight
    chat.disposeRoot()

  test "a closed chat hears nothing more":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let client = FakeAgentClient()
    let chat = newChat(client)
    chat.send("one")
    # Closing: the chat ends its turn and marks the client closed. No
    # callback reads `closed`.
    chat.endTurn()
    client.closed = true
    let messages = chat.messages.value
    discard scheduleAt(5, proc() = client.transports[0].fireAll("late"))
    ctx.step(5)
    check chat.messages.val == messages
    check chat.connectionState.val == "streaming"
    check chat.inputText.val == ""
    chat.disposeRoot()

  test "a disposed chat hears nothing more, and the client's set is restored":
    let ctx = newFakeAsyncContext()
    ctx.install()
    defer: ctx.uninstall()
    let client = FakeAgentClient()
    let chat = newChat(client)
    chat.send("one")
    check client.callbacks.onUpdate != nil
    chat.disposeRoot()
    check client.callbacks.onUpdate == nil
    let messages = chat.messages.value
    discard scheduleAt(5, proc() = client.transports[0].fireAll("late"))
    ctx.step(5)
    check chat.messages.value == messages
    check chat.connectionState.value == "streaming"
