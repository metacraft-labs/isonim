## Style provenance: the DSL captures authored syntax, the editor reads it.
##
## Three claims, in the order they have to be true:
##
## 1. A production build pays NOTHING. Same standard as
##    `tests/test_scene_graph_hooks.nim`: compile a real fixture through the
##    real DSL with the real backend and read the generated JavaScript. See
##    "WHICH ASSERTION IS LOAD-BEARING" below -- every assertion here was
##    checked by deliberately breaking the thing it guards and watching this
##    file fail.
## 2. An editor build records provenance that MEANS something -- the fixture
##    is run natively so it can print what it decoded, because "a string
##    appears in a bundle" is not the claim.
## 3. The editor can tell a binding from a literal. The ViewModel arm feeds
##    `previewDomElementRef` the payload the DSL actually produced, lifted out
##    of the fixture's own SSR output, rather than one this test encoded for
##    itself. A test that encodes its own input proves the decoder agrees with
##    the test, not that it agrees with the DSL.

import std/[unittest, os, osproc, strutils, strformat, options, algorithm,
            sequtils]
import isonim/core/[signals, owner]
import isonim/editor/viewmodels

const
  repoRoot = currentSourcePath().parentDir.parentDir
  srcPath = repoRoot / "src"
  fixture = repoRoot / "tests" / "fixtures" / "style_provenance_fixture.nim"

  # --- The sentinels -------------------------------------------------------
  #
  # Each one is a string that can ONLY have come from the provenance payload.
  # That qualification does the work. The obvious candidates are all
  # disqualified: the class name `zc-not-a-class` is legitimately in the
  # production bundle (it IS the rendered class attribute), and so is
  # `var(--zc-space-token)` (it IS the rendered attribute value). Asserting
  # their absence would be asserting that the page does not render.
  #
  # What is left is the WIRE FORMAT -- `property|value|kind|detail|token|note`
  # with `|` separators -- and the diagnostic prose, neither of which exists
  # anywhere outside an encoded `StyleBinding`.
  ssrAttribute = "data-isonim-props"          ## the SSR transport
  recorder = "recordProperties"               ## the client-mode recorder
  tokenRecord = "|tok|attr:padding|zc-space-token|"
  classRecord = "|cls|class:p-4|"
  unresolvedProse = "compile-time class index"

proc buildJs(defines, outFile, cacheDir: string): tuple[ok: bool, js: string] =
  removeDir(cacheDir)
  let cmd = &"nim js --hints:off --verbosity:0 --path:{srcPath} {defines} " &
            &"--nimcache:{cacheDir} -o:{outFile} {fixture}"
  let (_, code) = execCmdEx(cmd)
  if code != 0 or not fileExists(outFile):
    return (false, "")
  (true, readFile(outFile))

proc runNative(): string =
  let exe = getTempDir() / "style_provenance_native"
  let (output, code) = execCmdEx(
    &"nim c -r --hints:off --verbosity:0 --path:{srcPath} -d:isonimEditor " &
    &"-o:{exe} {fixture}")
  if code != 0:
    return ""
  output

func htmlAttrUnescape(s: string): string =
  s.multiReplace(("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"),
                 ("&amp;", "&"))

proc payloads(html: string): seq[string] =
  ## Every `data-isonim-props` value in the fixture's own SSR output, in
  ## document order. This is the wire, read off the wire.
  var i = 0
  let needle = ssrAttribute & "=\""
  while true:
    let start = html.find(needle, i)
    if start < 0: break
    let valueStart = start + needle.len
    let stop = html.find('"', valueStart)
    if stop < 0: break
    result.add html[valueStart ..< stop].htmlAttrUnescape()
    i = stop + 1

proc fixtureOutput(): string =
  let output = runNative()
  doAssert output.len > 0, "the fixture failed to build or run natively"
  output

proc ssrHtml(output: string): string =
  for line in output.splitLines():
    if line.startsWith("ssr-html="):
      return line["ssr-html=".len .. ^1]
  ""

