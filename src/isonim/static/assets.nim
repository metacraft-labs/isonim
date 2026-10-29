## isonim/static/assets -- the static-asset pipeline: content-hashed file
## names (`style.css` -> `style.<hash>.css`), an `asset-manifest.json`
## mapping each original to its hashed name, and a small CSS purge that
## drops the rules for classes no built page uses.
##
## Moved from isonim-docs (`src/core/asset_pipeline.nim`, plus the
## directory pass `hashAndPurgeAssets` from `src/build_site.nim`), which
## now re-export it. `contentHash` is a cache key, not a security hash.
## The directory pass visits files in sorted order, so the manifest and
## the returned rewrites do not depend on the order the file system lists
## a directory in.
##
## Responsive images: `ResponsiveImages` measures every image a
## built page shows, resizes each raster once into AVIF and WebP variants
## with an injected libvips, and rewrites the page's `<img>` elements into
## `<picture>` elements with `srcset`, `width`, `height`, `loading` and
## `decoding`, enforcing alt text and an allow-list of remote image origins
## (see the section below and `isonim/static/images`).

import std/[os, sets, strutils, json, sequtils, algorithm, osproc, streams, strtabs, tables, tempfiles]
import ./images
import ./buildinfo
import ./urls
export images

{.push warning[Deprecated]: off.}
import std/md5
{.pop.}

proc contentHash*(content: string): string =
  ## Short deterministic content-hash for cache-busting filenames
  ## (`style.<hash>.css`) -- a prefix of the MD5 digest is plenty of
  ## entropy for a build-time cache key; this is not a security hash.
  getMD5(content)[0 ..< 10]

proc hashedAssetName*(relPath, content: string): string =
  ## `style.css` -> `style.<hash>.css`; a nested `relPath` keeps its
  ## directory prefix, e.g. `img/logo.png` -> `img/logo.<hash>.png`.
  let (dir, name, ext) = splitFile(relPath)
  let hashedName = name & "." & contentHash(content) & ext
  if dir.len == 0: hashedName else: dir / hashedName

proc extractUsedClasses*(html: string): HashSet[string] =
  ## Scans `class="..."`/`class='...'` attribute values out of rendered
  ## HTML -- the set `purgeCss` keeps rules for.
  result = initHashSet[string]()
  var i = 0
  while true:
    let idx = html.find("class=", i)
    if idx < 0: break
    var j = idx + "class=".len
    if j < html.len and html[j] in {'"', '\''}:
      let quote = html[j]
      inc j
      let start = j
      while j < html.len and html[j] != quote: inc j
      for token in html[start ..< j].splitWhitespace():
        result.incl token
      i = j + 1
    else:
      i = idx + "class=".len

proc stripComments(css: string): string =
  ## Strips `/* ... */` comments before any brace/selector parsing --
  ## comments are free-form prose and may themselves contain `{`, `}`,
  ## or `.word` tokens (e.g. a file-header comment naming a `.nim`
  ## module), which would otherwise desync the block splitter or be
  ## misread as class selectors.
  result = newStringOfCap(css.len)
  var i = 0
  while i < css.len:
    if css[i] == '/' and i + 1 < css.len and css[i + 1] == '*':
      let closeIdx = css.find("*/", i + 2)
      if closeIdx < 0: break
      i = closeIdx + 2
    else:
      result.add css[i]
      inc i

proc splitTopLevelBlocks(css: string): seq[tuple[header, body: string]] =
  ## Splits `css` into top-level `header { body }` pairs; `body` keeps
  ## any nested braces verbatim (e.g. an `@media` block's own rules),
  ## matched by brace depth rather than assuming one level of nesting.
  ## Assumes comments have already been stripped (see `stripComments`).
  result = @[]
  var i = 0
  let n = css.len
  while i < n:
    let openIdx = css.find('{', i)
    if openIdx < 0: break
    let header = css[i ..< openIdx].strip()
    var depth = 1
    var j = openIdx + 1
    while j < n and depth > 0:
      case css[j]
      of '{': inc depth
      of '}': dec depth
      else: discard
      inc j
    let body = css[openIdx + 1 ..< max(openIdx + 1, j - 1)]
    if header.len > 0:
      result.add (header, body)
    i = j

proc classesInSelector(selector: string): seq[string] =
  result = @[]
  var i = 0
  while i < selector.len:
    if selector[i] == '.':
      var j = i + 1
      while j < selector.len and (selector[j].isAlphaNumeric or selector[j] in {'-', '_'}):
        inc j
      if j > i + 1:
        result.add selector[i + 1 ..< j]
      i = j
    else:
      inc i

