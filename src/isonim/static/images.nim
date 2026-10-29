## isonim/static/images -- what a static site needs to know about its
## images, and the markup that serves them responsively:
##
## - `readImageInfo` reads a raster's format and pixel size from its header
##   (PNG, JPEG with its Exif orientation, GIF, WebP and AVIF), and
##   `svgSize` the size an SVG declares, without decoding any pixels;
## - `variantWidths` picks the widths a source is resized to, never
##   enlarging it;
## - `imgTags`, `rewriteImgTags` and `responsiveImageHtml` find the `<img>`
##   elements of a built page and turn one into a `<picture>` with one
##   `<source srcset>` per format, `width`, `height`, `loading` and
##   `decoding`; `mainContentRange` finds the page's main content.
##
## Producing the variant files needs an image tool and lives in
## `isonim/static/assets` (`ResponsiveImages`, C only). This module is pure
## string work, identical on `nim c` and `nim js`; integers are assembled
## with arithmetic rather than shifts so 32-bit header fields stay positive
## on the JavaScript backend.
##
## Formats are read from their specifications:
## PNG https://www.w3.org/TR/png-3/#11IHDR;
## JPEG ITU-T T.81 annex B (https://www.w3.org/Graphics/JPEG/itu-t81.pdf)
## with the Exif 2.3 orientation tag (CIPA DC-008);
## GIF https://www.w3.org/Graphics/GIF/spec-gif89a.txt;
## WebP https://developers.google.com/speed/webp/docs/riff_container;
## AVIF https://aomediacodec.github.io/av1-avif/ over the ISO base media
## file format boxes (ISO/IEC 14496-12 `meta`, `pitm`, `iprp`, `ipco`,
## `ipma`; ISO/IEC 23008-12 `ispe` and `irot`).
## Responsive images: https://html.spec.whatwg.org/multipage/images.html.

import std/strutils
import ../ssr/escape

type
  ImageError* = object of ValueError
    ## A file that is not an image of a supported format, or whose header
    ## is truncated or inconsistent.

  ImageFormat* = enum
    ## The formats this module reads. Variants are written as AVIF or WebP.
    ifPng = "png", ifJpeg = "jpeg", ifGif = "gif", ifWebp = "webp",
    ifAvif = "avif", ifSvg = "svg"

  ImageInfo* = object
    ## A source's format and its displayed size in CSS pixels at density 1.
    ## For a JPEG whose Exif orientation turns it a quarter turn, `width`
    ## and `height` are the turned (displayed) size. An SVG that declares
    ## no size has 0 for both.
    format*: ImageFormat
    width*, height*: int
    animated*: bool  ## more than one frame (a GIF, an animated WebP, an AVIF sequence)

  ImageVariant* = object
    ## One resized copy of a source, as a page references it.
    format*: ImageFormat
    width*, height*: int
    url*: string

  ImgAttribute* = tuple[name, value: string]
    ## An attribute of an `<img>` element: the name in lower case, the value
    ## with its character references decoded.

  ImgTag* = object
    ## One `<img>` start tag of an HTML document: its attributes in source
    ## order and the byte range `first ..< last` the tag occupies.
    attributes*: seq[ImgAttribute]
    first*, last*: int

const
  defaultAvifQuality* = 50
    ## AVIF variant quality when a site sets none (libvips `Q`, 1-100). AVIF
    ## keeps detail at a lower Q than WebP, so its default is lower.
  defaultWebpQuality* = 75
    ## WebP variant quality when a site sets none, the default of Hugo and
    ## libwebp.

proc imageError(message: string) {.noreturn.} =
  raise newException(ImageError, message)

proc mediaType*(format: ImageFormat): string =
  ## The IANA media type of `format` (for `<source type>`).
  case format
  of ifPng: "image/png"
  of ifJpeg: "image/jpeg"
  of ifGif: "image/gif"
  of ifWebp: "image/webp"
  of ifAvif: "image/avif"
  of ifSvg: "image/svg+xml"

