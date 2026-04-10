## IsoNim Editor — ViewModels for the simulated user project (task manager).
##
## These are the components the editor will display and edit.
## Pure state machines — no CSS, no colors, no rendering.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import isonim/components/task_manager

export task_manager

# ===========================================================================
# Display state enums (pure logical states, no presentation)
# ===========================================================================

type
  TaskDisplayState* = enum
    tdsActive
    tdsCompleted
    tdsEditing
    tdsSaving
    tdsError

  FilterOption* = object
    mode*: FilterMode
    label*: string
    active*: bool

# ===========================================================================
# TaskRowVM
# ===========================================================================

type TaskRowVM* = ref object of ViewModel
  task*: Signal[TaskData]
  isEditing*: Signal[bool]
  saveStatus*: Signal[AsyncState]
  displayState*: Memo[TaskDisplayState]
  isCompleted*: Memo[bool]

proc createTaskRowVM*(task: TaskData): TaskRowVM =
  let taskSig = createSignal(task)
  let isEditing = createSignal(false)
  let saveStatus = createSignal(asIdle)

  let isCompleted = createMemo[bool](proc(): bool =
    taskSig.val.completed
  )

  let displayState = createMemo[TaskDisplayState](proc(): TaskDisplayState =
    if saveStatus.val == asLoading: tdsSaving
    elif saveStatus.val == asError: tdsError
    elif isEditing.val: tdsEditing
    elif taskSig.val.completed: tdsCompleted
    else: tdsActive
  )

  TaskRowVM(task: taskSig, isEditing: isEditing, saveStatus: saveStatus,
            displayState: displayState, isCompleted: isCompleted)

# ===========================================================================
# InputRowVM
# ===========================================================================

type InputRowVM* = ref object of ViewModel
  text*: Signal[string]
  placeholder*: string
  isSubmitting*: Signal[bool]

proc createInputRowVM*(placeholder: string = "What needs to be done?"): InputRowVM =
  InputRowVM(text: createSignal(""), placeholder: placeholder,
             isSubmitting: createSignal(false))

# ===========================================================================
# FilterBarVM
# ===========================================================================

type FilterBarVM* = ref object of ViewModel
  currentFilter*: Signal[FilterMode]
  options*: Memo[seq[FilterOption]]

proc createFilterBarVM*(store: TaskStore): FilterBarVM =
  let currentFilter = store.filter

  let options = createMemo[seq[FilterOption]](proc(): seq[FilterOption] =
    let f = currentFilter.val
    @[
      FilterOption(mode: fmAll, label: "All", active: f == fmAll),
      FilterOption(mode: fmActive, label: "Active", active: f == fmActive),
      FilterOption(mode: fmCompleted, label: "Completed", active: f == fmCompleted),
    ]
  )

  FilterBarVM(currentFilter: currentFilter, options: options)

# ===========================================================================
# TaskAppVM — composes all child VMs
# ===========================================================================

type TaskAppVM* = ref object of ViewModel
  store*: TaskStore
  input*: InputRowVM
  filterBar*: FilterBarVM
  hasTasks*: Memo[bool]
  hasCompletedTasks*: Memo[bool]

proc createTaskAppVM*(): TaskAppVM =
  let store = createTaskStore()
  let input = createInputRowVM()
  let filterBar = createFilterBarVM(store)

  let hasTasks = createMemo[bool](proc(): bool =
    store.filteredTasks.val.len > 0
  )

  let hasCompletedTasks = createMemo[bool](proc(): bool =
    store.completedCount.val > 0
  )

  TaskAppVM(store: store, input: input, filterBar: filterBar,
            hasTasks: hasTasks, hasCompletedTasks: hasCompletedTasks)

# ===========================================================================
# Mock data providers
# ===========================================================================

type TaskMockProvider* = object
  ## Pre-populated task data for story/flow scenarios.
  name*: string
  tasks*: seq[TaskData]
  filter*: FilterMode

proc emptyProvider*(): TaskMockProvider =
  TaskMockProvider(name: "Empty", tasks: @[], filter: fmAll)

proc activeWorkspaceProvider*(): TaskMockProvider =
  TaskMockProvider(name: "Active Workspace", filter: fmAll, tasks: @[
    TaskData(id: 1, text: "Buy groceries for dinner", completed: false),
    TaskData(id: 2, text: "Write quarterly report", completed: true),
    TaskData(id: 3, text: "Call dentist to reschedule", completed: false),
    TaskData(id: 4, text: "Review Sarah's pull request", completed: true),
    TaskData(id: 5, text: "Book flights for conference", completed: false),
  ])

proc allCompletedProvider*(): TaskMockProvider =
  TaskMockProvider(name: "All Completed", filter: fmAll, tasks: @[
    TaskData(id: 1, text: "Morning standup", completed: true),
    TaskData(id: 2, text: "Deploy v2.1", completed: true),
    TaskData(id: 3, text: "Update documentation", completed: true),
  ])

proc heavyUsageProvider*(): TaskMockProvider =
  var tasks: seq[TaskData]
  let names = [
    "Review quarterly OKRs", "Update team wiki", "Prepare sprint demo",
    "Fix login redirect bug", "Write API documentation", "Set up staging env",
    "Code review: auth module", "Design system audit", "Update dependencies",
    "Write unit tests for parser", "Optimize database queries", "Setup CI pipeline",
    "Create onboarding guide", "Fix mobile layout issue", "Add error tracking",
    "Refactor user service", "Update privacy policy", "Load testing",
    "Migrate to new API", "Archive old branches",
  ]
  for i, name in names:
    tasks.add TaskData(id: i + 1, text: name, completed: i mod 3 == 0)
  TaskMockProvider(name: "Heavy Usage", filter: fmAll, tasks: tasks)

proc applyMock*(vm: TaskAppVM; mock: TaskMockProvider) =
  ## Apply a mock data provider to populate the TaskAppVM.
  for task in mock.tasks:
    vm.store.addTask(task.text)
    if task.completed:
      vm.store.toggleTask(vm.store.tasks.val[^1].id)
  vm.store.setFilter(mock.filter)
