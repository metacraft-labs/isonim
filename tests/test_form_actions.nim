import unittest
import std/json
import isonim/server/rpc
import isonim/server/pragma
import isonim/server/form_action

when not defined(js):
  import std/tables

# ---- Action function definitions ----

proc createPost(title: string, body: string): string {.action.} =
  result = "Created: " & title & " — " & body

proc addItem(name: string, quantity: int): int {.action.} =
  result = quantity + 1

proc toggleFlag(flag: bool): bool {.action.} =
  result = not flag

# ---- Tests ----

when not defined(js):
  suite "Form Actions — C target":
    test "action URL constant is generated":
      check createPostUrl == "/api/actions/createPost"
      check addItemUrl == "/api/actions/addItem"
      check toggleFlagUrl == "/api/actions/toggleFlag"

    test "action functions are callable directly":
      check createPost("Hello", "World") == "Created: Hello — World"
      check addItem("widget", 5) == 6
      check toggleFlag(true) == false

    test "action is registered in the RPC registry":
      check rpcRegistry.hasKey("/api/actions/createPost")
      check rpcRegistry.hasKey("/api/actions/addItem")
      check rpcRegistry.hasKey("/api/actions/toggleFlag")

    test "action handler dispatches correctly with JSON":
      let handler = lookupRpc("/api/actions/createPost")
      check handler != nil
      let args = %*{"title": "Test", "body": "Content"}
      let res = handler(args)
      check res.getStr() == "Created: Test — Content"

    test "action handler dispatches correctly for int return":
      let handler = lookupRpc("/api/actions/addItem")
      check handler != nil
      let args = %*{"name": "bolt", "quantity": 10}
      let res = handler(args)
      check res.getInt() == 11

    test "parseFormData basic":
      let data = parseFormData("title=Hello&body=World")
      check data["title"] == "Hello"
      check data["body"] == "World"

    test "parseFormData decodes plus as space":
      let data = parseFormData("title=Hello+World&body=Some+Content")
      check data["title"] == "Hello World"
      check data["body"] == "Some Content"

    test "parseFormData decodes percent-encoded characters":
      let data = parseFormData("name=hello%20world&val=a%26b")
      check data["name"] == "hello world"
      check data["val"] == "a&b"

    test "parseFormData handles empty body":
      let data = parseFormData("")
      check data.len == 0

    test "parseFormData handles value with equals sign":
      let data = parseFormData("expr=a%3Db")
      check data["expr"] == "a=b"

    test "formToJson converts table to JSON object":
      var t = initTable[string, string]()
      t["title"] = "Hello"
      t["body"] = "World"
      let j = formToJson(t)
      check j["title"].getStr() == "Hello"
      check j["body"].getStr() == "World"

    test "formBodyToJson end-to-end":
      let j = formBodyToJson("title=Hello+World&body=Some+Content")
      check j["title"].getStr() == "Hello World"
      check j["body"].getStr() == "Some Content"

    test "dispatch action with form-encoded input":
      let handler = lookupRpc("/api/actions/createPost")
      check handler != nil
      let formJson = formBodyToJson("title=Form+Title&body=Form+Body")
      let res = handler(formJson)
      check res.getStr() == "Created: Form Title — Form Body"

    test "dispatch action with JSON input gives same result":
      let handler = lookupRpc("/api/actions/createPost")
      check handler != nil
      let jsonArgs = %*{"title": "Form Title", "body": "Form Body"}
      let res = handler(jsonArgs)
      check res.getStr() == "Created: Form Title — Form Body"

    test "actionUrl helper returns correct path":
      check actionUrl("createPost") == "/api/actions/createPost"
      check actionUrl("doSomething") == "/api/actions/doSomething"

    test "actionUrlOf template returns correct path":
      check actionUrlOf(createPost) == "/api/actions/createPost"

    test "decodeUrlComponent handles various encodings":
      check decodeUrlComponent("hello+world") == "hello world"
      check decodeUrlComponent("hello%20world") == "hello world"
      check decodeUrlComponent("100%25") == "100%"
      check decodeUrlComponent("a%2Fb") == "a/b"
      check decodeUrlComponent("plain") == "plain"
      check decodeUrlComponent("") == ""

else:
  suite "Form Actions — JS target":
    test "action function compiles":
      check declared(createPost)
      check declared(addItem)
      check declared(toggleFlag)

    test "action URL constants are available":
      check createPostUrl == "/api/actions/createPost"
      check addItemUrl == "/api/actions/addItem"
      check toggleFlagUrl == "/api/actions/toggleFlag"

    test "actionUrl returns correct path":
      check actionUrl("createPost") == "/api/actions/createPost"