proc extension*(format: ImageFormat): string =
  ## The file extension written for a variant of `format`, without the dot.
  case format
  of ifJpeg: "jpg"
  else: $format

proc parseImageFormat*(name: string): ImageFormat =
  ## A format named in configuration (`"avif"`, `"webp"`, ...).
  for format in ImageFormat:
    if $format == name.toLowerAscii: return format
  imageError("unknown image format: " & name)

# --- Byte readers -----------------------------------------------------------

proc byteAt(data: string; i: int): int =
  if i < 0 or i >= data.len: imageError("truncated image header")
  ord(data[i])

proc u16be(data: string; i: int): int = byteAt(data, i) * 256 + byteAt(data, i + 1)
proc u16le(data: string; i: int): int = byteAt(data, i) + byteAt(data, i + 1) * 256
proc u24le(data: string; i: int): int =
  byteAt(data, i) + byteAt(data, i + 1) * 256 + byteAt(data, i + 2) * 65536
proc u32be(data: string; i: int): int =
  ((byteAt(data, i) * 256 + byteAt(data, i + 1)) * 256 + byteAt(data, i + 2)) * 256 +
    byteAt(data, i + 3)
proc u32le(data: string; i: int): int =
  ((byteAt(data, i + 3) * 256 + byteAt(data, i + 2)) * 256 + byteAt(data, i + 1)) * 256 +
    byteAt(data, i)

proc hasPrefix(data: string; at: int; prefix: string): bool =
  at >= 0 and at + prefix.len <= data.len and data[at ..< at + prefix.len] == prefix

proc checkedSize(format: ImageFormat; width, height: int): ImageInfo =
  if width <= 0 or height <= 0: imageError("an image of zero size")
  ImageInfo(format: format, width: width, height: height)

# --- PNG, GIF, WebP ---------------------------------------------------------

proc pngInfo(data: string): ImageInfo =
  # The first chunk is IHDR: length, type, then width and height.
  if not data.hasPrefix(12, "IHDR"): imageError("a PNG must start with IHDR")
  checkedSize(ifPng, u32be(data, 16), u32be(data, 20))

proc skipSubBlocks(data: string; at: int): int =
  ## Past a GIF data sub-block sequence (length-prefixed, ended by 0).
  result = at
  while true:
    let size = byteAt(data, result)
    inc result
    if size == 0: return
    result += size

proc gifInfo(data: string): ImageInfo =
  # The logical screen descriptor follows the six-byte signature; a global
  # colour table follows it when its flag is set.
  result = checkedSize(ifGif, u16le(data, 6), u16le(data, 8))
  let flags = byteAt(data, 10)
  var i = 13
  if flags >= 128: i += 3 * (1 shl (flags mod 8 + 1))
  var frames = 0
  while i < data.len:
    case byteAt(data, i)
    of 0x2c:  # image descriptor, optional local colour table, LZW data
      inc frames
      let local = byteAt(data, i + 9)
      i += 10
      if local >= 128: i += 3 * (1 shl (local mod 8 + 1))
      i = skipSubBlocks(data, i + 1)
    of 0x21: i = skipSubBlocks(data, i + 2)  # extension: label, sub-blocks
    of 0x3b: break  # trailer
    else: imageError("a damaged GIF block")
  if frames == 0: imageError("a GIF without an image")
  result.animated = frames > 1

proc webpInfo(data: string): ImageInfo =
  # RIFF header (12 bytes), then the first chunk's FourCC at 12, its data at 20.
  if data.hasPrefix(12, "VP8 "):
    # A lossy key frame: three tag bytes, the start code, 14-bit sizes.
    if not data.hasPrefix(23, "\x9d\x01\x2a"): imageError("a lossy WebP without a key frame")
    result = checkedSize(ifWebp, u16le(data, 26) mod 16384, u16le(data, 28) mod 16384)
  elif data.hasPrefix(12, "VP8L"):
    # The lossless signature byte, then width-1 and height-1 in 14 bits each.
    if byteAt(data, 20) != 0x2f: imageError("a lossless WebP without its signature")
    let bits = u32le(data, 21)
    result = checkedSize(ifWebp, bits mod 16384 + 1, (bits div 16384) mod 16384 + 1)
  elif data.hasPrefix(12, "VP8X"):
    # Extended format: flags (bit 1: animation) and reserved bytes, then
    # the 24-bit canvas size.
    result = checkedSize(ifWebp, u24le(data, 24) + 1, u24le(data, 27) + 1)
    result.animated = (byteAt(data, 20) div 2) mod 2 == 1
  else:
    imageError("a WebP with an unknown first chunk")

