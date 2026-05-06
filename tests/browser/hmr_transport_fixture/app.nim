## tests/browser/hmr_transport_fixture/app.nim
##
## A tiny app that demonstrates the full HMR loop: the runtime is
## connected to the SSE transport via `installSseTransport`. When the
## dev server pushes an `update` event, the new bundle is loaded by
## script tag, its module-init registrations run, and slots whose hash
## changed get rewritten. No further test-side glue.
##
## Built twice during test setup:
##   `nim js -d:isonimHmr -o:before.js app.nim`
##   `nim js -d:isonimHmr -d:transportFixtureAfter -o:after.js app.nim`
##
## The dev server's rebuild command is `cp after.js main.js`; that
## simulates "user edited the source" without invoking the Nim compiler
## inside the test (which would be slow and brittle).

when not defined(js):
  {.error: "transport fixture requires the JS backend".}

import std/jsffi
import isonim/web/dom_api
import isonim/web/client
import isonim/web/hmr
import isonim/web/hmr_component
import isonim/web/hmr_sse

const isAfter = defined(transportFixtureAfter)

proc heading*(): Node {.uiComponent.} =
  let h = document.createElement(cstring"h1")
  h.setAttribute(cstring"id", cstring"heading")
  when isAfter:
    h.textContent = cstring"AFTER"
  else:
    h.textContent = cstring"BEFORE"
  return h.Node

proc app*(): Node {.uiComponent.} =
  let root = document.createElement(cstring"div")
  root.setAttribute(cstring"id", cstring"root")
  root.Node.appendChild(heading())
  return root.Node

bootstrapHmr()

proc main() =
  let container = document.getElementById(cstring"app")
  discard renderHot(app, container)
  # Connect to the dev server's SSE endpoint. The default URL works.
  discard installSseTransport()

main()
