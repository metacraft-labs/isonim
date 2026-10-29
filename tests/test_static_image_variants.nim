## isonim/static/assets responsive images against the real libvips the
## content-tools shell supplies (`ISONIM_VIPS`; entering another shell fails
## this suite, it never skips). Every positive case runs the real `vips`.
##
## Test doubles, and why: `instrumentTool` (tests/helpers/content_tool_fixture)
## wraps the real executable in a shell script that counts its invocations
## (the only way to observe that a cached variant was not re-encoded) or
## replaces its exit status after it ran (the only way to make a real tool
## fail on demand). Neither ever produces image output itself.
import std/[unittest, os, osproc, strutils, tables, tempfiles]
import isonim/static/assets
import ./helpers/content_tool_fixture

let vips = getEnv("ISONIM_VIPS")
doAssert vips.len > 0 and fileExists(vips),
  "ISONIM_VIPS is not set: run this suite in nix develop .#content-tools"
let vipsheader = parentDir(vips) / "vipsheader"

proc tool(args: varargs[string]): string =
  ## Run a libvips CLI directly (an independent oracle for the module's own
  ## invocation), with the same fixed thread count.
  let (output, status) = execCmdEx("env -i VIPS_CONCURRENCY=1 " &
    quoteShellCommand(@args))
  doAssert status == 0, output
  output

proc source(work: string; width, height: int; format = "png"): string =
  ## A real raster of seeded noise (so encoders cannot shortcut it).
  let raw = work / "noise.v"
  discard tool(vips, "gaussnoise", raw, $width, $height, "--mean", "128", "--sigma", "50", "--seed", "7")
  discard tool(vips, "bandjoin_const", raw, work / "rgb.v", "0 255")
  let path = work / ("source." & format)
  discard tool(vips, "cast", work / "rgb.v", path & "[keep=none]", "uchar")
  readFile(path)

proc config(cache = ""): ImageVariantConfig =
  ImageVariantConfig(vipsPath: vips, widths: @[480, 960, 1600],
    formats: @[ifAvif, ifWebp], maxSourceBytes: 2_000_000, cacheDir: cache)

proc site(prefix = ""): proc(path: string): string =
  result = proc(path: string): string = prefix & "/" & path

