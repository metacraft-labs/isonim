## Headless HTML class-token extraction for current compiled preview relevance.
## Uses the standard library single-codepoint entity table; the supplementary
## WHATWG names below cover its missing values and ten differing mappings.
## They are data, not a second renderer or browser dependency.
import std/[htmlparser, strutils, tables, sequtils]
from std/unicode import Rune, toUTF8

const HtmlSpace = {' ', '\t', '\n', '\r', '\f'}
const LegacyEntityNames = "AElig AMP Aacute Acirc Agrave Aring Atilde Auml COPY Ccedil ETH Eacute Ecirc Egrave Euml GT Iacute Icirc Igrave Iuml LT Ntilde Oacute Ocirc Ograve Oslash Otilde Ouml QUOT REG THORN Uacute Ucirc Ugrave Uuml Yacute aacute acirc acute aelig agrave amp aring atilde auml brvbar ccedil cedil cent copy curren deg divide eacute ecirc egrave eth euml frac12 frac14 frac34 gt iacute icirc iexcl igrave iquest iuml laquo lt macr micro middot nbsp not ntilde oacute ocirc ograve ordf ordm oslash otilde ouml para plusmn pound quot raquo reg sect shy sup1 sup2 sup3 szlig thorn times uacute ucirc ugrave uml uuml yacute yen yuml".split(' ')

proc namedEntity(name: string): string =
  case name
  of "NotEqualTilde": "≂̸"
  of "NotGreaterFullEqual": "≧̸"
  of "NotGreaterGreater": "≫̸"
  of "NotGreaterSlantEqual": "⩾̸"
  of "NotHumpDownHump": "≎̸"
  of "NotHumpEqual": "≏̸"
  of "NotLeftTriangleBar": "⧏̸"
  of "NotLessLess": "≪̸"
  of "NotLessSlantEqual": "⩽̸"
  of "NotNestedGreaterGreater": "⪢̸"
  of "NotNestedLessLess": "⪡̸"
  of "NotPrecedesEqual": "⪯̸"
  of "NotRightTriangleBar": "⧐̸"
  of "NotSquareSubset": "⊏̸"
  of "NotSquareSuperset": "⊐̸"
  of "NotSubset": "⊂⃒"
  of "NotSucceedsEqual": "⪰̸"
  of "NotSucceedsTilde": "≿̸"
  of "NotSuperset": "⊃⃒"
  of "ThickSpace": "  "
  of "acE": "∾̳"
  of "bne": "=⃥"
  of "bnequiv": "≡⃥"
  of "bsolhsub": "⟈"
  of "caps": "∩︀"
  of "cups": "∪︀"
  of "fjlig": "fj"
  of "gesl": "⋛︀"
  of "gvertneqq": "≩︀"
  of "gvnE": "≩︀"
  of "lates": "⪭︀"
  of "lesg": "⋚︀"
  of "lvertneqq": "≨︀"
  of "lvnE": "≨︀"
  of "nGg": "⋙̸"
  of "nGt": "≫⃒"
  of "nGtv": "≫̸"
  of "nLl": "⋘̸"
  of "nLt": "≪⃒"
  of "nLtv": "≪̸"
  of "nang": "∠⃒"
  of "napE": "⩰̸"
  of "napid": "≋̸"
  of "nbump": "≎̸"
  of "nbumpe": "≏̸"
  of "ncongdot": "⩭̸"
  of "nedot": "≐̸"
  of "nesim": "≂̸"
  of "ngE": "≧̸"
  of "ngeqq": "≧̸"
  of "ngeqslant": "⩾̸"
  of "nges": "⩾̸"
  of "nlE": "≦̸"
  of "nleqq": "≦̸"
  of "nleqslant": "⩽̸"
  of "nles": "⩽̸"
  of "notinE": "⋹̸"
  of "notindot": "⋵̸"
  of "nparsl": "⫽⃥"
  of "npart": "∂̸"
  of "npre": "⪯̸"
  of "npreceq": "⪯̸"
  of "nrarrc": "⤳̸"
  of "nrarrw": "↝̸"
  of "nsce": "⪰̸"
  of "nsubE": "⫅̸"
  of "nsubset": "⊂⃒"
  of "nsubseteqq": "⫅̸"
  of "nsucceq": "⪰̸"
  of "nsupE": "⫆̸"
  of "nsupset": "⊃⃒"
  of "nsupseteqq": "⫆̸"
  of "nvap": "≍⃒"
  of "nvge": "≥⃒"
  of "nvgt": ">⃒"
  of "nvle": "≤⃒"
  of "nvlt": "<⃒"
  of "nvltrie": "⊴⃒"
  of "nvrtrie": "⊵⃒"
  of "nvsim": "∼⃒"
  of "smtes": "⪬︀"
  of "sqcaps": "⊓︀"
  of "sqcups": "⊔︀"
  of "suphsol": "⟉"
  of "varsubsetneq": "⊊︀"
  of "varsubsetneqq": "⫋︀"
  of "varsupsetneq": "⊋︀"
  of "varsupsetneqq": "⫌︀"
  of "vnsub": "⊂⃒"
  of "vnsup": "⊃⃒"
  of "vsubnE": "⫋︀"
  of "vsubne": "⊊︀"
  of "vsupnE": "⫌︀"
  of "vsupne": "⊋︀"
  of "OverBar": "‾"
  of "UnderBar": "_"
  of "epsiv": "ϵ"
  of "varepsilon": "ϵ"
  of "phiv": "ϕ"
  of "varphi": "ϕ"
  of "epsi": "ε"
  of "ohm": "Ω"
  of "angst": "Å"
  of "race": "∽̱"
  else: entityToUtf8(name)

