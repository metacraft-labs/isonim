## Real Link source projection, key/caller scopes, direct append and native event.
import isonim/web/[web_renderer,dom_api]
import isonim/routing/navigate
import isonim/dsl/stable_ids
import isonim/rxcore
import isonim/core/signals
import std/jsffi
let context=newInternalClientCreationOrdinals()
let routed=newInternalClientRenderer(context)
var rendererArguments,parentArguments,hrefArguments,textArguments:int
proc rendererArgument():InternalClientRenderer =
  inc rendererArguments
  routed
proc parentArgument(parent:Node):Node =
  inc parentArguments
  parent
proc hrefArgument():string =
  inc hrefArguments
  "/next"
proc textArgument():string =
  inc textArguments
  "Next"
proc arguments():seq[int] = @[rendererArguments,parentArguments,hrefArguments,textArguments]
proc links(parent:Node; key:cstring; ordinary:bool) =
  withStableInstance("route-test"):
    withStableKey($key):
      if ordinary: Link(parentArgument(parent),hrefArgument(),textArgument())
      else: internalClientLink(rendererArgument(),parentArgument(parent),hrefArgument(),textArgument())
proc query(e:Element):cstring=internalClientCreationOrdinal(context,e)
proc reset() =
  rendererArguments=0
  parentArguments=0
  hrefArguments=0
  textArguments=0
  meterEnabled=true
  meterCodec=false
  when defined(isonimNoBoundaryMeter): meter=default(BoundaryMeter)
  else: resetMeter()
proc appends():int=meter.ops[boAppendChild]
proc creates():int=meter.ops[boCreateElement]
proc reactive(parent:Element):JsObject =
  let copied=routed
  let tick=createSignal(0)
  var dispose:proc()
  createRoot proc(d:proc()) =
    dispose=d
    createEffect proc() =
      let value=tick.val
      let e=copied.createElement("i")
      copied.setTextContent(e,$value)
      copied.appendChild(parent,e)
  let advance=proc() = tick.val=tick.val+1
  let value=proc():int = tick.val
  {.emit:[result,"={advance:",advance,",dispose:",dispose,",value:",value,"};"].}
{.emit:"globalThis.linkControls={arguments:`arguments`,links:`links`,query:`query`,reset:`reset`,appends:`appends`,creates:`creates`,reactive:`reactive`};".}
