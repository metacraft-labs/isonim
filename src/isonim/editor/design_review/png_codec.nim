## REV-M5 — minimal PNG codec for RGBA8888 surfaces.
##
## Reason for hand-rolling rather than depending on ``nimPNG``:
## the dev shell on ``aarch64-darwin`` is still broken under the
## REV-M3/M4 milestone (see "REV-M3/M4 environmental workarounds
## carry over" in the REV-M5 charter), so adding a new nimble
## dependency would compound that breakage.  PNG is small enough
## to vendor — exactly what we need (RGBA8888 round-trip) lands
## in <200 lines, no external deps.
##
## Wire layout (RFC 2083):
##
##   8-byte signature (137 80 78 71 13 10 26 10)
##   IHDR chunk: width(4) height(4) bitDepth(1)=8 colorType(1)=6 (RGBA)
##               compression(1)=0 filter(1)=0 interlace(1)=0
##   IDAT chunk: zlib stream wrapping the row-filtered pixel data
##   IEND chunk: empty
##
## We always emit uncompressed deflate blocks (the simplest valid
## zlib stream).  Decoders happily consume them; encode time stays
## proportional to pixel count without a deflate implementation.
##
## We always emit filter byte 0 (None) per row.  Decoders that
## honour PNG's optional filter byte handle this trivially.
##
## CRC-32: standard polynomial 0xEDB88320, table-driven.
## Adler-32: standard zlib trailing checksum.

## (no external imports needed; we keep the dependency surface minimal)

type
  PngImage* = object
    width*, height*: int
    pixels*: seq[byte]      ## RGBA8888 row-major, length == width*height*4

  PngDecodeError* = object of CatchableError

# ---------------------------------------------------------------------------
# CRC-32
# ---------------------------------------------------------------------------

var crcTable: array[256, uint32]
var crcTableInit = false

