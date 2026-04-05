## isonim/routing/params.nim
##
## RouteParams — route parameters as reactive signals.
## When the URL changes and a param value updates, the corresponding signal
## fires and dependent computations re-run. The signal identity is stable:
## navigating from /users/1 to /users/2 updates the existing signal rather
## than creating a new one.

import std/[tables, strutils]
import ../core/[signals, computation]

type
  RouteParams* = ref object
    table*: Table[string, Signal[string]]

proc newRouteParams*(): RouteParams =
  RouteParams(table: initTable[string, Signal[string]]())

proc get*(p: RouteParams; key: string): Signal[string] =
  ## Get a route param as a reactive signal.
  ## If the param doesn't exist yet, creates a signal with "".
  if key notin p.table:
    p.table[key] = createSignal("")
  p.table[key]

proc getInt*(p: RouteParams; key: string): Memo[int] =
  ## Derived: parse param as int. Updates when the param signal changes.
  ## Returns 0 if the param is empty or not a valid integer.
  let sig = p.get(key)
  createMemo(proc(): int =
    let s = sig.val
    if s.len == 0:
      return 0
    try:
      parseInt(s)
    except ValueError:
      0
  )

proc getAll*(p: RouteParams): seq[(string, string)] =
  ## Get all current param values as a non-reactive snapshot.
  for key, sig in p.table:
    result.add((key, sig.value))

proc updateFrom*(p: RouteParams; pairs: seq[(string, string)]) =
  ## Update param signals in-place from a (name, value) list.
  ## New keys create signals; existing keys update values;
  ## keys not present in `pairs` are set to "".
  var seen: Table[string, bool]
  for (key, value) in pairs:
    seen[key] = true
    if key in p.table:
      p.table[key].val = value
    else:
      p.table[key] = createSignal(value)
  # Clear params that are no longer present
  for key in p.table.keys:
    if key notin seen:
      p.table[key].val = ""
