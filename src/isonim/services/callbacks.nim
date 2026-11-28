## Services that answer through callbacks, adapted to async values.
##
## Many services do not return a future or a stream. They report through
## callbacks: a client object with `onUpdate`, `onEnd` and `onError` fields
## that the caller sets before each request, a callback passed to the call
## itself, or an event that does not say which request it answers. Wiring
## such a service into a ViewModel by hand means a check in every callback
## ("is this request still the one the ViewModel wants?"), because a
## callback can still fire after the request was replaced, finished, or the
## ViewModel was disposed.
##
## This module does that once. The author writes an `install` procedure that
## sets the callbacks for one request and starts it, and returns an
## `Uninstall` procedure that undoes the setup:
##
## .. code-block:: nim
##   vm.reply = createAsyncStream(
##     proc(): string = vm.prompt.val,                 # the question
##     proc(prompt: string): ServiceStream[string] =
##       fromCallbacks(proc(sink: Sink[string]): Uninstall =
##         let previous = client.callbacks             # one set per client
##         client.callbacks = ClientCallbacks(
##           onUpdate: sink.wrap(proc(text: cstring) = sink.emit($text)),
##           onEnd: sink.wrap(proc() = sink.finish()),
##           onError: sink.wrap(proc(message: cstring) = sink.fail($message)))
##         client.submit(prompt)
##         result = proc() = client.callbacks = previous))
##
## Each request is a *flight*. `install` runs when the flight starts. The
## flight stops being current when it is replaced (a new question, a
## refresh), when it settles (`finish`, `fail`, `answer`), or when its owner
## is disposed; at that moment, and only then, its `Uninstall` runs, exactly
## once. Every callback handed to the service goes through `wrap`, which
## drops any call made after the flight stopped being current, so the
## callbacks themselves contain no liveness test.
##
## Semantics:
##
## - *Exactly once.* `Uninstall` runs once per flight, whichever way the
##   flight stops, and never while `install` is still running: a flight that
##   settles or is replaced during `install` runs its `Uninstall` as soon as
##   `install` returns it.
## - *Before anyone hears the end.* When a flight settles, its `Uninstall`
##   runs before the value hears the answer or the end. Whatever the
##   ViewModel does on hearing it, including starting the next flight on
##   the same client, happens after the previous setup was undone.
## - *One set per client.* A service that keeps one set of callbacks per
##   client needs `Uninstall` to put back the set that was there before
##   `install` replaced it. Two flights in a row on one client then work:
##   the second installs over the restored set. An event that names no
##   request reaches the callbacks installed at the time it fires, which
##   belong to the only flight that is current, or to the restored set when
##   none is. Restoring is correct only if flights on a client stop in the
##   reverse order of their installs; an async value guarantees that by
##   stopping the old flight before it starts the new one.
## - *What `wrap` covers.* `wrap` takes a callback with no result and zero
##   to three parameters, and returns a callback of the same type. A
##   callback that must return a value to the service cannot be dropped
##   without inventing that value, so it is not wrapped; it can test
##   `isCurrent` itself.
## - *Errors.* `install` raising a `CatchableError` fails the question with
##   its message; whatever it set before raising is not undone, because no
##   `Uninstall` was returned. A `Defect` propagates. `Uninstall` must not
##   raise.
## - *Ignored, not stopped.* A callback service usually cannot be told to
##   stop: a dropped callback was still called, and work the service runs
##   for a replaced request continues unless `Uninstall` stops it.
##
## Two forms:
##
## - `fromCallbacks` makes a `ServiceStream`, for `createAsyncStream`: the
##   flight emits chunks, then finishes or fails.
## - `createAsyncFromCallback` makes an `AsyncValue[T]` from a service that
##   answers once, without wrapping the answer in a sequence of one chunk.
##   It is a constructor of its own rather than another form of
##   `createAsync`, so each constructor takes one kind of source. Its answer
##   travels through a platform future, so it shows one future step after
##   the callback delivers it (on JS a microtask, on C the next poll of the
##   dispatcher), as any future's answer does.
##
## Not imported by the reactive core, the renderers or the async value
## module: a page that does not use it carries none of its code. Not yet a
## stable API.

import std/options

import nim_everywhere/async_compat

