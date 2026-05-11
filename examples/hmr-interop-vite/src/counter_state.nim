## examples/hmr-interop-vite/src/counter_state.nim
##
## A separate ViewModel module imported by counter.nim. Exists so
## the Playwright spec can prove the plugin's *transitive* Nim
## dependency tracking works: edit this file and Vite re-runs the
## compile on counter.nim and triggers HMR — even though Vite
## itself doesn't know what a `.nim` import edge looks like.
##
## Module-name note: this is called `counter_state` rather than
## `counter_vm` because Nim folds underscore + case differences,
## so a `counter_vm` module would conflict with a `counterVm`
## variable binding in counter.nim.

import isonim/core/signals

type
  CounterVm* = ref object
    count*: Signal[int]
    label*: Signal[string]

proc newCounterVm*(initialLabel: string = "clicks"): CounterVm =
  CounterVm(
    count: signals.createSignal(0),
    label: signals.createSignal(initialLabel))
