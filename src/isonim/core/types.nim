## isonim/core/types.nim
##
## Core type definitions: Accessor[T], Setter[T], ComputationState enum.
## These are the foundational types used throughout the reactive system.
##
## Port of SolidJS signal.ts type definitions.

type
  ComputationState* = enum
    csClean = 0    ## No pending updates
    csStale = 1    ## Definitely needs re-execution
    csPending = 2  ## May need update (ancestor changed)

  Accessor*[T] = proc(): T {.closure.}
  Setter*[T] = proc(value: T) {.closure.}
  EqualityFn*[T] = proc(prev, next: T): bool
