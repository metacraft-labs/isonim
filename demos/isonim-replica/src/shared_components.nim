## Shared isomorphic components for the IsoNim demo app.
##
## These components use `isomorphicUi` to compile to either:
## - Client mode: element tree via renderer API (MockRenderer, browser DOM, etc.)
## - SSR mode: HTML strings (when compiled with `-d:isServer`)
##
## This demonstrates the key SolidJS-native pattern: write once, render anywhere.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/ssr/escape
import isonim/ssr/renderer
import task_store

when not defined(isServer):
  import isonim/testing/mock_dom

# ---------------------------------------------------------------------------
# Simple isomorphic components using isomorphicUi
# ---------------------------------------------------------------------------

proc pageHeader*(renderer: auto): auto =
  ## Static page header -- same output in SSR and client modes.
  isomorphicUi(renderer):
    header(class = "page-header"):
      h1: text "IsoNim Task Manager"
      p(class = "subtitle"):
        text "A reactive UI demo -- same code, server and client"

proc taskCountBadge*(renderer: auto; count: int): auto =
  ## Renders a count badge. In SSR mode, evaluates count once.
  ## In client mode, count should be passed from a signal read.
  isomorphicUi(renderer):
    span(class = "badge"):
      text $count

proc emptyState*(renderer: auto): auto =
  ## Empty state placeholder.
  isomorphicUi(renderer):
    tdiv(class = "empty-state"):
      p: text "No tasks yet"
      p(class = "hint"):
        text "Add your first task above"

# ---------------------------------------------------------------------------
# SSR-specific rendering using bare `ui:` blocks (no renderer arg)
# ---------------------------------------------------------------------------

proc renderTaskListSsr*(store: TaskStore): string =
  ## Server-side renders the full task list.
  ## Uses ui for structure, ssrFor for iteration.
  let tasks = store.filteredTasks.val
  if tasks.len == 0:
    return ui:
      p(class = "empty"):
        text "No tasks"

  ui:
    ul(class = "task-list"):
      raw ssrFor(tasks, proc(task: Task, index: int): string =
        let doneClass = if task.done: "completed" else: ""
        ui:
          li(class = doneClass):
            input(ttype = "checkbox")
            span: text task.text
            button(class = "remove"):
              text "x"
      )

proc renderTaskFooterSsr*(store: TaskStore): string =
  ## Server-side renders the footer with counts and filters.
  let taskCount = store.tasks.val.len
  if taskCount == 0:
    return ""

  let ac = store.activeCount.val
  let suffix = if ac != 1: "s" else: ""
  let countText = $ac & " item" & suffix & " left"

  ui:
    footer(class = "task-footer"):
      span: text countText
      tdiv(class = "filters"):
        button(class = "selected"):
          text "all"
        button:
          text "active"
        button:
          text "completed"

proc renderFullPageSsr*(store: TaskStore): string =
  ## Full-page SSR rendering of the task manager.
  ## Demonstrates `ui:` composing multiple components.
  let pageHeaderHtml = ui:
    header(class = "page-header"):
      h1: text "IsoNim Task Manager"
      p(class = "subtitle"):
        text "A reactive UI demo -- same code, server and client"
  let taskHeaderHtml = ui:
    header:
      h1: text "Task Manager"
      form:
        input(ttype = "text", placeholder = "What needs to be done?")
        button(ttype = "submit"):
          text "Add"
  let taskListHtml = renderTaskListSsr(store)
  let footerHtml = renderTaskFooterSsr(store)
  ui:
    tdiv(class = "app"):
      raw pageHeaderHtml
      section:
        raw taskHeaderHtml
        raw taskListHtml
      raw footerHtml
