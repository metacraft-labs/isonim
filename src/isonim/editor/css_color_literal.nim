## Finite numeric literal colors shared by inspector controls and source writers.
## Hex/RGB/HSL channels are decoded without evaluating token/expression owners.
import std/[math, strutils]

type LiteralColorChannels* = tuple[valid: bool, red, green, blue, alpha: int]

func component(raw: string; hue = false): tuple[valid: bool, value: float] =
  var text = raw.strip().toLowerAscii()
  if hue and text.endsWith("%"): return
  var divisor = 1.0
  if hue:
    for unit in ["grad", "turn", "deg", "rad"]:
      if text.endsWith(unit):
        text.setLen(text.len-unit.len)
        divisor = case unit
          of "grad": 400.0
          of "turn": 1.0
          of "rad": 2 * PI
          else: 360.0
        break
    if divisor == 1 and not raw.strip().toLowerAscii().endsWith("turn"): divisor = 360
  elif text.endsWith("%"):
    text.setLen(text.len-1)
    divisor = 100
  if text.len == 0: return
  try:
    let number = parseFloat(text)
    if classify(number) in {fcNan, fcInf, fcNegInf}: return
    result = (true, number/divisor)
  except ValueError: discard

func literalColorChannels*(raw: string): LiteralColorChannels =
  let text = raw.strip().toLowerAscii()
  if text.startsWith("#"):
    if text.len notin [4,5,7,9]: return
    var hex = ""
    for ch in text[1..^1]:
      if ch notin {'0'..'9','a'..'f'}: return
      hex.add ch
      if text.len in [4,5]: hex.add ch
    result = (true,parseHexInt(hex[0..1]),parseHexInt(hex[2..3]),parseHexInt(hex[4..5]),255)
    if hex.len == 8: result.alpha = parseHexInt(hex[6..7])
    return
  let opening = text.find('(')
  if opening < 0 or not text.endsWith(")"): return
  let name = text[0..<opening]
  if name notin ["rgb","rgba","hsl","hsla"]: return
  let body = text[opening+1..<text.len-1]
  if '(' in body or ')' in body: return
  var channels: seq[string]
  let comma = ',' in body
  if comma:
    if '/' in body: return
    channels = body.split(',')
    if channels.len notin [3,4]: return
  else:
    let parts = body.split('/')
    if parts.len notin [1,2]: return
    channels = parts[0].splitWhitespace()
    if channels.len != 3: return
    if parts.len == 2: channels.add parts[1].strip()
  let hsl = name in ["hsl","hsla"]
  var values: array[4,float]
  values[3] = 1
  for i, channel in channels:
    let percent = channel.strip().endsWith("%")
    if comma and i in [1,2] and not hsl and
        percent != channels[0].strip().endsWith("%"): return
    if comma and hsl and i in [1,2] and not percent: return
    let parsed = component(channel,hue=hsl and i==0)
    if not parsed.valid: return
    values[i] = parsed.value
    if i < 3 and not (hsl and i==0) and not percent:
      values[i] /= (if hsl: 100.0 else: 255.0)
  var red,green,blue: float
  if hsl:
    let hue = (values[0]-floor(values[0]))*6
    let saturation = clamp(values[1],0,1)
    let lightness = clamp(values[2],0,1)
    let chroma = (1-abs(2*lightness-1))*saturation
    let x = chroma*(1-abs(hue-floor(hue/2)*2-1))
    let m = lightness-chroma/2
    case int(floor(hue))
    of 0: red=chroma; green=x
    of 1: red=x; green=chroma
    of 2: green=chroma; blue=x
    of 3: green=x; blue=chroma
    of 4: red=x; blue=chroma
    else: red=chroma; blue=x
    red+=m; green+=m; blue+=m
  else: red=values[0]; green=values[1]; blue=values[2]
  (true,int(round(clamp(red,0,1)*255)),int(round(clamp(green,0,1)*255)),
    int(round(clamp(blue,0,1)*255)),int(round(clamp(values[3],0,1)*255)))

func validCssColorLiteral*(raw: string): bool = literalColorChannels(raw).valid

# --------------------------------------------------------------------------- #
#  Every CSS <color> syntax (CSS Color 4 §4, https://www.w3.org/TR/css-color-4/#color-syntax;
#  CSS Color 5, https://www.w3.org/TR/css-color-5/).
# --------------------------------------------------------------------------- #

