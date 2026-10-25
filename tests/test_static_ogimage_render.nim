## isonim/static/ogimage against the real resvg and the bundled DejaVu font
## the content-tools shell supplies (`ISONIM_RESVG`, `ISONIM_OG_FONT`,
## `ISONIM_OG_FONT_BOLD`; entering another shell fails this suite, it never
## skips). Every positive case runs the real resvg; PNG sizes are read back
## from the files resvg wrote.
##
## Test double, and why: `instrumentTool` (tests/helpers/content_tool_fixture)
## wraps the real resvg so that its exit status can be replaced after it
## ran, the only way to make the real tool fail on demand. It never writes
## an image itself.
import std/[unittest, os, strutils, tempfiles]
import isonim/static/ogimage
import isonim/static/images
import ./helpers/content_tool_fixture

let resvg = getEnv("ISONIM_RESVG")
let font = getEnv("ISONIM_OG_FONT")
let bold = getEnv("ISONIM_OG_FONT_BOLD")
doAssert resvg.len > 0 and font.len > 0 and bold.len > 0,
  "ISONIM_RESVG/ISONIM_OG_FONT are not set: run this suite in nix develop .#content-tools"

let config = OgImageConfig(resvgPath: resvg, fontFiles: @[font, bold],
  defaultFontFamily: "DejaVu Sans")

proc card(title: string; extra = ""): string =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" " &
    "width=\"1200\" height=\"630\" viewBox=\"0 0 1200 630\">" &
    "<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"#123\"/>" &
    "<stop offset=\"1\" stop-color=\"#345\"/></linearGradient></defs>" &
    "<rect width=\"1200\" height=\"630\" fill=\"url(#g)\"/>" &
    "<text x=\"80\" y=\"300\" font-size=\"72\" font-weight=\"bold\" fill=\"#fff\">" & title & "</text>" &
    extra & "</svg>"

