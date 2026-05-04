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

  test "editor_public_api_supports_example_metacraft_and_codetracer_consumers":
    let exampleWorkspace = newEditorWorkspace(
      title = "IsoNim Example Editor",
      id = "isonim-example",
      storyGroups = @[
        StoryGroup(
          name: "Pages",
          kind: skPage,
          expanded: true,
          description: "Example-owned page stories",
          items: @[
            StoryItem(
              name: "Destination Detail",
              description: "Example story data",
              kind: skPage,
              group: "Pages")
          ])
      ],
      initialView = evPagePreview)

    let metacraftWorkspace = newEditorWorkspace(
      title = "Metacraft Back Office",
      id = "metacraft-web",
      storyGroups = @[
        StoryGroup(
          name: "User Journeys",
          kind: skFlow,
          expanded: true,
          description: "Consumer-owned operational journeys",
          items: @[
            StoryItem(
              name: "Issue CodeTracer license",
              description: "Metacraft-owned journey",
              kind: skFlow,
              group: "User Journeys")
          ])
      ],
      initialView = evStoryboard)

    let codeTracerWorkspace = newEditorWorkspace(
      title = "CodeTracer Editor Host",
      id = "codetracer-editor-host",
      storyGroups = @[
        StoryGroup(
          name: "Debugger Surfaces",
          kind: skComponent,
          expanded: true,
          description: "CodeTracer-facing editor embedding pattern",
          items: @[
            StoryItem(
              name: "Trace Timeline",
              description: "Consumer-owned debugger surface",
              kind: skComponent,
              group: "Debugger Surfaces")
          ])
      ],
      initialView = evComponentDetail)

    check exampleWorkspace.id == "isonim-example"
    check metacraftWorkspace.id == "metacraft-web"
    check codeTracerWorkspace.id == "codetracer-editor-host"
    check exampleWorkspace.initialView == evPagePreview
    check metacraftWorkspace.storyGroups[0].kind == skFlow
    check codeTracerWorkspace.storyGroups[0].kind == skComponent
