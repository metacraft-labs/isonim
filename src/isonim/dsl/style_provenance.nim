## Style provenance: the wire format for "where did this property come from".
##
## A computed style has lost its provenance by the time `getComputedStyle`
## returns it — `padding: 12px` is the same string whether the author wrote
## `p-3`, `padding = "12px"`, or `padding: var(--space-3)`. The information
## exists only at the point the DSL macro reads the *authored* attribute, so
## that is where it is captured, and this module is the format it travels in.
##
## Deliberately dependency-light (`std/strutils` only). It is imported by the
## DSL, which every IsoNim project compiles, and by the editor's ViewModels,
## which must decode it without pulling the DSL's compile-time machinery.
##
## Transport mirrors the scene-graph seam exactly, because that seam is
## already measured to cost nothing in production:
##
##   client mode -> `noteProperties(el, id, <encoded>)`, a template whose
##                  production arm ignores every parameter;
##   SSR mode    -> `data-isonim-props="<encoded>"`, stamped inside the same
##                  `when sceneGraphEnabled` that stamps `data-isonim-src`.
##
## ONE encoded string per element rather than one call per property: less AST
## per element, and the two transports cannot disagree about a property list
## they do not each assemble.

import std/strutils

type
  StyleBindingKind* = enum
    ## How the authored source produced this property.
    ##
    ## These map onto the editor's `PropertyOrigin`, but they are a separate
    ## enum on purpose: this one describes *authored syntax*, which the DSL
    ## knows, and `PropertyOrigin` describes the editor's model of ownership,
    ## which the DSL must not have an opinion about.
    sbkUnresolved = "?"     ## A binding was authored and could not be resolved.
    sbkClassUtility = "cls" ## A class token found in the compile-time class index.
    sbkTokenRef = "tok"     ## The authored value is a token reference.
    sbkStyleAttr = "sty"    ## A DSL style-property attribute (becomes setStyle).
    sbkInlineStyle = "inl"  ## A declaration inside a literal `style="…"`.
    sbkConstant = "con"     ## A literal value with no binding.

  StyleBinding* = object
    property*: string  ## CSS property name, or "" on an unresolved record.
    value*: string     ## Authored value as it will reach the element.
    kind*: StyleBindingKind
    detail*: string    ## `class:p-4`, `attr:padding`, `style-attr:color`, …
    token*: string     ## Token key when `kind == sbkTokenRef`.
    note*: string      ## Why it could not be resolved; only for sbkUnresolved.

const
  fieldSep = '|'
  recordSep = ';'

func escapeField(s: string): string =
  ## `\` `|` `;` are the three characters the format reserves. Everything else
  ## — including the commas and quotes that live inside `box-shadow` and
  ## `font-family` values — passes through untouched.
  result = newStringOfCap(s.len + 4)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of fieldSep: result.add "\\p"
    of recordSep: result.add "\\s"
    of '\n', '\r': result.add ' '
    else: result.add c

func unescapeField(s: string): string =
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      case s[i + 1]
      of '\\': result.add '\\'
      of 'p': result.add fieldSep
      of 's': result.add recordSep
      else: result.add s[i + 1]
      i += 2
    else:
      result.add s[i]
      inc i

func encodeStyleBindings*(bindings: seq[StyleBinding]): string =
  ## `property|value|kind|detail|token|note` per record, records joined by `;`.
  var parts: seq[string] = @[]
  for b in bindings:
    parts.add(
      escapeField(b.property) & fieldSep &
      escapeField(b.value) & fieldSep &
      escapeField($b.kind) & fieldSep &
      escapeField(b.detail) & fieldSep &
      escapeField(b.token) & fieldSep &
      escapeField(b.note))
  parts.join($recordSep)

func kindFromTag(tag: string): StyleBindingKind =
  ## Unknown tags decode as `sbkUnresolved` rather than raising: this string
  ## arrives from a DOM attribute an older or newer build may have stamped,
  ## and a decode failure must not take down the inspector.
  for k in StyleBindingKind:
    if $k == tag:
      return k
  sbkUnresolved

func decodeStyleBindings*(encoded: string): seq[StyleBinding] =
  if encoded.len == 0:
    return @[]
  for record in encoded.split(recordSep):
    if record.len == 0:
      continue
    let fields = record.split(fieldSep)
    if fields.len < 3:
      continue
    var b = StyleBinding(
      property: unescapeField(fields[0]),
      value: unescapeField(fields[1]),
      kind: kindFromTag(unescapeField(fields[2])))
    if fields.len > 3: b.detail = unescapeField(fields[3])
    if fields.len > 4: b.token = unescapeField(fields[4])
    if fields.len > 5: b.note = unescapeField(fields[5])
    result.add b

func htmlAttrEscape*(s: string): string =
  ## Escape an already-encoded payload for a double-quoted HTML attribute.
  ## Separate from `ssr/escape.escapeAttr` because this one runs in the macro,
  ## on a compile-time constant, and must not drag the SSR module into the
  ## DSL's import graph.
  result = newStringOfCap(s.len + 8)
  for c in s:
    case c
    of '&': result.add "&amp;"
    of '"': result.add "&quot;"
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    else: result.add c

func tokenReferenceIn*(rawValue: string): string =
  ## The token key inside an authored value, or "" if the value is a literal.
  ##
  ## The three accepted spellings are exactly the ones the editor's
  ## `tokenNameFromRaw` (viewmodels.nim) already understands, so a value the
  ## DSL calls a binding is a value the inspector can chase to a token.
  ## Keeping the two in step matters more than the syntax itself; a third
  ## spelling added here without adding it there produces a binding the
  ## editor sees and cannot resolve.
  let text = rawValue.strip()
  if text.startsWith("var(--") and text.endsWith(")"):
    return text[6 ..< text.len - 1].strip()
  if text.startsWith("token(") and text.endsWith(")"):
    return text[6 ..< text.len - 1].strip()
  if text.startsWith("$") and text.len > 1 and not text.contains(' '):
    return text[1 .. ^1].strip()
  ""
