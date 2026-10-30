## Actual WebRenderer ordinary-mode regression; no mocks or private gate.
import isonim/web/web_renderer
import isonim/web/dom_api
import isonim/rxcore
import isonim/dsl/ui
proc publicComponent*(r: WebRenderer): Element =
  ui(r):
    input(`type` = "text", public = true, value = "seed")
discard publicComponent(WebRenderer())
