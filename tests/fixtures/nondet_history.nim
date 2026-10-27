## Exercise the actual private observation and public facades. Browser tests
## delegate to native History; partial-host tests only model missing metadata
## and throwing host accessors, not browser URL resolution.
import std/[json, options]
import isonim/core/nondet {.all.}

proc observeHistory(name, url: cstring): cstring =
  let observed = historyObservation($name, $url)
  if observed.browserUrl.isSome: cstring($(%observed.browserUrl.get()))
  else: cstring("null")
proc publicPush(url: cstring) = pushState($url)
proc publicReplace(url: cstring) = replaceState($url)
proc publicLocation(): cstring = cstring(location())
proc publicStorage(key, value: cstring) = storageSet($key, $value)
{.emit: "globalThis.xrHistory = {observe: `observeHistory`, push: `publicPush`, replace: `publicReplace`, pathname: `publicLocation`, storage: `publicStorage`};".}
