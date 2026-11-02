## Actual renderer, DSL, native DOM and hydration. The test's loopback server
## replaces external hosting only. There is no alternate ordinal allocator.
when defined(js):
  import isonim/web/[web_renderer, dom_api, hydration]
  import isonim/dsl/ui
  import isonim/routing/navigate
  import isonim/core/clock
  import std/jsffi
  proc ccContext(): InternalClientCreationOrdinals = newInternalClientCreationOrdinals()
  proc ccCreate(c: InternalClientCreationOrdinals; tag: cstring): Element =
    newInternalClientRenderer(c).createElement($tag)
  proc ccPublic(tag: cstring): Element = WebRenderer().createElement($tag)
  proc ccText(text: cstring): Node = WebRenderer().createTextNode($text)
  proc ccQuery(c: InternalClientCreationOrdinals; e: Element): cstring = internalClientCreationOrdinal(c,e)
  proc ccHydrate(c: InternalClientCreationOrdinals; root: Element; tag: cstring): Element =
    let r = newInternalClientRenderer(c)
    hydrate(proc(): Node =
      result = Node(r.createElement($tag))
      {.emit: ["globalThis.ccAdopted=",result,";"].}, root)
    {.emit: [result,"=globalThis.ccAdopted;"].}
  proc ccHandler(e: Element) =
    WebRenderer().addEventListener(e,"click",proc() =
      {.emit: "globalThis.ccHandlerCalls++;".})
  proc ccMeter(enabled: bool) =
    meterEnabled=enabled
    meterCodec=false
    when defined(isonimNoBoundaryMeter): meter=default(BoundaryMeter)
    else: resetMeter()
  proc ccCount(): int = meter.ops[boCreateElement]
  proc ccClock(): JsObject = cast[JsObject](currentClock)
  proc helper[R](r: R): Element =
    ui(r): button: text "Child"
  proc tree[R](r: R): Element =
    ui(r):
      tdiv:
        helper(r)
        br
        raw helper(r)
        span: text "Sibling"
  proc ccSaved(c: InternalClientCreationOrdinals): JsObject =
    let r=newInternalClientRenderer(c)
    let copy=r
    let saved=proc(): Element = tree(copy)
    {.emit: [result,"=",saved,";"].}
  proc ccLink(c: InternalClientCreationOrdinals; parent: Node) =
    internalClientLink(newInternalClientRenderer(c),parent,"/next","Next")
  proc ccInvalid(tag: cstring): Element =
    default(InternalClientRenderer).createElement($tag)
  proc ccInvalidConstructor(): InternalClientRenderer =
    newInternalClientRenderer(default(InternalClientCreationOrdinals))
  {.emit: """
globalThis.cc={context:`ccContext`,create:`ccCreate`,publicCreate:`ccPublic`,
text:`ccText`,query:`ccQuery`,hydrate:`ccHydrate`,handler:`ccHandler`,meter:`ccMeter`,
count:`ccCount`,clock:`ccClock`,saved:`ccSaved`,link:`ccLink`,invalid:`ccInvalid`,
invalidConstructor:`ccInvalidConstructor`};globalThis.ccHandlerCalls=0;
""".}
else:
  import isonim/dsl/ui
  import isonim/ssr/[renderer,escape,markers]
  proc content(): string = ui: section: text "Actual server element"
  echo "<!doctype html><body><main id='root'>"
  echo renderToString(content)
  echo "</main>"
  echo generateHydrationScript()
