## The workspace supplies declared preview metadata to the actual reactive
## editor model. No compiler, source-I/O, transport or DOM result is mocked.
## These observers exercise navigation coherence and owner cleanup directly.
import std/unittest
import isonim/core/[signals, computation, owner]
import isonim/editor/[types, viewmodels, workspace]

suite "Coherent synchronous story navigation":
  test "story_navigation_observers_receive_coherent_surface_preview_canvas_and_flow":
    createRoot proc(dispose: proc()) =
      let card = StoryRef(group: "Card", name: "Default", kind: skComponent)
      let first = StoryRef(group: "Flow", name: "First", kind: skFlow)
      let second = StoryRef(group: "Flow", name: "Second", kind: skFlow, index: 1)
      # This workspace supplies declared preview metadata, not a substituted
      # compiler/source-I/O result. It distinguishes each story's preview and
      # the generated component schema seen by navigation observers.
      let vm = createEditorVM(newEditorWorkspace(
        title = "Coherent story navigation",
        storyGroups = @[
          StoryGroup(name: "Card", kind: skComponent,
            items: @[StoryItem(group: "Card", name: "Default", kind: skComponent)]),
          StoryGroup(name: "Flow", kind: skFlow, items: @[
            StoryItem(group: "Flow", name: "First", kind: skFlow),
            StoryItem(group: "Flow", name: "Second", kind: skFlow)])],
        previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
          ProjectPreview(status: ppsRendered, story: story,
            documentHtml: "<div>" & story.name & "</div>",
            metadata: StoryRenderMetadata(story: story,
              sourceFile: story.group & ".nim", sourceLine: 1))))
      vm.storyboard.canvasItems.val = @[
        CanvasItem(storyRef: card), CanvasItem(storyRef: first),
        CanvasItem(storyRef: second)]
      vm.flowPlayer.steps.val = @[
        FlowStep(screenRef: first), FlowStep(screenRef: second)]
      check vm.selectStory(card)
      type Navigation = tuple[story, preview: StoryRef, view: EditorView,
        canvas, flow: int, schemaFile: string]
      var seen: seq[Navigation]
      var lifecycle: seq[string]
      var childUpdates: seq[string]
      let probe = createSignal(0)
      createRenderEffect proc() =
        let story = vm.selectedStory.val
        lifecycle.add "mount:" & story.group & "/" & story.name
        onCleanup(proc() = lifecycle.add "dispose:" & story.group & "/" & story.name)
        createRenderEffect proc() =
          childUpdates.add story.group & "/" & story.name & ":" & $probe.val
        let variants = vm.variants.variants.val
        var schemaFile = ""
        for variant in variants:
          if variant.story == story and variant.properties.len > 0:
            schemaFile = variant.properties[0].sourceFile
        seen.add (story, vm.preview.current.val.story, vm.activeView.val,
          vm.storyboard.selectedItem.val, vm.flowPlayer.currentStep.val, schemaFile)
      seen.setLen(0)
      lifecycle.setLen(0)
      childUpdates.setLen(0)
      check vm.selectStory(second)
      check seen == @[(second, second, evStoryboard, 2, 1, "")]
      check lifecycle == @["dispose:Card/Default", "mount:Flow/Second"]
      check childUpdates == @["Flow/Second:0"]
      seen.setLen(0)
      lifecycle.setLen(0)
      childUpdates.setLen(0)
      check vm.selectStory(card)
      check seen == @[(card, card, evComponentDetail, 0, 1, "Card.nim")]
      check lifecycle == @["dispose:Flow/Second", "mount:Card/Default"]
      check childUpdates == @["Card/Default:0"]
      probe.val = 1
      check childUpdates == @["Card/Default:0", "Card/Default:1"]
      seen.setLen(0)
      lifecycle.setLen(0)
      check not vm.selectStory(StoryRef(group: "Missing", name: "Missing"))
      check seen.len == 0
      check lifecycle.len == 0
      check vm.selectedStory.val == card
      dispose()
      check lifecycle == @["dispose:Card/Default"]
      probe.val = 2
      check childUpdates == @["Card/Default:0", "Card/Default:1"]
