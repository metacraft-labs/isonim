## No mocks: production CSS/markup/catalog binding logic reads real temporary
## source files. Static catalog rows are ordinary input fixtures for precise
## ambiguity/conditional/token contracts; real SSR/compiler/native/browser paths
## are separately exercised by test_editor_source_style_provider.py and GUI.
## A static row is a compiled page: it loads its stylesheets in `<style>`
## elements, as a project page embeds the constant (`page` below), because a
## stylesheet binds only the elements of pages that load it.
import std/[unittest, json, os, tempfiles, strutils]
import isonim/editor/[source_style_bindings, source_catalog, css_patch, source_style_values, viewmodels, types]

proc page(body, source: string; consts = @["styles"]): string =
  ## `body` as a compiled page that loads `consts` of `source` (Nim text).
  for name in consts: result.add "<style>" & nimConstBody(source, name) & "</style>"
  result.add body

proc pageCatalog(body, source: string; consts = @["styles"]): JsonNode =
  %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":page(body, source, consts)}]}

suite "Compiler owned stylesheet capabilities":
  test "optional arrays preserve old catalogs and malformed contracts refuse":
    let catalog = %* {"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel'>雪</div>"}]}
    let old = %* {"fixtures":[]}
    check compiledStyleBindings(catalog,old,proc(file:string):string = raise newException(ValueError,"No source should be read")).len == 0
    check sourceCatalogMarkup(catalog,old) == catalog
    for value in [%false, %"unexpected", newJObject()]:
      let invalid = %* {"fixtures":[],"editableStyleSources":value}
      expect ValueError:
        discard compiledStyleBindings(catalog,invalid,proc(file:string):string = "")
    check compiledStyleBindings(catalog,%*{"editableStyleSources":[]},proc(file:string):string = "").len == 0

  test "actual source literals bind exact selectors; tokens conditions and competition refuse":
    let directory = createTempDir("isonim-style-binding-","")
    defer: removeDir(directory)
    let source = directory / "styles.nim"
    writeFile(source,"const styles* = \"\"\"\n.panel { border-radius:4px; height:100%; color:var(--ink); }\n.other { border-radius:8px; }\n@media (max-width:800px) { .panel { height:auto; } }\n\"\"\"\n")
    let catalog = pageCatalog("<div class='panel'></div><div class='panel'></div><div class='panel other'></div><div class='panel-long'></div>", readFile(source))
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["border-radius","height","color"]}]}
    # As the native build records it: the page embeds these constants, so a
    # later edit of the source (below) still binds the same elements.
    recordEmbeddedStylesheets(catalog, manifest, proc(file:string):string = readFile(directory / file))
    let bindings = compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file))
    check bindings.len == 2
    for binding in bindings:
      check binding["selector"].getStr() == ".panel"
      check binding["sharedCount"].getInt() == 3 # Includes the real ambiguous matching instance.
      check binding["values"] == %*{"border-radius":"4px","border-top-left-radius":"4px","border-top-right-radius":"4px","border-bottom-right-radius":"4px","border-bottom-left-radius":"4px"}
      check binding["scope"].getStr() == "shared-class"
      check binding["sourceHash"].getStr().len == 40
    let firstId = bindings[0]["elementId"].getStr()
    writeFile(source,readFile(source).replace("border-radius:4px", "border-radius:5px"))
    let next = compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file))
    check next[0]["elementId"].getStr() == firstId
    check next[0]["sourceHash"] != bindings[0]["sourceHash"]
    check next[0]["values"] == %*{"border-radius":"5px","border-top-left-radius":"5px","border-top-right-radius":"5px","border-bottom-right-radius":"5px","border-bottom-left-radius":"5px"}

  test "CSS projection retains existing patch ownership and complete declaration comments":
    let literals = cssUnconditionalLiterals(".card { width:20px; color:#fff; /* preserved comment */ } @media (max-width:800px) { .card { width:10px; } }", @["width","color"])
    check literals.len == 1
    check literals[0].selector == ".card"
    check literals[0].values == @[("color","#fff")]

  test "derived side ownership follows actual CSS declaration order":
    let directory = createTempDir("isonim-style-order-","")
    defer: removeDir(directory)
    let source = directory / "styles.nim"
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["padding","border-radius"]}]}
    for (css,expectedOwner) in [("padding-left:2px; padding:4px; border-top-left-radius:2px; border-radius:4px;", "derived"),
        ("padding:4px; padding-left:2px; border-radius:4px; border-top-left-radius:2px;", "explicit")]:
      writeFile(source,"const styles* = \"\"\".panel { " & css & " }\"\"\"")
      let catalog = pageCatalog("<div class='panel'></div>", readFile(source))
      let bindings = compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file))
      check bindings.len == 1
      let binding = bindings[0]
      let expectedValue = if expectedOwner == "derived": "4px" else: "2px"
      check binding["values"]["padding-left"].getStr() == expectedValue
      check binding["values"]["border-top-left-radius"].getStr() == expectedValue
      check binding["sourceDeclarations"]["padding-left"]["property"].getStr() == (if expectedOwner == "derived": "padding" else: "padding-left")
      check binding["sourceDeclarations"]["border-top-left-radius"]["property"].getStr() == (if expectedOwner == "derived": "border-radius" else: "border-top-left-radius")
    check patchCssQuad("padding","2px 4px","8px",1) == "2px 8px 2px 4px"
    check patchCssQuad("padding","2px 8px 2px 4px","4px",1,"2px 4px") == "2px 4px"
    check patchCssQuad("padding","6px 8px 2px 4px","4px",1,"2px 4px") == ""
    check patchCssQuad("padding","2px 4px","4px",1,"2px; color:red") == ""

  test "literal root token owners preserve variable name case and priority refusal":
    let directory = createTempDir("isonim-style-token-","")
    defer: removeDir(directory)
    let source = directory / "styles.nim"
    writeFile(source,"const styles* = \"\"\".panel { color:var(--Panel); background:var(--panel); border-color:var(--priority); }\"\"\"\nconst tokens* = \"\"\":root { --Panel:#112233; --panel:#445566; --priority:#778899 !IMPORTANT; }\"\"\"\n")
    let catalog = pageCatalog("<div class='panel'></div><div class='panel'></div>", readFile(source), @["styles", "tokens"])
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["color","background","border-color"]},{"file":"styles.nim","const":"tokens","properties":["--Panel","--panel","--priority"]}]}
    let bindings = compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file))
    check bindings.len == 4
    for binding in bindings:
      check binding["scope"].getStr() == "semantic-token"
      check binding["sharedCount"].getInt() == 2
      check binding["values"]{"border-color"} == nil
      if binding["tokenName"].getStr() == "--Panel":
        check binding["values"]["color"].getStr() == "#112233"
      else:
        check binding["tokenName"].getStr() == "--panel"
        check binding["values"]["background-color"].getStr() == "#445566"
    let patched = patchCssInNimConstAt(readFile(source),"tokens",":root","--Panel","#abcdef",1440)
    check patched.ok
    check patched.content == readFile(source).replace("--Panel:#112233","--Panel:#abcdef")

  test "duplicate owners refuse while quoted declarations cannot become capabilities":
    let duplicate = cssUnconditionalLiterals(".panel { padding:4px; padding:8px; } :root { --panel:#111111; --panel:#222222; }", @["padding","--panel"])
    check duplicate.len == 0
    let quoted = ".panel { content:'padding:4px; --panel:#000000'; padding:8px; }"
    let literals = cssUnconditionalLiterals(quoted,@["padding","--panel"])
    check literals.len == 1
    check literals[0].values == @[("padding","8px")]
    let source = "const styles* = \"\"\"" & quoted & "\"\"\""
    let patch = patchCssInNimConstAt(source,"styles",".panel","padding","10px",1440)
    check patch.ok
    check patch.content == source.replace("'; padding:8px;","'; padding:10px;")

  test "unsupported shorthand owners cannot authorize a misleading explicit side":
    let directory = createTempDir("isonim-style-overlap-","")
    defer: removeDir(directory)
    let source = directory / "styles.nim"
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["padding","border-radius"]}]}
    for tail in ["padding:4px; padding:8px; border-radius:4px; border-radius:8px;",
        "padding:8px !important; border-radius:8px !IMPORTANT;",
        "padding:4px; border-radius:4px; } @media (max-width:800px) { .panel { padding:8px; border-radius:8px;"]:
      writeFile(source,"const styles* = \"\"\".panel { padding-left:2px; border-top-left-radius:2px; " & tail & " }\"\"\"")
      let catalog = pageCatalog("<div class='panel'></div>", readFile(source))
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file)).len == 0

  test "scoped conditional duplicate and inline token owners prevent false root authority":
    let directory = createTempDir("isonim-style-token-scope-","")
    defer: removeDir(directory)
    let source = directory / "styles.nim"
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background"]},{"file":"styles.nim","const":"tokens","properties":["--panel"]}]}
    for css in [".panel { --panel:#000000; background:var(--panel); }",
        ".host { --panel:#000000; } .panel { background:var(--panel); }",
        ".panel { background:var(--panel); } @media (max-width:800px) { :root { --panel:#000000; } }",
        ".panel { background:var(--panel); } :root { --panel:#000000; }"]:
      writeFile(source,"const styles* = \"\"\"" & css & "\"\"\"\nconst tokens* = \"\"\":root { --panel:#ffffff; }\"\"\"")
      let catalog = pageCatalog("<div class='host'><div class='panel'></div></div>", readFile(source), @["styles", "tokens"])
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file)).len == 0
    writeFile(source,"const styles* = \"\"\".panel { background:var(--panel); }\"\"\"\nconst tokens* = \"\"\":root { --panel:#ffffff; }\"\"\"")
    let inlineCatalog = pageCatalog("<div class='panel' style='--panel : #000000'></div>", readFile(source), @["styles", "tokens"])
    check compiledStyleBindings(inlineCatalog,manifest,proc(file:string):string = readFile(directory / file)).len == 0

  test "exposed corner longhands validate finite nonnegative spatial lengths":
    for property in ["border-top-left-radius","border-top-right-radius","border-bottom-right-radius","border-bottom-left-radius"]:
      for value in ["8px","2em","12%","0"]:
        check validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
          PropertyEditRequest(property:property,newValue:value,kind:pekCss),parseCssPropertyValue(property,value)).len == 0
      for value in ["8","-2px","NaNpx","Infinitypx","1e999px","8ms","2s","4garbage"]:
        check validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
          PropertyEditRequest(property:property,newValue:value,kind:pekCss),parseCssPropertyValue(property,value)).len > 0

  test "native color validation accepts complete finite forms and rejects prefixes":
    for raw in ["#1234", "rgb(18, 52, 86)", "rgba(18, 52, 86, .5)",
        "rgb(10% 20% 30% / 50%)", "hsl(120deg, 50%, 25%)", "hsla(1turn, 50%, 25%, .5)", "rgba(18,52,86)", "hsla(120,50%,25%)", "hsl(10 50 50)"]:
      check validateCssPropertyValue(PropertyInfo(name:"background-color",directStyleAllowed:true),
        PropertyEditRequest(property:"background-color",newValue:raw),
        parseCssPropertyValue("background-color",raw)).len == 0
    for raw in ["rgb(NaN,2,3)","rgba(1,2,3,Infinity)","rgb(1e999,2,3)",
        "rgb(1,2)","rgb(1,2,3)junk","hsl(10,junk,20%)","rgb(1,,3)", "hsl(10%,50%,50%)", "rgb(10%,20,30)", "RGB(NaN,2,3)"]:
      check validateCssPropertyValue(PropertyInfo(name:"background-color",directStyleAllowed:true),
        PropertyEditRequest(property:"background-color",newValue:raw),
        parseCssPropertyValue("background-color",raw)).len > 0

  test "background current owner respects order and refuses unsupported resets outside allowlist":
    let body = "<div class='panel'></div>"
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background","background-color"]}]}
    for pair in [("background-color:#112233; background:#445566;", "background", "#445566"),
        ("background:#445566; background-color:#112233;", "background-color", "#112233"),
        ("background:linear-gradient(red,blue); background-color:#112233;", "background-color", "#112233"),
        ("background:#445566;", "background", "#445566")]:
      let source = "const styles* = \"\"\".panel { " & pair[0] & " }\"\"\""
      let bindings = compiledStyleBindings(pageCatalog(body, source),manifest,proc(file:string):string = source)
      check bindings.len == 1
      check bindings[0]["values"]["background-color"].getStr() == pair[2]
      check bindings[0]["sourceDeclarations"]["background-color"]["property"].getStr() == pair[1]
    for properties in [@["background-color"], @["background", "background-color"]]:
      let limited = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":properties}]}
      for css in ["background-color:#112233; background:#445566 !important;",
          "background-color:#112233; background:#445566; background:#778899;",
          "background-color:#112233; background:linear-gradient(red,blue);",
          "background:#445566; background-color:#112233 !important;",
          "background-color:#112233; } @media(min-width:100px) { .panel { background:#445566;"]:
        let source = "const styles* = \"\"\".panel { " & css & " }\"\"\""
        let bindings = compiledStyleBindings(pageCatalog(body, source),limited,proc(file:string):string = source)
        for binding in bindings:
          check binding["values"]{"background-color"} == nil
    let shorthandOnly = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background"]}]}
    let shadowed = "const styles* = \"\"\".panel { background:#445566; background-color:#112233; }\"\"\""
    check compiledStyleBindings(pageCatalog(body, shadowed),shorthandOnly,proc(file:string):string = shadowed).len == 0
    let supportedAlias = "const styles* = \"\"\".panel { background-color:#112233; background:#445566; }\"\"\""
    let alias = compiledStyleBindings(pageCatalog(body, supportedAlias),shorthandOnly,proc(file:string):string = supportedAlias)
    check alias.len == 1
    check alias[0]["values"]["background-color"].getStr() == "#445566"
    check alias[0]["sourceDeclarations"]["background-color"]["property"].getStr() == "background"
    let restricted = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background-color"]}]}
    let winning = "const styles* = \"\"\".panel { background:linear-gradient(red,blue); background-color:#112233; }\"\"\""
    check compiledStyleBindings(pageCatalog(body, winning),restricted,proc(file:string):string = winning)[0]["values"]["background-color"].getStr() == "#112233"

  test "provider current origin cannot impersonate inline conditional or unknown selector owner":
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["width"]}]}
    for pair in [(".panel { width:10px; }", "<div id='action' class='panel' style='width:20px'></div>"),
        (".panel { width:10px; } @media(min-width:100px) { #action { width:20px; } }", "<div id='action' class='panel'></div>"),
        (".panel { width:10px; } div.panel:hover { width:20px; }", "<div id='action' class='panel'></div>")]:
      let source = "const styles* = \"\"\"" & pair[0] & "\"\"\""
      let catalog = pageCatalog(pair[1], source)
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0
    for unrelated in [".other:hover { width:20px; }", ".other[data-kind=\"panel\"] { width:20px; }", ".panel[data-kind=\"other\"] .other:hover { width:20px; }", ".panel .other:hover { width:20px; }",
        ".other > button:hover { width:20px; }", "@media(min-width:100px) { .host .other { width:20px; } }"]:
      let source = "const styles* = \"\"\".panel { width:10px; } " & unrelated & "\"\"\""
      let catalog = pageCatalog("<div class='panel'></div>", source)
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 1
    for ambiguous in [".other .panel:hover { width:20px; }", ".panel[data-kind=\"other\"] { width:20px; }", ".host > .panel { width:20px; }",
        "[data-kind='other'] { width:20px; }", ".other\\:escaped { width:20px; }",
        "@media(min-width:100px) { .host .panel { width:20px; } }"]:
      let source = "const styles* = \"\"\".panel { width:10px; } " & ambiguous & "\"\"\""
      let catalog = pageCatalog("<div class='panel'></div>", source)
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0

  test "all reset refuses ordinary current origins but preserves CSS exceptions":
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["width","background-color","direction","unicode-bidi","--panel"]}]}
    for tail in ["all:initial;", "all:unset !important;", "} @media(min-width:100px) { #action { all:initial;",
        "} .panel[data-kind=active] { all:initial;", "} .panel:hover { all:initial;", "} .host .panel { all:initial;"]:
      let source = "const styles* = \"\"\".panel { width:40px; background-color:#112233; " & tail & " }\"\"\""
      let catalog = pageCatalog("<div id='action' class='panel'></div>", source)
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0
    let source = "const styles* = \"\"\".panel { width:40px; background-color:#112233; }\"\"\""
    let inline = pageCatalog("<div class='panel' style='all:initial'></div>", source)
    check compiledStyleBindings(inline,manifest,proc(file:string):string = source).len == 0
    for unrelated in [".panel .other:hover { all:initial; }", ".other[data-kind=active] { all:initial; }",
        "@media(min-width:100px) { .host .other { all:initial; } }"]:
      let text = "const styles* = \"\"\".panel { width:40px; background-color:#112233; } " & unrelated & "\"\"\""
      check compiledStyleBindings(pageCatalog("<div id='action' class='panel'></div>", text),manifest,proc(file:string):string = text).len == 1
    let exceptions = "const styles* = \"\"\".panel { direction:rtl; unicode-bidi:isolate; all:initial; } :root { --panel:#112233; all:initial; }\"\"\""
    let result = compiledStyleBindings(pageCatalog("<div id='action' class='panel'></div>", exceptions),manifest,proc(file:string):string = exceptions)
    check result.len == 1
    check result[0]["values"] == %*{"direction":"rtl","unicode-bidi":"isolate"}
    let token = "const styles* = \"\"\".panel { background-color:var(--panel); } :root { --panel:#112233; all:initial; }\"\"\""
    let tokens = compiledStyleBindings(pageCatalog("<div id='action' class='panel'></div>", token),manifest,proc(file:string):string = token)
    check tokens.len == 1
    check tokens[0]["values"]["background-color"].getStr() == "#112233"
    check tokens[0]["tokenName"].getStr() == "--panel"
    let rootReset = "const styles* = \"\"\".panel { width:40px; background-color:#112233; } :root { all:initial; }\"\"\""
    let htmlRoot = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<html class='panel'><head><style>" & nimConstBody(rootReset, "styles") & "</style></head><body></body></html>"}]}
    check compiledStyleBindings(htmlRoot,manifest,proc(file:string):string = rootReset).len == 0

