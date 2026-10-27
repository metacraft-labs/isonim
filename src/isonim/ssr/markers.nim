## isonim/ssr/markers.nim
##
## Hydration marker emission: `data-hk` keys and `generateHydrationScript`.
##
## Keys. Inside a *hydratable render* every element the `ui:` DSL emits
## (string mode and `uiWrite` stream mode) carries `data-hk="<key>"`, where
## `<key>` is `<renderId><n>` and `n` counts the render's elements from 1 in
## document (pre-)order. The client's `hydrate` counts its `createElement`
## calls the same way (`rxcore.getHydrationKey`), so the n-th element the
## client creates adopts the n-th element the server rendered (IsoNim.md
## § Hydration).
##
## A hydratable render is the extent of `renderToString`, `renderToStream`,
## `renderToStringAsync` and `renderToOutputStream`, or of an explicit
## `withHydrationKeys` block. Outside one, `ui:` emits no keys: an e-mail body
## or an HTML fragment built with `ui:` is not a page a client hydrates.
## An element written with `hydrate = true` (or `needsId = true`) carries a
## key even outside a hydratable render.
##
## Keys are taken in evaluation order, so markup must be produced where it
## appears: a component whose HTML is computed into a variable *before* the
## enclosing `ui:` block (rather than called inline, e.g. through `raw`)
## takes its keys before its ancestors and will not match the client.

when defined(isonimStableIds):
  import ../dsl/stable_ids

var hydrationCounter {.threadvar.}: int
var hydrationActive {.threadvar.}: bool
var hydrationPrefix {.threadvar.}: string

type
  HydrationKeyScope* = object
    ## The key state a hydratable render replaced, restored when it ends.
    when defined(isonimStableIds):
      stableScope: StableRenderScope
    counter: int
    active: bool
    prefix: string

proc nextHydrationKey*(): string =
  ## Advances the render's element counter and returns the element's key.
  inc hydrationCounter
  result = hydrationPrefix & $hydrationCounter

proc hydrationKeysActive*(): bool =
  ## True inside a hydratable render.
  hydrationActive

proc ssrHydrationKey*(force = false): string =
  ## The ` data-hk="<key>"` attribute of the next element, or "" outside a
  ## hydratable render (unless `force`: the element asked for a key with
  ## `hydrate = true`).
  if hydrationActive or force:
    result = " data-hk=\"" & nextHydrationKey() & "\""

proc resetHydrationCounter*() =
  ## Restarts the element count of the current render.
  hydrationCounter = 0

proc beginHydratableRender*(renderId = ""): HydrationKeyScope =
  ## Starts a hydratable render: keys on, counted from 1, prefixed with
  ## `renderId`. Returns the state to give back to `endHydratableRender`.
  result = HydrationKeyScope(counter: hydrationCounter, active: hydrationActive,
                             prefix: hydrationPrefix)
  when defined(isonimStableIds):
    result.stableScope = beginStableRender()
  hydrationCounter = 0
  hydrationActive = true
  hydrationPrefix = renderId

proc endHydratableRender*(saved: HydrationKeyScope) =
  ## Ends the hydratable render begun by `beginHydratableRender`.
  when defined(isonimStableIds):
    endStableRender(saved.stableScope)
  hydrationCounter = saved.counter
  hydrationActive = saved.active
  hydrationPrefix = saved.prefix

template withHydrationKeys*(renderId: string; body: untyped): untyped =
  ## Runs `body` as a hydratable render (for a renderer that produces its
  ## page without `renderToString` and friends).
  let savedKeyScope = beginHydratableRender(renderId)
  try:
    body
  finally:
    endHydratableRender(savedKeyScope)

type
  HydrationScript* = object
    ## Marker type for the hydration script element.
    nonce*: string

const defaultHydrationEvents* = @["click", "input"]
  ## The events the bootstrap records before hydration by default.

const recordingHydrationEvents* = @["click", "input", "change", "submit", "keydown"]
  ## Expanded capture list for recording sessions.

proc generateHydrationScript*(eventNames: seq[string] = defaultHydrationEvents;
                              nonce: string = ""): string =
  ## Generates the inline <script> that initializes window._$HY.
  ##
  ## It records the listed events, on any element inside server-rendered
  ## markup (`data-hk`), until the client's `hydrate` takes the queue and
  ## replays it (IsoNim.md § Hydration). `_$HY` is created once: a second
  ## copy of the script on the same page does nothing.
  result = "<script"
  if nonce.len > 0:
    result.add " nonce=\"" & nonce & "\""
  result.add ">"
  when defined(isonimInternalReplayReads):
    # Internal preparation only. Ordinary/recordable capture scripts retain
    # their original bytes and never even look up a private selector property.
    result.add "if(Object.getOwnPropertyDescriptor(globalThis,'__isonimInternalReadReplaySelected')?.value?.internalReadReplay===true&&globalThis.__isonimInternalReadReplaySelected.selected())throw new Error(\"internal read Replay does not support prehydration capture\");"
  result.add "window._$HY||(e=>{let t=e=>e&&e.hasAttribute&&(e.hasAttribute(\"data-hk\")?e:t(e.host&&e.host.nodeType?e.host:e.parentNode));[\""
  for i, name in eventNames:
    if i > 0: result.add "\",\""
    result.add name
  result.add """"].forEach(type=>document.addEventListener(type,ev=>{
    if(!e.events)return;
    const target=ev.composedPath&&ev.composedPath()[0]||ev.target;
    const el=t(target);
    if(!el||e.completed.has(el))return;
    const snapshot={};
    for(const key of ['key','code','ctrlKey','shiftKey','altKey','metaKey','clientX','clientY','button']){
      const v=ev[key]; if(['string','number','boolean'].includes(typeof v))snapshot[key]=v;
    }
    if(target){
      if(typeof target.value==='string')snapshot.value=target.value;
      else if(target.isContentEditable)snapshot.textContent=target.textContent;
      if(typeof target.checked==='boolean')snapshot.checked=target.checked;
    }
    e.events.push([el,ev,snapshot]);
  }));})(_$HY={events:[],completed:new WeakSet,r:{},fe(){}});</script><!--xs-->"""