const namedCssColorHex* = [
  ("aliceblue", "#F0F8FF"), ("antiquewhite", "#FAEBD7"), ("aqua", "#00FFFF"),
  ("aquamarine", "#7FFFD4"), ("azure", "#F0FFFF"), ("beige", "#F5F5DC"),
  ("bisque", "#FFE4C4"), ("black", "#000000"), ("blanchedalmond", "#FFEBCD"),
  ("blue", "#0000FF"), ("blueviolet", "#8A2BE2"), ("brown", "#A52A2A"),
  ("burlywood", "#DEB887"), ("cadetblue", "#5F9EA0"),
  ("chartreuse", "#7FFF00"), ("chocolate", "#D2691E"), ("coral", "#FF7F50"),
  ("cornflowerblue", "#6495ED"), ("cornsilk", "#FFF8DC"),
  ("crimson", "#DC143C"), ("cyan", "#00FFFF"), ("darkblue", "#00008B"),
  ("darkcyan", "#008B8B"), ("darkgoldenrod", "#B8860B"),
  ("darkgray", "#A9A9A9"), ("darkgreen", "#006400"), ("darkgrey", "#A9A9A9"),
  ("darkkhaki", "#BDB76B"), ("darkmagenta", "#8B008B"),
  ("darkolivegreen", "#556B2F"), ("darkorange", "#FF8C00"),
  ("darkorchid", "#9932CC"), ("darkred", "#8B0000"),
  ("darksalmon", "#E9967A"), ("darkseagreen", "#8FBC8F"),
  ("darkslateblue", "#483D8B"), ("darkslategray", "#2F4F4F"),
  ("darkslategrey", "#2F4F4F"), ("darkturquoise", "#00CED1"),
  ("darkviolet", "#9400D3"), ("deeppink", "#FF1493"),
  ("deepskyblue", "#00BFFF"), ("dimgray", "#696969"), ("dimgrey", "#696969"),
  ("dodgerblue", "#1E90FF"), ("firebrick", "#B22222"),
  ("floralwhite", "#FFFAF0"), ("forestgreen", "#228B22"),
  ("fuchsia", "#FF00FF"), ("gainsboro", "#DCDCDC"),
  ("ghostwhite", "#F8F8FF"), ("gold", "#FFD700"), ("goldenrod", "#DAA520"),
  ("gray", "#808080"), ("green", "#008000"), ("greenyellow", "#ADFF2F"),
  ("grey", "#808080"), ("honeydew", "#F0FFF0"), ("hotpink", "#FF69B4"),
  ("indianred", "#CD5C5C"), ("indigo", "#4B0082"), ("ivory", "#FFFFF0"),
  ("khaki", "#F0E68C"), ("lavender", "#E6E6FA"),
  ("lavenderblush", "#FFF0F5"), ("lawngreen", "#7CFC00"),
  ("lemonchiffon", "#FFFACD"), ("lightblue", "#ADD8E6"),
  ("lightcoral", "#F08080"), ("lightcyan", "#E0FFFF"),
  ("lightgoldenrodyellow", "#FAFAD2"), ("lightgray", "#D3D3D3"),
  ("lightgreen", "#90EE90"), ("lightgrey", "#D3D3D3"),
  ("lightpink", "#FFB6C1"), ("lightsalmon", "#FFA07A"),
  ("lightseagreen", "#20B2AA"), ("lightskyblue", "#87CEFA"),
  ("lightslategray", "#778899"), ("lightslategrey", "#778899"),
  ("lightsteelblue", "#B0C4DE"), ("lightyellow", "#FFFFE0"),
  ("lime", "#00FF00"), ("limegreen", "#32CD32"), ("linen", "#FAF0E6"),
  ("magenta", "#FF00FF"), ("maroon", "#800000"),
  ("mediumaquamarine", "#66CDAA"), ("mediumblue", "#0000CD"),
  ("mediumorchid", "#BA55D3"), ("mediumpurple", "#9370DB"),
  ("mediumseagreen", "#3CB371"), ("mediumslateblue", "#7B68EE"),
  ("mediumspringgreen", "#00FA9A"), ("mediumturquoise", "#48D1CC"),
  ("mediumvioletred", "#C71585"), ("midnightblue", "#191970"),
  ("mintcream", "#F5FFFA"), ("mistyrose", "#FFE4E1"),
  ("moccasin", "#FFE4B5"), ("navajowhite", "#FFDEAD"), ("navy", "#000080"),
  ("oldlace", "#FDF5E6"), ("olive", "#808000"), ("olivedrab", "#6B8E23"),
  ("orange", "#FFA500"), ("orangered", "#FF4500"), ("orchid", "#DA70D6"),
  ("palegoldenrod", "#EEE8AA"), ("palegreen", "#98FB98"),
  ("paleturquoise", "#AFEEEE"), ("palevioletred", "#DB7093"),
  ("papayawhip", "#FFEFD5"), ("peachpuff", "#FFDAB9"), ("peru", "#CD853F"),
  ("pink", "#FFC0CB"), ("plum", "#DDA0DD"), ("powderblue", "#B0E0E6"),
  ("purple", "#800080"), ("rebeccapurple", "#663399"), ("red", "#FF0000"),
  ("rosybrown", "#BC8F8F"), ("royalblue", "#4169E1"),
  ("saddlebrown", "#8B4513"), ("salmon", "#FA8072"),
  ("sandybrown", "#F4A460"), ("seagreen", "#2E8B57"),
  ("seashell", "#FFF5EE"), ("sienna", "#A0522D"), ("silver", "#C0C0C0"),
  ("skyblue", "#87CEEB"), ("slateblue", "#6A5ACD"), ("slategray", "#708090"),
  ("slategrey", "#708090"), ("snow", "#FFFAFA"), ("springgreen", "#00FF7F"),
  ("steelblue", "#4682B4"), ("tan", "#D2B48C"), ("teal", "#008080"),
  ("thistle", "#D8BFD8"), ("tomato", "#FF6347"), ("turquoise", "#40E0D0"),
  ("violet", "#EE82EE"), ("wheat", "#F5DEB3"), ("white", "#FFFFFF"),
  ("whitesmoke", "#F5F5F5"), ("yellow", "#FFFF00"),
  ("yellowgreen", "#9ACD32")]
  ## The named colours and their sRGB values
  ## (https://www.w3.org/TR/css-color-4/#named-colors).

