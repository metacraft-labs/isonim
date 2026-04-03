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

proc newJsSet*[T](): JsSet[T] {.importcpp: "new Set()".}
proc incl*[T](s: JsSet[T], val: T) {.importcpp: "#.add(#)".}
proc contains*[T](s: JsSet[T], val: T): bool {.importcpp: "#.has(#)".}
proc delete*[T](s: JsSet[T], val: T): bool {.importcpp: "#.delete(#)", discardable.}
proc clear*[T](s: JsSet[T]) {.importcpp: "#.clear()".}
proc len*[T](s: JsSet[T]): int {.importcpp: "#.size".}
