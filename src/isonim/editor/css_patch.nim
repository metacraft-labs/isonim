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
    cpoRemoved           ## The one owning declaration was removed.
    cpoUnreadable        ## The value holds an unterminated comment, string
                         ## or `url(`; refused, nothing written.

  CssPatchResult* = object
    ok*: bool
    outcome*: CssPatchOutcome
    content*: string     ## The whole stylesheet, patched. Empty unless `ok`.
    oldValue*: string    ## What the declaration held before, "" if inserted.
    message*: string     ## Why, when `ok` is false.

  CssBreakpoint* = object
    ## A width-based `@media` block the stylesheet actually defines.
    ##
    ## Extracted from the stylesheet rather than configured, because a
    ## configured list is a second place for the truth to live and the two
    ## drift the first time somebody adds a query. The editor shows these to
    ## say which one it is editing in, so a wrong list is a wrong promise.
    condition*: string   ## The prelude, verbatim: `@media (max-width:1080px)`.
    minWidth*: int       ## -1 when unbounded below.
    maxWidth*: int       ## -1 when unbounded above.

  CssEditTarget* = object
    ## Which rule an edit should be written into, at a given viewport width.
    found*: bool
    condition*: string   ## The at-rule prelude, "" for the base rule.
    selector*: string
    isBreakpoint*: bool  ## True when `condition` is non-empty.
    reason*: string      ## Why this rule, in one sentence, for the UI; when
                         ## `undecided`, why no rule can be named.
    undecided*: bool     ## No rule is named (`found` is false): a rule under
                         ## a condition this cannot evaluate at the width
                         ## would decide the property whenever it holds.
    ruleStart: int       ## The chosen rule's `bodyStart`, -1 for none.
    decides: bool        ## The chosen rule declares the property (it is not
                         ## only the base rule a new declaration would go to).

  CssConditionAnswer* = object
    ## The preview's own answer for one of the stylesheet's conditions: its
    ## `matchMedia(…).matches` for a `@media` prelude, its `CSS.supports(…)`
    ## for a `@supports` one. ``condition`` is the prelude as the stylesheet
    ## writes it (`editConditions`), compared with whitespace collapsed.
    condition*: string
    holds*: bool

  CssShadow* = object
    ## A LATER rule that overrides the declaration a patch just wrote.
    ##
    ## Why this exists. The inspector edits longhands; stylesheets are written
    ## in shorthands. grip declares `.tagline { font: var(--sys-type-display) }`
    ## at the top level and redeclares `.tagline { font: ... }` inside
    ## `@media (max-width:1080px)`. Writing `font-size:50px` into the top-level
    ## rule is a correct patch that has NO EFFECT below 1080px, because the
    ## media rule comes later at equal specificity and its `font` shorthand
    ## resets `font-size`.
    ##
    ## That combination -- the file changed, the save succeeded, the page did
    ## not move -- is the single most confusing thing this editor can do, and
    ## it is indistinguishable from a broken save unless somebody says so.
    ## This type is how the adapter says so.
    found*: bool
    byProperty*: string  ## The winning declaration: `font`, or `font-size`.
    condition*: string   ## Enclosing at-rule prelude, "" at the top level.
    selector*: string    ## The later rule's selector, as written.

func splitCssPriority*(value: string): tuple[value: string; important: bool] =
  ## ``value`` without a trailing `!important`, and whether it had one. CSS
  ## allows whitespace between `!` and `important`, and either case
  ## (https://www.w3.org/TR/css-syntax-3/#consume-declaration).
  let text = value.strip()
  let lower = text.toLowerAscii()
  if lower.endsWith("important"):
    var at = text.len - "important".len - 1
    while at >= 0 and text[at] in Whitespace: dec at
    if at >= 0 and text[at] == '!':
      return (text[0 ..< at].strip(), true)
  (text, false)

type CssValueParts = object
  ## A declaration's text between its `:` and its `;`, cut where CSS reads
  ## it (https://www.w3.org/TR/css-syntax-3/): a comment runs from `/*` to
  ## the FIRST `*/` and does not nest; `/*` inside a quoted string is text.
  ## The parts, concatenated, are the text as written.
  lead: string       ## whitespace and comments before the first token
  value: string      ## first token .. last token before the priority
  gap: string        ## whitespace and comments between value and `!`
  priority: string   ## `!` .. `important`, with whatever it holds
  trail: string      ## whitespace and comments after the last token
  important: bool

type CssValueLex = object
  tokens: seq[int]    ## indices that are part of a token
  comments: seq[tuple[first, last: int]]  ## each comment, inclusive
  unterminated: string  ## "" or what runs to the end unclosed

func lexCssValue(text: string): CssValueLex =
  ## Read a declaration's value as CSS Syntax does
  ## (https://www.w3.org/TR/css-syntax-3/#tokenization): a comment runs from
  ## `/*` to the FIRST `*/` and does not nest; a quoted string, and an
  ## unquoted `url(...)`, are one token whatever they hold (`/*` included);
  ## a backslash escapes the character after it, inside a string or not.
  ## A comment, string or `url(` with no end is reported, not guessed at:
  ## a writer cannot tell where such a value stops.
  var i = 0
  template escape() =
    result.tokens.add i
    if i + 1 < text.len: result.tokens.add i + 1
    i += 2
  while i < text.len:
    let c = text[i]
    if c == '\\':
      escape()
    elif c in {'"', '\''}:
      result.tokens.add i
      inc i
      var closed = false
      while i < text.len:
        if text[i] == '\\': escape(); continue
        if text[i] == '\n': break            # a newline ends a bad string
        result.tokens.add i
        inc i
        if text[i - 1] == c:
          closed = true
          break
      if not closed: result.unterminated = "string"
    elif c == '/' and i + 1 < text.len and text[i + 1] == '*':
      let close = text.find("*/", i + 2)
      if close < 0:
        result.comments.add (first: i, last: text.high)
        result.unterminated = "comment"
        i = text.len
      else:
        result.comments.add (first: i, last: close + 1)
        i = close + 2
    elif c in Whitespace:
      inc i
    elif c in {'u', 'U'} and i + 3 < text.len and
        text[i .. i + 3].toLowerAscii() == "url(" and
        (i == 0 or not (text[i - 1].isAlphaNumeric or text[i - 1] in {'-', '_', '\\'})):
      var j = i + 4
      while j < text.len and text[j] in Whitespace: inc j
      for k in i .. i + 3: result.tokens.add k
      i += 4
      if j < text.len and text[j] in {'"', '\''}:
        continue                             # url("..."): a function
      # An unquoted url: one token up to its `)`.
      var closed = false
      while i < text.len:
        if text[i] == '\\': escape(); continue
        if text[i] notin Whitespace: result.tokens.add i
        inc i
        if text[i - 1] == ')':
          closed = true
          break
      if not closed: result.unterminated = "url("
    else:
      result.tokens.add i
      inc i

func scanCssValue(text: string): seq[int] =
  ## The indices of ``text`` that are part of a token (`lexCssValue`).
  text.lexCssValue().tokens

func commentSpans(text: string): seq[tuple[first, last: int]] =
  ## Where each comment of ``text`` is (`first` .. `last` inclusive).
  text.lexCssValue().comments

func cssValueParts(text: string): CssValueParts =
  let tokens = text.scanCssValue()
  if tokens.len == 0:
    result.lead = text
    return
  result.lead = text[0 ..< tokens[0]]
  const word = "important"
  let n = tokens.len
  var valueEnd = tokens[^1]           # inclusive
  if n >= word.len + 1 and tokens[^1] - tokens[n - word.len] == word.high and
      text[tokens[n - word.len] .. tokens[^1]].toLowerAscii() == word and
      text[tokens[n - word.len - 1]] == '!':
    let bang = tokens[n - word.len - 1]
    result.important = true
    result.priority = text[bang .. tokens[^1]]
    if n > word.len + 1:
      valueEnd = tokens[n - word.len - 2]
      result.value = text[tokens[0] .. valueEnd]
      result.gap = text[valueEnd + 1 ..< bang]
    else:
      result.lead = text[0 ..< bang]
  else:
    result.value = text[tokens[0] .. valueEnd]
  result.trail = text[tokens[^1] + 1 .. ^1]

func withoutCssComments(text: string): string =
  ## ``text`` with its comments removed; a comment between two tokens leaves
  ## one space, as CSS reads it, and no run of spaces is left behind.
  var at = 0
  for span in text.commentSpans():
    result.add text[at ..< span.first]
    var next = span.last + 1
    let before = result.len > 0 and result[^1] notin Whitespace
    while next < text.len and text[next] in Whitespace: inc next
    if before and next < text.len: result.add ' '
    at = next
  result.add text[at .. ^1]
  result = result.strip()

func cssDeclarationValue*(existing: string): string =
  ## A declaration's value as written, with its priority: the text between
  ## its `:` and its `;` without the whitespace and comments around it. It
  ## is what a patch reports as `oldValue`, and writing it back with
  ## `cssValueEdit` restores the declaration byte for byte.
  let parts = existing.cssValueParts()
  (parts.value & parts.gap & parts.priority).strip()

func cssValueWithoutPriority*(declared: string): string =
  ## ``declared``'s value as an inspector field shows it: `cssDeclarationValue`
  ## without its `!important`. The field takes a value without a priority (a
  ## typed `!important` is refused) and a value edit keeps the declaration's
  ## priority (`cssValueEdit`), so the shown value is what can be committed
  ## back.
  let parts = declared.strip().cssValueParts()
  if parts.important: parts.value.strip() else: declared.cssDeclarationValue()

func cssPrioritySuffix*(value: string): string =
  ## The `!important` that ends ``value``, exactly as written: from the
  ## whitespace before its `!` to the end, with any comment inside or after
  ## it (`" !important"`, `" ! IMPORTANT"`, `" !important /* why */"`), or ""
  ## when the value states no priority. CSS allows whitespace and comments
  ## between `!` and `important`, and either case
  ## (https://www.w3.org/TR/css-syntax-3/#consume-declaration).
  let parts = value.cssValueParts()
  if not parts.important: return
  var gap = parts.gap
  # Only the whitespace right before `!` belongs to the suffix; a comment
  # before that is the value's.
  var k = gap.len
  while k > 0 and gap[k - 1] in Whitespace: dec k
  if parts.value.len == 0: gap = "" else: gap = gap[k .. ^1]
  (gap & parts.priority & parts.trail).strip(leading = false)

