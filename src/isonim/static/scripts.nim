## isonim/static/scripts -- the script policy of a statically exported
## page: which `<script>` elements a page carries, and a checker that
## finds every executable script in built HTML.
##
## A static page needs no JavaScript to be read. A site declares the
## scripts its pages could carry as `PageScript`s (a theme bootstrap, a
## behaviour script, a deferred bundle, an analytics snippet), and the
## `ScriptPolicy` decides which of them are emitted:
##
## - `spNone` omits every bootstrap, behaviour script and bundle, so a page
##   carries no executable script. Data blocks such as
##   `<script type="application/ld+json">` are not executable and stay
##   (`isonim/static/head` emits the JSON-LD block outside this policy).
##   An analytics snippet the site configured (`srAnalytics`) also stays:
##   configuring one is an explicit decision to run it.
## - `spDeclared` emits every declared script, in declaration order. This
##   is what a site that ships progressive enhancement uses (isonim-docs'
##   default: its theme bootstrap, image viewer and app bundle).
##
## Static export defaults to `spNone` wherever this library takes a
## policy parameter. `spDeclared` is the enum's first value only so that a
## zero-initialised site configuration keeps the scripts it already
## declares; nothing here relies on the zero value.
##
## Pure string work, identical on `nim c` and `nim js`.

import std/[strutils, htmlparser, sets]
import ../ssr/escape

type
  ScriptPolicy* = enum
    spDeclared = "declared" ## Emit every declared script.
    spNone = "none"         ## Emit no executable script except configured analytics.

  ScriptRole* = enum
    srEnhancement ## A bootstrap, behaviour script or bundle: dropped by `spNone`.
    srAnalytics   ## A site-configured analytics snippet: kept by `spNone`.

  ScriptSlot* = enum
    ## Where in the document a script goes.
    ssHeadTop ## Early in `<head>`, right after `<meta charset>` (blocking
              ## bootstraps that must run before first paint).
    ssHeadEnd ## Just before `</head>` (deferred external bundles).
    ssBodyEnd ## Just before `</body>` (scripts that need the parsed page).

  PageScript* = object
    ## One script a page may carry. Exactly one of `body` (an inline
    ## script) and `src` (an external one) is set.
    id*: string        ## Optional `id` attribute.
    role*: ScriptRole
    slot*: ScriptSlot
    body*: string      ## Inline script text, emitted verbatim between the tags.
    src*: string       ## External script URL.
    deferLoad*: bool   ## Adds `defer` (meaningful for an external script).

proc inlineScript*(body: string; id = ""; slot = ssHeadTop;
                   role = srEnhancement): PageScript =
  ## An inline script with `body` as its exact text.
  PageScript(id: id, role: role, slot: slot, body: body)

proc externalScript*(src: string; id = ""; slot = ssHeadEnd; deferLoad = true;
                     role = srEnhancement): PageScript =
  ## An external script loaded from `src`, deferred by default.
  PageScript(id: id, role: role, slot: slot, src: src, deferLoad: deferLoad)

proc keptBy*(policy: ScriptPolicy; script: PageScript): bool =
  ## Whether `policy` emits `script`.
  case policy
  of spDeclared: true
  of spNone: script.role == srAnalytics

proc applyScriptPolicy*(policy: ScriptPolicy;
                        scripts: openArray[PageScript]): seq[PageScript] =
  ## The scripts `policy` emits, in declaration order. A script with
  ## neither a body nor a `src` is dropped (it would be an empty element).
  for s in scripts:
    if (s.body.len > 0 or s.src.len > 0) and policy.keptBy(s):
      result.add s

proc renderScriptHtml*(script: PageScript): string =
  ## The `<script>` element for `script`: `<script id="i">body</script>` for
  ## an inline script, `<script src="u" defer></script>` for an external
  ## one. The body is emitted verbatim (a consumer that interpolates data
  ## into it escapes `</script>` itself); attribute values are escaped.
  result = "<script"
  if script.id.len > 0:
    result.add " id=\"" & escapeAttr(script.id) & "\""
  if script.src.len > 0:
    result.add " src=\"" & escapeAttr(script.src) & "\""
    if script.deferLoad: result.add " defer"
    result.add "></script>"
  else:
    result.add ">" & script.body & "</script>"

