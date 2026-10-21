## isonim/content/highlight -- the build-time tokenizer and its language
## registry. Dual-target: `nim c -r` and `nim js -r` must both pass.
##
## The first suite is isonim-docs' tokenizer suite, moved unchanged with
## the module: `tokenize` classifies keywords/strings/comments/numbers
## into typed spans for nim/bash/json/typescript, and an unknown language
## degrades to a single plain token instead of crashing. The second
## covers the registry the module now exposes. No test doubles.

import std/[unittest, strutils, sets]
import isonim/content/highlight

suite "isonim/content/highlight -- tokenize":
  test "nim: classifies a keyword, a string, and a line comment as distinct typed tokens":
    let tokens = tokenize("nim", "let x = \"hi\" # note")
    let kinds = block:
      var ks: seq[TokenKind] = @[]
      for t in tokens: ks.add t.kind
      ks
    check tkKeyword in kinds
    check tkString in kinds
    check tkComment in kinds

    let keywordTok = block:
      var found = Token(kind: tkPlain, text: "")
      for t in tokens:
        if t.kind == tkKeyword: found = t
      found
    check keywordTok.text == "let"

    let stringTok = block:
      var found = Token(kind: tkPlain, text: "")
      for t in tokens:
        if t.kind == tkString: found = t
      found
    check stringTok.text == "\"hi\""

    let commentTok = block:
      var found = Token(kind: tkPlain, text: "")
      for t in tokens:
        if t.kind == tkComment: found = t
      found
    check commentTok.text == "# note"

  test "nim: reassembling every token's text round-trips the original source exactly":
    let src = "proc add(a, b: int): int =\n  # sum two ints\n  result = a + b"
    let tokens = tokenize("nim", src)
    var rebuilt = ""
    for t in tokens: rebuilt.add t.text
    check rebuilt == src

  test "json: classifies object-key/value strings, numbers, and the null/true/false keywords":
    let tokens = tokenize("json", "{\"a\": 1, \"b\": true, \"c\": null}")
    var sawString, sawNumber, sawKeyword = false
    for t in tokens:
      case t.kind
      of tkString: sawString = true
      of tkNumber: sawNumber = true
      of tkKeyword: sawKeyword = true
      else: discard
    check sawString and sawNumber and sawKeyword

  test "bash: classifies control-flow keywords and a double-quoted string, ignores plain command words":
    let tokens = tokenize("bash", "if [ -f x ]; then\n  echo \"hi\"\nfi")
    var keywords: seq[string] = @[]
    var sawString = false
    for t in tokens:
      if t.kind == tkKeyword: keywords.add t.text
      if t.kind == tkString: sawString = true
    check "if" in keywords
    check "then" in keywords
    check "fi" in keywords
    check sawString

  test "typescript: classifies keywords, a string, and both line and block comments":
    let tokens = tokenize("typescript", "// leading\nconst x: string = \"hi\"; /* trailing */")
    var sawLineComment, sawBlockComment, sawKeyword, sawString = false
    for t in tokens:
      if t.kind == tkComment and t.text.startsWith("//"): sawLineComment = true
      if t.kind == tkComment and t.text.startsWith("/*"): sawBlockComment = true
      if t.kind == tkKeyword and t.text == "const": sawKeyword = true
      if t.kind == tkString: sawString = true
    check sawLineComment
    check sawBlockComment
    check sawKeyword
    check sawString

  test "an unrecognized language degrades to a single plain token, never crashes, and preserves the text":
    let src = "some <weird> & unknown syntax"
    let tokens = tokenize("cobol", src)
    check tokens.len == 1
    check tokens[0].kind == tkPlain
    check tokens[0].text == src

  test "an empty fence body tokenizes to no tokens, for both a known and an unknown language":
    check tokenize("nim", "").len == 0
    check tokenize("cobol", "").len == 0

  test "an unterminated string in a known language does not crash and consumes to end of input":
    let tokens = tokenize("nim", "let x = \"never closed")
    check tokens.len > 0
    check tokens[^1].kind == tkString
    check tokens[^1].text == "\"never closed"

suite "isonim/content/highlight -- the language registry":
  test "the built-in registry knows nim, bash, json and typescript, and their aliases":
    let reg = builtinLanguages()
    check reg.languages == @["bash", "json", "nim", "typescript"]
    for alias in ["sh", "shell", "ts", "tsx", "js", "jsx", "javascript", "NIM", "Bash"]:
      check reg.findLangSpec(alias)[0]
    check not reg.findLangSpec("rust")[0]
    check not reg.findLangSpec("")[0]

  test "an alias tokenizes exactly like its canonical language":
    let code = "const x = \"s\" // c"
    check tokenize("js", code) == tokenize("typescript", code)
    check tokenize("TS", code) == tokenize("typescript", code)

  test "registerLanguage extends a copy of the registry; the built-in one is untouched":
    var reg = builtinLanguages()
    reg.registerLanguage("toml", LangSpec(keywords: toHashSet(["true", "false"]),
      lineComment: @["#"], stringDelims: {'"', '\''}), aliases = ["TOML-file"])
    let toks = reg.tokenize("toml-file", "a = true # c")
    check toks == @[Token(kind: tkPlain, text: "a = "),
                    Token(kind: tkKeyword, text: "true"),
                    Token(kind: tkPlain, text: " "),
                    Token(kind: tkComment, text: "# c")]
    # The two-argument form still uses only the built-in languages.
    check tokenize("toml", "a = true # c") ==
      @[Token(kind: tkPlain, text: "a = true # c")]
    check "toml" in reg.languages
    check "toml" notin builtinLanguages().languages

  test "registering an existing name replaces its spec":
    var reg = builtinLanguages()
    reg.registerLanguage("nim", LangSpec(keywords: toHashSet(["foo"])))
    check reg.tokenize("nim", "proc foo") == @[Token(kind: tkPlain, text: "proc "),
                                              Token(kind: tkKeyword, text: "foo")]