func cssValueEdit*(existing, newValue: string):
    tuple[unchanged: bool; text, refusal: string] =
  ## The text a value edit writes in place of a declaration's ``existing``
  ## text (between its `:` and its `;`), without surrounding whitespace.
  ##
  ## * The declaration keeps its `!important` as written (spacing, case,
  ##   comments) when ``newValue`` states no priority, and gains none when
  ##   it has none. Why: a value edit changes the value, not the priority.
  ##   The inspector shows and takes a value without its priority (a typed
  ##   `!important` is refused), and the preview applies the edit keeping
  ##   the declaration's priority and adding none; a writer that dropped it
  ##   would write a file whose cascade differs from what the preview shows
  ##   (editor spec "Visual box model": the preview shows the same values
  ##   before the write and after it; "Saving": an edit changes the one
  ##   declaration that owns the property).
  ## * A ``newValue`` that states a priority (an undo putting back text a
  ##   write replaced, `cssDeclarationValue`) is written as given.
  ## * Comments before the value, between it and its priority, inside the
  ##   priority and after it stay where they are: such a comment explains
  ##   the DECLARATION, not the old number, and dropping it on every edit
  ##   would strip the stylesheet's reasoning one property at a time. A
  ##   comment between the parts of the value (`8px /* mid */ 4px`) is part
  ##   of the value being replaced and goes with it; the old value reported
  ##   for undo (`cssDeclarationValue`) holds it, so an undo puts it back
  ##   exactly.
  ## * ``unchanged`` when the result says what ``existing`` says, comments
  ##   aside.
  ## * ``refusal`` says why nothing may be written when either value holds
  ##   a comment, string or `url(` that is never closed (`lexCssValue`):
  ##   where such a value ends cannot be told, and a write around it could
  ##   leave the file with an unterminated comment.
  let given = newValue.strip()
  for (which, text) in [("declaration's value", existing), ("new value", given)]:
    let open = text.lexCssValue().unterminated
    if open.len > 0:
      result.refusal = "The " & which & " `" & text.strip() & "` holds an " &
        "unterminated " & (if open == "url(": "`url(`" else: open) &
        ", so where it ends cannot be told. Nothing was written; edit the " &
        "stylesheet directly."
      return
  let parts = existing.strip().cssValueParts()
  let stated = given.cssValueParts()
  var body = given
  if not stated.important and parts.important:
    body.add parts.gap & parts.priority
  result.text = parts.lead & body & parts.trail
  result.unchanged = result.text == existing.strip() or
    result.text.withoutCssComments() == existing.strip().withoutCssComments()

func cssValueMatches*(declared, expected: string): bool =
  ## Whether a declaration whose text is ``declared`` holds the value
  ## ``expected``: the same value, comments aside, or -- for an ``expected``
  ## that states no priority, as the inspector shows a value -- the same
  ## value once ``declared``'s `!important` is set aside.
  let want = expected.withoutCssComments()
  if declared.cssDeclarationValue().withoutCssComments() == want: return true
  let parts = declared.cssValueParts()
  parts.important and not expected.cssValueParts().important and
    parts.value.withoutCssComments() == want

func isIdentChar(c: char): bool =
  c.isAlphaNumeric or c in {'-', '_'}

type RuleSpan = object
  ## Byte offsets of one top-level rule: where its selector starts, and the
  ## span BETWEEN the braces (`bodyStart` inclusive, `bodyEnd` exclusive --
  ## `bodyEnd` is the index of the closing `}`).
  selector: string
  bodyStart: int
  bodyEnd: int

func scanCssOpaque(css: string; at: int; limit = -1):
    tuple[past: int; closed: bool] =
  ## Past the comment, quoted string, escaped character or unquoted
  ## `url(...)` token that starts at ``at`` (``past`` is ``at`` when none
  ## does): text in which a `{`, `}`, `;`, quote or `/*` is not syntax. The
  ## rules are `lexCssValue`'s, CSS Syntax's: a comment ends at the first
  ## `*/`, a newline ends a (bad) string, a backslash escapes the next
  ## character. ``closed`` is false when the construct runs to ``limit`` (the
  ## end of ``css`` by default) without its end, as CSS lets one run to the
  ## end of the sheet.
  let stop = if limit < 0: css.len else: limit
  let c = css[at]
  if c == '\\':
    return (min(at + 2, stop), true)
  if c in {'"', '\''}:
    var i = at + 1
    while i < stop:
      if css[i] == '\\': i += 2; continue
      if css[i] == c: return (i + 1, true)
      if css[i] == '\n': return (i, true)    # a bad string ends here
      inc i
    return (stop, false)
  if c == '/' and at + 1 < stop and css[at + 1] == '*':
    let close = css.find("*/", at + 2)
    return if close < 0 or close + 2 > stop: (stop, false) else: (close + 2, true)
  if c in {'u', 'U'} and at + 3 < stop and
      css[at .. at + 3].toLowerAscii() == "url(" and
      (at == 0 or not (css[at - 1].isAlphaNumeric or css[at - 1] in {'-', '_', '\\'})):
    var i = at + 4
    while i < stop and css[i] in Whitespace: inc i
    if i < stop and css[i] in {'"', '\''}: return (at, true)  # url("..."): a function
    while i < stop:
      if css[i] == '\\': i += 2; continue
      if css[i] == ')': return (i + 1, true)
      inc i
    return (stop, false)
  (at, true)

func skipCssOpaque*(css: string; at: int; limit = -1): int =
  ## `scanCssOpaque`'s end alone.
  css.scanCssOpaque(at, limit).past

func cssOpenTail*(css: string): tuple[at: int; what: string] =
  ## Where the part of stylesheet ``css`` that only its end closes begins,
  ## or ``at`` = -1. CSS Syntax closes at the end of the sheet whatever is
  ## still open there -- blocks, a comment, a string, a `url(` -- and a
  ## browser applies what came before it as written. So the sheet is read
  ## that way, and only a write AT or AFTER that point is ambiguous: it would
  ## land inside the construct the end of the sheet closes, where the
  ## author's text does not say what it belongs to (`cssWriteRefusal`).
  var open: seq[int] = @[]
  var i = 0
  while i < css.len:
    let scanned = css.scanCssOpaque(i)
    if scanned.past > i:
      if not scanned.closed:
        let what =
          if css[i] in {'"', '\''}: "string"
          elif css[i] == '/': "comment"
          else: "`url(`"
        return (at: (if open.len > 0: open[0] else: i),
          what: (if open.len > 0: "block" else: what))
      i = scanned.past
      continue
    if css[i] == '{': open.add i
    elif css[i] == '}' and open.len > 0: discard open.pop()
    inc i
  if open.len > 0: return (at: open[0], what: "block")
  (at: -1, what: "")

func cssWriteRefusal(css: string; patched: CssPatchResult): CssPatchResult =
  ## ``patched`` unless its write changes ``css`` at or after the point only
  ## the end of the sheet closes (`cssOpenTail`); then a refusal with the
  ## reason. A write before that point is the one a browser reads as written.
  if patched.ok and patched.content == css: return patched
  if not patched.ok and patched.outcome != cpoRuleNotFound: return patched
  let tail = css.cssOpenTail()
  if tail.at < 0: return patched
  if not patched.ok:
    # Not found: say what may be hiding it.
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: patched.message & " The stylesheet has a " & tail.what &
        " that is never closed (only the end of the sheet closes it); a " &
        "rule after its start is inside it, so it is not edited here.")
  var first = 0
  while first < css.len and first < patched.content.len and
      css[first] == patched.content[first]: inc first
  if first < tail.at: return patched
  CssPatchResult(ok: false, outcome: cpoUnreadable,
    message: "This write would land inside a " & tail.what & " that is " &
      "never closed in the stylesheet (only the end of the sheet closes it), " &
      "so what the new text would belong to cannot be told. Nothing was " &
      "written; close the " & tail.what & " in the stylesheet first.")

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
    # Comments, strings, escapes and unquoted urls are scanned first: a
    # `{`, `}` or `;` inside one is text (`skipCssOpaque`).
    let past = css.skipCssOpaque(i)
    if past > i:
      i = past
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
    of ';':
      # At depth 0 a `;` ends an at-statement (`@layer a, b;`, `@import …;`),
      # which is not part of the next rule's selector.
      if depth == 0: selectorStart = i + 1
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
  ## A `/*` inside a string or an unquoted url (`[title="/*"]`) is text.
  var i = 0
  while i < text.len:
    let past = text.skipCssOpaque(i)
    if past > i:
      if not (text[i] == '/' and i + 1 < text.len and text[i + 1] == '*'):
        result.add text[i ..< past]
      i = past
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
  nameStart: int   ## first byte of the property name
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
  result = DeclSpan(nameStart: -1, valueStart: -1, valueEnd: -1)
  var i = body.bodyStart
  while i < body.bodyEnd:
    # Comments, strings, escapes and unquoted urls are never a name.
    let past = css.skipCssOpaque(i, body.bodyEnd)
    if past > i:
      i = past
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
            # A comment, string, escape or unquoted url inside the value is
            # part of the value's span; a `;` inside one does not end it.
            let past = css.skipCssOpaque(valueEnd, body.bodyEnd)
            valueEnd = if past > valueEnd: past else: valueEnd + 1
          return DeclSpan(nameStart: i, valueStart: j + 1, valueEnd: valueEnd)
    i += 1

const shorthandsFor: seq[(string, seq[string])] = @[
  # Longhand -> the shorthands that set it, and therefore reset it.
  #
  # Not exhaustive, and it does not need to be: a missing entry costs a
  # warning that was not raised, never a wrong patch. It covers the shorthands
  # this stylesheet actually uses and the longhands the inspector actually
  # offers, which is where the confusion is real. Add to it when a new pair
  # bites, and add the fixture with it.
  ("font-size", @["font"]),
  ("font-family", @["font"]),
  ("font-weight", @["font"]),
  ("font-style", @["font"]),
  ("font-variant", @["font"]),
  ("font-stretch", @["font"]),
  ("line-height", @["font"]),
  ("margin-top", @["margin"]),
  ("margin-right", @["margin"]),
  ("margin-bottom", @["margin"]),
  ("margin-left", @["margin"]),
  ("padding-top", @["padding"]),
  ("padding-right", @["padding"]),
  ("padding-bottom", @["padding"]),
  ("padding-left", @["padding"]),
  ("background-color", @["background"]),
  ("background-image", @["background"]),
  ("background-position", @["background"]),
  ("background-size", @["background"]),
  ("background-repeat", @["background"]),
  ("border-width", @["border"]),
  ("border-style", @["border"]),
  ("border-color", @["border"]),
  ("border-radius", @[]),
  ("flex-grow", @["flex"]),
  ("flex-shrink", @["flex"]),
  ("flex-basis", @["flex"]),
  ("row-gap", @["gap"]),
  ("column-gap", @["gap"]),
  ("overflow-x", @["overflow"]),
  ("overflow-y", @["overflow"]),
  ("top", @["inset"]),
  ("right", @["inset"]),
  ("bottom", @["inset"]),
  ("left", @["inset"]),
  ("list-style-type", @["list-style"]),
  ("list-style-position", @["list-style"]),
  ("text-decoration-line", @["text-decoration"]),
  ("text-decoration-color", @["text-decoration"]),
  ("transition-duration", @["transition"]),
  ("transition-property", @["transition"]),
  ("animation-duration", @["animation"]),
  ("animation-name", @["animation"]),
]

