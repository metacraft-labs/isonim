## The authored literals of a ui block, as values the editor can write.
##
## An IsoNim project's DSL is full of literals -- `padding = "12px"`,
## `text "Faster than C."` -- and in a production build each one is compiled
## straight into the element that carries it. That is the right answer for a
## shipped page and the wrong one for an editor: changing such a value meant
## rewriting the source and recompiling, seconds per keystroke.
##
## Under `-d:isonimEditor` the `ui` macro compiles each literal into a cell
## instead, registered here and read inside a render effect. Writing the cell
## invalidates that effect and nothing else, so the edit reaches the DOM
## through the framework's ordinary reactive path rather than through a
## mechanism the editor maintains alongside it. No diffing, no re-render of the
## surrounding block, no string patching -- the node that showed the value is
## the node that updates.
##
## **A separate module, and imported by nothing in the DSL.** The macro emits
## `editableValue` as an unbound identifier, exactly as it already emits
## `createRenderEffect`, so the symbol resolves where the block is written
## rather than where the macro is defined. That keeps the reactive core out of
## the DSL's dependencies: `dsl/scene_graph_hooks.nim` is documented as
## staying close to dependency-free because every IsoNim project compiles it,
## and importing signals there made a scene-graph fixture stop building.
## `dsl/isomorphic.nim` re-exports this under the editor flag, so a project
## using `uiIsomorphic` gets it without knowing it exists.

import std/tables
import ../core/signals

var cells = initTable[string, Signal[string]]()
  ## Keyed `<element id>|<property>`. A plain global for the same reason the
  ## scene graph keeps one: rendering is single-threaded on every backend the
  ## editor previews, and `threadvar` does not survive the JS backend.

func editableCellKey*(id, property: string): string {.inline.} =
  id & "|" & property

proc editableValue*(id, property, initial: string): Signal[string] =
  ## The cell behind one authored value. Emitted by the `ui` macro.
  ##
  ## Created on first render and REUSED afterwards, which is the point:
  ## re-rendering the block that declared it must not discard an edit. A story
  ## re-selected, a list re-keyed, a parent effect re-running -- each rebuilds
  ## elements, and each would otherwise reset the value to the literal
  ## compiled into the bundle.
  ##
  ## `initial` therefore seeds the cell and is ignored once it exists. When the
  ## project is recompiled the new literal SHOULD win, because the source now
  ## says something different; `resetEditableCells` is how the hot swap says so.
  let key = editableCellKey(id, property)
  if cells.hasKey(key):
    return cells[key]
  result = createSignal(initial)
  cells[key] = result

proc editableCell*(id, property: string): Signal[string] =
  ## The cell for an authored value, or nil when this element never declared
  ## the property.
  ##
  ## Nil is the honest answer and the caller's cue to fall back rather than a
  ## failure: a property the DSL does not author cannot be edited through a
  ## cell, and most of a design system's properties are of that kind. They live
  ## in the stylesheet, and the editor reaches those through the rule that
  ## declares them instead.
  cells.getOrDefault(editableCellKey(id, property), nil)

proc setEditableValue*(id, property, value: string): bool =
  ## Write an authored value. Returns false when no cell exists, so a caller
  ## can tell "applied" from "nothing here to apply to" instead of assuming.
  let cell = editableCell(id, property)
  if cell.isNil: return false
  cell.val = value
  true

proc resetEditableCells*() =
  ## Drop every cell. Called when the project's code is replaced under a
  ## running editor: the literals these were seeded from no longer describe the
  ## source, so keeping them would show the user a value their file does not
  ## contain.
  cells = initTable[string, Signal[string]]()

proc editableCellCount*(): int = cells.len
  ## For tests and the telemetry overlay.

iterator editableCellKeys*(): string =
  ## For tests and diagnostics: which values this render made editable.
  for key in cells.keys: yield key
