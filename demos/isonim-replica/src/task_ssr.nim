## SSR rendering of the task manager demo app.
## Uses renderToString to produce HTML with hydration markers.

import isonim/core/computation
import isonim/ssr/renderer
import isonim/ssr/escape
import isonim/ssr/markers
import task_store

proc renderTaskApp*(): string =
  ## Renders the task manager as an HTML string using SSR.
  ## Pre-populates with sample data for demonstration.
  renderToString do () -> string:
    var store = createTaskStore()
    # Pre-populate with sample data
    store.addTask("Learn IsoNim")
    store.addTask("Build demo app")

    ssrElement("div", {"class": "app", "id": "app"},
      ssrElement("h1", children = escapeHtml("Task Manager")) &
      ssrElement("div", {"class": "task-list"},
        ssrFor(store.filteredTasks.val, proc(task: Task, i: int): string =
          ssrElement("div", {"class": "task"},
            ssrElement("span", children = escapeHtml(task.text))
          )
        )
      )
    )

proc renderTaskPage*(): string =
  ## Renders a full HTML page with the task app and hydration script.
  let appHtml = renderTaskApp()
  let hydrationScript = generateHydrationScript()
  result = "<!DOCTYPE html><html><head><title>Task Manager</title></head><body>" &
    appHtml & hydrationScript & "</body></html>"
