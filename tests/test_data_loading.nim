## test_data_loading.nim
##
## Tests for M6: createServerResource — data loading via server functions.
##
## C target tests verify:
##   - Server functions resolve synchronously (rsReady immediately)
##   - Correct values are returned
##   - Multiple resources in one render all resolve
##   - Integration with renderToString produces HTML with server data
##   - Integration with SSR routing (renderRoute) includes fetched data
##
## JS target tests verify:
##   - Server function + createServerResource compiles correctly
##   - Resource types are correct

import unittest
import std/[json, strutils]
import isonim/core/[signals, owner, resource]
import isonim/server/[pragma, rpc, data_loading]

# ---------------------------------------------------------------------------
# Server function definitions (used by both targets)
# ---------------------------------------------------------------------------

type
  User = object
    id: int
    name: string

  Post = object
    id: int
    title: string
    body: string

proc getUser(id: int): User {.server.} =
  User(id: id, name: "User " & $id)

proc getPost(id: int): Post {.server.} =
  Post(id: id, title: "Post " & $id, body: "Body of post " & $id)

proc getCount(): int {.server.} =
  42

proc getUserName(id: int): string {.server.} =
  "User " & $id

proc failingFetch(): string {.server.} =
  raise newException(CatchableError, "server error")

# ---------------------------------------------------------------------------
# C target: SSR path tests
# ---------------------------------------------------------------------------

