## Tests for the branded UI component layer.
##
## Uses MockRenderer to verify:
## - Correct tree structure for empty and populated states
## - Task operations (add, toggle, delete, clear completed)
## - Filter behavior
## - Theme color application

import unittest
import std/[tables, strutils]
import isonim/testing/mock_dom
import isonim/components/task_manager
import isonim/components/branded_ui
import isonim/theming/theme

# ---- Helpers ----

proc countElementsByTag(node: MockNode; tag: string): int =
  if node.kind == mnkElement and node.tag == tag:
    result = 1
  for child in node.children:
    result += countElementsByTag(child, tag)

proc findFirstByTag(node: MockNode; tag: string): MockNode =
  if node.kind == mnkElement and node.tag == tag:
    return node
  for child in node.children:
    let found = findFirstByTag(child, tag)
    if found != nil:
      return found
  nil

proc findAllByTag(node: MockNode; tag: string): seq[MockNode] =
  if node.kind == mnkElement and node.tag == tag:
    result.add(node)
  for child in node.children:
    result.add(findAllByTag(child, tag))

proc findTextContent(node: MockNode; text: string): bool =
  ## Returns true if any descendant text node contains the given text.
  if node.kind == mnkText and text in node.text:
    return true
  for child in node.children:
    if findTextContent(child, text):
      return true
  false

proc collectStyleValues(node: MockNode; prop: string): seq[string] =
  ## Collect all values of a given style property across the tree.
  if prop in node.styles:
    result.add(node.styles[prop])
  for child in node.children:
    result.add(collectStyleValues(child, prop))

# Dummy callbacks
var lastToggled = -1
var lastDeleted = -1
var lastFilter = fmAll
var addedText = ""
var clearCalled = false

proc resetCallbacks() =
  lastToggled = -1
  lastDeleted = -1
  lastFilter = fmAll
  addedText = ""
  clearCalled = false

proc dummyOnAdd(text: string) = addedText = text
proc dummyOnToggle(id: int) = lastToggled = id
proc dummyOnDelete(id: int) = lastDeleted = id
proc dummyOnFilter(f: FilterMode) = lastFilter = f
proc dummyOnClear() = clearCalled = true

suite "Branded UI - Empty State":
  test "renders title, input, and empty message":
    let r = MockRenderer()
    let state = newTaskAppState()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check root != nil
    check root.tag == "div"
    # Should contain title "Tasks"
    check findTextContent(root, "Tasks")
    # Should contain empty message
    check findTextContent(root, "No tasks yet")
    # Should contain an input element
    let inputs = findAllByTag(root, "input")
    check inputs.len == 1
    check inputs[0].attributes.getOrDefault("placeholder") == "What needs to be done?"

  test "filter bar shows All, Active, Completed":
    let r = MockRenderer()
    let state = newTaskAppState()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check findTextContent(root, "All")
    check findTextContent(root, "Active")
    check findTextContent(root, "Completed")

  test "no clear completed button when no completed tasks":
    let r = MockRenderer()
    let state = newTaskAppState()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check not findTextContent(root, "Clear Completed")

suite "Branded UI - With Tasks":
  test "renders 3 task rows":
    let r = MockRenderer()
    let state = newTaskAppState()
    state.addTask("Buy milk")
    state.addTask("Write tests")
    state.addTask("Deploy app")
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check findTextContent(root, "Buy milk")
    check findTextContent(root, "Write tests")
    check findTextContent(root, "Deploy app")
    # Should NOT show empty message
    check not findTextContent(root, "No tasks yet")

  test "toggle changes checkbox state":
    let state = newTaskAppState()
    state.addTask("Toggle me")
    let taskId = state.tasks[0].id
    check not state.tasks[0].completed

    state.toggleTask(taskId)
    check state.tasks[0].completed

    # Re-render and verify completed styling
    let r = MockRenderer()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # Should show checkmark for completed task
    check findTextContent(root, "\u2713")
    # Should show clear completed button
    check findTextContent(root, "Clear Completed")

  test "filter active hides completed tasks":
    let state = newTaskAppState()
    state.addTask("Active task")
    state.addTask("Done task")
    state.toggleTask(2)  # Mark "Done task" as completed
    state.filter = fmActive

    let r = MockRenderer()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check findTextContent(root, "Active task")
    check not findTextContent(root, "Done task")

  test "filter completed shows only completed tasks":
    let state = newTaskAppState()
    state.addTask("Active task")
    state.addTask("Done task")
    state.toggleTask(2)
    state.filter = fmCompleted

    let r = MockRenderer()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    check not findTextContent(root, "Active task")
    check findTextContent(root, "Done task")

  test "clear completed removes completed tasks":
    let state = newTaskAppState()
    state.addTask("Keep me")
    state.addTask("Remove me")
    state.toggleTask(2)
    state.clearCompleted()

    check state.tasks.len == 1
    check state.tasks[0].text == "Keep me"

  test "delete task removes it":
    let state = newTaskAppState()
    state.addTask("First")
    state.addTask("Second")
    state.addTask("Third")
    state.deleteTask(2)

    check state.tasks.len == 2
    check state.tasks[0].text == "First"
    check state.tasks[1].text == "Third"

