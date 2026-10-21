## isonim/content/highlight -- build-time code highlighting through a
## language registry.
##
## A pure, filesystem-free tokenizer (`tokenize`) that turns a fenced
## code block's raw text into a flat sequence of typed `Token`s
## (keyword/string/comment/number/plain). A renderer wraps each non-plain
## token in an element carrying a class for its kind (isonim-docs uses
## `<span class="tok-*">`) and leaves plain runs as bare text, so the
## colours come from the theme's stylesheet: no inline colours and no
## client JS. An unrecognized `lang` degrades to a single `tkPlain`
## token (never crashes, never loses text).
##
## Languages live in a `LanguageRegistry`: a name, its aliases, and a
## `LangSpec` (keywords, comment and string delimiters). `builtinLanguages`
## is the registry every `tokenize(lang, code)` call uses -- Nim, Bash
## (`sh`, `shell`), JSON and TypeScript (`ts`, `tsx`, `js`, `jsx`,
## `javascript`). A consumer that needs more builds its own registry
## from it with `registerLanguage` and calls `tokenize(registry, ...)`;
## there is no mutable global table.
##
## Moved here from isonim-docs (`src/core/syntax_highlight.nim`, which
## now re-exports this module); the scanner is unchanged.

import std/[strutils, sets, tables, algorithm]

type
  TokenKind* = enum
    tkPlain
    tkKeyword
    tkString
    tkComment
    tkNumber

  Token* = object
    kind*: TokenKind
    text*: string

  LangSpec* = object
    ## How one language is scanned.
    keywords*: HashSet[string]
    lineComment*: seq[string] ## e.g. `@["#"]`, empty when the language has none (JSON)
    blockCommentOpen*: string ## empty when the language has no block comments
    blockCommentClose*: string
    stringDelims*: set[char]

  LanguageRegistry* = object
    ## Language specs by canonical (lowercase) name, plus aliases that map
    ## another fence name onto a canonical one. Lookups ignore ASCII case.
    specs: Table[string, LangSpec]
    aliases: Table[string, string]

const
  nimKeywords = toHashSet([
    "addr", "and", "as", "asm", "bind", "block", "break", "case", "cast",
    "concept", "const", "continue", "converter", "defer", "discard",
    "distinct", "div", "do", "elif", "else", "end", "enum", "except",
    "export", "finally", "for", "from", "func", "if", "import", "in",
    "include", "interface", "is", "isnot", "iterator", "let", "macro",
    "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or",
    "out", "proc", "ptr", "raise", "ref", "return", "shl", "shr", "static",
    "template", "try", "tuple", "type", "using", "var", "when", "while",
    "xor", "yield", "true", "false"])

  bashKeywords = toHashSet([
    "if", "then", "elif", "else", "fi", "for", "in", "do", "done",
    "while", "until", "case", "esac", "function", "select", "time",
    "coproc", "return", "break", "continue", "local", "export",
    "readonly", "declare", "unset", "shift", "exit", "eval", "exec",
    "source", "trap", "wait", "true", "false", "let"])

  jsonKeywords = toHashSet(["true", "false", "null"])

  typescriptKeywords = toHashSet([
    "abstract", "any", "as", "asserts", "async", "await", "boolean",
    "break", "case", "catch", "class", "const", "continue", "debugger",
    "declare", "default", "delete", "do", "else", "enum", "export",
    "extends", "false", "finally", "for", "from", "function", "get", "if",
    "implements", "import", "in", "infer", "instanceof", "interface",
    "is", "keyof", "let", "module", "namespace", "never", "new", "null",
    "number", "object", "of", "package", "private", "protected", "public",
    "readonly", "return", "set", "static", "string", "super", "switch",
    "symbol", "this", "throw", "true", "try", "type", "typeof",
    "undefined", "unique", "unknown", "var", "void", "while", "with",
    "yield"])

  nimSpec = LangSpec(keywords: nimKeywords, lineComment: @["#"],
    blockCommentOpen: "", blockCommentClose: "", stringDelims: {'"'})
  bashSpec = LangSpec(keywords: bashKeywords, lineComment: @["#"],
    blockCommentOpen: "", blockCommentClose: "", stringDelims: {'"', '\''})
  jsonSpec = LangSpec(keywords: jsonKeywords, lineComment: @[],
    blockCommentOpen: "", blockCommentClose: "", stringDelims: {'"'})
  typescriptSpec = LangSpec(keywords: typescriptKeywords, lineComment: @["//"],
    blockCommentOpen: "/*", blockCommentClose: "*/", stringDelims: {'"', '\'', '`'})

proc registerLanguage*(reg: var LanguageRegistry; name: string; spec: LangSpec;
                       aliases: openArray[string] = []) =
  ## Adds (or replaces) the language `name`, reachable also through each
  ## of `aliases`. Names and aliases are matched case-insensitively.
  let canonical = name.toLowerAscii
  reg.specs[canonical] = spec
  for a in aliases:
    reg.aliases[a.toLowerAscii] = canonical

