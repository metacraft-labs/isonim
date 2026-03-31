## IsoNim Hello World demo
##
## A minimal example that renders a greeting into the DOM.

import isonim/web/client
import isonim/web/dom_api

proc app(): Node =
  let el = tmpl("<div><h1></h1></div>")()
  let h1 = el.firstChild
  insert(h1, cstring"Hello, IsoNim!")
  el

discard render(app, document.getElementById("app"))
