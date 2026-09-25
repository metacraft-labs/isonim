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
## `codetracer-specs/Front-Ends/IsoNim/Editor-Scene-Graph.milestones.org`.

const sceneGraphEnabled* = defined(isonimEditor)

when sceneGraphEnabled:
  import ../editor/scene_graph_hooks
  export scene_graph_hooks
else:
  import ./scene_graph_hooks_off
  export scene_graph_hooks_off
