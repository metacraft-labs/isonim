## Edit one CSS declaration in a stylesheet, in place.
##
## This is the half of a project's edit adapter that is NOT project-specific.
## A workspace whose styles live in CSS rules -- whether in a `.css` file, a
## Nim raw-string const, or a template literal -- has to turn "the inspector
## set `font-size` to `42px` on `.tagline`" into new file content. That
## transformation is the same everywhere; only where the stylesheet lives
## differs, and that part stays with the project.
##
## It is deliberately NOT a CSS parser. It is a scanner that knows three
## things -- comments, brace depth, and where a declaration ends -- because
## those are the three things you must get right to avoid editing the wrong
## text, and everything else a parser would give us we would then have to
## un-parse back into the author's formatting.
##
## Preserving formatting is the point. A patch that reflows the file destroys
## the diff a reviewer needs and, in a stylesheet like the grip pilot's, the
## comments that explain why a value is what it is:
##
##     .tagline { font:var(--sys-type-display);
##                letter-spacing:var(--sys-tracking-display);
##                margin:0 0 30px;         /* OPTICAL: between `block` and
##                                            `section`, tuned to the 40px line */
##                text-wrap:balance; }
##
## Editing `margin` here must leave that comment attached and the other three
## declarations byte-identical.

import std/strutils

type
  CssPatchOutcome* = enum
    cpoReplaced          ## The declaration existed and its value changed.
    cpoInserted          ## The rule existed; the declaration was added to it.
    cpoUnchanged         ## The declaration already held this value.
    cpoRuleNotFound      ## No top-level rule with that selector.
    cpoAmbiguous         ## More than one top-level rule with that selector.

  CssPatchResult* = object
    ok*: bool
    outcome*: CssPatchOutcome
    content*: string     ## The whole stylesheet, patched. Empty unless `ok`.
    oldValue*: string    ## What the declaration held before, "" if inserted.
    message*: string     ## Why, when `ok` is false.

func isIdentChar(c: char): bool =
  c.isAlphaNumeric or c in {'-', '_'}

type RuleSpan = object
  ## Byte offsets of one top-level rule: where its selector starts, and the
  ## span BETWEEN the braces (`bodyStart` inclusive, `bodyEnd` exclusive --
  ## `bodyEnd` is the index of the closing `}`).
  selector: string
  bodyStart: int
  bodyEnd: int

iterator topLevelRules(css: string): RuleSpan =
  ## Every rule at brace depth 0, with its selector text.
  ##
  ## Depth is what keeps `@media` honest. The grip pilot declares
  ## `.site-header` twice -- once at the top level and once inside a
  ## `@media (prefers-color-scheme: dark)` -- and a scan that only looked for
  ## the selector text would patch whichever came first. An at-rule opens a
  ## block at depth 0, so its contents sit at depth 1 and are skipped here.
  var i = 0
  var depth = 0
  var selectorStart = 0
  var pendingSelector = ""
  var bodyStart = -1
  while i < css.len:
    # Comments are scanned first: a `{`, `}` or `;` inside one is text.
    if i + 1 < css.len and css[i] == '/' and css[i + 1] == '*':
      let close = css.find("*/", i + 2)
      i = if close < 0: css.len else: close + 2
      continue
    case css[i]
    of '{':
      if depth == 0:
        pendingSelector = css[selectorStart ..< i].strip()
        bodyStart = i + 1
      depth += 1
      i += 1
    of '}':
      depth -= 1
      if depth == 0 and bodyStart >= 0:
        # An at-rule (`@media`, `@supports`) is a container, not a rule with
        # declarations, so it never yields.
        if not pendingSelector.startsWith("@"):
          yield RuleSpan(selector: pendingSelector, bodyStart: bodyStart,
                         bodyEnd: i)
        bodyStart = -1
      selectorStart = i + 1
      i += 1
    else:
      i += 1

func withoutComments(text: string): string =
  ## Strip `/* ... */` spans. Selector text is everything since the previous
  ## rule closed, which in a commented stylesheet includes that rule's
  ## trailing comment:
  ##
  ##     .hero-argument { align-self:start; }   /* STRUCTURAL */
  ##
  ##     .tagline { font:var(--sys-type-display);
  ##
  ## so `.tagline`'s raw selector text is "/* STRUCTURAL */\n\n  .tagline".
  ## The grip pilot comments nearly every rule that way, which is why this
  ## was invisible in a fixture and total in the real file.
  var i = 0
  while i < text.len:
    if i + 1 < text.len and text[i] == '/' and text[i + 1] == '*':
      let close = text.find("*/", i + 2)
      i = if close < 0: text.len else: close + 2
    else:
      result.add text[i]
      i += 1

