## Same public imports compare exact emitted bytes with unused private define.
when defined(historyImport):import isonim/core/private/record_history
import isonim/core/nondet
when defined(js):
  proc ordinary(url:string) {.exportc.}=pushState(url)