# --- JPEG -------------------------------------------------------------------

proc exifOrientation(data: string; start, stop: int): int =
  ## The orientation tag (0x0112) of IFD0 in an APP1 Exif payload
  ## (`start` is the TIFF header), or 1 when there is none.
  result = 1
  if stop - start < 8: return
  let little = data.hasPrefix(start, "II")
  if not little and not data.hasPrefix(start, "MM"): return
  proc u16(i: int): int = (if little: u16le(data, i) else: u16be(data, i))
  proc u32(i: int): int = (if little: u32le(data, i) else: u32be(data, i))
  if u16(start + 2) != 42: return
  let ifd = start + u32(start + 4)
  if ifd + 2 > stop: return
  let count = u16(ifd)
  for n in 0 ..< count:
    let entry = ifd + 2 + n * 12
    if entry + 12 > stop: return
    if u16(entry) == 0x0112:
      let value = u16(entry + 8)
      if value in 1 .. 8: return value
      return 1

proc jpegInfo(data: string): ImageInfo =
  var i = 2
  var orientation = 1
  while i < data.len:
    if byteAt(data, i) != 0xff: imageError("a JPEG marker was expected")
    var marker = byteAt(data, i + 1)
    var at = i + 1
    while marker == 0xff:  # fill bytes before a marker
      inc at
      marker = byteAt(data, at + 1)
    i = at + 1
    if marker == 0x01 or marker in 0xd0 .. 0xd8: continue  # markers without a length
    if marker in [0xd9, 0xda]: break  # end of image or start of scan
    let length = u16be(data, i)
    if length < 2: imageError("a JPEG segment with an invalid length")
    let payload = i + 2
    if marker == 0xe1 and data.hasPrefix(payload, "Exif\0\0"):
      orientation = exifOrientation(data, payload + 6, min(data.len, i + length))
    elif marker in 0xc0 .. 0xcf and marker notin [0xc4, 0xc8, 0xcc]:
      # Frame header: precision, then height and width.
      let height = u16be(data, payload + 1)
      let width = u16be(data, payload + 3)
      # Orientations 5 to 8 turn the image a quarter turn: browsers show it
      # (and size it) turned, as `image-orientation: from-image` requires.
      return if orientation >= 5: checkedSize(ifJpeg, height, width)
             else: checkedSize(ifJpeg, width, height)
    i += length
  imageError("a JPEG without a frame header")

# --- AVIF -------------------------------------------------------------------

type BmffBox = tuple[kind: string, body, stop: int]

proc boxes(data: string; first, stop: int): seq[BmffBox] =
  ## The boxes in `first ..< stop`: their type, where their body starts and
  ## where they end. A box that does not fit its parent is an error.
  var i = first
  while i + 8 <= stop:
    var size = u32be(data, i)
    let kind = data[i + 4 ..< i + 8]
    var body = i + 8
    if size == 1:
      # A 64-bit size; anything that does not fit an image header is refused.
      if u32be(data, i + 8) != 0: imageError("an AVIF box too large to be a header")
      size = u32be(data, i + 12)
      body = i + 16
    elif size == 0:
      size = stop - i
    if size < body - i or i + size > stop: imageError("an AVIF box overruns its parent")
    result.add (kind, body, i + size)
    i += size

proc find(list: seq[BmffBox]; kind: string): int =
  for n, box in list:
    if box.kind == kind: return n
  -1