suite "A stylesheet binds only the pages that load it":
  # isonim-pm issue 2026-10-17-compiled-bindings-match-elements-in-stories-
  # that-do-not-load-their-stylesheet; editor spec "Saving": an edit changes
  # the one declaration that owns the element's property, and a rule from a
  # stylesheet the page does not load owns none of its elements' styles.
  const source = "const cardStyles* = \"\"\"\n.chip { opacity:0.5; }\n#action { width:120px; }\n\"\"\"\n" &
    "const alternateStyles* = \"\"\"\n#alternate { width:180px; }\n\"\"\"\n"
  let manifest = %*{"editableStyleSources":[
    {"file":"s.nim","const":"cardStyles","properties":["opacity","width"]},
    {"file":"s.nim","const":"alternateStyles","properties":["width"]}]}
  proc story(group, styles, body: string): JsonNode =
    %*{"group":group,"name":"Ready","kind":"component",
      "documentHtml":"<!doctype html><html><head><title>t</title>" & styles & "</head><body>" & body & "</body></html>"}
  proc style(css: varargs[string]): string =
    for text in css: result.add "<style>" & text & "</style>"
  proc rows(bindings: JsonNode): seq[string] =
    for binding in bindings:
      var properties: seq[string]
      for property, value in binding["values"]: properties.add property & "=" & value.getStr()
      result.add binding["storyId"].getStr() & " " & binding["elementId"].getStr() & " " &
        binding["selector"].getStr() & " " & properties.join(",") & " shared " & $binding["sharedCount"].getInt()
  let card = nimConstBody(source, "cardStyles")
  let alternate = nimConstBody(source, "alternateStyles")
  let read = proc(file: string): string = source

  test "a rule binds the elements of the stories whose page loads its stylesheet, and no others":
    let catalog = %*{"stories":[
      story("Card", style(card), "<button id='action' class='chip' data-isonim-element-id='action'></button>"),
      story("Alternate", style(alternate), "<button id='alternate' class='chip' data-isonim-element-id='alternate'></button>")]}
    check rows(compiledStyleBindings(catalog, manifest, read)) == @[
      "Card / Ready action .chip opacity=0.5 shared 1",
      "Card / Ready action #action width=120px shared 1",
      "Alternate / Ready alternate #alternate width=180px shared 1"]
    # The same element in a page that loads both (one <style> holding both,
    # as a page concatenating constants does) is bound to both.
    let both = %*{"stories":[
      story("Card", style(card), "<button id='action' class='chip' data-isonim-element-id='action'></button>"),
      story("Alternate", style(alternate & card), "<button id='alternate' class='chip' data-isonim-element-id='alternate'></button>")]}
    check rows(compiledStyleBindings(both, manifest, read)) == @[
      "Card / Ready action .chip opacity=0.5 shared 2",
      "Card / Ready action #action width=120px shared 1",
      "Alternate / Ready alternate .chip opacity=0.5 shared 2",
      "Alternate / Ready alternate #alternate width=180px shared 1"]

  test "a page that loads no stylesheet, or one only for print, binds nothing":
    for styles in ["", "<style media=\"print\">" & card & "</style>",
        "<template><style>" & card & "</style></template>", "<link rel=\"stylesheet\" href=\"card.css\">"]:
      let catalog = %*{"stories":[story("Card", styles, "<button id='action' class='chip'></button>")]}
      check compiledStyleBindings(catalog, manifest, read).len == 0
    let all = %*{"stories":[story("Card", "<style media=\"all\">" & card & "</style>", "<button id='action' class='chip'></button>")]}
    check compiledStyleBindings(all, manifest, read).len == 2

  test "a stylesheet whose text repeats part of a loaded one is not loaded by the repetition":
    # chipStyles' whole text is cardStyles' first rule; the page loads only
    # cardStyles, whose bytes claim it.
    let repeated = source & "const chipStyles* = \"\"\"\n.chip { opacity:0.5; }\n\"\"\"\n"
    let chips = %*{"editableStyleSources":[
      {"file":"s.nim","const":"cardStyles","properties":["opacity"]},
      {"file":"s.nim","const":"chipStyles","properties":["opacity"]}]}
    let catalog = %*{"stories":[story("Card", style(card), "<button class='chip' data-isonim-element-id='chip'></button>")]}
    check rows(compiledStyleBindings(catalog, chips, proc(file: string): string = repeated)) == @[
      "Card / Ready chip .chip opacity=0.5 shared 1"]
    # Embedded after it as well: both are loaded, and two .chip rules then
    # set opacity, so neither owns it alone.
    let twice = %*{"stories":[story("Card", style(card, nimConstBody(repeated, "chipStyles")),
      "<button class='chip' data-isonim-element-id='chip'></button>")]}
    check compiledStyleBindings(twice, chips, proc(file: string): string = repeated).len == 0

  test "a page embeds a constant's runtime value, without the newline after its opening quotes":
    # cardStyles' body starts with a newline that is not part of its value.
    check card.startsWith("\n")
    let catalog = %*{"stories":[story("Card", "<style>" & card[1 .. ^1] & "</style>", "<button id='action' class='chip' data-isonim-element-id='action'></button>")]}
    check rows(compiledStyleBindings(catalog, manifest, read)).len == 2

  test "a source with CRLF line ends is credited with the LF value its page embeds":
    # A checkout with Windows line ends: the compiled value has LF only.
    let crlf = source.replace("\n", "\r\n")
    check "\r\n" in nimConstBody(crlf, "cardStyles")
    let catalog = %*{"stories":[story("Card", style(card[1 .. ^1]), "<button id='action' class='chip' data-isonim-element-id='action'></button>")]}
    check rows(compiledStyleBindings(catalog, manifest, proc(file: string): string = crlf)) == @[
      "Card / Ready action .chip opacity=0.5 shared 1",
      "Card / Ready action #action width=120px shared 1"]
    recordEmbeddedStylesheets(catalog, manifest, proc(file: string): string = crlf)
    check catalog["stories"][0][embeddedStylesheetsField] == %*[{"file":"s.nim","const":"cardStyles"}]

  test "the longer constant claims its text before a shorter one listed first":
    # shortStyles is listed first and is a prefix of longStyles; the page
    # embeds only longStyles, so only it is credited.
    let pair = "const shortStyles* = \"\"\".chip { opacity:0.5; }\"\"\"\n" &
      "const longStyles* = \"\"\".chip { opacity:0.5; }\n#action { width:120px; }\"\"\"\n"
    let opted = %*{"editableStyleSources":[
      {"file":"s.nim","const":"shortStyles","properties":["opacity"]},
      {"file":"s.nim","const":"longStyles","properties":["width"]}]}
    let catalog = %*{"stories":[story("Card", style(nimConstBody(pair, "longStyles")),
      "<button id='action' class='chip' data-isonim-element-id='action'></button>")]}
    recordEmbeddedStylesheets(catalog, opted, proc(file: string): string = pair)
    check catalog["stories"][0][embeddedStylesheetsField] == %*[{"file":"s.nim","const":"longStyles"}]
    check rows(compiledStyleBindings(catalog, opted, proc(file: string): string = pair)) == @[
      "Card / Ready action #action width=120px shared 1"]

  test "a stylesheet embedded more than once is still loaded":
    let catalog = %*{"stories":[story("Card", style(card, card), "<button id='action' class='chip' data-isonim-element-id='action'></button>")]}
    check rows(compiledStyleBindings(catalog, manifest, read)) == @[
      "Card / Ready action .chip opacity=0.5 shared 1",
      "Card / Ready action #action width=120px shared 1"]

  test "a page is credited only with the stylesheets whose exact text it embeds":
    # Review P3: A and B overlap; the page embeds an un-opted N=[.card] and B
    # in one <style>, which has A's rule sequence but not A's text.
    let overlap = "const a* = \"\"\".card { width:1px; }\n.chip { opacity:0.5; }\"\"\"\n" &
      "const b* = \"\"\".chip { opacity:0.7; }\n.badge { opacity:1; }\"\"\"\n"
    let pair = %*{"editableStyleSources":[{"file":"s.nim","const":"a","properties":["width","opacity"]},
      {"file":"s.nim","const":"b","properties":["opacity"]}]}
    let page = %*{"stories":[story("Card", style(".card { width:2px; }\n" & nimConstBody(overlap, "b")),
      "<div class='card' data-isonim-element-id='card'></div><span class='chip' data-isonim-element-id='chip'></span>")]}
    check rows(compiledStyleBindings(page, pair, proc(file: string): string = overlap)) == @[
      "Card / Ready chip .chip opacity=0.7 shared 1"]
    # Review P3b: a foreign un-opted stylesheet with the same selector.
    let short = "const chip* = \"\"\".chip { width:44px; }\"\"\""
    let opted = %*{"editableStyleSources":[{"file":"s.nim","const":"chip","properties":["width"]}]}
    let foreign = %*{"stories":[story("Card", style(".chip { opacity:1; }"), "<span class='chip'></span>")]}
    check compiledStyleBindings(foreign, opted, proc(file: string): string = short).len == 0
    # Review P5/P5c: a and b share their rule sequence; the page embeds b
    # twice (in one <style>, or once per component instance): only b.
    let same = "const a* = \"\"\".chip { opacity:0.5; }\"\"\"\nconst b* = \"\"\".chip { width:10px; }\"\"\"\n"
    let ab = %*{"editableStyleSources":[{"file":"s.nim","const":"a","properties":["opacity"]},
      {"file":"s.nim","const":"b","properties":["width"]}]}
    let bText = nimConstBody(same, "b")
    for styles in [style(bText & bText), style(bText, bText), style(bText)]:
      let catalog = %*{"stories":[story("Card", styles, "<span class='chip' data-isonim-element-id='chip'></span>")]}
      check rows(compiledStyleBindings(catalog, ab, proc(file: string): string = same)) == @[
        "Card / Ready chip .chip width=10px shared 1"]

  test "stylesheets with the same text cannot be told apart and are not offered":
    # Each opts in a different property, so crediting either would offer it.
    let same = "const a* = \"\"\".chip { opacity:0.5; width:1px; }\"\"\"\nconst b* = \"\"\".chip { opacity:0.5; width:1px; }\"\"\"\n"
    let pair = %*{"editableStyleSources":[{"file":"s.nim","const":"a","properties":["opacity"]},
      {"file":"s.nim","const":"b","properties":["width"]}]}
    let text = nimConstBody(same, "a")
    for styles in [style(text), style(text, text)]:
      let catalog = %*{"stories":[story("Card", styles, "<span class='chip'></span>")]}
      check compiledStyleBindings(catalog, pair, proc(file: string): string = same).len == 0

  test "the build's record names the constants a page embeds while declarations are edited":
    let catalog = %*{"stories":[
      story("Card", style(card), "<button id='action' class='chip' data-isonim-element-id='action'></button>"),
      story("Alternate", style(alternate), "<button id='alternate' class='chip' data-isonim-element-id='alternate'></button>")]}
    let unrecorded = catalog.copy()
    recordEmbeddedStylesheets(catalog, manifest, read)
    check catalog["stories"][0][embeddedStylesheetsField] == %*[{"file":"s.nim","const":"cardStyles"}]
    check catalog["stories"][1][embeddedStylesheetsField] == %*[{"file":"s.nim","const":"alternateStyles"}]
    # Edited since the build (a value, a removed declaration, an added rule):
    # still loaded by the record, with the source's current values.
    let edited = source.replace("opacity:0.5;", "opacity:0.9;").replace("#action { width:120px; }", "#action { }\n.badge { opacity:1; }")
    check rows(compiledStyleBindings(catalog, manifest, proc(file: string): string = edited)) == @[
      "Card / Ready action .chip opacity=0.9 shared 1",
      "Alternate / Ready alternate #alternate width=180px shared 1"]
    # Without a record only a page holding the exact current text loads it:
    # the edited stylesheet is refused, the unedited one still binds.
    check rows(compiledStyleBindings(unrecorded, manifest, proc(file: string): string = edited)) == @[
      "Alternate / Ready alternate #alternate width=180px shared 1"]

  test "a stylesheet record the catalog's producer declares is used as declared":
    # The producer names cardStyles for a page whose <style> holds other
    # bytes, and nothing for the Alternate page that embeds cardStyles.
    let catalog = %*{"stories":[
      story("Card", style(".chip { opacity:1; }"), "<button id='action' class='chip' data-isonim-element-id='action'></button>"),
      story("Alternate", style(card), "<button id='alternate' class='chip' data-isonim-element-id='alternate'></button>")]}
    catalog["stories"][0][embeddedStylesheetsField] = %*[{"file":"s.nim","const":"cardStyles"}, {"file":"s.nim","const":"unknown"}]
    catalog["stories"][1][embeddedStylesheetsField] = %*[]
    recordEmbeddedStylesheets(catalog, manifest, read)
    check catalog["stories"][1][embeddedStylesheetsField] == %*[]
    check rows(compiledStyleBindings(catalog, manifest, read)) == @[
      "Card / Ready action .chip opacity=0.5 shared 1",
      "Card / Ready action #action width=120px shared 1"]

  test "a design token binds only where the page loads the stylesheet that defines it":
    let tokens = "const styles* = \"\"\".panel { color:var(--ink); }\"\"\"\nconst tokens* = \"\"\":root { --ink:#112233; }\"\"\"\n"
    let opted = %*{"editableStyleSources":[{"file":"s.nim","const":"styles","properties":["color"]},
      {"file":"s.nim","const":"tokens","properties":["--ink"]}]}
    let without = %*{"stories":[story("Card", style(nimConstBody(tokens, "styles")), "<div class='panel'></div>")]}
    check compiledStyleBindings(without, opted, proc(file: string): string = tokens).len == 0
    let loaded = %*{"stories":[story("Card", style(nimConstBody(tokens, "tokens") & nimConstBody(tokens, "styles")), "<div class='panel'></div>")]}
    let bound = compiledStyleBindings(loaded, opted, proc(file: string): string = tokens)
    check bound.len == 1
    check bound[0]["tokenName"].getStr() == "--ink"

  test "a rule of a stylesheet the page does not load does not decide another rule's ownership":
    # Both set #action's width (rivalStyles also for every button). Only
    # cardStyles is loaded by the page, so its rule alone owns it there.
    let rival = source & "const rivalStyles* = \"\"\"\n#action { width:999px; }\nbutton { width:1px; }\n\"\"\"\n"
    let opted = %*{"editableStyleSources":[{"file":"s.nim","const":"cardStyles","properties":["width"]},
      {"file":"s.nim","const":"rivalStyles","properties":["width"]}]}
    let catalog = %*{"stories":[story("Card", style(card), "<button id='action' data-isonim-element-id='action'></button>")]}
    check rows(compiledStyleBindings(catalog, opted, proc(file: string): string = rival)) == @[
      "Card / Ready action #action width=120px shared 1"]
    let loadsBoth = %*{"stories":[story("Card", style(card, nimConstBody(rival, "rivalStyles")), "<button id='action' data-isonim-element-id='action'></button>")]}
    check compiledStyleBindings(loadsBoth, opted, proc(file: string): string = rival).len == 0

  test "a re-offered declaration reaches only the pages that load its stylesheet":
    let reset = source.replace(".chip { opacity:0.5; }", ".chip { }")
    let catalog = %*{"stories":[
      story("Card", style(nimConstBody(reset, "cardStyles")), "<button id='action' class='chip' data-isonim-element-id='action'></button>"),
      story("Alternate", style(alternate), "<button id='alternate' class='chip' data-isonim-element-id='alternate'></button>")]}
    let offer = @[ReofferedDeclaration(file: "s.nim", constName: "cardStyles", selector: ".chip", property: "opacity")]
    check rows(compiledStyleBindings(catalog, manifest, proc(file: string): string = reset, offer)) == @[
      "Card / Ready action #action width=120px shared 1",
      "Alternate / Ready alternate #alternate width=180px shared 1",
      "Card / Ready action .chip opacity= shared 1"]

  test "a re-offer is not withheld by a stylesheet the page does not load":
    # Review N2: rivalStyles also sets .chip opacity but no page here loads
    # it, so the Reset .chip opacity is still offered on the Card page.
    let reset = source.replace(".chip { opacity:0.5; }", ".chip { }") &
      "const rivalStyles* = \"\"\"\n.chip { opacity:0.2; }\n\"\"\"\n"
    let opted = %*{"editableStyleSources":[
      {"file":"s.nim","const":"cardStyles","properties":["opacity","width"]},
      {"file":"s.nim","const":"rivalStyles","properties":["opacity"]}]}
    let catalog = %*{"stories":[story("Card", style(nimConstBody(reset, "cardStyles")),
      "<button id='action' class='chip' data-isonim-element-id='action'></button>")]}
    let offer = @[ReofferedDeclaration(file: "s.nim", constName: "cardStyles", selector: ".chip", property: "opacity")]
    check rows(compiledStyleBindings(catalog, opted, proc(file: string): string = reset, offer)) == @[
      "Card / Ready action #action width=120px shared 1",
      "Card / Ready action .chip opacity= shared 1"]

