## isonim/theming/dtcg -- a content-agnostic W3C DTCG design-token
## loader and alias resolver.
##
## Reads one or more W3C DTCG (Design Tokens Community Group) token JSON
## documents -- e.g. a `brand` / `alias` / `mapped` layering -- merges
## them into a single flat token table keyed by dotted path, and resolves
## `{group.token}` alias references across every loaded layer down to a
## concrete primitive value. The format is the Design Tokens Community
## Group's (https://tr.designtokens.org/format/): token leaves carry
## `$type` and `$value`, and aliases are `{dotted.path}` strings
## (https://tr.designtokens.org/format/#aliases-references).
##
## This module bakes in no consumer specifics: it knows only the DTCG
## shape (`{"$type": ..., "$value": ...}` leaves, nested groups, and the
## `{dotted.path}` alias syntax), so it consumes any DTCG document set.
## It is pure `std/json` + `std/tables` string work, so it compiles and
## runs identically on the C and JS targets (only `loadTokens`, which
## reads files, is unavailable on JS, and it says so).
##
## Moved here unchanged from isonim-docs (`src/core/tokens.nim`, which
## now re-exports this module), so that every IsoNim consumer of design
## tokens -- documentation sites, blogs and HTML email -- resolves them
## with one implementation.

import std/[json, tables, strutils, sets]

type
  TokenError* = object of CatchableError
    ## Raised for a structurally-broken token graph: a `{alias}` that
    ## points at no token (dangling), or a reference cycle.

  TokenCategory* = enum
    ## The coarse, DTCG-`$type`-derived category of a resolved token, so a
    ## consumer can drive a typed token model (color / type / spacing /
    ## radius / shadow, ...) without re-parsing the raw `$type` string.
    tcColor = "color"
    tcDimension = "dimension"
    tcFontFamily = "fontFamilies"
    tcFontSize = "fontSizes"
    tcFontWeight = "fontWeights"
    tcLineHeight = "lineHeights"
    tcLetterSpacing = "letterSpacing"
    tcParagraphSpacing = "paragraphSpacing"
    tcNumber = "number"
    tcText = "text"
    tcTextCase = "textCase"
    tcTextDecoration = "textDecoration"
    tcShadow = "shadow"
    tcTypography = "typography"
    tcOther = "other"

  RawToken = object
    ## One DTCG leaf, before alias resolution: its declared `$type` (may
    ## be empty when a document leans on group-level type inheritance) and
    ## its raw `$value` node (a concrete scalar, a `{alias}` string, or a
    ## composite object such as a `typography` token).
    typ: string
    value: JsonNode

  TokenSet* = object
    ## The merged, still-unresolved token universe: every DTCG leaf from
    ## every loaded layer, flattened to its dotted path. Later layers may
    ## reference earlier ones (and vice-versa) -- resolution walks the
    ## whole merged set, so cross-layer `brand -> alias -> mapped` chains
    ## resolve regardless of which document each hop lives in.
    nodes: Table[string, RawToken]

  ResolvedToken* = object
    ## A token flattened to its concrete primitive: the fully-resolved
    ## scalar `value`, its dotted `key`, and its coarse `category`.
    key*: string
    category*: TokenCategory
    value*: string

proc toCategory(typ: string): TokenCategory =
  for c in TokenCategory:
    if $c == typ: return c
  tcOther

proc isAlias(v: JsonNode): bool =
  ## A DTCG alias is a string whose entire body is `{dotted.path}`.
  v.kind == JString and v.getStr.startsWith("{") and v.getStr.endsWith("}")

proc aliasTarget(v: JsonNode): string =
  let s = v.getStr
  s[1 ..< s.len - 1]

proc scalarToString(v: JsonNode): string =
  ## Renders a concrete (non-alias) DTCG `$value` primitive to the string
  ## a CSS emitter would use. Composite object values (e.g. a `typography`
  ## token) are returned as compact JSON so the resolver never silently
  ## drops information; scalar callers simply don't ask for those.
  case v.kind
  of JString: v.getStr
  of JInt: $v.getInt
  of JFloat:
    let f = v.getFloat
    if f == f.int.float: $f.int else: $f
  of JBool: $v.getBool
  of JNull: ""
  else: $v