proc domRef(file: string; line: int; className, color, padding, wire: string;
            elementId = ""): ElementRef =
  ## Named-argument wrapper over `previewDomElementRef`. Its 25 positional
  ## strings are all computed-style fields and miscounting them silently
  ## shifts the payload into `layerTreeJson`, where it decodes to nothing and
  ## the test reports "no provenance" as a product defect. Naming the one
  ## argument this feature is about removes that failure mode.
  previewDomElementRef(
    StoryRenderMetadata(sourceFile: file, sourceLine: line),
    tag = "div", testId = "", className = className, role = "",
    elementPath = "", ancestry = "", sourceFile = file, sourceLine = line,
    display = "block", position = "static", backgroundColor = "",
    color = color, padding = padding, margin = "", width = "", height = "",
    borderRadius = "", borderWidth = "", borderStyle = "", borderColor = "",
    fontSize = "", fontWeight = "", lineHeight = "", boxShadow = "",
    opacity = "", rectWidth = "", rectHeight = "", textContent = "provenance",
    elementId = elementId, sourceKey = "", schemaKey = "", ancestorIds = "",
    layerTreeJson = "", styleBindings = wire)

proc propNamed(props: seq[PropertyInfo]; name: string): PropertyInfo =
  for p in props:
    if p.name == name:
      return p
  PropertyInfo()

suite "DSE style provenance":

  test "a production build carries no trace of style provenance":
    let outFile = getTempDir() / "dse_prod.js"
    let (ok, js) = buildJs("", outFile, getTempDir() / "dse_prod_cache")
    check ok

    # The SSR transport. Guarded by the same `when sceneGraphEnabled` that
    # guards `data-isonim-src`, and the fixture CALLS its SSR proc, so the
    # code that would stamp this is genuinely emitted -- the attribute's
    # absence is a fact about the guard, not about dead-code elimination.
    check not js.contains(ssrAttribute)

    # The client-mode recorder must not be reachable.
    check not js.contains(recorder)

    # The payload itself, in both of its spellings. A production build
    # resolves `noteProperties` to the no-op template in
    # `dsl/scene_graph_hooks_off.nim`, whose arguments are never referenced.
    check not js.contains(tokenRecord)
    check not js.contains(classRecord)

    # The diagnostic prose for a class that resolves to nothing.
    check not js.contains(unresolvedProse)

    # WHICH ASSERTION IS LOAD-BEARING, and how that was established.
    #
    # Every check above was verified to FAIL under a matching sabotage of the
    # production code, one sabotage at a time, with the sabotage reverted
    # afterwards. This is the standard `test_scene_graph_hooks.nim` set after
    # an earlier version of it passed under sabotage and was deleted:
    #
    #  * SSR guard. Deleting the `when sceneGraphEnabled:` line around the
    #    `data-isonim-props` emission in `dsl/ui.nim` (and de-indenting its
    #    body) puts the attribute and both records into the production
    #    bundle. `ssrAttribute`, `tokenRecord`, `classRecord` and
    #    `unresolvedProse` all fail.
    #
    #  * Client no-op. Changing `noteProperties` in
    #    `dsl/scene_graph_hooks_off.nim` from `discard` to
    #    `let sink {.used.} = bindings & id` puts the encoded payload into
    #    the bundle through the client arm. `tokenRecord`, `classRecord` and
    #    `unresolvedProse` fail; `ssrAttribute` does NOT, which is exactly
    #    why the payload sentinels are here as well as the attribute name.
    #
    # Note what is NOT asserted: that a sentinel passed through an argument
    # the template ignores is absent. `discard <literal>` is elided by Nim
    # regardless of whether the seam works, so such a check passes under
    # sabotage and proves nothing. `test_scene_graph_hooks.nim` removed one
    # for that reason; this file never had one. The sentinels above are all
    # strings the payload must be BUILT from, not strings handed to a
    # function that drops them.

  test "an editor build emits the provenance the production build omits":
    # The complement, and it is not decoration: every absence asserted above
    # is only evidence if the thing could have been present. If the fixture
    # stopped producing a payload, the production test would still pass and
    # would be measuring nothing.
    let outFile = getTempDir() / "dse_ed.js"
    let (ok, js) = buildJs("-d:isonimEditor", outFile,
                           getTempDir() / "dse_ed_cache")
    check ok
    check js.contains(ssrAttribute)
    check js.contains(recorder)
    check js.contains(tokenRecord)
    check js.contains(classRecord)
    check js.contains(unresolvedProse)

  test "an editor build records provenance that decodes to distinct kinds":
    # Run natively so the fixture can print what it recorded. The claim is
    # that the four authored constructs stay four DIFFERENT things, which a
    # substring search over a bundle cannot show.
    let output = fixtureOutput()
    check output.contains("records=4")
    check output.contains("kind=cls property=padding detail=class:p-4")
    check output.contains("kind=tok property=padding detail=attr:padding" &
                          " token=zc-space-token")
    check output.contains("kind=sty property=color detail=attr:color")
    # Requirement 8: the class that resolves to nothing is RECORDED, not
    # skipped. `expandTailwindClasses` documents that it silently skips such
    # a class; this is the line that says it no longer does.
    check output.contains("kind=? property= detail=class:zc-not-a-class")
    check output.contains("unresolved=1")
    check output.contains("page-unresolved=1")

