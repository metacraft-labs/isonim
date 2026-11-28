## Async values: a ViewModel's answers from injected services, as reactive
## state.
##
## A ViewModel asks its services questions whose answers arrive later: a
## `PlatformFuture` (one answer) or a `ServiceStream` (increments, then done).
## Wiring each answer into signals by hand means a phase enum, a counter to
## drop the answers of questions that were replaced, and a subscription
## field to cancel. An `AsyncValue` does that wiring once:
##
## .. code-block:: nim
##   # Inside the ViewModel's constructor (`withViewModel`):
##   vm.transcript = createAsync(
##     proc(): string = vm.selectedId.val,              # the question
##     proc(id: string): PlatformFuture[seq[Message]] = # the service call
##       services.loadTranscript(id))
##   # The View reads vm.transcript.val, .loading, .pending, .error.
##
## The question is `input`, a tracked function: whenever it yields a new
## value (compared with `==`), the primitive calls the service with it.
## When `input` returns an `Option`, `none` asks nothing: the value becomes
## `idle`, the flight in progress stops, and the next question is a first
## load again (`loading`, not `pending`). The answer, its status and its
## error are readable, tracked accessors:
##
## - `val` — what the View shows: the latest answer, held while the next
##   question is in flight; before the first answer the declared
##   `placeholder` (flagged by `provisional`), or `default(T)`. It is not
##   necessarily the answer to the current question: `ready` says when it
##   is.
## - `status` — one of `AsyncStatus`:
##   - `idle` — nothing is asked (the input is an `Option` and is `none`);
##   - `loading` — a question is in flight and there is no answer yet;
##   - `pending` — a new question is in flight, and the answer to an older
##     one is still shown;
##   - `ready` — the answer to the current question is shown (for a stream:
##     its chunks so far; `done` says whether more follow);
##   - `failed` — the current question failed; `error` says why.
##   `loading`, `pending` and `ready` are shorthands.
## - `done` — the current question's answer is shown and complete (a
##   future's answer always is; a stream's once it has finished). It is
##   false while `pending`: the answer shown then is an older question's.
## - `inFlight` — a call for the current question is running: true from the
##   propagation that asks the question until the call settles, whatever
##   the status (under `loading` and `pending`, and under `ready` during a
##   quiet refresh or while a stream is still delivering); false while
##   `idle`. It answers "is work running", which is a different question
##   from "what is shown": do not draw a spinner from `inFlight` alone,
##   because a quiet refresh runs a call while the answer stays `ready`.
##
## Semantics:
##
## - *Supersession.* A new question replaces the flight of the old one. A
##   stream is cancelled at the producer. A future cannot be cancelled, so
##   its answer is ignored when it arrives; when the service can stop the
##   work, pass `cancel`, which is called with the replaced question. No
##   answer to a replaced question ever reaches the value, so the ViewModel
##   keeps no counters of its own. `cancel` is never called for a call that
##   has already answered. Because a future cannot be cancelled, the work
##   behind a replaced call runs to its end unless `cancel` stops it at the
##   service: work that must stop is better served as a stream.
## - *Quiet refresh.* `refresh()` asks the current question again without
##   changing the status: the old answer stays shown, as `ready`, until the
##   new one replaces it. `refresh(pending = true)` shows the wait instead
##   (`pending`, or `loading` when there is no answer yet).
## - *Errors.* A failed question shows `failed` and its message; the last
##   answer stays the value. A new question, or a refresh, recovers. A
##   service call (or `known`) that raises a `CatchableError` fails the
##   question the same way. A failure is the value's state (and the settle
##   hook's `failed` outcome): it reaches no error handler and no error
##   boundary. A `Defect` raised by the call is
##   not a failure: it is a programming error and propagates.
## - *Placeholder.* An optional declared first value shown, flagged
##   `provisional`, while there is no answer. It is never reported as an
##   answer: it does not make the status `ready` and records no readiness
##   mark.
## - *Readiness marks.* With `marks` and `element`, the first real answer or
##   chunk records `<element>:first`, and a complete answer (a future's
##   answer, a stream's done) records `<element>`. Marks are recorded once
##   per load; starting a load (`beginLoad`) stays with the caller, because
##   one recorder usually covers several elements of a screen.
## - *Answers the ViewModel already has* (`known`). Before calling the
##   service for a new question, the primitive asks `known(question)`; an
##   answer it returns is shown at once, in the propagation that asked the
##   question, with no call and no `loading` frame. For example the first
##   conversation's transcript, which came with the first screen, or the
##   empty transcript of a conversation just created. `known` is consulted
##   only for a new question: a refresh always calls the service.
## - *Local writes* (`mutate`). The ViewModel can replace the value shown,
##   as when it appends the user's own message to a transcript at once. It
##   shows as the current question's answer (`ready`); a call in flight is
##   not stopped, and the next real answer replaces it (a stream's further
##   chunks are appended to it). The call is not stopped because its
##   answer, when it comes, is the truth. Nothing reverts a local write: it
##   is not an optimistic overlay, and not meant for a guess that must be
##   undone if an action fails. A write made in the batch that changes the
##   question belongs to the new question. `local` tells a value written so
##   from the service's answer: true from the write until an answer
##   replaces the value (for a stream, its next chunk) or the question
##   changes.
## - *Settling* (`onSettled`, `Outcome`). Called with the question and how
##   its call settled: `answered` with the whole answer (a future's answer,
##   a stream's chunks when it finishes, a `known` answer) or `failed` with
##   the message. Called once each time the current question is asked (a
##   new question, or a refresh), inside the batch that writes the outcome,
##   so what the ViewModel writes there (a reply joining a transcript, a
##   draft restored after a failure) shows in the same frame. Called only
##   for the current question of a live value: a call stopped because the
##   question changed, a refresh replaced it or the value ended settles
##   nothing, so the hook needs no check of its own that its answer is
##   still wanted. A local write settles nothing. `onDone` is the
##   `answered` case alone, called before `onSettled` when both are given.
##   A failure is the value's state and the hook's argument; it is never
##   raised. A hook that raises an ordinary error raises an error of the
##   reactive graph: it goes to the nearest error handler above the value
##   (`onError`), and with none it is raised to the code whose write or
##   batch settled the question, as for any computation. A `Defect` it
##   raises propagates.
## - *Asking again.* A question equal to the last one asks nothing; to ask
##   the same question again use `refresh`. An event that must always be
##   answered (a prompt sent twice) is a different question each time only
##   if it says what makes it different, such as the place in the
##   conversation it was sent at.
## - *Batches.* Inside a `batch`, the call for a new question starts when
##   the batch ends.
## - *Ownership.* The value lives in a reactive root created under the
##   current owner, so it ends with that owner: created in a ViewModel's
##   constructor (`withViewModel`), it ends with the ViewModel. Ending it
##   cancels the flight in progress (a stream at the producer), and an
##   answer that arrives later writes nothing. `dispose` ends it earlier.
##
## Why the status is derived rather than written: it is computed from the
## question and the answers in the same propagation as the question, so a
## reader that sees a new question always sees it `pending` or `loading`,
## never the old answer as `ready`.
##
## This module is not imported by the reactive core or the renderers: a
## page that does not use it carries none of its code. Not yet a stable
## API.
##
## Works on the C and JS backends; time comes from nim-everywhere, so tests
## drive it with `FakeAsyncContext`.