proc avifInfo(data: string): ImageInfo =
  let top = boxes(data, 0, data.len)
  let meta = top.find("meta")
  if meta < 0: imageError("an AVIF without a meta box")
  # `meta` is a full box: version and flags precede its children.
  let children = boxes(data, top[meta].body + 4, top[meta].stop)
  let pitm = children.find("pitm")
  let iprp = children.find("iprp")
  if pitm < 0 or iprp < 0: imageError("an AVIF without a primary item or its properties")
  let primary =
    if byteAt(data, children[pitm].body) == 0: u16be(data, children[pitm].body + 4)
    else: u32be(data, children[pitm].body + 4)
  let props = boxes(data, children[iprp].body, children[iprp].stop)
  let ipco = props.find("ipco")
  if ipco < 0: imageError("an AVIF without a property container")
  let properties = boxes(data, props[ipco].body, props[ipco].stop)
  var width, height, turns = -1
  for association in props:
    if association.kind != "ipma": continue
    let version = byteAt(data, association.body)
    let wideIndex = byteAt(data, association.body + 3) mod 2 == 1
    var i = association.body + 4
    let count = u32be(data, i)
    i += 4
    for _ in 0 ..< count:
      let item = if version < 1: u16be(data, i) else: u32be(data, i)
      i += (if version < 1: 2 else: 4)
      let links = byteAt(data, i)
      inc i
      for _ in 0 ..< links:
        let index =
          if wideIndex: u16be(data, i) mod 32768
          else: byteAt(data, i) mod 128
        i += (if wideIndex: 2 else: 1)
        if item != primary or index == 0: continue
        if index > properties.len: imageError("an AVIF property index out of range")
        let property = properties[index - 1]
        if property.kind == "ispe":
          width = u32be(data, property.body + 4)
          height = u32be(data, property.body + 8)
        elif property.kind == "irot":
          turns = byteAt(data, property.body) mod 4
  if width < 0: imageError("an AVIF primary item without a size")
  result = if turns in [1, 3]: checkedSize(ifAvif, height, width)
           else: checkedSize(ifAvif, width, height)
  # An image sequence carries the `avis` brand (AVIF §7).
  result.animated = data.hasPrefix(8, "avis")

# --- SVG --------------------------------------------------------------------

proc svgLength(value: string): float =
  ## A length in user units or `px`; anything else (`%`, `em`) is -1.
  var text = value.strip()
  if text.endsWith("px"): text.setLen(text.len - 2)
  try: result = parseFloat(text)
  except ValueError: return -1
  if result <= 0: return -1

proc svgSize*(content: string): ImageInfo =
  ## The size an SVG document's root declares: `width` and `height` in user
  ## units or pixels, else the `viewBox` (one declared length scales the
  ## other by the `viewBox` ratio). 0 by 0 when it declares neither. Sizes
  ## are rounded to whole pixels.
  result.format = ifSvg
  var at = 0
  # Skip the XML declaration, comments, processing instructions, a doctype.
  while true:
    at = content.find('<', at)
    if at < 0: imageError("not an SVG document")
    if content.hasPrefix(at, "<?") or content.hasPrefix(at, "<!"):
      let close = if content.hasPrefix(at, "<!--"): content.find("-->", at) else: content.find('>', at)
      if close < 0: imageError("not an SVG document")
      at = close + 1
    else: break
  if not content.hasPrefix(at, "<svg") or content.len <= at + 4 or
      content[at + 4] notin {' ', '\t', '\n', '\r', '>', '/'}:
    imageError("the document root is not <svg>")
  let close = content.find('>', at)
  if close < 0: imageError("an unterminated <svg> tag")
  let tag = content[at ..< close]
  proc attribute(name: string): string =
    var i = 0
    while true:
      i = tag.find(name & "=", i)
      if i < 0: return ""
      if i > 0 and tag[i - 1] in {' ', '\t', '\n', '\r'}:
        let quote = tag[i + name.len + 1]
        if quote in {'"', '\''}:
          let stop = tag.find(quote, i + name.len + 2)
          if stop > 0: return tag[i + name.len + 2 ..< stop]
      i += name.len
  let width = svgLength(attribute("width"))
  let height = svgLength(attribute("height"))
  var boxWidth, boxHeight = -1.0
  let box = attribute("viewBox").replace(',', ' ').splitWhitespace()
  if box.len == 4:
    try:
      boxWidth = parseFloat(box[2])
      boxHeight = parseFloat(box[3])
    except ValueError: discard
  if boxWidth <= 0 or boxHeight <= 0: boxWidth = -1
  var w, h: float
  if width > 0 and height > 0: (w, h) = (width, height)
  elif width > 0 and boxWidth > 0: (w, h) = (width, width * boxHeight / boxWidth)
  elif height > 0 and boxWidth > 0: (w, h) = (height * boxWidth / boxHeight, height)
  elif boxWidth > 0: (w, h) = (boxWidth, boxHeight)
  else: return
  result.width = max(1, int(w + 0.5))
  result.height = max(1, int(h + 0.5))

