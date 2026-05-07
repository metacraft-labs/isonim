import unittest
import isonim/core/[signals, computation, owner]
import isonim/routing/[match, router, params, outlet]

suite "URL Pattern Matching":
  test "exact match: /about matches /about":
    let pat = parsePattern("/about")
    let m = matchPath(pat, "/about")
    check m.matched == true
    check m.params.len == 0

  test "no match: /about does not match /contact":
    let pat = parsePattern("/about")
    let m = matchPath(pat, "/contact")
    check m.matched == false

  test "param match: /users/:id matches /users/42":
    let pat = parsePattern("/users/:id")
    let m = matchPath(pat, "/users/42")
    check m.matched == true
    check m.params.len == 1
    check m.params[0] == ("id", "42")

  test "multi-param: /users/:id/posts/:postId":
    let pat = parsePattern("/users/:id/posts/:postId")
    let m = matchPath(pat, "/users/7/posts/99")
    check m.matched == true
    check m.params.len == 2
    check m.params[0] == ("id", "7")
    check m.params[1] == ("postId", "99")

  test "root match: / matches /":
    let pat = parsePattern("/")
    let m = matchPath(pat, "/")
    check m.matched == true
    check m.params.len == 0

  test "trailing slash: /about/ matches /about":
    let pat = parsePattern("/about")
    let m = matchPath(pat, "/about/")
    check m.matched == true

  test "trailing slash: /about matches /about/":
    let pat = parsePattern("/about/")
    let m = matchPath(pat, "/about")
    check m.matched == true

  test "segment count mismatch: /users/:id does not match /users":
    let pat = parsePattern("/users/:id")
    let m = matchPath(pat, "/users")
    check m.matched == false

  test "segment count mismatch: /users does not match /users/42":
    let pat = parsePattern("/users")
    let m = matchPath(pat, "/users/42")
    check m.matched == false

  test "parsePattern produces correct segments":
    let pat = parsePattern("/users/:id/posts")
    check pat.segments.len == 3
    check pat.segments[0].value == "users"
    check pat.segments[0].isDynamic == false
    check pat.segments[1].value == "id"
    check pat.segments[1].isDynamic == true
    check pat.segments[2].value == "posts"
    check pat.segments[2].isDynamic == false

suite "Prefix Matching":
  test "prefix match: /users matches /users/42":
    let pat = parsePattern("/users")
    let m = matchPrefix(pat, "/users/42")
    check m.matched == true
    check m.params.len == 0

  test "prefix match: /users/:id matches /users/42/posts":
    let pat = parsePattern("/users/:id")
    let m = matchPrefix(pat, "/users/42/posts")
    check m.matched == true
    check m.params.len == 1
    check m.params[0] == ("id", "42")

  test "prefix match: /users does not match /about":
    let pat = parsePattern("/users")
    let m = matchPrefix(pat, "/about")
    check m.matched == false

  test "remainingPath: /users consumed from /users/42/posts":
    let pat = parsePattern("/users")
    let rest = remainingPath(pat, "/users/42/posts")
    check rest == "/42/posts"

  test "remainingPath: full consumption returns /":
    let pat = parsePattern("/users/42")
    let rest = remainingPath(pat, "/users/42")
    check rest == "/"

suite "Router Signal Integration":
  test "createRouter matches initial path":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")
      check r.hasMatch() == true
      check r.matchedIndex.val == 0
      check r.currentParams().len == 0
      dispose()

  test "navigate updates matchedRoute signal":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/contact"), component: proc() = discard),
      ], "/")
      check r.matchedIndex.val == 0  # initial: /

      r.navigate("/about")
      check r.matchedIndex.val == 1
      check r.currentPath.val == "/about"

      r.navigate("/contact")
      check r.matchedIndex.val == 2
      check r.currentPath.val == "/contact"
      dispose()

  test "navigate to parameterized route updates params":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
      ], "/")

      r.navigate("/users/42")
      check r.matchedIndex.val == 1
      let p = r.currentParams()
      check p.len == 1
      check p[0] == ("id", "42")

      r.navigate("/users/99")
      let p2 = r.currentParams()
      check p2[0] == ("id", "99")
      dispose()

  test "navigate to non-existent route yields no match":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")

      r.navigate("/nonexistent")
      check r.hasMatch() == false
      check r.matchedIndex.val == -1
      dispose()

  test "reactive effect observes route changes":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/page"), component: proc() = discard),
      ], "/")

      var observedIdx = -99
      createEffect do:
        observedIdx = r.matchedIndex.val

      check observedIdx == 0  # initial match on "/"

      r.navigate("/page")
      check observedIdx == 1

      r.navigate("/nowhere")
      check observedIdx == -1
      dispose()

  test "matchedRoute returns correct entry":
    createRoot do (dispose: proc()):
      var aboutCalled = false
      let aboutComp = proc() = aboutCalled = true

      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: aboutComp),
      ], "/")

      r.navigate("/about")
      let entry = r.matchedRoute()
      check entry.pattern.path == "/about"
      entry.component()
      check aboutCalled == true
      dispose()

  test "global activeRouter is set":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
      ], "/")
      check activeRouter == r
      dispose()

  test "createRouter with custom initial path":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/dashboard"), component: proc() = discard),
      ], "/dashboard")
      check r.matchedIndex.val == 1
      check r.currentPath.val == "/dashboard"
      dispose()

