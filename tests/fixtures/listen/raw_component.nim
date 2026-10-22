## Intentionally raw component registration: live negative control for the lint.
import isonim/web/dom_api
proc rawRegister*(node: Element; cb: EventHandler)
  {.importjs: "#.addEventListener('click',#)".}
