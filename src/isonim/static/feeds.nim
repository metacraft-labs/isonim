## isonim/static/feeds -- syndication feeds: RSS 2.0
## (https://www.rssboard.org/rss-specification) and Atom 1.0
## (RFC 4287, https://www.rfc-editor.org/rfc/rfc4287).
##
## Pure string work, identical on `nim c` and `nim js`. One `Feed` value
## renders as either format, so a generator builds its entry list once.
## The writers emit entries in the order they are given: the caller owns
## the order (a blog passes its posts newest first), as with the sitemap.
##
## - **Absolute URLs.** Feed readers resolve nothing against the site, so
##   every URL a feed carries must be absolute. The feed's own URL, its
##   site URL and every entry URL are checked (`FeedError` otherwise), and
##   `absoluteHtmlUrls` rewrites the relative references (`href`, `src`,
##   `poster`, `srcset`) inside an entry's HTML against the entry URL,
##   following RFC 3986 §5.2 (https://www.rfc-editor.org/rfc/rfc3986#section-5.2).
## - **Full content.** An entry's HTML is carried escaped as text
##   (`<content type="html">` in Atom, `<description>` and
##   `<content:encoded>` in RSS: https://web.resource.org/rss/1.0/modules/content/).
##   Escaping rather than CDATA keeps a `]]>` in the HTML harmless.
## - **Dates.** Entries carry W3C Datetimes (`YYYY-MM-DD` or a date with a
##   time and zone designator, `isonim/static/sitemap.isW3cDatetime`). A
##   bare date means midnight UTC. Atom gets RFC 3339 (`rfc3339Date`), RSS
##   gets RFC 822 with a four-digit year (`rfc822Date`, as RSS 2.0 allows).
## - **Validity is checked, not hoped for.** A missing required element
##   (a title, a date, an Atom author), a relative URL, a malformed date or
##   a control character XML 1.0 cannot carry
##   (https://www.w3.org/TR/xml/#charsets) raises `FeedError` rather than
##   writing a feed readers would reject.

import std/strutils
import ./urls
import ./sitemap

type
  FeedPerson* = object
    ## An author: Atom `<author>` (RFC 4287 §3.2).
    name*: string   ## Required for every person written.
    uri*: string    ## Optional; absolute when given.
    email*: string  ## Optional.

  FeedEntry* = object
    ## One post.
    title*: string          ## Required.
    url*: string            ## The post's absolute URL (`<link>`).
    id*: string             ## A permanent identifier; empty uses `url`.
    published*: string      ## W3C Datetime; required.
    updated*: string        ## W3C Datetime; empty uses `published`.
    summary*: string        ## Optional HTML summary (an excerpt).
    contentHtml*: string    ## The full HTML body; empty omits content.
    categories*: seq[string] ## Tags and categories, in the order given.
    authors*: seq[FeedPerson] ## Empty falls back to the feed's authors.

  Feed* = object
    ## A feed document and its entries.
    title*: string          ## Required.
    subtitle*: string       ## Atom `<subtitle>`, RSS `<description>`
                            ## (RSS requires one; empty repeats the title).
    siteUrl*: string        ## The absolute URL of the site's page that the
                            ## feed syndicates (`rel="alternate"`).
    feedUrl*: string        ## The absolute URL of this document (`rel="self"`).
    id*: string             ## Atom `<id>`; empty uses `feedUrl`.
    language*: string       ## `xml:lang` / RSS `<language>`; empty omits it.
    updated*: string        ## W3C Datetime; empty uses the newest entry
                            ## `updated`, which must then exist.
    authors*: seq[FeedPerson] ## Feed-level authors (Atom requires them
                              ## unless every entry names its own).
    generator*: string      ## `<generator>`; empty omits it.
    entries*: seq[FeedEntry]

  FeedError* = object of ValueError
    ## A feed that would be invalid. Raised instead of written.

const
  atomNamespace* = "http://www.w3.org/2005/Atom"
  rssContentNamespace* = "http://purl.org/rss/1.0/modules/content/"
  atomMediaType* = "application/atom+xml"
  rssMediaType* = "application/rss+xml"

proc fail(msg: string) {.noreturn.} =
  raise newException(FeedError, "feed: " & msg)

# --- URLs -------------------------------------------------------------------

proc schemeEnd(url: string): int =
  ## The index of the `:` ending a URI scheme (RFC 3986 §3.1), or -1.
  if url.len == 0 or url[0] notin {'a'..'z', 'A'..'Z'}: return -1
  for i in 1 ..< url.len:
    case url[i]
    of 'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.': discard
    of ':': return i
    else: return -1
  -1

