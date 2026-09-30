## isonim/dsl/vocabulary.nim
##
## Renderer-declared static vocabulary.
##
## A renderer type opts in by declaring a compile-time proc in its module:
##
##   proc staticVocabulary*(T: typedesc[MyRenderer]): VocabularyRef {.compileTime.}
##
## Renderer-mode `ui(r)` then emits, for each element, a static check guarded
## by `when compiles(staticVocabulary(typeof(r)))`, so renderers without the
## hook see no change at all (the `when` folds away). See `dsl/ui.nim`
## `emitVocabCheck`.
##
## `VocabularyRef` answers four queries: `hasTag`, `attrKind`,
## `forbiddenReason`, `allowedChild`. `checkElement` runs all four and
## returns "" when the element is valid, else a diagnostic message carrying
## the stable diagnostic code (E-VOCAB-UNKNOWN-TAG, E-VOCAB-FORBIDDEN-TAG,
## E-VOCAB-UNKNOWN-ATTR, E-STRUCT-NESTING). The caller passes the result
## to `failVocabCheck` inside a `static:` block whose lineinfo points at
## the element, so the error is reported at the offending node.

import std/macros

type
  AttrKind* = enum
    akStyle
    akAttr
    akUnknown

  AttrDef* = object
    name*: string
    kind*: AttrKind
    typ*: string
      ## Informational value type (`Len`, `Color`, `bool`, …); "" means
      ## untyped. The static check covers names only; value types are
      ## the renderer's own render-time concern.

  TagDef* = object
    name*: string
    attrs*: seq[AttrDef]
    allowedParents*: seq[string]
      ## Empty means the tag may appear anywhere (including the top level).
      ## Non-empty restricts the parent tag to this list; the top level
      ## (parent "") then fails, since "" is never listed — so `@[""]`
      ## means top-level-only (used by `mailDocument`).
    allowAnyStyle*: bool
      ## When true, style-keyword attributes (the macro's `styleAttrs`
      ## array) skip the schema: HTML leaves accept any style keyword plus
      ## their listed attributes. Plain attributes are always
      ## checked.

  ForbiddenTag* = object
    tag*: string
    reason*: string
    alternative*: string
      ## "" when the element is not expressible at all.

  VocabularyRef* = ref object
    tags*: seq[TagDef]
    forbidden*: seq[ForbiddenTag]

proc hasTag*(v: VocabularyRef; tag: string): bool =
  for t in v.tags:
    if t.name == tag:
      return true
  return false

proc canonAttrName(name: string): string =
  ## Attribute lookup is insensitive to `_` vs `-`: the macro passes the
  ## raw name (`background_color`) while a schema may store either form.
  result = newStringOfCap(name.len)
  for c in name:
    if c == '_':
      result.add('-')
    else:
      result.add(c)

proc attrKind*(v: VocabularyRef; tag, name: string): AttrKind =
  let want = canonAttrName(name)
  for t in v.tags:
    if t.name == tag:
      for a in t.attrs:
        if canonAttrName(a.name) == want:
          return a.kind
      return akUnknown
  return akUnknown

proc forbiddenReason*(v: VocabularyRef; tag: string): tuple[found: bool;
    reason, alternative: string] =
  for f in v.forbidden:
    if f.tag == tag:
      return (true, f.reason, f.alternative)
  return (false, "", "")

proc allowedChild*(v: VocabularyRef; parent, child: string): bool =
  for t in v.tags:
    if t.name == child:
      if t.allowedParents.len == 0:
        return true
      for p in t.allowedParents:
        if p == parent:
          return true
      return false
  # Unknown children are reported by hasTag; nesting says nothing about them.
  return true

proc editDistance(a, b: string): int =
  ## Wagner-Fischer edit distance. VM-safe (no imports) for `static:` use.
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len:
    prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    for j in 1 .. b.len:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      var m = prev[j] + 1
      let ins = cur[j - 1] + 1
      if ins < m:
        m = ins
      let sub = prev[j - 1] + cost
      if sub < m:
        m = sub
      cur[j] = m
    swap(prev, cur)
  result = prev[b.len]

