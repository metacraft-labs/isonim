## Production scene-graph hooks: the seam, wired to nothing.
##
## The `ui` macro emits one `noteElement` call per element. In a production
## build this module is what that call resolves to, and every parameter is
## unused — so Nim never evaluates the arguments and nothing reaches the
## backend. The element's source location, its parent's id and the tag string
## are not computed, not stored, and not present in the emitted JS or C.
##
## That is a measured property, not an assumption: a probe passing a
## side-effecting call as an ignored argument did not run the side effect, and
## the generated C and JS each contained zero references to it
## (`Editor-Scene-Graph.milestones.org` SGR-M1 § Verification).
##
## The editor counterpart is `isonim/editor/scene_graph_hooks.nim`. Exactly one
## of the two is in scope, selected by `-d:isonimEditor` in
## `isonim/dsl/scene_graph.nim`.

template noteElement*(el: untyped; id: static string; tag: static string;
                      loc: static string; parentId: static string) =
  ## No-op. Every parameter is deliberately unused; see the module doc.
  discard
