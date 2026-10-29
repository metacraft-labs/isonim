## Compile-time fixture (tests/test_server_functions.nim): a browser client
## that decodes, or sends, a 64-bit integer field. Built for JS with
## `--jsbigint64:off`, it must fail to compile (json_decode.nim, "64-BIT
## INTEGERS"); with `-d:asString` (the id as a decimal string) it compiles,
## and so does the int64 form with `--jsbigint64:on`.
import std/json
import isonim/routing/json_decode

type
  Liked = object
    when defined(asString):
      postId: string
    else:
      postId: int64
    likeCount: int

let decoded = fromJsonLite[Liked](parseJson("""{"postId": "9007199254740993", "likeCount": 1}"""))
echo decoded.likeCount
echo jsonStringify(toJsAny(decoded))