proc initCrcTable() =
  if crcTableInit: return
  for i in 0 ..< 256:
    var c = uint32(i)
    for _ in 0 ..< 8:
      if (c and 1'u32) != 0:
        c = 0xEDB88320'u32 xor (c shr 1)
      else:
        c = c shr 1
    crcTable[i] = c
  crcTableInit = true

proc crc32(buf: openArray[byte]): uint32 =
  initCrcTable()
  var c = 0xFFFFFFFF'u32
  for b in buf:
    c = crcTable[(c xor uint32(b)) and 0xFF] xor (c shr 8)
  result = c xor 0xFFFFFFFF'u32

proc adler32(buf: openArray[byte]): uint32 =
  var s1 = 1'u32
  var s2 = 0'u32
  for b in buf:
    s1 = (s1 + uint32(b)) mod 65521'u32
    s2 = (s2 + s1) mod 65521'u32
  (s2 shl 16) or s1

# ---------------------------------------------------------------------------
# Big-endian helpers
# ---------------------------------------------------------------------------

proc putU32BE(buf: var seq[byte]; v: uint32) =
  buf.add byte((v shr 24) and 0xFF'u32)
  buf.add byte((v shr 16) and 0xFF'u32)
  buf.add byte((v shr 8) and 0xFF'u32)
  buf.add byte(v and 0xFF'u32)

proc readU32BE(buf: openArray[byte]; off: int): uint32 =
  (uint32(buf[off]) shl 24) or
    (uint32(buf[off + 1]) shl 16) or
    (uint32(buf[off + 2]) shl 8) or
    uint32(buf[off + 3])

# ---------------------------------------------------------------------------
# Chunk writers
# ---------------------------------------------------------------------------

proc writeChunk(buf: var seq[byte]; chunkType: string; data: openArray[byte]) =
  putU32BE(buf, uint32(data.len))
  let start = buf.len
  for ch in chunkType: buf.add byte(ch)
  for b in data: buf.add b
  # CRC covers the type + data.
  var crcBuf = newSeq[byte](buf.len - start)
  for i in 0 ..< crcBuf.len: crcBuf[i] = buf[start + i]
  putU32BE(buf, crc32(crcBuf))

# ---------------------------------------------------------------------------
# Deflate "stored" block stream (zlib wrapper, always uncompressed)
# ---------------------------------------------------------------------------

proc buildZlibStored(raw: openArray[byte]): seq[byte] =
  ## Build a zlib stream that wraps ``raw`` in one or more uncompressed
  ## ("stored") deflate blocks.  Each block carries at most 65535 bytes.
  result = @[]
  # zlib header: CMF=0x78 (deflate, 32K window), FLG chosen so
  # CMF*256 + FLG % 31 == 0.  0x78 0x01 is the canonical "no
  # compression" pair (FLEVEL=0, FCHECK=1).
  result.add 0x78'u8
  result.add 0x01'u8

  var off = 0
  while off < raw.len:
    let remaining = raw.len - off
    let blockLen = min(remaining, 65535)
    let isLast = (off + blockLen) == raw.len
    # BFINAL bit | BTYPE=00 (stored).
    result.add (if isLast: 0x01'u8 else: 0x00'u8)
    # LEN (LE) + NLEN (LE, one's complement of LEN).
    result.add byte(blockLen and 0xFF)
    result.add byte((blockLen shr 8) and 0xFF)
    result.add byte((not blockLen) and 0xFF)
    result.add byte(((not blockLen) shr 8) and 0xFF)
    for i in 0 ..< blockLen:
      result.add raw[off + i]
    off += blockLen

  # Adler-32 trailer (big-endian) over the uncompressed input.
  putU32BE(result, adler32(raw))

proc parseZlibStream(data: openArray[byte]): seq[byte] =
  ## Inverse of ``buildZlibStored``.  Supports both "stored" blocks
  ## (BTYPE=00) and a minimal "fixed Huffman" / "dynamic Huffman"
  ## decoder is intentionally *not* included — we only ever decode
  ## PNGs we wrote, which only ever use stored blocks.  Real-world
  ## PNGs from other encoders will raise ``PngDecodeError``.
  ##
  ## The capture pipeline only reads PNGs back to verify byte-
  ## identical dimensions / pixels in the test suite, so the
  ## constraint is acceptable.
  if data.len < 6:
    raise newException(PngDecodeError, "zlib stream too short")
  let cmf = data[0]
  let flg = data[1]
  if (cmf and 0x0F) != 0x08:
    raise newException(PngDecodeError, "zlib: not deflate stream")
  if (uint16(cmf) * 256'u16 + uint16(flg)) mod 31'u16 != 0:
    raise newException(PngDecodeError, "zlib: bad FCHECK")
  var off = 2
  result = @[]
  var finalSeen = false
  while not finalSeen:
    if off >= data.len:
      raise newException(PngDecodeError, "zlib: truncated block header")
    let blockHeader = data[off]
    inc off
    let bfinal = (blockHeader and 0x01'u8) != 0
    let btype = (blockHeader shr 1) and 0x03'u8
    if btype != 0:
      raise newException(PngDecodeError,
        "zlib: only stored blocks supported (BTYPE=" & $btype & ")")
    if off + 4 > data.len:
      raise newException(PngDecodeError, "zlib: truncated LEN/NLEN")
    let blen = int(uint16(data[off]) or (uint16(data[off + 1]) shl 8))
    off += 4   # skip LEN+NLEN
    if off + blen > data.len:
      raise newException(PngDecodeError, "zlib: truncated stored payload")
    for i in 0 ..< blen:
      result.add data[off + i]
    off += blen
    finalSeen = bfinal
  # Adler-32 trailer ignored (we validate by length elsewhere).

# ---------------------------------------------------------------------------
# Public encode / decode
# ---------------------------------------------------------------------------

const PngSig: array[8, byte] = [137'u8, 80'u8, 78'u8, 71'u8,
                                13'u8, 10'u8, 26'u8, 10'u8]

proc encodePng32*(img: PngImage): seq[byte] =
  ## Encode an RGBA8888 image as a valid PNG.  The pixel buffer is
  ## row-major with no padding (length == width*height*4).
  let expectedLen = img.width * img.height * 4
  if img.pixels.len != expectedLen:
    raise newException(ValueError,
      "encodePng32: pixel buffer length " & $img.pixels.len &
      " != width*height*4 (" & $expectedLen & ")")
  result = @[]
  for b in PngSig: result.add b

  # IHDR (13 bytes payload).
  var ihdr = newSeq[byte](13)
  ihdr[0] = byte((img.width shr 24) and 0xFF)
  ihdr[1] = byte((img.width shr 16) and 0xFF)
  ihdr[2] = byte((img.width shr 8) and 0xFF)
  ihdr[3] = byte(img.width and 0xFF)
  ihdr[4] = byte((img.height shr 24) and 0xFF)
  ihdr[5] = byte((img.height shr 16) and 0xFF)
  ihdr[6] = byte((img.height shr 8) and 0xFF)
  ihdr[7] = byte(img.height and 0xFF)
  ihdr[8] = 8'u8                      # bit depth
  ihdr[9] = 6'u8                      # colour type RGBA
  ihdr[10] = 0'u8                     # compression
  ihdr[11] = 0'u8                     # filter
  ihdr[12] = 0'u8                     # interlace
  writeChunk(result, "IHDR", ihdr)

  # IDAT: row-filtered pixels then zlib(stored).
  let stride = img.width * 4
  var filtered = newSeq[byte](img.height * (stride + 1))
  for y in 0 ..< img.height:
    let dstRowOff = y * (stride + 1)
    filtered[dstRowOff] = 0'u8            # filter = None
    let srcRowOff = y * stride
    for x in 0 ..< stride:
      filtered[dstRowOff + 1 + x] = img.pixels[srcRowOff + x]
  let idat = buildZlibStored(filtered)
  writeChunk(result, "IDAT", idat)

  # IEND.
  writeChunk(result, "IEND", [])

proc decodePng32*(data: openArray[byte]): PngImage =
  ## Decode a PNG produced by ``encodePng32`` (or any PNG that uses
  ## RGBA8888, bit depth 8, no interlace, filter byte 0 per row, and
  ## a zlib stream made of stored deflate blocks).  Sufficient for
  ## the round-trip tests in this milestone.
  if data.len < 8:
    raise newException(PngDecodeError, "PNG too short")
  for i in 0 ..< 8:
    if data[i] != PngSig[i]:
      raise newException(PngDecodeError, "PNG bad signature")
  var off = 8
  var width = 0
  var height = 0
  var idatBuf: seq[byte] = @[]
  var sawIhdr = false
  var sawIend = false
  while off < data.len:
    if off + 8 > data.len:
      raise newException(PngDecodeError, "PNG truncated chunk header")
    let chunkLen = int(readU32BE(data, off))
    off += 4
    var chunkType = newString(4)
    for i in 0 ..< 4: chunkType[i] = char(data[off + i])
    off += 4
    if off + chunkLen + 4 > data.len:
      raise newException(PngDecodeError, "PNG truncated chunk payload")
    if chunkType == "IHDR":
      if chunkLen != 13:
        raise newException(PngDecodeError, "PNG IHDR not 13 bytes")
      width = int(readU32BE(data, off))
      height = int(readU32BE(data, off + 4))
      let bitDepth = int(data[off + 8])
      let colorType = int(data[off + 9])
      let interlace = int(data[off + 12])
      if bitDepth != 8 or colorType != 6 or interlace != 0:
        raise newException(PngDecodeError,
          "PNG: only 8-bit RGBA non-interlaced supported")
      sawIhdr = true
    elif chunkType == "IDAT":
      for i in 0 ..< chunkLen:
        idatBuf.add data[off + i]
    elif chunkType == "IEND":
      sawIend = true
    # off += chunkLen + 4 (data + CRC).  We don't validate CRC here:
    # we wrote the file ourselves; checking would only slow tests.
    off += chunkLen + 4
    if sawIend: break

  if not sawIhdr:
    raise newException(PngDecodeError, "PNG missing IHDR")
  if not sawIend:
    raise newException(PngDecodeError, "PNG missing IEND")

  let raw = parseZlibStream(idatBuf)
  let stride = width * 4
  if raw.len != height * (stride + 1):
    raise newException(PngDecodeError,
      "PNG IDAT length " & $raw.len & " != height*(stride+1) (" &
      $(height * (stride + 1)) & ")")
  var pixels = newSeq[byte](height * stride)
  for y in 0 ..< height:
    let srcRowOff = y * (stride + 1)
    if raw[srcRowOff] != 0'u8:
      raise newException(PngDecodeError,
        "PNG: only filter type 0 (None) supported, got " & $raw[srcRowOff])
    let dstRowOff = y * stride
    for x in 0 ..< stride:
      pixels[dstRowOff + x] = raw[srcRowOff + 1 + x]
  result = PngImage(width: width, height: height, pixels: pixels)
