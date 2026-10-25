## isonim/static: the script policy, the SEO head and the CSP it carries.
## Dual-target: `nim c -r` and `nim js -r` must both pass.
##
## The page under test has the scripts a documentation site declares: a
## theme bootstrap early in `<head>`, a deferred app bundle at the end of
## `<head>`, a behaviour script at the end of `<body>`, and a JSON-LD head.
## Under `spNone` it must carry no executable script while the JSON-LD
## data block stays. The negative control is the declared policy (what
## isonim-docs uses by default): the theme bootstrap, and the other two,
## must still be emitted -- which also shows the checker can see a script
## when there is one. isonim-docs' own pages are checked the same way, end
## to end, by its `tests/docs/test_script_policy.nim`.
##
## No test doubles: the head is rendered by the real renderer and the HTML
## is scanned as built.

import std/[unittest, strutils]
import isonim/static/[head, scripts, csp]

const
  bootstrapBody = "(function(){try{document.documentElement.setAttribute('data-theme'," &
                  "localStorage.getItem('theme')||'light');}catch(e){}})();"
  viewerBody = "document.addEventListener('click',function(){});"
  analyticsBody = "(function(){navigator.sendBeacon('/a');})();"

proc declaredScripts(withAnalytics = false): seq[PageScript] =
  result = @[inlineScript(bootstrapBody, id = "theme-bootstrap", slot = ssHeadTop)]
  if withAnalytics:
    result.add inlineScript(analyticsBody, id = "analytics", slot = ssHeadTop,
                            role = srAnalytics)
  result.add externalScript("/assets/app.js", slot = ssHeadEnd)
  result.add inlineScript(viewerBody, id = "viewer", slot = ssBodyEnd)

proc pageHead(): DocumentHead =
  result = DocumentHead(title: "Hello </script> — Example", description: "A post",
    stylesheetHref: "/assets/style.css", siteName: "Example",
    canonicalUrl: "https://example.org/posts/hello", ogType: "article")
  result.jsonLd = articleJsonLd(result, "BlogPosting")

proc renderPage(policy: ScriptPolicy; scripts: seq[PageScript];
                cspCfg = defaultCspConfig()): string =
  "<!doctype html><html>" & renderPageHeadHtml(pageHead(), scripts, policy, cspCfg) &
    "<body><main><p>Hello.</p></main>" & renderBodyEndScriptsHtml(scripts, policy) &
    "</body></html>"

suite "isonim/static/scripts -- spNone emits no executable script":
  test "under spNone a page with an ld+json head carries no executable script":
    let html = renderPage(spNone, declaredScripts())
    check executableScripts(html).len == 0
    check eventHandlerAttributes(html).len == 0
    check html.contains("<script type=\"application/ld+json\">{\"@context\":\"https://schema.org\"," &
                        "\"@type\":\"BlogPosting\",\"headline\":\"Hello \\u003c/script> — Example\"")
    check html.count("<script") == 1

  test "negative control: the declared policy still emits the theme bootstrap (and the rest)":
    let html = renderPage(spDeclared, declaredScripts())
    let found = executableScripts(html)
    check found == @["<script id=\"theme-bootstrap\">", "<script src=\"/assets/app.js\" defer>",
                     "<script id=\"viewer\">"]
    # the bootstrap is right after <meta charset>, the bundle before </head>
    check html.contains("<head><meta charset=\"utf-8\" /><script id=\"theme-bootstrap\">" &
                        bootstrapBody & "</script><title>")
    check html.contains("</script><script src=\"/assets/app.js\" defer></script></head>")
    check html.contains("<script id=\"viewer\">" & viewerBody & "</script></body>")

  test "static export defaults to spNone":
    check renderPageHeadHtml(pageHead(), declaredScripts()) ==
      renderPageHeadHtml(pageHead(), declaredScripts(), spNone)
    check renderBodyEndScriptsHtml(declaredScripts()) == ""

  test "a configured analytics snippet survives spNone; the CSP allows exactly the scripts kept":
    let strict = strictCspConfig()
    let none = renderPage(spNone, declaredScripts(withAnalytics = true), strict)
    check executableScripts(none) == @["<script id=\"analytics\">"]
    check none.contains(cspHashSource(analyticsBody))
    check not none.contains(cspHashSource(bootstrapBody))
    check not none.contains(cspHashSource(viewerBody))
    let declared = renderPage(spDeclared, declaredScripts(withAnalytics = true), strict)
    for body in [bootstrapBody, analyticsBody, viewerBody]:
      check declared.contains(cspHashSource(body))
    # the CSP meta precedes every script it governs
    check declared.find("Content-Security-Policy") < declared.find("<script id=\"theme-bootstrap\">")

