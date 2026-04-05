import unittest
import isonim/core/[signals, computation, owner]
import isonim/routing/[match, router]

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

suite "Router Signal Integration":
  test "createRouter matches initial path":
    createRoot proc(dispose: proc()) =
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")
      check r.hasMatch() == true
      check r.matchedIndex.val == 0
      check r.currentParams().len == 0
      dispose()

  test "navigate updates matchedRoute signal":
    createRoot proc(dispose: proc()) =
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
    createRoot proc(dispose: proc()) =
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
    createRoot proc(dispose: proc()) =
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/about"), component: proc() = discard),
      ], "/")

      r.navigate("/nonexistent")
      check r.hasMatch() == false
      check r.matchedIndex.val == -1
      dispose()

  test "reactive effect observes route changes":
    createRoot proc(dispose: proc()) =
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/page"), component: proc() = discard),
      ], "/")

      var observedIdx = -99
      createEffect proc() =
        observedIdx = r.matchedIndex.val

      check observedIdx == 0  # initial match on "/"

      r.navigate("/page")
      check observedIdx == 1

      r.navigate("/nowhere")
      check observedIdx == -1
      dispose()

  test "matchedRoute returns correct entry":
    createRoot proc(dispose: proc()) =
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
    createRoot proc(dispose: proc()) =
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
      ], "/")
      check activeRouter == r
      dispose()

  test "createRouter with custom initial path":
    createRoot proc(dispose: proc()) =
      let r = createRouter(@[
        RouteEntry(pattern: parsePattern("/"), component: proc() = discard),
        RouteEntry(pattern: parsePattern("/dashboard"), component: proc() = discard),
      ], "/dashboard")
      check r.matchedIndex.val == 1
      check r.currentPath.val == "/dashboard"
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
      createRoot proc(dispose: proc()) =
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
      createRoot proc(dispose: proc()) =
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
      createRoot proc(dispose: proc()) =
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