proc isAbsoluteHttpUrl*(url: string): bool =
  ## True for an `http:` or `https:` URL with a host: the only form a feed
  ## may cite. Whitespace and control characters are refused.
  for c in url:
    if c <= ' ': return false
  let colon = schemeEnd(url)
  if colon < 0: return false
  let scheme = url[0 ..< colon].toLowerAscii
  if scheme notin ["http", "https"]: return false
  if not url.continuesWith("//", colon + 1): return false
  let hostStart = colon + 3
  hostStart < url.len and url[hostStart] notin {'/', '?', '#'}

proc requireAbsolute(what, url: string) =
  if not isAbsoluteHttpUrl(url):
    fail(what & " must be an absolute http(s) URL: '" & url & "'")

proc removeDotSegments(path: string): string =
  ## RFC 3986 §5.2.4.
  var input = path
  var output = ""
  while input.len > 0:
    if input.startsWith("../"): input = input[3 .. ^1]
    elif input.startsWith("./"): input = input[2 .. ^1]
    elif input.startsWith("/./"): input = input[2 .. ^1]
    elif input == "/.": input = "/"
    elif input.startsWith("/../") or input == "/..":
      input = if input == "/..": "/" else: input[3 .. ^1]
      let cut = output.rfind('/')
      output = if cut < 0: "" else: output[0 ..< cut]
    elif input in [".", ".."]: input = ""
    else:
      var stop = input.find('/', 1)
      if input[0] != '/': stop = input.find('/')
      if stop < 0: stop = input.len
      output.add input[0 ..< stop]
      input = input[stop .. ^1]
  output

proc splitReference(url: string): tuple[beforeQuery, query, fragment: string] =
  var rest = url
  let hash = rest.find('#')
  if hash >= 0:
    result.fragment = rest[hash .. ^1]
    rest = rest[0 ..< hash]
  let question = rest.find('?')
  if question >= 0:
    result.query = rest[question .. ^1]
    rest = rest[0 ..< question]
  result.beforeQuery = rest

proc resolveUrl*(base, reference: string): string =
  ## Resolves `reference` against the absolute `base` (RFC 3986 §5.2.2):
  ## an absolute reference is returned unchanged, `//host/...` takes the
  ## base's scheme, `/path` its origin, `#frag` and `?query` its path, and a
  ## relative path merges with the base's directory, with `.` and `..`
  ## segments removed. An empty reference is returned unchanged (it names
  ## the document itself, which a feed reader handles).
  requireAbsolute("base", base)
  if reference.len == 0 or schemeEnd(reference) >= 0: return reference
  let colon = schemeEnd(base)
  let scheme = base[0 .. colon]           # "https:"
  if reference.startsWith("//"): return scheme & reference
  let parts = splitReference(base)
  let authorityStart = colon + 3
  var pathStart = parts.beforeQuery.find('/', authorityStart)
  if pathStart < 0: pathStart = parts.beforeQuery.len
  let origin = parts.beforeQuery[0 ..< pathStart]
  let basePath = parts.beforeQuery[pathStart .. ^1]
  if reference[0] == '#': return parts.beforeQuery & parts.query & reference
  if reference[0] == '?': return parts.beforeQuery & reference
  let refParts = splitReference(reference)
  var path: string
  if refParts.beforeQuery.startsWith("/"):
    path = removeDotSegments(refParts.beforeQuery)
  else:
    let directory =
      if basePath.len == 0: "/"
      else: basePath[0 .. basePath.rfind('/')]
    path = removeDotSegments(directory & refParts.beforeQuery)
  origin & path & refParts.query & refParts.fragment

proc absoluteSrcset(base, value: string): string =
  ## `srcset` is a comma-separated list of `URL [descriptor]` candidates
  ## (https://html.spec.whatwg.org/multipage/images.html#srcset-attributes).
  var candidates: seq[string]
  for candidate in value.split(','):
    let item = candidate.strip()
    if item.len == 0: continue
    let space = item.find({' ', '\t', '\n'})
    if space < 0: candidates.add resolveUrl(base, item)
    else: candidates.add resolveUrl(base, item[0 ..< space]) & item[space .. ^1]
  candidates.join(", ")