func namedColorHex*(name: string): string =
  ## The hex value of a named colour, or "".
  let lowered = name.strip().toLowerAscii()
  for (named, hex) in namedCssColorHex:
    if named == lowered: return hex
  ""

const systemCssColors* = ["accentcolor", "accentcolortext", "activetext",
  "buttonborder", "buttonface", "buttontext", "canvas", "canvastext", "field",
  "fieldtext", "graytext", "highlight", "highlighttext", "linktext", "mark",
  "marktext", "selecteditem", "selecteditemtext", "visitedtext"]
  ## The system colours (https://www.w3.org/TR/css-color-4/#css-system-colors).

const predefinedColorSpaces = ["srgb", "srgb-linear", "display-p3", "a98-rgb",
  "prophoto-rgb", "rec2020", "xyz", "xyz-d50", "xyz-d65"]
  ## `color()`'s predefined spaces (https://www.w3.org/TR/css-color-4/#predefined).

const rectangularSpaces = ["srgb", "srgb-linear", "display-p3", "a98-rgb",
  "prophoto-rgb", "rec2020", "lab", "oklab", "xyz", "xyz-d50", "xyz-d65"]
const polarSpaces = ["hsl", "hwb", "lch", "oklch"]
const hueMethods = ["shorter", "longer", "increasing", "decreasing"]
  ## color-mix()'s interpolation spaces and hue methods
  ## (https://www.w3.org/TR/css-color-4/#interpolation-space).

const mathFunctions = ["calc", "min", "max", "clamp", "round", "mod", "rem",
  "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "pow", "sqrt", "hypot",
  "log", "exp", "abs", "sign"]
  ## Math functions a component may be written as (CSS Values 4 §10).

const referenceFunctions = ["var", "env", "attr"]
  ## Substitutions: a value holding one is a colour only by what it resolves
  ## to, which this text does not say.

func functionName(token: string): string =
  ## ``token``'s function name (`oklch` of `oklch(...)`), or "" when it is
  ## not one balanced function call.
  let opening = token.find('(')
  if opening <= 0 or not token.endsWith(")"): return ""
  var depth = 0
  for i, ch in token:
    if ch == '(': inc depth
    elif ch == ')':
      dec depth
      if depth < 0 or (depth == 0 and i != token.len - 1): return ""
  if depth != 0: return ""
  token[0 ..< opening]

func hasReference(text: string): bool =
  for name in referenceFunctions:
    if (name & "(") in text: return true

func colorTokens(body: string): seq[string] =
  ## ``body`` split at the top level on whitespace, with `,` and `/` as
  ## tokens of their own; a nested function stays one token.
  var depth = 0
  var current = ""
  proc flush(current: var string; result: var seq[string]) =
    if current.len > 0:
      result.add current
      current = ""
  for ch in body:
    if ch == '(':
      inc depth
      current.add ch
    elif ch == ')':
      dec depth
      current.add ch
    elif depth == 0 and ch in {' ', '\t', '\n', '\r'}:
      flush(current, result)
    elif depth == 0 and ch in {',', '/'}:
      flush(current, result)
      result.add $ch
    else:
      current.add ch
  flush(current, result)