func resettersOf(property: string): seq[string] =
  ## Every declaration whose presence overrides `property`: the property
  ## itself, plus any shorthand that sets it.
  result = @[property]
  for (longhand, shorthands) in shorthandsFor:
    if longhand == property:
      for s in shorthands:
        result.add s
      break

type
  NestedRule = object
    ## A rule at ANY depth, with the at-rule conditions enclosing it.
    selector: string
    condition: string    ## All enclosing preludes, outermost first, " and "-
                         ## joined; for a rule nested in a style rule, that
                         ## rule's selector too, so a caller that treats any
                         ## condition as "not unconditional" stays safe.
    bodyStart: int
    bodyEnd: int
    preludes: seq[string]  ## The enclosing at-rule preludes, outermost first.
    layer: seq[string]   ## The cascade layer it sits in, as the names of each
                         ## level (an anonymous layer gets a name no author
                         ## can write); empty outside every layer.
    inStyle: bool        ## Nested in a style rule: its selector is relative.

  CssItemKind = enum
    ciRule               ## A style rule (`NestedRule`).
    ciLayer              ## A cascade layer named: an `@layer` block or
                         ## statement, or an `@import … layer(…)`.

  CssItem = object
    at: int              ## Where it starts: a rule's body, a layer's prelude.
    case kind: CssItemKind
    of ciRule: rule: NestedRule
    of ciLayer:
      names: seq[seq[string]]  ## Each name it declares, in full.
      gates: seq[string]   ## The at-rule preludes enclosing it: a layer named
                           ## under a condition that does not hold is not
                           ## named at all (CSS Cascade 5, checked in Chromium).
      gatedByStyle: bool   ## Named inside a style rule.

func layerNames(prelude: string; anonymous: var int): seq[seq[string]] =
  ## The layer names an `@layer` prelude (or an `@import`'s `layer(…)`)
  ## declares, each split at its dots. An unnamed layer gets a name of its
  ## own that no author can write, so two of them are two layers.
  let list = prelude.strip()
  if list.len == 0:
    inc anonymous
    return @[@["\0anonymous" & $anonymous]]
  for name in list.split(','):
    var parts: seq[string] = @[]
    for part in name.split('.'): parts.add part.strip()
    result.add parts

func importLayer(text: string; anonymous: var int): seq[seq[string]] =
  ## The layer an `@import` statement puts its sheet in: its `layer` keyword
  ## or `layer(…)` function, read after the url or string (whose text may
  ## say "layer" too) and outside any other function (`supports(…)`).
  var i = 7                       # past `@import`
  var depth = 0
  while i < text.len:
    let past = text.skipCssOpaque(i)
    if past > i:
      i = past
      continue
    let c = text[i]
    if c == '(':
      inc depth
    elif c == ')':
      if depth > 0: dec depth
    elif depth == 0 and c in {'l', 'L'} and i + 5 <= text.len and
        text[i ..< i + 5].toLowerAscii() == "layer" and
        text[i - 1] notin IdentChars + {'-', '\\'} and
        (i + 5 == text.len or text[i + 5] notin IdentChars + {'-'}):
      if i + 5 < text.len and text[i + 5] == '(':
        let close = text.find(')', i + 6)
        if close > 0: return text[i + 6 ..< close].layerNames(anonymous)
        return @[]
      return "".layerNames(anonymous)
    inc i

func isAtKeyword(lower, name: string): bool =
  lower.startsWith(name) and
    (lower.len == name.len or lower[name.len] notin IdentChars + {'-'})

iterator cssItems(css: string): CssItem =
  ## Every style rule, at any depth, and every place a cascade layer is
  ## named, in the order they are found (a rule yields at its closing brace,
  ## so after the rules nested in it; `at` gives document order).
  ##
  ## `topLevelRules` deliberately skips at-rule contents, because a patch must
  ## never land inside a `@media` block it was not asked about. That is the
  ## right rule for the UNCONDITIONAL write path and the wrong one for asking
  ## "what governs this property at this width", since the answer is usually
  ## exactly the thing in the `@media` block.
  ##
  ## The conditions are a STACK, not a single value: `@supports` wrapping
  ## `@media` is a rule that applies only when both hold, and a reader told
  ## only about the inner one would be told something false.
  type Frame = tuple[selector, prelude: string; bodyStart: int;
    layer: seq[string]]
  var i = 0
  var open: seq[Frame] = @[]
  var selectorStart = 0
  var anonymous = 0
  proc enclosingLayer(open: seq[Frame]): seq[string] =
    if open.len > 0: open[^1].layer else: @[]
  proc gates(open: seq[Frame]): tuple[preludes: seq[string]; style: bool] =
    for frame in open:
      if frame.prelude.len > 0: result.preludes.add frame.prelude
      else: result.style = true
  while i < css.len:
    let past = css.skipCssOpaque(i)   # comments, strings, escapes, urls
    if past > i:
      i = past
      continue
    case css[i]
    of '{':
      let text = css[selectorStart ..< i].strip().withoutComments().strip()
      var layer = open.enclosingLayer()
      if text.startsWith("@"):
        if text.toLowerAscii().isAtKeyword("@layer"):
          let names = text[6 .. ^1].layerNames(anonymous)
          var full: seq[seq[string]] = @[]
          for name in names: full.add layer & name
          let gate = open.gates()
          yield CssItem(kind: ciLayer, at: selectorStart, names: full,
            gates: gate.preludes, gatedByStyle: gate.style)
          if full.len == 1: layer = full[0]
        open.add (selector: "", prelude: text, bodyStart: i + 1, layer: layer)
      else:
        open.add (selector: text, prelude: "", bodyStart: i + 1, layer: layer)
      selectorStart = i + 1
      i += 1
    of '}':
      if open.len > 0:
        let closed = open.pop()
        if closed.selector.len > 0:
          var preludes, conditions: seq[string] = @[]
          var inStyle = false
          for frame in open:
            if frame.prelude.len > 0:
              preludes.add frame.prelude
              conditions.add frame.prelude
            else:
              inStyle = true
              conditions.add frame.selector
          yield CssItem(kind: ciRule, at: closed.bodyStart, rule: NestedRule(
            selector: closed.selector, condition: conditions.join(" and "),
            bodyStart: closed.bodyStart, bodyEnd: i, preludes: preludes,
            layer: closed.layer, inStyle: inStyle))
      selectorStart = i + 1
      i += 1
    of ';':
      # Outside a style rule, a `;` ends an at-statement (`@layer a, b;`,
      # `@import …;`); inside one it ends a declaration. Neither is part of
      # the next rule's selector (`.y { color: red; .x { … } }` nests `.x`).
      if open.len == 0 or open[^1].prelude.len > 0:
        let text = css[selectorStart ..< i].strip().withoutComments().strip()
        let lower = text.toLowerAscii()
        let layer = open.enclosingLayer()
        var names: seq[seq[string]] = @[]
        if lower.isAtKeyword("@layer"):
          names = text[6 .. ^1].layerNames(anonymous)
        elif lower.isAtKeyword("@import"):
          names = text.importLayer(anonymous)
        if names.len > 0:
          var full: seq[seq[string]] = @[]
          for name in names: full.add layer & name
          let gate = open.gates()
          yield CssItem(kind: ciLayer, at: selectorStart, names: full,
            gates: gate.preludes, gatedByStyle: gate.style)
      selectorStart = i + 1
      i += 1
    else:
      i += 1

iterator allRules(css: string): NestedRule =
  ## Every style rule `cssItems` finds, including those nested inside
  ## at-rules, with the full stack of conditions it sits under.
  for item in css.cssItems():
    if item.kind == ciRule: yield item.rule

# ---------------------------------------------------------------------------
#  Which rule governs a property at a given width.
# ---------------------------------------------------------------------------

func widthBound(condition, feature: string): int =
  ## The pixel value of `(max-width: N)` / `(min-width: N)` in `condition`,
  ## or -1 when the feature is absent. Only `px` is understood; a bound in
  ## other units reads as absent, which makes the condition inevaluable rather
  ## than silently wrong.
  result = -1
  var search = 0
  while true:
    let at = condition.find(feature, search)
    if at < 0: return
    var j = at + feature.len
    while j < condition.len and condition[j] in {' ', '\t'}: j += 1
    if j < condition.len and condition[j] == ':':
      j += 1
      while j < condition.len and condition[j] in {' ', '\t'}: j += 1
      var digits = ""
      while j < condition.len and condition[j].isDigit:
        digits.add condition[j]
        j += 1
      if digits.len > 0 and condition[j ..< min(j + 2, condition.len)] == "px":
        return parseInt(digits)
    search = at + feature.len

func conditionIsWidthOnly(condition: string): bool =
  ## True when every feature in the prelude is a width bound this module can
  ## evaluate.
  ##
  ## `@media (prefers-color-scheme: dark)` also redeclares selectors in this
  ## stylesheet, and it is NOT a breakpoint: an edit made because the preview
  ## is 850px wide must never land in the dark-mode block. Anything not
  ## recognised as a width bound therefore disqualifies the whole condition,
  ## which is the safe direction -- an unrecognised condition costs a write
  ## that falls back to the base rule, never a write into the wrong block.
  if condition.len == 0:
    return false
  var rest = condition
  rest = rest.replace("@media", " ").replace("and", " ").replace("screen", " ")
  rest = rest.replace("only", " ")
  var depth = 0
  var feature = ""
  var features: seq[string] = @[]
  for c in rest:
    if c == '(':
      depth += 1
      feature = ""
    elif c == ')':
      depth -= 1
      features.add feature.strip()
    elif depth > 0:
      feature.add c
    elif c notin {' ', '\t', '\n', ','}:
      return false            # bare text outside a feature: not understood
  if features.len == 0:
    return false
  for f in features:
    let name = f.split(':')[0].strip()
    if name notin ["max-width", "min-width"]:
      return false
  true

func conditionMatchesWidth(condition: string; width: int): bool =
  ## Does a rule under `condition` apply at a viewport `width` px wide?
  ##
  ## An empty condition is the base rule and always applies.
  if condition.len == 0:
    return true
  if not condition.conditionIsWidthOnly():
    return false
  let maxW = condition.widthBound("max-width")
  let minW = condition.widthBound("min-width")
  if maxW >= 0 and width > maxW: return false
  if minW >= 0 and width < minW: return false
  true

func responsiveBreakpoints*(css: string): seq[CssBreakpoint] =
  ## Every width-based `@media` block in the stylesheet, narrowest first.
  ##
  ## Non-width blocks (`prefers-color-scheme`, `print`) are left out: they are
  ## not breakpoints and offering them as ones would invite an edit that lands
  ## somewhere a viewport chip has nothing to do with.
  var seen: seq[string] = @[]
  for rule in css.allRules():
    if rule.condition.len == 0: continue
    if rule.condition in seen: continue
    if not rule.condition.conditionIsWidthOnly(): continue
    seen.add rule.condition
    result.add CssBreakpoint(condition: rule.condition,
                             minWidth: rule.condition.widthBound("min-width"),
                             maxWidth: rule.condition.widthBound("max-width"))
  # Narrowest first, by upper bound; unbounded-above sorts last.
  for i in 1 ..< result.len:
    var j = i
    proc upper(b: CssBreakpoint): int =
      if b.maxWidth >= 0: b.maxWidth else: high(int)
    while j > 0 and result[j - 1].upper() > result[j].upper():
      swap(result[j - 1], result[j])
      j -= 1