proc absoluteHtmlUrls*(html, base: string): string =
  ## `html` with every relative `href`, `src`, `poster` and `srcset` value
  ## in its tags resolved against the absolute `base` (`resolveUrl`). Text,
  ## comments and other attributes are copied byte for byte. Attribute
  ## values are matched quoted (`"` or `'`) or unquoted, as HTML allows; an
  ## entity in a value (`&amp;`) is kept, since it is still the same
  ## character once the reader decodes the attribute.
  requireAbsolute("base", base)
  var i = 0
  while i < html.len:
    if html.continuesWith("<!--", i):
      let stop = html.find("-->", i + 4)
      let last = if stop < 0: html.len else: stop + 3
      result.add html[i ..< last]
      i = last
      continue
    if html[i] != '<' or i + 1 >= html.len or html[i + 1] notin {'a'..'z', 'A'..'Z'}:
      result.add html[i]
      inc i
      continue
    # A start tag: copy its name, then walk its attributes.
    var j = i + 1
    while j < html.len and html[j] notin {' ', '\t', '\n', '\r', '\f', '/', '>'}: inc j
    result.add html[i ..< j]
    while j < html.len and html[j] != '>':
      if html[j] in {' ', '\t', '\n', '\r', '\f', '/'}:
        result.add html[j]
        inc j
        continue
      let nameStart = j
      while j < html.len and html[j] notin {' ', '\t', '\n', '\r', '\f', '/', '>', '='}: inc j
      let name = html[nameStart ..< j].toLowerAscii
      result.add html[nameStart ..< j]
      var k = j
      while k < html.len and html[k] in {' ', '\t', '\n', '\r', '\f'}: inc k
      if k >= html.len or html[k] != '=':
        continue
      inc k
      while k < html.len and html[k] in {' ', '\t', '\n', '\r', '\f'}: inc k
      result.add html[j ..< k]
      var quote = '\0'
      if k < html.len and html[k] in {'"', '\''}:
        quote = html[k]
        result.add quote
        inc k
      let valueStart = k
      if quote != '\0':
        while k < html.len and html[k] != quote: inc k
      else:
        while k < html.len and html[k] notin {' ', '\t', '\n', '\r', '\f', '>'}: inc k
      let value = html[valueStart ..< k]
      case name
      of "href", "src", "poster": result.add resolveUrl(base, value.strip())
      of "srcset": result.add absoluteSrcset(base, value)
      else: result.add value
      if quote != '\0' and k < html.len:
        result.add quote
        inc k
      j = k
    if j < html.len:
      result.add '>'
      inc j
    i = j

# --- dates ------------------------------------------------------------------

const
  monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep",
                "Oct", "Nov", "Dec"]
  dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

proc requireDate(what, value: string) =
  if not isW3cDatetime(value):
    fail(what & " is not a W3C Datetime (YYYY-MM-DD or YYYY-MM-DDThh:mm[:ss]Z): '" & value & "'")

proc dayOfWeek(year, month, day: int): int =
  ## 0 = Sunday. Sakamoto's method for the proleptic Gregorian calendar.
  const offsets = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  var y = year
  if month < 3: dec y
  (y + y div 4 - y div 100 + y div 400 + offsets[month - 1] + day) mod 7

proc splitDatetime(value: string): tuple[date, time, zone: string] =
  ## Parts of a valid W3C Datetime: the date, `hh:mm:ss` (seconds added
  ## when absent, fraction dropped) and the zone as `Z` or `+hh:mm`.
  result.date = value[0 ..< 10]
  if value.len == 10:
    return (result.date, "00:00:00", "Z")
  var rest = value[11 .. ^1]
  if rest.endsWith("Z"):
    result.zone = "Z"
    rest = rest[0 ..< rest.len - 1]
  else:
    result.zone = rest[^6 .. ^1]
    rest = rest[0 ..< rest.len - 6]
  result.time = if rest.len == 5: rest & ":00" else: rest[0 ..< 8]

proc rfc3339Date*(value: string): string =
  ## A W3C Datetime as the RFC 3339 `date-time` Atom requires
  ## (https://www.rfc-editor.org/rfc/rfc3339#section-5.6): a bare date is
  ## midnight UTC; a fraction of a second is kept.
  requireDate("date", value)
  if value.len == 10: return value & "T00:00:00Z"
  let parts = splitDatetime(value)
  var rest = value[11 .. ^1]
  rest = rest[0 ..< rest.len - parts.zone.len]
  let time = if rest.len == 5: rest & ":00" else: rest
  parts.date & "T" & time & parts.zone