func numberUnit(token: string): tuple[ok: bool, unit: string] =
  ## A CSS number token with its unit (https://www.w3.org/TR/css-syntax-3/#consume-number).
  var at = 0
  if at < token.len and token[at] in {'+', '-'}: inc at
  var digits = 0
  while at < token.len and token[at] in {'0'..'9'}: (inc at; inc digits)
  if at < token.len and token[at] == '.':
    inc at
    while at < token.len and token[at] in {'0'..'9'}: (inc at; inc digits)
  if digits == 0: return
  if at + 1 < token.len and token[at] == 'e':
    var next = at + 1
    if token[next] in {'+', '-'}: inc next
    if next < token.len and token[next] in {'0'..'9'}:
      at = next
      while at < token.len and token[at] in {'0'..'9'}: inc at
  (true, token[at .. ^1])

type ComponentKind = enum ckValue, ckHue, ckAlpha

func validComponent(token: string; kind: ComponentKind;
    channels: openArray[string]): bool =
  ## One channel of a colour function: a number, a percentage (not for a
  ## hue), an angle (a hue only), `none`, a math function, or -- in relative
  ## syntax -- one of the origin colour's channel keywords.
  if token == "none" or token in channels: return true
  let name = functionName(token)
  if name.len > 0: return name in mathFunctions
  let (ok, unit) = numberUnit(token)
  if not ok: return false
  case kind
  of ckHue: unit in ["", "deg", "rad", "grad", "turn"]
  of ckValue, ckAlpha: unit in ["", "%"]

func isCssColorValue*(raw: string): bool

func validChannels(tokens: openArray[string]; hueAt: int;
    channels: openArray[string]): bool =
  ## Three channels and an optional `/ alpha`, in the space-separated syntax.
  if tokens.len notin [3, 5]: return false
  if tokens.len == 5 and tokens[3] != "/": return false
  for i in 0 ..< 3:
    if tokens[i] in [",", "/"]: return false
    let kind = if i == hueAt: ckHue else: ckValue
    if not validComponent(tokens[i], kind, channels): return false
  tokens.len == 3 or validComponent(tokens[4], ckAlpha, channels)