proc renderScriptsHtml*(scripts: openArray[PageScript]; slot: ScriptSlot): string =
  ## Every script in `scripts` that belongs in `slot`, in order. Pass the
  ## result of `applyScriptPolicy`, not the declared list.
  for s in scripts:
    if s.slot == slot: result.add renderScriptHtml(s)

proc inlineScriptBodies*(scripts: openArray[PageScript]): seq[string] =
  ## The bodies of the inline scripts, in order: what a CSP's `script-src`
  ## must allow by hash (`isonim/static/csp`). Pass the result of
  ## `applyScriptPolicy`, so a policy that drops a script also drops its
  ## hash.
  for s in scripts:
    if s.src.len == 0 and s.body.len > 0: result.add s.body

# --- checking built HTML -----------------------------------------------------

const htmlSpace = {' ', '\t', '\n', '\r', '\f'}

type
  HtmlNamespace = enum
    hnHtml, hnSvg, hnMath
  HtmlTag = object
    name, source: string
    attrs: seq[tuple[name, value: string]]
    namespace: HtmlNamespace
  HtmlContext = object
    name: string
    namespace: HtmlNamespace
    htmlIntegration, mathTextIntegration: bool

proc contextFor(tag: HtmlTag): HtmlContext =
  result = HtmlContext(name: tag.name, namespace: tag.namespace)
  case tag.namespace
  of hnHtml: discard
  of hnSvg:
    result.htmlIntegration = tag.name in ["foreignobject", "desc", "title"]
  of hnMath:
    result.mathTextIntegration = tag.name in ["mi", "mo", "mn", "ms", "mtext"]
    if tag.name == "annotation-xml":
      for attr in tag.attrs:
        if attr.name == "encoding":
          result.htmlIntegration = attr.value.toLowerAscii in
            ["text/html", "application/xhtml+xml"]

proc usesHtmlRules(parent: HtmlContext; name: string): bool =
  parent.namespace == hnHtml or parent.htmlIntegration or
    (parent.mathTextIntegration and name notin ["mglyph", "malignmark"]) or
    (parent.namespace == hnMath and parent.name == "annotation-xml" and name == "svg")

proc breaksOutOfForeign(tag: HtmlTag): bool =
  ## HTML's foreign-content breakout list (not a list of all HTML tags).
  ## https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inforeign
  if tag.name in ["b", "big", "blockquote", "body", "br", "center", "code", "dd",
      "div", "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6",
      "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol",
      "p", "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup",
      "table", "tt", "u", "ul", "var"]: return true
  if tag.name == "font":
    for attr in tag.attrs:
      if attr.name in ["color", "face", "size"]: return true

proc afterComment(html: string; start: int): int =
  ## The comment start/start-dash states can close immediately; the body
  ## ends with --> or --!>. Other '>' bytes and nested '<!--' do not end
  ## or nest the comment. Return EOF for an unterminated comment.
  ## https://html.spec.whatwg.org/multipage/parsing.html#comment-start-state
  if start < html.len and html[start] == '>': return start + 1
  if html.continuesWith("->", start): return start + 2
  var i = start
  while i < html.len:
    if html.continuesWith("-->", i): return i + 3
    if html.continuesWith("--!>", i): return i + 4
    inc i
  html.len

proc decodeAttribute(value: string): string =
  ## Character references are resolved before the browser interprets an
  ## attribute. Numeric references may omit their semicolon in HTML.
  var i = 0
  while i < value.len:
    if value[i] == '&':
      var e = i + 1
      if e < value.len and value[e] == '#':
        inc e
        let hexadecimal = e < value.len and value[e] in {'x', 'X'}
        if hexadecimal: inc e
        while e < value.len and (value[e] in {'0'..'9'} or
            (hexadecimal and value[e] in {'a'..'f', 'A'..'F'})): inc e
      else:
        while e < value.len and value[e].isAlphaNumeric: inc e
      let terminated = e < value.len and value[e] == ';'
      let numeric = i + 1 < value.len and value[i + 1] == '#'
      if e > i + 1 and (terminated or numeric):
        let decoded = entityToUtf8(value[i + 1 ..< e])
        if decoded.len > 0:
          result.add decoded
          i = e + (if terminated: 1 else: 0)
          continue
    result.add value[i]
    inc i