func breakpointForWidth*(breakpoints: seq[CssBreakpoint];
                         width: int): CssBreakpoint =
  ## The narrowest defined breakpoint that applies at `width`, or one with an
  ## empty condition meaning "the base, no query applies".
  ##
  ## Narrowest wins because that is what the cascade does: overlapping
  ## `max-width` blocks all apply and the last (tightest) one written is the
  ## one whose values survive.
  result = CssBreakpoint(condition: "", minWidth: -1, maxWidth: -1)
  for b in breakpoints:
    if b.condition.conditionMatchesWidth(width):
      return b

type
  CssTruth = enum
    ctFails, ctHolds, ctUnknown

  CascadeCandidate = object
    rule: NestedRule
    important: bool
    layer: seq[int]      ## Ordinals from the outermost layer down, then
                         ## `high(int)` for the declarations directly in it.
    order: int
    declared: string     ## The declaration that sets the property in it.

func collapsedCondition(condition: string): string =
  ## An at-rule prelude compared without its incidental whitespace, so the
  ## stylesheet's `@media (max-width: 980px)` and a caller's copy of it with a
  ## different line break or indentation name the same block.
  condition.withoutComments().splitWhitespace().join(" ")

func answered(answers: openArray[CssConditionAnswer];
    prelude: string): CssTruth =
  ## The caller's answer for ``prelude`` (`ctUnknown` when it gave none).
  let wanted = prelude.collapsedCondition()
  for answer in answers:
    if answer.condition.collapsedCondition() == wanted:
      return if answer.holds: ctHolds else: ctFails
  ctUnknown

func splitTopLevel(text: string; separator: char): seq[string] =
  ## ``text`` split at each ``separator`` outside parentheses, strings and
  ## comments.
  var depth = 0
  var start = 0
  var i = 0
  while i < text.len:
    let past = text.skipCssOpaque(i)
    if past > i:
      i = past
      continue
    case text[i]
    of '(': inc depth
    of ')':
      if depth > 0: dec depth
    else:
      if text[i] == separator and depth == 0:
        result.add text[start ..< i]
        start = i + 1
    inc i
  result.add text[start .. ^1]

func mediaQueryTruth(query: string; width: int): CssTruth =
  ## One media query (no top-level comma), from its text alone, for a screen
  ## ``width`` px wide: a media type, then `px` width bounds. Anything else
  ## (`not`, a feature other than a width, an `em` bound, range syntax) is
  ## unknown.
  let q = query.strip().toLowerAscii()
  if q in ["", "all", "screen", "only screen", "only all"]: return ctHolds
  for printType in ["print", "only print", "not screen"]:
    if q.isAtKeyword(printType): return ctFails
  if q.isAtKeyword("not"): return ctUnknown
  let prelude = "@media " & q
  if not prelude.conditionIsWidthOnly(): return ctUnknown
  # Each bound must be one `px` value this reads, or the query is unknown:
  # an `em` bound read as absent would make the query hold at every width.
  for feature in ["max-width", "min-width"]:
    let count = q.count(feature)
    if count > 1: return ctUnknown
    if count == 1 and prelude.widthBound(feature) < 0: return ctUnknown
  if prelude.conditionMatchesWidth(width): ctHolds else: ctFails

func widthDecided*(prelude: string): bool =
  ## Whether ``prelude`` is a `@media` query list every query of which is
  ## read from its text at any width (`mediaQueryTruth`: a media type and
  ## `px` width bounds), so that a writer told the preview's width decides
  ## it without the preview's answer.
  let lower = prelude.strip().toLowerAscii()
  if not lower.isAtKeyword("@media"): return false
  for query in prelude.strip()[6 .. ^1].splitTopLevel(','):
    if query.mediaQueryTruth(1) == ctUnknown: return false
  true

func preludeTruth(prelude: string; width: int;
    answers: openArray[CssConditionAnswer]): CssTruth =
  ## Whether a rule under the at-rule ``prelude`` applies in the preview.
  ##
  ## The caller's answer for the prelude decides when it gave one: the
  ## preview's own `matchMedia` / `CSS.supports` result for the condition,
  ## as the preview runtime evaluates it (`CssConditionAnswer`). Otherwise
  ## the text is read, for a screen ``width`` px wide: a media query list
  ## holds when one of its queries does (`mediaQueryTruth`), `@layer` always
  ## holds (it orders, it does not filter), and rules in at-rules that hold
  ## no element style (`@font-face`, `@keyframes`, `@page`,
  ## `@starting-style`, ...) never apply. Everything else is unknown:
  ## `@supports`, `@container`, `@scope` and any at-rule not named here.
  let lower = prelude.strip().toLowerAscii()
  if lower.isAtKeyword("@layer"): return ctHolds
  for name in ["@font-face", "@keyframes", "@-webkit-keyframes", "@page",
      "@property", "@counter-style", "@font-feature-values",
      "@font-palette-values", "@starting-style", "@view-transition",
      "@namespace"]:
    if lower.isAtKeyword(name): return ctFails
  # A `px` width condition is the writer's own to decide, from the width it
  # is given (`widthDecided`); an answer for one is not used, so a request
  # cannot move a write to a breakpoint its width does not apply.
  if not prelude.widthDecided():
    let given = answers.answered(prelude)
    if given != ctUnknown: return given
  if not lower.isAtKeyword("@media"): return ctUnknown
  result = ctFails
  for query in prelude.strip()[6 .. ^1].splitTopLevel(','):
    case query.mediaQueryTruth(width)
    of ctHolds: return ctHolds
    of ctUnknown: result = ctUnknown
    of ctFails: discard

func widthIntervals*(preludes: openArray[string]):
    seq[tuple[minWidth, maxWidth: int]] =
  ## The preview widths, as ranges `minWidth .. maxWidth` (`maxWidth` -1 for
  ## no upper bound, from 1px up), over each of which every one of
  ## ``preludes`` (each `widthDecided`) holds throughout or fails throughout.
  var points = @[1]
  for prelude in preludes:
    for query in prelude.strip()[6 .. ^1].splitTopLevel(','):
      let text = "@media " & query.strip().toLowerAscii()
      let upper = text.widthBound("max-width")
      if upper >= 0: points.add upper + 1
      let lower = text.widthBound("min-width")
      if lower >= 1: points.add lower
  for i in 1 ..< points.len:
    var j = i
    while j > 0 and points[j - 1] > points[j]:
      swap(points[j - 1], points[j])
      dec j
  var unique: seq[int] = @[]
  for point in points:
    if unique.len == 0 or unique[^1] != point: unique.add point
  for i, point in unique:
    result.add (minWidth: point,
      maxWidth: if i + 1 < unique.len: unique[i + 1] - 1 else: -1)

func stackTruth(preludes: seq[string]; inStyle: bool; width: int;
    answers: openArray[CssConditionAnswer]): tuple[truth: CssTruth;
    unknown: string] =
  ## Every condition in a stack, together: false when one is, otherwise
  ## unknown when one is (``unknown`` names the first such). Inside a style
  ## rule is unknown: a nested rule's selector is relative to its parent's,
  ## so which elements it styles is not its selector text.
  result.truth = ctHolds
  if inStyle:
    result = (ctUnknown, "a rule nested in another style rule")
  for prelude in preludes:
    case prelude.preludeTruth(width, answers)
    of ctFails: return (ctFails, "")
    of ctUnknown:
      if result.truth != ctUnknown: result = (ctUnknown, prelude)
    of ctHolds: discard

type LayerOrder = object
  ## Each cascade layer's ordinal among its siblings, by first appearance.
  ordinals: seq[tuple[name: seq[string]; ordinal: int]]
  counts: seq[tuple[parent: seq[string]; count: int]]

func known(order: LayerOrder; name: seq[string]): bool =
  for o in order.ordinals:
    if o.name == name: return true

func register(order: var LayerOrder; name: seq[string]) =
  ## Ranks ``name`` and each layer above it, where they first appear.
  for depth in 1 .. name.len:
    let prefix = name[0 ..< depth]
    if order.known(prefix): continue
    let parent = name[0 ..< depth - 1]
    var ordinal = -1
    for c in order.counts.mitems:
      if c.parent == parent:
        ordinal = c.count
        inc c.count
        break
    if ordinal < 0:
      ordinal = 0
      order.counts.add (parent: parent, count: 1)
    order.ordinals.add (name: prefix, ordinal: ordinal)

func position(order: LayerOrder; layer: seq[string]): seq[int] =
  ## A layer's place in the layer order, comparable by `compareLayers`: its
  ## ordinal at each level, then `high(int)` for the declarations directly in
  ## it, which come after its sublayers. Outside every layer, `[high(int)]`:
  ## after every layer.
  for depth in 1 .. layer.len:
    for o in order.ordinals:
      if o.name == layer[0 ..< depth]:
        result.add o.ordinal
        break
  result.add high(int)

func compareLayers(x, y: seq[int]): int =
  ## Positive when layer position ``x`` comes later in the layer order.
  for i in 0 ..< min(x.len, y.len):
    if x[i] != y[i]: return (if x[i] > y[i]: 1 else: -1)
  x.len - y.len

func cascadeWins(x, y: CascadeCandidate): bool =
  ## True when ``x`` beats ``y`` for one property, both rules having the
  ## same selector and so the same specificity
  ## (https://www.w3.org/TR/css-cascade-5/#cascade-sort): importance, then
  ## cascade layer -- later layers win for normal declarations and earlier
  ## ones for `!important`, and a declaration outside every layer counts as
  ## in the last one -- then order of appearance.
  if x.important != y.important: return x.important
  let layers = compareLayers(x.layer, y.layer)
  if layers != 0: return (if x.important: layers < 0 else: layers > 0)
  x.order > y.order

func describe(rule: NestedRule; selector: string): string =
  if rule.condition.len > 0: "`" & selector & "` in " & rule.condition
  else: "the base rule for `" & selector & "`"

func sortedItems(css: string): seq[CssItem] =
  ## `cssItems` in document order.
  for item in css.cssItems():
    result.add item
  for i in 1 ..< result.len:
    var j = i
    while j > 0 and result[j - 1].at > result[j].at:
      swap(result[j - 1], result[j])
      j -= 1