import std/options

import nim_everywhere/async_compat

import isonim/core/[signals, computation, owner, batch, graph]
import ./streams
import ./readiness

type
  AsyncStatus* {.pure.} = enum
    ## What an `AsyncValue` shows (see the module documentation): `idle`
    ## (nothing asked), `loading` (asked, no answer yet), `pending` (a new
    ## question asked, an older answer shown), `ready` (the current
    ## question's answer shown) or `failed` (the current question failed).
    idle, loading, pending, ready, failed

  OutcomeKind* {.pure.} = enum
    ## How a call settled: `answered` (it gave its whole answer), `failed`
    ## (it failed, or the service could not be called), `interrupted` or
    ## `refused`. An `AsyncValue` settles only as `answered` or `failed`:
    ## a call it stops because the question changed, a refresh replaced it
    ## or the value ended settles nothing. `interrupted` and `refused` are
    ## for work that runs under a policy for being asked again while busy.
    answered, failed, interrupted, refused

  Outcome*[T] = object
    ## How one call settled, given to the settle hook (`onSettled`).
    case kind*: OutcomeKind
      ## Which way it settled.
    of OutcomeKind.answered:
      value*: T
        ## The whole answer: a future's answer, a stream's chunks when it
        ## finished, or a known answer.
    of OutcomeKind.failed:
      error*: string
        ## Why it failed: the service's message, or the message of the
        ## error the call raised.
    of OutcomeKind.interrupted, OutcomeKind.refused:
      discard

  SettleHook[S, T] = proc(question: S; outcome: Outcome[T])

  Ask = object
    ## The current question, by number. `serial` grows with every new
    ## question; `epoch` is the serial of the first question since nothing
    ## was asked (an answer from before it is not shown).
    serial: int
    epoch: int
    idle: bool

  Arrival = object
    ## What has arrived, by question number (0: nothing yet).
    settled: int      ## The question whose answer or error is shown.
    answered: int     ## The question whose answer `answer` holds.
    failed: bool      ## `settled` failed with `error`.
    error: string
    done: bool        ## `answer` is complete.
    local: bool       ## `answer` was written by `mutate`, not by an answer.
    refreshing: bool  ## A refresh that shows the wait is in flight.
    closed: int       ## The question whose call has settled (answered
                      ## whole or failed) with no call asked since.

  Flight = ref object
    ## One call of the service. Its callbacks write only while it is live:
    ## replacing, finishing or disposing it ends that.
    serial: int
    live: bool
    chunked: bool     ## A stream flight has delivered a chunk.
    subscription: StreamSubscription
    cancelHook: proc() {.closure.}

  AsyncValue*[T] = ref object
    ## A service's answer to a reactive question (see the module
    ## documentation). Its accessors are tracked reads, each a separate
    ## dependency, so a View that reads only `status` re-runs only when the
    ## status changes. Not yet a stable API.
    answer: Signal[T]
    outcome: Signal[Arrival]
    ask: Memo[Ask]
    statusMemo: Memo[AsyncStatus]
    shown: Memo[bool]
    doneMemo: Memo[bool]
    inFlightMemo: Memo[bool]
    errorMemo: Memo[string]
    placeholder: Option[T]
    marks: ReadinessMarks
    element: string
    current: Flight
    restart: proc(pending: bool) {.closure.}
    disposeRoot: proc() {.closure.}
    disposed: bool
    source: ComputationBase
      ## The value's own computation: a settle hook's error is reported as
      ## its error, so it reaches the handlers above the value.

