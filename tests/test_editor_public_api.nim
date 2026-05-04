import std/[unittest, options, strutils]

import isonim/editor

suite "IsoNim editor public API compatibility":

  test "editor_public_api_imports_without_demo_dependencies":
    let workspace = newEditorWorkspace(
      title = "Public API consumer",
      id = "public-api-consumer",
      storyGroups = @[
        StoryGroup(
          name: "Pages",
          kind: skPage,
          description: "Consumer-owned stories",
          expanded: true,
          items: @[
            StoryItem(
              name: "Dashboard",
              description: "Consumer page fixture",
              kind: skPage,
              group: "Pages")
          ])
      ],
      initialStory = some(StoryRef(
        group: "Pages", name: "Dashboard", kind: skPage)))

    check workspace.id == "public-api-consumer"
    check workspace.storyGroups[0].items[0].name == "Dashboard"

    let publicApi = readFile("src/isonim/editor.nim")
    let browserApi = readFile("src/isonim/editor/browser.nim")
    check not publicApi.contains("examples/")
    check not publicApi.contains("demos/")
    check not browserApi.contains("examples/")
    check not browserApi.contains("demos/")
