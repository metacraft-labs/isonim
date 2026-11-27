## Production catalog refresh preserves real ViewModel state. Static catalog
## data and fixture preview hooks isolate reactive composition and metadata;
## they substitute only producer output for these focused state tests. Registered
## native/GUI source tests exercise actual files, compiler and mounted rendering.
## The adapter identity regression uses callbacks that record prompt/cancel
## invocation only: this isolates replacement by the production hot-reload/data
## API without launching a model. Actual REST/CLI/source compiler boundaries stay
## covered by registered native and mounted Harbor scenario integration tests.
## The source project's first catalog read (JS only) is given a catalog
## service that answers with a fixed reply, and a source transport that
## records requests and never answers: the tests decide when the read's
## answer arrives relative to the editor's own writes, which a real server
## cannot be made to order. The mounted source GUI tests cover the real
## endpoint and transport.
import std/[unittest, json, strutils]
import isonim/core/[owner, signals, computation]
import isonim/editor
import isonim/editor/[workspace, control, source_catalog, preview_identity]
when defined(js):
  import std/options
  import nim_everywhere/async_compat
  import isonim/editor/source_browser

suite "Workspace catalog refresh":
  test "same workspace preserves conversations drafts journals selection and viewport":
    createRoot proc(dispose: proc()) =
      let initial = newEditorWorkspace("Project", @[
        StoryGroup(name: "Card", kind: skComponent, items: @[
          StoryItem(group: "Card", name: "Ready", kind: skComponent)])], id = "project")
      let vm = createEditorVM(initial)
      discard vm.selectStory(StoryRef(group: "Card", name: "Ready", kind: skComponent))
      let first = vm.chats.val[0]
      first.vm.inputText.val = "Keep first draft"
      first.vm.controlConversationId.val = "persistent-backend"
      let secondId = vm.createNewChat()
      let second = vm.chats.val[1]
      second.vm.inputText.val = "Keep second draft"
      vm.changeViewport(builtinViewportFromSlug("phone"))
      vm.inspector.pendingSourceEdits.val = @[SourceEditPlan(file: "source.nim", property: "title", newValue: "pending")]
      let before = vm.controlSnapshot()["revision"].getInt()
      var rebuilt = initial
      rebuilt.storyGroups[0].items = @[
        StoryItem(group: "Card", name: "Busy", kind: skComponent),
        StoryItem(group: "Card", name: "Ready", kind: skComponent)]
      vm.refreshWorkspaceCatalog(rebuilt)
      check vm.chats.val[0] == first
      check vm.chats.val[1] == second
      check vm.activeChatId.val == secondId
      check first.vm.controlConversationId.val == "persistent-backend"
      check first.vm.inputText.val == "Keep first draft"
      check second.vm.inputText.val == "Keep second draft"
      check vm.selectedStory.val.name == "Ready"
      check vm.selectedStory.val.index == 1
      check vm.viewport.val.slug == "phone"
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].newValue == "pending"
      check vm.controlSnapshot()["revision"].getInt() > before
      dispose()

  test "catalog and hot bundle refresh keep mounted adapters callable and session identity":
    createRoot proc(dispose: proc()) =
      let initial = newEditorWorkspace("Project", @[
        StoryGroup(name: "Card", kind: skComponent, items: @[
          StoryItem(group: "Card", name: "Ready", kind: skComponent)])], id = "project")
      let vm = createEditorVM(initial)
      discard vm.selectStory(StoryRef(group: "Card", name: "Ready", kind: skComponent))
      let conversation = vm.chat
      conversation.controlConversationId.val = "persistent-rest-session"
      vm.controlInstanceId = "mounted-control-instance"
      var prompts: seq[string] = @[]
      var cancellations = 0
      conversation.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
          check context.selectedStory.name == "Ready"
          check context.backend == absAgentHarbor
          prompts.add prompt
          true,
        proc(): bool =
          inc cancellations
          true,
        absAgentHarbor)
      conversation.addUserMessage("Existing conversation history")
      conversation.inputText.val = "Draft after catalog refresh"
      let history = conversation.messages.val
      vm.refreshWorkspaceCatalog(initial)
      check vm.chat == conversation
      check vm.chat.messages.val == history
      check vm.chat.inputText.val == "Draft after catalog refresh"
      check vm.chat.controlConversationId.val == "persistent-rest-session"
      check vm.controlInstanceId == "mounted-control-instance"
      check vm.sendAgentPrompt()
      check prompts == @["Draft after catalog refresh"]
      # This is mountEditor's actual hot-bundle replacement entry point.
      conversation.inputText.val = "Draft after hot bundle refresh"
      let afterFirst = conversation.messages.val
      let previewGeneration = vm.preview.sourceGeneration.val
      vm.loadProjectData(initial)
      check vm.chat == conversation
      check conversation.messages.val == afterFirst
      check conversation.inputText.val == "Draft after hot bundle refresh"
      check conversation.controlConversationId.val == "persistent-rest-session"
      check vm.controlInstanceId == "mounted-control-instance"
      check vm.preview.sourceGeneration.val > previewGeneration
      check vm.sendAgentPrompt()
      check prompts == @["Draft after catalog refresh", "Draft after hot bundle refresh"]
      check conversation.cancelAdapter()
      check cancellations == 1
      dispose()

  test "foreign refresh is refused before project permissions adapters or sessions mutate":
    createRoot proc(dispose: proc()) =
      let initial = newEditorWorkspace("Project", @[
        StoryGroup(name: "Card", kind: skComponent, items: @[
          StoryItem(group: "Card", name: "Ready", kind: skComponent)])], id = "project",
        permissions = EditorWorkspacePermissions(readSource: true, writeSource: true))
      let vm = createEditorVM(initial)
      discard vm.selectStory(StoryRef(group: "Card", name: "Ready", kind: skComponent))
      let conversation = vm.chat
      conversation.controlConversationId.val = "persistent-rest-session"
      conversation.inputText.val = "Keep this draft"
      vm.controlInstanceId = "mounted-control-instance"
      var prompts = 0
      conversation.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
          inc prompts
          true,
        nil, absAgentHarbor)
      let before = vm.controlSnapshot()
      let groups = vm.sidebar.groups.val
      let selected = vm.selectedStory.val
      let permissions = vm.workspacePermissions.val
      let adapterReady = vm.sourceAdapterReady.val
      let generation = vm.preview.sourceGeneration.val
      let foreignProject = newEditorWorkspace("Foreign", @[], id = "foreign",
        permissions = EditorWorkspacePermissions())
      expect ValueError: vm.loadProjectData(foreignProject)
      expect ValueError: vm.refreshWorkspaceCatalog(foreignProject)
      check vm.workspaceId == "project"
      check vm.sidebar.groups.val == groups
      check vm.selectedStory.val == selected
      check vm.workspacePermissions.val == permissions
      check vm.sourceAdapterReady.val == adapterReady
      check vm.preview.sourceGeneration.val == generation
      check vm.chat == conversation
      check conversation.controlConversationId.val == "persistent-rest-session"
      check conversation.inputText.val == "Keep this draft"
      check vm.controlInstanceId == "mounted-control-instance"
      check vm.controlSnapshot() == before
      check vm.sendAgentPrompt()
      check prompts == 1
      dispose()

  test "bundle recovery clears only build and same-scope refusal diagnostics":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM(newEditorWorkspace("Project", @[], id = "project"))
      let pending = SourceEditPlan(file: "source.nim", property: "width", newValue: "12px")
      vm.inspector.pendingSourceEdits.val = @[pending]
      let saveFailure = WorkspaceEditDiagnostic(kind: wedWriteFailed,
        message: "Existing source write refusal.")
      vm.workspaceEditDiagnostics.val = @[saveFailure]
      vm.workspaceEditStage.val = wesFailed
      vm.recordProjectRefreshRefusal("Foreign project refused.")
      check vm.workspaceEditDiagnostics.val.len == 2
      vm.recoverProjectBuild()
      check vm.workspaceEditDiagnostics.val.len == 2
      check vm.workspaceEditStage.val == wesFailed
      vm.loadProjectData(newEditorWorkspace("Project", @[], id = "project"))
      vm.clearProjectRefreshRefusal()
      check vm.workspaceEditDiagnostics.val == @[saveFailure]
      check vm.workspaceEditStage.val == wesFailed
      check vm.inspector.pendingSourceEdits.val == @[pending]
      vm.recoverProjectBuild()
      check vm.workspaceEditDiagnostics.val == @[saveFailure]
      check vm.workspaceEditStage.val == wesFailed
      vm.workspaceEditDiagnostics.val = @[WorkspaceEditDiagnostic(
        kind: wedCompileFailed, message: "The project failed to rebuild: actual build failure")]
      vm.recoverProjectBuild()
      check vm.workspaceEditDiagnostics.val.len == 0
      check vm.workspaceEditStage.val == wesDirty
      check vm.inspector.pendingSourceEdits.val == @[pending]
      dispose()

  test "project switch requires acknowledged backend closure before resetting state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM(newEditorWorkspace("First", @[], id = "first"))
      vm.chat.controlConversationId.val = "active-backend"
      vm.chat.inputText.val = "Unsaved conversation draft"
      let next = newEditorWorkspace("Second", @[], id = "second")
      expect ValueError: vm.applyWorkspace(next)
      check vm.workspaceId == "first"
      check vm.chat.inputText.val == "Unsaved conversation draft"
      check vm.chat.controlConversationId.val == "active-backend"
      expect ValueError: vm.applyWorkspace(newEditorWorkspace("First", @[], id = "first"))
      check vm.chat.controlConversationId.val == "active-backend"
      check vm.chat.inputText.val == "Unsaved conversation draft"
      vm.chat.controlConversationId.val = ""
      vm.applyWorkspace(next)
      check vm.workspaceId == "second"
      check vm.chat.inputText.val == ""
      check vm.chat.controlConversationId.val == ""
      dispose()


