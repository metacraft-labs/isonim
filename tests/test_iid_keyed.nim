## Keyed reconciliation over the shipped in-memory renderer; a mock DOM is
## justified here to isolate DSL/key propagation. Real browser coverage also
## exercises the typed DOM index, hydration and garbage-collection lifecycle.
import std/[unittest, tables, strutils]
import isonim/core/[owner, signals, computation]
import isonim/dsl/[ui, components, stable_ids]
import isonim/testing/mock_dom

when not defined(isonimStableIds):
  {.error: "this test requires stable ids".}

proc row(r: MockRenderer; item: proc(): string): MockNode =
  ui(r):
    button(onclick = proc() = discard): text item()

suite "keyed structural identities":
  test "reorder, removal and reinsertion preserve the reconcile key":
    createRoot do(dispose: proc()):
      let r = MockRenderer()
      let list = r.createElement("ul")
      let items = createSignal(@["a", "b", "c"])
      forEachKeyed(r, list, proc(): seq[string] = items.val,
        proc(item: proc(): string; index: proc(): int): MockNode = row(r, item))
      check list.children.len == 3
      let a = list.children[0]
      let b = list.children[1]
      let aIid = a.attributes["data-iid"]
      let bIid = b.attributes["data-iid"]
      check aIid.endsWith("#a")
      check bIid.endsWith("#b")
      items.val = @["c", "b", "a"]
      check list.children[2] == a
      check list.children[1] == b
      check list.children[2].attributes["data-iid"] == aIid
      items.val = @["c", "a"]
      items.val = @["b", "c", "a"]
      check list.children[0] != b
      check list.children[0].attributes["data-iid"] == bIid
      check stableKeyPath == ""
      dispose()
  test "nested key scopes are unambiguous and restore on exception":
    withStableKey("a#b"):
      check runtimeIid("root") == "root#a%23b"
      withStableKey("c"):
        check runtimeIid("root") == "root#a%23b#c"
    expect ValueError:
      withStableKey("failure"):
        raise newException(ValueError, "intentional")
    check stableKeyPath == ""
  test "nested instance scopes restore after exceptions":
    let before = runtimeIid("aaaaaaaaaaaa")
    withStableInstance("bbbbbbbbbbbb"):
      let outer = runtimeIid("aaaaaaaaaaaa")
      expect ValueError:
        withStableInstance("cccccccccccc"):
          raise newException(ValueError, "intentional instance failure")
      check runtimeIid("aaaaaaaaaaaa") == outer
    check runtimeIid("aaaaaaaaaaaa") == before

when not defined(js):
  import std/locks
  import isonim/ssr/markers
  var barrierLock: Lock
  var barrierCondition: Cond
  var readyWorkers: int
  var threadResults: array[2, bool]
  proc scopedWorker(index: int) {.thread.} =
    let scope = if index == 0: "aaaaaaaaaaaa" else: "bbbbbbbbbbbb"
    withStableInstance(scope):
      withHydrationKeys(""):
        # Both real threads hold their render/caller scopes concurrently.
        # No timing assumptions or sleeps: the barrier forces overlap.
        acquire(barrierLock)
        inc readyWorkers
        if readyWorkers == 2: broadcast(barrierCondition)
        while readyWorkers < 2: wait(barrierCondition, barrierLock)
        release(barrierLock)
        threadResults[index] = ssrRuntimeIid("cccccccccccc") == "cccccccccccc@" & scope

  suite "native stable-id scope isolation":
    test "concurrent server renders keep separate caller paths and claims":
      initLock(barrierLock)
      initCond(barrierCondition)
      readyWorkers = 0
      var workers: array[2, Thread[int]]
      createThread(workers[0], scopedWorker, 0)
      createThread(workers[1], scopedWorker, 1)
      joinThreads(workers)
      check threadResults == [true, true]
      deinitCond(barrierCondition)
      deinitLock(barrierLock)
