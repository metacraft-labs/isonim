## Exact public bytes across an unused internal define retain the SAME imports.
## A separate arm deliberately imports an inert private module; it tests omission
## and lazy execution, not byte equality after stock module-symbol renumbering.
when defined(storageImport):import isonim/core/private/record_storage
import isonim/core/nondet
proc stPublic():string {.exportc.}=storageGet("ordinary")