import ./async_value
import ./deferred
import ./readiness
import ./streams

type
  Uninstall* = proc() {.closure.}
    ## Undoes what `install` set up for one flight (restores the previous
    ## callbacks, unsubscribes, stops the service's work when it can). Run
    ## exactly once, when the flight stops being current. May be nil when
    ## there is nothing to undo.

  Life = ref object
    ## Whether one flight is current, and its `Uninstall`. Shared by the
    ## sink and the wrapped callbacks; it holds no reference back to them,
    ## so no reference cycle forms under ARC.
    current: bool
    installing: bool
    uninstall: Uninstall

  Sink*[T] = ref object
    ## The producer's side of one flight of `fromCallbacks`: emit chunks,
    ## then finish or fail, and wrap every callback handed to the service.
    life: Life
    emitter: StreamEmitter[T]

  AnswerSink*[T] = ref object
    ## The producer's side of one flight of `createAsyncFromCallback`:
    ## answer once or fail, and wrap every callback handed to the service.
    life: Life
    deferred: Deferred[T]

  AnySink[T] = Sink[T] | AnswerSink[T]

proc release(life: Life) =
  ## Run the flight's `Uninstall` if it is known and has not run. Called
  ## when the flight stops, and again when `install` returns.
  if life.installing or life.uninstall == nil: return
  let undo = life.uninstall
  life.uninstall = nil
  undo()

proc stop(life: Life) =
  ## The flight stops being current: later wrapped calls are dropped, and
  ## its `Uninstall` runs (now, or when `install` returns it).
  if not life.current: return
  life.current = false
  life.release()

proc installed(life: Life; undo: Uninstall) =
  ## `install` has returned `undo`. A flight that stopped while `install`
  ## ran is undone at once.
  life.installing = false
  life.uninstall = undo
  if not life.current: life.release()

proc isCurrent*[T](s: AnySink[T]): bool =
  ## True while the flight is current: not replaced, not settled, and its
  ## owner not disposed. A wrapped callback runs only while this is true.
  s.life.current

proc wrap*[T](s: AnySink[T]; callback: proc() {.closure.}): proc() {.closure.} =
  ## `callback`, called only while the flight is current; a call made after
  ## the flight stopped does nothing.
  let life = s.life
  result = proc() =
    if life.current: callback()

proc wrap*[T, A](s: AnySink[T]; callback: proc(a: A) {.closure.}):
    proc(a: A) {.closure.} =
  ## `callback`, called only while the flight is current; a call made after
  ## the flight stopped does nothing.
  let life = s.life
  result = proc(a: A) =
    if life.current: callback(a)

proc wrap*[T, A, B](s: AnySink[T]; callback: proc(a: A; b: B) {.closure.}):
    proc(a: A; b: B) {.closure.} =
  ## `callback`, called only while the flight is current; a call made after
  ## the flight stopped does nothing.
  let life = s.life
  result = proc(a: A; b: B) =
    if life.current: callback(a, b)

proc wrap*[T, A, B, C](s: AnySink[T];
                       callback: proc(a: A; b: B; c: C) {.closure.}):
    proc(a: A; b: B; c: C) {.closure.} =
  ## `callback`, called only while the flight is current; a call made after
  ## the flight stopped does nothing.
  let life = s.life
  result = proc(a: A; b: B; c: C) =
    if life.current: callback(a, b, c)

proc emit*[T](s: Sink[T]; chunk: T) =
  ## Deliver one chunk. Ignored once the flight is not current.
  if s.life.current: s.emitter.emit(chunk)

proc finish*[T](s: Sink[T]) =
  ## End the flight successfully. Its `Uninstall` runs first, then the
  ## value hears the end. Ignored once the flight is not current.
  if not s.life.current: return
  s.life.stop()
  s.emitter.finish()

proc fail*[T](s: Sink[T]; message: string) =
  ## End the flight with an error. Its `Uninstall` runs first, then the
  ## value hears the error. Ignored once the flight is not current.
  if not s.life.current: return
  s.life.stop()
  s.emitter.fail(message)

proc answer*[T](s: AnswerSink[T]; value: T) =
  ## The flight's one answer. Its `Uninstall` runs first, then the answer
  ## is passed on. Ignored once the flight is not current, so a second
  ## answer is dropped.
  if not s.life.current: return
  s.life.stop()
  s.deferred.resolve(value)

