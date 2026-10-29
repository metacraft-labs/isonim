## isonim/static/images on C and JS, without test doubles. The header
## readers are checked against real encoder output: the fixtures in
## tests/fixtures/images were written by libvips and the codecs it links
## (tests/fixtures/images/generate.sh), an independent implementation of
## each format, and vipsheader reported their sizes (7x5). Two cases have
## no encoder in that toolchain and are built here from the format
## specifications, each next to its citation: a JPEG Exif orientation tag
## (CIPA DC-008 4.6.4, TIFF 6.0 IFD layout) and an AVIF rotation property
## (ISO/IEC 23008-12 6.5.10 `irot`). The native suite
## test_static_image_variants cross-checks the orientation case against
## libvips' own `autorot`.
import std/[unittest, strutils]
import isonim/static/images

const
  tinyPng = staticRead("fixtures/images/tiny.png")
  tinyJpeg = staticRead("fixtures/images/tiny.jpg")
  tinyGif = staticRead("fixtures/images/tiny.gif")
  animatedGif = staticRead("fixtures/images/tiny-animated.gif")
  lossyWebp = staticRead("fixtures/images/tiny-lossy.webp")
  losslessWebp = staticRead("fixtures/images/tiny-lossless.webp")
  animatedWebp = staticRead("fixtures/images/tiny-animated.webp")
  tinyAvif = staticRead("fixtures/images/tiny.avif")

proc be16(n: int): string = $chr(n div 256) & $chr(n mod 256)
proc be32(n: int): string = be16(n div 65536) & be16(n mod 65536)
proc le16(n: int): string = $chr(n mod 256) & $chr(n div 256)
proc le32(n: int): string = le16(n mod 65536) & le16(n div 65536)

proc withOrientation(jpeg: string; orientation: int; little = false): string =
  ## `jpeg` with an APP1 Exif segment after SOI whose IFD0 holds one entry:
  ## tag 0x0112 (Orientation), type 3 (SHORT), count 1, the value.
  let tiff =
    if little: "II" & le16(42) & le32(8) & le16(1) & le16(0x0112) & le16(3) & le32(1) &
      le16(orientation) & le16(0) & le32(0)
    else: "MM" & be16(42) & be32(8) & be16(1) & be16(0x0112) & be16(3) & be32(1) &
      be16(orientation) & be16(0) & be32(0)
  let payload = "Exif\0\0" & tiff
  jpeg[0 .. 1] & "\xff\xe1" & be16(payload.len + 2) & payload & jpeg[2 .. ^1]

proc box(kind, body: string): string = be32(body.len + 8) & kind & body
proc fullBox(kind: string; version: int; body: string): string =
  box(kind, $chr(version) & "\0\0\0" & body)

proc craftedAvif(width, height: int; turns = -1; brand = "avif"): string =
  ## The header boxes of an AVIF whose primary item (id 1) has an `ispe`
  ## (property 1) and, with `turns`, an `irot` (property 2); `ipma`
  ## version 0 with 7-bit property indexes. No image data: only the header
  ## is read.
  var properties = fullBox("ispe", 0, be32(width) & be32(height))
  var links = $chr(1)
  if turns >= 0:
    properties.add box("irot", $chr(turns))
    links = $chr(1) & $chr(2)
  let ipma = fullBox("ipma", 0, be32(1) & be16(1) & $chr(links.len) & links)
  let meta = fullBox("meta", 0, fullBox("pitm", 0, be16(1)) &
    box("iprp", box("ipco", properties) & ipma))
  box("ftyp", brand & be32(0) & "mif1" & brand) & meta