proc selectorListIsUsed(headerCombined: string, used: HashSet[string]): bool =
  ## `headerCombined` may be a comma-separated selector list; kept if
  ## ANY individual selector has no class constraint (element/attribute/
  ## pseudo selectors, `:root`, ...) or references a used class.
  for sel in headerCombined.split(','):
    let classes = classesInSelector(sel.strip())
    if classes.len == 0 or classes.anyIt(it in used):
      return true
  false

proc purgeCss*(css: string, usedClasses: HashSet[string]): string =
  ## Drops CSS rules whose selectors reference ONLY unused classes --
  ## a hand-rolled equivalent of a Tailwind purge, run against the
  ## classes actually emitted across every rendered page. Rules with no
  ## class in their selector (resets, `:root`, attribute selectors) and
  ## unrecognized at-rules (`@font-face`, `@keyframes`, ...) are always
  ## kept verbatim; `@media`/`@supports` recurse into their nested rules.
  var parts: seq[string] = @[]
  for (header, body) in splitTopLevelBlocks(stripComments(css)):
    let lower = header.toLowerAscii
    if lower.startsWith("@media") or lower.startsWith("@supports"):
      var nested: seq[string] = @[]
      for (innerHeader, innerBody) in splitTopLevelBlocks(body):
        if selectorListIsUsed(innerHeader, usedClasses):
          nested.add innerHeader & " {" & innerBody & "}"
      if nested.len > 0:
        parts.add header & " {\n" & nested.join("\n") & "\n}"
    elif header.startsWith("@"):
      parts.add header & " {" & body & "}"
    elif selectorListIsUsed(header, usedClasses):
      parts.add header & " {" & body & "}"
  parts.join("\n\n") & "\n"

proc renderAssetManifest*(entries: openArray[tuple[original, hashed: string]]): string =
  ## The `asset-manifest.json` text: one key per original path, in the
  ## order given, pretty-printed with a trailing newline.
  var obj = newJObject()
  for (original, hashed) in entries:
    obj[original] = %hashed
  pretty(obj) & "\n"

proc writeAssetManifest*(path: string, entries: seq[tuple[original, hashed: string]]) =
  ## Writes `renderAssetManifest(entries)` to `path`.
  writeFile(path, renderAssetManifest(entries))

proc hashAndPurgeAssets*(siteDir: string; usedClasses: HashSet[string];
                         purgeFiles: openArray[string] = ["style.css"];
                         assetsSubdir = "assets";
                         manifestName = "asset-manifest.json"):
    seq[tuple[fromHref, toHref: string]] =
  ## Content-hashes every file under `siteDir/assetsSubdir` in place,
  ## first purging (`purgeCss`) each file whose path relative to that
  ## directory is in `purgeFiles`, removes the unhashed copies, and writes
  ## `siteDir/manifestName` (`assets/<name>` -> `assets/<hashed name>`).
  ## Returns the `/assets/<name>` -> `/assets/<hashed name>` rewrites a
  ## caller applies to already-rendered HTML. Files are visited in sorted
  ## path order (with `/` separators on every OS), so equal inputs give an
  ## equal manifest and equal rewrites. A missing assets directory yields
  ## an empty manifest.
  let assetsDir = siteDir / assetsSubdir
  var relPaths: seq[string] = @[]
  if dirExists(assetsDir):
    for relPath in walkDirRec(assetsDir, relative = true):
      relPaths.add relPath.replace('\\', '/')
  relPaths.sort(system.cmp[string])
  # Snapshot and validate the whole plan before any destination can
  # overwrite an original. A hashed name may itself be an input name.
  var planned: seq[tuple[original, hashed, content: string]]
  var destinations = initHashSet[string]()
  for relPath in relPaths:
    var content = readFile(assetsDir / relPath)
    if relPath in purgeFiles: content = purgeCss(content, usedClasses)
    let hashed = hashedAssetName(relPath, content).replace('\\', '/')
    let key = hashed.toLowerAscii
    if key in destinations or dirExists(assetsDir / hashed):
      raise newException(ValueError, "asset destination collision: " & hashed)
    destinations.incl key
    planned.add (relPath, hashed, content)
  var manifestEntries: seq[tuple[original, hashed: string]]
  for item in planned:
    let destination = assetsDir / item.hashed
    createDir(destination.parentDir)
    # A copied symlink is an input, never permission to overwrite its target.
    if symlinkExists(destination): removeFile(destination)
    writeFile(destination, item.content)
    manifestEntries.add (assetsSubdir & "/" & item.original, assetsSubdir & "/" & item.hashed)
    result.add ("/" & assetsSubdir & "/" & item.original, "/" & assetsSubdir & "/" & item.hashed)
  for item in planned:
    if item.original.toLowerAscii notin destinations:
      removeFile(assetsDir / item.original)
  writeAssetManifest(siteDir / manifestName, manifestEntries)