proc builtinLanguages*(): LanguageRegistry =
  ## The registry `tokenize(lang, code)` uses: Nim, Bash, JSON and
  ## TypeScript, with the aliases isonim-docs has always accepted
  ## (`ts`/`tsx`/`js`/`jsx`/`javascript` share TypeScript's superset
  ## grammar closely enough for span classification; `sh`/`shell` are
  ## Bash by another fence name).
  result.registerLanguage("nim", nimSpec)
  result.registerLanguage("bash", bashSpec, ["sh", "shell"])
  result.registerLanguage("json", jsonSpec)
  result.registerLanguage("typescript", typescriptSpec,
                          ["ts", "tsx", "js", "jsx", "javascript"])

proc findLangSpec*(reg: LanguageRegistry; lang: string): (bool, LangSpec) =
  ## The spec for `lang` (a name or an alias, any ASCII case), as
  ## `(true, spec)`; `(false, default)` when the registry does not know it.
  let lower = lang.toLowerAscii
  let canonical = reg.aliases.getOrDefault(lower, lower)
  if canonical in reg.specs: (true, reg.specs[canonical])
  else: (false, LangSpec())

proc languages*(reg: LanguageRegistry): seq[string] =
  ## The canonical names the registry knows, sorted.
  for name in reg.specs.keys: result.add name
  result.sort()

proc matchesAt(s: string; i: int; needle: string): bool =
  needle.len > 0 and i + needle.len <= s.len and s[i ..< i + needle.len] == needle

proc scanNumberEnd(code: string; start: int): int =
  ## Returns the end index (exclusive) of the number literal beginning at
  ## `start` -- caller already knows `code[start]` is an ASCII digit.
  var j = start
  if code[j] == '0' and j + 1 < code.len and code[j + 1] in {'x', 'X'}:
    j += 2
    while j < code.len and code[j].isAlphaNumeric: inc j
    return j
  while j < code.len and code[j].isDigit: inc j
  if j < code.len and code[j] == '.' and j + 1 < code.len and code[j + 1].isDigit:
    inc j
    while j < code.len and code[j].isDigit: inc j
  if j < code.len and code[j] in {'e', 'E'}:
    var k = j + 1
    if k < code.len and code[k] in {'+', '-'}: inc k
    if k < code.len and code[k].isDigit:
      j = k
      while j < code.len and code[j].isDigit: inc j
  j

proc scan(code: string; spec: LangSpec): seq[Token] =
  let n = code.len
  var i = 0
  var plainStart = 0

  template flushPlain(upTo: int) =
    if upTo > plainStart:
      result.add Token(kind: tkPlain, text: code[plainStart ..< upTo])

  while i < n:
    block matchSpecial:
      for prefix in spec.lineComment:
        if matchesAt(code, i, prefix):
          flushPlain(i)
          var j = i
          while j < n and code[j] != '\n': inc j
          result.add Token(kind: tkComment, text: code[i ..< j])
          i = j
          plainStart = i
          break matchSpecial

      if matchesAt(code, i, spec.blockCommentOpen):
        flushPlain(i)
        var j = i + spec.blockCommentOpen.len
        while j < n and not matchesAt(code, j, spec.blockCommentClose): inc j
        j = min(n, j + spec.blockCommentClose.len)
        result.add Token(kind: tkComment, text: code[i ..< j])
        i = j
        plainStart = i
        break matchSpecial

      let c = code[i]
      if c in spec.stringDelims:
        flushPlain(i)
        var j = i + 1
        while j < n and code[j] != c:
          if code[j] == '\\' and j + 1 < n: j += 2
          else: inc j
        j = min(n, j + 1) # include the closing delimiter, if any
        result.add Token(kind: tkString, text: code[i ..< j])
        i = j
        plainStart = i
        break matchSpecial

      if c.isDigit:
        flushPlain(i)
        let j = scanNumberEnd(code, i)
        result.add Token(kind: tkNumber, text: code[i ..< j])
        i = j
        plainStart = i
        break matchSpecial

      if c.isAlphaAscii or c == '_':
        var j = i
        while j < n and (code[j].isAlphaNumeric or code[j] == '_'): inc j
        let word = code[i ..< j]
        if word in spec.keywords:
          flushPlain(i)
          result.add Token(kind: tkKeyword, text: word)
          plainStart = j
        i = j
        break matchSpecial

      inc i

  flushPlain(n)

proc tokenize*(reg: LanguageRegistry; lang: string; code: string): seq[Token] =
  ## Splits `code` into typed spans for `lang`, looked up in `reg`.
  ## Unrecognized/empty `lang` degrades to one `tkPlain` token holding the
  ## whole text unchanged -- a renderer must never crash or drop content
  ## over an unknown fence-info string.
  let (known, spec) = reg.findLangSpec(lang)
  if not known:
    return if code.len > 0: @[Token(kind: tkPlain, text: code)] else: @[]
  scan(code, spec)

const builtinRegistry = builtinLanguages()
  ## Evaluated at compile time, like the language specs it holds, so the
  ## two-argument `tokenize` touches no mutable or GC-managed global.

proc tokenize*(lang: string; code: string): seq[Token] =
  ## `tokenize` over `builtinLanguages()`.
  tokenize(builtinRegistry, lang, code)
