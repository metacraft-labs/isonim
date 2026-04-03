## Context providers for IsoNim.
## Allows passing values through the reactive owner tree without prop drilling.

import graph

when defined(js):
  import js_collections
else:
  import std/tables

type
  ContextId = int
  Context*[T] = object
    id: ContextId
    defaultValue: T

  ContextValue[T] = ref object of RootObj
    ## GC-tracked wrapper for context values.
    ## Stored as RootRef in the context table to prevent collection.
    value: T

var nextContextId {.threadvar.}: int

proc createContext*[T](defaultValue: T = default(T)): Context[T] =
  ## Creates a new context type with an optional default value.
  inc nextContextId
  Context[T](id: nextContextId, defaultValue: defaultValue)

proc provide*[T](ctx: Context[T]; value: T) =
  ## Sets a context value on the current owner.
  ## Children of this owner will see this value via useContext.
  if Owner != nil:
    if Owner.contextTable.isNil:
      when defined(js):
        Owner.contextTable = newJsMap[int, RootRef]()
      else:
        Owner.contextTable = newTable[int, RootRef]()
    let wrapped = ContextValue[T](value: value)
    Owner.contextTable[ctx.id] = wrapped

proc useContext*[T](ctx: Context[T]): T =
  ## Reads the context value from the nearest ancestor that provides it.
  ## Returns the default value if no provider is found.
  var current = Owner
  while current != nil:
    if not current.contextTable.isNil and ctx.id in current.contextTable:
      let wrapped = ContextValue[T](current.contextTable[ctx.id])
      return wrapped.value
    current = current.owner
  return ctx.defaultValue
