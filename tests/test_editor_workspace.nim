## Tests for the importable IsoNim Editor workspace framework API.

import std/unittest

import isonim/core/owner
import isonim/core/signals
import isonim/editor

suite "IsoNim Editor workspace API":

  test "workspace constructor keeps project-owned story data":
    let workspace = newEditorWorkspace(
      title = "Metacraft Back Office",
      id = "metacraft-web",
      description = "Operations dashboard workspace",
      storyGroups = @[
        StoryGroup(
          name: "Operations dashboard",
          kind: skPage,
          expanded: true,
          description: "Main back-office dashboard",
          items: @[
            StoryItem(
              name: "Seeded local data",
              description: "Dashboard with realistic billing and license data",
              kind: skPage,
              group: "Operations dashboard")
      ])
    ],
      initialView = evPagePreview,
      initialInspectorSection = isFill)

    check workspace.id == "metacraft-web"
    check workspace.title == "Metacraft Back Office"
    check workspace.storyGroups.len == 1
    check workspace.storyGroups[0].items[0].name == "Seeded local data"
    check workspace.initialView == evPagePreview
    check workspace.initialInspectorSection == isFill
    check workspace.panels.sidebar
    check workspace.panels.inspector

  test "createEditorVM loads a workspace without demo coupling":
    createRoot proc(dispose: proc()) =
      let workspace = newEditorWorkspace(
        title = "Project Workspace",
        storyGroups = @[
          StoryGroup(
            name: "Customers",
            kind: skPage,
            expanded: true,
            description: "Customer operations pages",
            items: @[
              StoryItem(
                name: "Customer detail",
                description: "Billing, entitlement, and audit state",
                kind: skPage,
                group: "Customers")
        ])
      ],
        flowSteps = @[
          FlowStep(
            screenRef: StoryRef(group: "Customers", name: "Customer detail",
                                kind: skPage),
            action: "Open customer",
            description: "Operator opens a customer record")
        ],
        initialView = evStoryboard)

      let vm = createEditorVM(workspace)

      check vm.sidebar.groups.val.len == 1
      check vm.sidebar.groups.val[0].name == "Customers"
      check vm.flowPlayer.steps.val.len == 1
      check vm.activeView.val == evStoryboard
      check vm.platform.val == pfWeb

      dispose()