suite "isonim/static/scripts -- the executable-script checker":
  test "script types are classified as the HTML standard does":
    check executableScripts("<script>x()</script>").len == 1
    check executableScripts("<SCRIPT type=\"text/javascript\">x()</SCRIPT>").len == 1
    check executableScripts("<script type='module' src='/m.js'></script>").len == 1
    # The HTML algorithm's essence match does not parse MIME parameters.
    check executableScripts("<script type=\"text/javascript; charset=utf-8\"></script>").len == 0
    check executableScripts("<script type=\"\">x()</script>").len == 1
    check executableScripts("<script type=\"importmap\">{}</script>").len == 1
    check executableScripts("<script type=\"application/ld+json\">{}</script>").len == 0
    check executableScripts("<script type=application/json>{}</script>").len == 0
    check executableScripts("<script data-type=\"application/json\">x()</script>").len == 1
    check executableScripts("<scripts></scripts><p>no script here</p>").len == 0

  test "inline event handlers and javascript: URLs are found; prose mentioning them is not":
    check eventHandlerAttributes("<button onclick=\"x()\">b</button>") == @["onclick"]
    check eventHandlerAttributes("<body onload = \"x()\">") == @["onload"]
    check eventHandlerAttributes("<a href=\"javascript:x()\">a</a>") == @["javascript:"]
    check eventHandlerAttributes("<p>set onclick=handler in prose</p>").len == 0
    check eventHandlerAttributes("<a class=\"one\" href=\"/on\">a</a>").len == 0

suite "isonim/static/head -- the SEO head":
  test "without the new optional fields the head is exactly isonim-docs' layout":
    var h = pageHead()
    h.jsonLd = "{}"
    check renderDocumentHeadHtml(h) ==
      "<head><meta charset=\"utf-8\" /><title>Hello &lt;/script&gt; — Example</title>" &
      "<meta name=\"description\" content=\"A post\" />" &
      "<link rel=\"stylesheet\" href=\"/assets/style.css\" />" &
      "<link rel=\"canonical\" href=\"https://example.org/posts/hello\" />" &
      "<meta property=\"og:title\" content=\"Hello </script> — Example\" />" &
      "<meta property=\"og:description\" content=\"A post\" />" &
      "<meta property=\"og:type\" content=\"article\" />" &
      "<meta property=\"og:url\" content=\"https://example.org/posts/hello\" />" &
      "<meta property=\"og:site_name\" content=\"Example\" />" &
      "<meta name=\"twitter:card\" content=\"summary\" />" &
      "<meta name=\"twitter:title\" content=\"Hello </script> — Example\" />" &
      "<meta name=\"twitter:description\" content=\"A post\" />" &
      "<script type=\"application/ld+json\">{}</script></head>"

  test "a page without a stylesheet gets no stylesheet link":
    var h = pageHead()
    h.stylesheetHref = ""
    let html = renderDocumentHeadHtml(h)
    check not html.contains("rel=\"stylesheet\"")
    check html.contains("<meta name=\"description\" content=\"A post\" />" &
      "<link rel=\"canonical\" href=\"https://example.org/posts/hello\" />")

  test "theme-color for both schemes, og:image and the card type":
    var h = pageHead()
    h.themeColors = @[ThemeColor(color: "#ffffff", media: "(prefers-color-scheme: light)"),
                      ThemeColor(color: "#0b0d12", media: "(prefers-color-scheme: dark)")]
    h.ogImage = "https://example.org/og/hello.png"
    h.twitterCard = "summary_large_image"
    let html = renderDocumentHeadHtml(h)
    check html.contains("<meta name=\"description\" content=\"A post\" />" &
      "<meta name=\"theme-color\" content=\"#ffffff\" media=\"(prefers-color-scheme: light)\" />" &
      "<meta name=\"theme-color\" content=\"#0b0d12\" media=\"(prefers-color-scheme: dark)\" />")
    check html.contains("<meta property=\"og:image\" content=\"https://example.org/og/hello.png\" />")
    check html.contains("<meta name=\"twitter:card\" content=\"summary_large_image\" />")
    check html.contains("<meta name=\"twitter:image\" content=\"https://example.org/og/hello.png\" />")

  test "JSON-LD strings cannot close the script element":
    check jsonLdString("a</script>\"\\\n") == "\"a\\u003c/script>\\\"\\\\\\n\""
    check not pageHead().jsonLd.contains("</script")

