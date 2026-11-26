## Simulated network conditions for injected services.
##
## How quickly a screen fills with data is a design property. It can be
## measured while the UI is still a prototype over stand-in services, as long
## as those stand-ins answer the way a real network would: after a round trip,
## and after the time the response's bytes take to arrive. This module
## supplies that, in one place, so no stand-in implements delays of its own:
##
## - `NetworkProfile` describes a connection: latency (one round trip),
##   downstream bandwidth, jitter and a failure rate. `NetworkPresets` names a
##   range of them, from an instant connection to a slow mobile one.
## - `NetworkSimulator.simulate` wraps one future-returning operation: the
##   response is delivered `latency + jitter + size / bandwidth` after the
##   operation produced it, or the request fails after one latency at the
##   profile's failure rate (and never reaches the service).
## - `NetworkSimulator.simulateStream` wraps a streamed operation: the first
##   chunk waits the latency, every later chunk its own transfer time behind
##   the previous one (and the latency too, if it was produced after the
##   previous one arrived), and order is preserved. Cancelling the wrapped
##   stream cancels the source.
##
## A service interface is wrapped by applying these to each of its
## operations — one wrapper per interface, written once, used for every
## stand-in parameterisation and every profile. Synchronous operations and
## signals pass through unchanged.
##
## Timing comes from nim-everywhere's clock, so a `FakeAsyncContext` makes it
## deterministic in tests, and jitter and failures come from a seeded RNG.

import std/random

import nim_everywhere/time

import ./deferred
import ./streams

export deferred, streams

type
  NetworkProfile* = object
    name*: string        ## Stable identifier (`"4g"`), used in URLs and reports.
    label*: string       ## What a selector shows (`"4G"`).
    latencyMs*: int      ## One round trip.
    downKbps*: int       ## Downstream bandwidth in kilobits per second; 0 = unlimited.
    jitterMs*: int       ## Extra delay drawn uniformly from `0 .. jitterMs` per response.
    failureRate*: float  ## Probability that a request fails, `0.0 .. 1.0`.

  NetworkSimulator* = ref object
    profile*: NetworkProfile
    rng: Rand

const
  InstantNetwork* = NetworkProfile(name: "instant", label: "Instant")
  WifiNetwork* = NetworkProfile(name: "wifi", label: "Wi-Fi",
    latencyMs: 20, downKbps: 30_000, jitterMs: 5)
  FourGNetwork* = NetworkProfile(name: "4g", label: "4G",
    latencyMs: 70, downKbps: 9_000, jitterMs: 20)
  Fast3GNetwork* = NetworkProfile(name: "fast-3g", label: "Fast 3G",
    latencyMs: 560, downKbps: 1_600, jitterMs: 40)
  Slow3GNetwork* = NetworkProfile(name: "slow-3g", label: "Slow 3G",
    latencyMs: 2_000, downKbps: 400, jitterMs: 100)

  NetworkPresets* = [InstantNetwork, WifiNetwork, FourGNetwork,
                     Fast3GNetwork, Slow3GNetwork]
    ## Ordered from fastest to slowest. The 3G figures follow the throttling
    ## presets of browser developer tools, so measurements here and there
    ## are comparable.

proc networkPreset*(name: string; found: var bool): NetworkProfile =
  ## The preset called `name`; `found` is false (and the result instant)
  ## when there is none.
  for p in NetworkPresets:
    if p.name == name:
      found = true
      return p
  found = false
  InstantNetwork

proc networkPreset*(name: string): NetworkProfile =
  ## The preset called `name`, or `ValueError`.
  var found = false
  result = networkPreset(name, found)
  if not found:
    raise newException(ValueError, "unknown network profile: " & name)

proc transferMs*(p: NetworkProfile; bytes: int): int =
  ## Milliseconds `bytes` take over the profile's bandwidth (rounded up).
  if p.downKbps <= 0 or bytes <= 0: return 0
  # kbps is kilobits per second, which is bits per millisecond.
  (bytes * 8 + p.downKbps - 1) div p.downKbps

proc newNetworkSimulator*(profile: NetworkProfile; seed: int64 = 1):
    NetworkSimulator =
  NetworkSimulator(profile: profile, rng: initRand(seed))

proc jitter(sim: NetworkSimulator): int =
  if sim.profile.jitterMs <= 0: 0
  else: sim.rng.rand(0 .. sim.profile.jitterMs)

proc failsNow(sim: NetworkSimulator): bool =
  if sim.profile.failureRate <= 0.0: false
  elif sim.profile.failureRate >= 1.0: true
  else: sim.rng.rand(1.0) < sim.profile.failureRate

proc failureMessage(sim: NetworkSimulator; opName: string): string =
  "network error: " & opName & " failed (simulated " &
    sim.profile.label & " connection)"

proc responseDelayMs*(sim: NetworkSimulator; bytes: int): int =
  ## The delay one response of `bytes` would see: latency, jitter, transfer.
  sim.profile.latencyMs + sim.jitter() + sim.profile.transferMs(bytes)