proc nearestName(candidates: openArray[string]; target: string): string =
  var best = -1
  for c in candidates:
    let d = editDistance(c, target)
    if best < 0 or d < best:
      best = d
      result = c

proc nearestTag(v: VocabularyRef; tag: string): string =
  var names = newSeq[string](v.tags.len)
  for i, t in v.tags:
    names[i] = t.name
  result = nearestName(names, tag)

proc nearestAttr(v: VocabularyRef; tag, attr: string): string =
  for t in v.tags:
    if t.name == tag:
      var names = newSeq[string](t.attrs.len)
      for i, a in t.attrs:
        names[i] = a.name
      return nearestName(names, attr)
  return ""

proc tagAllowsAnyStyle(v: VocabularyRef; tag: string): bool =
  for t in v.tags:
    if t.name == tag:
      return t.allowAnyStyle
  return false

proc unknownAttrMsg(v: VocabularyRef; tag, attr: string): string =
  let suggestion = v.nearestAttr(tag, attr)
  if suggestion.len > 0:
    return "E-VOCAB-UNKNOWN-ATTR: '" & tag & "' has no attribute '" &
      attr & "'. Did you mean '" & suggestion & "'?"
  else:
    return "E-VOCAB-UNKNOWN-ATTR: '" & tag & "' has no attribute '" &
      attr & "'."

proc checkElement*(v: VocabularyRef; tag: string;
    styleAttrs, attrs: openArray[string]; parentTag: string): string =
  ## Validate one element. Returns "" when valid, else a diagnostic
  ## message with the stable diagnostic code. Pure and VM-safe: the caller
  ## evaluates it inside `static:` and asserts the result is "".
  ## `styleAttrs` holds the macro-routed style keywords, `attrs` the plain
  ## attributes; `class` always passes (the Tailwind vehicle, which a
  ## renderer may strip or rewrite itself, so no schema lists it).
  let (isForbidden, reason, alternative) = v.forbiddenReason(tag)
  if isForbidden:
    if alternative.len > 0:
      return "E-VOCAB-FORBIDDEN-TAG: '" & tag & "' is forbidden (" &
        reason & "). Use '" & alternative & "' instead."
    else:
      return "E-VOCAB-FORBIDDEN-TAG: '" & tag & "' is forbidden (" &
        reason & "). It is not expressible here."
  if not v.hasTag(tag):
    let suggestion = v.nearestTag(tag)
    if suggestion.len > 0:
      return "E-VOCAB-UNKNOWN-TAG: unknown tag '" & tag &
        "'. Did you mean '" & suggestion & "'?"
    else:
      return "E-VOCAB-UNKNOWN-TAG: unknown tag '" & tag & "'."
  if not v.tagAllowsAnyStyle(tag):
    for attr in styleAttrs:
      if attr != "class" and v.attrKind(tag, attr) == akUnknown:
        return v.unknownAttrMsg(tag, attr)
  for attr in attrs:
    if attr != "class" and v.attrKind(tag, attr) == akUnknown:
      return v.unknownAttrMsg(tag, attr)
  if not v.allowedChild(parentTag, tag):
    var allowed = ""
    for t in v.tags:
      if t.name == tag:
        for i, p in t.allowedParents:
          if i > 0:
            allowed.add(", ")
          allowed.add("'" & p & "'")
        break
    if parentTag.len == 0:
      return "E-STRUCT-NESTING: '" & tag &
        "' must not appear at the top level (allowed parents: " &
        allowed & ")."
    else:
      return "E-STRUCT-NESTING: '" & tag & "' must not be a child of '" &
        parentTag & "' (allowed parents: " & allowed & ")."
  return ""