suite "DSE the inspector tells a binding from a literal":

  test "the same computed value decodes to a binding or a literal by origin":
    let html = fixtureOutput().ssrHtml()
    check html.len > 0
    let wire = html.payloads()
    check wire.len == 2

    # The inner element: `padding = "var(--zc-space-token)"` beside
    # `color = "#123456"`. The browser hands the editor `12px` and
    # `rgb(18, 52, 86)`; both are resolved values and neither remembers how it
    # was written. The payload does.
    let inner = domRef("fixture.nim", 35, "", "rgb(18, 52, 86)", "12px", wire[1])

    let padding = inner.properties.propNamed("padding")
    let color = inner.properties.propNamed("color")

    # Before this change both of these were `poInherited`, because a computed
    # style is all the bridge had and `poInherited` was the only claim about
    # it that was not a guess.
    check padding.origin == poThemeToken
    check padding.tokenName == "zc-space-token"
    check padding.originDetail == "attr:padding"
    check padding.isTokenBound()
    # A token-backed value is not this element's to rewrite in place.
    check padding.directStyleAllowed == false

    check color.origin == poSetStyle
    check color.originDetail == "attr:color"
    check color.tokenName == ""
    check not color.isTokenBound()
    check color.directStyleAllowed

    # The value itself is untouched: the editor still shows and edits what
    # the element actually renders.
    check padding.value == "12px"
    check color.value == "rgb(18, 52, 86)"

  test "a class-backed property names the class, not the element":
    let html = fixtureOutput().ssrHtml()
    let wire = html.payloads()
    let outer = domRef("fixture.nim", 34, "p-4 zc-not-a-class", "", "16px", wire[0])
    let padding = outer.properties.propNamed("padding")
    check padding.origin == poTailwindClass
    check padding.originDetail == "class:p-4"
    check padding.directStyleAllowed == false

  test "an unresolvable class is visible on the selected element":
    # `Styling-Substrate-Evaluation.md` 7.4, the eighth requirement: silence
    # is the defect. A class that contributes nothing must say so.
    let wire = fixtureOutput().ssrHtml().payloads()
    let diagnostics = styleBindingDiagnostics(wire[0], "fixture.nim", 34)
    check diagnostics.len == 1
    check diagnostics[0].kind == pedUnresolvedStyleBinding
    check diagnostics[0].message.contains("class:zc-not-a-class")
    check diagnostics[0].message.contains("resolves to no properties")
    check diagnostics[0].file == "fixture.nim"
    # The element that resolved cleanly produces none.
    check styleBindingDiagnostics(wire[1], "fixture.nim", 35).len == 0

  test "an inline declaration outranks a class for the same property":
    # Both constructs set `padding`; the browser already decided which won.
    # The editor has to name the construct the user must edit, so it has to
    # agree -- inline beats class, which is the cascade, not a heuristic.
    let bindings = @[
      StyleBinding(property: "padding", value: "16", kind: sbkClassUtility,
                   detail: "class:p-4"),
      StyleBinding(property: "padding", value: "20px", kind: sbkStyleAttr,
                   detail: "attr:padding")]
    check bindings.winningBinding("padding").detail == "attr:padding"
    # …and the authored order does not change that.
    check bindings.reversed().winningBinding("padding").detail == "attr:padding"

