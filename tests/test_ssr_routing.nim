## test_ssr_routing.nim
##
## SSR routing tests (C target only).
## Verifies that renderRoute matches URLs against routes and renders
## the correct component to HTML, including parameterized routes,
## nested layouts, and 404 handling.

import std/strutils
import unittest
import isonim/core/signals
import isonim/routing/[match, params, ssr]
import isonim/ssr/escape
import isonim/dsl/ui

# ---------------------------------------------------------------------------
# Test components — each returns HTML via the bare `ui` form
# ---------------------------------------------------------------------------

proc IndexPage(): string =
  ui:
    h1: text "Welcome"
    p: text "Home page"

proc AboutPage(): string =
  ui:
    h1: text "About"
    p: text "About this site"

proc UserPage(id: string): string =
  ui:
    h1: text "User " & id
    p: text "Profile for user " & id

proc UsersLayout(childHtml: string): string =
  ui:
    tdiv(class = "users-layout"):
      nav: text "Users Navigation"
      raw childHtml

proc UserDetailPage(id: string): string =
  ui:
    section:
      h2: text "Detail for " & id
      p: text "Detailed info about user " & id

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "SSR Routing — renderRoute":
  test "/ renders IndexPage":
    let routes = @[
      SsrRouteEntry(pattern: parsePattern("/"), component: IndexPage),
      SsrRouteEntry(pattern: parsePattern("/about"), component: AboutPage),
    ]
    let html = renderRoute(routes, "/")
    check "Welcome" in html
    check "Home page" in html

  test "/about renders AboutPage":
    let routes = @[
      SsrRouteEntry(pattern: parsePattern("/"), component: IndexPage),
      SsrRouteEntry(pattern: parsePattern("/about"), component: AboutPage),
    ]
    let html = renderRoute(routes, "/about")
    check "About" in html
    check "About this site" in html

  test "/users/:id renders UserPage with extracted param":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(pattern: parsePattern("/"), component: IndexPage),
      SsrRouteEntry(
        pattern: parsePattern("/users/:id"),
        component: proc(): string = UserPage(rp.get("id").val),
      ),
    ]
    let html = renderRoute(routes, "/users/42", rp)
    check "User 42" in html
    check "Profile for user 42" in html

  test "/users/:id with different id":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/users/:id"),
        component: proc(): string = UserPage(rp.get("id").val),
      ),
    ]
    let html = renderRoute(routes, "/users/99", rp)
    check "User 99" in html

  test "/nonexistent returns 404":
    let routes = @[
      SsrRouteEntry(pattern: parsePattern("/"), component: IndexPage),
      SsrRouteEntry(pattern: parsePattern("/about"), component: AboutPage),
    ]
    let html = renderRoute(routes, "/nonexistent")
    check "404" in html
    check "Not Found" in html

  test "empty route table returns 404":
    let routes: seq[SsrRouteEntry] = @[]
    let html = renderRoute(routes, "/anything")
    check "404" in html

suite "SSR Routing — nested routes with layout":
  test "nested /users/:id renders layout wrapping child":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/users"),
        component: nil,
        layout: UsersLayout,
        children: @[
          SsrRouteEntry(
            pattern: parsePattern("/:id"),
            component: proc(): string = UserDetailPage(rp.get("id").val),
          ),
        ],
      ),
      SsrRouteEntry(pattern: parsePattern("/about"), component: AboutPage),
    ]
    let html = renderRoute(routes, "/users/42", rp)
    check "users-layout" in html
    check "Users Navigation" in html
    check "Detail for 42" in html
    check "Detailed info about user 42" in html

  test "nested route — different child id":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/users"),
        component: nil,
        layout: UsersLayout,
        children: @[
          SsrRouteEntry(
            pattern: parsePattern("/:id"),
            component: proc(): string = UserDetailPage(rp.get("id").val),
          ),
        ],
      ),
    ]
    let html = renderRoute(routes, "/users/7", rp)
    check "Detail for 7" in html
    check "users-layout" in html

  test "nested route — no matching child returns 404":
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/admin"),
        component: nil,
        layout: proc(child: string): string = "<div>Admin</div>" & child,
        children: @[
          SsrRouteEntry(
            pattern: parsePattern("/dashboard"),
            component: proc(): string = "<p>Dashboard</p>",
          ),
        ],
      ),
    ]
    # /admin/settings has no matching child route
    let html = renderRoute(routes, "/admin/settings")
    check "404" in html

  test "parent exact match without children":
    proc allUsersPage(): string =
      ui:
        h1: text "All Users"

    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/users"),
        component: allUsersPage,
        layout: UsersLayout,
        children: @[
          SsrRouteEntry(
            pattern: parsePattern("/:id"),
            component: proc(): string = "<p>User</p>",
          ),
        ],
      ),
    ]
    # Exact /users should match the parent's own component
    let html = renderRoute(routes, "/users")
    check "All Users" in html

suite "SSR Routing — routeParams population":
  test "routeParams populated on match":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/posts/:slug"),
        component: proc(): string =
          let slug = rp.get("slug").val
          "<article>" & slug & "</article>",
      ),
    ]
    let html = renderRoute(routes, "/posts/hello-world", rp)
    check rp.get("slug").val == "hello-world"
    check "hello-world" in html

  test "routeParams cleared on no match":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/users/:id"),
        component: proc(): string = UserPage(rp.get("id").val),
      ),
    ]
    # First, match a route to populate params
    discard renderRoute(routes, "/users/42", rp)
    check rp.get("id").val == "42"

    # Then navigate to a non-matching route
    discard renderRoute(routes, "/nonexistent", rp)
    check rp.get("id").val == ""

  test "nested route merges parent and child params":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(
        pattern: parsePattern("/org/:orgId"),
        component: nil,
        layout: proc(child: string): string =
          "<div class=\"org\">" & child & "</div>",
        children: @[
          SsrRouteEntry(
            pattern: parsePattern("/users/:userId"),
            component: proc(): string =
              let orgId = rp.get("orgId").val
              let userId = rp.get("userId").val
              "<p>Org " & orgId & " User " & userId & "</p>",
          ),
        ],
      ),
    ]
    let html = renderRoute(routes, "/org/5/users/42", rp)
    check rp.get("orgId").val == "5"
    check rp.get("userId").val == "42"
    check "Org 5 User 42" in html

suite "SSR Routing — multiple renders":
  test "renderRoute can be called multiple times with different paths":
    let rp = newRouteParams()
    let routes = @[
      SsrRouteEntry(pattern: parsePattern("/"), component: IndexPage),
      SsrRouteEntry(pattern: parsePattern("/about"), component: AboutPage),
      SsrRouteEntry(
        pattern: parsePattern("/users/:id"),
        component: proc(): string = UserPage(rp.get("id").val),
      ),
    ]

    let html1 = renderRoute(routes, "/", rp)
    check "Welcome" in html1

    let html2 = renderRoute(routes, "/about", rp)
    check "About" in html2

    let html3 = renderRoute(routes, "/users/42", rp)
    check "User 42" in html3

    let html4 = renderRoute(routes, "/nonexistent", rp)
    check "404" in html4