proc never[T](a, b: T): bool = false

proc stop(f: Flight) =
  ## End `f`: its callbacks write nothing more, a stream is cancelled at the
  ## producer and a future's cancel hook asks the service to stop.
  if f == nil or not f.live: return
  f.live = false
  if f.subscription != nil: f.subscription.cancel()
  if f.cancelHook != nil:
    let hook = f.cancelHook
    f.cancelHook = nil
    hook()

proc finish(f: Flight) =
  ## `f` has delivered its last event: nothing is left to cancel.
  f.live = false
  f.cancelHook = nil

proc mark[T](av: AsyncValue[T]; complete: bool) =
  if av.marks == nil or av.element.len == 0: return
  if complete: av.marks.markComplete(av.element)
  else: av.marks.markFirst(av.element)

proc settleAnswer[T](av: AsyncValue[T]; f: Flight; value: T; done: bool;
                     keepValue = false; after: proc() = nil) =
  ## `value` is the (new) answer to `f`'s question; with `keepValue` the
  ## answer held is already it (a stream that finishes after its chunks).
  ## `after` (the completion hook) runs in the same batch, so what it
  ## writes shows in the same frame as the answer. An answer that writes
  ## the value replaces a local write; one that keeps it (a stream that
  ## finishes with no chunk since a local write) leaves it local.
  var o = av.outcome.value
  if not keepValue: o.local = false
  o.settled = f.serial
  o.answered = f.serial
  o.failed = false
  o.error = ""
  o.done = done
  o.refreshing = false
  if done: o.closed = f.serial
  batch proc() =
    if not keepValue: av.answer.val = value
    av.outcome.val = o
    av.mark(done)
    if after != nil: after()

