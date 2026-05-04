## IsoNim Editor — browser demo entry point.
## Compiles to JS via `nim js` and mounts a project workspace.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import examples/wanderlust/stories as wanderlust
import isonim/editor
import isonim/editor/browser

proc main() =
  let workspace = newEditorWorkspace(
    title = "Wanderlust",
    storyGroups = wanderlust.buildWanderlustStoryboard(),
    id = "wanderlust",
    description = "Travel app workspace for IsoNim Editor development")
  discard mountEditor(workspace)

main()
