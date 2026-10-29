## isonim/routing/json_decode.nim
##
## The typed decoder of the browser clients (route_client.nim,
## rpc_client.nim): a response's JSON into its declared Nim type.
##
## std/json's `to` would do, but on the JS target each instantiation carries
## its kind checks and their formatted error messages (strutils' `%`, the
## kinds' names), which is most of a generated client's size; a client
## bundle with a size budget (say 30 KB gzipped of critical JS) pays
## for every response type it decodes. This decoder is lenient instead: a
## missing or mistyped field takes its type's default value (an `Option`,
## `none`), unknown fields are ignored, and nothing raises. The server's
## responses are generated from the same types, so a mismatch is a version
## skew between the page's bundle and the server, not an input to validate
## (requests are validated on the server, route_dispatch.nim).
##
## Supported: strings, booleans, integers, floats, enums (by name),
## `Option`, `seq`, objects and refs to objects of these, and `JsonNode`
## (kept as it is). Case objects are not.
##
## 64-BIT INTEGERS. A JS build with `--jsbigint64:off` (a size-budgeted
## bundle) represents `int64` and `uint64` as JS numbers, which are exact
## only up to 2^53, and the browser's JSON numbers are doubles anyway. Such a
## build refuses to compile a decode or an encode of an `int64`/`uint64`
## field (`noInexactInt64`): a value that can exceed 2^53 (a `BIGINT` id, a
## commit position) is carried as a decimal string instead, and only fields
## known to fit (an `int` of a 32-bit column, a count) are numbers.

import std/[json, options]

template noInexactInt64(T: typedesc) =
  ## Module doc, "64-BIT INTEGERS".
  when defined(js) and not compileOption("jsbigint64") and (T is int64 or T is uint64):
    {.error: "json_decode: a " & $T & " field is not exact in a --jsbigint64:off build " &
      "(a JS number holds 2^53); carry the value as a decimal string".}

proc decodeInto*[T](n: JsonNode; x: var T) =
  ## Fills `x` from `n` (module doc).
  when T is JsonNode:
    x = n
  elif T is string:
    x = if not n.isNil and n.kind == JString: n.str else: ""
  elif T is bool:
    x = not n.isNil and n.kind == JBool and n.bval
  elif T is SomeInteger:
    noInexactInt64(T)
    x = if n.isNil: T(0)
        elif n.kind == JInt: T(n.num)
        elif n.kind == JFloat: T(n.fnum)
        else: T(0)
  elif T is SomeFloat:
    x = if n.isNil: T(0)
        elif n.kind == JFloat: T(n.fnum)
        elif n.kind == JInt: T(n.num)
        else: T(0)
  elif T is enum:
    x = low(T)
    if not n.isNil and n.kind == JString:
      for e in T:
        if $e == n.str:
          x = e
          break
  elif T is Option:
    if n.isNil or n.kind == JNull:
      x = none(typeof(x.get))
    else:
      var v: typeof(x.get)
      decodeInto(n, v)
      x = some(v)
  elif T is seq:
    x.setLen(0)
    if not n.isNil and n.kind == JArray:
      for e in n.elems:
        var v: typeof(x[0])
        decodeInto(e, v)
        x.add v
  elif T is ref:
    new(x)
    decodeInto(n, x[])
  elif T is object:
    for name, field in x.fieldPairs:
      decodeInto((if not n.isNil and n.kind == JObject: n.getOrDefault(name) else: nil), field)
  else:
    {.error: "json_decode: unsupported type " & $T.}

proc fromJsonLite*[T](n: JsonNode): T =
  ## `n` decoded as a `T` (module doc).
  decodeInto(n, result)

when defined(js):
  import std/[jsffi, tables]

  proc toJsValue(n: JsonNode): JsObject =
    if n.isNil: return jsNull
    case n.kind
    of JNull: result = jsNull
    of JBool: result = toJs(n.bval)
    of JInt: result = toJs(float(n.num))
    of JFloat: result = toJs(n.fnum)
    of JString: result = toJs(cstring(n.str))
    of JArray:
      result = newJsObject()
      {.emit: [result, " = [];"].}
      for e in n.elems:
        let v = toJsValue(e)
        {.emit: [result, ".push(", v, ");"].}
    of JObject:
      result = newJsObject()
      for k, v in n.fields:
        result[cstring(k)] = toJsValue(v)

  proc jsonStringify*(v: JsObject): string =
    ## `JSON.stringify(v)`.
    var t: cstring
    {.emit: [t, " = JSON.stringify(", v, ");"].}
    $t

  proc toJsAny*[T](v: T): JsObject =
    ## `v` as the JS value its JSON is (the inverse of `decodeInto`): a
    ## request body built without a `JsonNode` tree (`jsonStringify`).
    when T is JsonNode:
      result = toJsValue(v)
    elif T is string:
      result = toJs(cstring(v))
    elif T is bool:
      result = toJs(v)
    elif T is SomeInteger:
      noInexactInt64(T)
      result = toJs(float(v))
    elif T is SomeFloat:
      result = toJs(v)
    elif T is enum:
      result = toJs(cstring($v))
    elif T is Option:
      result = if v.isSome: toJsAny(v.get) else: jsNull
    elif T is seq:
      result = newJsObject()
      {.emit: [result, " = [];"].}
      for e in v:
        let x = toJsAny(e)
        {.emit: [result, ".push(", x, ");"].}
    elif T is object:
      result = newJsObject()
      for name, field in v.fieldPairs:
        result[cstring(name)] = toJsAny(field)
    else:
      {.error: "json_decode: unsupported type " & $T.}

  proc jsonText*(n: JsonNode): string =
    ## `n` as JSON text, by the browser's `JSON.stringify` (std/json's `$`
    ## carries its own serializer and escaper, which a size-budgeted bundle
    ## need not: the request bodies of the generated clients use this).
    let v = toJsValue(n)
    var t: cstring
    {.emit: [t, " = JSON.stringify(", v, ");"].}
    $t
