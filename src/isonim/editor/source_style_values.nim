## Narrow, source-preserving CSS literal transformations shared by capability
## discovery and the native writer. Functions, token chains and elliptical
## radius syntax are deliberately outside the scalar/quad editing contract.
import std/[options, strutils]
import isonim/editor/[types, viewmodels]

func directCssVariable*(raw: string): string =
  let text = raw.strip()
  if not text.startsWith("var(--") or not text.endsWith(")"): return ""
  let name = text[4 ..< text.len - 1]
  if name.len <= 2: return ""
  for ch in name:
    if ch notin {'a'..'z','A'..'Z','0'..'9','-','_'}: return ""
  name

proc cssQuadValues*(property, raw: string): Option[array[4,string]] =
  let parts = raw.splitWhitespace()
  if parts.len < 1 or parts.len > 4: return none(array[4,string])
  for part in parts:
    let parsed = parseCssPropertyValue(property,part)
    if (parsed.kind notin {cvkLength,cvkPercentage} and part != "0") or
        validateCssPropertyValue(PropertyInfo(name:property,directStyleAllowed:true),
          PropertyEditRequest(property:property,newValue:part,kind:pekCss),parsed).len > 0:
      return none(array[4,string])
  let quad = [parts[0], if parts.len > 1: parts[1] else: parts[0],
    if parts.len > 2: parts[2] else: parts[0],
    if parts.len > 3: parts[3] elif parts.len > 1: parts[1] else: parts[0]]
  some(quad)

proc patchCssQuad*(property, raw, value: string; component: int;
    restoreLiteral = ""): string =
  let current = cssQuadValues(property,raw)
  if current.isNone or component notin 0..3: return ""
  let replacement = cssQuadValues(property,value)
  if replacement.isNone or value.splitWhitespace().len != 1: return ""
  var next = current.get
  next[component] = value
  if restoreLiteral.len > 0:
    let restored = cssQuadValues(property,restoreLiteral)
    if restored.isNone or restored.get != next: return ""
    return restoreLiteral
  # Retain the original byte representation for semantic no-ops.
  if next == current.get: return raw
  if next[0] == next[1] and next[0] == next[2] and next[0] == next[3]: return next[0]
  if next[0] == next[2] and next[1] == next[3]: return next[0] & " " & next[1]
  if next[1] == next[3]: return next[0] & " " & next[1] & " " & next[2]
  next.join(" ")