# --- Dispatch ---------------------------------------------------------------

proc readImageInfo*(content: string): ImageInfo =
  ## The format and displayed size of an image file, from its header.
  ## Raises `ImageError` for an unsupported or damaged file. An SVG is
  ## recognised by its root element (after an optional XML declaration).
  if content.hasPrefix(0, "\x89PNG\r\n\x1a\n"): pngInfo(content)
  elif content.hasPrefix(0, "\xff\xd8\xff"): jpegInfo(content)
  elif content.hasPrefix(0, "GIF87a") or content.hasPrefix(0, "GIF89a"): gifInfo(content)
  elif content.hasPrefix(0, "RIFF") and content.hasPrefix(8, "WEBP"): webpInfo(content)
  elif content.hasPrefix(4, "ftyp") and (content.hasPrefix(8, "avif") or
      content.hasPrefix(8, "avis") or "avif" in content[8 ..< min(content.len, u32be(content, 0))]):
    avifInfo(content)
  elif content.strip(trailing = false).startsWith("<"): svgSize(content)
  else: imageError("not a PNG, JPEG, GIF, WebP, AVIF or SVG image")

proc variantWidths*(sourceWidth: int; widths: openArray[int]): seq[int] =
  ## The widths a source of `sourceWidth` pixels is resized to: each
  ## configured width smaller than the source, plus the source's own width
  ## when a configured width reaches it, so the largest variant is never an
  ## enlargement and never smaller than both the source and the largest
  ## configured width. Ascending, without duplicates.
  var reaches = false
  for width in widths:
    if width <= 0: imageError("an image width must be positive")
    if width >= sourceWidth: reaches = true
    elif width notin result: result.add width
  if reaches and sourceWidth notin result: result.add sourceWidth
  for i in 1 ..< result.len:  # insertion sort: the list is a handful long
    var j = i
    while j > 0 and result[j - 1] > result[j]:
      swap(result[j - 1], result[j])
      dec j

proc srcsetValue*(variants: openArray[ImageVariant]): string =
  ## `url 480w, url 960w`: a width-descriptor `srcset` in the given order.
  for variant in variants:
    if result.len > 0: result.add ", "
    result.add variant.url & " " & $variant.width & "w"

# --- <img> elements ---------------------------------------------------------

proc decodeReferences(value: string): string =
  ## Character references in an attribute value: the named ones the IsoNim
  ## escaper writes and numeric ones; anything else stays as written.
  var i = 0
  while i < value.len:
    if value[i] == '&':
      let semi = value.find(';', i)
      if semi > i and semi - i <= 10:
        let name = value[i + 1 ..< semi]
        var decoded = ""
        case name
        of "amp": decoded = "&"
        of "lt": decoded = "<"
        of "gt": decoded = ">"
        of "quot": decoded = "\""
        of "apos": decoded = "'"
        else:
          if name.len > 1 and name[0] == '#':
            try:
              let code = if name[1] in {'x', 'X'}: parseHexInt(name[2 .. ^1]) else: parseInt(name[1 .. ^1])
              if code in 1 .. 127: decoded = $chr(code)
            except ValueError: discard
        if decoded.len > 0:
          result.add decoded
          i = semi + 1
          continue
    result.add value[i]
    inc i