suite "Compiled catalog identity":
  test "same selected story rerenders on generation and preserves permissions and metadata":
    createRoot proc(dispose: proc()) =
      let story = StoryRef(group: "Card", name: "Ready", kind: skComponent)
      let base = newEditorWorkspace("Project", @[StoryGroup(name: "Card", kind: skComponent,
        items: @[StoryItem(group: "Card", name: "Ready", kind: skComponent)])], id = "project",
        previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
          ProjectPreview(status: ppsRendered, story: story, documentHtml: "old rendered title",
            metadata: StoryRenderMetadata(sourceFile: "consumer/component.nim", sourceLine: 42)))
      let vm = createEditorVM(base)
      discard vm.selectStory(story)
      check vm.preview.current.val.documentHtml == "old rendered title"
      let manifest = %* {"fixtures": []}
      let catalog = %* {"stories": [{"group":"Card", "name":"Ready", "kind":"component", "documentHtml":"new compiled title"}]}
      vm.workspacePermissions.val = defaultEditorPermissions()
      vm.refreshWorkspaceCatalog(sourceCatalogWorkspace(catalog, manifest, base))
      check vm.selectedStory.val == story
      check vm.preview.current.val.documentHtml == "new compiled title"
      check vm.preview.current.val.metadata.sourceFile == "consumer/component.nim"
      check vm.preview.current.val.metadata.sourceLine == 42
      check not vm.workspacePermissions.val.writeSource
      check not vm.workspacePermissions.val.createStory
      dispose()

  test "catalog rejects ambiguous stable IDs and cross-kind shadowing":
    let base = newEditorWorkspace("Project", @[StoryGroup(name: "Shared", kind: skPage,
      items: @[StoryItem(group: "Shared", name: "Same", kind: skPage)])])
    let manifest = %* {"fixtures": []}
    expect ValueError:
      discard sourceCatalogWorkspace(%* {"stories": [{"group":"Shared", "name":"Same", "kind":"component", "documentHtml":"wrong kind"}]}, manifest, base)
    expect ValueError:
      discard sourceCatalogWorkspace(%* {"stories": [
        {"group":"Card", "name":"Same", "kind":"component", "documentHtml":"one"},
        {"group":"Card", "name":"Same", "kind":"component", "documentHtml":"two"}]}, manifest, base)