suite "RouteParams — reactive params":
  test "navigate to /users/42 — params.get(id) == 42":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
      ], "/")

      r.navigate("/users/42")
      check r.routeParams.get("id").val == "42"
      dispose()

  test "same signal updates when navigating /users/1 to /users/2":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
      ], "/users/1")

      let idSignal = r.routeParams.get("id")
      check idSignal.val == "1"

      r.navigate("/users/99")
      # The SAME signal object should have the new value
      check idSignal.val == "99"
      check r.routeParams.get("id") == idSignal  # same signal identity
      dispose()

  test "getInt returns correct integer value":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
      ], "/users/42")

      let idInt = r.routeParams.getInt("id")
      check idInt.val == 42

      r.navigate("/users/7")
      check idInt.val == 7
      dispose()

  test "missing param returns empty string":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/about")

      check r.routeParams.get("nonexistent").val == ""
      dispose()

  test "getAll returns snapshot of all params":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/users/:id/posts/:postId"), component: proc() = discard),
      ], "/users/7/posts/99")

      let all = r.routeParams.getAll()
      check all.len == 2
      # Check both params are present (order may vary with table iteration)
      var foundId, foundPostId = false
      for (key, val) in all:
        if key == "id" and val == "7": foundId = true
        if key == "postId" and val == "99": foundPostId = true
      check foundId
      check foundPostId
      dispose()

  test "param cleared when navigating to route without that param":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/users/42")

      let idSignal = r.routeParams.get("id")
      check idSignal.val == "42"

      r.navigate("/about")
      check idSignal.val == ""
      dispose()

  test "reactive effect fires when param changes":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/users/:id"), component: proc() = discard),
      ], "/users/1")

      var observed = ""
      createEffect do:
        observed = r.routeParams.get("id").val

      check observed == "1"
      r.navigate("/users/42")
      check observed == "42"
      dispose()