proc rfc822Date*(value: string): string =
  ## A W3C Datetime as the RFC 822 date RSS 2.0 uses, with a four-digit
  ## year (RFC 1123 §5.2.14): `Thu, 02 Jan 2020 03:04:05 +0200`. A bare
  ## date is midnight UTC; a fraction of a second is dropped.
  requireDate("date", value)
  let parts = splitDatetime(value)
  let year = parseInt(parts.date[0 .. 3])
  let month = parseInt(parts.date[5 .. 6])
  let day = parseInt(parts.date[8 .. 9])
  let zone = if parts.zone == "Z": "+0000" else: parts.zone[0 .. 2] & parts.zone[4 .. 5]
  dayNames[dayOfWeek(year, month, day)] & ", " & parts.date[8 .. 9] & " " &
    monthNames[month - 1] & " " & parts.date[0 .. 3] & " " & parts.time & " " & zone

# --- shared validation ------------------------------------------------------

proc text(what, value: string): string =
  ## XML text: the five specials escaped, characters XML 1.0 cannot carry
  ## refused (C0 controls other than tab, line feed and carriage return).
  for c in value:
    if c < ' ' and c notin {'\t', '\n', '\r'}:
      fail(what & " contains control character " & $ord(c) & ", which XML cannot carry")
  xmlEscape(value)

proc entryUpdated(entry: FeedEntry): string =
  if entry.updated.len > 0: entry.updated else: entry.published

proc checkEntry(entry: FeedEntry) =
  let what = "entry '" & entry.title & "'"
  if entry.title.len == 0: fail("an entry has no title (" & entry.url & ")")
  requireAbsolute(what & " url", entry.url)
  requireDate(what & " published", entry.published)
  if entry.updated.len > 0: requireDate(what & " updated", entry.updated)
  for person in entry.authors:
    if person.name.len == 0: fail(what & " has an author without a name")
    if person.uri.len > 0: requireAbsolute(what & " author uri", person.uri)

proc checkFeed(feed: Feed) =
  if feed.title.len == 0: fail("the feed has no title")
  requireAbsolute("siteUrl", feed.siteUrl)
  requireAbsolute("feedUrl", feed.feedUrl)
  if feed.updated.len > 0: requireDate("feed updated", feed.updated)
  for person in feed.authors:
    if person.name.len == 0: fail("a feed author has no name")
    if person.uri.len > 0: requireAbsolute("feed author uri", person.uri)
  for entry in feed.entries: checkEntry(entry)

proc feedUpdated*(feed: Feed): string =
  ## The feed's `updated`: its own, else the newest entry `updated`
  ## (compared as RFC 3339 text, exact for one zone; a feed mixing zones
  ## should set `updated` itself). Raises `FeedError` when there is none.
  if feed.updated.len > 0: return feed.updated
  var newest = ""
  for entry in feed.entries:
    let value = entryUpdated(entry)
    if newest.len == 0 or rfc3339Date(value) > rfc3339Date(newest): newest = value
  if newest.len == 0: fail("an empty feed needs an explicit updated date")
  newest

# --- Atom -------------------------------------------------------------------

proc atomPerson(person: FeedPerson): string =
  result = "<author><name>" & text("author name", person.name) & "</name>"
  if person.uri.len > 0: result.add "<uri>" & text("author uri", person.uri) & "</uri>"
  if person.email.len > 0: result.add "<email>" & text("author email", person.email) & "</email>"
  result.add "</author>"

proc renderAtom*(feed: Feed): string =
  ## The Atom 1.0 document (RFC 4287). Raises `FeedError` for an invalid
  ## feed, including one with no feed author where an entry has none
  ## either (RFC 4287 §4.1.1).
  checkFeed(feed)
  if feed.authors.len == 0:
    for entry in feed.entries:
      if entry.authors.len == 0:
        fail("Atom needs an author: entry '" & entry.title & "' has none and the feed has none")
  result = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<feed xmlns=\"" & atomNamespace & "\""
  if feed.language.len > 0: result.add " xml:lang=\"" & text("language", feed.language) & "\""
  result.add ">\n"
  result.add "  <title>" & text("title", feed.title) & "</title>\n"
  if feed.subtitle.len > 0: result.add "  <subtitle>" & text("subtitle", feed.subtitle) & "</subtitle>\n"
  result.add "  <link rel=\"alternate\" type=\"text/html\" href=\"" & text("siteUrl", feed.siteUrl) & "\"/>\n"
  result.add "  <link rel=\"self\" type=\"" & atomMediaType & "\" href=\"" & text("feedUrl", feed.feedUrl) & "\"/>\n"
  result.add "  <id>" & text("id", if feed.id.len > 0: feed.id else: feed.feedUrl) & "</id>\n"
  result.add "  <updated>" & rfc3339Date(feedUpdated(feed)) & "</updated>\n"
  for person in feed.authors: result.add "  " & atomPerson(person) & "\n"
  if feed.generator.len > 0: result.add "  <generator>" & text("generator", feed.generator) & "</generator>\n"
  for entry in feed.entries:
    let what = "entry '" & entry.title & "'"
    result.add "  <entry>\n"
    result.add "    <title>" & text(what & " title", entry.title) & "</title>\n"
    result.add "    <link rel=\"alternate\" type=\"text/html\" href=\"" & text(what & " url", entry.url) & "\"/>\n"
    result.add "    <id>" & text(what & " id", if entry.id.len > 0: entry.id else: entry.url) & "</id>\n"
    result.add "    <published>" & rfc3339Date(entry.published) & "</published>\n"
    result.add "    <updated>" & rfc3339Date(entryUpdated(entry)) & "</updated>\n"
    for person in entry.authors: result.add "    " & atomPerson(person) & "\n"
    for category in entry.categories:
      result.add "    <category term=\"" & text(what & " category", category) & "\"/>\n"
    if entry.summary.len > 0:
      result.add "    <summary type=\"html\">" & text(what & " summary", entry.summary) & "</summary>\n"
    if entry.contentHtml.len > 0:
      result.add "    <content type=\"html\">" & text(what & " content", entry.contentHtml) & "</content>\n"
    result.add "  </entry>\n"
  result.add "</feed>\n"