func validColorFunction(name, body: string): bool =
  ## ``name(body)`` against its CSS Color 4 / 5 grammar.
  let tokens = colorTokens(body)
  if tokens.len == 0: return false
  case name
  of "rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch":
    let family = if name in ["rgba", "hsla"]: name[0 ..< 3] else: name
    let hueAt = case family
      of "hsl", "hwb": 0
      of "lch", "oklch": 2
      else: -1
    var channels: seq[string]
    for ch in family: channels.add $ch
    if family == "oklab": channels = @["l", "a", "b"]
    if family == "oklch": channels = @["l", "c", "h"]
    channels.add "alpha"
    if tokens[0] == "from":
      # Relative colour syntax (CSS Color 5 §4): an origin colour, then
      # channels that may name the origin's own.
      return tokens.len >= 2 and isCssColorValue(tokens[1]) and
        validChannels(tokens[2 .. ^1], hueAt, channels)
    if family in ["rgb", "hsl"] and "," in tokens:
      # The legacy comma syntax: three or four comma-separated channels.
      var parts: seq[string]
      for i, token in tokens:
        if i mod 2 == 1:
          if token != ",": return false
        else: parts.add token
      if tokens.len mod 2 == 0 or parts.len notin [3, 4]: return false
      # CSS Color 4 legacy syntax (https://www.w3.org/TR/css-color-4/#typedef-legacy-rgb-syntax,
      # #typedef-legacy-hsl-syntax): no `none`; rgb's three channels are all
      # numbers or all percentages; hsl's are a hue and two percentages; the
      # alpha is a number or a percentage. A math function stands for either.
      var rgbKind = ""
      for i, part in parts:
        if part == "none": return false
        let math = functionName(part).len > 0
        if math:
          if functionName(part) notin mathFunctions: return false
          continue
        let (ok, unit) = numberUnit(part)
        if not ok: return false
        if i == 3:
          if unit notin ["", "%"]: return false
        elif family == "rgb":
          if unit notin ["", "%"]: return false
          if rgbKind.len == 0: rgbKind = (if unit == "%": "%" else: "number")
          elif rgbKind != (if unit == "%": "%" else: "number"): return false
        elif i == 0:
          if unit notin ["", "deg", "rad", "grad", "turn"]: return false
        elif unit != "%": return false
      return true
    validChannels(tokens, hueAt, @[])
  of "color":
    var rest = @tokens
    var channels = @["r", "g", "b", "x", "y", "z", "alpha"]
    if rest[0] == "from":
      if rest.len < 2 or not isCssColorValue(rest[1]): return false
      rest = rest[2 .. ^1]
    else: channels = @[]
    if rest.len == 0: return false
    let space = rest[0]
    if space notin predefinedColorSpaces and not space.startsWith("--"):
      return false
    validChannels(rest[1 .. ^1], -1, channels)
  of "color-mix":
    # CSS Color 5 (https://www.w3.org/TR/css-color-5/#color-mix):
    # `color-mix(<color-interpolation-method>, [<color> && <percentage [0,100]>?]#{2})`,
    # where the method is `in` a rectangular space, a polar space with an
    # optional `<hue-interpolation-method> hue`, or a custom `--space`; and
    # two percentages that sum to zero make the function invalid.
    var groups: seq[seq[string]] = @[@[]]
    for token in tokens:
      if token == ",": groups.add @[]
      else: groups[^1].add token
    if groups.len != 3: return false
    let head = groups[0]
    if head.len < 2 or head[0] != "in": return false
    let space = head[1]
    if space in rectangularSpaces or space.startsWith("--"):
      if head.len != 2: return false
    elif space in polarSpaces:
      if head.len == 4:
        if head[2] notin hueMethods or head[3] != "hue": return false
      elif head.len != 2: return false
    else: return false
    var total = 0.0
    var given = 0
    for group in groups[1 .. ^1]:
      if group.len notin [1, 2]: return false
      var color = 0
      for token in group:
        if isCssColorValue(token): inc color
        elif functionName(token).len > 0:
          if functionName(token) notin mathFunctions: return false
          given = -100 # a computed percentage: its range is not known here
        else:
          let (ok, unit) = numberUnit(token)
          if not ok or unit != "%": return false
          let percent = parseFloat(token[0 ..< token.len - 1])
          if percent < 0.0 or percent > 100.0: return false
          total += percent
          if given >= 0: inc given
      if color != 1: return false
    # Two stated percentages summing to zero (`red 0%, blue 0%`) are invalid.
    not (given == 2 and total == 0.0)
  of "light-dark":
    tokens.len == 3 and tokens[1] == "," and isCssColorValue(tokens[0]) and
      isCssColorValue(tokens[2])
  else: false

func isCssColorValue*(raw: string): bool =
  ## Whether ``raw`` is a CSS <color> (CSS Color 4 §4, CSS Color 5): a hex
  ## colour, a named or system colour, `transparent`, `currentColor`, or a
  ## colour function whose arguments follow its grammar, including relative
  ## colour syntax (`rgb(from red r g b)`). A value that holds a reference
  ## (`var()`, `env()`, `attr()`) is not: it is a colour only by what it
  ## resolves to, and the editor reads the resolved value where the host
  ## reports one (editor spec "Section catalogue", "When colours present").
  let text = raw.strip().toLowerAscii()
  if text.len == 0 or hasReference(text): return false
  if literalColorChannels(text).valid: return true
  if text in ["transparent", "currentcolor"] or namedColorHex(text).len > 0 or
      text in systemCssColors:
    return true
  let name = functionName(text)
  if name.len == 0: return false
  validColorFunction(name, text[name.len + 1 ..< text.len - 1])

func cssColorKey*(raw: string): string =
  ## A key under which two spellings of one colour are one colour: the
  ## sRGB channels of every colour the editor decodes (`#f00`, `red`,
  ## `rgb(255, 0, 0)` and `hsl(0 100% 50%)` share one; `transparent` is
  ## transparent black), otherwise the lower-cased text.
  let text = raw.strip().toLowerAscii()
  var channels = literalColorChannels(text)
  if not channels.valid:
    let hex = namedColorHex(text)
    if hex.len > 0: channels = literalColorChannels(hex)
    elif text == "transparent": channels = literalColorChannels("#00000000")
  if channels.valid: $channels else: text

func decodedColorChannels*(raw: string): LiteralColorChannels =
  ## The sRGB channels of a literal or named colour (or `transparent`), as
  ## the Selection colours row shows them; invalid for other colour syntax.
  let text = raw.strip().toLowerAscii()
  result = literalColorChannels(text)
  if not result.valid:
    let hex = namedColorHex(text)
    if hex.len > 0: result = literalColorChannels(hex)
    elif text == "transparent": result = literalColorChannels("#00000000")