proc runHook[S, T](av: AsyncValue[T]; hook: SettleHook[S, T]; question: S;
                   outcome: Outcome[T]) =
  ## Run the settle hook. An ordinary error it raises is an error of the
  ## graph, reported as the error of the value's own computation: it goes to the
  ## nearest handler above the value (with none, it is raised, as for any
  ## computation). A `Defect` is not caught.
  try:
    hook(question, outcome)
  except CatchableError as e:
    if av.source != nil: handleError(av.source, e)
    else: raise e

proc answeredHook[S, T](av: AsyncValue[T]; hook: SettleHook[S, T];
                        question: S; value: T): proc() =
  ## The settle hook for one answer, or nil. Captures the value, the hook
  ## and what it passes on, not the flight (which would be a cycle under
  ## ARC); nothing stores it beyond the batch that runs it.
  if hook == nil: return nil
  result = proc() =
    av.runHook(hook, question, Outcome[T](kind: OutcomeKind.answered,
                                          value: value))

proc failedHook[S, T](av: AsyncValue[T]; hook: SettleHook[S, T];
                      question: S; message: string): proc() =
  ## The settle hook for one failure, or nil.
  if hook == nil: return nil
  result = proc() =
    av.runHook(hook, question, Outcome[T](kind: OutcomeKind.failed,
                                          error: message))

proc settleHookOf[S, T](onDone: proc(question: S; value: T);
                        onSettled: SettleHook[S, T]): SettleHook[S, T] =
  ## One hook for both parameters: `onDone` is the answered case, called
  ## first.
  if onDone == nil: return onSettled
  result = proc(question: S; outcome: Outcome[T]) =
    if outcome.kind == OutcomeKind.answered: onDone(question, outcome.value)
    if onSettled != nil: onSettled(question, outcome)

proc settleError[T](av: AsyncValue[T]; f: Flight; message: string;
                    after: proc() = nil) =
  ## `f`'s question failed with `message`; the held answer stays. `after`
  ## (the settle hook) runs in the same batch.
  if not f.live: return
  f.finish()
  var o = av.outcome.value
  o.settled = f.serial
  o.failed = true
  o.error = message
  o.refreshing = false
  o.closed = f.serial
  batch proc() =
    av.outcome.val = o
    if after != nil: after()

proc isNoQuestion[S](question: S): bool =
  when S is Option: question.isNone
  else: false

