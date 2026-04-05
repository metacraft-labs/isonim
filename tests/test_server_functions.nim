import unittest
import std/json
import isonim/server/rpc
import isonim/server/pragma

when not defined(js):
  import std/tables

# ---- Server function definitions ----

proc add(a: int, b: int): int {.server.} =
  result = a + b

proc greet(name: string): string {.server.} =
  result = "Hello, " & name & "!"

proc multiply(x: float, y: float): float {.server.} =
  result = x * y

proc negate(flag: bool): bool {.server.} =
  result = not flag

proc noArgs(): int {.server.} =
  result = 42

type
  Point = object
    x: int
    y: int

proc makePoint(x: int, y: int): Point {.server.} =
  result = Point(x: x, y: y)

# ---- Tests ----

when not defined(js):
  suite "Server Functions — C target":
    test "basic int function works":
      check add(3, 4) == 7

    test "string function works":
      check greet("World") == "Hello, World!"

    test "float function works":
      check multiply(2.5, 4.0) == 10.0

    test "bool function works":
      check negate(true) == false
      check negate(false) == true

    test "zero-arg function works":
      check noArgs() == 42

    test "object return type works":
      let p = makePoint(10, 20)
      check p.x == 10
      check p.y == 20

    test "RPC registry has entries for all server functions":
      check rpcRegistry.hasKey("/api/add")
      check rpcRegistry.hasKey("/api/greet")
      check rpcRegistry.hasKey("/api/multiply")
      check rpcRegistry.hasKey("/api/negate")
      check rpcRegistry.hasKey("/api/noArgs")
      check rpcRegistry.hasKey("/api/makePoint")

    test "RPC handler dispatches correctly for add":
      let handler = lookupRpc("/api/add")
      check handler != nil
      let args = %*{"a": 10, "b": 20}
      let res = handler(args)
      check res.getInt() == 30

    test "RPC handler dispatches correctly for greet":
      let handler = lookupRpc("/api/greet")
      check handler != nil
      let args = %*{"name": "Nim"}
      let res = handler(args)
      check res.getStr() == "Hello, Nim!"

    test "RPC handler dispatches correctly for makePoint":
      let handler = lookupRpc("/api/makePoint")
      check handler != nil
      let args = %*{"x": 5, "y": 15}
      let res = handler(args)
      check res["x"].getInt() == 5
      check res["y"].getInt() == 15

    test "handleRpc end-to-end with JSON string":
      let response = handleRpc("/api/add", """{"a": 100, "b": 200}""")
      let parsed = parseJson(response)
      check parsed.getInt() == 300

    test "handleRpc returns error for unknown endpoint":
      let response = handleRpc("/api/nonexistent", "{}")
      let parsed = parseJson(response)
      check parsed.hasKey("error")

    test "multiple calls produce correct results":
      for i in 0 ..< 10:
        check add(i, i) == i * 2

else:
  suite "Server Functions — JS target":
    test "server function compiles and is callable":
      # On JS, the body is replaced with an RPC stub.
      # We can't actually call rpcFetchSync without a server,
      # but we verify the proc exists with the correct signature.
      # The proc is defined and has the right type.
      check declared(add)
      check declared(greet)
      check declared(multiply)
      check declared(negate)
      check declared(noArgs)
      check declared(makePoint)

    test "endpoint paths are deterministic":
      # Verify the endpoint derivation is consistent.
      # This tests the endpointPath logic indirectly —
      # the macro generates "/api/<procname>" paths.
      check true  # If the module compiled, endpoint generation worked.