suite "HTML token boundaries":
  test "unquoted JavaScript MIME type is detected":
    check executableScripts("<script type=text/javascript>alert(1)</script>").len == 1
  test "attribute-looking text in another value cannot hide script":
    check executableScripts("<script data-note=\" type='application/json'\">alert(1)</script>").len == 1
  test "quoted greater-than does not truncate tag":
    check executableScripts("<script data-note='>' type='application/json'>{}</script>").len == 0
  test "comments and raw-text elements do not execute script":
    check executableScripts("<!-- <script>alert(1)</script> -->").len == 0
    check executableScripts("<textarea><script>alert(1)</script></textarea>").len == 0
  test "all HTML attribute whitespace is recognized":
    check eventHandlerAttributes("<button\nonclick='alert(1)'>x</button>") == @["onclick"]
    check eventHandlerAttributes("<button\tonclick='alert(1)'>x</button>") == @["onclick"]
  test "quoted text is not a handler attribute":
    check eventHandlerAttributes("<p title=\" onclick='example'\">x</p>").len == 0

  test "encoded values and duplicate attributes follow HTML semantics":
    for markup in ["<script type=text&#47;javascript>x()</script>",
                   "<script type='text&sol;javascript'>x()</script>",
                   "<script type=text/javascript data-x='>'>x()</script>"]:
      check executableScripts(markup).len == 1
    for markup in ["<a href='java&#x73;cript&colon;x()'>x</a>",
                   "<a href=' java&#9;script:x()'>x</a>",
                   "<a href='java&Tab;script:x()'>x</a>"]:
      check eventHandlerAttributes(markup) == @["javascript:"]
    check eventHandlerAttributes("<p title='javascript:example'>text</p>").len == 0
    check eventHandlerAttributes("<!-- <b onclick=x()> --><textarea><b onload=x()></textarea>").len == 0
    check executableScripts("<p title='<script>'>text</p><style>x{content:'<script>'}</style>").len == 0
    check executableScripts("<script>const s='<script>';</script>").len == 1
    check executableScripts("<script type=application/json type=text/javascript>{}</script>").len == 0
    check executableScripts("<script type=text/javascript type=application/json>x()</script>").len == 1

  test "script preparation uses exact special types and MIME essence matches":
    for value in ["module;foo", " module ", " ", "text/javascript; charset=utf-8"]:
      check executableScripts("<script type='" & value & "'>x()</script>").len == 0
    for value in ["MoDuLe", " text/javascript ", "IMPORTMAP", "speculationrules"]:
      check executableScripts("<script type='" & value & "'>x()</script>").len == 1
    check executableScripts("<script language=javascript>x()</script>").len == 1
    check executableScripts("<script language=json>{}</script>").len == 0
    check executableScripts("<script type='' language=json>x()</script>").len == 1