proc newAsyncValue[S, T](input: proc(): S; placeholder: Option[T];
                         marks: ReadinessMarks; element: string;
                         known: proc(question: S): Option[T];
                         hook: SettleHook[S, T];
                         launch: proc(av: AsyncValue[T]; question: S;
                                      f: Flight) {.closure.}): AsyncValue[T] =
  ## The machinery shared by futures and streams; `launch` calls the
  ## service for one question.
  let av = AsyncValue[T](placeholder: placeholder, marks: marks,
                         element: element)
  # Answers are written only when they arrive, so no comparison is needed
  # (and `T` need not have one).
  av.answer = createSignal(default(T), never[T])
  av.outcome = createSignal(Arrival())
  var question: S
  var serial = 0
  var epoch = 0
  var asked = false

  proc start(a: Ask; pending: bool; fresh: bool) =
    ## Replace the flight in progress with a call for the current question
    ## (`fresh`: a new question, which `known` may answer at once).
    let previous = av.current
    av.current = nil
    previous.stop()
    if a.idle or av.disposed: return
    if not fresh:
      # The question is asked again: in flight until this call settles.
      var o = av.outcome.value
      o.closed = 0
      if pending: o.refreshing = true
      av.outcome.val = o
    let f = Flight(serial: a.serial, live: true)
    av.current = f
    if fresh and known != nil:
      var answer: Option[T]
      try:
        answer = known(question)
      except CatchableError as e:
        av.settleError(f, e.msg, av.failedHook(hook, question, e.msg))
        return
      if answer.isSome:
        # Shown in this propagation: no call, no loading frame.
        f.finish()
        av.settleAnswer(f, answer.get, done = true,
                        after = av.answeredHook(hook, question, answer.get))
        return
    launch(av, question, f)

  createRoot proc(dispose: proc()) =
    av.disposeRoot = dispose
    av.ask = createMemo(proc(): Ask =
      # A new question is numbered here, in the propagation that changed
      # the input, so the status below sees it at once.
      let q = input()
      if isNoQuestion(q):
        asked = false
        return Ask(serial: serial, epoch: epoch, idle: true)
      if not asked or q != question:
        inc serial
        if not asked: epoch = serial
        asked = true
        question = q
      Ask(serial: serial, epoch: epoch))
    av.statusMemo = createMemo(proc(): AsyncStatus =
      let a = av.ask.val
      let o = av.outcome.val
      if a.idle: AsyncStatus.idle
      elif o.settled == a.serial and not o.refreshing:
        (if o.failed: AsyncStatus.failed else: AsyncStatus.ready)
      elif o.answered >= a.epoch and o.answered > 0: AsyncStatus.pending
      else: AsyncStatus.loading)
    av.shown = createMemo(proc(): bool =
      let a = av.ask.val
      let o = av.outcome.val
      not a.idle and o.answered > 0 and o.answered >= a.epoch)
    # Separate memos, so a View that reads only one of these re-runs only
    # when it changes.
    av.doneMemo = createMemo(proc(): bool =
      # The current question's answer, complete: never while pending.
      av.statusMemo.val == AsyncStatus.ready and av.outcome.val.done)
    av.errorMemo = createMemo(proc(): string =
      if av.statusMemo.val == AsyncStatus.failed: av.outcome.val.error
      else: "")
    av.inFlightMemo = createMemo(proc(): bool =
      # The call has settled when its question is the one last closed.
      let a = av.ask.val
      not a.idle and av.outcome.val.closed != a.serial)
    av.restart = proc(pending: bool) =
      start(untrack(proc(): Ask = av.ask.val), pending, false)
    # The value's own computation, which starts the call for each new
    # question. It is pure, so in a flush it runs with the memos, before
    # any effect: an answer it writes at once (a known answer, a service
    # that answers while it is called) is in place before a View's effect
    # reads the value, whatever order the effects were queued in. As an
    # effect, it ran before or after the View's effect depending on the
    # order in which the value's memos last subscribed to the question, so
    # a View could see a frame of the new question `pending` before its
    # known answer.
    createComputed proc() =
      if av.source == nil: av.source = ComputationBase(getOwner())
      let a = av.ask.val
      untrack(proc() = start(a, false, true))
    onCleanup proc() =
      # The owner (or `dispose`) ends the value: the flight in progress
      # stops and nothing it started writes or settles afterwards.
      av.disposed = true
      av.source = nil
      let f = av.current
      av.current = nil
      f.stop()
  av

proc cancelHookFor[S](cancel: proc(question: S); question: S): proc() =
  ## A hook that captures only `cancel` and `question`, not the flight it
  ## is stored on (which would be a reference cycle under ARC).
  result = proc() = cancel(question)

