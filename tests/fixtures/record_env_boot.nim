## Ordinary eager boot is intentionally the actual nondet module initialization.
import std/[json, jsffi]
import isonim/core/nondet
import ./record_env
proc cached(): cstring {.exportc: "envCached".} = cstring($env())
proc cacheOwnership(): cstring {.exportc: "envCacheOwnership".} =
  let first = env()
  let second = env()
  let before = $second
  first["viewport"]["width"] = %99
  first["assignment"]["altered"] = %7
  let after = $env()
  cstring($(%*{"before": before, "second": $second, "after": after}))

# Actual selector/hook identities: the projector must leave both untouched.
import nim_everywhere/backend
type BackendIdentityCheck = proc(): bool
proc backendSnapshot(): BackendIdentityCheck {.exportc: "envBackendSnapshot".} =
  let selected = currentClock
  let hook = currentBackendHook
  result = proc(): bool = currentClock == selected and currentBackendHook == hook
proc backendControl(): bool {.exportc: "envBackendControl".} =
  let selected = currentClock
  let hook = currentBackendHook
  let unchanged = backendSnapshot()
  try:
    install(newTestBackend())
    result = not unchanged()
  finally:
    currentClock = selected
    currentBackendHook = hook
