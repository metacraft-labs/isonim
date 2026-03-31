## Root component for the IsoNim demo app.
## Assembles all sub-components with error boundary and context provider.

import isonim/core/[owner, context]
import isonim/testing/mock_dom
import isonim/dsl/components
import task_store
import components

proc renderApp*(renderer: MockRenderer; parent: MockNode) =
  ## Renders the full app tree into the given parent node.
  ## Sets up error boundary, creates the task store, provides context,
  ## and renders all sub-components.
  errorBoundary(renderer, parent,
    proc(): MockNode =
      let appDiv = renderer.createElement("div")
      renderer.setAttribute(appDiv, "class", "app")

      let store = createTaskStore()
      provideTaskStore(store)

      renderTaskHeader(renderer, appDiv, store)
      renderTaskList(renderer, appDiv, store)
      renderTaskFooter(renderer, appDiv, store)
      renderEffectLog(renderer, appDiv, store)

      appDiv
    ,
    proc(err: ref CatchableError): MockNode =
      let errDiv = renderer.createElement("div")
      renderer.setAttribute(errDiv, "class", "error")

      let h2 = renderer.createElement("h2")
      renderer.setTextContent(h2, "Something went wrong")
      renderer.appendChild(errDiv, h2)

      let p = renderer.createElement("p")
      renderer.setTextContent(p, err.msg)
      renderer.appendChild(errDiv, p)

      errDiv
  )