func selectorMatches(ruleSelector, wanted: string): bool =
  ## A rule matches when `wanted` is one of its comma-separated selectors.
  ##
  ## Exact, after trimming. `.tagline` must not match `.tagline-clause`, and
  ## a grouped rule (`html,body { ... }`) is a legitimate home for the
  ## declaration when you ask for either of its members.
  for part in ruleSelector.withoutComments().split(','):
    if part.strip() == wanted.strip():
      return true
  false

type DeclSpan = object
  valueStart: int  ## first byte after the `:`
  valueEnd: int    ## exclusive; the `;` or the closing `}`

func findDeclaration(css: string; body: RuleSpan;
                     property: string): DeclSpan =
  ## Locate `property`'s value inside a rule body, or return `valueStart < 0`.
  ##
  ## Matching is anchored on both sides so `font` does not match inside
  ## `font-size`, and `size` does not match inside `font-size` either. That
  ## pair is not hypothetical: the grip pilot's `.tagline` declares the `font`
  ## shorthand, and the inspector's Font size row edits `font-size`.
  result = DeclSpan(valueStart: -1, valueEnd: -1)
  var i = body.bodyStart
  while i < body.bodyEnd:
    if i + 1 < css.len and css[i] == '/' and css[i + 1] == '*':
      let close = css.find("*/", i + 2)
      i = if close < 0 or close > body.bodyEnd: body.bodyEnd else: close + 2
      continue
    if css[i] == property[0] and i + property.len <= body.bodyEnd and
       css[i ..< i + property.len] == property:
      let before = if i == 0: ' ' else: css[i - 1]
      let afterIdx = i + property.len
      let after = if afterIdx < css.len: css[afterIdx] else: ' '
      if not before.isIdentChar and not after.isIdentChar:
        # Only whitespace may sit between the name and its colon.
        var j = afterIdx
        while j < body.bodyEnd and css[j] in {' ', '\t', '\n', '\r'}: j += 1
        if j < body.bodyEnd and css[j] == ':':
          var valueEnd = j + 1
          while valueEnd < body.bodyEnd and css[valueEnd] != ';':
            # A comment inside the value is part of the value's span but must
            # not hide a `;` that follows it.
            if valueEnd + 1 < css.len and css[valueEnd] == '/' and
               css[valueEnd + 1] == '*':
              let close = css.find("*/", valueEnd + 2)
              valueEnd = if close < 0: body.bodyEnd else: close + 2
              continue
            valueEnd += 1
          return DeclSpan(valueStart: j + 1, valueEnd: valueEnd)
    i += 1

func trailingComment(text: string): string =
  ## The `/* ... */` a declaration's value carries after it, if any. It is
  ## kept when the value is replaced: the comment explains the DECLARATION,
  ## not the old number, and dropping it on every edit would strip the
  ## stylesheet's reasoning one property at a time.
  let open = text.find("/*")
  if open < 0: "" else: text[open .. ^1]