func editConditions*(css, selector, property: string): seq[string] =
  ## The `@media` and `@supports` preludes, as the stylesheet writes them
  ## and in document order, whose answers can change which rule
  ## `editTargetAtWidth` names for `property` on `selector`: those over a
  ## rule with the selector that declares the property (or a shorthand
  ## setting it), and those over a place a cascade layer is named. These are
  ## the conditions a caller asks the preview about (`CssConditionAnswer`).
  let targets = property.resettersOf()
  proc addCondition(list: var seq[string]; prelude: string) =
    let lower = prelude.strip().toLowerAscii()
    if not (lower.isAtKeyword("@media") or lower.isAtKeyword("@supports")):
      return
    for known in list:
      if known.collapsedCondition() == prelude.collapsedCondition(): return
    list.add prelude
  for item in css.sortedItems():
    case item.kind
    of ciLayer:
      for prelude in item.gates: result.addCondition prelude
    of ciRule:
      let rule = item.rule
      if not rule.selector.selectorMatches(selector): continue
      let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                          bodyEnd: rule.bodyEnd)
      var declares = false
      for name in targets:
        if css.findDeclaration(body, name).valueStart >= 0:
          declares = true
          break
      if declares:
        for prelude in rule.preludes: result.addCondition prelude

type
  IndexedItem = object
    ## One place the cascade for one selector and property is decided by:
    ## a layer naming, or a rule with the selector (whatever it declares,
    ## since a rule with the selector and no declaration can be the base
    ## rule a new declaration goes to).
    isLayer: bool
    names: seq[seq[string]]
    gates: seq[string]
    gatedByStyle: bool
    rule: NestedRule
    declared: string     ## The declaration that sets the property, "" for none.
    important: bool

  CssTargetIndex* = object
    ## What `editTargetAtWidth` reads from a stylesheet for one selector and
    ## property, read once (`targetIndex`), so that the target for many
    ## widths and answers (`editTarget`) costs no further scan of the sheet.
    selector, property: string
    items: seq[IndexedItem]
    base: int            ## Index in `items` of the base rule, -1 for none.

func targetIndex*(css, selector, property: string): CssTargetIndex =
  ## `css` read once for `editTarget`: every layer naming, and every rule
  ## with `selector` with the declaration that sets `property` in it.
  result = CssTargetIndex(selector: selector, property: property, base: -1)
  let targets = property.resettersOf()
  for item in css.sortedItems():
    if item.kind == ciLayer:
      result.items.add IndexedItem(isLayer: true, names: item.names,
        gates: item.gates, gatedByStyle: item.gatedByStyle)
      continue
    let rule = item.rule
    if not rule.selector.selectorMatches(selector):
      continue
    var indexed = IndexedItem(rule: rule)
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    for name in targets:
      let decl = css.findDeclaration(body, name)
      if decl.valueStart >= 0:
        if indexed.declared.len == 0: indexed.declared = name
        if css[decl.valueStart ..< decl.valueEnd].cssValueParts().important:
          indexed.important = true
    if rule.condition.len == 0 and not rule.inStyle:
      result.base = result.items.len
    result.items.add indexed

func targetKey*(target: CssEditTarget): string =
  ## Which rule ``target`` names (or why none), apart from the width its
  ## reason mentions: equal keys write the same rule, or refuse alike.
  $target.found & "|" & $target.undecided & "|" & $target.ruleStart & "|" &
    (if target.undecided: target.reason else: "")

func editTarget*(index: CssTargetIndex; width: int;
    answers: openArray[CssConditionAnswer] = []): CssEditTarget =
  ## `editTargetAtWidth` from a stylesheet read once (`targetIndex`).
  let selector = index.selector
  let property = index.property
  var layers: LayerOrder
  var uncertainLayer = ""         # a prelude a layer's naming depends on
  var base = CssEditTarget(found: false, ruleStart: -1)
  var baseRule: NestedRule
  if index.base >= 0:
    baseRule = index.items[index.base].rule
    base = CssEditTarget(found: true, condition: "",
                         selector: baseRule.selector, isBreakpoint: false,
                         reason: "the base rule for `" & selector & "`",
                         ruleStart: baseRule.bodyStart)
  var best: CascadeCandidate
  var haveBest = false
  var anyLayered = false
  var unknown: seq[tuple[candidate: CascadeCandidate; why: string]] = @[]
  for item in index.items:
    if item.isLayer:
      let gate = stackTruth(item.gates, item.gatedByStyle, width, answers)
      case gate.truth
      of ctFails: discard
      of ctHolds:
        for name in item.names: layers.register(name)
      of ctUnknown:
        for name in item.names:
          if not layers.known(name) and uncertainLayer.len == 0:
            uncertainLayer = gate.unknown
          layers.register(name)
      continue
    if item.declared.len == 0:
      continue
    let rule = item.rule
    let truth = stackTruth(rule.preludes, rule.inStyle, width, answers)
    if truth.truth == ctFails:
      continue
    let candidate = CascadeCandidate(rule: rule, order: rule.bodyStart,
      layer: layers.position(rule.layer), declared: item.declared,
      important: item.important)
    if rule.layer.len > 0: anyLayered = true
    if truth.truth == ctUnknown:
      unknown.add (candidate, truth.unknown)
    elif not haveBest or candidate.cascadeWins(best):
      best = candidate
      haveBest = true

  if uncertainLayer.len > 0 and anyLayered:
    return CssEditTarget(found: false, undecided: true, ruleStart: -1,
      reason: "the order of the cascade layers that set `" & property &
        "` for `" & selector & "` depends on " & uncertainLayer &
        ", which the preview did not answer, so which rule decides `" &
        property & "` cannot be told.")
  # What an unknown rule is weighed against: the deciding rule, or, when
  # none declares the property, a normal declaration added to the base rule.
  var against: CascadeCandidate
  var haveAgainst = haveBest
  if haveBest: against = best
  elif base.found:
    against = CascadeCandidate(rule: baseRule, order: baseRule.bodyStart,
      layer: layers.position(baseRule.layer))
    haveAgainst = true
  for (u, why) in unknown:
    if not haveAgainst or u.cascadeWins(against):
      return CssEditTarget(found: false, undecided: true, ruleStart: -1,
        reason: "`" & u.declared & "` is also set for " &
          u.rule.describe(selector) & ", and whether " & why &
          " applies in the preview is not known; whenever it does, that " &
          "rule decides `" & property & "`, so which rule decides it " &
          "cannot be told.")

  if not haveBest:
    return base
  let rule = best.rule
  CssEditTarget(
    found: true, condition: rule.condition, selector: rule.selector,
    isBreakpoint: rule.condition.len > 0, ruleStart: rule.bodyStart,
    decides: true,
    reason:
      if rule.condition.len > 0:
        "`" & best.declared & "` is set for `" & selector & "` in " &
          rule.condition & ", which is what applies at " & $width & "px" &
          (if best.important: " (`!important`)" else: "")
      else:
        "`" & best.declared & "` is set for `" & selector & "` in the base rule" &
          (if best.important: " (`!important`)" else: ""))


func editTargetAtWidth*(css, selector, property: string; width: int;
    answers: openArray[CssConditionAnswer] = []): CssEditTarget =
  ## The rule that should receive `property` for `selector` in a preview
  ## `width` px wide whose own answers for the stylesheet's conditions are
  ## ``answers`` (`CssConditionAnswer`; see `editConditions`).
  ##
  ## This is the whole of breakpoint-aware editing, and it is one rule:
  ##
  ##   **Write where the value is already decided.** Of every rule that has
  ##   the selector and applies in the preview, take the one the cascade uses
  ##   for the property or a shorthand setting it. That rule is the one
  ##   currently winning, so it is the one that has to change for anything to
  ##   happen. The rules share the selector, so they share its specificity,
  ##   and the cascade orders them by importance, then cascade layer, then
  ##   order of appearance (`cascadeWins`): `.x { padding:1px !important; }`
  ##   decides `padding` over a later `@media` rule's normal `padding`, and a
  ##   rule outside every `@layer` over one inside a layer. A layer named
  ##   under a condition that does not hold takes no place in the order.
  ##
  ##   **If nothing declares it, write to the base rule.** A property no rule
  ##   mentions has no responsive intent to respect, and scoping it to whatever
  ##   breakpoint happens to be on screen would invent one.
  ##
  ##   **If it cannot be told, name no rule.** Whether a rule applies is the
  ##   preview's answer for its conditions when the caller gives one, and is
  ##   otherwise read from the text (`preludeTruth`). A rule under a
  ##   condition neither answers (`@container`; `@supports` or
  ##   `prefers-color-scheme` without an answer) is never chosen. When it
  ##   declares the property and would outrank the rule otherwise chosen
  ##   whenever its condition holds, or a layer it depends on is named under
  ##   such a condition, which rule decides the property is not known, and
  ##   the answer is `undecided`, with the reason in `reason`. A writer
  ##   refuses then, with that reason, as the preview runtime leaves the
  ##   preview alone when it cannot tell which rule decides.
  ##
  ## Worked example, from the stylesheet this was built against. `.tagline` is
  ## declared at the top level with `font: var(--sys-type-display)` and again
  ## inside `@media (max-width:1080px)` with `font: var(--sys-type-displayCompact)`.
  ## Editing `font-size`:
  ##
  ##   * at 850px  -> the media rule. Both apply; the media rule is later, so
  ##     its `font` shorthand is what is resetting `font-size` today. Writing
  ##     anywhere else changes nothing, which is what used to happen.
  ##   * at 1440px -> the base rule. The media rule does not apply up there,
  ##     so the base rule is the one deciding, and the compact size below
  ##     1080px is left intact.
  ##
  ## Both answers are correct and they are different rules. That is why this
  ## takes a width instead of guessing.
  css.targetIndex(selector, property).editTarget(width, answers)

func inRuleOverride(css: string; body: RuleSpan; property: string): string =
  ## The declaration in the rule ``body`` that would still decide
  ## ``property`` after a value edit of it (the declaration kept with its
  ## priority, or a normal one added at the end): a shorthand setting it that
  ## is `!important` over a normal declaration, or of the same priority and
  ## later. "" when none would.
  let own = css.findDeclaration(body, property)
  let ownImportant = own.valueStart >= 0 and
    css[own.valueStart ..< own.valueEnd].cssValueParts().important
  let ownAt = if own.valueStart >= 0: own.nameStart else: high(int)
  for name in property.resettersOf():
    if name == property: continue
    let decl = css.findDeclaration(body, name)
    if decl.valueStart < 0: continue
    let important = css[decl.valueStart ..< decl.valueEnd].cssValueParts().important
    if important and not ownImportant:
      return "the `!important` `" & name & "` declaration"
    if important == ownImportant and decl.nameStart > ownAt:
      return "the later `" & name & "` declaration"
  ""