proc attributeText(value: string): string =
  ## Attribute character references follow HTML's longest-match and ambiguous
  ## ampersand rules. Numeric references use replacement/C1 mappings rather
  ## than the XML numeric-reference semantics of the standard library.
  var at = 0
  while at < value.len:
    if value[at] != '&':
      result.add value[at]
      inc at
      continue
    let start = at
    inc at
    if at < value.len and value[at] == '#':
      inc at
      var radix = 10
      if at < value.len and value[at] in {'x', 'X'}:
        radix = 16
        inc at
      let digits = at
      var code = 0
      while at < value.len:
        let digit = case value[at]
          of '0'..'9': ord(value[at]) - ord('0')
          of 'a'..'f': ord(value[at]) - ord('a') + 10
          of 'A'..'F': ord(value[at]) - ord('A') + 10
          else: -1
        if digit < 0 or digit >= radix: break
        # Saturation avoids overflow even for hostile arbitrary-length input.
        code = min(0x110000, code * radix + digit)
        inc at
      if at > digits:
        if at < value.len and value[at] == ';': inc at
        if code == 0 or code > 0x10FFFF or code in 0xD800..0xDFFF:
          code = 0xFFFD
        const C1 = [0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020,
          0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F,
          0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
          0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178]
        if code in 0x80..0x9F: code = C1[code - 0x80]
        result.add toUTF8(Rune(code))
        continue
    else:
      let nameStart = at
      # The longest WHATWG name is 31 ASCII characters. Bound probing so an
      # arbitrary unknown name cannot cause quadratic suffix allocation.
      while at < value.len and at - nameStart < 32 and
          value[at] in {'a'..'z', 'A'..'Z', '0'..'9'}:
        inc at
      # A terminated known name consumes the semicolon. Only the historical
      # subset may omit it, and never before an attribute '=' or alphanumeric.
      if at < value.len and value[at] == ';':
        let decoded = namedEntity(value[nameStart ..< at])
        if decoded.len > 0:
          result.add decoded
          inc at
          continue
      var consumed = false
      for finish in countdown(at, nameStart + 1):
        let name = value[nameStart ..< finish]
        if name in LegacyEntityNames and (finish == value.len or
            value[finish] notin {'a'..'z', 'A'..'Z', '0'..'9', '='}):
          result.add namedEntity(name)
          at = finish
          consumed = true
          break
      if consumed: continue
    # Unknown/ambiguous references remain literal, without recursively decoding.
    result.add '&'
    at = start + 1

proc tagBoundary(text: string; at: int): bool =
  at == text.len or text[at] in HtmlSpace + {'/', '>'}

type HtmlElementToken* = object
  tag*: string
  start*, finish*: int
  closing*: bool
  attributes*: OrderedTable[string, string]