proc failVocabCheck*(msg: string) {.compileTime.} =
  ## Raise the `checkElement` message as a compile error. Called inside the
  ## generated `static:` block; a macros `error` (unlike `doAssert`) renders
  ## as a plain `Error:` without a VM stack trace or `AssertionDefect`.
  if msg != "":
    error(msg)

macro checkProcOverloads*(resolved, elem: typed; src: untyped): untyped =
  ## Inner half of the E-VOCAB-PROC-AS-ELEMENT probe: `resolved` is the
  ## already-bound symbol(s) for the element name, `elem` the created
  ## element, `src` the as-written name carrying the element's lineinfo.
  ## Errors when any routine candidate returns the element type. The
  ## symbols arrive bound, so no scope lookup happens here. `resolved` is
  ## typed (not untyped) so the `bindSym` call the template forwards is
  ## evaluated instead of arriving as an opaque call node; `src` stays
  ## untyped so it keeps the element's lineinfo rather than the proc's.
  result = newStmtList()
  var elemType: NimNode
  try:
    elemType = getType(elem)
  except Exception:
    return result
  var cands: seq[NimNode] = @[]
  case resolved.kind
  of nnkOpenSymChoice, nnkClosedSymChoice:
    for c in resolved:
      cands.add(c)
  of nnkSym:
    cands.add(resolved)
  else:
    return result
  var hit = ""
  for c in cands:
    try:
      if c.kind != nnkSym or
          c.symKind notin {nskProc, nskFunc, nskMethod, nskTemplate}:
        continue
      # `getType` on a routine symbol answers `proc[ret, params...]`; a
      # typedef alias unwraps to the same. Either way `ret` below is the
      # routine's resolved return type, compared structurally.
      var ret: NimNode
      let ty = getType(c)
      if ty.kind == nnkBracketExpr and ty.len >= 2:
        ret = ty[1]
      elif ty.kind == nnkSym:
        let td = getImpl(ty)
        if td.kind != nnkTypeDef or td.len < 3 or
            td[^1].kind != nnkProcTy:
          continue
        let formal = td[^1][0]
        if formal.kind != nnkFormalParams or formal.len == 0:
          continue
        ret = formal[0]
      else:
        continue
      if ret.kind != nnkEmpty and sameType(ret, elemType):
        hit = c.strVal
        break
    except Exception:
      continue
  # The `error` sits outside every `try`: a probe failure degrades to the
  # plain unknown-tag error from the sibling check. A hit reports here
  # first (the probe is emitted before the tag check for this); the
  # sibling unknown-tag error still follows, and both are true.
  if hit.len > 0:
    error("E-VOCAB-PROC-AS-ELEMENT: '" & hit &
      "' is a proc returning the renderer's element type, but it was " &
      "called with named arguments or a block, so the ui macro parsed it " &
      "as an element. Either call it positionally — " & hit &
      "(r, data) — or, if it takes a child block, declare it as a " &
      "vocabulary element (defineMailPattern).", src)

template checkNotProcAsElement*(name: untyped; elem: typed): untyped =
  ## E-VOCAB-PROC-AS-ELEMENT: `name` was classified
  ## as an element (a call with named arguments or a block), but resolves
  ## in the template's scope to a routine returning the renderer's element
  ## type — a data-only component called the content-taking way. Emits no
  ## code; errors naming both fixes. The return-type gate is what keeps
  ## coincidental matches (e.g. `div` vs `system.div`) silent.
  ##
  ## A template, not a macro: `bindSym` only accepts syntactic ident or
  ## string-literal syntax, so substitution carries the as-written name to
  ## it; the analysis lives in `checkProcOverloads`. The name travels via
  ## `astToStr` (a bare substituted ident would resolve to the proc before
  ## the magic sees it). Instantiated under `when declared(name)`, which
  ## keeps unresolvable names from ever reaching `bindSym`.
  checkProcOverloads(bindSym(astToStr(name), brForceOpen), elem, name)