func shadowingDeclaration*(css, selector, property: string): CssShadow =
  ## The later rule that would override `property` for `selector`, if any.
  ##
  ## "Later" is the whole test. Both rules carry the same selector, so they
  ## have the same specificity, and at equal specificity document order
  ## decides. A rule EARLIER in the file loses to the patched one and is not a
  ## problem; a rule later in the file wins, whether it sets the property
  ## directly or folds it into a shorthand.
  ##
  ## A shadow inside an at-rule is reported with its prelude rather than
  ## resolved, because whether it applies depends on the viewport and this
  ## function has no viewport. Naming the condition lets the caller say "below
  ## 1080px" instead of pretending to know.
  let targets = property.resettersOf()
  # Where the patch landed: the single top-level rule for this selector.
  var patchedEnd = -1
  for rule in css.topLevelRules():
    if rule.selector.selectorMatches(selector):
      patchedEnd = rule.bodyEnd
      break
  if patchedEnd < 0:
    return CssShadow(found: false)
  for rule in css.allRules():
    if rule.bodyStart <= patchedEnd:
      continue                      # same rule, or earlier: cannot shadow
    if not rule.selector.selectorMatches(selector):
      continue
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    for candidate in targets:
      if css.findDeclaration(body, candidate).valueStart >= 0:
        return CssShadow(found: true, byProperty: candidate,
                         condition: rule.condition, selector: rule.selector)
  CssShadow(found: false)

proc patchCssDeclarationUnguarded(css, selector, property,
    newValue: string):
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
    let current = existing.cssDeclarationValue()
    # The value changes; its priority and the comments around it stay
    # (`cssValueEdit`). The whitespace outside `valueStart .. valueEnd` is
    # untouched, so a multi-line rule keeps its alignment.
    let edit = existing.cssValueEdit(newValue)
    if edit.refusal.len > 0:
      return CssPatchResult(ok: false, outcome: cpoUnreadable,
        message: edit.refusal)
    if edit.unchanged:
      return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                            oldValue: current)
    return CssPatchResult(ok: true, outcome: cpoReplaced,
      oldValue: current,
      content: css[0 ..< decl.valueStart] & (
        if css[decl.valueStart] in {' ', '\t'}: " " else: "") &
        edit.text & css[decl.valueEnd .. ^1])

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

proc patchCssDeclaration*(css, selector, property, newValue: string):
    CssPatchResult =
  ## `patchCssDeclarationUnguarded`, refused when its write would land inside
  ## what only the end of the sheet closes (`cssWriteRefusal`).
  css.cssWriteRefusal(patchCssDeclarationUnguarded(css, selector, property, newValue))

proc patchCssDeclarationAtUnguarded(css, selector, property,
    newValue: string; width: int;
    answers: openArray[CssConditionAnswer]): CssPatchResult =
  ## `patchCssDeclaration`, but into the rule that governs `property` at
  ## `width` -- which may be inside an `@media` block.
  ##
  ## Falls back to the plain top-level patch when the governing rule IS the
  ## base rule, so the unconditional path keeps its refusals (ambiguous
  ## selector, missing rule) and its byte-for-byte behaviour.
  ##
  ## Refused, with `editTargetAtWidth`'s reason, when which rule decides the
  ## property in the preview cannot be told (`CssEditTarget.undecided`), and
  ## when a shorthand in the target rule would still decide the property
  ## after the edit (`inRuleOverride`: an `!important` shorthand over a
  ## normal declaration, or a later one of the same priority), so the write
  ## would change nothing that renders.
  let target = css.editTargetAtWidth(selector, property, width, answers)
  if target.undecided:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: "`" & property & "` for `" & selector & "` cannot be edited here: " &
        target.reason & " Edit the stylesheet directly.")
  if target.found:
    for rule in css.allRules():
      if rule.bodyStart != target.ruleStart: continue
      let overrider = css.inRuleOverride(RuleSpan(selector: rule.selector,
        bodyStart: rule.bodyStart, bodyEnd: rule.bodyEnd), property)
      if overrider.len > 0:
        return CssPatchResult(ok: false, outcome: cpoAmbiguous,
          message: "`" & property & "` for `" & selector & "` cannot be " &
            "edited here: in " & rule.describe(selector) & ", " & overrider &
            " sets it and would still decide it after the edit. Edit that " &
            "declaration instead.")
  if not target.found:
    return patchCssDeclaration(css, selector, property, newValue)
  if not target.isBreakpoint:
    # An unconditional rule: the plain top-level patch, with its refusals,
    # unless more than one top-level rule has the selector and the cascade
    # names the one that declares the property (the later, or the
    # `!important`, of `.x { … } .x { … }`): then that rule, exactly.
    var topLevel = 0
    for rule in css.topLevelRules():
      if rule.selector.selectorMatches(selector): inc topLevel
    if not target.decides or topLevel <= 1:
      return patchCssDeclaration(css, selector, property, newValue)

  # The one rule the cascade uses: the rule `editTargetAtWidth` chose, found
  # by where its body starts, so another rule under the same conditions is
  # never mistaken for it.
  var matches: seq[NestedRule] = @[]
  for rule in css.allRules():
    if rule.bodyStart == target.ruleStart and
        rule.selector.selectorMatches(selector):
      matches.add rule
  if matches.len != 1:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "The rule that owns `" & property & "` for `" & selector &
        "` in " & target.condition & " could not be found again.")

  let rule = matches[0]
  let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                      bodyEnd: rule.bodyEnd)
  let decl = css.findDeclaration(body, property)
  if decl.valueStart >= 0:
    let existing = css[decl.valueStart ..< decl.valueEnd]
    let current = existing.cssDeclarationValue()
    # The value changes; its priority and comments stay (`cssValueEdit`).
    let edit = existing.cssValueEdit(newValue)
    if edit.refusal.len > 0:
      return CssPatchResult(ok: false, outcome: cpoUnreadable,
        message: edit.refusal)
    if edit.unchanged:
      return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                            oldValue: current)
    # The space after the colon stays, as in the base-rule path, so writing
    # the old value back restores the rule byte for byte.
    return CssPatchResult(ok: true, outcome: cpoReplaced,
      content: css[0 ..< decl.valueStart] & (
        if css[decl.valueStart] in {' ', '\t'}: " " else: "") &
        edit.text & css[decl.valueEnd .. ^1],
      oldValue: current)

  # Insert before the closing brace, matching the neighbours' layout.
  let bodyText = css[rule.bodyStart ..< rule.bodyEnd]
  let trimmed = bodyText.strip(leading = false)
  let needsSemicolon = trimmed.len > 0 and not trimmed.endsWith(";")
  let singleLine = "\n" notin trimmed
  var insertion = ""
  if trimmed.len == 0:
    insertion = " " & property & ":" & newValue & "; "
    return CssPatchResult(ok: true, outcome: cpoInserted,
      content: css[0 ..< rule.bodyStart] & insertion & css[rule.bodyEnd .. ^1],
      oldValue: "")
  if singleLine:
    insertion = (if needsSemicolon: ";" else: "") & " " & property & ":" &
      newValue & ";"
  else:
    # Align under the previous declaration, which is what makes the diff read
    # as one added line rather than a reformat.
    var indent = ""
    let lastNewline = trimmed.rfind('\n')
    if lastNewline >= 0:
      for c in trimmed[lastNewline + 1 .. ^1]:
        if c == ' ': indent.add ' '
        else: break
    insertion = (if needsSemicolon: ";" else: "") & "\n" & indent &
      property & ":" & newValue & ";"
  let cut = rule.bodyStart + trimmed.len
  CssPatchResult(ok: true, outcome: cpoInserted,
    content: css[0 ..< cut] & insertion & css[cut .. ^1],
    oldValue: "")

# ---------------------------------------------------------------------------
#  Responsive overrides: a declaration written under a named breakpoint.
# ---------------------------------------------------------------------------

proc patchCssDeclarationAt*(css, selector, property, newValue: string;
    width: int; answers: openArray[CssConditionAnswer] = []): CssPatchResult =
  ## `patchCssDeclarationAtUnguarded`, refused when its write would land inside
  ## what only the end of the sheet closes (`cssWriteRefusal`).
  css.cssWriteRefusal(patchCssDeclarationAtUnguarded(css, selector, property,
    newValue, width, answers))


iterator topLevelAtBlocks(css: string): tuple[prelude: string;
    bodyStart, bodyEnd: int] =
  ## Every at-rule block at brace depth 0 (`@media … { … }`), with its prelude
  ## and the span between its braces (`bodyEnd` is the index of its `}`).
  var i = 0
  var depth = 0
  var selectorStart = 0
  var prelude = ""
  var bodyStart = -1
  while i < css.len:
    let past = css.skipCssOpaque(i)   # comments, strings, escapes, urls
    if past > i:
      i = past
      continue
    case css[i]
    of '{':
      if depth == 0:
        prelude = css[selectorStart ..< i].withoutComments().strip()
        bodyStart = i + 1
      depth += 1
    of '}':
      depth -= 1
      if depth == 0 and bodyStart >= 0:
        if prelude.startsWith("@"):
          yield (prelude: prelude, bodyStart: bodyStart, bodyEnd: i)
        bodyStart = -1
      if depth <= 0:
        depth = 0
        selectorStart = i + 1
    of ';':
      if depth == 0: selectorStart = i + 1
    else: discard
    i += 1

