## Tests for the importable IsoNim Editor workspace framework API.

import std/[options, unittest]

import isonim/core/computation
import isonim/core/owner
import isonim/core/signals
import isonim/editor
import examples/wanderlust/stories as wanderlust

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
    createRoot do (dispose: proc()):
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
      check vm.platform.val == pbWeb

      dispose()

  test "editor_vm_workspace_initial_state_is_applied":
    createRoot do (dispose: proc()):
      let groups = wanderlust.buildWanderlustStoryboard()
      let flowStory = StoryRef(
        group: groups[0].items[1].group,
        name: groups[0].items[1].name,
        kind: groups[0].items[1].kind,
        index: 1)
      let element = ElementRef(
        tag: "article",
        sourceFile: "examples/wanderlust/components/views.nim",
        sourceLine: 42,
        sourceColumn: 7,
        properties: @[
          PropertyInfo(
            name: "display",
            value: "flex",
            origin: poTailwindClass,
            originDetail: "class:flex",
            sourceLine: 42,
            sourceFile: "examples/wanderlust/components/views.nim")
        ])
      let reviewBaseline = @[
        Violation(
          severity: vsWarning,
          category: vcAccessibility,
          message: "Add clearer image alt text",
          file: "examples/wanderlust/components/views.nim",
          line: 42,
          autoFixable: true)
      ]
      let symbol = VectorSymbol(
        name: "Compass",
        category: "Icons",
        svgContent: "<svg></svg>",
        tags: @["travel"],
        width: 24,
        height: 24)
      let workspace = newEditorWorkspace(
        title = "Wanderlust",
        id = "wanderlust",
        storyGroups = groups,
        canvasItems = @[
          CanvasItem(
            storyRef: flowStory,
            x: 0,
            y: 0,
            width: 320,
            height: 200,
            label: "Destination detail")
        ],
        flowSteps = @[
          FlowStep(
            screenRef: flowStory,
            action: "Open destination",
            description: "The user opens the destination detail page")
        ],
        vectorSymbols = @[symbol],
        initialView = evStoryboard,
        initialStory = some(flowStory),
        initialCanvasItem = some(0),
        initialInspectorElement = some(element),
        initialInspectorSection = isTypography,
        initialVectorSymbol = some(0),
        initialReviewBaseline = some(reviewBaseline),
        platform = pbCocoa,
        panels = PanelVisibility(sidebar: false, inspector: true))

      let vm = createEditorVM(workspace)

      check vm.activeView.val == evStoryboard
      check vm.selectedStory.val.name == flowStory.name
      check computation.val(vm.hasSelection) == true
      check vm.storyboard.selectedItem.val == 0
      check vm.flowPlayer.currentStep.val == 0
      check computation.val(vm.inspector.hasElement) == true
      check vm.inspector.selectedElement.val.tag == "article"
      check vm.inspector.activeSection.val == isTypography
      check vm.vectorEditor.selectedSymbol.val == 0
      check vm.review.violations.val.len == 1
      check computation.val(vm.review.warningCount) == 1
      check vm.platform.val == pbCocoa
      check vm.panels.val.sidebar == false
      check vm.panels.val.inspector == true
      dispose()
