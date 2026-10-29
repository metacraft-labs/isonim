## mapping_other.nim
##
## A second exception type named `Overloaded`, for
## t_manifest_mapped_exceptions.nim: the application maps
## `t_manifest_mapped_exceptions.Overloaded`, and this one, whose name is the
## same, must not be answered by that mapping.  It shows the dispatch tests
## the exception's type (`of`), never its name.

type
  Overloaded* = object of CatchableError
    ## Unrelated to the mapped `Overloaded`; only the name is shared.