proc patchCssDeclaration*(css, selector, property, newValue: string):
    CssPatchResult =
  ## Set `property` to `newValue` inside the top-level rule for `selector`.
  ##
  ## The declaration is replaced where it exists and inserted where it does
  ## not, because the inspector edits properties an author never wrote --
  ## a `font-size` row is offered on a rule that only declares the `font`
  ## shorthand, and refusing there would make most of the panel inert.
  if selector.len == 0 or property.len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "A CSS patch needs both a selector and a property.")

  var matches: seq[RuleSpan] = @[]
  for rule in css.topLevelRules():
    if rule.selector.selectorMatches(selector):
      matches.add rule

  if matches.len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "No top-level rule for `" & selector & "`. The class may be " &
        "declared only inside an at-rule, or in another stylesheet.")
  if matches.len > 1:
    # Refusing beats guessing. Two top-level rules for one selector is a
    # cascade the author built on purpose, and picking one would silently
    # change which of the two wins.
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: $matches.len & " top-level rules declare `" & selector &
        "`. Which one owns `" & property & "` is a decision this patch " &
        "cannot make; edit the stylesheet directly.")

  let rule = matches[0]
  let decl = css.findDeclaration(rule, property)

  if decl.valueStart >= 0:
    let existing = css[decl.valueStart ..< decl.valueEnd]
    let comment = existing.trailingComment()
    let current = (if comment.len > 0: existing[0 ..< existing.find("/*")]
                   else: existing).strip()
    if current == newValue.strip():
      return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                            oldValue: current)
    # One leading space, the value, then whatever comment was there. The
    # surrounding whitespace outside `valueStart .. valueEnd` is untouched,
    # so a multi-line rule keeps its alignment.
    var replacement = newValue.strip()
    if comment.len > 0:
      let gap = existing[existing.find("/*") - 1]
      replacement.add (if gap in {' ', '\t'}: " " else: "")
      replacement.add comment
    return CssPatchResult(ok: true, outcome: cpoReplaced,
      oldValue: current,
      content: css[0 ..< decl.valueStart] & (
        if css[decl.valueStart] in {' ', '\t'}: " " else: "") &
        replacement & css[decl.valueEnd .. ^1])

  # Insert. Placed just after the last existing declaration so the new one
  # reads as part of the rule rather than as an afterthought wedged against
  # the brace, and indented to match its neighbours.
  var insertAt = rule.bodyEnd
  while insertAt > rule.bodyStart and
        css[insertAt - 1] in {' ', '\t', '\n', '\r'}:
    insertAt -= 1
  let needsSemicolon = insertAt > rule.bodyStart and css[insertAt - 1] != ';'
  # A one-line rule stays on one line. Only a rule whose body already spans
  # lines gets the new declaration on its own line, indented to match its
  # neighbours -- which is the alignment the author chose, not a guess.
  var multiLine = false
  for k in rule.bodyStart ..< insertAt:
    if css[k] == '\n':
      multiLine = true
      break
  var indent = ""
  if multiLine:
    var lineStart = insertAt
    while lineStart > 0 and css[lineStart - 1] != '\n': lineStart -= 1
    var k = lineStart
    while k < css.len and css[k] in {' ', '\t'}: k += 1
    indent = css[lineStart ..< k]
  let sep = if multiLine: "\n" & indent else: " "
  CssPatchResult(ok: true, outcome: cpoInserted,
    content: css[0 ..< insertAt] & (if needsSemicolon: ";" else: "") & sep &
      property & ":" & newValue.strip() & ";" & css[insertAt .. ^1])

proc patchCssInNimConst*(nimSource, constName, selector, property,
                         newValue: string): CssPatchResult =
  ## The same edit, for a stylesheet that lives in a Nim raw-string const.
  ##
  ## This is the IsoNim idiom rather than a grip peculiarity: a project that
  ## compiles to both a server and a browser keeps its CSS as a `const` so
  ## the same bytes reach the SSR output and the client, and
  ## `staticRead`ing a `.css` file would put it out of reach of the
  ## compile-time class index. So the adapter of any such project needs to
  ## reach inside the literal, and doing it here means it is done once and
  ## tested once.
  ##
  ## Only the const's own body is handed to the patcher, so a selector that
  ## appears elsewhere in the module -- in a doc comment, in a second
  ## stylesheet, in ordinary code -- is out of range by construction rather
  ## than by a careful regex.
  let decl = "const " & constName & "* = \"\"\""
  var start = nimSource.find(decl)
  var declLen = decl.len
  if start < 0:
    # A non-exported const is still a stylesheet.
    let unexported = "const " & constName & " = \"\"\""
    start = nimSource.find(unexported)
    declLen = unexported.len
  if start < 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "`" & constName & "` is not a raw-string const in this file.")

  let bodyStart = start + declLen
  let bodyEnd = nimSource.find("\"\"\"", bodyStart)
  if bodyEnd < 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "`" & constName & "` has no closing `\"\"\"`.")

  let body = nimSource[bodyStart ..< bodyEnd]
  result = patchCssDeclaration(body, selector, property, newValue)
  if not result.ok or result.outcome == cpoUnchanged:
    # An unchanged patch returns the CSS body as `content`; the caller wants
    # the whole module back either way, so splice it regardless.
    if result.outcome == cpoUnchanged:
      result.content = nimSource
    return
  result.content = nimSource[0 ..< bodyStart] & result.content &
    nimSource[bodyEnd .. ^1]
