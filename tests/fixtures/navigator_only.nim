## A program that renders its own pages: it installs its own navigator and
## navigates through IsoNim's global `navigate()`. `just test-js` runs it and
## checks that its output does not contain the router (`currentPath`,
## `updateMatch`, `matchChain`): installing a navigator must not compile
## `Router` in (isonim/routing/navigator.nim).

import isonim/routing/navigate

var shown: seq[string]
setNavigator(proc (path: string; replace: bool) = shown.add(path))
navigate("/first")
navigate("/second", replace = true)
doAssert shown == @["/first", "/second"]
echo "navigator_only: ok"
