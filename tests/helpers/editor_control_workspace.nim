## Real compiled browser project for control acceptance. Project preview data is
## deliberately small; the editor, renderer, iframe bridge, RPC and CLI are the
## production implementations. No source adapter or command dispatcher is mocked.
import isonim/editor
import isonim/editor/browser

proc preview(story: StoryRef; platform: Platform): ProjectPreview =
  ProjectPreview(status: ppsRendered, story: story, title: story.name,
    documentHtml: "<!doctype html><html><head><title>" & story.name &
      "</title></head><body><main><h1>" & story.name &
      "</h1><button id='first' data-isonim-element-id='first'>First action</button>" &
      "<button id='second' data-isonim-element-id='second'>Second action</button>" &
      "</main></body></html>")

discard mountEditor(newEditorWorkspace("Control acceptance", @[
  StoryGroup(name: "Pages", kind: skPage, items: @[
    StoryItem(name: "Home", group: "Pages", kind: skPage),
    StoryItem(name: "Details", group: "Pages", kind: skPage)])],
  id = "control-acceptance", previewHook = preview,
  agentBackend = absAgentHarbor))
