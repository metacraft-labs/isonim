## Deliberate existing TestClock/scripted snapshot and explicit platform-hook
## inputs exercise initialization without pretending to be a Replay provider.
## This dependency module runs before the importing entrypoint's nondet import.
import std/json
import isonim/core/clock
import nim_everywhere/backend

when defined(bridgePreselect):
  currentClock = newTestClock(123.25)
  when defined(js): currentClock.bootEnv = newJObject()

var explicitHook*: PlatformBackendHook
when defined(bridgeExplicit):
  explicitHook = PlatformBackendHook(monotonicNowMs: proc(): int64 = 777)
  installBackendHook(explicitHook)