iterator htmlStartTags(html: string): HtmlTag =
  ## Static-markup scanner, not a DOM constructor or sanitizer. Keep the
  ## tokenizer contexts that govern script recognition: quotes, comments,
  ## HTML raw/RCDATA text, foreign CDATA, namespaces and integration points.
  ## Foreign style/title are not HTML raw text. Duplicate attributes use
  ## their first value. This does not emulate script-driven DOM changes.
  ## https://html.spec.whatwg.org/multipage/parsing.html#tree-construction
  let lower = html.toLowerAscii
  var i = 0
  var raw = ""
  var stack: seq[HtmlContext]
  while i < html.len:
    if raw.len > 0:
      let needle = "</" & raw
      var close = lower.find(needle, i)
      while close >= 0:
        let after = close + needle.len
        if after == html.len or html[after] in htmlSpace + {'/', '>'}: break
        close = lower.find(needle, after)
      if close < 0: break
      i = close
      raw = ""
    let start = html.find('<', i)
    if start < 0: break
    i = start + 1
    if lower.continuesWith("!--", i):
      i = afterComment(html, i + 3)
      continue
    if i >= html.len: break
    if html.continuesWith("![CDATA[", i) and stack.len > 0 and
        stack[^1].namespace != hnHtml:
      let close = html.find("]]>", i + 8)
      if close < 0: break
      i = close + 3
      continue
    if html[i] in {'!', '?'}:
      let close = html.find('>', i)
      if close < 0: break
      i = close + 1
      continue
    let closing = html[i] == '/'
    if closing: inc i
    if i >= html.len or html[i] notin {'a'..'z', 'A'..'Z'}: continue
    let nameStart = i
    while i < html.len and html[i] notin htmlSpace + {'/', '>'}: inc i
    var tag = HtmlTag(name: lower[nameStart ..< i])
    var names = initHashSet[string]()
    var complete = false
    var selfClosing = false
    while i < html.len:
      while i < html.len and html[i] in htmlSpace: inc i
      if i < html.len and html[i] == '/':
        inc i
        if i < html.len and html[i] == '>': selfClosing = true
        continue
      if i >= html.len: break
      if html[i] == '>':
        inc i
        complete = true
        break
      let attrStart = i
      while i < html.len and html[i] notin htmlSpace + {'=', '/', '>'}: inc i
      if i == attrStart: # stray '=' is a parse error, but still consumes input
        inc i
        continue
      let name = lower[attrStart ..< i]
      while i < html.len and html[i] in htmlSpace: inc i
      var value = ""
      if i < html.len and html[i] == '=':
        inc i
        while i < html.len and html[i] in htmlSpace: inc i
        if i < html.len and html[i] in {'\"', '\''}:
          let quote = html[i]
          inc i
          let valueStart = i
          while i < html.len and html[i] != quote: inc i
          value = html[valueStart ..< i]
          if i < html.len: inc i
        else:
          let valueStart = i
          while i < html.len and html[i] notin htmlSpace + {'>'}: inc i
          value = html[valueStart ..< i]
      if name notin names:
        names.incl name
        tag.attrs.add (name, decodeAttribute(value))
    if not complete: break
    tag.source = html[start ..< i]
    if closing:
      # Foreign </br> and </p> also leave foreign content before HTML
      # handling. Other end tags unwind the matching open context.
      if tag.name in ["br", "p"]:
        while stack.len > 0 and stack[^1].namespace != hnHtml and
            not stack[^1].htmlIntegration and not stack[^1].mathTextIntegration:
          stack.setLen(stack.len - 1)
      for n in countdown(stack.len - 1, 0):
        if stack[n].name == tag.name:
          stack.setLen(n)
          break
      continue
    var parent = if stack.len > 0: stack[^1] else: HtmlContext()
    if not usesHtmlRules(parent, tag.name) and breaksOutOfForeign(tag):
      while stack.len > 0 and stack[^1].namespace != hnHtml and
          not stack[^1].htmlIntegration and not stack[^1].mathTextIntegration:
        stack.setLen(stack.len - 1)
      parent = if stack.len > 0: stack[^1] else: HtmlContext()
    if usesHtmlRules(parent, tag.name):
      tag.namespace = case tag.name
        of "svg": hnSvg
        of "math": hnMath
        else: hnHtml
    else:
      tag.namespace = parent.namespace
    yield tag
    if tag.namespace == hnHtml:
      # HTML ignores the self-closing slash on non-void elements. Foreign
      # elements acknowledge it, so <svg/> cannot affect the next tag.
      if tag.name in ["area", "base", "br", "col", "embed", "hr", "img", "input",
                      "link", "meta", "param", "source", "track", "wbr"]: continue
      if tag.name == "plaintext": break
      if tag.name in ["script", "style", "textarea", "title", "xmp", "iframe",
                      "noembed", "noframes", "noscript"]:
        raw = tag.name
    elif selfClosing:
      continue
    stack.add contextFor(tag)

