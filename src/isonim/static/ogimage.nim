## isonim/static/ogimage -- OpenGraph images (https://ogp.me/#structured):
## an SVG template, written by a theme as ordinary markup, rendered to a
## 1200x630 PNG with resvg (https://github.com/linebender/resvg).
##
## The render is hermetic and byte-reproducible:
##
## - **The tool is injected.** `OgImageConfig.resvgPath` is an absolute path
##   (Nix supplies it); nothing is looked up on `PATH`, and resvg runs with
##   a fixed minimal environment in a private scratch directory.
## - **Fonts are bundled, never discovered.** resvg runs with
##   `--skip-system-fonts` and loads exactly `fontFiles`, so the host's fonts
##   cannot change a glyph. `defaultFontFamily` also stands in for the
##   generic families (`serif`, `sans-serif`, `monospace`) and for text that
##   names none.
## - **The template reads nothing else.** resvg (through usvg) loads the
##   target of an `<image>` or `<feImage>` link that is not a `data:` URL as
##   a file path, so `checkOgSvg` refuses every reference that leaves the
##   document. It judges what resvg will see, not how it is spelled:
##
##   - An attribute whose *local name* is `href`, `src` or `base` must be a
##     `#fragment` or a `data:` URL, whatever its namespace prefix. usvg
##     reads `href` with no prefix, in the XLink namespace under any prefix
##     (`xlink:href`, `x:href`) and in the `xml` namespace (`xml:href`), so
##     the check matches the local name and never trusts the prefix. An SVG
##     embedded as a `data:` URL is safe: usvg ignores its external images.
##   - CSS may reference only fragments: in a `<style>` element (its text
##     and its CDATA sections), in a `style` attribute and in any attribute
##     value with a `url(...)`, the check refuses `@import`, a `url(...)` that
##     is not a `#fragment`, and CSS escapes (`\`), which could spell either.
##     resvg 0.47 fetches no CSS resources; the check keeps a later resvg
##     from starting to.
##   - A document type declaration is refused, and with it every entity: an
##     entity can expand to markup this check would never see. So are
##     processing instructions other than the leading `<?xml ...?>`
##     declaration (e.g. `<?xml-stylesheet?>`) and undeclared entities.
##
##   resvg's command line has no switch that turns file loading off (its
##   library takes a resolver, which the executable does not expose), so the
##   check is the guard. resvg also runs in an empty scratch directory that
##   is its `--resources-dir`, and inside the Nix build sandbox only the
##   build's own inputs exist to be read.
## - **The size is checked, not assumed.** The PNG's own header must say
##   1200x630; a template of another aspect ratio is an error rather than a
##   letterboxed card.
##
## C only: it runs a native process.

when defined(js): {.error: "isonim/static/ogimage renders with a native tool; it is C only".}

import std/[os, osproc, parsexml, streams, strtabs, strutils, tempfiles, xmlparser, xmltree]
import ./images

const
  ogImageWidth* = 1200   ## The OpenGraph card width most platforms crop to.
  ogImageHeight* = 630   ## Its height (1.91:1).

type
  OgImageError* = object of ValueError
    ## A template that is not a self-contained SVG, a missing tool or font,
    ## a failed render, or a render of the wrong size.

  OgImageConfig* = object
    ## How to render. Every path must be absolute and exist.
    resvgPath*: string          ## The resvg executable.
    fontFiles*: seq[string]     ## The only fonts the render may use.
    defaultFontFamily*: string  ## A family in `fontFiles`, for generic names.

proc ogError(message: string) {.noreturn.} =
  raise newException(OgImageError, message)

proc inDocument(reference: string): bool =
  let value = reference.strip()
  value.startsWith("#") or value.toLowerAscii.startsWith("data:")

proc localName(name: string): string =
  ## The local part of a qualified XML name, lower-cased: `x:HREF` -> `href`.
  ## usvg matches `href` case-sensitively and in three namespaces; matching
  ## every prefix and case over-approximates it, and a false refusal is safe
  ## where a miss is not.
  name.rsplit(':', maxsplit = 1)[^1].toLowerAscii

const hrefLike = ["href", "src", "base"]
  ## Local names of attributes whose value names a resource (`base` is
  ## `xml:base`, which would re-root relative references).

proc checkCss(css, where: string) =
  ## CSS may reference only fragments. Escapes are refused, not decoded, so
  ## an escaped `url(` or `@import` cannot hide from the search below.
  let lower = css.toLowerAscii
  if '\\' in css: ogError(where & ": CSS escapes are not allowed in an OG template")
  if "@import" in lower: ogError(where & ": @import is not allowed in an OG template")
  var i = 0
  while true:
    i = lower.find("url(", i)
    if i < 0: return
    var target = css[i + 4 .. ^1].strip(trailing = false)
    if target.len > 0 and target[0] in {'"', '\''}: target = target[1 .. ^1]
    if not target.startsWith("#"):
      ogError(where & ": an OG template may reference only its own fragments, not url(" &
        css[i + 4 ..< min(css.len, i + 40)] & ")")
    i += 4