const tagSpace = {' ', '\t', '\n', '\r', '\f'}

proc parseStartTag(html: string; first: int): ImgTag =
  ## The attributes of the start tag at `first` (just past its name).
  result.first = first
  var i = first
  while i < html.len and html[i] notin tagSpace + {'/', '>'}: inc i
  while i < html.len:
    while i < html.len and html[i] in tagSpace + {'/'}: inc i
    if i >= html.len: break
    if html[i] == '>':
      result.last = i + 1
      return
    let nameStart = i
    while i < html.len and html[i] notin tagSpace + {'/', '>', '='}: inc i
    let name = html[nameStart ..< i].toLowerAscii
    while i < html.len and html[i] in tagSpace: inc i
    var value = ""
    if i < html.len and html[i] == '=':
      inc i
      while i < html.len and html[i] in tagSpace: inc i
      if i < html.len and html[i] in {'"', '\''}:
        let quote = html[i]
        let stop = html.find(quote, i + 1)
        if stop < 0: break
        value = html[i + 1 ..< stop]
        i = stop + 1
      else:
        let start = i
        while i < html.len and html[i] notin tagSpace + {'>'}: inc i
        value = html[start ..< i]
    result.attributes.add (name, decodeReferences(value))
  raise newException(ImageError, "an unterminated <img> tag")

proc imgTags*(html: string): seq[ImgTag] =
  ## Every `<img>` start tag of `html`, in document order. Comments and the
  ## raw-text contents of `script`, `style`, `textarea` and `title` are not
  ## markup, so an `<img` inside them is not an element and is skipped.
  let lower = html.toLowerAscii
  var i = 0
  while true:
    i = html.find('<', i)
    if i < 0 or i + 1 >= html.len: return
    if html.hasPrefix(i, "<!--"):
      let close = html.find("-->", i + 4)
      if close < 0: return
      i = close + 3
      continue
    var j = i + 1
    while j < html.len and html[j] in Letters: inc j
    let name = html[i + 1 ..< j].toLowerAscii
    if j < html.len and html[j] notin tagSpace + {'/', '>'}:
      inc i
      continue
    if name == "img":
      let tag = parseStartTag(html, i)
      result.add tag
      i = tag.last
    elif name in ["script", "style", "textarea", "title"]:
      let close = lower.find("</" & name, j)
      if close < 0: return
      i = close + 2
    else:
      i = j

proc mainContentRange*(html: string): tuple[first, last: int] =
  ## The byte range `first ..< last` of the content of `html`'s `<main>`
  ## element, the page's dominant content
  ## (https://html.spec.whatwg.org/multipage/grouping-content.html#the-main-element),
  ## or the whole document when it has none. Comments and raw text are
  ## skipped as `imgTags` skips them. A page has at most one visible
  ## `<main>`; the first one counts, up to its end tag (or the document's
  ## end when that is missing).
  result = (0, html.len)
  let lower = html.toLowerAscii
  var opened = false
  var i = 0
  while true:
    i = html.find('<', i)
    if i < 0 or i + 1 >= html.len: return
    if html.hasPrefix(i, "<!--"):
      let close = html.find("-->", i + 4)
      if close < 0: return
      i = close + 3
      continue
    let closing = html[i + 1] == '/'
    var j = i + 1 + ord(closing)
    let nameStart = j
    while j < html.len and html[j] in Letters: inc j
    let name = lower[nameStart ..< j]
    if j < html.len and html[j] notin tagSpace + {'/', '>'}:
      inc i
      continue
    if name == "main" and not closing and not opened:
      let close = html.find('>', j)
      if close < 0: return
      result = (close + 1, html.len)
      opened = true
      i = close + 1
    elif name == "main" and closing and opened:
      result.last = i
      return
    elif name in ["script", "style", "textarea", "title"] and not closing:
      let close = lower.find("</" & name, j)
      if close < 0: return
      i = close + 2
    else:
      i = j

