## SSR HTML generation for Playwright E2E tests.
##
## Compiles as a C-target program that:
## 1. Creates a TaskStore with sample data
## 2. Renders the full page via SSR
## 3. Wraps in a complete HTML document with hydration script
## 4. Writes to tests/browser/dist/ssr.html

{.define: isServer.}

import std/os
import isonim/core/signals
import isonim/ssr/[renderer, markers]
import task_store
import shared_components

proc main() =
  let outputDir = currentSourcePath().parentDir / "dist"
  createDir(outputDir)

  let html = renderToString(proc(): string =
    # Create store with sample data inside the reactive root
    let store = createTaskStore()
    store.addTask("Buy groceries")
    store.addTask("Write tests")
    store.addTask("Deploy app")
    # Mark the third task as completed
    let tasks = store.tasks.val
    store.toggleTask(tasks[2].id)

    renderFullPageSsr(store)
  )

  let hydrationScript = generateHydrationScript(
    @["click", "input", "change", "submit"]
  )

  let fullPage = """<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>IsoNim SSR Hydration Test</title>
    <style>
      body {
        font-family: sans-serif;
        max-width: 600px;
        margin: 2rem auto;
      }
      .app {
        padding: 1rem;
      }
      .task-list {
        list-style: none;
        padding: 0;
      }
      .task-list li {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.25rem 0;
      }
      .task-list li.completed span {
        text-decoration: line-through;
        color: #999;
      }
      .task-list li span {
        cursor: pointer;
      }
      .remove {
        background: none;
        border: none;
        color: red;
        cursor: pointer;
        font-size: 1.2rem;
      }
      .task-footer {
        display: flex;
        gap: 1rem;
        align-items: center;
        margin-top: 1rem;
        padding-top: 0.5rem;
        border-top: 1px solid #eee;
      }
      .filters {
        display: flex;
        gap: 0.25rem;
      }
      .filters button.selected {
        font-weight: bold;
        border-color: #333;
      }
      .task-detail {
        background: #f5f5f5;
        padding: 1rem;
        margin-top: 1rem;
        border-radius: 4px;
      }
      .effect-log {
        margin-top: 1rem;
        font-size: 0.875rem;
        color: #666;
      }
      .empty {
        color: #999;
        font-style: italic;
      }
      .error {
        color: red;
      }
      .loading {
        color: #999;
      }
      form {
        display: flex;
        gap: 0.5rem;
        margin-top: 0.5rem;
      }
      form input {
        flex: 1;
        padding: 0.5rem;
      }
      form button {
        padding: 0.5rem 1rem;
      }
    </style>
  </head>
  <body>
    """ & hydrationScript & """
    <div id="root">""" & html & """</div>
    <script src="main.js"></script>
  </body>
</html>
"""

  writeFile(outputDir / "ssr.html", fullPage)
  echo "Generated: " & outputDir / "ssr.html"

main()
