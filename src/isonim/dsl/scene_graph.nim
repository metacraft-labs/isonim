## Scene-graph seam selector.
##
## The `ui` macro emits `noteElement(...)` per element and imports this module,
## which resolves to exactly one implementation:
##
##   production (default)   -> `scene_graph_hooks_off`  (no-op; arguments erased)
##   editor (-d:isonimEditor) -> `../editor/scene_graph_hooks` (records the tree)
##
## Keeping the choice here rather than in `ui.nim` is what keeps editor
## concerns out of the DSL: `ui.nim` emits one uniform call and has no idea an
## editor exists.
##
## `sceneGraphEnabled` is exported for the macro's Design-B arm, which skips
## generating the call at all. SGR-M1 measures the two and keeps one; see
## `isonim-specs/Editor-Scene-Graph.milestones.org`.

const sceneGraphEnabled* = defined(isonimEditor)

const editRegimeEnabled* = defined(isonimEditor)
  ## Compile the DSL's authored literals into cells the editor can write.
  ##
  ## The same flag as `sceneGraphEnabled`, named separately because it is a
  ## different claim: one records what the tree IS, the other makes what it
  ## SAYS changeable at runtime. They are enabled together today because both
  ## exist to serve the editor, and a project that wanted one without the other
  ## would be asking for a build the editor cannot drive.
  ##
  ## In a production build this is false and the macro emits exactly what it
  ## always did -- the literal, in place, with no cell, no effect and no
  ## registry lookup. The edit regime costs a shipped page nothing because it
  ## is not in it.

when sceneGraphEnabled:
  import ../editor/scene_graph_hooks
  export scene_graph_hooks
  # The edit regime's registry, reached through the same seam for the same
  # reason: the `ui` macro emits one uniform call and has no idea an editor
  # exists. `bindSym` resolves it here, so a project writing client-mode DSL
  # needs no import of its own.
  #
  # This is the one place the DSL touches the reactive core, and only in an
  # editor build -- `sceneGraphEnabled` is false in production, the import does
  # not happen, and a shipped page links none of it.
  import ../editor/editable_cells
  export editable_cells
else:
  import ./scene_graph_hooks_off
  export scene_graph_hooks_off