suite "Authored preview identity boundaries":
  let story = StoryRef(group: "Card & \"quoted\"", name: "<Ready>", kind: skComponent)
  let identity = "<meta name=\"isonim-rendered-story\" content=\"Card &amp; &quot;quoted&quot; / <Ready>\"><meta name=\"isonim-rendered-generation\" content=\"7\">"

  template stamped(input: string): string =
    block:
      let document = identifiedPreviewDocument(input, story, 7)
      check document.replace(identity, "") == input
      document

  test "comment examples do not hide the real head":
    let input = "<!doctype html><!-- documentation <head> --><html><head><title>Okay</title></head><body>Ready</body></html>"
    check stamped(input) == input.replace("<head><title>", "<head>" & identity & "<title>")

  test "head attributes preserve quoted greater-than characters and mixed case":
    let input = "<!doctype html><HTML><HeAd data-double=\"1 > 0\" data-single='2 > 1'><title>Okay</title></HeAd><body>Ready</body></HTML>"
    check stamped(input) == input.replace("<title>", identity & "<title>")

  test "raw script and style literals are never markup":
    for tag in ["script", "style"]:
      let input = "<!doctype html><html><" & tag & ">example = '<head>'; example2 = '<header>';</" & tag & "><head></head><body>Ready</body></html>"
      check stamped(input) == input.replace("<html>", "<html>" & identity)

  test "RCDATA title and textarea examples remain authored text":
    for tag in ["title", "textarea"]:
      let input = "<!doctype html><html><" & tag & ">Example <head> and <header></" & tag & "><head></head><body>Ready</body></html>"
      check stamped(input) == input.replace("<html>", "<html>" & identity)

  test "headless documents retain doctype and html attributes":
    let input = "<!doctype html><html lang='en'><body>Ready</body></html>"
    check stamped(input) == input.replace("<html lang='en'>", "<html lang='en'>" & identity)
    let withoutHtml = "<!doctype html><!-- authored --><body>Ready</body>"
    check stamped(withoutHtml) == withoutHtml.replace("<body>", identity & "<body>")

  test "fragment header and quoted attributes are not a head":
    let input = "<header data-example='a > b'><h1>Ready</h1></header>"
    check stamped(input) == identity & input
    check stamped("") == ""

  test "headless raw and RCDATA fragments retain examples and prepend real metadata":
    for tag in ["script", "style", "title", "textarea", "noscript"]:
      let input = "<" & tag & ">Authored <head> example</" & tag & "><header>Ready</header>"
      check stamped(input) == identity & input

  test "script escaped states remain untouched after implicit head admission":
    for script in [
      "window.value=\"<!--<script></script><head>\";",
      "window.value=\"<!--<script>--><header>\";",
      "window.value=\"<!--<scripture></scripture><head>\";",
      "window.value='<!--<script x=\"<script>\"></script x=\"<script>\"><head>-->';"]:
      let input = "<!doctype html><html><script>" & script & "</script><head data-real='yes'></head><body>Ready</body></html>"
      check stamped(input) == input.replace("<html>", "<html>" & identity)

  test "initial UTF-8 BOM remains before the doctype and metadata":
    let input = "\xEF\xBB\xBF<!doctype html><html><head data-value='1 > 0'></head><body>Ready</body></html>"
    check stamped(input) == input.replace("<head data-value='1 > 0'>", "<head data-value='1 > 0'>" & identity)

  test "leading text-html processing comment preserves doctype and explicit head":
    let input = "<?xml version=\"1.0\"?><!doctype html><html><head data-value='1 > 0'></head><body>Ready</body></html>"
    check stamped(input) == input.replace("<head data-value='1 > 0'>", "<head data-value='1 > 0'>" & identity)