suite "image headers":
  test "real encoder output of every raster format":
    for (content, format) in [(tinyPng, ifPng), (tinyJpeg, ifJpeg), (tinyGif, ifGif),
        (lossyWebp, ifWebp), (losslessWebp, ifWebp), (tinyAvif, ifAvif)]:
      let info = readImageInfo(content)
      check info.format == format
      check info.width == 7 and info.height == 5
      check not info.animated
    # Two-frame files: the size is a frame's, and they are animated.
    for (content, format) in [(animatedGif, ifGif), (animatedWebp, ifWebp)]:
      let info = readImageInfo(content)
      check info.format == format and info.width == 7 and info.height == 5
      check info.animated

  test "a JPEG's Exif orientation turns its displayed size":
    check readImageInfo(withOrientation(tinyJpeg, 6)).width == 5
    check readImageInfo(withOrientation(tinyJpeg, 6)).height == 7
    check readImageInfo(withOrientation(tinyJpeg, 8, little = true)).width == 5
    # Half turns and mirrors keep the size; an invalid value is ignored.
    for orientation in [1, 2, 3, 4, 9]:
      let info = readImageInfo(withOrientation(tinyJpeg, orientation))
      check info.width == 7 and info.height == 5

  test "an AVIF primary item's ispe and irot":
    check readImageInfo(craftedAvif(640, 480)).width == 640
    let turned = readImageInfo(craftedAvif(640, 480, turns = 1))
    check turned.width == 480 and turned.height == 640
    check readImageInfo(craftedAvif(640, 480, turns = 2)).width == 640
    check readImageInfo(craftedAvif(640, 480, brand = "avis")).animated
    check not readImageInfo(craftedAvif(640, 480)).animated

  test "damaged and unknown files are errors":
    expect ImageError: discard readImageInfo(tinyPng[0 ..< 20])
    expect ImageError: discard readImageInfo(tinyJpeg[0 ..< 30])
    expect ImageError: discard readImageInfo(lossyWebp[0 ..< 24])
    expect ImageError: discard readImageInfo("BM not a supported bitmap")
    expect ImageError: discard readImageInfo("")
    # A PNG that says it is 0 pixels wide.
    var zero = tinyPng
    for i in 16 .. 19: zero[i] = '\0'
    expect ImageError: discard readImageInfo(zero)
    # An AVIF box that claims to run past the file.
    var overrun = craftedAvif(4, 4)
    overrun[3] = '\xff'
    expect ImageError: discard readImageInfo(overrun)

  test "an SVG's declared size":
    let head = "<?xml version=\"1.0\"?>\n<!-- a figure -->\n<!DOCTYPE svg>\n"
    check svgSize(head & "<svg width=\"120px\" height=\"80\"></svg>").width == 120
    check svgSize("<svg viewBox=\"0 0 300 150\"/>").height == 150
    check svgSize("<svg width=\"600\" viewBox=\"0,0,300,150\"/>").height == 300
    check svgSize("<svg height=\"50\" viewBox=\"0 0 300 150\"/>").width == 100
    # A relative width falls back to the viewBox; nothing at all is 0x0.
    check svgSize("<svg width=\"100%\" viewBox=\"0 0 30 20\"/>").width == 30
    let unsized = readImageInfo("<svg xmlns=\"http://www.w3.org/2000/svg\"><g/></svg>")
    check unsized.format == ifSvg and unsized.width == 0 and unsized.height == 0
    expect ImageError: discard svgSize("<html><svg/></html>")
    expect ImageError: discard svgSize("<svgx width=\"1\"/>")

suite "variant widths":
  test "configured widths below the source, plus the source when one reaches it":
    check variantWidths(1000, [480, 960, 1600]) == @[480, 960, 1000]
    check variantWidths(3000, [480, 960, 1600]) == @[480, 960, 1600]
    check variantWidths(960, [480, 960, 1600]) == @[480, 960]
    check variantWidths(300, [480, 960]) == @[300]
    check variantWidths(2000, [1600, 480, 480, 960]) == @[480, 960, 1600]
    check variantWidths(100, []).len == 0
    expect ImageError: discard variantWidths(100, [0])

