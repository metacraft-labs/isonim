## isonim/core/platform.nim
##
## Platform abstraction layer. Provides unified types and factory
## templates for collections and strings that map to:
##   JS backend:  native Map, Set, cstring (zero overhead)
##   C backend:   std/tables, std/sets, string (Nim standard library)
##
## All core modules should `import platform` instead of directly
## importing std/tables, std/sets, or js_collections.

when defined(js):
  import js_collections
  export js_collections

  type
    HashMap*[K, V] = JsMap[K, V]
      ## Key-value map: JS Map on browser, Table on server.
    HashSet*[T] = JsSet[T]
      ## Value set: JS Set on browser, HashSet on server.
    HashMapRef*[K, V] = JsMap[K, V]
      ## Nil-able ref map. On JS, JsMap is already a ref type.
      ## On C, this is TableRef (heap-allocated, nil-able).
    NativeString* = cstring
      ## String type native to the platform: JS string on browser,
      ## Nim string on server.

  template newHashMap*[K, V](): HashMap[K, V] = newJsMap[K, V]()
  template newHashSet*[T](): HashSet[T] = newJsSet[T]()
  template newHashMapRef*[K, V](): HashMapRef[K, V] = newJsMap[K, V]()

  template toNative*(s: string): NativeString = cstring(s)
  template toNative*(s: cstring): NativeString = s

  # NativeString concatenation (JS + operator)
  proc `&`*(a, b: NativeString): NativeString {.importcpp: "(# + #)".}
  proc `&`*(a: NativeString, b: string): NativeString {.importcpp: "(# + #)".}
  proc `&`*(a: string, b: NativeString): NativeString {.importcpp: "(# + #)".}

else:
  import std/tables
  import std/sets
  export tables, sets

  type
    HashMap*[K, V] = Table[K, V]
    HashSet*[T] = sets.HashSet[T]
    HashMapRef*[K, V] = TableRef[K, V]
    NativeString* = string

  template newHashMap*[K, V](): HashMap[K, V] = initTable[K, V]()
  template newHashSet*[T](): HashSet[T] = sets.initHashSet[T]()
  template newHashMapRef*[K, V](): HashMapRef[K, V] = newTable[K, V]()

  template toNative*(s: string): NativeString = s