proc addLayer(ts: var TokenSet, node: JsonNode, prefix: string) =
  ## Recursively flattens one DTCG document into `ts.nodes`. A node with a
  ## `$value` is a token leaf; any other object is a group whose non-`$`
  ## keys are recursed into. `$`-prefixed metadata keys ($extensions,
  ## $description, ...) are ignored.
  if node.kind != JObject: return
  if node.hasKey("$value"):
    let typ = if node.hasKey("$type"): node["$type"].getStr else: ""
    ts.nodes[prefix] = RawToken(typ: typ, value: node["$value"])
    return
  for key, child in node:
    if key.startsWith("$"): continue
    let childPath = if prefix.len == 0: key else: prefix & "." & key
    addLayer(ts, child, childPath)

proc loadTokens*(paths: varargs[string]): TokenSet =
  ## Loads and merges every DTCG JSON file in `paths` (the intended use:
  ## the `brand`, `alias`, and `mapped` layer files, in any order) into a
  ## single resolvable `TokenSet`.
  result.nodes = initTable[string, RawToken]()
  when defined(js):
    # The JS target has no filesystem and `std/json.parseFile` is C-only;
    # referencing it would break this module's promised JS-compilability
    # (see the file header). Runtime paths can't be `staticRead`, so JS
    # callers must embed token JSON at compile time (`staticRead`) and use
    # `loadTokensFromStrings`. The C-target path below is unchanged.
    raise newException(TokenError,
      "loadTokens requires a filesystem and is unavailable on the JS target; " &
      "embed the token JSON at compile time (staticRead) and use loadTokensFromStrings")
  else:
    for p in paths:
      addLayer(result, parseFile(p), "")

proc loadTokensFromStrings*(jsons: openArray[string]): TokenSet =
  ## Same as `loadTokens` but from in-memory JSON strings -- used by tests
  ## and by consumers that assemble token documents at runtime.
  result.nodes = initTable[string, RawToken]()
  for s in jsons:
    addLayer(result, parseJson(s), "")

proc contains*(ts: TokenSet, key: string): bool =
  ## Whether a token with the given dotted path exists in the merged set.
  key in ts.nodes

proc len*(ts: TokenSet): int = ts.nodes.len

proc categoryOf*(ts: TokenSet, key: string): TokenCategory =
  ## The coarse category of the token at `key` (errors if absent).
  if key notin ts.nodes:
    raise newException(TokenError, "unknown token: '" & key & "'")
  toCategory(ts.nodes[key].typ)

proc resolve*(ts: TokenSet, key: string): string =
  ## Resolves `key` to its concrete primitive value, following any
  ## `{alias}` chain across every loaded layer.
  ##
  ## Raises `TokenError` if the path (or any hop along the chain) points
  ## at a token that does not exist (dangling reference), or if the chain
  ## loops back on itself (cyclic reference).
  var visiting = initHashSet[string]()
  proc walk(k: string): string =
    if k notin ts.nodes:
      raise newException(TokenError,
        "dangling token reference: '" & k & "' does not resolve to any token")
    if k in visiting:
      raise newException(TokenError,
        "cyclic token reference detected at '" & k & "'")
    visiting.incl k
    let raw = ts.nodes[k]
    result =
      if isAlias(raw.value): walk(aliasTarget(raw.value))
      else: scalarToString(raw.value)
    visiting.excl k
  walk(key)

proc resolveToken*(ts: TokenSet, key: string): ResolvedToken =
  ## Resolves `key` and returns it as a typed `ResolvedToken` (value +
  ## category). Convenience over `resolve` for callers building a typed
  ## token model.
  ResolvedToken(key: key, category: ts.categoryOf(key), value: ts.resolve(key))

iterator keys*(ts: TokenSet): string =
  ## Every dotted token path in the merged set (unordered).
  for k in ts.nodes.keys: yield k