proc createAsync*[S, T](input: proc(): S;
                        call: proc(question: S): PlatformFuture[T];
                        placeholder = none(T);
                        marks: ReadinessMarks = nil; element = "";
                        cancel: proc(question: S) = nil;
                        known: proc(question: S): Option[T] = nil;
                        onDone: proc(question: S; value: T) = nil;
                        onSettled: proc(question: S;
                                        outcome: Outcome[T]) = nil):
    AsyncValue[T] =
  ## The answer of `call` to the question `input` yields, asked again
  ## whenever the question changes (see the module documentation).
  ## `placeholder` is shown, flagged `provisional`, until the first answer;
  ## `marks` and `element` record readiness marks; `cancel`, when the
  ## service can stop a call, is called with a question whose answer is no
  ## longer wanted (replaced, refreshed over or disposed). When `input`
  ## returns an `Option`, `none` asks nothing and `call` receives the
  ## `some` value wrapped as it is. `known` answers a new question at once
  ## when it returns a value (no call); `onSettled` is called when the call
  ## for the current question settles (`answered` or `failed`), in the
  ## batch that writes the outcome, and `onDone` when it is answered. Not
  ## yet a stable API.
  ##
  ## A question equal (`==`) to the last one asks nothing; `refresh` asks
  ## it again. `cancel` is never called for a call that has answered. A
  ## future cannot be cancelled, so without `cancel` the work behind a
  ## replaced call runs to its end; for work that must stop, answer with a
  ## stream (`createAsyncStream`). `call` raising a `CatchableError`, or
  ## returning nil, fails the question; a `Defect` propagates.
  let hook = settleHookOf(onDone, onSettled)
  newAsyncValue[S, T](input, placeholder, marks, element, known, hook,
    proc(av: AsyncValue[T]; question: S; f: Flight) =
      var future: PlatformFuture[T]
      try:
        future = call(question)
      except CatchableError as e:
        av.settleError(f, e.msg, av.failedHook(hook, question, e.msg))
        return
      if future.isNil:
        const message = "the service returned no future"
        av.settleError(f, message, av.failedHook(hook, question, message))
        return
      if cancel != nil:
        if not f.live:
          # Replaced while calling (a call that changes the question): the
          # call was made and is no longer wanted.
          cancel(question)
        else:
          f.cancelHook = cancelHookFor(cancel, question)
      # Subscribed even when replaced (the callbacks then write nothing),
      # so a failure of the unwanted call is still observed and is not an
      # unhandled rejection on the JS backend.
      future.onComplete(
        proc(value: T) =
          if not f.live: return
          f.finish()
          av.settleAnswer(f, value, done = true,
                          after = av.answeredHook(hook, question, value)),
        proc(message: string) =
          if not f.live: return
          av.settleError(f, message, av.failedHook(hook, question, message))))

proc createAsyncStream*[S, C](input: proc(): S;
                              call: proc(question: S): ServiceStream[C];
                              placeholder = none(seq[C]);
                              marks: ReadinessMarks = nil; element = "";
                              known: proc(question: S): Option[seq[C]] = nil;
                              onDone: proc(question: S; chunks: seq[C]) = nil;
                              onSettled: proc(question: S;
                                  outcome: Outcome[seq[C]]) = nil):
    AsyncValue[seq[C]] =
  ## The chunks of the stream `call` answers the question `input` yields
  ## with, re-subscribed whenever the question changes; the old stream is
  ## cancelled at the producer. The value is the chunks so far, in order;
  ## the previous question's chunks stay shown (`pending`) until the new
  ## stream's first chunk replaces them. `done` is set once the stream
  ## finishes. A stream that fails keeps its chunks so far and shows
  ## `failed`. `known` answers a new question at once with chunks the
  ## ViewModel already has (a finished stream, no call); `onSettled` is
  ## called once when the stream finishes (`answered` with the chunks) or
  ## breaks off (`failed`), never per chunk, in the batch that writes it,
  ## and `onDone` when it finishes. Not yet a stable API.
  ##
  ## A replaced, refreshed-over or disposed stream is cancelled at the
  ## producer, so its work stops. The value is copied on each chunk.
  let hook = settleHookOf(onDone, onSettled)
  newAsyncValue[S, seq[C]](input, placeholder, marks, element, known, hook,
    proc(av: AsyncValue[seq[C]]; question: S; f: Flight) =
      var stream: ServiceStream[C]
      try:
        stream = call(question)
      except CatchableError as e:
        av.settleError(f, e.msg, av.failedHook(hook, question, e.msg))
        return
      if stream.isNil:
        const message = "the service returned no stream"
        av.settleError(f, message, av.failedHook(hook, question, message))
        return
      let subscription = stream(StreamSink[C](
        onChunk: proc(chunk: C) =
          if not f.live: return
          var chunks: seq[C]
          if f.chunked: chunks = av.answer.value
          f.chunked = true
          chunks.add chunk
          av.settleAnswer(f, chunks, done = false),
        onDone: proc() =
          if not f.live: return
          f.finish()
          # Nothing to add: the chunks shown are the answer (or, when none
          # came, an empty one).
          let chunks = if f.chunked: av.answer.value else: newSeq[C]()
          av.settleAnswer(f, chunks, done = true, keepValue = f.chunked,
                          after = av.answeredHook(hook, question, chunks)),
        onError: proc(message: string) =
          if not f.live: return
          av.settleError(f, message, av.failedHook(hook, question, message))))
      f.subscription = subscription
      # Replaced while subscribing (a producer that calls back into the
      # ViewModel): the subscription is not wanted. A finished one ignores
      # the cancel.
      if not f.live: subscription.cancel())

