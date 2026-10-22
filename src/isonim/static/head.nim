## isonim/static/head -- the SEO `<head>` of a static page: title,
## description, stylesheet, canonical link, `hreflang` alternates,
## `theme-color`, OpenGraph (https://ogp.me/), Twitter card
## (https://developer.x.com/en/docs/x-for-websites/cards/overview/markup)
## and a JSON-LD (https://json-ld.org/, https://schema.org/) block.
##
## Two renderings of one `DocumentHead`, kept in the same order: the SSR
## string (`renderDocumentHeadHtml`) and a tree built through any
## renderer backend (`renderDocumentHead[R, E]`, e.g. `MockRenderer` in
## tests). Moved from isonim-docs (`src/core/shell_vm.nim`'s
## `DocumentHead` and JSON-LD builder, `src/components/shell.nim`'s head
## renderers), which now re-export them. The fields added here
## (`themeColors`, `ogImage`, `twitterCard`) are empty by default and then
## emit nothing, so a head without them is byte-for-byte what isonim-docs
## always wrote.
##
## Scripts are not part of `DocumentHead`. `renderPageHeadHtml` places a
## page's declared scripts around the head under a `ScriptPolicy`
## (`isonim/static/scripts`) and hashes the inline ones into the CSP
## (`isonim/static/csp`). The JSON-LD block is a data block, not an
## executable script, so it is emitted under every policy.
##
## Pure string work, identical on `nim c` and `nim js`.

import std/strutils
import ../ssr/escape
import ./scripts
import ./csp

type
  ThemeColor* = object
    ## One `<meta name="theme-color">`: the browser UI colour, optionally
    ## for one colour scheme (`media = "(prefers-color-scheme: dark)"`).
    color*: string
    media*: string

  DocumentHead* = object
    ## Everything a static page's `<head>` says about the page.
    title*: string          ## The full `<title>` (see `formatPageTitle`).
    description*: string    ## `<meta name="description">`, `og:` and `twitter:`.
    stylesheetHref*: string ## The page's stylesheet `<link>`.
    siteName*: string       ## `og:site_name`; the JSON-LD publisher.
    canonicalUrl*: string   ## `<link rel="canonical">` and `og:url`; absolute
                            ## when the site has a base URL, else root-relative.
    ogType*: string         ## `og:type` ("article", "website", ...).
    jsonLd*: string         ## The serialized JSON-LD document (see
                            ## `articleJsonLd`), emitted verbatim inside
                            ## `<script type="application/ld+json">`.
    alternates*: seq[tuple[hreflang, href: string]]
                            ## `hreflang` alternate links, one per locale
                            ## plus `x-default`; empty for a single-language
                            ## page.
    themeColors*: seq[ThemeColor]
                            ## `theme-color` metas, typically one per colour
                            ## scheme. Empty emits none.
    ogImage*: string        ## `og:image` and `twitter:image` (absolute URL).
                            ## Empty emits neither.
    twitterCard*: string    ## `twitter:card`; empty means "summary".

proc formatPageTitle*(pageTitle, siteTitle: string): string =
  ## "Page Title — Site Title", or just the site title when the page has
  ## no title of its own (an index page, for example).
  if pageTitle.len == 0: siteTitle
  else: pageTitle & " — " & siteTitle

proc jsonLdString*(s: string): string =
  ## A JSON string literal for the JSON-LD builder
  ## (https://www.rfc-editor.org/rfc/rfc8259#section-7). Pure per-char work
  ## (no `std/json`), so it is identical on the C and JS targets. `<` is
  ## written as `\u003c`, so a value containing `</script>` cannot break out
  ## of the `<script type="application/ld+json">` block it is embedded in.
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '<': result.add "\\u003c"
    else:
      if ord(c) < 32:
        const hex = "0123456789abcdef"
        result.add "\\u00" & hex[ord(c) shr 4] & hex[ord(c) and 15]
      else: result.add c
  result.add "\""