suite "HTML comments and foreign-content contexts":
  # Expectations independently observed in Chromium, and grounded in the
  # HTML tokenizer/comment and foreign-content tree-construction rules.
  test "abrupt and bang comment endings resume markup tokenization":
    for comment in ["<!-->", "<!--->", "<!-- comment --!>", "<!---->"]:
      check executableScripts(comment & "<script>x()</script>").len == 1
      check eventHandlerAttributes(comment & "<img onerror=x()>") == @["onerror"]
    for comment in ["<!-- <script>x()</script> -->", "<!--!><script>x()</script>",
                    "<!-- comment --!-><script>x()</script>"]:
      check executableScripts(comment).len == 0

  test "SVG style is foreign data and SVG integration points dispatch HTML":
    for container in ["style", "title", "desc", "foreignObject"]:
      let html = "<svg><" & container & "><script>x()</script></" & container & "></svg>"
      check executableScripts(html).len == 1
    for integration in ["title", "desc", "foreignObject"]:
      for raw in ["title", "textarea", "style"]:
        let html = "<svg><" & integration & "><" & raw & "><script>x()</script>" &
          "<img onerror=x()></" & raw & "></" & integration & "></svg>"
        check executableScripts(html).len == 0
        check eventHandlerAttributes(html).len == 0

  test "MathML scripts are inert except at HTML integration points":
    check executableScripts("<math><style><script>x()</script></style></math>").len == 0
    for container in ["mi", "mo", "mn", "ms", "mtext", "annotation-xml encoding='text/html'",
                      "annotation-xml encoding='application/xhtml+xml'"]:
      check executableScripts("<math><" & container & "><script>x()</script>").len == 1
      for raw in ["title", "textarea", "style"]:
        let html = "<math><" & container & "><" & raw & "><script>x()</script>" &
          "<img onerror=x()></" & raw & ">"
        check executableScripts(html).len == 0
        check eventHandlerAttributes(html).len == 0
    for exception in ["mglyph", "malignmark"]:
      check executableScripts("<math><mtext><" & exception & "><script>x()</script>").len == 0
    check executableScripts("<math><annotation-xml encoding='other'><script>x()</script>").len == 0
    check executableScripts("<math><annotation-xml><svg><script>x()</script>").len == 1

  test "CDATA in foreign content and HTML raw text stay inert":
    for namespace in ["svg", "math"]:
      let html = "<" & namespace & "><![CDATA[x> <script>x()</script><img onerror=x()>]]>" &
        "</" & namespace & ">"
      check executableScripts(html).len == 0
      check eventHandlerAttributes(html).len == 0
    for raw in ["title", "textarea", "style"]:
      check executableScripts("<" & raw & "><script>x()</script></" & raw & ">").len == 0
    check executableScripts("<select><textarea><script>x()</script></select>").len == 0

  test "HTML breakout elements leave SVG and MathML before handling attributes":
    for namespace in ["svg", "math"]:
      let html = "<" & namespace & "><style><img src='data:,broken' onerror=x()>" &
        "</style></" & namespace & ">"
      check eventHandlerAttributes(html) == @["onerror"]
      # After the img breakout, the next style is HTML raw text.
      check executableScripts("<" & namespace & "><style><img><style><script>x()</script>").len == 0

  test "self-closing foreign roots and ordinary end tags restore HTML context":
    for foreign in ["<svg/>", "<svg></svg>", "<math/>", "<math></math>"]:
      check executableScripts(foreign & "<style><script>x()</script></style>").len == 0
      check executableScripts(foreign & "<script>x()</script>").len == 1