# --- Responsive image variants ----------------------------------------------
#
# Every raster a page shows gets `width` and `height` and, for formats that
# have a still frame to resize, AVIF/WebP copies at the configured widths,
# written by libvips (https://www.libvips.org/API/current/Using-vipsthumbnail.html)
# from an injected executable. The pure half (header reading, `srcset`,
# `<picture>` markup) is `isonim/static/images`.
#
# Variants are reproducible: libvips runs with a fixed minimal environment,
# with a fixed thread count (an AV1 encode's bytes depend on how many threads
# split the frame, so leaving it to the host's core count would make the
# output depend on the machine) and with its own SIMD paths off
# (`VIPS_NOVECTOR`), so its resampling does not depend on the host's
# instruction set. Metadata is stripped (`keep=none`) after converting to
# sRGB, so nothing about the source file but its pixels reaches a variant.

const
  vipsThreads = "4"  ## Fixed, not the host's core count (see above).
  imageVariantRevision = "isonim-image-variants-1"
    ## Changes whenever the arguments below change, so cached variants made
    ## with other settings are never reused. The quality is part of each
    ## variant's key on its own (`saveOptions`).

type
  ImageVariantConfig* = object
    ## How a site's images are served.
    vipsPath*: string             ## The `vips` executable (absolute); needed
                                  ## only when a raster is given variants.
    widths*: seq[int]             ## Variant widths, in pixels.
    formats*: seq[ImageFormat]    ## Variant formats: `ifAvif`, `ifWebp`.
    maxSourceBytes*: int          ## A larger source is an error; 0: no limit.
    cacheDir*: string             ## Optional; variants are reused from here.
    avifQuality*, webpQuality*: int
                                  ## Encoder quality, 1-100 (libvips `Q`); 0:
                                  ## `defaultAvifQuality` / `defaultWebpQuality`.
    remoteOrigins*: seq[string]   ## Origins (`https://cdn.example.net`) whose
                                  ## images a page may show; an image on any
                                  ## other origin is an error.

  ImageReferenceKind* = enum
    irFile       ## a file of the site
    irExternal   ## a URL this build cannot read (another origin, `data:`)
    irMissing    ## a path of the site that names no file

  ImageReference* = object
    ## What an `<img src>` refers to, as the caller's resolver sees it.
    kind*: ImageReferenceKind
    name*: string      ## irFile: the source's site-relative name, which
                       ## names its variants (`assets/b/photo.png` gives
                       ## `assets/b/photo-480.<hash>.avif`).
    content*: string   ## irFile: the file's bytes.

  ImageSet* = tuple[info: ImageInfo, variants: seq[ImageVariant]]

  ResponsiveImages* = ref object
    ## One build's image processing: each source is measured and resized
    ## once, whichever pages show it. `files` collects the variant files
    ## the build writes, in the order they were first made.
    config: ImageVariantConfig
    urlFor: proc(path: string): string {.closure.}
    sets: Table[string, ImageSet]
    vipsIdentity: string
    files*: seq[tuple[path, content: string]]
    warnings*: seq[string]

proc newResponsiveImages*(config: ImageVariantConfig;
    urlFor: proc(path: string): string {.closure.}): ResponsiveImages =
  ## `urlFor` maps an output path (`assets/b/photo-480.<hash>.avif`) to the
  ## URL pages use for it (a site under a base path prefixes it).
  for format in config.formats:
    if format notin [ifAvif, ifWebp]:
      raise newException(ImageError, "image variants are written as avif or webp, not " & $format)
  for width in config.widths:
    if width <= 0: raise newException(ImageError, "an image width must be positive")
  var checked = config
  for (name, quality) in [("avif", config.avifQuality), ("webp", config.webpQuality)]:
    if quality notin 0 .. 100:
      raise newException(ImageError, "the " & name & " quality must be from 1 to 100, not " & $quality)
  if checked.avifQuality == 0: checked.avifQuality = defaultAvifQuality
  if checked.webpQuality == 0: checked.webpQuality = defaultWebpQuality
  checked.remoteOrigins = @[]
  for origin in config.remoteOrigins:
    let parsed =
      try: parseWebOrigin(origin)
      except ValueError as cause: raise newException(ImageError, "a remote image origin is " & cause.msg)
    if parsed notin checked.remoteOrigins: checked.remoteOrigins.add parsed
  ResponsiveImages(config: checked, urlFor: urlFor)