proc status*[T](av: AsyncValue[T]): AsyncStatus =
  ## What `av` shows now (tracked; see `AsyncStatus`). Derived in the same
  ## propagation as the question, so a new question is never reported with
  ## the old answer as `ready`.
  av.statusMemo.val

proc loading*[T](av: AsyncValue[T]): bool =
  ## A question is in flight and there is no answer yet (tracked).
  av.status == AsyncStatus.loading

proc pending*[T](av: AsyncValue[T]): bool =
  ## A new question is in flight; an older answer is shown (tracked).
  av.status == AsyncStatus.pending

proc ready*[T](av: AsyncValue[T]): bool =
  ## The answer to the current question is shown (tracked).
  av.status == AsyncStatus.ready

proc error*[T](av: AsyncValue[T]): string =
  ## Why the current question failed, or "" (tracked).
  av.errorMemo.val

proc val*[T](av: AsyncValue[T]): T =
  ## What the View shows (tracked): the latest answer, else the
  ## placeholder while a question is asked, else `default(T)`. The latest
  ## answer is not necessarily the current question's (`pending` shows the
  ## previous one, `failed` keeps it); `ready` says when it is. A replaced
  ## question's late answer never shows here.
  if av.shown.val: av.answer.val
  elif av.placeholder.isSome and not av.ask.val.idle: av.placeholder.get
  else: default(T)

proc value*[T](av: AsyncValue[T]): T =
  ## `val`, untracked.
  untrack(proc(): T = av.val)

proc provisional*[T](av: AsyncValue[T]): bool =
  ## The value shown is the declared placeholder, not an answer (tracked).
  av.placeholder.isSome and not av.shown.val and not av.ask.val.idle

proc local*[T](av: AsyncValue[T]): bool =
  ## The value shown was written by `mutate`, not answered by the service
  ## (tracked): true from the write until an answer replaces the value (a
  ## future's answer, a stream's next chunk, a `known` answer) or the
  ## question changes. A failure after the write leaves it true, because
  ## the value stays shown. Not yet a stable API.
  ##
  ## Always false while `idle` and when nothing was written. A refresh
  ## leaves it true until the refresh's answer arrives; a stream that only
  ## finishes after the write (no chunk since) leaves it true, with `done`.
  # Local only for the question it was written for: a new question's
  # number is past it, so the flag drops in the propagation that asks.
  let a = av.ask.val
  let o = av.outcome.val
  not a.idle and o.local and o.answered == a.serial

