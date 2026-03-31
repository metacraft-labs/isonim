## isonim/ssr/markers.nim
##
## Hydration marker emission: data-hk attributes and generateHydrationScript.
## Inserts markers into SSR output that the client uses for hydration.

var hydrationCounter {.threadvar.}: int

proc ssrHydrationKey*(): string =
  ## Returns the next hydration key and increments counter.
  ## Called during SSR to mark dynamic elements.
  inc hydrationCounter
  result = " data-hk=\"" & $hydrationCounter & "\""

proc resetHydrationCounter*() =
  ## Resets the hydration counter to zero. Called at start of renderToString.
  hydrationCounter = 0

type
  HydrationScript* = object
    ## Marker type for the hydration script element.
    nonce*: string

proc generateHydrationScript*(eventNames: seq[string] = @["click", "input"];
                              nonce: string = ""): string =
  ## Generates the inline <script> that initializes window._$HY.
  ## This script captures events on hydration-marked elements before
  ## the client-side framework loads, then replays them after hydration.
  result = "<script"
  if nonce.len > 0:
    result.add " nonce=\"" & nonce & "\""
  result.add ">window._$HY||(e=>{let t=e=>e&&e.hasAttribute&&(e.hasAttribute(\"data-hk\")?e:t(e.host&&e.host.nodeType?e.host:e.parentNode));[\""
  for i, name in eventNames:
    if i > 0: result.add "\",\""
    result.add name
  result.add "\"].forEach((o=>document.addEventListener(o,(o=>{if(!e.events)return;let s=t(o.composedPath&&o.composedPath()[0]||o.target);s&&!e.completed.has(s)&&e.events.push([s,o])}))))})(_$HY={events:[],completed:new WeakSet,r:{},fe(){}});</script><!--xs-->"