proc articleJsonLd*(head: DocumentHead; schemaType: string): string =
  ## The schema.org JSON-LD document for an article-like page of type
  ## `schemaType` (`TechArticle`, `BlogPosting`, `Article`, ...): its
  ## headline and description, its URL when the head has one, and the site
  ## as an `Organization` publisher when it has a name. Keys are in a fixed
  ## order, so equal heads give equal bytes.
  var parts = @[
    "\"@context\":" & jsonLdString("https://schema.org"),
    "\"@type\":" & jsonLdString(schemaType),
    "\"headline\":" & jsonLdString(head.title),
    "\"description\":" & jsonLdString(head.description),
  ]
  if head.canonicalUrl.len > 0:
    parts.add "\"url\":" & jsonLdString(head.canonicalUrl)
  if head.siteName.len > 0:
    parts.add "\"publisher\":{\"@type\":\"Organization\",\"name\":" &
      jsonLdString(head.siteName) & "}"
  "{" & parts.join(",") & "}"

proc twitterCardOf(head: DocumentHead): string =
  if head.twitterCard.len > 0: head.twitterCard else: "summary"

proc renderDocumentHeadHtml*(head: DocumentHead; headTop = ""): string =
  ## The `<head>` element as an HTML string.
  ##
  ## `<meta charset="utf-8">` is always its first child: the HTML standard
  ## requires the encoding declaration within the first 1024 bytes
  ## (https://html.spec.whatwg.org/multipage/semantics.html#charset), and
  ## without it a server that sends no charset makes the browser mis-decode
  ## every non-ASCII byte. `headTop` (a CSP meta, blocking bootstrap
  ## scripts) follows it, before `<title>`. The JSON-LD payload is emitted
  ## verbatim: `jsonLdString` already encodes `<`, so it cannot close the
  ## `<script>` element.
  var alternatesHtml = ""
  for alt in head.alternates:
    alternatesHtml.add "<link rel=\"alternate\" hreflang=\"" &
      escapeAttr(alt.hreflang) & "\" href=\"" & escapeAttr(alt.href) & "\" />"
  var themeColorHtml = ""
  for tc in head.themeColors:
    themeColorHtml.add "<meta name=\"theme-color\" content=\"" & escapeAttr(tc.color) & "\""
    if tc.media.len > 0:
      themeColorHtml.add " media=\"" & escapeAttr(tc.media) & "\""
    themeColorHtml.add " />"
  let ogImageHtml =
    if head.ogImage.len == 0: ""
    else: "<meta property=\"og:image\" content=\"" & escapeAttr(head.ogImage) & "\" />"
  let twitterImageHtml =
    if head.ogImage.len == 0: ""
    else: "<meta name=\"twitter:image\" content=\"" & escapeAttr(head.ogImage) & "\" />"
  "<head>" &
    "<meta charset=\"utf-8\" />" & headTop &
    "<title>" & escapeHtml(head.title) & "</title>" &
    "<meta name=\"description\" content=\"" & escapeAttr(head.description) & "\" />" &
    themeColorHtml &
    "<link rel=\"stylesheet\" href=\"" & escapeAttr(head.stylesheetHref) & "\" />" &
    "<link rel=\"canonical\" href=\"" & escapeAttr(head.canonicalUrl) & "\" />" &
    alternatesHtml &
    "<meta property=\"og:title\" content=\"" & escapeAttr(head.title) & "\" />" &
    "<meta property=\"og:description\" content=\"" & escapeAttr(head.description) & "\" />" &
    "<meta property=\"og:type\" content=\"" & escapeAttr(head.ogType) & "\" />" &
    "<meta property=\"og:url\" content=\"" & escapeAttr(head.canonicalUrl) & "\" />" &
    "<meta property=\"og:site_name\" content=\"" & escapeAttr(head.siteName) & "\" />" &
    ogImageHtml &
    "<meta name=\"twitter:card\" content=\"" & escapeAttr(twitterCardOf(head)) & "\" />" &
    "<meta name=\"twitter:title\" content=\"" & escapeAttr(head.title) & "\" />" &
    "<meta name=\"twitter:description\" content=\"" & escapeAttr(head.description) & "\" />" &
    twitterImageHtml &
    "<script type=\"application/ld+json\">" & head.jsonLd & "</script>" &
  "</head>"

