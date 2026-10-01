## Production catalog refresh preserves real ViewModel state. Static catalog
## data and fixture preview hooks isolate reactive composition and metadata;
## they substitute only producer output for these focused state tests. Registered
## native/GUI source tests exercise actual files, compiler and mounted rendering.
## No backend, source adapter or compiler behavior is mocked here.
import std/[unittest, json, strutils]
import isonim/core/[owner, signals, computation]
import isonim/editor
import isonim/editor/[workspace, control, source_catalog, preview_identity]

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
      vm.applyWorkspace(rebuilt)
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
      vm.applyWorkspace(sourceCatalogWorkspace(catalog, manifest, base))
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