suite "Branded UI - Theme Colors":
  test "theme colors applied to styles":
    setTheme(isoTheme())

    let r = MockRenderer()
    let state = newTaskAppState()
    state.addTask("Themed task")
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # Background should use theme background color
    check root.styles["background-color"] == "#F8FAFC"

    # Collect all background-color values in the tree
    let bgColors = collectStyleValues(root, "background-color")
    # Should contain the primary color (for add button)
    check "#6366F1" in bgColors
    # Should contain the surface color (for task row, input)
    check "#FFFFFF" in bgColors

    # Text colors should use theme values
    let textColors = collectStyleValues(root, "color")
    # Title and task text should use text-primary
    check "#0F172A" in textColors
    # Delete icon should use error color
    check "#EF4444" in textColors

  test "completed task uses text-disabled color":
    setTheme(isoTheme())

    let r = MockRenderer()
    let state = newTaskAppState()
    state.addTask("Completed task")
    state.toggleTask(1)
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    let textColors = collectStyleValues(root, "color")
    # Completed task text should use text-disabled
    check "#CBD5E1" in textColors

  test "active filter button uses primary background":
    setTheme(isoTheme())

    let r = MockRenderer()
    let state = newTaskAppState()
    state.filter = fmActive
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # The active filter button should have primary background
    let bgColors = collectStyleValues(root, "background-color")
    check "#6366F1" in bgColors

suite "Branded UI - Event Callbacks":
  test "toggle callback fires with correct task id":
    let r = MockRenderer()
    let state = newTaskAppState()
    state.addTask("Click me")
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # Find the checkbox (first div with width=28 inside a task row)
    # The task row is inside the list div
    let divs = findAllByTag(root, "div")
    for d in divs:
      if d.styles.getOrDefault("width") == "28":
        d.fireEvent("click")
        break

    check lastToggled == 1

  test "delete callback fires with correct task id":
    let r = MockRenderer()
    let state = newTaskAppState()
    state.addTask("Delete me")
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # Find delete button - div containing the X text node
    let divs = findAllByTag(root, "div")
    for d in divs:
      if d.children.len > 0 and d.children[0].kind == mnkText and
         "\u2715" in d.children[0].text:
        d.fireEvent("click")
        break

    check lastDeleted == 1

  test "filter callback changes filter mode":
    let r = MockRenderer()
    let state = newTaskAppState()
    resetCallbacks()
    let root = renderTaskApp[MockRenderer, MockNode](
      r, state, dummyOnAdd, dummyOnToggle, dummyOnDelete, dummyOnFilter, dummyOnClear)

    # Find filter buttons - divs with border-radius=16
    # Collect all filter buttons and their labels
    var filterButtons: seq[(string, MockNode)] = @[]
    let divs = findAllByTag(root, "div")
    for d in divs:
      if d.styles.getOrDefault("border-radius") == "16":
        for child in d.children:
          if child.kind == mnkText:
            filterButtons.add((child.text, d))
            break

    # Should have exactly 3 filter buttons
    check filterButtons.len == 3
    # Find and click "Active"
    var found = false
    for (label, btn) in filterButtons:
      if label == "Active":
        btn.fireEvent("click")
        found = true
        break

    check found == true
    check lastFilter == fmActive