proc attr*(tag: ImgTag; name: string): string =
  ## The decoded value of attribute `name`, or "".
  for attribute in tag.attributes:
    if attribute.name == name: return attribute.value

proc hasAttr*(tag: ImgTag; name: string): bool =
  for attribute in tag.attributes:
    if attribute.name == name: return true

proc setAttr*(tag: var ImgTag; name, value: string) =
  ## Replace attribute `name` in place, or append it.
  for attribute in tag.attributes.mitems:
    if attribute.name == name:
      attribute.value = value
      return
  tag.attributes.add (name, value)

proc renderImgTag*(tag: ImgTag): string =
  ## The `<img>` start tag, every value escaped.
  result = "<img"
  for (name, value) in tag.attributes:
    result.add " " & name & "=\"" & escapeAttr(value) & "\""
  result.add ">"

proc rewriteImgTags*(html: string;
    transform: proc(tag: ImgTag; index: int): string {.closure.}): string =
  ## `html` with each `<img>` tag replaced by `transform(tag, index)`, where
  ## `index` counts the document's images from 0.
  var last = 0
  for index, tag in imgTags(html):
    result.add html[last ..< tag.first]
    result.add transform(tag, index)
    last = tag.last
  result.add html[last .. ^1]

proc parseDimension(value: string): int =
  ## A non-negative integer attribute value (`width="480"`), or -1.
  let text = value.strip()
  if text.len == 0: return -1
  for c in text:
    if c notin Digits: return -1
  try: parseInt(text) except ValueError: -1

proc responsiveImageHtml*(tag: ImgTag; info: ImageInfo;
    variants: openArray[ImageVariant]; lazy: bool; sizes = "";
    asyncDecoding = false): string =
  ## The element that replaces `tag`: the `<img>` with `width` and `height`
  ## (the author's own when both are given, one given scales the other by
  ## the source's ratio, otherwise the source's size), `loading="lazy"`
  ## when `lazy` and `decoding="async"` when `asyncDecoding`, each only when
  ## the author did not set that attribute; wrapped, when there are
  ## variants and the author wrote no `srcset`, in a `<picture>` with one
  ## `<source>` per format in the order the variants first name it. `sizes`
  ## defaults to the source's width capped by the viewport
  ## (`(min-width: Wpx) Wpx, 100vw`), which is how an image that is never
  ## enlarged past its own size is laid out. An `info` without a size (an
  ## SVG that declares none) adds no dimensions.
  var img = tag
  if info.width > 0 and info.height > 0:
    let width = parseDimension(tag.attr("width"))
    let height = parseDimension(tag.attr("height"))
    if width > 0 and height > 0: discard
    elif width > 0:
      img.setAttr("height", $max(1, int(width.float * info.height.float / info.width.float + 0.5)))
    elif height > 0:
      img.setAttr("width", $max(1, int(height.float * info.width.float / info.height.float + 0.5)))
    else:
      img.setAttr("width", $info.width)
      img.setAttr("height", $info.height)
  if lazy and not img.hasAttr("loading"): img.setAttr("loading", "lazy")
  if asyncDecoding and not img.hasAttr("decoding"): img.setAttr("decoding", "async")
  if variants.len == 0 or tag.hasAttr("srcset"): return renderImgTag(img)
  let sizesValue =
    if sizes.len > 0: sizes
    elif tag.hasAttr("sizes"): tag.attr("sizes")
    else: "(min-width: " & $info.width & "px) " & $info.width & "px, 100vw"
  var formats: seq[ImageFormat]
  for variant in variants:
    if variant.format notin formats: formats.add variant.format
  result = "<picture>"
  for format in formats:
    var group: seq[ImageVariant]
    for variant in variants:
      if variant.format == format: group.add variant
    result.add "<source type=\"" & mediaType(format) & "\" srcset=\"" &
      escapeAttr(srcsetValue(group)) & "\" sizes=\"" & escapeAttr(sizesValue) & "\">"
  result.add renderImgTag(img) & "</picture>"
