## Fixed finite qualification entry. The conditional negative entries are compiled
## separately; none is executed as an admitted application. No alternate DOM.
import isonim/web/[web_renderer,dom_api,client,hydration]
import isonim/dsl/ui
import isonim/routing/navigate
import std/jsffi
when defined(isonimInternalClientRouting):
  let context = newInternalClientCreationOrdinals()
  let r = newInternalClientRenderer(context)
else:
  let r = WebRenderer()
let parent = document.getElementById("root")
proc child[R](renderer:R):Element =
  ui(renderer): button: text "Child"
proc render[R](renderer:R):Element =
  ui(renderer):
    section:
      child(renderer)
      br
      span: text "Fixed entry"
let copy = r
let saved = proc():Element = render(copy)
discard parent.appendChild(saved())
when defined(isonimInternalClientRouting): internalClientLink(r,Node(parent),"/next","Next")
else: Link(Node(parent),"/next","Next")
when defined(admitRawHtml): r.appendRawHtml(parent,"<b>x</b>")
elif defined(admitInnerHtml): r.setInnerHtml(parent,"<b>x</b>")
elif defined(admitTemplate): discard tmpl(cstring"<b>x</b>")()
elif defined(admitHydrationRaw):
  let rawHost=document.getElementById("raw-root")
  hydrate(proc():Node =
    let adopted=r.createElement("div")
    discard hydrationAppendRaw(Node(adopted),cstring"<b>x</b>")
    Node(adopted),rawHost)
elif defined(admitClone): discard Node(parent).cloneNode(true)
elif defined(admitDirectDom): discard document.createElement(cstring"b")
elif defined(admitOrdinaryRenderer): discard WebRenderer().createElement("b")
elif defined(admitOldLink): Link(Node(parent),"/next","Next")
elif defined(admitForeign):
  {.emit: "document.createElement('b');".}
elif defined(admitHmr):
  import isonim/web/hmr_transport
  applyBundleByScriptTag(cstring"/app.js")
elif defined(admitBracket):
  {.emit: "document['createElement']('b');".}
elif defined(admitAlias):
  {.emit: "var alias=document['createElement'];alias.call(document,'b');".}
elif defined(admitDynamic):
  {.emit: "var memberName=['create','Element'].join('');document[memberName]('b');".}
elif defined(admitConstructor):
  {.emit: "var Parser=DOMParser;new Parser().parseFromString('<b>x</b>','text/html');".}
elif defined(admitCallback):
  {.emit: "globalThis.unreviewedLate=()=>document['createElement']('b');".}
elif defined(admitReflect):
  {.emit: "Reflect.get(document,'createElement').call(document,'b');".}
elif defined(admitUnknownFunction):
  {.emit: "function unreviewedCallback(x){return x;}globalThis.unreviewedCallback=unreviewedCallback;".}
elif defined(admitUnknownInit):
  {.emit: "globalThis.unreviewedInitialization=17;".}
let empty=r.createElement("aside")
r.clearChildren(empty)
when defined(isonimInternalClientRouting):
  proc query(element:Element):cstring = internalClientCreationOrdinal(context,element)
else:
  proc query(element:Element):cstring = nil
{.emit:"globalThis.fixedClientCreation={query:`query`,saved:`saved`,empty:`empty`};".}