suite "DSE the headless editor consumes provenance":

  test "selecting an element publishes its bindings and its diagnostics":
    let wire = fixtureOutput().ssrHtml().payloads()
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[
        FoundationTokenEntry(key: "zc-space-token", kind: ftkSpacingScale,
          value: "12px", sourceFile: "tokens.nim", sourceLine: 7)]

      let inner = domRef("fixture.nim", 35, "", "rgb(18, 52, 86)", "12px", wire[1],
        elementId = "inner")
      check vm.selectInspectorElement(inner)

      # THE DEMONSTRATION. `inspectorBindingFor` has been the inspector's
      # read path since VBIND-M1 and its own doc comment says it "returns
      # `none` for every row today" because nothing seeds the table. The
      # authored token reference seeds it, and the authored literal does not.
      let bound = vm.inspectorBindingFor("padding")
      check bound.isSome
      check bound.get.variableKey == "zc-space-token"
      check bound.get.state == vbsBound
      check bound.get.resolvedValue == "12px"
      check bound.get.sourceFileRef == "tokens.nim"
      check vm.inspectorBindingFor("color").isNone

      # The alias chain the cascade view renders. `StyleCascadeLayer` has
      # carried `tokenChain` all along with nothing to put in it.
      let padding = inner.properties.propNamed("padding")
      let layers = vm.styleCascadeLayers(padding)
      check layers.len > 0
      check layers[0].tokenChain == @["zc-space-token"]
      check layers[0].kind == sclFinalValue

      # The unresolved class on the OUTER element reaches the inspector.
      let outer = domRef("fixture.nim", 34, "p-4 zc-not-a-class", "", "16px", wire[0],
        elementId = "outer")
      check vm.selectInspectorElement(outer)
      check vm.inspector.editDiagnostics.val.len == 1
      check vm.inspector.editDiagnostics.val[0].kind ==
        pedUnresolvedStyleBinding
      check vm.unresolvedStyleBindingsForSelection().len == 1
      check vm.unresolvedStyleBindingsForSelection()[0].detail ==
        "class:zc-not-a-class"

      # A class-backed property is a shared-ownership edit, and the editor
      # already knew what to do with that once the origin was true. Neither
      # of these branches could ever be reached while every property was
      # stamped `poInherited`.
      let classProp = outer.properties.propNamed("padding")
      check vm.styleCascadeLayers(classProp).anyIt(it.kind == sclSharedClass)
      check vm.styleDiagnostics(classProp).anyIt(
        it.kind == sdkUnsafeDetachment)
      dispose()

  test "a token the foundations do not know is broken, not absent":
    # The failure mode requirement 8 exists to prevent: a binding that cannot
    # be resolved must be VISIBLE. `vbsBoundMissing` is the inspector's
    # existing broken-link state; dropping the binding would render the row
    # as a plain literal and lose the fact that the author asked for a token.
    let wire = fixtureOutput().ssrHtml().payloads()
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.foundations.tokens.val = @[]
      let inner = domRef("fixture.nim", 35, "", "rgb(18, 52, 86)", "12px", wire[1],
        elementId = "inner")
      check vm.selectInspectorElement(inner)
      let bound = vm.inspectorBindingFor("padding")
      check bound.isSome
      check bound.get.state == vbsBoundMissing
      check bound.get.variableKey == "zc-space-token"
      dispose()

  test "the selection echo does not silently downgrade the selection":
    # The same element is selected twice by design: the preview bridge selects
    # it from the DOM, where `data-isonim-props` lives, and the echo
    # re-selects it from a layer row, which is built from the scene-graph tree
    # and carries no provenance. Taking the echo verbatim made the chip and
    # the diagnostic appear and then vanish a few milliseconds later -- a
    # failure that looks exactly like the feature not working.
    let wire = fixtureOutput().ssrHtml().payloads()
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let withProvenance =
        domRef("fixture.nim", 34, "p-4 zc-not-a-class", "", "16px", wire[0],
        elementId = "echo-target")
      check vm.selectInspectorElement(withProvenance)
      check vm.inspector.editDiagnostics.val.len == 1

      # The echo: same element, same id, no payload.
      var echoed = withProvenance
      echoed.styleBindings = ""
      vm.inspector.selectElement(echoed)
      check vm.inspector.selectedElement.val.styleBindings == wire[0]
      check vm.inspector.editDiagnostics.val.len == 1

      # A DIFFERENT element must NOT inherit it.
      var other = withProvenance
      other.styleBindings = ""
      other.id = "somewhere-else"
      other.sourceKey = "somewhere-else"
      vm.inspector.selectElement(other)
      check vm.inspector.selectedElement.val.styleBindings == ""
      check vm.inspector.editDiagnostics.val.len == 0
      dispose()

  test "a selection with no provenance behaves exactly as before":
    # Every surface that is not an IsoNim-rendered element -- a hand-built
    # story fixture, a non-IsoNim preview document -- passes an empty payload,
    # and an empty payload must mean "no provenance available", never "no
    # bindings". Otherwise this feature would rewrite the model of every
    # property it knows nothing about.
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      let element = domRef("fixture.nim", 1, "", "rgb(18, 52, 86)", "12px", "",
        elementId = "plain")
      check vm.selectInspectorElement(element)
      for prop in element.properties:
        if prop.name != "text":
          check prop.origin == poInherited
          check prop.directStyleAllowed
      check vm.inspector.editDiagnostics.val.len == 0
      check vm.inspectorBindingFor("padding").isNone
      dispose()