when defined(js):
  proc sourceProject(): EditorWorkspace =
    newEditorWorkspace("Project", @[
      StoryGroup(name: "Card", kind: skComponent, items: @[
        StoryItem(group: "Card", name: "Ready", kind: skComponent)])], id = "project",
      permissions = EditorWorkspacePermissions(readSource: true, writeSource: true))

  proc catalogReply(story: string): SourceCatalogService =
    ## A catalog service whose answer is already there: it is delivered
    ## when the test drains the platform callbacks.
    let raw = $(%* {"manifest": {"workspace": "project", "fixtures": []},
      "catalog": {"stories": [{"group": "Card", "name": story, "kind": "component",
        "documentHtml": "<p>" & story & "</p>"}]},
      "bindingSidecar": "", "bindingHash": repeat('a', 40)})
    result = proc(): PlatformFuture[cstring] = newCompletedFuture(raw.cstring)

  proc storyNames(vm: EditorVM): seq[string] =
    for group in vm.sidebar.groups.val:
      for item in group.items: result.add item.name

  suite "Source project first catalog read":
    test "the first catalog is applied when it arrives":
      createRoot proc(dispose: proc()) =
        let base = sourceProject()
        let vm = createEditorVM(base)
        let reloads = vm.livePreviewReloadGeneration.val
        vm.attachSourceProject(base, catalog = catalogReply("Compiled"))
        check not vm.sourceAdapterReady.val
        drainCallbacks()
        check vm.sourceAdapterReady.val
        check "Compiled" in vm.storyNames
        check vm.sourceBindingMetadataHash == repeat('a', 40)
        check vm.controlAsyncCommandAdapter != nil
        check vm.livePreviewReloadGeneration.val == reloads + 1
        vm.sourceProjectMappingDispose()
        dispose()

    test "a binding changed before the first catalog arrives keeps it out":
      createRoot proc(dispose: proc()) =
        let base = sourceProject()
        let vm = createEditorVM(base)
        vm.attachSourceProject(base, catalog = catalogReply("Stale"))
        let key = PropertyBindingKey(elementId: "action", propertyName: "background-color")
        vm.bindPropertyToVariable(key, "color/surface")
        drainCallbacks()
        check not vm.sourceAdapterReady.val
        check "Stale" notin vm.storyNames
        check vm.sourceBindingMetadataHash.len == 0
        check vm.controlAsyncCommandAdapter == nil
        check vm.propertyBindingFor(key).isSome
        vm.sourceProjectMappingDispose()
        dispose()

    test "a metadata save sent before the first catalog arrives keeps it out":
      createRoot proc(dispose: proc()) =
        let base = sourceProject()
        let vm = createEditorVM(base)
        var requests: seq[JsonNode] = @[]
        vm.controlSourceTransport = proc(request: JsonNode; done: proc(data: JsonNode) {.closure.}) =
          requests.add request
        let saved = repeat('b', 40)
        vm.sourceBindingMetadataHash = saved
        vm.attachSourceProject(base, catalog = catalogReply("Stale"))
        vm.sourceBindingMetadataSave(nil)
        check requests.len == 1
        check requests[0]{"command"}.getStr() == "bindings-save"
        drainCallbacks()
        check not vm.sourceAdapterReady.val
        check "Stale" notin vm.storyNames
        check vm.sourceBindingMetadataHash == saved
        check vm.controlAsyncCommandAdapter == nil
        vm.sourceProjectMappingDispose()
        dispose()

    test "opening another workspace before the first catalog arrives keeps it out":
      createRoot proc(dispose: proc()) =
        let base = sourceProject()
        let vm = createEditorVM(base)
        vm.attachSourceProject(base, catalog = catalogReply("Stale"))
        vm.applyWorkspace(newEditorWorkspace("Other", @[], id = "other"))
        drainCallbacks()
        check vm.workspaceEditStage.val != wesFailed
        check vm.workspaceEditDiagnostics.val.len == 0
        check "Stale" notin vm.storyNames
        check vm.controlAsyncCommandAdapter == nil
        vm.sourceProjectMappingDispose()
        dispose()