suite "variants from the real libvips":
  test "a raster yields every configured width and format, measured independently":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let png = source(work, 1000, 600)
    let images = newResponsiveImages(config(), site("/blog"))
    let found = images.imageSet("assets/posts/b/photo.png", png)
    check found.info == ImageInfo(format: ifPng, width: 1000, height: 600)
    # Widths below the 1000-pixel source, plus the source width itself.
    var made: seq[string]
    for v in found.variants: made.add $v.format & "@" & $v.width & "x" & $v.height
    check made == @["avif@480x288", "avif@960x576", "avif@1000x600",
      "webp@480x288", "webp@960x576", "webp@1000x600"]
    check images.files.len == 6
    for i, file in images.files:
      let variant = found.variants[i]
      let ext = if variant.format == ifAvif: ".avif" else: ".webp"
      check file.path.startsWith("assets/posts/b/photo-" & $variant.width & ".")
      check file.path.endsWith(ext)
      check file.path == hashedAssetName("assets/posts/b/photo-" & $variant.width & ext, file.content)
      check variant.url == "/blog/" & file.path
      # libvips' own reader agrees with the header reader on every file.
      let written = work / extractFilename(file.path)
      writeFile(written, file.content)
      check tool(vipsheader, "-f", "width", written).strip == $variant.width
      check tool(vipsheader, "-f", "height", written).strip == $variant.height
      check tool(vipsheader, "-f", "vips-loader", written).strip ==
        (if variant.format == ifAvif: "heifload" else: "webpload")
      # Metadata is stripped: no Exif, XMP or ICC profile survives.
      let fields = tool(vipsheader, "-a", written)
      check "exif-data" notin fields and "xmp-data" notin fields and "icc-profile-data" notin fields
    # Asking again for the same source makes nothing new.
    discard images.imageSet("assets/posts/b/photo.png", png)
    check images.files.len == 6

  test "two independent runs write identical bytes":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let png = source(work, 1300, 700)
    let first = newResponsiveImages(config(), site())
    let second = newResponsiveImages(config(), site())
    discard first.imageSet("assets/a.png", png)
    discard second.imageSet("assets/a.png", png)
    check first.files.len == 6
    check first.files == second.files

  test "the cache serves identical encodes and replaces a damaged entry":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let png = source(work, 700, 400)
    let counter = work / "calls"
    let counted = instrumentTool(work, "vips", vips, "", counter)
    var cfg = config(work / "cache")
    cfg.vipsPath = counted
    let cold = newResponsiveImages(cfg, site())
    discard cold.imageSet("assets/a.png", png)
    let encodes = readFile(counter).count('\n')
    # One --version for the cache key, then 480 and 700 in two formats.
    check encodes == 5
    let warm = newResponsiveImages(cfg, site())
    discard warm.imageSet("assets/a.png", png)
    check warm.files == cold.files
    # Only the identity query ran: every variant came from the cache.
    check readFile(counter).count('\n') == encodes + 1
    # A damaged entry is re-encoded rather than served.
    var entries: seq[string]
    for file in walkFiles(work / "cache" / "*.webp"): entries.add file
    check entries.len == 2
    writeFile(entries[0], "not a webp")
    let repaired = newResponsiveImages(cfg, site())
    discard repaired.imageSet("assets/a.png", png)
    check repaired.files == cold.files
    check readFile(counter).count('\n') == encodes + 3
    check readImageInfo(readFile(entries[0])).format == ifWebp

  test "an SVG and an animated GIF get no raster variants":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let counter = work / "calls"
    var cfg = config()
    cfg.vipsPath = instrumentTool(work, "vips", vips, "", counter)
    let images = newResponsiveImages(cfg, site())
    let svg = images.imageSet("assets/figure.svg",
      "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1200 800\"><rect width=\"9\" height=\"9\"/></svg>")
    check svg.info == ImageInfo(format: ifSvg, width: 1200, height: 800)
    check svg.variants.len == 0
    let gif = images.imageSet("assets/a.gif", readFile(currentSourcePath().parentDir / "fixtures/images/tiny-animated.gif"))
    check gif.info.animated and gif.variants.len == 0
    check images.files.len == 0
    # vips never ran.
    check not fileExists(counter)
    # Positive control: a raster in the same configuration does run it.
    discard images.imageSet("assets/b.png", source(work, 500, 300))
    check images.files.len == 4 and fileExists(counter)

  test "a JPEG's Exif orientation matches libvips' autorot":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let jpeg = source(work, 640, 360, "jpg")
    # The same APP1 Exif segment the pure suite builds: Orientation = 6.
    let tiff = "MM\0\x2a\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01\0\x06\0\0\0\0\0\0"
    let payload = "Exif\0\0" & tiff
    let oriented = jpeg[0 .. 1] & "\xff\xe1" & $chr((payload.len + 2) div 256) &
      $chr((payload.len + 2) mod 256) & payload & jpeg[2 .. ^1]
    writeFile(work / "oriented.jpg", oriented)
    check tool(vipsheader, "-f", "orientation", work / "oriented.jpg").strip == "6"
    discard tool(vips, "autorot", work / "oriented.jpg", work / "upright.v")
    let info = readImageInfo(oriented)
    check $info.width == tool(vipsheader, "-f", "width", work / "upright.v").strip
    check $info.height == tool(vipsheader, "-f", "height", work / "upright.v").strip
    check info.width == 360 and info.height == 640

