## task_app.nim — High-level task manager app with reactive rendering.
##
## Uses signal-based TaskStore for state, control-flow components (show,
## forEachKeyed) for reactive list/conditional rendering, and compile-time
## control module selection for branded vs native controls.
##
## Usage:
##   -d:nativeControls + -d:ios — iOS native controls
##   -d:nativeControls + -d:android — Android native controls
##   (default) — branded cross-platform rendering

import isonim/components/task_manager
import isonim/core/[signals, computation]
import isonim/dsl/components

when defined(nativeControls):
  when defined(ios):
    import isonim/components/native_ios_controls
  elif defined(android):
    import isonim/components/native_android_controls
  else:
    import isonim/components/native_ios_controls
else:
  import isonim/components/branded_controls

# Re-export types so callers only need task_app.
export task_manager

proc renderApp*[R, E](r: R; store: TaskStore): E =
  ## Render the full task manager app with reactive updates.
  ## The tree is built once; signals drive fine-grained updates.
  initTheme()

  let root = createAppRoot[R, E](r)

  # Title
  let title = createTitle[R, E](r, "Tasks")
  r.appendChild(root, title)

  # Input row
  let inputRow = createInputRow[R, E](r, "What needs to be done?",
    proc(text: string) = store.addTask(text))
  r.appendChild(root, inputRow)

  # Task list / empty state — reactive via show + forEachKeyed
  show(r, root,
    proc(): bool = store.filteredTasks.val.len > 0,
    proc(): E =
      let list = createTaskList[R, E](r)
      forEachKeyed(r, list,
        proc(): seq[TaskData] = store.filteredTasks.val,
        proc(item: proc(): TaskData, index: proc(): int): E =
          let taskId = proc(): int = item().id
          createTaskRow[R, E](r, item,
            onToggle = proc() = store.toggleTask(taskId()),
            onDelete = proc() = store.deleteTask(taskId()))
      )
      list
    ,
    proc(): E =
      createEmptyState[R, E](r, "No tasks yet.\nTap + to add one.")
  )

  # Filter bar — reactive via accessor
  let filterBar = createFilterBar[R, E](r,
    proc(): FilterMode = store.filter.val,
    proc(f: FilterMode) = store.setFilter(f))
  r.appendChild(root, filterBar)

  # Clear completed button — reactive via accessor
  let clearBtn = createClearButton[R, E](r,
    proc(): bool = store.completedCount.val > 0,
    proc() = store.clearCompleted())
  r.appendChild(root, clearBtn)

  root