proc vipsExecutable(images: ResponsiveImages): string =
  let path = images.config.vipsPath
  if path.len == 0:
    raise newException(ImageError, "libvips (vips) is not configured; image variants need it")
  if not path.isAbsolute or not fileExists(path):
    raise newException(ImageError, "the vips executable must be an existing absolute path: " & path)
  path

proc runVips(images: ResponsiveImages; args: openArray[string]; work: string): string =
  let executable = vipsExecutable(images)
  var status: int
  try:
    let process = startProcess(executable, workingDir = work, args = args,
      options = {poStdErrToStdOut},
      env = newStringTable({"PATH": parentDir(executable), "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8", "TZ": "UTC", "HOME": work, "TMPDIR": work,
        "VIPS_CONCURRENCY": vipsThreads, "VIPS_NOVECTOR": "1"}))
    defer: process.close()
    result = process.outputStream.readAll()
    status = process.waitForExit()
  except OSError as cause:
    raise newException(ImageError, "vips could not run: " & cause.msg)
  if status != 0:
    raise newException(ImageError, "vips exited with status " & $status & ": " & result.strip())

proc identity(images: ResponsiveImages): string =
  ## The tool's identity for cache keys: its path and version report.
  if images.vipsIdentity.len == 0:
    let work = createTempDir("isonim-images-", "")
    defer: removeDir(work)
    images.vipsIdentity = vipsExecutable(images) & "\n" & runVips(images, ["--version"], work)
  images.vipsIdentity

proc saveOptions(images: ResponsiveImages; format: ImageFormat): string =
  ## libvips save options for a variant: quality, a fixed effort and no
  ## metadata (https://www.libvips.org/API/current/method.Image.heifsave.html,
  ## https://www.libvips.org/API/current/method.Image.webpsave.html). The
  ## string is part of the variant's cache key, so a new quality re-encodes.
  let quality = if format == ifAvif: images.config.avifQuality else: images.config.webpQuality
  "[Q=" & $quality & ",effort=4,keep=none]"

proc encodeVariant(images: ResponsiveImages; source: string; info: ImageInfo;
    width: int; format: ImageFormat): string =
  ## One variant's bytes, from the cache when an identical encode was kept.
  let options = saveOptions(images, format)
  let key = treeHashOf([("revision", imageVariantRevision), ("tool", images.identity),
    ("width", $width), ("format", $format & options), ("source", source)])
  let cached = if images.config.cacheDir.len == 0: ""
               else: images.config.cacheDir / key & "." & format.extension
  proc valid(content: string): bool =
    try:
      let made = readImageInfo(content)
      made.format == format and made.width == width
    except ImageError: false
  if cached.len > 0 and fileExists(cached):
    let content = readFile(cached)
    if valid(content): return content
    # A damaged entry is replaced, never served.
    removeFile(cached)
  let work = createTempDir("isonim-images-", "")
  defer: removeDir(work)
  let input = work / ("source." & info.format.extension)
  let output = work / ("variant." & format.extension)
  writeFile(input, source)
  discard runVips(images, ["thumbnail", input, output & options, $width,
    "--export-profile", "srgb"], work)
  if not fileExists(output): raise newException(ImageError, "vips wrote no variant")
  result = readFile(output)
  if not valid(result):
    raise newException(ImageError, "vips wrote a " & $format & " variant that is not " &
      $width & " pixels wide")
  if cached.len > 0:
    createDir(images.config.cacheDir)
    # Write beside the entry and rename, so a reader never sees half a file.
    let (file, temporary) = createTempFile("variant-", ".part", images.config.cacheDir)
    file.write(result)
    file.close()
    moveFile(temporary, cached)

proc variantName(name: string; width: int; format: ImageFormat; content: string): string =
  ## `assets/b/photo.png` at 480 as AVIF: `assets/b/photo-480.<hash>.avif`.
  ## Variants are fingerprinted assets, so a source outside `assets/` gets
  ## its variants under `assets/`.
  let base = if name.startsWith("assets/"): name else: "assets/" & name
  let (dir, stem, _) = splitFile(base)
  hashedAssetName(dir & "/" & stem & "-" & $width & "." & format.extension, content)
    .replace('\\', '/')