proc patchCssDeclarationUnderUnguarded(css, condition, selector,
    property, newValue: string): CssPatchResult =
  ## Set `property` for `selector` inside the `@media` block `condition` --
  ## a responsive override -- leaving every rule outside that block alone.
  ##
  ## This is the write a responsive override makes (editor spec "Full CSS
  ## Property Inspector": the Layout section exposes responsive overrides as
  ## source-backed CSS concepts; `SourceEditPlan.breakpointCondition`). It is
  ## the counterpart of `patchCssDeclarationAt`, which writes where a value is
  ## ALREADY decided at a width: an override is the explicit request to decide
  ## it under one breakpoint, so it is written there even when nothing in that
  ## block mentions the property yet.
  ##
  ## * The one rule for `selector` directly under `condition` holds the
  ##   declaration: its value is replaced (a trailing comment is kept) or it
  ##   is added after the rule's last declaration.
  ## * When that block has no rule for `selector`, one is added at the end of
  ##   the block; when the stylesheet has no such block, the block is added at
  ##   the end of the stylesheet. `condition` is written verbatim.
  ## * An empty `newValue` removes exactly that declaration, as Reset does for
  ##   the base rule, and refuses when there is none.
  ##
  ## Refused, with nothing changed: a condition that is not a width-only
  ## `@media` prelude (it is not a breakpoint); two rules for `selector` under
  ## the condition, or two such blocks (which one holds the override is not
  ## this function's decision); a rule whose selector list styles other
  ## selectors too (the override would change them as well); a declaration of
  ## the property that appears more than once in the rule.
  let wanted = condition.collapsedCondition()
  if not wanted.startsWith("@media") or not wanted.conditionIsWidthOnly():
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "`" & condition & "` is not a width-based `@media` " &
        "breakpoint, so it cannot hold a responsive override.")
  if selector.strip().len == 0 or property.strip().len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "A responsive override needs a selector and a property.")
  let value = newValue.strip()
  var matches: seq[NestedRule] = @[]
  for rule in css.allRules():
    if rule.condition.collapsedCondition() == wanted and
        rule.selector.selectorMatches(selector):
      matches.add rule
  if matches.len > 1:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: $matches.len & " rules for `" & selector & "` sit inside `" &
        condition & "`. Which one holds the override is a decision this " &
        "patch cannot make; edit the stylesheet directly.")
  if matches.len == 1:
    let rule = matches[0]
    for member in rule.selector.withoutComments().split(','):
      if member.strip() != selector.strip():
        return CssPatchResult(ok: false, outcome: cpoAmbiguous,
          message: "The `" & selector & "` rule inside `" & condition &
            "` is shared by the selector list `" & rule.selector.strip() &
            "`; an override there would change every selector in the list. " &
            "Edit the stylesheet directly.")
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    let decl = css.findDeclaration(body, property)
    if decl.valueStart >= 0:
      let later = css.findDeclaration(RuleSpan(selector: rule.selector,
        bodyStart: decl.valueEnd + 1, bodyEnd: rule.bodyEnd), property)
      if later.valueStart >= 0:
        return CssPatchResult(ok: false, outcome: cpoAmbiguous,
          message: "The `" & selector & "` rule inside `" & condition &
            "` declares `" & property & "` more than once, so the one this " &
            "override owns cannot be identified.")
      let existing = css[decl.valueStart ..< decl.valueEnd]
      let current = existing.cssDeclarationValue()
      if value.len == 0:
        var start = decl.nameStart
        var stop = decl.valueEnd
        if stop < rule.bodyEnd and css[stop] == ';': inc stop
        var lineStart = start
        while lineStart > 0 and css[lineStart - 1] in {' ', '\t'}: dec lineStart
        var after = stop
        while after < css.len and css[after] in {' ', '\t', '\r'}: inc after
        if (lineStart == 0 or css[lineStart - 1] == '\n') and
            after < css.len and css[after] == '\n':
          start = lineStart
          stop = after + 1
        else:
          while stop < rule.bodyEnd and css[stop] in {' ', '\t'}: inc stop
        return CssPatchResult(ok: true, outcome: cpoRemoved, oldValue: current,
          content: css[0 ..< start] & css[stop .. ^1])
      # The value changes; its priority and comments stay (`cssValueEdit`).
      let edit = existing.cssValueEdit(value)
      if edit.refusal.len > 0:
        return CssPatchResult(ok: false, outcome: cpoUnreadable,
          message: edit.refusal)
      if edit.unchanged:
        return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                              oldValue: current)
      let lead = if css[decl.valueStart] in {' ', '\t'}: " " else: ""
      return CssPatchResult(ok: true, outcome: cpoReplaced, oldValue: current,
        content: css[0 ..< decl.valueStart] & lead & edit.text &
          css[decl.valueEnd .. ^1])
    if value.len == 0:
      return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
        message: "The `" & selector & "` rule inside `" & condition &
          "` has no `" & property & "` override to remove.")
    # Add it after the rule's last declaration, on the rule's own layout.
    let trimmed = css[rule.bodyStart ..< rule.bodyEnd].strip(leading = false)
    let needsSemicolon = trimmed.strip().len > 0 and not trimmed.endsWith(";")
    var insertion: string
    if trimmed.strip().len == 0:
      insertion = " " & property & ": " & value & ";"
    elif "\n" notin trimmed:
      insertion = (if needsSemicolon: ";" else: "") & " " & property & ": " &
        value & ";"
    else:
      var indent = ""
      let lastNewline = trimmed.rfind('\n')
      for c in trimmed[lastNewline + 1 .. ^1]:
        if c in {' ', '\t'}: indent.add c
        else: break
      insertion = (if needsSemicolon: ";" else: "") & "\n" & indent &
        property & ": " & value & ";"
    let cut = rule.bodyStart + trimmed.len
    return CssPatchResult(ok: true, outcome: cpoInserted, oldValue: "",
      content: css[0 ..< cut] & insertion &
        (if trimmed.strip().len == 0: " " & css[rule.bodyEnd .. ^1]
         else: css[cut .. ^1]))
  if value.len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "No `" & selector & "` rule inside `" & condition &
        "` holds a `" & property & "` override to remove.")
  let ruleText = selector.strip() & " { " & property & ": " & value & "; }"
  var blocks: seq[tuple[prelude: string; bodyStart, bodyEnd: int]] = @[]
  for blk in css.topLevelAtBlocks():
    if blk.prelude.collapsedCondition() == wanted:
      blocks.add blk
  if blocks.len > 1:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: "The stylesheet has " & $blocks.len & " `" & condition &
        "` blocks, so the one to hold the override cannot be identified. " &
        "Edit the stylesheet directly.")
  if blocks.len == 1:
    # The new rule goes after the block's last rule, indented like it.
    let blk = blocks[0]
    let inner = css[blk.bodyStart ..< blk.bodyEnd].strip(leading = false)
    let cut = blk.bodyStart + inner.len
    var indent = "  "
    let lastNewline = inner.rfind('\n')
    if lastNewline >= 0:
      indent = ""
      for c in inner[lastNewline + 1 .. ^1]:
        if c in {' ', '\t'}: indent.add c
        else: break
    let separator = if "\n" in css[blk.bodyStart ..< blk.bodyEnd]: "\n" & indent
                    else: " "
    return CssPatchResult(ok: true, outcome: cpoInserted, oldValue: "",
      content: css[0 ..< cut] & separator & ruleText &
        (if "\n" in css[blk.bodyStart ..< blk.bodyEnd]: css[cut .. ^1]
         else: " " & css[blk.bodyEnd .. ^1]))
  # No such block yet: add it at the end, on lines of its own.
  var head = css
  if head.len > 0 and not head.endsWith("\n"): head.add "\n"
  CssPatchResult(ok: true, outcome: cpoInserted, oldValue: "",
    content: head & condition.strip() & " {\n  " & ruleText & "\n}\n")

proc patchCssDeclarationUnder*(css, condition, selector, property,
    newValue: string): CssPatchResult =
  ## `patchCssDeclarationUnderUnguarded`, refused when its write would land inside
  ## what only the end of the sheet closes (`cssWriteRefusal`).
  css.cssWriteRefusal(patchCssDeclarationUnderUnguarded(css, condition,
    selector, property, newValue))

func nimConstBody*(nimSource, constName: string): string =
  ## The raw-string body of `const <constName> = """..."""`, or "".
  ##
  ## Exposed because a project implementing the preview fast path has to hand
  ## the editor the stylesheet as it appears in the rendered page -- the const's
  ## body, not the module around it. Locating it here means the fast path and
  ## the patcher agree about where the stylesheet is, rather than each carrying
  ## its own idea of it.
  let decl = "const " & constName & "* = \"\"\""
  var start = nimSource.find(decl)
  var declLen = decl.len
  if start < 0:
    let unexported = "const " & constName & " = \"\"\""
    start = nimSource.find(unexported)
    declLen = unexported.len
  if start < 0:
    return ""
  let bodyStart = start + declLen
  let bodyEnd = nimSource.find("\"\"\"", bodyStart)
  if bodyEnd < 0:
    return ""
  nimSource[bodyStart ..< bodyEnd]

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


proc patchCssInNimConstAt*(nimSource, constName, selector, property,
                           newValue: string; width: int;
                           answers: openArray[CssConditionAnswer] = []): CssPatchResult =
  ## `patchCssInNimConst`, but breakpoint-aware: the declaration lands in the
  ## rule that governs `property` at `width`, which may be inside an `@media`
  ## block in the same const.
  ##
  ## The const-locating half is deliberately identical to
  ## `patchCssInNimConst`'s and stays shared by reading the same declaration
  ## forms; only the patcher applied to the body differs.
  let decl = "const " & constName & "* = \"\"\""
  var start = nimSource.find(decl)
  var declLen = decl.len
  if start < 0:
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
  result = patchCssDeclarationAt(body, selector, property, newValue, width,
    answers)
  if not result.ok or result.outcome == cpoUnchanged:
    if result.outcome == cpoUnchanged:
      result.content = nimSource
    return
  result.content = nimSource[0 ..< bodyStart] & result.content &
    nimSource[bodyEnd .. ^1]

const radiusLonghands = ["border-top-left-radius", "border-top-right-radius",
  "border-bottom-right-radius", "border-bottom-left-radius"]

func removalOverlaps(property: string): seq[string] =
  ## Every other declaration that also sets `property`: the shorthands that
  ## reset it, `all` (which spares custom properties, `direction` and
  ## `unicode-bidi`), and -- for a shorthand -- the longhands that override
  ## it. Corner radii are paired here because `shorthandsFor` does not list
  ## them.
  for name in property.resettersOf():
    if name != property: result.add name
  if property in radiusLonghands: result.add "border-radius"
  if not property.startsWith("--") and
      property.toLowerAscii() notin ["direction", "unicode-bidi"]:
    result.add "all"
  for (longhand, shorthands) in shorthandsFor:
    if property in shorthands and longhand notin result: result.add longhand
  if property == "border-radius":
    for side in radiusLonghands: result.add side

proc removeCssDeclarationUnguarded(css, selector, property: string):
    CssPatchResult =
  ## Remove the ONE declaration of `property` that the rule for `selector`
  ## owns, leaving every other byte where it was.
  ##
  ## Reset (editor spec "Universal Patterns") reverts a property to its
  ## class, token or inherited value by removing the declaration that sets
  ## it. Exactly one declaration may be removed: every rule for `selector`,
  ## at any depth and under any condition, is searched, and anything but a
  ## single unconditional declaration is refused with the reason. Two
  ## declarations (a duplicate, or a `@media` override) are a cascade the
  ## author built on purpose; removing one of them is a guess about which
  ## one Reset means, and removing a conditional one would leave the base
  ## value standing while claiming the property was reset.
  ##
  ## A declaration on a line of its own takes the whole line with it; one
  ## that shares its line (`#a { width:1px; height:2px; }`) takes itself and
  ## the spaces after it. A comment after its `;` stays: it may describe the
  ## rule rather than this declaration, and losing it cannot be undone from
  ## the value alone.
  if selector.len == 0 or property.len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "A CSS removal needs both a selector and a property.")
  var hits: seq[tuple[condition: string, body: RuleSpan, decl: DeclSpan]] = @[]
  var rules = 0
  for rule in css.allRules():
    if not rule.selector.selectorMatches(selector): continue
    inc rules
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    var remaining = body
    while remaining.bodyStart < remaining.bodyEnd:
      let decl = css.findDeclaration(remaining, property)
      if decl.valueStart < 0: break
      hits.add (rule.condition, body, decl)
      remaining.bodyStart = decl.valueEnd + 1
  if rules == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "No rule for `" & selector & "` declares `" & property &
        "`, so there is no declaration to remove.")
  if hits.len == 0:
    return CssPatchResult(ok: false, outcome: cpoRuleNotFound,
      message: "There is no `" & property & "` declaration for `" & selector &
        "` to remove.")
  if hits.len > 1:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: $hits.len & " declarations set `" & property & "` for `" &
        selector & "`. Reset removes exactly one owning declaration and " &
        "cannot tell which of them is meant; edit the stylesheet directly.")
  let hit = hits[0]
  if hit.condition.len > 0:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: "The `" & property & "` declaration for `" & selector &
        "` is inside `" & hit.condition & "`. Reset removes only a " &
        "declaration that applies at every width.")
  # The one declaration must be the property's only setter for the selector.
  # A shorthand (or `all`) that also sets it, or longhands that override a
  # removed shorthand, keep a value in place: the property would not fall
  # back to its class, token or inherited value.
  for other in property.removalOverlaps():
    for rule in css.allRules():
      if not rule.selector.selectorMatches(selector): continue
      let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                          bodyEnd: rule.bodyEnd)
      if css.findDeclaration(body, other).valueStart >= 0:
        return CssPatchResult(ok: false, outcome: cpoAmbiguous,
          message: "`" & other & "` also sets `" & property & "` for `" &
            selector & "`, so removing this declaration would not reset " &
            "it to its class, token or inherited value. Edit the " &
            "stylesheet directly.")
  let existing = css[hit.decl.valueStart ..< hit.decl.valueEnd]
  let current = existing.cssDeclarationValue()
  var start = hit.decl.nameStart
  var stop = hit.decl.valueEnd
  if stop < hit.body.bodyEnd and css[stop] == ';': inc stop
  var lineStart = start
  while lineStart > 0 and css[lineStart - 1] in {' ', '\t'}: dec lineStart
  var after = stop
  while after < css.len and css[after] in {' ', '\t', '\r'}: inc after
  let ownLine = (lineStart == 0 or css[lineStart - 1] == '\n') and
    after < css.len and css[after] == '\n'
  if ownLine:
    start = lineStart
    stop = after + 1
  else:
    while stop < hit.body.bodyEnd and css[stop] in {' ', '\t'}: inc stop
  CssPatchResult(ok: true, outcome: cpoRemoved, oldValue: current,
    content: css[0 ..< start] & css[stop .. ^1])

