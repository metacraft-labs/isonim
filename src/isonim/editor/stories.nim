## IsoNim Editor — story and flow definitions for the simulated user project.
##
## Stories are ViewModel constructors that produce specific visual states.
## Flows are multi-step sequences with action annotations.

import std/sequtils
import isonim/core/[signals]
import isonim/viewmodel
import isonim/editor/types
import isonim/editor/user_project_vms
import isonim/components/task_manager

# ===========================================================================
# Component stories
# ===========================================================================

type ComponentStory* = object
  name*: string
  description*: string
  createVM*: proc(): TaskRowVM

proc taskRowStories*(): seq[ComponentStory] =
  @[
    ComponentStory(
      name: "Active task",
      description: "Normal uncompleted task",
      createVM: proc(): TaskRowVM =
        createTaskRowVM(TaskData(id: 1, text: "Buy groceries for dinner", completed: false))),
    ComponentStory(
      name: "Completed task",
      description: "Task marked as done (strikethrough)",
      createVM: proc(): TaskRowVM =
        createTaskRowVM(TaskData(id: 1, text: "Write quarterly report", completed: true))),
    ComponentStory(
      name: "Long title",
      description: "Tests text overflow behavior",
      createVM: proc(): TaskRowVM =
        createTaskRowVM(TaskData(id: 1, text: "This is a very long task title that should test how the component handles text overflow and wrapping behavior in constrained layouts", completed: false))),
    ComponentStory(
      name: "Saving in progress",
      description: "Task being saved (dimmed, loading state)",
      createVM: proc(): TaskRowVM =
        let vm = createTaskRowVM(TaskData(id: 1, text: "Uploading data...", completed: false))
        vm.saveStatus.val = asLoading
        vm),
    ComponentStory(
      name: "Save error",
      description: "Task save failed (error indicator)",
      createVM: proc(): TaskRowVM =
        let vm = createTaskRowVM(TaskData(id: 1, text: "Failed to sync", completed: false))
        vm.saveStatus.val = asError
        vm),
  ]

# ===========================================================================
# Page stories
# ===========================================================================

type PageStory* = object
  name*: string
  description*: string
  mock*: TaskMockProvider

proc pageStories*(): seq[PageStory] =
  @[
    PageStory(
      name: "Empty State",
      description: "First-time user sees the app with no tasks",
      mock: emptyProvider()),
    PageStory(
      name: "Active Workspace",
      description: "User has 5 tasks, 2 completed — typical daily usage",
      mock: activeWorkspaceProvider()),
    PageStory(
      name: "All Done",
      description: "Every task is checked off — celebration moment",
      mock: allCompletedProvider()),
    PageStory(
      name: "Heavy Usage",
      description: "20 tasks with mixed completion — tests scrolling",
      mock: heavyUsageProvider()),
  ]

# ===========================================================================
# User flow stories
# ===========================================================================

type UserFlow* = object
  name*: string
  description*: string
  steps*: seq[FlowStep]

proc userFlows*(): seq[UserFlow] =
  @[
    UserFlow(
      name: "First Task",
      description: "New user creates their first task",
      steps: @[
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Empty State", kind: skPage),
          action: "User opens the app for the first time",
          description: "Empty state with placeholder text"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Empty State", kind: skPage),
          action: "Types 'Buy groceries for dinner' in the input field",
          description: "Input field has text, + button ready"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Taps the + button",
          description: "Task appears in the list"),
      ]),
    UserFlow(
      name: "Complete & Clear",
      description: "User completes tasks and clears them",
      steps: @[
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "User sees their task list",
          description: "3 active tasks, 2 completed"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Toggles 'Buy groceries' checkbox",
          description: "Task shows strikethrough"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Taps 'Clear Completed'",
          description: "Completed tasks removed from list"),
      ]),
    UserFlow(
      name: "Filter Workflow",
      description: "User filters between active and completed tasks",
      steps: @[
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "User sees all tasks (All filter active)",
          description: "Mixed active and completed tasks visible"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Taps 'Active' filter pill",
          description: "Only uncompleted tasks shown"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Taps 'Completed' filter pill",
          description: "Only completed tasks shown"),
        FlowStep(
          screenRef: StoryRef(group: "Pages", name: "Active Workspace", kind: skPage),
          action: "Taps 'All' to return to full view",
          description: "All tasks visible again"),
      ]),
  ]

# ===========================================================================
# Build full storyboard for the sidebar
# ===========================================================================