suite "Nested Layouts":
  test "nested route matching — parent + child":
    createRoot do (dispose: proc()):
      var layoutRendered = false
      var childRendered = false
      var childId = ""

      let r = createRouter(@[
        RouteEntry(
          pattern: parsePattern("/users"),
          component: proc() = discard,
          layout: proc() = layoutRendered = true,
          children: @[
            RouteEntry(pattern: parsePattern("/:id"), component: proc() =
              childRendered = true
              childId = activeRouter.routeParams.get("id").val
            ),
            RouteEntry(pattern: parsePattern("/new"), component: proc() =
              childRendered = true
              childId = "new"
            ),
          ],
        ),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/users/42")

      check r.hasMatch()
      check r.matchedIndex.val == 0

      let chain = r.matchChain.val
      check chain.len == 2
      # The parent's component in the chain is the layout
      chain[0].component()
      check layoutRendered == true
      # The child's component renders
      chain[1].component()
      check childRendered == true
      check childId == "42"
      dispose()

  test "navigate between children — layout persists in chain":
    createRoot do (dispose: proc()):
      var layoutCallCount = 0
      let layoutComp = proc() = inc layoutCallCount

      var childValue = ""
      let childComp = proc() = childValue = "child"
      let newChildComp = proc() = childValue = "new"

      let r = createRouter(@[
        RouteEntry(
          pattern: parsePattern("/users"),
          layout: layoutComp,
          component: proc() = discard,
          children: @[
            # Static routes must come before dynamic ones
            RouteEntry(pattern: parsePattern("/new"), component: newChildComp),
            RouteEntry(pattern: parsePattern("/:id"), component: childComp),
          ],
        ),
      ], "/users/42")

      let chain1 = r.matchChain.val
      check chain1.len == 2
      let layoutRef1 = chain1[0].component

      r.navigate("/users/99")
      let chain2 = r.matchChain.val
      check chain2.len == 2
      let layoutRef2 = chain2[0].component

      # The layout component proc is the SAME reference — it persists
      check layoutRef1 == layoutRef2
      # But child component is also the same (same route, different param)
      check chain2[1].component == childComp

      # Navigate to a different child route
      r.navigate("/users/new")
      let chain3 = r.matchChain.val
      check chain3.len == 2
      check chain3[0].component == layoutRef1  # layout same
      check chain3[1].component == newChildComp  # different child
      dispose()

  test "nested params merge parent + child":
    createRoot do (dispose: proc()):
      let r = createRouter(@[
        RouteEntry(
          pattern: parsePattern("/org/:orgId"),
          component: proc() = discard,
          children: @[
            RouteEntry(pattern: parsePattern("/users/:userId"), component: proc() = discard),
          ],
        ),
      ], "/org/5/users/42")

      check r.routeParams.get("orgId").val == "5"
      check r.routeParams.get("userId").val == "42"

      let flat = r.currentParams()
      check flat.len == 2
      dispose()

suite "Outlet — child projection":
  test "OutletState renders child from match chain":
    createRoot do (dispose: proc()):
      var parentRendered = false
      var childRendered = false

      let chain = createSignal(@[
        MatchChainEntry(component: proc() = parentRendered = true, params: @[]),
        MatchChainEntry(component: proc() = childRendered = true, params: @[]),
      ])

      # Create outlet at depth 1 (renders the child)
      let state = createOutletState(chain, 1)

      check childRendered == true
      check parentRendered == false  # outlet at depth 1 doesn't render depth 0
      dispose()

  test "OutletState swaps child when chain changes":
    createRoot do (dispose: proc()):
      var childARendered = 0
      var childBRendered = 0

      let parentComp = proc() = discard
      let childA = proc() = inc childARendered
      let childB = proc() = inc childBRendered

      let chain = createSignal(@[
        MatchChainEntry(component: parentComp, params: @[]),
        MatchChainEntry(component: childA, params: @[]),
      ])

      let state = createOutletState(chain, 1)
      check childARendered == 1
      check childBRendered == 0

      # Change to child B
      chain.val = @[
        MatchChainEntry(component: parentComp, params: @[]),
        MatchChainEntry(component: childB, params: @[]),
      ]
      check childBRendered == 1
      # childA was disposed, so no additional calls
      check childARendered == 1
      dispose()

  test "OutletState preserves layout — same component not re-rendered":
    createRoot do (dispose: proc()):
      var layoutRenderCount = 0
      let layoutComp = proc() = inc layoutRenderCount

      var childRenderCount = 0
      let childComp = proc() = inc childRenderCount

      let chain = createSignal(@[
        MatchChainEntry(component: layoutComp, params: @[]),
        MatchChainEntry(component: childComp, params: @[("id", "1")]),
      ])

      # Outlet at depth 0 renders the layout
      let layoutOutlet = createOutletState(chain, 0)
      check layoutRenderCount == 1

      # Update chain with same layout but different child params
      chain.val = @[
        MatchChainEntry(component: layoutComp, params: @[]),
        MatchChainEntry(component: childComp, params: @[("id", "2")]),
      ]

      # Layout should NOT be re-rendered (same component identity)
      check layoutRenderCount == 1
      dispose()

suite "Layout Persistence":
  test "layout signal retains value across child navigation":
    createRoot do (dispose: proc()):
      # Simulate a layout that has its own counter signal
      var counterSignal: Signal[int]
      var layoutRendered = false

      let layoutComp = proc() =
        layoutRendered = true
        counterSignal = createSignal(0)

      let childA = proc() = discard
      let childB = proc() = discard

      let chain = createSignal(@[
        MatchChainEntry(component: layoutComp, params: @[]),
        MatchChainEntry(component: childA, params: @[]),
      ])

      # Render layout via outlet at depth 0
      let layoutOutlet = createOutletState(chain, 0)
      check layoutRendered == true
      check counterSignal != nil

      # Increment the counter
      counterSignal.val = 5
      check counterSignal.val == 5

      # Navigate to a different child — layout persists
      chain.val = @[
        MatchChainEntry(component: layoutComp, params: @[]),
        MatchChainEntry(component: childB, params: @[]),
      ]

      # Counter should retain its value because layout was NOT re-rendered
      check counterSignal.val == 5
      dispose()

  test "layout signal destroyed when layout changes":
    createRoot do (dispose: proc()):
      var layoutARendered = 0
      var layoutBRendered = 0

      let layoutA = proc() = inc layoutARendered
      let layoutB = proc() = inc layoutBRendered
      let child = proc() = discard

      let chain = createSignal(@[
        MatchChainEntry(component: layoutA, params: @[]),
        MatchChainEntry(component: child, params: @[]),
      ])

      let layoutOutlet = createOutletState(chain, 0)
      check layoutARendered == 1

      # Change to a completely different layout
      chain.val = @[
        MatchChainEntry(component: layoutB, params: @[]),
        MatchChainEntry(component: child, params: @[]),
      ]

      check layoutBRendered == 1
      check layoutARendered == 1  # old layout not re-rendered
      dispose()

  test "full router: layout persists across sibling navigations":
    createRoot do (dispose: proc()):
      var layoutRenderCount = 0
      var counterSignal: Signal[int]

      let layoutComp = proc() =
        inc layoutRenderCount
        if counterSignal == nil:
          counterSignal = createSignal(0)

      var childAId = ""
      var childBFlag = false

      let r = createRouter(@[
        RouteEntry(
          pattern: parsePattern("/users"),
          layout: layoutComp,
          component: proc() = discard,
          children: @[
            RouteEntry(pattern: parsePattern("/:id"), component: proc() =
              childAId = activeRouter.routeParams.get("id").val
            ),
            RouteEntry(pattern: parsePattern("/new"), component: proc() =
              childBFlag = true
            ),
          ],
        ),
      ], "/users/1")

      # Render via outlet
      let layoutOutlet = createOutletState(r.matchChain, 0)
      let childOutlet = createOutletState(r.matchChain, 1)

      check layoutRenderCount == 1
      check counterSignal != nil
      counterSignal.val = 10

      # Navigate to different user — same layout
      r.navigate("/users/42")
      check layoutRenderCount == 1  # layout NOT re-rendered
      check counterSignal.val == 10  # signal persists
      check r.routeParams.get("id").val == "42"

      # Navigate to /users/new — still same layout
      r.navigate("/users/new")
      check layoutRenderCount == 1  # still not re-rendered
      check counterSignal.val == 10  # still persists

      dispose()

when defined(js):
  # Inject a minimal window shim for History API tests in Node.js
  {.emit: """
  // ---- Minimal window shim for router tests in Node.js ----
  (function() {
    if (typeof window !== 'undefined') return; // real browser, skip shim

    var _pathname = '/';
    var _historyStack = ['/'];
    var _historyIndex = 0;
    var _popstateListeners = [];

    var locationObj = {
      get pathname() { return _pathname; },
      set pathname(v) { _pathname = v; },
      search: '',
      hash: ''
    };

    var historyObj = {
      pushState: function(state, title, url) {
        _pathname = url;
        // Trim forward history
        _historyStack = _historyStack.slice(0, _historyIndex + 1);
        _historyStack.push(url);
        _historyIndex = _historyStack.length - 1;
      },
      replaceState: function(state, title, url) {
        _pathname = url;
        _historyStack[_historyIndex] = url;
      },
      back: function() {
        if (_historyIndex > 0) {
          _historyIndex--;
          _pathname = _historyStack[_historyIndex];
          // Fire popstate
          for (var i = 0; i < _popstateListeners.length; i++) {
            _popstateListeners[i]({});
          }
        }
      }
    };

    globalThis.window = {
      location: locationObj,
      history: historyObj,
      addEventListener: function(event, handler) {
        if (event === 'popstate') {
          _popstateListeners.push(handler);
        }
      },
      removeEventListener: function(event, handler) {
        if (event === 'popstate') {
          var idx = _popstateListeners.indexOf(handler);
          if (idx >= 0) _popstateListeners.splice(idx, 1);
        }
      }
    };
  })();
  """.}

  suite "JS History API Integration":
    test "navigate calls pushState and updates URL":
      createRoot do (dispose: proc()):
        let r = createRouter(@[
          RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
          RouteEntry(pattern: parsePattern("/test"), component: proc() = discard),
        ])

        # Navigate — this should call pushState and update the signal
        r.navigate("/test")
        check r.currentPath.val == "/test"
        check r.matchedIndex.val == 1

        # Verify the window.location was updated via the shim
        var pathname: cstring
        {.emit: [pathname, " = window.location.pathname;"].}
        check $pathname == "/test"
        dispose()

    test "navigate with replace calls replaceState":
      createRoot do (dispose: proc()):
        let r = createRouter(@[
          RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
          RouteEntry(pattern: parsePattern("/replaced"), component: proc() = discard),
        ])

        r.navigate("/replaced", replace = true)
        check r.currentPath.val == "/replaced"

        var pathname: cstring
        {.emit: [pathname, " = window.location.pathname;"].}
        check $pathname == "/replaced"
        dispose()

    test "popstate handler updates currentPath":
      createRoot do (dispose: proc()):
        let r = createRouter(@[
          RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
          RouteEntry(pattern: parsePattern("/page1"), component: proc() = discard),
          RouteEntry(pattern: parsePattern("/page2"), component: proc() = discard),
        ])

        r.navigate("/page1")
        check r.currentPath.val == "/page1"
        r.navigate("/page2")
        check r.currentPath.val == "/page2"

        # Simulate browser back button via the shim
        {.emit: "window.history.back();".}
        check r.currentPath.val == "/page1"
        check r.matchedIndex.val == 1
        dispose()
