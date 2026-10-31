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