proc simulate*[T](sim: NetworkSimulator; opName: string;
                  op: proc(): PlatformFuture[T] {.closure.};
                  sizeOf: proc(value: T): int {.closure.}):
    PlatformFuture[T] =
  ## Run `op` behind the simulated connection. The result reaches the caller
  ## `latency + jitter + sizeOf(result) / bandwidth` after `op` produced it;
  ## an error from `op` arrives after one latency. At the failure rate, the
  ## request is lost: `op` is not called and the caller gets an error after
  ## one latency.
  let d = newDeferred[T]("network." & opName)
  let latency = sim.profile.latencyMs
  if sim.failsNow():
    let message = sim.failureMessage(opName)
    discard scheduleAt(latency, proc() = d.reject(message))
    return d.future
  proc onValue(value: T) =
    let delay = sim.responseDelayMs(sizeOf(value))
    discard scheduleAt(delay, proc() = d.resolve(value))
  proc onError(message: string) =
    discard scheduleAt(latency, proc() = d.reject(message))
  let produced = op()
  when defined(js):
    # On the JS backend an already-settled future (`newCompletedFuture`)
    # defers its callbacks to `drainPlatformCallbacks`, which nothing in a
    # browser page calls; read it directly instead.
    if isSyncResolved(produced):
      onValue(getSyncValue[T](produced))
      return d.future
    if isSyncFailed(produced):
      onError(getSyncError(produced))
      return d.future
  produced.onComplete(onValue, onError)
  d.future

type
  PendingDeliveryKind = enum
    pdChunk, pdDone, pdError

  PendingDelivery[T] = object
    atMs: int64
    case kind: PendingDeliveryKind
    of pdChunk: chunk: T
    of pdDone: discard
    of pdError: message: string

proc simulateStream*[T](sim: NetworkSimulator; opName: string;
                        source: ServiceStream[T];
                        sizeOf: proc(chunk: T): int {.closure.}):
    ServiceStream[T] =
  ## Deliver `source` through the simulated connection. Every event arrives
  ## one latency (plus the stream's jitter) after it was produced, plus its
  ## own transfer time, and never before the previous delivery: chunks
  ## produced in a burst arrive one transfer time apart after the first one's
  ## latency, and a chunk produced later still travels the latency. A slow
  ## connection therefore stretches a stream out and never reorders it. The
  ## end of the stream (done or error) follows the last chunk. At the failure
  ## rate, the stream fails after one latency without subscribing to
  ## `source`.
  result = proc(sink: StreamSink[T]): StreamSubscription =
    let outer = newStreamEmitter[T](sink)
    let latency = sim.profile.latencyMs
    if sim.failsNow():
      let message = sim.failureMessage(opName)
      let timer = scheduleAt(latency, proc() = outer.fail(message))
      outer.onCancel(proc() = cancelTimer(timer))
      return outer.subscription

    var queue: seq[PendingDelivery[T]]
    var timer: TimerHandle
    var lastAt = int64.low
    # One latency (with its jitter) for the whole stream, so a later chunk
    # can never overtake an earlier one.
    let delay = (latency + sim.jitter()).int64

    proc deliver(item: PendingDelivery[T]) =
      case item.kind
      of pdChunk: outer.emit(item.chunk)
      of pdDone: outer.finish()
      of pdError: outer.fail(item.message)

    proc pump() =
      if timer != nil or queue.len == 0 or not outer.isActive: return
      let wait = max(0'i64, queue[0].atMs - monotonicNowMs())
      timer = scheduleAt(wait.int, proc() =
        timer = nil
        if queue.len == 0: return
        # Move the item out of the queue before removing its slot, so the
        # local owns it. The obvious `let item = queue[0]` followed by
        # `queue.delete(0)` is miscompiled by Nim 2.2 under ARC and ORC:
        # cursor inference does not see that `queue`, a variable this
        # closure captures, is changed through the closure's environment,
        # so `item` becomes a borrowed view of the slot, the delete frees
        # the chunk, and the subscriber is handed freed memory. A move
        # does not depend on that inference.
        let item = move(queue[0])
        queue.delete(0)
        deliver(item)
        pump())

    proc enqueue(pending: PendingDelivery[T]; bytes: int) =
      var item = pending
      # Every event travels the latency; behind an earlier delivery it also
      # waits its turn, so a burst arrives one transfer time apart.
      let at = max(monotonicNowMs() + delay, lastAt) +
        sim.profile.transferMs(bytes).int64
      lastAt = at
      item.atMs = at
      queue.add item
      pump()

    let inner = source(StreamSink[T](
      onChunk: proc(chunk: T) =
        enqueue(PendingDelivery[T](kind: pdChunk, chunk: chunk), sizeOf(chunk)),
      onDone: proc() =
        enqueue(PendingDelivery[T](kind: pdDone), 0),
      onError: proc(message: string) =
        enqueue(PendingDelivery[T](kind: pdError, message: message), 0)))
    outer.onCancel(proc() =
      cancelTimer(timer)
      queue.setLen(0)
      inner.cancel())
    outer.subscription

proc textBytes*(s: string): int = s.len
  ## Size of a text chunk on the wire, for `simulateStream[string]`.
