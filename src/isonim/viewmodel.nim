## isonim/viewmodel.nim
##
## ViewModel base pattern: reactive stores with typed state enums,
## service injection for mockable dependencies, and helpers for
## creating ViewModels within reactive roots.
##
## A ViewModel's async work ends with it: the stream subscriptions it
## registers with `track` are cancelled when it is disposed, and the
## callbacks of a future it registers with `own` are ignored once it is
## disposed, so nothing it started writes to it afterwards. `track` and
## `own` are not yet a stable API.
##
## Works on both C and JS backends.

import isonim/core/owner
import isonim/services/streams
import nim_everywhere/async_compat

type
  AsyncState* = enum
    ## Generic async operation state.
    asIdle       ## No operation in progress
    asLoading    ## Operation in progress
    asReady      ## Operation completed successfully
    asError      ## Operation failed

  ViewModel* = ref object of RootObj
    ## Base ViewModel: holds a reactive root dispose proc, and the async
    ## work registered with it (`track`, `own`).
    disposeProc*: proc()
    disposed: bool
    tracked: TrackedStreams
      ## Nil until the first `track`. A ref rather than a seq field so that
      ## a ViewModel object built before this field existed (a browser hot
      ## reload keeps live objects) reads as "nothing tracked".

  TrackedStreams = ref object
    live: seq[StreamSubscription]
      ## Registered with `track` and not yet known to have ended.

proc isDisposed*(vm: ViewModel): bool =
  ## True once `vm` has been disposed, by `dispose` or with the root it was
  ## created in (`withViewModel`).
  vm.disposed

proc release(vm: ViewModel) =
  ## Marks `vm` disposed and cancels every stream it tracks. Runs once.
  if vm.disposed: return
  vm.disposed = true
  let tracked = vm.tracked
  if tracked == nil: return
  # Detached first: a producer's cancel hook that calls back into `vm`
  # (`track`) finds it disposed and does not touch this list.
  vm.tracked = nil
  for s in tracked.live: s.cancel()

proc dispose*(vm: ViewModel) =
  ## Disposes the reactive root owned by this ViewModel, cancels the
  ## streams it tracks and makes it ignore the futures it owns. Calling it
  ## again does nothing.
  if vm.disposeProc != nil:
    # Call, then clear: a local copy of the closure would be a cursor
    # under ARC/ORC and could be freed by the clear before the call.
    vm.disposeProc()
    vm.disposeProc = nil
  vm.release()

proc track*(vm: ViewModel; subscription: StreamSubscription):
    StreamSubscription {.discardable.} =
  ## Registers a stream subscription `vm` started: disposing `vm` cancels
  ## it, which reaches the producer. Returns `subscription`. On a disposed
  ## `vm` the subscription is cancelled at once. (Not yet a stable API.)
  result = subscription
  if subscription.isNil: return
  if vm.disposed:
    subscription.cancel()
    return
  if vm.tracked == nil: vm.tracked = TrackedStreams()
  # Forget the subscriptions that have ended, so a long-lived ViewModel
  # that starts many streams keeps only the live ones.
  let tracked = vm.tracked
  var i = 0
  while i < tracked.live.len:
    if tracked.live[i].isActive: inc i
    else: tracked.live.del(i)
  tracked.live.add subscription

proc own*[T](vm: ViewModel; future: PlatformFuture[T];
             onSuccess: proc(value: T);
             onError: proc(message: string) = nil) =
  ## `future.onComplete(onSuccess, onError)` for a future `vm` started,
  ## except that neither callback runs once `vm` is disposed: an answer
  ## that arrives after dispose writes nothing. A future cannot be
  ## cancelled from here; a service that can stop the work should answer
  ## with a stream instead. (Not yet a stable API.)
  future.onComplete(
    proc(value: T) =
      if not vm.disposed: onSuccess(value),
    proc(message: string) =
      if not vm.disposed and onError != nil: onError(message))

proc withViewModel*[T: ViewModel](create: proc(dispose: proc()): T): T =
  ## Creates a ViewModel inside a reactive root. The root's dispose
  ## proc is stored on the ViewModel for later cleanup. Created under an
  ## owner, the root is one of its children (see `createRoot`), so the
  ## ViewModel is disposed with that owner too, its streams cancelled.
  var vm: T
  createRoot proc(dispose: proc()) =
    vm = create(dispose)
    vm.disposeProc = dispose
    let base = ViewModel(vm)
    onCleanup proc() = base.release()
  result = vm
