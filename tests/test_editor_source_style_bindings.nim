## No mocks: production CSS/markup/catalog binding logic reads real temporary
## source files. Static catalog rows are ordinary input fixtures for precise
## ambiguity/conditional/token contracts; real SSR/compiler/native/browser paths
## are separately exercised by test_editor_source_style_provider.py and GUI.
import std/[unittest, json, os, tempfiles, strutils]
import isonim/editor/[source_style_bindings, source_catalog, css_patch, source_style_values, viewmodels, types]

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
    let catalog = %* {"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel'></div><div class='panel'></div><div class='panel other'></div><div class='panel-long'></div>"}]}
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["border-radius","height","color"]}]}
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
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel'></div>"}]}
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["padding","border-radius"]}]}
    for (css,expectedOwner) in [("padding-left:2px; padding:4px; border-top-left-radius:2px; border-radius:4px;", "derived"),
        ("padding:4px; padding-left:2px; border-radius:4px; border-top-left-radius:2px;", "explicit")]:
      writeFile(source,"const styles* = \"\"\".panel { " & css & " }\"\"\"")
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
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel'></div><div class='panel'></div>"}]}
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
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel'></div>"}]}
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["padding","border-radius"]}]}
    for tail in ["padding:4px; padding:8px; border-radius:4px; border-radius:8px;",
        "padding:8px !important; border-radius:8px !IMPORTANT;",
        "padding:4px; border-radius:4px; } @media (max-width:800px) { .panel { padding:8px; border-radius:8px;"]:
      writeFile(source,"const styles* = \"\"\".panel { padding-left:2px; border-top-left-radius:2px; " & tail & " }\"\"\"")
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
      let catalog = %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='host'><div class='panel'></div></div>"}]}
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = readFile(directory / file)).len == 0
    writeFile(source,"const styles* = \"\"\".panel { background:var(--panel); }\"\"\"\nconst tokens* = \"\"\":root { --panel:#ffffff; }\"\"\"")
    let inlineCatalog = %*{"stories":[{"group":"Card","name":"Ready","kind":"component","documentHtml":"<div class='panel' style='--panel : #000000'></div>"}]}
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
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<div class='panel'></div>"}]}
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background","background-color"]}]}
    for pair in [("background-color:#112233; background:#445566;", "background", "#445566"),
        ("background:#445566; background-color:#112233;", "background-color", "#112233"),
        ("background:linear-gradient(red,blue); background-color:#112233;", "background-color", "#112233"),
        ("background:#445566;", "background", "#445566")]:
      let source = "const styles* = \"\"\".panel { " & pair[0] & " }\"\"\""
      let bindings = compiledStyleBindings(catalog,manifest,proc(file:string):string = source)
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
        let bindings = compiledStyleBindings(catalog,limited,proc(file:string):string = source)
        for binding in bindings:
          check binding["values"]{"background-color"} == nil
    let shorthandOnly = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background"]}]}
    let shadowed = "const styles* = \"\"\".panel { background:#445566; background-color:#112233; }\"\"\""
    check compiledStyleBindings(catalog,shorthandOnly,proc(file:string):string = shadowed).len == 0
    let supportedAlias = "const styles* = \"\"\".panel { background-color:#112233; background:#445566; }\"\"\""
    let alias = compiledStyleBindings(catalog,shorthandOnly,proc(file:string):string = supportedAlias)
    check alias.len == 1
    check alias[0]["values"]["background-color"].getStr() == "#445566"
    check alias[0]["sourceDeclarations"]["background-color"]["property"].getStr() == "background"
    let restricted = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["background-color"]}]}
    let winning = "const styles* = \"\"\".panel { background:linear-gradient(red,blue); background-color:#112233; }\"\"\""
    check compiledStyleBindings(catalog,restricted,proc(file:string):string = winning)[0]["values"]["background-color"].getStr() == "#112233"

  test "provider current origin cannot impersonate inline conditional or unknown selector owner":
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["width"]}]}
    for pair in [(".panel { width:10px; }", "<div id='action' class='panel' style='width:20px'></div>"),
        (".panel { width:10px; } @media(min-width:100px) { #action { width:20px; } }", "<div id='action' class='panel'></div>"),
        (".panel { width:10px; } div.panel:hover { width:20px; }", "<div id='action' class='panel'></div>")]:
      let catalog = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":pair[1]}]}
      let source = "const styles* = \"\"\"" & pair[0] & "\"\"\""
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<div class='panel'></div>"}]}
    for unrelated in [".other:hover { width:20px; }", ".other[data-kind=\"panel\"] { width:20px; }", ".panel[data-kind=\"other\"] .other:hover { width:20px; }", ".panel .other:hover { width:20px; }",
        ".other > button:hover { width:20px; }", "@media(min-width:100px) { .host .other { width:20px; } }"]:
      let source = "const styles* = \"\"\".panel { width:10px; } " & unrelated & "\"\"\""
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 1
    for ambiguous in [".other .panel:hover { width:20px; }", ".panel[data-kind=\"other\"] { width:20px; }", ".host > .panel { width:20px; }",
        "[data-kind='other'] { width:20px; }", ".other\\:escaped { width:20px; }",
        "@media(min-width:100px) { .host .panel { width:20px; } }"]:
      let source = "const styles* = \"\"\".panel { width:10px; } " & ambiguous & "\"\"\""
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0

  test "all reset refuses ordinary current origins but preserves CSS exceptions":
    let manifest = %*{"editableStyleSources":[{"file":"styles.nim","const":"styles","properties":["width","background-color","direction","unicode-bidi","--panel"]}]}
    let catalog = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<div id='action' class='panel'></div>"}]}
    for tail in ["all:initial;", "all:unset !important;", "} @media(min-width:100px) { #action { all:initial;",
        "} .panel[data-kind=active] { all:initial;", "} .panel:hover { all:initial;", "} .host .panel { all:initial;"]:
      let source = "const styles* = \"\"\".panel { width:40px; background-color:#112233; " & tail & " }\"\"\""
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = source).len == 0
    let source = "const styles* = \"\"\".panel { width:40px; background-color:#112233; }\"\"\""
    let inline = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<div class='panel' style='all:initial'></div>"}]}
    check compiledStyleBindings(inline,manifest,proc(file:string):string = source).len == 0
    for unrelated in [".panel .other:hover { all:initial; }", ".other[data-kind=active] { all:initial; }",
        "@media(min-width:100px) { .host .other { all:initial; } }"]:
      let text = "const styles* = \"\"\".panel { width:40px; background-color:#112233; } " & unrelated & "\"\"\""
      check compiledStyleBindings(catalog,manifest,proc(file:string):string = text).len == 1
    let exceptions = "const styles* = \"\"\".panel { direction:rtl; unicode-bidi:isolate; all:initial; } :root { --panel:#112233; all:initial; }\"\"\""
    let result = compiledStyleBindings(catalog,manifest,proc(file:string):string = exceptions)
    check result.len == 1
    check result[0]["values"] == %*{"direction":"rtl","unicode-bidi":"isolate"}
    let token = "const styles* = \"\"\".panel { background-color:var(--panel); } :root { --panel:#112233; all:initial; }\"\"\""
    let tokens = compiledStyleBindings(catalog,manifest,proc(file:string):string = token)
    check tokens.len == 1
    check tokens[0]["values"]["background-color"].getStr() == "#112233"
    check tokens[0]["tokenName"].getStr() == "--panel"
    let htmlRoot = %*{"stories":[{"group":"Card","name":"Ready","documentHtml":"<html class='panel'><body></body></html>"}]}
    let rootReset = "const styles* = \"\"\".panel { width:40px; background-color:#112233; } :root { all:initial; }\"\"\""
    check compiledStyleBindings(htmlRoot,manifest,proc(file:string):string = rootReset).len == 0