proc removeCssDeclaration*(css, selector, property: string): CssPatchResult =
  ## `removeCssDeclarationUnguarded`, refused when its write would land inside
  ## what only the end of the sheet closes (`cssWriteRefusal`).
  css.cssWriteRefusal(removeCssDeclarationUnguarded(css, selector, property))

proc removeCssInNimConst*(nimSource, constName, selector,
                          property: string): CssPatchResult =
  ## `removeCssDeclaration` inside a Nim raw-string const, located exactly as
  ## `patchCssInNimConst` locates it.
  let decl = "const " & constName & "* = \"\"\""
  var start = nimSource.find(decl)
  var declLen = decl.len
  if start < 0:
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
  result = removeCssDeclaration(nimSource[bodyStart ..< bodyEnd], selector,
    property)
  if result.ok:
    result.content = nimSource[0 ..< bodyStart] & result.content &
      nimSource[bodyEnd .. ^1]

func editTargetInNimConst*(nimSource, constName, selector, property: string;
                           width: int;
                           answers: openArray[CssConditionAnswer] = []): CssEditTarget =
  ## `editTargetAtWidth` against a stylesheet held in a Nim const.
  ##
  ## Separate from the patch so the UI can ask "where would this go?" without
  ## writing anything -- which is what makes the breakpoint indicator ambient
  ## rather than a report on what just happened.
  let decl = "const " & constName & "* = \"\"\""
  var start = nimSource.find(decl)
  var declLen = decl.len
  if start < 0:
    let unexported = "const " & constName & " = \"\"\""
    start = nimSource.find(unexported)
    declLen = unexported.len
  if start < 0:
    return CssEditTarget(found: false)
  let bodyStart = start + declLen
  let bodyEnd = nimSource.find("\"\"\"", bodyStart)
  if bodyEnd < 0:
    return CssEditTarget(found: false)
  nimSource[bodyStart ..< bodyEnd].editTargetAtWidth(selector, property,
    width, answers)

proc cssRuleSelectors*(css: string): seq[string] =
  ## Read candidates through the same rule scanner used by source patching.
  ## Conditions are deliberately included: native binding must account for
  ## every potentially overriding rule before advertising a direct writer.
  for rule in css.allRules():
    for selector in rule.selector.withoutComments().split(','):
      let candidate = selector.strip()
      if candidate.len > 0 and candidate notin result: result.add candidate

type CssLiteralRule* = object
  selector*: string
  values*: seq[tuple[property, value: string]]
  declarationPositions*: seq[tuple[property: string, position: int]]
  blockedProperties*: seq[string]

proc cssCustomPropertyOwners*(css: string; properties: seq[string]): seq[tuple[selector, condition, property: string]] =
  ## Capability discovery must see overriding/duplicate owners even though
  ## their declarations cannot themselves become writable capabilities.
  for rule in css.allRules():
    let body = RuleSpan(selector:rule.selector,bodyStart:rule.bodyStart,bodyEnd:rule.bodyEnd)
    for property in properties:
      if not property.startsWith("--"): continue
      var remaining = body
      while remaining.bodyStart < remaining.bodyEnd:
        let declaration = css.findDeclaration(remaining,property)
        if declaration.valueStart < 0: break
        result.add (rule.selector.withoutComments().strip(),rule.condition,property)
        remaining.bodyStart = declaration.valueEnd + 1

func capabilityResetters(property: string): seq[string] =
  ## CSS all excludes custom properties, direction and unicode-bidi. Discovery
  ## sees the reset without changing the ordinary property patcher's grammar.
  result = property.resettersOf()
  if not property.startsWith("--") and property.toLowerAscii() notin ["direction", "unicode-bidi"]:
    result.add "all"

proc cssPropertyOwners*(css: string; properties: seq[string]): seq[tuple[selector, condition, property: string]] =
  ## Read every possible owner, including shorthand resets and unsupported
  ## conditions. Attribution uses this projection; it does not authorize edits.
  for rule in css.allRules():
    let body = RuleSpan(selector:rule.selector,bodyStart:rule.bodyStart,bodyEnd:rule.bodyEnd)
    for property in properties:
      for resetter in property.capabilityResetters():
        if css.findDeclaration(body, resetter).valueStart >= 0:
          for member in rule.selector.withoutComments().split(','):
            result.add (member.strip(),rule.condition,property)
          break

proc cssUnconditionalLiterals*(css: string; properties: seq[string]): seq[CssLiteralRule] =
  ## Read supported direct declarations once through the patcher's scanner.
  ## Conditional/resetting owners and duplicate base rules are withheld rather
  ## than presenting a guessed viewport/state value as source authority.
  var rules: seq[NestedRule]
  for rule in css.allRules(): rules.add rule
  # A rule inside what only the end of the sheet closes is never offered:
  # the writers refuse to write there (`cssWriteRefusal`), and a browser may
  # not apply it as a top-level rule at all. It still counts as an owner.
  let tail = css.cssOpenTail()
  for base in rules:
    if base.condition.len > 0: continue
    if tail.at >= 0 and base.bodyStart > tail.at: continue
    for member in base.selector.withoutComments().split(','):
      let selector = member.strip()
      var owners = 0
      for rule in rules:
        if rule.condition.len == 0 and rule.selector.selectorMatches(selector): inc owners
      if owners != 1: continue
      var literal = CssLiteralRule(selector: selector)
      let body = RuleSpan(selector: base.selector, bodyStart: base.bodyStart, bodyEnd: base.bodyEnd)
      for property in properties:
        if property.len == 0: continue
        # A global reset is an unsupported effective owner for ordinary
        # properties. Conservatively refuse either order, including priority.
        if "all" in property.capabilityResetters() and css.findDeclaration(body,"all").valueStart >= 0:
          literal.blockedProperties.add property
          continue
        var conditional = false
        for rule in rules:
          if rule.condition.len == 0 or not rule.selector.selectorMatches(selector): continue
          let other = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart, bodyEnd: rule.bodyEnd)
          for resetter in property.capabilityResetters():
            if css.findDeclaration(other, resetter).valueStart >= 0: conditional = true
        if conditional:
          literal.blockedProperties.add property
          continue
        let declaration = css.findDeclaration(body, property)
        if declaration.valueStart < 0: continue
        let remaining = RuleSpan(selector:body.selector,bodyStart:declaration.valueEnd + 1,bodyEnd:body.bodyEnd)
        if css.findDeclaration(remaining,property).valueStart >= 0:
          literal.blockedProperties.add property
          continue
        let existing = css[declaration.valueStart ..< declaration.valueEnd]
        # As the writers report it (`oldValue`), so a native edit's
        # expected value is the value the patch then finds.
        let value = existing.cssDeclarationValue()
        if value.len > 0:
          literal.values.add((property, value))
          literal.declarationPositions.add((property,declaration.valueStart))
      if literal.values.len > 0: result.add literal

proc cssSelectorListRefusal*(css, selector, property: string): string =
  ## Why an edit or removal of `property` for `selector` would not be this
  ## selector's alone, or "" when it would be. A rule whose selector is a list
  ## (`.a, .b { ... }`) styles every selector in it, so a declaration there --
  ## or one added to it when no rule declares the property yet -- changes
  ## them all (editor spec "Saving": an edit changes exactly the one owning
  ## declaration). The patcher itself still treats a list as a home for any
  ## of its members; the editor's writers ask this first and refuse.
  let wanted = selector.strip()
  if wanted.len == 0 or property.len == 0: return
  let message = proc(list: string): string =
    "`" & wanted & "` is styled here by the selector list `" & list &
      "`; changing `" & property & "` there would change every selector " &
      "in the list. Edit the stylesheet directly."
  var declared = false
  var baseRules: seq[string] = @[]
  for rule in css.allRules():
    var members: seq[string] = @[]
    for member in rule.selector.withoutComments().split(','):
      members.add member.strip()
    if wanted notin members: continue
    let list = rule.selector.withoutComments().strip()
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    var sets = false
    for resetter in property.capabilityResetters():
      if css.findDeclaration(body, resetter).valueStart >= 0: sets = true
    if sets:
      declared = true
      if members.len > 1: return message(list)
    if rule.condition.len == 0:
      baseRules.add (if members.len > 1: list else: "")
  # Nothing declares it: a value would be inserted into the selector's one
  # top-level rule, which must not be a list either.
  if not declared and baseRules.len == 1 and baseRules[0].len > 0:
    return message(baseRules[0])

proc cssInsertionHome*(css, selector, property: string): bool =
  ## Whether a value for `property` would be inserted into the one rule for
  ## `selector`, and nowhere else: exactly one rule names the selector, at
  ## the top level, alone (not in a list), and nothing in it sets the
  ## property yet. Used to keep offering a property after Reset removed its
  ## last declaration.
  let wanted = selector.strip()
  if wanted.len == 0 or property.len == 0: return false
  var owners = 0
  var home = false
  for rule in css.allRules():
    var members: seq[string] = @[]
    for member in rule.selector.withoutComments().split(','):
      members.add member.strip()
    if wanted notin members: continue
    inc owners
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    var sets = false
    for resetter in property.capabilityResetters():
      if css.findDeclaration(body, resetter).valueStart >= 0: sets = true
    home = rule.condition.len == 0 and members.len == 1 and not sets
  owners == 1 and home