# --- RSS 2.0 ----------------------------------------------------------------

proc renderRss*(feed: Feed): string =
  ## The RSS 2.0 document. `<description>` carries the summary when there
  ## is one and the content otherwise; `<content:encoded>` carries the full
  ## content. The `atom:link rel="self"` element is the RSS Advisory
  ## Board's recommendation (https://www.rssboard.org/rss-profile#namespace-elements-atom-link).
  ## Authors are not written: RSS's `<author>` must be an e-mail address.
  checkFeed(feed)
  result = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" &
    "<rss version=\"2.0\" xmlns:atom=\"" & atomNamespace & "\" xmlns:content=\"" &
    rssContentNamespace & "\">\n<channel>\n"
  result.add "  <title>" & text("title", feed.title) & "</title>\n"
  result.add "  <link>" & text("siteUrl", feed.siteUrl) & "</link>\n"
  result.add "  <description>" & text("subtitle",
    if feed.subtitle.len > 0: feed.subtitle else: feed.title) & "</description>\n"
  result.add "  <atom:link rel=\"self\" type=\"" & rssMediaType & "\" href=\"" & text("feedUrl", feed.feedUrl) & "\"/>\n"
  if feed.language.len > 0: result.add "  <language>" & text("language", feed.language) & "</language>\n"
  if feed.entries.len > 0 or feed.updated.len > 0:
    result.add "  <lastBuildDate>" & rfc822Date(feedUpdated(feed)) & "</lastBuildDate>\n"
  if feed.generator.len > 0: result.add "  <generator>" & text("generator", feed.generator) & "</generator>\n"
  for entry in feed.entries:
    let what = "entry '" & entry.title & "'"
    let id = if entry.id.len > 0: entry.id else: entry.url
    result.add "  <item>\n"
    result.add "    <title>" & text(what & " title", entry.title) & "</title>\n"
    result.add "    <link>" & text(what & " url", entry.url) & "</link>\n"
    result.add "    <guid isPermaLink=\"" & (if id == entry.url: "true" else: "false") & "\">" &
      text(what & " id", id) & "</guid>\n"
    result.add "    <pubDate>" & rfc822Date(entry.published) & "</pubDate>\n"
    for category in entry.categories:
      result.add "    <category>" & text(what & " category", category) & "</category>\n"
    let description = if entry.summary.len > 0: entry.summary else: entry.contentHtml
    if description.len > 0:
      result.add "    <description>" & text(what & " description", description) & "</description>\n"
    if entry.contentHtml.len > 0:
      result.add "    <content:encoded>" & text(what & " content", entry.contentHtml) & "</content:encoded>\n"
    result.add "  </item>\n"
  result.add "</channel>\n</rss>\n"

# --- discovery --------------------------------------------------------------

proc feedLinkHtml*(href, mediaType, title: string): string =
  ## The `<link rel="alternate">` that lets browsers and readers discover a
  ## feed from a page (https://www.rssboard.org/rss-autodiscovery). Pass
  ## `atomMediaType` or `rssMediaType`.
  for c in href & title:
    if c < ' ': fail("feed link contains a control character")
  "<link rel=\"alternate\" type=\"" & xmlEscape(mediaType) & "\" title=\"" &
    xmlEscape(title) & "\" href=\"" & xmlEscape(href) & "\" />"