proc fail*[T](s: AnswerSink[T]; message: string) =
  ## The flight fails with `message`. Its `Uninstall` runs first, then the
  ## failure is passed on. Ignored once the flight is not current.
  if not s.life.current: return
  s.life.stop()
  s.deferred.reject(message)

proc fromCallbacks*[T](install: proc(sink: Sink[T]): Uninstall {.closure.}):
    ServiceStream[T] =
  ## A stream over a callback service. Each subscription is one flight:
  ## `install` runs with a fresh `Sink`, sets the service's callbacks
  ## (each through `sink.wrap`), starts the request and returns its
  ## `Uninstall`. The flight stops when the subscriber cancels (an async
  ## value does so when the question is replaced or the value is disposed)
  ## or when the sink finishes or fails; its `Uninstall` then runs, exactly
  ## once (see the module documentation). `install` raising a
  ## `CatchableError` fails the stream with its message. Not yet a stable
  ## API.
  result = proc(subscriber: StreamSink[T]): StreamSubscription =
    let emitter = newStreamEmitter[T](subscriber)
    let life = Life(current: true, installing: true)
    let s = Sink[T](life: life, emitter: emitter)
    # Captures only `life`: the subscription holds this hook, and the sink
    # holds the subscription's emitter.
    emitter.onCancel(proc() = life.stop())
    var undo: Uninstall
    try:
      undo = install(s)
    except CatchableError as e:
      life.installed(nil)
      s.fail(e.msg)
      return emitter.subscription
    life.installed(undo)
    emitter.subscription

type Installation[S] = object
  ## A flight of `createAsyncFromCallback` that may still be current, with
  ## the question it was installed for.
  question: S
  life: Life

proc createAsyncFromCallback*[S, T](
    input: proc(): S;
    install: proc(question: S; sink: AnswerSink[T]): Uninstall {.closure.};
    placeholder = none(T);
    marks: ReadinessMarks = nil; element = "";
    known: proc(question: S): Option[T] = nil;
    onDone: proc(question: S; value: T) = nil): AsyncValue[T] =
  ## An async value over a service that answers once through a callback:
  ## `createAsync`, with `install` in place of a call that returns a
  ## future. For each question, `install` runs with the question and a
  ## fresh `AnswerSink`, sets the service's callbacks (each through
  ## `sink.wrap`), starts the request and returns its `Uninstall`; the
  ## callbacks end the flight with `sink.answer` or `sink.fail`. The flight
  ## stops when it settles, when the question is replaced or refreshed
  ## over, or when the value is disposed, and its `Uninstall` then runs,
  ## exactly once. `placeholder`, `marks`, `element`, `known` and `onDone`
  ## are as for `createAsync`. Not yet a stable API.
  ##
  ## The answer is shown one future step after `sink.answer` (on JS a
  ## microtask, on C the next poll of the dispatcher). `install` raising a
  ## `CatchableError` fails the question; a `Defect` propagates.
  # The flights that may still be current, oldest first. `createAsync`
  # names a flight to stop by its question only; the oldest current flight
  # for that question is the one it means, because it stops the old flight
  # before it starts the next one.
  var flights: seq[Installation[S]]

  proc prune() =
    var kept: seq[Installation[S]]
    for f in flights:
      if f.life.current: kept.add f
    flights = kept

  proc call(question: S): PlatformFuture[T] =
    prune()
    let d = newDeferred[T]("callback answer")
    let life = Life(current: true, installing: true)
    flights.add Installation[S](question: question, life: life)
    var undo: Uninstall
    try:
      undo = install(question, AnswerSink[T](life: life, deferred: d))
    except CatchableError:
      # The question fails (createAsync reports the message); nothing is
      # left to undo, and the flight must not be stopped again later.
      life.installed(nil)
      life.stop()
      prune()
      raise
    life.installed(undo)
    d.future

  proc cancel(question: S) =
    prune()
    for i in 0 ..< flights.len:
      if flights[i].question == question:
        let life = flights[i].life
        flights.delete(i)
        life.stop()
        return

  createAsync[S, T](input, call, placeholder, marks, element, cancel,
                    known, onDone)