suite "rendering":
  test "a template renders to a 1200x630 PNG, identically every time":
    let first = renderOgImage(card("Hello, cards"), config)
    let info = readImageInfo(first)
    check info.format == ifPng and info.width == 1200 and info.height == 630
    check renderOgImage(card("Hello, cards"), config) == first
    # The text is really drawn with the bundled font: other text, other bytes.
    check renderOgImage(card("Other words"), config) != first
    check renderOgImage(card(""), config) != first

  test "a generic family and unstyled text use the bundled font":
    # With system fonts off, text in a family nobody bundled would vanish;
    # the default family stands in for generic names, so it is drawn.
    let generic = card("", "<text x=\"80\" y=\"500\" font-family=\"sans-serif\" font-size=\"40\">Generic</text>")
    let none = card("")
    check renderOgImage(generic, config) != renderOgImage(none, config)
    var noDefault = config
    noDefault.defaultFontFamily = ""
    # Negative control: without the stand-in the generic family resolves to
    # a font that was never loaded, and nothing is drawn.
    check renderOgImage(generic, noDefault) == renderOgImage(none, noDefault)

  test "a template of another aspect ratio is refused":
    try:
      discard renderOgImage("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"/>", config)
      check false
    except OgImageError as cause:
      check "it rendered at 630x630" in cause.msg

suite "hermetic templates":
  test "references outside the document are refused before resvg runs":
    let work = createTempDir("isonim-og-", "")
    defer: removeDir(work)
    writeFile(work / "secret.png", readFile(currentSourcePath().parentDir / "fixtures/images/tiny.png"))
    for extra in [
        "<image href=\"" & work / "secret.png" & "\" width=\"10\" height=\"10\"/>",
        "<image xlink:href=\"secret.png\" width=\"10\" height=\"10\"/>",
        "<image href=\"https://example.org/a.png\" width=\"10\" height=\"10\"/>",
        "<rect width=\"1\" height=\"1\" style=\"fill: url('file:///etc/passwd')\"/>",
        "<style>@import url(\"theme.css\");</style>",
        "<style>rect { fill: url(other.svg#p) }</style>",
        "<use href=\"other.svg#shape\"/>"]:
      expect OgImageError: discard renderOgImage(card("x", extra), config)

  test "references are judged by what resvg reads, not by their spelling":
    let work = createTempDir("isonim-og-", "")
    defer: removeDir(work)
    let secret = work / "secret.png"
    writeFile(secret, readFile(currentSourcePath().parentDir / "fixtures/images/tiny.png"))
    const xlink = "xmlns:x=\"http://www.w3.org/1999/xlink\""
    let image = "width=\"1200\" height=\"630\""
    # Each element (or whole document) below is a way to reach a file or a
    # stylesheet that a check matching attribute names or tree text misses.
    var templates: seq[(string, string)]
    for (name, extra) in [
        ("XLink under another prefix", "<image " & xlink & " x:href=\"" & secret & "\" " & image & "/>"),
        ("href in the xml namespace", "<image xml:href=\"" & secret & "\" " & image & "/>"),
        ("feImage, XLink under another prefix", "<filter id=\"f\"><feImage " & xlink &
          " x:href=\"" & secret & "\"/></filter><rect " & image & " filter=\"url(#f)\"/>"),
        ("xml:base", "<g xml:base=\"file:///etc/\"><use href=\"#g\"/></g>"),
        ("@import in CDATA", "<style><![CDATA[@import url(\"theme.css\");]]></style>"),
        ("url() in CDATA", "<style><![CDATA[rect { fill: url(other.svg#p) }]]></style>"),
        ("url() split over text and CDATA", "<style>rect { fill: ur<![CDATA[l(other.svg#p) }]]></style>"),
        ("an escaped url()", "<style>rect { fill: u\\72l(other.svg#p) }</style>"),
        ("url() in a presentation attribute", "<rect width=\"1\" height=\"1\" fill=\"url(other.svg#p)\"/>"),
        ("an undeclared entity", "<text>&secret;</text>")]:
      templates.add (name, card("x", extra))
    templates.add ("a DOCTYPE entity that expands to an image",
      "<!DOCTYPE svg [<!ENTITY e \"<image href='" & secret & "' " & image.replace("\"", "'") &
      "/>\">]>" & card("x", "&e;"))
    templates.add ("an xml-stylesheet instruction", "<?xml-stylesheet href=\"theme.css\"?>" & card("x"))
    for (name, svg) in templates:
      checkpoint name
      expect OgImageError: discard renderOgImage(svg, config)

  test "the prefix and entity cases are ones resvg really follows":
    # Positive control for the test above: rendered by resvg directly, with
    # no check in front of it, these templates draw the file when it exists
    # and nothing when it does not, so refusing them is what stops a read.
    let work = createTempDir("isonim-og-", "")
    defer: removeDir(work)
    let secret = work / "secret.png"
    writeFile(secret, readFile(currentSourcePath().parentDir / "fixtures/images/tiny.png"))
    proc direct(svg: string): string =
      writeFile(work / "in.svg", svg)
      check execShellCmd(quoteShell(resvg) & " --skip-system-fonts " &
        quoteShell(work / "in.svg") & " " & quoteShell(work / "out.png")) == 0
      readFile(work / "out.png")
    let image = "width=\"1200\" height=\"630\""
    for svg in [
        card("", "<image xmlns:x=\"http://www.w3.org/1999/xlink\" x:href=\"" & secret & "\" " & image & "/>"),
        card("", "<image xml:href=\"" & secret & "\" " & image & "/>"),
        "<!DOCTYPE svg [<!ENTITY e \"<image href='" & secret & "' " & image.replace("\"", "'") &
          "/>\">]>" & card("", "&e;")]:
      check direct(svg) != direct(svg.replace(secret, work / "absent.png"))

  test "in-document references in any spelling are accepted":
    let ok = [
      card("x", "<image xmlns:x=\"http://www.w3.org/1999/xlink\" x:href=\"#g\"/>"),
      card("x", "<style><![CDATA[rect { fill: url(#g) }]]></style>"),
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & card("x", "<!-- a comment -->")]
    for svg in ok:
      check readImageInfo(renderOgImage(svg, config)).width == 1200
    # In-document references are fine: fragments and data: URLs.
    let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
    check readImageInfo(renderOgImage(card("x", "<use href=\"#g\"/><image href=\"" & png &
      "\" width=\"10\" height=\"10\"/><rect width=\"1\" height=\"1\" style=\"fill:url(#g)\"/>"),
      config)).width == 1200

  test "malformed templates, missing tools and fonts are errors":
    for svg in ["<svg", "<html/>", "not xml", "<svg xmlns=\"http://www.w3.org/2000/svg\"><g></svg>"]:
      expect OgImageError: discard renderOgImage(svg, config)
    var bad = config
    bad.resvgPath = ""
    expect OgImageError: discard renderOgImage(card("x"), bad)
    bad.resvgPath = "resvg"
    expect OgImageError: discard renderOgImage(card("x"), bad)
    bad = config
    bad.fontFiles = @[]
    expect OgImageError: discard renderOgImage(card("x"), bad)
    bad.fontFiles = @["/nonexistent/font.ttf"]
    expect OgImageError: discard renderOgImage(card("x"), bad)
    let work = createTempDir("isonim-og-", "")
    defer: removeDir(work)
    bad = config
    bad.resvgPath = instrumentTool(work, "resvg", resvg, "exit 4")
    try:
      discard renderOgImage(card("x"), bad)
      check false
    except OgImageError as cause:
      check "resvg exited with status 4" in cause.msg
