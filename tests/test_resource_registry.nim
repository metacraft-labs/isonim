## Resource registration with the owner.
##
## Every `createResource` / `createDeferredResource` overload registers its
## state signal with the owner that is current when it is created, and
## `ownedResourceStates(root)` enumerates the live resources created under a
## root — at top level and inside computations it owns, at any depth — so
## code holding the root can inspect them before disposing it, whether or
## not anything ever read them.
##
## Nested roots do not count: a `createRoot` inside another root is not
## owned by it (disposing the outer root does not dispose it), so its
## resources are enumerated from the nested root, not the outer one.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## None. The async overloads run against real platform futures; a future
## that is never completed is how a real pending fetch looks at the moment
## the enumeration runs.

import std/unittest
import nim_everywhere/async_compat
import isonim/core/[graph, signals, computation, owner, resource]

proc neverCompletes[T](): PlatformFuture[T] =
  ## A real platform future that nothing ever completes: the resource
  ## fetching it stays pending.
  when defined(js):
    newPromise proc(resolve: proc(value: T)) = discard
  else:
    newFuture[T]("test-resource-registry never completes")

proc states(root: OwnerBase): seq[ResourceState] =
  for s in ownedResourceStates(root):
    result.add s.value

suite "resource registration with the owner":

  test "every overload created at the top of a root is enumerated":
    createRoot do (dispose: proc()):
      let root = getOwner()
      let src = createSignal(1)
      let syncR = createResource(proc(): int = 7)
      let syncSrc = createResource(proc(): int = src.val,
                                   proc(s: int): int = s * 2)
      let deferred = createDeferredResource[int]()
      let asyncR = createResource(
        proc(info: ResourceFetcherInfo[int]): PlatformFuture[int] =
          neverCompletes[int]())
      let asyncSrc = createResource(proc(): int = src.val,
        proc(s: int; info: ResourceFetcherInfo[int]): PlatformFuture[int] =
          neverCompletes[int]())
      let found = ownedResourceStates(root)
      check found.len == 5
      if found.len == 5:
        # Identity, in creation order: the enumeration hands back the
        # resources' own state signals, not copies.
        check found[0] == syncR.state
        check found[1] == syncSrc.state
        check found[2] == deferred.resource.state
        check found[3] == asyncR.state
        check found[4] == asyncSrc.state
      check states(root) == @[rsReady, rsReady, rsPending, rsPending,
                              rsPending]
      # The state is live: resolving the deferred resource shows up.
      deferred.resolve(3)
      check states(root)[2] == rsReady
      dispose()
      # Disposal clears the record.
      check ownedResourceStates(root).len == 0

  test "a resource whose state is never read is still enumerated":
    createRoot do (dispose: proc()):
      let root = getOwner()
      let r = createResource(
        proc(info: ResourceFetcherInfo[string]): PlatformFuture[string] =
          neverCompletes[string](), initialValue = "Loading…")
      discard r.data.val   # only the data is read, never the state
      check states(root) == @[rsPending]
      dispose()

  test "resources created inside nested computations are enumerated":
    createRoot do (dispose: proc()):
      let root = getOwner()
      var inner: DeferredResource[int]
      var innermost: DeferredResource[int]
      createEffect proc() =
        inner = createDeferredResource[int]()
        discard createMemo(proc(): int =
          innermost = createDeferredResource[int]()
          1)
      let found = ownedResourceStates(root)
      check found.len == 2
      if found.len == 2:
        check found[0] == inner.resource.state
        check found[1] == innermost.resource.state
      dispose()

  test "a re-running computation drops the resources of its previous run":
    createRoot do (dispose: proc()):
      let root = getOwner()
      let trigger = createSignal(0)
      var latest: DeferredResource[int]
      var runs = 0
      createEffect proc() =
        discard trigger.val
        inc runs
        latest = createDeferredResource[int]()
      trigger.val = 1
      trigger.val = 2
      check runs == 3
      let found = ownedResourceStates(root)
      check found.len == 1
      if found.len == 1:
        check found[0] == latest.resource.state
      dispose()

  test "a nested createRoot's resources belong to the nested root only":
    createRoot do (dispose: proc()):
      let outer = getOwner()
      let own = createDeferredResource[int]()
      var nestedOwner: OwnerBase
      var nestedRes: DeferredResource[int]
      var disposeNested: proc()
      createRoot do (d: proc()):
        disposeNested = d
        nestedOwner = getOwner()
        nestedRes = createDeferredResource[int]()
      let outerFound = ownedResourceStates(outer)
      check outerFound.len == 1
      if outerFound.len == 1:
        check outerFound[0] == own.resource.state
      let nestedFound = ownedResourceStates(nestedOwner)
      check nestedFound.len == 1
      if nestedFound.len == 1:
        check nestedFound[0] == nestedRes.resource.state
      # Disposing the outer root leaves the nested root's record alone,
      # matching disposal: the nested root outlives it.
      dispose()
      check ownedResourceStates(outer).len == 0
      check ownedResourceStates(nestedOwner).len == 1
      disposeNested()
      check ownedResourceStates(nestedOwner).len == 0

  test "nothing leaks across sibling roots":
    var rootA, rootB: OwnerBase
    var disposeA, disposeB: proc()
    var resA, resB: DeferredResource[int]
    createRoot do (d: proc()):
      disposeA = d
      rootA = getOwner()
      resA = createDeferredResource[int]()
    createRoot do (d: proc()):
      disposeB = d
      rootB = getOwner()
      resB = createDeferredResource[int]()
    let a = ownedResourceStates(rootA)
    let b = ownedResourceStates(rootB)
    check a.len == 1
    check b.len == 1
    if a.len == 1 and b.len == 1:
      check a[0] == resA.resource.state
      check b[0] == resB.resource.state
    disposeA()
    check ownedResourceStates(rootA).len == 0
    check ownedResourceStates(rootB).len == 1
    disposeB()

  test "a resource created with no current owner registers nowhere":
    check getOwner() == nil
    let loose = createDeferredResource[int]()
    check loose.resource.state.value == rsPending
    createRoot do (dispose: proc()):
      check ownedResourceStates(getOwner()).len == 0
      dispose()
    check ownedResourceStates(nil).len == 0
