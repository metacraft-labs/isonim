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
## the stable diagnostic code (E-VOCAB-UNKNOWN-TAG, E-VOCAB-FORBIDDEN-TAG
## or the forbidden entry's own code, E-VOCAB-UNKNOWN-ATTR,
## E-STRUCT-NESTING).
##
## Reporting. `ui.nim` evaluates the message into a `const` and, when it is
## non-empty, emits an `{.error: msg.}` pragma carrying the element's line
## info. The compiler then reports the error at the template's own
## `file(line, col)`, preceded only by the `ui` call's instantiation line in
## the same file: no VM stack trace, and nothing attributed to this module.
## (`macros.error` from a compile-time proc or a macro prints a
## `stack trace:` header first, so neither is used for reporting.)
##
## Parent at the top of a block. Each `ui(r)` block is checked on its own,
## and the parent of its top-level elements is unknown: the block may be the
## body of a proc whose result a caller appends inside some other element.
## `ui` therefore passes `parentKnown = false` for top-level elements and
## the nesting rule is skipped for them. A tag whose only allowed parent is
## `""` (the document root) is still rejected when it is nested below
## another element, so "must be the top-level element" keeps holding. A
## renderer that re-checks the assembled tree at run time calls
## `checkElement` with `parentKnown = true` and parent `""` for the tree's
## root.

import std/macros

const DefaultForbiddenCode* = "E-VOCAB-FORBIDDEN-TAG"

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
      ## Non-empty restricts the parent tag to this list; `""` in the list
      ## stands for the document root, so `@[""]` means "only ever the
      ## top-level element" (a document element). With a known parent of
      ## `""` (a run-time check of an assembled tree) an element whose list
      ## lacks `""` fails; at the top of a `ui` block the parent is unknown
      ## and the rule is skipped (see the module doc).
    nestingAlternative*: string
      ## Optional hint named by an E-STRUCT-NESTING violation for this tag
      ## ("Use '<alternative>' instead."), e.g. the vocabulary element that
      ## replaces a bare HTML tag in the wrong place. "" names none.
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
    code*: string = DefaultForbiddenCode
      ## The diagnostic code the violation reports. Defaults to
      ## E-VOCAB-FORBIDDEN-TAG; a vocabulary may give a family of forbidden
      ## tags a more specific code (e.g. an accessibility code for
      ## sectioning elements). "" also means the default.

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

proc forbiddenCode*(v: VocabularyRef; tag: string): string =
  ## The diagnostic code for a forbidden `tag` ("" when it is not
  ## forbidden).
  for f in v.forbidden:
    if f.tag == tag:
      return (if f.code.len > 0: f.code else: DefaultForbiddenCode)
  return ""

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

proc tagDef(v: VocabularyRef; tag: string): tuple[found: bool; def: TagDef] =
  for t in v.tags:
    if t.name == tag:
      return (true, t)
  return (false, TagDef())

proc isDocumentRootOnly(t: TagDef): bool =
  ## True when the tag's only allowed parent is the document root.
  if t.allowedParents.len == 0:
    return false
  for p in t.allowedParents:
    if p.len > 0:
      return false
  return true

proc nestingMsg(v: VocabularyRef; tag, parentTag: string): string =
  let (_, t) = v.tagDef(tag)
  var allowed = ""
  for i, p in t.allowedParents:
    if i > 0:
      allowed.add(", ")
    if p.len == 0:
      allowed.add("the top level")
    else:
      allowed.add("'" & p & "'")
  if parentTag.len == 0:
    result = "E-STRUCT-NESTING: '" & tag &
      "' must not appear at the top level (allowed parents: " &
      allowed & ")."
  elif t.isDocumentRootOnly:
    result = "E-STRUCT-NESTING: '" & tag &
      "' must be the top-level element of its ui block; it must not be a " &
      "child of '" & parentTag & "'."
  else:
    result = "E-STRUCT-NESTING: '" & tag & "' must not be a child of '" &
      parentTag & "' (allowed parents: " & allowed & ")."
  if t.nestingAlternative.len > 0:
    result.add(" Use '" & t.nestingAlternative & "' instead.")

proc checkElement*(v: VocabularyRef; tag: string;
    styleAttrs, attrs: openArray[string]; parentTag: string;
    parentKnown = true): string =
  ## Validate one element. Returns "" when valid, else a diagnostic
  ## message with the stable diagnostic code. Pure and VM-safe: the caller
  ## evaluates it at compile time and reports a non-empty result.
  ## `styleAttrs` holds the macro-routed style keywords, `attrs` the plain
  ## attributes; `class` always passes (the Tailwind vehicle, which a
  ## renderer may strip or rewrite itself, so no schema lists it).
  ##
  ## `parentTag` is the enclosing element's tag, `""` for the document
  ## root. With `parentKnown = false` (the top level of a `ui` block, whose
  ## result a caller may append anywhere) the nesting rule is skipped.
  let (isForbidden, reason, alternative) = v.forbiddenReason(tag)
  if isForbidden:
    let code = v.forbiddenCode(tag)
    if alternative.len > 0:
      return code & ": '" & tag & "' is forbidden (" &
        reason & "). Use '" & alternative & "' instead."
    else:
      return code & ": '" & tag & "' is forbidden (" &
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
  if parentKnown and not v.allowedChild(parentTag, tag):
    return v.nestingMsg(tag, parentTag)
  return ""

proc failVocabCheck*(msg: string) {.compileTime.} =
  ## Raise a `checkElement` message as a compile error from inside a
  ## `static:` block. Kept for callers that validate outside `ui`; the
  ## `ui` macro itself does not use it, because a compile-time `error`
  ## prints a VM `stack trace:` ahead of the message and attributes the
  ## error to this module (see the module doc for what `ui` emits instead).
  if msg != "":
    error(msg)

proc setLineInfoDeep(n, src: NimNode) =
  copyLineInfo(n, src)
  for child in n:
    setLineInfoDeep(child, src)

proc errorPragmaAt*(msg: NimNode | string; src: NimNode): NimNode =
  ## `{.error: msg.}` as a statement whose every node carries `src`'s line
  ## info. `msg` is a string literal or a constant string expression. The
  ## compiler reports it as `file(line, col) Error: msg` at `src`, with no
  ## VM stack trace (the pragma is semantic, not evaluated in the VM).
  let msgNode = when msg is string: newStrLitNode(msg) else: msg
  result = newNimNode(nnkPragma).add(
    newNimNode(nnkExprColonExpr).add(ident"error", msgNode))
  setLineInfoDeep(result, src)

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
  # The report sits outside every `try`: a probe failure degrades to the
  # plain unknown-tag error from the sibling check. A hit reports here
  # first (the probe is emitted before the tag check for this); the
  # sibling unknown-tag error still follows, and both are true.
  #
  # Reported by returning an `{.error.}` pragma carrying `src`'s line info
  # rather than calling `error` here: `error` from a macro prints a VM
  # `stack trace:` header naming this module ahead of the message.
  if hit.len > 0:
    result.add errorPragmaAt("E-VOCAB-PROC-AS-ELEMENT: '" & hit &
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