proc done*[T](av: AsyncValue[T]): bool =
  ## The current question's answer is shown and complete (tracked): a
  ## future's answer, a stream that has finished, a known answer, or a
  ## local write that no stream is continuing. Never true while `pending`,
  ## `loading`, `failed` or `idle`, so it can be read as "the current
  ## question is loaded". A quiet refresh leaves it true: the answer shown
  ## is still the current question's, complete, while it is asked again
  ## (`inFlight` tells that a call is running). For a stream, `ready` with
  ## `done` false means chunks are still arriving. Not yet a stable API.
  av.doneMemo.val

proc inFlight*[T](av: AsyncValue[T]): bool =
  ## A call for the current question is running (tracked): true from the
  ## propagation that asks the question (or `refresh` asks it again) until
  ## that call settles, by its whole answer or a failure, whatever the
  ## status. So it is true while `loading` and `pending`, and while
  ## `ready` during a quiet refresh or while a stream is still delivering;
  ## false while `idle`, after `failed`, and after a known answer. A local
  ## write does not change it. Not yet a stable API.
  ##
  ## It is a different question from what is shown (`status`, `val`): a
  ## quiet refresh runs a call while the answer stays `ready`, so do not
  ## draw a spinner from `inFlight` alone.
  av.inFlightMemo.val

proc refresh*[T](av: AsyncValue[T]; pending = false) =
  ## Ask the current question again, replacing the flight in progress.
  ## Quiet by default: the status does not change until the answer
  ## arrives. With `pending`, the wait shows (`pending`, or `loading` with
  ## no answer yet). Does nothing when nothing is asked or after dispose.
  ## This is how to ask an equal question again; `known` is not consulted,
  ## and the replaced flight's late answer never shows.
  if av.disposed: return
  av.restart(pending)

proc mutate*[T](av: AsyncValue[T]; value: T) =
  ## A local write: show `value` as the answer to the current question
  ## (`ready`, no error), for example a transcript with the user's own
  ## message appended at once. A call in flight is not stopped: a future's
  ## answer replaces `value` when it arrives, and a stream's further chunks
  ## are appended to it. Records no readiness mark and settles nothing
  ## (no `onSettled` or `onDone` call). Not an optimistic overlay: nothing
  ## reverts it; `local` is true until an answer replaces it. Does nothing
  ## when nothing is asked or after dispose. Not yet a stable API.
  ##
  ## Why a late answer is not cancelled: when it comes, it is the truth.
  ## So a local write cannot hold the reply of a write against a read that
  ## is still in flight (the read's answer replaces it); withdraw or change
  ## the question instead. A write made in the batch that changes the input
  ## belongs to the new question: it is that question's complete answer
  ## (`done`) until the new call answers over it. The value is replaced
  ## whole, so the caller builds it (the shown transcript plus one message,
  ## say); on a stream still delivering, it must be a value the stream's
  ## next chunks can extend.
  if av.disposed: return
  let a = untrack(proc(): Ask = av.ask.val)
  if a.idle: return
  let f = av.current
  # A stream still delivering continues from the local value. A flight for
  # an older question (the input changed in this batch, and the computation
  # that replaces the flight has not run yet) is about to stop: the local value
  # is then complete, and the new question's call answers over it.
  let streaming = f != nil and f.live and f.subscription != nil and
    f.serial == a.serial
  if streaming: f.chunked = true
  var o = av.outcome.value
  o.settled = a.serial
  o.answered = a.serial
  o.failed = false
  o.error = ""
  o.done = not streaming
  o.refreshing = false
  o.local = true
  batch proc() =
    av.answer.val = value
    av.outcome.val = o

proc isDisposed*[T](av: AsyncValue[T]): bool = av.disposed
  ## True once `av` has ended, by `dispose` or with its owner.

proc dispose*[T](av: AsyncValue[T]) =
  ## End `av` before its owner does: the flight in progress stops (a
  ## stream at the producer; `cancel` is asked to stop a future's call) and
  ## no later answer is written. Calling it again does nothing.
  if av.disposeRoot != nil:
    # Call, then clear (a local copy could be freed by the clear first
    # under ARC/ORC).
    av.disposeRoot()
    av.disposeRoot = nil
