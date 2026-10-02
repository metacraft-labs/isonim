## Form actions: `{.action.}` server functions, form-encoded bodies and the
## progressive-enhancement form helper.  (Their dispatch, including the
## no-JS redirect-after-POST, is in test_rpc_dispatch.nim.)

import std/[json, strutils]
import isonim/server/[rpc, pragma, context, form_action]

proc createPost(title: string, body: string): Future[string] {.action.} =
  return "Created: " & title & " — " & body

proc addItem(name: string, quantity: int): Future[int] {.action(target = "/items").} =
  return quantity + 1

proc toggleFlag(flag: bool): Future[bool] {.server, action.} =
  return not flag

when not defined(js):
  import std/[unittest, tables]

  suite "Form actions — C target":
    test "action URL constants are module-qualified":
      check createPostUrl == "/api/test_form_actions/createPost"
      check addItemUrl == "/api/test_form_actions/addItem"
      check toggleFlagUrl == "/api/test_form_actions/toggleFlag"

    test "actions are registered as actions, with their targets":
      check lookupRpc("test_form_actions/createPost").isAction
      check lookupRpc("test_form_actions/addItem").target == "/items"
      # {.server, action.} is an action too.
      check lookupRpc("test_form_actions/toggleFlag").isAction

    test "actions are callable in-process":
      check waitFor(createPost("Hello", "World")) == "Created: Hello — World"
      check waitFor(addItem("widget", 5)) == 6

    test "a form body decodes to the action's arguments":
      let ep = lookupRpc("test_form_actions/addItem")
      let (args, token) = decodeRpcBody(newSsrRequest("POST", addItemUrl,
        addItemUrl, "", @[("Content-Type", "application/x-www-form-urlencoded")],
        "127.0.0.1", body = "name=bolt&quantity=10&_csrf=tok"))
      check token == "tok"
      check not args.hasKey("_csrf")
      check waitFor(ep.handler(nil, args)).getInt == 11

    test "parseFormData decodes plus, percent escapes and equals signs":
      let data = parseFormData("title=Hello+World&val=a%26b&expr=a%3Db")
      check data["title"] == "Hello World"
      check data["val"] == "a&b"
      check data["expr"] == "a=b"
      check parseFormData("").len == 0

    test "a malformed percent escape is kept, not an error":
      check decodeUrlComponent("100%") == "100%"
      check decodeUrlComponent("a%zzb") == "a%zzb"
      check decodeUrlComponent("a%2Fb") == "a/b"

    test "formBodyToJson":
      let j = formBodyToJson("title=Hello+World&body=Some+Content")
      check j == %*{"title": "Hello World", "body": "Some Content"}

    test "formHtml carries the session's CSRF token":
      let ctx = newRequestContext(newSsrRequest("GET", "/", "/", "", @[], "127.0.0.1"))
      ctx.session = Session(subject: "u", csrfToken: "sess-tok")
      let html = formHtml(ctx, addItemUrl, "<button>Add</button>")
      check html.startsWith("<form action=\"/api/test_form_actions/addItem\" method=\"post\">")
      check "<input type=\"hidden\" name=\"_csrf\" value=\"sess-tok\">" in html
      check html.endsWith("<button>Add</button></form>")
      check ctx.response.headers.len == 0   # no cookie for a session

    test "formHtml issues the anonymous CSRF cookie without a session":
      let ctx = newRequestContext(newSsrRequest("GET", "/", "/", "", @[], "127.0.0.1"))
      let html = formHtml(ctx, "/subscribe", "")
      let cookie = ctx.response.header("Set-Cookie")
      check cookie.startsWith(anonCsrfCookieName & "=")
      check "HttpOnly" in cookie and "Secure" in cookie and "SameSite=Lax" in cookie
      let token = cookie[anonCsrfCookieName.len + 1 ..< cookie.find(';')]
      check token.len >= 43                     # 256 bits, base64url
      check ("value=\"" & token & "\"") in html
      # A second form in the same response reuses the token.
      check ("value=\"" & token & "\"") in formHtml(ctx, "/x", "")
      check ctx.response.headers.len == 1

else:
  import std/unittest

  suite "Form actions — JS target":
    test "action URL constants are available in the browser":
      check createPostUrl == "/api/test_form_actions/createPost"
      check addItemUrl == "/api/test_form_actions/addItem"