suite "A re-offered shorthand presents its sides":
  # isonim-pm issue 2026-10-17-re-offered-shorthand-after-reset-has-no-per-
  # side-rows; editor spec "Universal Patterns": a re-settable shorthand
  # presents the same rows as an authored one, so each side can be set again.
  let manifest = %*{"editableStyleSources":[{"file":"s.nim","const":"styles","properties":["width","padding","border-radius"]}]}
  let offers = @[ReofferedDeclaration(file: "s.nim", constName: "styles", selector: ".panel", property: "padding"),
    ReofferedDeclaration(file: "s.nim", constName: "styles", selector: ".panel", property: "border-radius")]
  proc bound(text: string; body = "<div class='panel'></div>"; reoffer = offers): JsonNode =
    compiledStyleBindings(pageCatalog(body, text), manifest, proc(file: string): string = text, reoffer)
  proc keys(binding: JsonNode): seq[string] =
    for property, _ in binding["values"]: result.add property

  test "the same rows as the authored shorthand, each with no value":
    let authored = bound("const styles* = \"\"\".panel { width:10px; padding:4px; border-radius:2px; }\"\"\"", reoffer = @[])
    let reset = bound("const styles* = \"\"\".panel { width:10px; }\"\"\"")
    check authored.len == 1 and reset.len == 1
    check reset[0]["values"] == %*{"width":"10px","padding":"","padding-top":"","padding-right":"",
      "padding-bottom":"","padding-left":"","border-radius":"","border-top-left-radius":"",
      "border-top-right-radius":"","border-bottom-right-radius":"","border-bottom-left-radius":""}
    var authoredKeys = authored[0].keys()
    var resetKeys = reset[0].keys()
    check authoredKeys.len == 11
    for key in authoredKeys: check key in resetKeys
    for key in resetKeys: check key in authoredKeys
    for property, _ in reset[0]["values"]: check reset[0]["properties"].contains(%property)
    check reset[0]["key"] == authored[0]["key"]

  test "a side the rule declares again shows its value; the others stay offered":
    let reset = bound("const styles* = \"\"\".panel { width:10px; padding-top:5px; }\"\"\"")
    check reset.len == 1
    check reset[0]["values"]["padding-top"].getStr() == "5px"
    check reset[0]["sourceDeclarations"]["padding-top"]["property"].getStr() == "padding-top"
    for side in ["padding", "padding-right", "padding-bottom", "padding-left"]:
      check reset[0]["values"][side].getStr() == ""

  test "a side another rule or the inline style sets for the element is not offered":
    let reset = bound("const styles* = \"\"\".panel { width:10px; }\n#action { padding-left:2px; }\"\"\"",
      "<div id='action' class='panel' style='border-top-left-radius:1px'></div>")
    var panel: seq[JsonNode]
    for binding in reset:
      if binding["selector"].getStr() == ".panel": panel.add binding
    check panel.len == 1
    check panel[0]["values"]{"padding-left"} == nil
    check panel[0]["values"]{"border-top-left-radius"} == nil
    for side in ["padding", "padding-top", "padding-right", "padding-bottom", "border-radius", "border-top-right-radius"]:
      check panel[0]["values"][side].getStr() == ""

  test "a side opted in through its shorthand is re-offered after its own Reset":
    let only = @[ReofferedDeclaration(file: "s.nim", constName: "styles", selector: ".panel", property: "padding-top")]
    let reset = bound("const styles* = \"\"\".panel { width:10px; }\"\"\"", reoffer = only)
    check reset.len == 1
    check reset[0]["values"] == %*{"width":"10px","padding-top":""}
    let unlisted = %*{"editableStyleSources":[{"file":"s.nim","const":"styles","properties":["width"]}]}
    let text = "const styles* = \"\"\".panel { width:10px; }\"\"\""
    check compiledStyleBindings(pageCatalog("<div class='panel'></div>", text), unlisted,
      proc(file: string): string = text, only)[0]["values"] == %*{"width":"10px"}

  test "no side is offered where the rule is not the one place a value would go":
    # Two unconditional .panel rules (a value would have no single home) or a
    # selector list (it would style the list's other selectors): nothing is
    # re-offered, neither the shorthand nor a side.
    check bound("const styles* = \"\"\".panel { width:10px; }\n.panel { color:red; }\"\"\"").len == 0
    let listed = bound("const styles* = \"\"\".panel, .other { width:10px; }\"\"\"")
    check listed.len == 1
    check listed[0]["values"] == %*{"width":"10px"}