const javaScriptMimeTypes = [
  # https://html.spec.whatwg.org/multipage/scripting.html#javascript-mime-type
  "application/ecmascript", "application/javascript", "application/x-ecmascript",
  "application/x-javascript", "text/ecmascript", "text/javascript",
  "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
  "text/javascript1.3", "text/javascript1.4", "text/javascript1.5",
  "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript"]

proc isExecutableScriptType*(typeAttr: string; present: bool): bool =
  ## Whether a `<script>` with this `type` attribute is run by a browser,
  ## following the HTML standard's "prepare the script element" steps
  ## (https://html.spec.whatwg.org/multipage/scripting.html#prepare-the-script-element):
  ## no `type`, an empty one, a JavaScript MIME type and `module` are
  ## scripts; `importmap` and `speculationrules` are processed by the
  ## browser too, so they count. Anything else (`application/ld+json`,
  ## `application/json`, ...) is a data block.
  if not present or typeAttr.len == 0: return true
  # "JavaScript MIME type essence match" compares against the essence;
  # it does not parse MIME parameters. Only the classic MIME branch trims
  # ASCII whitespace; the special keywords compare the original value.
  typeAttr.strip(chars = htmlSpace).toLowerAscii in javaScriptMimeTypes or
    typeAttr.toLowerAscii in ["module", "importmap", "speculationrules"]

proc executableScripts*(html: string): seq[string] =
  ## Opening tags of executable script elements, in document order.
  ## Data blocks including application/ld+json remain exempt.
  for tag in htmlStartTags(html):
    if tag.name == "script" and tag.namespace != hnMath:
      var present = false
      var value = ""
      for attr in tag.attrs:
        if attr.name == "type":
          present = true
          value = attr.value
      if not present and tag.namespace == hnHtml:
        for attr in tag.attrs:
          if attr.name == "language" and attr.value.len > 0:
            value = "text/" & attr.value
            present = true
      if isExecutableScriptType(value, present): result.add tag.source

proc eventHandlerAttributes*(html: string): seq[string] =
  ## Inline handler names and javascript: URL attributes. Text in an
  ## unrelated attribute is not executable. URL processing removes ASCII
  ## tab/newline/CR and leading C0 controls before testing the scheme.
  for tag in htmlStartTags(html):
    for attr in tag.attrs:
      if attr.name.startsWith("on") and attr.name.len > 2:
        result.add attr.name
      if attr.name in ["href", "src", "action", "formaction", "xlink:href"]:
        var url = ""
        for c in attr.value:
          if c notin {'\t', '\n', '\r'}: url.add c
        url = url.strip(chars = {'\0'..' '}).toLowerAscii
        if url.startsWith("javascript:"): result.add "javascript:"