when not defined(js):
  import isonim/ssr/renderer
  import isonim/ssr/escape
  import isonim/dsl/html
  import isonim/routing/[match, params, ssr]

  suite "createServerResource — C target (SSR)":
    test "server function resource resolves immediately":
      createRoot proc(dispose: proc()) =
        let r = createServerResource[User](
          proc(): User = getUser(1)
        )
        check r.state.val == rsReady
        check r.val.id == 1
        check r.val.name == "User 1"

    test "zero-arg server function resource":
      createRoot proc(dispose: proc()) =
        let r = createServerResource[int](
          proc(): int = getCount()
        )
        check r.state.val == rsReady
        check r.val == 42

    test "string-returning server function":
      createRoot proc(dispose: proc()) =
        let r = createServerResource[string](
          proc(): string = getUserName(7)
        )
        check r.state.val == rsReady
        check r.val == "User 7"

    test "resource is not loading after synchronous resolve":
      createRoot proc(dispose: proc()) =
        let r = createServerResource[int](
          proc(): int = getCount()
        )
        check r.loading == false

    test "failing server function produces errored resource":
      createRoot proc(dispose: proc()) =
        let r = createServerResource[string](
          proc(): string = failingFetch()
        )
        check r.state.val == rsErrored
        check "server error" in r.error.val

    test "multiple resources in one scope all resolve":
      createRoot proc(dispose: proc()) =
        let userRes = createServerResource[User](
          proc(): User = getUser(10)
        )
        let postRes = createServerResource[Post](
          proc(): Post = getPost(5)
        )
        let countRes = createServerResource[int](
          proc(): int = getCount()
        )
        check userRes.state.val == rsReady
        check postRes.state.val == rsReady
        check countRes.state.val == rsReady
        check userRes.val.name == "User 10"
        check postRes.val.title == "Post 5"
        check countRes.val == 42

  suite "createServerResource — SSR renderToString integration":
    test "resource data appears in rendered HTML":
      let html = renderToString proc(): string =
        let user = createServerResource[User](
          proc(): User = getUser(42)
        )
        uiString:
          h1: text user.val.name
          p: text "ID: " & $user.val.id

      check "User 42" in html
      check "ID: 42" in html

    test "multiple resources in rendered HTML":
      let html = renderToString proc(): string =
        let user = createServerResource[User](
          proc(): User = getUser(1)
        )
        let post = createServerResource[Post](
          proc(): Post = getPost(99)
        )
        uiString:
          tdiv:
            h1: text user.val.name
            h2: text post.val.title
            p: text post.val.body

      check "User 1" in html
      check "Post 99" in html
      check "Body of post 99" in html

    test "resource error handled in rendered HTML":
      let html = renderToString proc(): string =
        let r = createServerResource[string](
          proc(): string = failingFetch()
        )
        if r.state.val == rsErrored:
          uiString:
            p(class = "error"): text "Error: " & r.error.val
        else:
          uiString:
            p: text r.val

      check "error" in html
      check "server error" in html

  suite "createServerResource — SSR routing integration":
    test "route component using server resource renders data":
      let rp = newRouteParams()
      let routes = @[
        SsrRouteEntry(
          pattern: parsePattern("/users/:id"),
          component: proc(): string =
            let id = rp.get("id").val
            let user = createServerResource[User](
              proc(): User = getUser(parseInt(id))
            )
            uiString:
              h1: text user.val.name
              p: text "Profile for " & user.val.name
        ),
      ]
      let html = renderRoute(routes, "/users/42", rp)
      check "User 42" in html
      check "Profile for User 42" in html

    test "route with multiple server resources":
      let rp = newRouteParams()
      let routes = @[
        SsrRouteEntry(
          pattern: parsePattern("/dashboard"),
          component: proc(): string =
            let user = createServerResource[User](
              proc(): User = getUser(1)
            )
            let count = createServerResource[int](
              proc(): int = getCount()
            )
            uiString:
              tdiv(class = "dashboard"):
                h1: text user.val.name & "'s Dashboard"
                p: text "Items: " & $count.val
        ),
      ]
      let html = renderRoute(routes, "/dashboard", rp)
      check "User 1" in html
      check "Dashboard" in html
      check "Items: 42" in html

    test "nested route with layout and server resource":
      proc usersLayout(childHtml: string): string =
        uiString:
          tdiv(class = "users-layout"):
            nav: text "Users Nav"
            raw childHtml

      let rp = newRouteParams()
      let routes = @[
        SsrRouteEntry(
          pattern: parsePattern("/users"),
          component: nil,
          layout: usersLayout,
          children: @[
            SsrRouteEntry(
              pattern: parsePattern("/:id"),
              component: proc(): string =
                let id = rp.get("id").val
                let user = createServerResource[User](
                  proc(): User = getUser(parseInt(id))
                )
                uiString:
                  section:
                    h2: text user.val.name
                    p: text "ID: " & $user.val.id
            ),
          ],
        ),
      ]
      let html = renderRoute(routes, "/users/7", rp)
      check "users-layout" in html
      check "Users Nav" in html
      check "User 7" in html
      check "ID: 7" in html

  suite "createServerResource — source variant (C target)":
    test "source-based server resource resolves immediately":
      createRoot proc(dispose: proc()) =
        let id = createSignal(5)
        let r = createServerResource[int, User](
          proc(): int = id.val,
          proc(i: int): User = getUser(i)
        )
        check r.state.val == rsReady
        check r.val.name == "User 5"

    test "source-based resource refetches on source change":
      createRoot proc(dispose: proc()) =
        let id = createSignal(1)
        var fetchCount = 0
        let r = createServerResource[int, User](
          proc(): int = id.val,
          proc(i: int): User =
            inc fetchCount
            getUser(i)
        )
        check r.val.name == "User 1"
        check fetchCount == 1

        id.val = 3
        check r.val.name == "User 3"
        check fetchCount == 2

# ---------------------------------------------------------------------------
# JS target: compilation and type checks
# ---------------------------------------------------------------------------

else:
  suite "createServerResource — JS target":
    test "server function + createServerResource compiles":
      # On JS, server functions become RPC stubs.
      # We verify that createServerResource compiles with the stub.
      check declared(getUser)
      check declared(getPost)
      check declared(getCount)
      check declared(getUserName)
      check declared(createServerResource)

    test "resource type is correct":
      # Verify the return type is Resource[T]
      # (can't actually call RPC without a server, but types must match)
      when compiles(createServerResource[int](proc(): int = 0)):
        check true
      else:
        check false

    test "source variant compiles":
      when compiles(createServerResource[int, string](
        proc(): int = 0,
        proc(i: int): string = ""
      )):
        check true
      else:
        check false