suite "pages":
  proc resolver(files: Table[string, string]): proc(src: string): ImageReference =
    result = proc(src: string): ImageReference =
      if src.startsWith("http://") or src.startsWith("https://") or src.startsWith("data:"):
        ImageReference(kind: irExternal)
      elif files.hasKey(src):
        ImageReference(kind: irFile, name: src[1 .. ^1], content: files[src])
      else: ImageReference(kind: irMissing)

  test "every image gets dimensions, rasters get pictures, later images load lazily":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    var files = initTable[string, string]()
    files["/assets/photo.png"] = source(work, 1000, 600)
    files["/assets/figure.svg"] = "<svg width=\"300\" height=\"200\"/>"
    var allowed = config()
    allowed.remoteOrigins = @["https://elsewhere.example"]
    let images = newResponsiveImages(allowed, site())
    let html = "<header><img src=\"/assets/figure.svg\" alt=\"Logo\"></header>" &
      "<p><img src=\"/assets/photo.png\" alt=\"A photo\"></p>" &
      "<p><img src=\"https://elsewhere.example/x.png\" alt=\"Remote\"></p>"
    let page = images.rewritePageImages(html, "posts/a.md", resolver(files))
    let tags = imgTags(page)
    check tags.len == 3
    check tags[0].attr("width") == "300" and tags[0].attr("height") == "200"
    check not tags[0].hasAttr("loading")
    check tags[1].attr("width") == "1000" and tags[1].attr("height") == "600"
    check tags[1].attr("loading") == "lazy" and tags[2].attr("loading") == "lazy"
    # A page without <main> is all content: every image decodes asynchronously.
    for tag in tags: check tag.attr("decoding") == "async"
    check not tags[2].hasAttr("width")
    check page.count("<picture>") == 1 and page.count("<source ") == 2
    check "<source type=\"image/avif\" srcset=\"/assets/photo-480." in page
    check images.warnings == @["posts/a.md: the image https://elsewhere.example/x.png is not a file " &
      "of the site, so it has no width, height or variants"]

  test "a missing or blank alt attribute, an oversized source and a missing file are errors":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    var files = initTable[string, string]()
    files["/assets/photo.png"] = source(work, 600, 400)
    let images = newResponsiveImages(config(), site())
    for (html, message) in [
        ("<img src=\"/assets/photo.png\">", "posts/a.md: the image /assets/photo.png has no alt attribute"),
        ("<img src=\"/assets/photo.png\" alt=\"  \">", "has alt text of only whitespace"),
        ("<img src=\"/assets/gone.png\" alt=\"x\">", "the image /assets/gone.png is not a file of the site")]:
      try:
        discard images.rewritePageImages(html, "posts/a.md", resolver(files))
        check false
      except ImageError as cause:
        check message in cause.msg
    var small = config()
    small.maxSourceBytes = files["/assets/photo.png"].len - 1
    try:
      discard newResponsiveImages(small, site()).rewritePageImages(
        "<img src=\"/assets/photo.png\" alt=\"x\">", "posts/a.md", resolver(files))
      check false
    except ImageError as cause:
      check "over the limit of " & $small.maxSourceBytes in cause.msg
    # Positive control: at exactly the limit the same image is accepted.
    small.maxSourceBytes = files["/assets/photo.png"].len
    check "<picture>" in newResponsiveImages(small, site()).rewritePageImages(
      "<img src=\"/assets/photo.png\" alt=\"x\">", "posts/a.md", resolver(files))

  test "a missing or failing vips is an error, never a skip":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let png = source(work, 600, 400)
    var cfg = config()
    cfg.vipsPath = ""
    expect ImageError: discard newResponsiveImages(cfg, site()).imageSet("assets/a.png", png)
    cfg.vipsPath = "relative/vips"
    expect ImageError: discard newResponsiveImages(cfg, site()).imageSet("assets/a.png", png)
    cfg.vipsPath = instrumentTool(work, "vips", vips, "exit 3")
    try:
      discard newResponsiveImages(cfg, site()).imageSet("assets/a.png", png)
      check false
    except ImageError as cause:
      check "vips exited with status 3" in cause.msg
    # Without variant formats, vips is not needed at all.
    cfg.vipsPath = ""
    cfg.formats = @[]
    check newResponsiveImages(cfg, site()).imageSet("assets/a.png", png).variants.len == 0
    cfg.formats = @[ifPng]
    expect ImageError: discard newResponsiveImages(cfg, site())

  test "alt=\"\" marks a decorative image and is accepted":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    var files = initTable[string, string]()
    files["/assets/rule.png"] = source(work, 300, 20)
    let page = newResponsiveImages(config(), site()).rewritePageImages(
      "<img src=\"/assets/rule.png\" alt=\"\">", "posts/a.md", resolver(files))
    check imgTags(page)[0].attr("alt") == "" and imgTags(page)[0].hasAttr("alt")
    check imgTags(page)[0].attr("width") == "300"

  test "only the main content's images are lazy and async; the first of them loads eagerly":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    var files = initTable[string, string]()
    files["/assets/logo.png"] = source(work, 200, 100)
    files["/assets/hero.png"] = source(work, 600, 300)
    files["/assets/later.png"] = source(work, 500, 300)
    let images = newResponsiveImages(config(), site())
    let html = "<header><img src=\"/assets/logo.png\" alt=\"Logo\"></header>" &
      "<main><h1>Post</h1><img src=\"/assets/hero.png\" alt=\"Hero\">" &
      "<p><img src=\"/assets/later.png\" alt=\"Later\"></p>" &
      "<p><img src=\"/assets/later.png\" alt=\"Own\" loading=\"eager\" decoding=\"sync\"></p></main>" &
      "<footer><img src=\"/assets/logo.png\" alt=\"Logo again\"></footer>"
    let tags = imgTags(images.rewritePageImages(html, "posts/a.md", resolver(files)))
    check tags.len == 5
    # Outside <main>: dimensions, but neither loading nor decoding.
    for outside in [tags[0], tags[4]]:
      check outside.attr("width") == "200"
      check not outside.hasAttr("loading") and not outside.hasAttr("decoding")
    # The first content image is the likely LCP element: eager, async.
    check not tags[1].hasAttr("loading") and tags[1].attr("decoding") == "async"
    check tags[2].attr("loading") == "lazy" and tags[2].attr("decoding") == "async"
    # The author's own attributes win.
    check tags[3].attr("loading") == "eager" and tags[3].attr("decoding") == "sync"

  test "a remote image needs its origin allowed; data: URLs stay allowed":
    let images = newResponsiveImages(block:
        var cfg = config()
        cfg.remoteOrigins = @["https://CDN.example.net/", "https://cdn.example.net"]
        cfg, site())
    let files = initTable[string, string]()
    # Allowed: the origin matches after normalisation (case, default port).
    let allowed = images.rewritePageImages(
      "<img src=\"https://cdn.example.net:443/a.png\" alt=\"A\">" &
      "<img src=\"data:image/gif;base64,R0lGODlhAQABAAAAACw=\" alt=\"Dot\">", "posts/a.md", resolver(files))
    check imgTags(allowed).len == 2
    check images.warnings.len == 2
    # Both dimensions set by the author: nothing shifts, so no warning. With
    # only one of them the warning stays (the control).
    let sized = images.rewritePageImages(
      "<img src=\"https://cdn.example.net/b.png\" alt=\"B\" width=\"40\" height=\"30\">" &
      "<img src=\"https://cdn.example.net/c.png\" alt=\"C\" width=\"40\">", "posts/a.md", resolver(files))
    check imgTags(sized)[0].attr("width") == "40" and imgTags(sized)[0].attr("height") == "30"
    check images.warnings.len == 3
    check images.warnings[^1] == "posts/a.md: the image https://cdn.example.net/c.png is not a file " &
      "of the site, so it has no width, height or variants"
    for (src, message) in [
        ("https://elsewhere.example/a.png", "is on https://elsewhere.example, which is not an allowed remote image origin"),
        ("http://cdn.example.net/a.png", "is on http://cdn.example.net, which is not an allowed remote image origin"),
        ("//cdn.example.net/a.png", "is protocol-relative"),
        ("ftp://cdn.example.net/a.png", "is not a file of the site, a data: URL or an http(s) URL")]:
      try:
        discard images.rewritePageImages("<img src=\"" & src & "\" alt=\"x\">", "posts/a.md",
          proc(s: string): ImageReference = ImageReference(kind: irExternal))
        check false
      except ImageError as cause:
        check ("posts/a.md: the image " & src & " " & message) in cause.msg
    # Without an allow-list every remote image is an error.
    expect ImageError:
      discard newResponsiveImages(config(), site()).rewritePageImages(
        "<img src=\"https://cdn.example.net/a.png\" alt=\"A\">", "posts/a.md", resolver(files))
    # A malformed origin in the configuration is refused up front.
    var bad = config()
    bad.remoteOrigins = @["https://cdn.example.net/images"]
    expect ImageError: discard newResponsiveImages(bad, site())

  test "the encoder quality is configurable, validated and part of the cache key":
    let work = createTempDir("isonim-variants-", "")
    defer: removeDir(work)
    let png = source(work, 500, 300)
    proc encoded(avif, webp: int; cache = ""): seq[tuple[path, content: string]] =
      var cfg = config(cache)
      cfg.avifQuality = avif
      cfg.webpQuality = webp
      let images = newResponsiveImages(cfg, site())
      discard images.imageSet("assets/a.png", png)
      images.files
    let defaults = encoded(0, 0)
    # 0 means the defaults, which are AVIF 50 and WebP 75.
    check encoded(defaultAvifQuality, defaultWebpQuality) == defaults
    check defaultAvifQuality == 50 and defaultWebpQuality == 75
    # A lower quality makes smaller files, measured on the bytes themselves.
    let low = encoded(20, 30)
    check low.len == defaults.len
    for i in 0 ..< low.len:
      check low[i].content.len < defaults[i].content.len
    # A shared cache does not serve one quality's variants for another.
    let cache = work / "cache"
    discard encoded(0, 0, cache)
    check encoded(20, 30, cache) == low
    for quality in [-1, 101]:
      var cfg = config()
      cfg.avifQuality = quality
      expect ImageError: discard newResponsiveImages(cfg, site())
      cfg.avifQuality = 0
      cfg.webpQuality = quality
      expect ImageError: discard newResponsiveImages(cfg, site())
