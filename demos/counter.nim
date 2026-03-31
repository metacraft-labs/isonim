## IsoNim Counter demo
##
## A counter with signal-driven increment/decrement buttons.

import isonim/web/client
import isonim/web/dom_api
import isonim/web/events
import isonim/rxcore

proc app(): Node =
  var count = createSignal(0)
  let el = tmpl("<div><h1></h1><button>-</button><span></span><button>+</button></div>")()
  let h1 = el.firstChild
  let decBtn = h1.nextSibling
  let span = decBtn.nextSibling
  let incBtn = span.nextSibling

  insert(h1, cstring"Counter")
  insert(span, proc(): cstring = cstring($count.val))
  addEventListenerWeb(decBtn, "click", proc(ev: Event) =
    count.val = count.val - 1, delegate = true)
  addEventListenerWeb(incBtn, "click", proc(ev: Event) =
    count.val = count.val + 1, delegate = true)
  delegateEvents(["click"])
  el

discard render(app, document.getElementById("app"))