suite "img markup":
  test "img tags in document order, outside comments and raw text":
    let html = "<p><IMG SRC=a.png Alt='A &amp; B'></p><!-- <img src=no.png> -->" &
      "<script>var s = \"<img src=no2.png>\";</script><style>/* <img> */</style>" &
      "<title><img src=no3.png></title><img src=\"b.png\" alt=\"&quot;b&quot;\" />" &
      "<imgx src=no4.png><picture><img\nsrc=c.svg\nalt=c></picture>"
    let tags = imgTags(html)
    check tags.len == 3
    check tags[0].attr("src") == "a.png" and tags[0].attr("alt") == "A & B"
    check tags[1].attr("alt") == "\"b\""
    check tags[2].attr("src") == "c.svg"
    check html[tags[1].first ..< tags[1].last] == "<img src=\"b.png\" alt=\"&quot;b&quot;\" />"
    expect ImageError: discard imgTags("<img src=\"x.png")

  test "a responsive picture with dimensions and lazy loading":
    let tag = imgTags("<img src=\"/assets/p.1.png\" alt=\"A <photo>\" class=\"wide\">")[0]
    let info = ImageInfo(format: ifPng, width: 1000, height: 600)
    let variants = @[
      ImageVariant(format: ifAvif, width: 480, height: 288, url: "/assets/p-480.a.avif"),
      ImageVariant(format: ifAvif, width: 1000, height: 600, url: "/assets/p-1000.b.avif"),
      ImageVariant(format: ifWebp, width: 480, height: 288, url: "/assets/p-480.c.webp")]
    check responsiveImageHtml(tag, info, variants, lazy = true) ==
      "<picture>" &
      "<source type=\"image/avif\" srcset=\"/assets/p-480.a.avif 480w, /assets/p-1000.b.avif 1000w\" " &
      "sizes=\"(min-width: 1000px) 1000px, 100vw\">" &
      "<source type=\"image/webp\" srcset=\"/assets/p-480.c.webp 480w\" " &
      "sizes=\"(min-width: 1000px) 1000px, 100vw\">" &
      "<img src=\"/assets/p.1.png\" alt=\"A <photo>\" class=\"wide\" width=\"1000\" " &
      "height=\"600\" loading=\"lazy\"></picture>"
    # The first image of a page is not lazy; without variants there is no
    # picture element.
    check responsiveImageHtml(tag, info, [], lazy = false) ==
      "<img src=\"/assets/p.1.png\" alt=\"A <photo>\" class=\"wide\" width=\"1000\" height=\"600\">"

  test "the author's own attributes are respected":
    let info = ImageInfo(format: ifPng, width: 1000, height: 600)
    let one = ImageVariant(format: ifWebp, width: 480, height: 288, url: "v.webp")
    # One dimension given: the other keeps the source's ratio.
    let wide = responsiveImageHtml(imgTags("<img src=a alt=a width=500>")[0], info, [], false)
    check "width=\"500\"" in wide and "height=\"300\"" in wide
    let tall = responsiveImageHtml(imgTags("<img src=a alt=a height=60>")[0], info, [], false)
    check "width=\"100\"" in tall and "height=\"60\"" in tall
    # Both given: kept. An own loading: kept. An own srcset: no picture.
    let own = responsiveImageHtml(imgTags("<img src=a alt=a width=1 height=2 loading=eager srcset=\"x 1x\">")[0],
      info, [one], true)
    check own == "<img src=\"a\" alt=\"a\" width=\"1\" height=\"2\" loading=\"eager\" srcset=\"x 1x\">"
    # An own sizes is carried onto the sources.
    let sized = responsiveImageHtml(imgTags("<img src=a alt=a sizes=\"50vw\">")[0], info, [one], false)
    check "<source type=\"image/webp\" srcset=\"v.webp 480w\" sizes=\"50vw\">" in sized
    # An SVG without a declared size gets no dimensions.
    check responsiveImageHtml(imgTags("<img src=a.svg alt=a>")[0], ImageInfo(format: ifSvg), [], true) ==
      "<img src=\"a.svg\" alt=\"a\" loading=\"lazy\">"

  test "rewriting replaces each tag and counts images from zero":
    let html = "<h1>T</h1><img src=a alt=a><p>x</p><img src=b alt=b>"
    let rewritten = rewriteImgTags(html, proc(tag: ImgTag; index: int): string =
      "[" & tag.attr("src") & $index & "]")
    check rewritten == "<h1>T</h1>[a0]<p>x</p>[b1]"
    check rewriteImgTags("<p>no images</p>", proc(tag: ImgTag; index: int): string = "!") ==
      "<p>no images</p>"

  test "formats, media types and extensions":
    check parseImageFormat("AVIF") == ifAvif
    check mediaType(ifWebp) == "image/webp" and extension(ifJpeg) == "jpg"
    expect ImageError: discard parseImageFormat("bmp")

suite "content images and decoding":
  test "async decoding is added only when asked, and the author's own value wins":
    let info = ImageInfo(format: ifPng, width: 10, height: 5)
    let plain = imgTags("<img src=a alt=a>")[0]
    check responsiveImageHtml(plain, info, [], lazy = false, asyncDecoding = true) ==
      "<img src=\"a\" alt=\"a\" width=\"10\" height=\"5\" decoding=\"async\">"
    check responsiveImageHtml(plain, info, [], lazy = true, asyncDecoding = true) ==
      "<img src=\"a\" alt=\"a\" width=\"10\" height=\"5\" loading=\"lazy\" decoding=\"async\">"
    # Negative control: without the flag nothing is added (the default).
    check "decoding" notin responsiveImageHtml(plain, info, [], lazy = true)
    let own = imgTags("<img src=a alt=a decoding=sync loading=eager>")[0]
    check responsiveImageHtml(own, info, [], lazy = true, asyncDecoding = true) ==
      "<img src=\"a\" alt=\"a\" decoding=\"sync\" loading=\"eager\" width=\"10\" height=\"5\">"

  test "the main element's content range, skipping comments and raw text":
    let html = "<header><img src=logo alt=L></header><!-- <main> -->" &
      "<script>var m = \"<main>\";</script><MAIN class=\"site-main\">" &
      "<img src=a alt=a><mainly></mainly></main><footer><img src=f alt=f></footer>"
    let range = mainContentRange(html)
    check html[range.first ..< range.last] == "<img src=a alt=a><mainly></mainly>"
    let tags = imgTags(html)
    var inside: seq[string]
    for tag in tags:
      if tag.first >= range.first and tag.first < range.last: inside.add tag.attr("src")
    check inside == @["a"]
    # Without a main element the whole document is the content.
    let plain = "<p><img src=a alt=a></p>"
    check mainContentRange(plain) == (0, plain.len)
    # An unclosed main runs to the end of the document.
    let open = "<main><img src=a alt=a>"
    check mainContentRange(open) == (6, open.len)
