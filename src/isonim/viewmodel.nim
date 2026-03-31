## isonim/viewmodel.nim
##
## ViewModel base pattern: reactive stores with typed state enums,
## service injection for mockable dependencies, and helpers for
## creating ViewModels within reactive roots.
##
## Works on both C and JS backends.

import isonim/core/owner

type
  AsyncState* = enum
    ## Generic async operation state.
    asIdle       ## No operation in progress
    asLoading    ## Operation in progress
    asReady      ## Operation completed successfully
    asError      ## Operation failed

  ViewModel* = ref object of RootObj
    ## Base ViewModel: holds a reactive root dispose proc.
    disposeProc*: proc()

proc dispose*(vm: ViewModel) =
  ## Disposes the reactive root owned by this ViewModel.
  if vm.disposeProc != nil:
    vm.disposeProc()
    vm.disposeProc = nil

proc withViewModel*[T: ViewModel](create: proc(dispose: proc()): T): T =
  ## Creates a ViewModel inside a reactive root. The root's dispose
  ## proc is stored on the ViewModel for later cleanup.
  var vm: T
  createRoot proc(dispose: proc()) =
    vm = create(dispose)
    vm.disposeProc = dispose
  result = vm
