## Real reactive owner/state and lossless metadata production on native/Node.
## MockRenderer supplies only a non-DOM host to verify renderer gating; it does
## not simulate browser readiness, source/compiler or Harbor outcomes. Real DOM
## loading, mounted content and saved load callbacks run in the companion GUI.
import std/[unittest, strutils]
import isonim/core/owner
import isonim/editor/[types, viewmodels, preview_identity]
import isonim/editor/views/preview_mount
import isonim/testing/mock_dom

suite "Requested preview document ownership":
  test "mount metadata preserves actual markup and existing story identity":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = MockRenderer().createElement("iframe")
      let html = "<!doctype html><html><head><!-- > --><script>const x='<head>Ü';</script></head><body data-x='>'>Exact &amp; text</body></html>"
      let first = requestedPreviewMountDocument(frame, state, html)
      let marker = "<meta name=\"isonim-mount-document\" content=\"1\">"
      check first.replace(marker, "") == html
      check first.startsWith("<!doctype html><html><head>" & marker)
      check state.documentGeneration == 1
      let next = requestedPreviewMountDocument(frame, state, html)
      check next.replace("<meta name=\"isonim-mount-document\" content=\"2\">", "") == html
      check state.documentGeneration == 2
      check requestedPreviewMountDocument(frame, state, "") == ""
      check state.documentGeneration == 3
      check state.readyDocumentGeneration == 0
      let story = StoryRef(group: "Cards", name: "Ü & button", kind: skComponent)
      let identified = identifiedPreviewDocument(html, story, 7)
      check identified.replace("<meta name=\"isonim-rendered-story\" content=\"Cards / Ü &amp; button\"><meta name=\"isonim-rendered-generation\" content=\"7\">", "") == html
      dispose()

  test "document replacement disposes the previous real reactive root exactly once":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = MockRenderer().createElement("iframe")
      var cleanups = 0
      createRoot do(unmount: proc()):
        state.dispose = unmount
        onCleanup proc() = inc cleanups
      discard requestedPreviewMountDocument(frame, state, "<body></body>")
      check cleanups == 1
      check state.dispose == nil
      discard requestedPreviewMountDocument(frame, state, "<body>next</body>")
      check cleanups == 1
      dispose()
      check cleanups == 1

  test "logical renderer retains non-DOM gating and unchanged-document bookkeeping":
    createRoot do(dispose: proc()):
      let state = newPreviewMountState()
      let frame = MockRenderer().createElement("iframe")
      let story = StoryRef(group: "Cards", name: "First", kind: skComponent)
      var hookCalls = 0
      let hook: PreviewMountHook = proc(story: StoryRef; host: PreviewMountHost) = inc hookCalls
      discard requestedPreviewMountDocument(frame, state, "<body></body>")
      mountPreviewInto(frame, story, hook, state, true)
      let generation = state.generation
      check state.lastStory == story
      check state.mountedDocumentGeneration == state.documentGeneration
      mountPreviewInto(frame, story, hook, state, false)
      check state.generation == generation
      state.cancelPendingPreviewMount()
      check state.generation > generation
      check hookCalls == 0
      dispose()

  test "view disposal retires requests and releases the actual owned mount root":
    var state: PreviewMountState
    var cleanups = 0
    createRoot do(dispose: proc()):
      state = newPreviewMountState()
      createRoot do(unmount: proc()):
        state.dispose = unmount
        onCleanup proc() = inc cleanups
      dispose()
    check cleanups == 1
    check state.ownerDisposed
    check state.dispose == nil
    let generation = state.generation
    let revision = state.documentGeneration
    let frame = MockRenderer().createElement("iframe")
    check requestedPreviewMountDocument(frame, state, "retired") == "retired"
    let hook: PreviewMountHook = proc(story: StoryRef; host: PreviewMountHost) = inc cleanups
    mountPreviewInto(frame, StoryRef(group: "Cards", name: "Other"), hook, state, true)
    check state.generation == generation
    check state.documentGeneration == revision
    check cleanups == 1
