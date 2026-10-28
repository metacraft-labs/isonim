## Genuine-browser delegated clear fixture. JS functions below only expose
## receiver/argument observations; actual traversal, registration and removal
## execute IsoNim's compiled events module and native Chromium EventTarget.
## No DOM/event dispatcher mock is used. Separate foreign, direct and nondet
## callbacks ensure clearing cannot pass by removing every document listener.
import std/jsffi
import isonim/web/[events, dom_api]
import isonim/core/nondet

var disposeObserved: ListenerDisposer

proc setup() {.exportc: "dcSetup".} =
  {.emit: """
  globalThis.dcCalls=[];
  document.getElementById('child')['$$dc-main']=function(e){
    dcCalls.push({who:'child',receiver:this.id,same:e===globalThis.dcEvent});
  };
  document.getElementById('parent')['$$dc-main']=function(data,e){
    dcCalls.push({who:'parent',receiver:this.id,same:e===globalThis.dcEvent,data:data===globalThis.dcData});
  };
  document.getElementById('parent')['$$dc-mainData']=globalThis.dcData={sentinel:42};
  document.getElementById('child')['$$dc-other']=function(e){
    dcCalls.push({who:'other',receiver:this.id,same:e===globalThis.dcEvent});
    e.cancelBubble=true;
  };
  document.getElementById('parent')['$$dc-other']=function(){dcCalls.push({who:'unexpected-parent'});};
  """.}

proc registerNative() {.exportc: "dcRegisterNative".} =
  delegateEvents([cstring"dc-main", cstring"dc-main", cstring"dc-other"])

proc registerStrings() {.exportc: "dcRegisterStrings".} =
  delegateEvents(["dc-other", "dc-main", "dc-other"])

proc clear() {.exportc: "dcClear".} = clearDelegatedEvents()

proc registerObserved() {.exportc: "dcRegisterObserved".} =
  disposeObserved = nondet.listen(toJs(document), "dc-main", proc(e: Event) =
    {.emit: "globalThis.dcNondet++;".})

proc removeObserved() {.exportc: "dcRemoveObserved".} =
  if disposeObserved != nil: disposeObserved()
