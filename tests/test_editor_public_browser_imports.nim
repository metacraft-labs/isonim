when not defined(js):
  {.error: "This compatibility entry must be compiled with `nim js`".}

import isonim/editor
import isonim/editor/browser

let workspace = newEditorWorkspace(
  title = "Browser public API consumer",
  id = "browser-public-api-consumer",
  storyGroups = @[
    StoryGroup(
      name: "Pages",
      kind: skPage,
      description: "Consumer-owned browser stories",
      expanded: true,
      items: @[
        StoryItem(
          name: "Dashboard",
          description: "Consumer page fixture",
          kind: skPage,
          group: "Pages")
      ])
  ])

discard workspace