proc htmlElementTokens*(html: string): seq[HtmlElementToken] =
  ## Extract completed start-tag attributes in source order. This is a tokenizer
  ## for compiler-produced HTML, not tree construction/error-repair. It ignores
  ## comments/declarations, inert template content and text-only element bodies;
  ## scripting-enabled previews; incomplete tags never publish guessed classes.
  ## First duplicate
  ## attribute wins, matching HTML. Tokens split only on HTML ASCII whitespace.
  let lower = html.toLowerAscii()
  var at = 0
  var templateDepth = 0
  while at < html.len:
    let start = html.find('<', at)
    if start < 0: break
    at = start + 1
    if html.continuesWith("<!--", start):
      let finish = html.find("-->", at + 3)
      if finish < 0: break
      at = finish + 3
      continue
    if at >= html.len: break
    if html[at] in {'!', '?'}:
      # Doctype public/system identifiers can contain quoted '>' and '<'.
      # Other declarations/processing instructions are HTML bogus comments.
      if lower.continuesWith("!doctype", at) and tagBoundary(lower, at + 8):
        var quote = '\0'
        while at < html.len:
          if quote != '\0':
            if html[at] == quote: quote = '\0'
          elif html[at] in {'"', '\''}: quote = html[at]
          elif html[at] == '>': break
          inc at
        if at >= html.len: break
        inc at
      else:
        let finish = html.find('>', at)
        if finish < 0: break
        at = finish + 1
      continue
    let closing = html[at] == '/'
    if closing: inc at
    if at >= html.len or html[at] notin {'a'..'z', 'A'..'Z'}: continue
    let nameStart = at
    while at < html.len and html[at] notin HtmlSpace + {'/', '>'}: inc at
    let tag = lower[nameStart ..< at]
    var attributes = initOrderedTable[string, string]()
    var complete = false
    while at < html.len:
      while at < html.len and html[at] in HtmlSpace + {'/'}: inc at
      if at >= html.len: break
      if html[at] == '>':
        inc at
        complete = true
        break
      let attrStart = at
      # A leading '=' belongs to the attribute name in HTML. Discarding it
      # would invent a class attribute from a malformed '=class' spelling.
      if html[at] == '=': inc at
      while at < html.len and html[at] notin HtmlSpace + {'=', '/', '>'}: inc at
      if at == attrStart:
        inc at
        continue
      let attr = lower[attrStart ..< at]
      while at < html.len and html[at] in HtmlSpace: inc at
      var value = ""
      if at < html.len and html[at] == '=':
        inc at
        while at < html.len and html[at] in HtmlSpace: inc at
        if at >= html.len: break
        if html[at] in {'"', '\''}:
          let quote = html[at]
          inc at
          let valueStart = at
          while at < html.len and html[at] != quote: inc at
          if at >= html.len: break
          value = html[valueStart ..< at]
          inc at
        else:
          let valueStart = at
          while at < html.len and html[at] notin HtmlSpace + {'>'}: inc at
          value = html[valueStart ..< at]
      if not attributes.hasKey(attr): attributes[attr] = attributeText(value)
    if not complete: break
    if closing:
      if templateDepth == 0:
        result.add HtmlElementToken(tag: tag, start: start, finish: at,
          closing: true, attributes: attributes)
      if tag == "template" and templateDepth > 0: dec templateDepth
      continue
    if templateDepth == 0:
      result.add HtmlElementToken(tag: tag, start: start, finish: at,
        closing: false, attributes: attributes)
    if tag == "template": inc templateDepth
    if tag == "plaintext": break
    if tag in ["script", "style", "title", "textarea", "xmp", "iframe",
        "noembed", "noframes", "noscript"]:
      # Script escaped/double-escaped text can contain apparent script closing
      # tags. Track those states without evaluating executable source.
      var scriptState = 0
      while at < html.len:
        if tag == "script":
          if html.continuesWith("<!--", at):
            if scriptState == 0: scriptState = 1
            at += 4
            continue
          if html.continuesWith("-->", at):
            scriptState = 0
            at += 3
            continue
          if scriptState == 1 and lower.continuesWith("<script", at) and
              tagBoundary(lower, at + 7):
            scriptState = 2
            at += 7
            continue
        if lower.continuesWith("</" & tag, at) and
            tagBoundary(lower, at + tag.len + 2):
          if tag == "script" and scriptState == 2:
            scriptState = 1
            at += tag.len + 2
            continue
          break
        inc at


proc htmlClassNames*(html: string): seq[string] =
  ## Class relevance and source binding share one lossless markup tokenizer.
  for token in htmlElementTokens(html):
    if token.closing: continue
    let classes = token.attributes.getOrDefault("class")
    var tokenStart = 0
    for i in 0 .. classes.len:
      if i == classes.len or classes[i] in HtmlSpace:
        if i > tokenStart:
          let item = classes[tokenStart ..< i]
          if item notin result: result.add item
        tokenStart = i + 1

type SourceHtmlElement* = object
  id*: string
  tag*: string
  attributes*: OrderedTable[string, string]

proc sourceElementMarkup*(html, identityPrefix: string): tuple[html: string,
    elements: seq[SourceHtmlElement]] =
  ## Stamp compiler-owned identities into original markup offsets. No HTML is
  ## reserialized: scripts, CSS, text, Unicode and authored attributes retain
  ## their exact bytes. The prefix belongs to the catalog producer, not an RPC.
  if identityPrefix.len == 0 or identityPrefix.anyIt(it notin
      {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
    raise newException(ValueError, "Invalid compiler element identity prefix.")
  var cursor = 0
  var ordinal = 0
  var ids: seq[string]
  for token in htmlElementTokens(html):
    if token.closing or token.tag in ["html", "head", "body", "script", "style",
        "title", "meta", "link", "base", "template", "noscript"]: continue
    inc ordinal
    let existing = token.attributes.getOrDefault("data-isonim-element-id")
    let id = if existing.len > 0: existing else: identityPrefix & "-" & $ordinal
    if id in ids: raise newException(ValueError, "Duplicate compiler element identity.")
    ids.add id
    var attributes = token.attributes
    attributes["data-isonim-element-id"] = id
    result.elements.add SourceHtmlElement(id: id, tag: token.tag, attributes: attributes)
    if existing.len > 0: continue
    var insertion = token.finish - 1
    if insertion > token.start and html[insertion - 1] == '/': dec insertion
    result.html.add html[cursor ..< insertion]
    result.html.add " data-isonim-element-id=\"" & id & "\""
    cursor = insertion
  result.html.add html[cursor ..< html.len]