proc renderPageHeadHtml*(head: DocumentHead; scripts: openArray[PageScript];
                         policy = spNone; csp = defaultCspConfig()): string =
  ## The `<head>` with the page's scripts placed under `policy`: the CSP
  ## meta (when `csp` is enabled) right after `<meta charset>`, then the
  ## kept `ssHeadTop` scripts, and the kept `ssHeadEnd` scripts just before
  ## `</head>`. The CSP's `script-src` allows the kept inline scripts of
  ## every slot by hash, so a page that also emits its `ssBodyEnd` scripts
  ## (`renderBodyEndScriptsHtml`) stays within its own policy. Under
  ## `spNone` with no analytics declared, the head carries no executable
  ## script, only the JSON-LD data block.
  let kept = applyScriptPolicy(policy, scripts)
  let headTop = renderCspMetaHtml(csp, inlineScriptBodies(kept)) &
    renderScriptsHtml(kept, ssHeadTop)
  result = renderDocumentHeadHtml(head, headTop)
  let headEnd = renderScriptsHtml(kept, ssHeadEnd)
  if headEnd.len > 0:
    result = result[0 ..< result.len - "</head>".len] & headEnd & "</head>"

proc renderBodyEndScriptsHtml*(scripts: openArray[PageScript];
                               policy = spNone): string =
  ## The kept `ssBodyEnd` scripts, to emit just before `</body>`.
  renderScriptsHtml(applyScriptPolicy(policy, scripts), ssBodyEnd)

# --- the same head as a renderer-backend tree ------------------------------

proc addMetaName[R, E](r: R; parent: E; name, content: string) =
  let m = r.createElement("meta")
  r.setAttribute(m, "name", name)
  r.setAttribute(m, "content", content)
  r.appendChild(parent, m)

proc addMetaProperty[R, E](r: R; parent: E; property, content: string) =
  let m = r.createElement("meta")
  r.setAttribute(m, "property", property)
  r.setAttribute(m, "content", content)
  r.appendChild(parent, m)

proc renderDocumentHead*[R, E](r: R; head: DocumentHead): E =
  ## The `<head>` element built through renderer backend `r`, in the same
  ## order as `renderDocumentHeadHtml` (without `headTop`, which is SSR
  ## string content). Built against the generic backend API rather than
  ## the `ui` DSL, because the DSL's fixed attribute vocabulary has no
  ## `property=` for OpenGraph metas.
  let headEl = r.createElement("head")

  let charsetMeta = r.createElement("meta")
  r.setAttribute(charsetMeta, "charset", "utf-8")
  r.appendChild(headEl, charsetMeta)

  let titleEl = r.createElement("title")
  r.appendChild(titleEl, r.createTextNode(head.title))
  r.appendChild(headEl, titleEl)

  addMetaName[R, E](r, headEl, "description", head.description)

  for tc in head.themeColors:
    let m = r.createElement("meta")
    r.setAttribute(m, "name", "theme-color")
    r.setAttribute(m, "content", tc.color)
    if tc.media.len > 0:
      r.setAttribute(m, "media", tc.media)
    r.appendChild(headEl, m)

  let styleLink = r.createElement("link")
  r.setAttribute(styleLink, "rel", "stylesheet")
  r.setAttribute(styleLink, "href", head.stylesheetHref)
  r.appendChild(headEl, styleLink)

  let canonicalLink = r.createElement("link")
  r.setAttribute(canonicalLink, "rel", "canonical")
  r.setAttribute(canonicalLink, "href", head.canonicalUrl)
  r.appendChild(headEl, canonicalLink)

  for alt in head.alternates:
    let altLink = r.createElement("link")
    r.setAttribute(altLink, "rel", "alternate")
    r.setAttribute(altLink, "hreflang", alt.hreflang)
    r.setAttribute(altLink, "href", alt.href)
    r.appendChild(headEl, altLink)

  addMetaProperty[R, E](r, headEl, "og:title", head.title)
  addMetaProperty[R, E](r, headEl, "og:description", head.description)
  addMetaProperty[R, E](r, headEl, "og:type", head.ogType)
  addMetaProperty[R, E](r, headEl, "og:url", head.canonicalUrl)
  addMetaProperty[R, E](r, headEl, "og:site_name", head.siteName)
  if head.ogImage.len > 0:
    addMetaProperty[R, E](r, headEl, "og:image", head.ogImage)

  addMetaName[R, E](r, headEl, "twitter:card", twitterCardOf(head))
  addMetaName[R, E](r, headEl, "twitter:title", head.title)
  addMetaName[R, E](r, headEl, "twitter:description", head.description)
  if head.ogImage.len > 0:
    addMetaName[R, E](r, headEl, "twitter:image", head.ogImage)

  let ldScript = r.createElement("script")
  r.setAttribute(ldScript, "type", "application/ld+json")
  r.appendChild(ldScript, r.createTextNode(head.jsonLd))
  r.appendChild(headEl, ldScript)

  headEl
