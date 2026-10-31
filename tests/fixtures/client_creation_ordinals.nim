## Actual renderer/SSR/hydration under Chromium. Only the test's loopback HTTP
## origin replaces external hosting; DOM, hydration and metadata stay native.
when defined(js):
  import isonim/web/[web_renderer, dom_api, hydration]
  import std/jsffi
  import isonim/core/clock
  proc ccContext(): InternalClientCreationOrdinals = newInternalClientCreationOrdinals()
  proc ccCreate(c: InternalClientCreationOrdinals; tag: cstring): Element =
    createInternalClientElement(c, WebRenderer(), $tag)
  proc ccPublic(tag: cstring): Element = WebRenderer().createElement($tag)
  proc ccText(text: cstring): Node = WebRenderer().createTextNode($text)
  proc ccQuery(c: InternalClientCreationOrdinals; e: Element): cstring =
    internalClientCreationOrdinal(c, e)
  proc ccHydrate(c: InternalClientCreationOrdinals; root: Element; tag: cstring): Element =
    hydrate(proc(): Node =
      result = Node(createInternalClientElement(c, WebRenderer(), $tag))
      {.emit: ["globalThis.ccAdopted=", result, ";"].}, root)
    {.emit: [result, "=globalThis.ccAdopted;"].}
  proc ccHandler(e: Element) =
    WebRenderer().addEventListener(e, "click", proc() =
      {.emit: "globalThis.ccHandlerCalls++;".})
  proc ccMeter(enabled: bool) =
    meterEnabled = enabled
    meterCodec = false
    when defined(isonimNoBoundaryMeter):
      meter = default(BoundaryMeter)
    else:
      resetMeter()
  proc ccCount(): int = meter.ops[boCreateElement]
  proc ccClock(): JsObject = cast[JsObject](currentClock)
  {.emit: """
globalThis.cc={context:`ccContext`,create:`ccCreate`,publicCreate:`ccPublic`,
 text:`ccText`,query:`ccQuery`,hydrate:`ccHydrate`,handler:`ccHandler`,
 meter:`ccMeter`,count:`ccCount`,clock:`ccClock`};
globalThis.ccHandlerCalls=0;
""".}
else:
  import isonim/dsl/ui
  import isonim/ssr/[renderer, escape, markers]
  proc content(): string =
    ui:
      section: text "Actual server element"
  echo "<!doctype html><body><main id='root'>"
  echo renderToString(content)
  echo "</main>"
  echo generateHydrationScript()
