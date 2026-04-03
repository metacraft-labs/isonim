## JS-native Map and Set bindings for the JS backend.
## Zero-overhead: each proc compiles to a direct JS method call.
## Used instead of std/tables on the JS target to avoid compiling
## Nim's hash table implementation (~40KB) into the JS bundle.

when not defined(js):
  {.error: "js_collections.nim is JS-only".}

type
  JsMap*[K, V] {.importc: "Map".} = ref object
  JsSet*[T] {.importc: "Set".} = ref object

proc newJsMap*[K, V](): JsMap[K, V] {.importcpp: "new Map()".}
proc set*[K, V](m: JsMap[K, V], key: K, val: V) {.importcpp: "#.set(#, #)".}
proc get*[K, V](m: JsMap[K, V], key: K): V {.importcpp: "#.get(#)".}
proc has*[K, V](m: JsMap[K, V], key: K): bool {.importcpp: "#.has(#)".}
proc delete*[K, V](m: JsMap[K, V], key: K): bool {.importcpp: "#.delete(#)", discardable.}
proc del*[K, V](m: JsMap[K, V], key: K) {.importcpp: "void #.delete(#)".}
proc clear*[K, V](m: JsMap[K, V]) {.importcpp: "#.clear()".}
proc len*[K, V](m: JsMap[K, V]): int {.importcpp: "#.size".}

# Nim-friendly aliases
proc `[]`*[K, V](m: JsMap[K, V], key: K): V {.importcpp: "#.get(#)".}
proc `[]=`*[K, V](m: JsMap[K, V], key: K, val: V) {.importcpp: "#.set(#, #)".}
proc contains*[K, V](m: JsMap[K, V], key: K): bool {.importcpp: "#.has(#)".}

proc keysSeq*[K, V](m: JsMap[K, V]): seq[K] =
  ## Returns all keys as a seq. Useful when you need to iterate and
  ## potentially mutate the map (e.g. delete entries).
  result = @[]
  {.emit: [m, ".forEach(function(v, k) { ", result, ".push(k); });"].}

iterator keys*[K, V](m: JsMap[K, V]): K =
  let ks = keysSeq(m)
  for k in ks:
    yield k

# --- JsArray: native JS array (reference semantics, no nimCopy) ---

type JsArray*[T] {.importc: "Array".} = ref object

proc newJsArray*[T](): JsArray[T] {.importcpp: "[]".}
proc newJsArray*[T](len: int): JsArray[T] {.importcpp: "new Array(#)".}
proc `[]`*[T](a: JsArray[T], i: int): T {.importcpp: "#[#]".}
proc `[]=`*[T](a: JsArray[T], i: int, v: T) {.importcpp: "#[#] = #".}
proc len*[T](a: JsArray[T]): int {.importcpp: "#.length".}
proc add*[T](a: JsArray[T], v: T) {.importcpp: "#.push(#)".}
proc push*[T](a: JsArray[T], v: T) {.importcpp: "#.push(#)".}
proc pop*[T](a: JsArray[T]): T {.importcpp: "#.pop()".}
proc splice*[T](a: JsArray[T], start: int, deleteCount: int) {.importcpp: "#.splice(#, #)".}
proc `high`*[T](a: JsArray[T]): int {.importcpp: "(#.length - 1)".}
proc setLen*[T](a: JsArray[T], newLen: int) {.importcpp: "#.length = #".}

proc swap*[T](a: JsArray[T], i, j: int) =
  ## Swap two elements in-place. No copy, just reference swap.
  {.emit: ["var _t = ", a, "[", i, "]; ", a, "[", i, "] = ", a, "[", j, "]; ", a, "[", j, "] = _t;"].}

proc delete*[T](a: JsArray[T], i: int) =
  ## Remove element at index i (shifts remaining elements).
  a.splice(i, 1)

iterator items*[T](a: JsArray[T]): T =
  for i in 0 ..< a.len:
    yield a[i]

iterator pairs*[T](a: JsArray[T]): (int, T) =
  for i in 0 ..< a.len:
    yield (i, a[i])

proc toSeq*[T](a: JsArray[T]): seq[T] =
  ## View a JsArray as a Nim seq. On JS both are the same underlying array.
  ## This is a zero-cost cast, not a copy.
  {.emit: [result, " = ", a, ";"].}

proc toJsArray*[T](s: seq[T]): JsArray[T] =
  ## View a Nim seq as a JsArray. Zero-cost cast on JS.
  {.emit: [result, " = ", s, ";"].}

proc newJsSet*[T](): JsSet[T] {.importcpp: "new Set()".}
proc incl*[T](s: JsSet[T], val: T) {.importcpp: "#.add(#)".}
proc contains*[T](s: JsSet[T], val: T): bool {.importcpp: "#.has(#)".}
proc delete*[T](s: JsSet[T], val: T): bool {.importcpp: "#.delete(#)", discardable.}
proc clear*[T](s: JsSet[T]) {.importcpp: "#.clear()".}
proc len*[T](s: JsSet[T]): int {.importcpp: "#.size".}