proc imageSet*(images: ResponsiveImages; name, content: string): ImageSet =
  ## Measure a source and make its variants (once per `name`). An SVG, and
  ## a raster with more than one frame, get no variants: resizing would
  ## rasterise the one and freeze the other.
  if images.sets.hasKey(name): return images.sets[name]
  let info = readImageInfo(content)
  result.info = info
  if info.format != ifSvg and info.format != ifGif and not info.animated:
    for format in images.config.formats:
      for width in variantWidths(info.width, images.config.widths):
        let bytes = encodeVariant(images, content, info, width, format)
        let made = readImageInfo(bytes)
        let path = variantName(name, width, format, bytes)
        images.files.add (path, bytes)
        result.variants.add ImageVariant(format: format, width: made.width,
          height: made.height, url: images.urlFor(path))
  images.sets[name] = result

proc remoteImageProblem(images: ResponsiveImages; src: string): string =
  ## Why an image source that names no file of the site may not be shown,
  ## or "" when it may: a `data:` URL, or an absolute `http`/`https` URL on
  ## an allowed origin. Everything else would either be blocked by a policy
  ## that names only those origins or depend on the page's own scheme.
  let value = src.strip
  if value.toLowerAscii.startsWith("data:"): return ""
  if value.startsWith("//"):
    return "is protocol-relative; write it with its scheme (https:)"
  let origin = webOrigin(value)
  if origin.len == 0:
    return "is not a file of the site, a data: URL or an http(s) URL"
  if origin notin images.config.remoteOrigins:
    return "is on " & origin & ", which is not an allowed remote image origin"

proc rewritePageImages*(images: ResponsiveImages; html, page: string;
    resolve: proc(src: string): ImageReference {.closure.}; sizes = ""): string =
  ## `html` (one built page, named `page` in errors) with every `<img>`
  ## served responsively (`responsiveImageHtml`).
  ##
  ## The page's content images, those inside its `<main>` element (every
  ## image when the page has none, see `mainContentRange`), get
  ## `decoding="async"`, and every one but the first `loading="lazy"`: the
  ## first is the likely Largest Contentful Paint element, which must not
  ## wait for layout (https://web.dev/articles/lcp-lazy-loading). Images
  ## outside the main content (a header logo) get neither, so they load as
  ## the author wrote them; an attribute the author set is always kept.
  ##
  ## Errors (`ImageError`): an image without an `alt` attribute (`alt=""`
  ## marks a decorative image and is accepted;
  ## https://html.spec.whatwg.org/multipage/images.html#alt), or with one
  ## of only whitespace; a source larger than `maxSourceBytes`; a site path
  ## that names no file; and an external image other than a `data:` URL or
  ## an `http`/`https` URL on one of `remoteOrigins`. An allowed external
  ## image keeps its markup, and a warning says it has no dimensions unless
  ## the author set both `width` and `height`.
  let content = mainContentRange(html)
  var contentIndex = 0
  rewriteImgTags(html, proc(tag: ImgTag; index: int): string =
    let src = tag.attr("src")
    if not tag.hasAttr("alt"):
      raise newException(ImageError, page & ": the image " & src &
        " has no alt attribute (alt=\"\" marks a decorative image)")
    if tag.attr("alt").len > 0 and tag.attr("alt").strip().len == 0:
      raise newException(ImageError, page & ": the image " & src &
        " has alt text of only whitespace (alt=\"\" marks a decorative image)")
    let inContent = tag.first >= content.first and tag.first < content.last
    let lazy = inContent and contentIndex > 0
    if inContent: inc contentIndex
    let reference = resolve(src)
    case reference.kind
    of irMissing:
      raise newException(ImageError, page & ": the image " & src & " is not a file of the site")
    of irExternal:
      let problem = images.remoteImageProblem(src)
      if problem.len > 0:
        raise newException(ImageError, page & ": the image " & src & " " & problem)
      # The warning is about layout shift: the browser reserves no space for
      # an image of unknown size
      # (https://web.dev/articles/optimize-cls#images-without-dimensions).
      # When the author set both dimensions there is nothing to warn about.
      if not (tag.hasAttr("width") and tag.hasAttr("height")):
        images.warnings.add page & ": the image " & src &
          " is not a file of the site, so it has no width, height or variants"
      responsiveImageHtml(tag, ImageInfo(), [], lazy = lazy, asyncDecoding = inContent)
    of irFile:
      let limit = images.config.maxSourceBytes
      if limit > 0 and reference.content.len > limit:
        raise newException(ImageError, page & ": the image " & src & " is " &
          $reference.content.len & " bytes, over the limit of " & $limit)
      let found =
        try: images.imageSet(reference.name, reference.content)
        except ImageError as cause:
          raise newException(ImageError, page & ": the image " & src & ": " & cause.msg)
      responsiveImageHtml(tag, found.info, found.variants, lazy = lazy, sizes = sizes,
        asyncDecoding = inContent))