proc buildStoryboard*(): seq[StoryGroup] =
  ## Build the complete storyboard with all four levels.
  var groups: seq[StoryGroup]

  # Foundations
  groups.add StoryGroup(
    name: "Foundations", kind: skFoundation, expanded: true,
    description: "Design tokens — colors, typography, spacing",
    items: @[
      StoryItem(name: "Colors", description: "Theme color palette", kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Typography", description: "Font scale and weights", kind: skFoundation, group: "Foundations"),
      StoryItem(name: "Spacing & Radii", description: "Spacing scale and border radii", kind: skFoundation, group: "Foundations"),
    ])

  # M-EVP-8: vector symbols. Sit under Foundations in the sidebar
  # (folded into the same quick-nav category) and expose an inline
  # "Edit" affordance that opens the dedicated vector editor.
  groups.add StoryGroup(
    name: "Vector Symbols", kind: skVectorSymbol, expanded: true,
    description: "Reusable SVG icons / illustrations",
    items: @[
      StoryItem(name: "Compass", description: "Travel / navigation icon",
        kind: skVectorSymbol, group: "Vector Symbols"),
      StoryItem(name: "Heart", description: "Save / favourite icon",
        kind: skVectorSymbol, group: "Vector Symbols"),
      StoryItem(name: "Pin", description: "Map / place marker icon",
        kind: skVectorSymbol, group: "Vector Symbols"),
      StoryItem(name: "Hero", description: "Empty-state illustration",
        kind: skVectorSymbol, group: "Vector Symbols"),
    ])

  # Components
  groups.add StoryGroup(
    name: "TaskRow", kind: skComponent, expanded: true,
    description: "Individual task item with toggle and delete",
    items: taskRowStories().mapIt(
      StoryItem(name: it.name, description: it.description, kind: skComponent, group: "TaskRow")))

  groups.add StoryGroup(
    name: "FilterBar", kind: skComponent, expanded: false,
    description: "Filter pills for All/Active/Completed",
    items: @[
      StoryItem(name: "All selected", description: "All filter active", kind: skComponent, group: "FilterBar"),
      StoryItem(name: "Active selected", description: "Active filter active", kind: skComponent, group: "FilterBar"),
      StoryItem(name: "Completed selected", description: "Completed filter active", kind: skComponent, group: "FilterBar"),
    ])

  groups.add StoryGroup(
    name: "InputRow", kind: skComponent, expanded: false,
    description: "Text input with add button",
    items: @[
      StoryItem(name: "Empty", description: "Placeholder visible", kind: skComponent, group: "InputRow"),
      StoryItem(name: "With text", description: "User has typed text", kind: skComponent, group: "InputRow"),
    ])

  # Pages
  for page in pageStories():
    # Pages are individual items in a "Pages" group
    discard
  # M-EVP-8: seed `usesVectorSymbols` on a subset of pages so the vector
  # editor's usage-context companion has real data to surface in tests
  # and in the demo. The seed deliberately spreads "Hero" across all
  # four pages (>3 → carousel) and "Compass" across two (<=3 → split).
  func pageUsesSymbols(name: string): seq[string] =
    case name
    of "Empty State": @["Compass", "Hero"]
    of "Active Workspace": @["Compass", "Hero"]
    of "All Done": @["Hero"]
    of "Heavy Usage": @["Hero", "Pin"]
    else: @[]
  groups.add StoryGroup(
    name: "Pages", kind: skPage, expanded: true,
    description: "Full app views with realistic data",
    items: pageStories().mapIt(
      StoryItem(name: it.name, description: it.description,
        kind: skPage, group: "Pages",
        usesVectorSymbols: pageUsesSymbols(it.name))))

  # Patterns
  groups.add StoryGroup(
    name: "Patterns", kind: skPattern, expanded: false,
    description: "Common UI compositions and layouts",
    items: @[
      StoryItem(name: "Form Layout", description: "Input fields with labels and validation", kind: skPattern, group: "Patterns"),
      StoryItem(name: "List with Actions", description: "Scrollable list with item actions", kind: skPattern, group: "Patterns"),
      StoryItem(name: "Empty State", description: "Illustration + message + CTA pattern", kind: skPattern, group: "Patterns"),
      StoryItem(name: "Loading Skeleton", description: "Placeholder shimmer while data loads", kind: skPattern, group: "Patterns"),
    ])

  # User Flows
  for flow in userFlows():
    groups.add StoryGroup(
      name: flow.name, kind: skFlow, expanded: false,
      description: flow.description,
      items: flow.steps.mapIt(
        StoryItem(name: it.action, description: it.description, kind: skFlow, group: flow.name)))

  # Guidelines
  groups.add StoryGroup(
    name: "Guidelines", kind: skGuideline, expanded: false,
    description: "Usage rules, content, motion, accessibility",
    items: @[
      StoryItem(name: "Do / Don't", description: "Component usage rules with examples", kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Content & Voice", description: "Tone, terminology, error messages", kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Motion", description: "Animation durations, easing curves", kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Accessibility", description: "Keyboard nav, ARIA, screen readers", kind: skGuideline, group: "Guidelines"),
      StoryItem(name: "Responsive", description: "Breakpoints and adaptive behavior", kind: skGuideline, group: "Guidelines"),
    ])

  groups