proc checkAttribute(element, name, value: string) =
  if name == "xmlns" or name.startsWith("xmlns:"): return  # namespace bindings
  let local = localName(name)
  let where = "<" & element & " " & name & "=\"" & value & "\">"
  if local in hrefLike and not inDocument(value):
    ogError(where & ": an OG template may reference only its own fragments or data: URLs")
  if local == "style" or "url(" in value.toLowerAscii: checkCss(value, where)

proc checkReferences(svg: string) =
  ## Walk the template's parse events rather than the tree std/xmlparser
  ## builds: the tree silently drops a DOCTYPE and processing instructions,
  ## and `innerText` skips CDATA, so each would hide content from the check.
  let lower = svg.toLowerAscii
  if "<!doctype" in lower or "<!entity" in lower:
    ogError("the OG template may not have a document type declaration or entities")
  var parser: XmlParser
  parser.open(newStringStream(svg), "og.svg")
  defer: parser.close()
  var open: seq[string]    # local names of the enclosing elements
  var styles: seq[string]  # text of each open <style>, CDATA included
  var element = ""         # the element whose attributes are being read
  while true:
    parser.next()
    case parser.kind
    of xmlEof: break
    of xmlError: ogError("the OG template is not well-formed XML: " & parser.errorMsg)
    of xmlElementStart, xmlElementOpen:
      element = parser.elementName
      open.add localName(element)
      if open[^1] == "style": styles.add ""
    of xmlAttribute: checkAttribute(element, parser.attrKey, parser.attrValue)
    of xmlElementClose, xmlComment: discard
    of xmlElementEnd:
      if open.len > 0:
        if open[^1] == "style":
          checkCss(styles.pop(), "<style>")
        open.setLen(open.len - 1)
    of xmlCharData, xmlWhitespace, xmlCData:
      if open.len > 0 and open[^1] == "style": styles[^1].add parser.charData
    of xmlPI:
      ogError("the OG template may not have processing instructions: <?" & parser.piName & " ...?>")
    of xmlSpecial:
      ogError("the OG template may not have <!" & parser.charData & ">")
    of xmlEntity:
      ogError("the OG template uses an undeclared entity: &" & parser.entityName & ";")

proc checkOgSvg*(svg: string) =
  ## Refuse a template that is not well-formed XML with an `<svg>` root, or
  ## that references anything outside itself (see the module notes).
  var errors: seq[string]
  let root =
    try: parseXml(newStringStream(svg), "og.svg", errors)
    except XmlError as cause: ogError("the OG template is not well-formed XML: " & cause.msg)
  if errors.len > 0: ogError("the OG template is not well-formed XML: " & errors[0])
  if root == nil or root.kind != xnElement or localName(root.tag) != "svg":
    ogError("the OG template's root element is not <svg>")
  checkReferences(svg)

proc existingAbsolute(path, what: string): string =
  if path.len == 0: ogError(what & " is not configured")
  if not path.isAbsolute or not fileExists(path):
    ogError(what & " must be an existing absolute path: " & path)
  path

proc renderOgImage*(svg: string; config: OgImageConfig): string =
  ## The PNG bytes of `svg` rendered at 1200x630. Equal inputs (template,
  ## resvg build, font files) give equal bytes. Raises `OgImageError`.
  checkOgSvg(svg)
  let resvg = existingAbsolute(config.resvgPath, "resvg")
  if config.fontFiles.len == 0:
    ogError("an OG image needs at least one bundled font file")
  var args = @["--skip-system-fonts"]
  for font in config.fontFiles:
    args.add @["--use-font-file", existingAbsolute(font, "font file")]
  if config.defaultFontFamily.len > 0:
    for flag in ["--font-family", "--serif-family", "--sans-serif-family", "--monospace-family"]:
      args.add @[flag, config.defaultFontFamily]
  let work = createTempDir("isonim-ogimage-", "")
  defer: removeDir(work)
  let input = work / "og.svg"
  let output = work / "og.png"
  writeFile(input, svg)
  # Relative references are already refused; the scratch directory holds
  # nothing but the template, so even resvg's resolution finds nothing.
  args.add @["--width", $ogImageWidth, "--height", $ogImageHeight,
    "--resources-dir", work, input, output]
  var diagnostics: string
  var status: int
  try:
    let process = startProcess(resvg, workingDir = work, args = args,
      options = {poStdErrToStdOut},
      env = newStringTable({"PATH": parentDir(resvg), "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8", "TZ": "UTC", "HOME": work}))
    defer: process.close()
    diagnostics = process.outputStream.readAll()
    status = process.waitForExit()
  except OSError as cause:
    ogError("resvg could not run: " & cause.msg)
  if status != 0: ogError("resvg exited with status " & $status & ": " & diagnostics.strip())
  if not fileExists(output): ogError("resvg produced no image: " & diagnostics.strip())
  result = readFile(output)
  let info =
    try: readImageInfo(result)
    except ImageError as cause: ogError("resvg wrote an unreadable image: " & cause.msg)
  if info.format != ifPng or info.width != ogImageWidth or info.height != ogImageHeight:
    ogError("the OG template must render at " & $ogImageWidth & "x" & $ogImageHeight &
      " (a 1.91:1 viewBox); it rendered at " & $info.width & "x" & $info.height)
