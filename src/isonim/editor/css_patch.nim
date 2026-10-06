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
    reason*: string      ## Why this rule, in one sentence, for the UI.

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

type NestedRule = object
  ## A rule at ANY depth, with the at-rule conditions enclosing it.
  selector: string
  condition: string    ## All enclosing preludes, outermost first, " and "-joined.
  bodyStart: int
  bodyEnd: int

iterator allRules(css: string): NestedRule =
  ## Every rule, including those nested inside at-rules, with the full stack of
  ## conditions it sits under.
  ##
  ## `topLevelRules` deliberately skips at-rule contents, because a patch must
  ## never land inside a `@media` block it was not asked about. That is the
  ## right rule for the UNCONDITIONAL write path and the wrong one for asking
  ## "what governs this property at this width", since the answer is usually
  ## exactly the thing in the `@media` block. Two iterators, two questions --
  ## not one iterator with a flag, because the unconditional write path must
  ## not be able to acquire this behaviour by accident.
  ##
  ## The conditions are a STACK, not a single value: `@supports` wrapping
  ## `@media` is a rule that applies only when both hold, and a reader told
  ## only about the inner one would be told something false.
  var i = 0
  var open: seq[tuple[selector, prelude: string; bodyStart: int]] = @[]
  var selectorStart = 0
  while i < css.len:
    if i + 1 < css.len and css[i] == '/' and css[i + 1] == '*':
      let close = css.find("*/", i + 2)
      i = if close < 0: css.len else: close + 2
      continue
    case css[i]
    of '{':
      let text = css[selectorStart ..< i].strip().withoutComments().strip()
      if text.startsWith("@"):
        open.add (selector: "", prelude: text, bodyStart: i + 1)
      else:
        open.add (selector: text, prelude: "", bodyStart: i + 1)
      selectorStart = i + 1
      i += 1
    of '}':
      if open.len > 0:
        let closed = open.pop()
        if closed.selector.len > 0:
          var conditions: seq[string] = @[]
          for frame in open:
            if frame.prelude.len > 0:
              conditions.add frame.prelude
          yield NestedRule(selector: closed.selector,
                           condition: conditions.join(" and "),
                           bodyStart: closed.bodyStart, bodyEnd: i)
      selectorStart = i + 1
      i += 1
    else:
      i += 1

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

func editTargetAtWidth*(css, selector, property: string;
                        width: int): CssEditTarget =
  ## The rule that should receive `property` for `selector` at `width` px.
  ##
  ## This is the whole of breakpoint-aware editing, and it is one rule:
  ##
  ##   **Write where the value is already decided.** Of every rule that matches
  ##   the selector and applies at this width, take the LAST one that declares
  ##   the property or a shorthand setting it. That rule is the one currently
  ##   winning, so it is the one that has to change for anything to happen.
  ##
  ##   **If nothing declares it, write to the base rule.** A property no rule
  ##   mentions has no responsive intent to respect, and scoping it to whatever
  ##   breakpoint happens to be on screen would invent one.
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
  let targets = property.resettersOf()
  var rules: seq[NestedRule] = @[]
  for rule in css.allRules():
    rules.add rule
  # Document order. `allRules` yields on the closing brace, so a nested rule
  # is yielded before the block containing it.
  for i in 1 ..< rules.len:
    var j = i
    while j > 0 and rules[j - 1].bodyStart > rules[j].bodyStart:
      swap(rules[j - 1], rules[j])
      j -= 1

  var base = CssEditTarget(found: false)
  var winner = CssEditTarget(found: false)
  for rule in rules:
    if not rule.selector.selectorMatches(selector):
      continue
    if rule.condition.len == 0:
      base = CssEditTarget(found: true, condition: "",
                           selector: rule.selector, isBreakpoint: false,
                           reason: "the base rule for `" & selector & "`")
    if not rule.condition.conditionMatchesWidth(width):
      continue
    let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                        bodyEnd: rule.bodyEnd)
    for candidate in targets:
      if css.findDeclaration(body, candidate).valueStart >= 0:
        winner = CssEditTarget(
          found: true, condition: rule.condition, selector: rule.selector,
          isBreakpoint: rule.condition.len > 0,
          reason:
            if rule.condition.len > 0:
              "`" & candidate & "` is set for `" & selector & "` in " &
                rule.condition & ", which is what applies at " & $width & "px"
            else:
              "`" & candidate & "` is set for `" & selector & "` in the base rule")
        break
  if winner.found: winner else: base

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

proc patchCssDeclarationAt*(css, selector, property, newValue: string;
                            width: int): CssPatchResult =
  ## `patchCssDeclaration`, but into the rule that governs `property` at
  ## `width` -- which may be inside an `@media` block.
  ##
  ## Falls back to the plain top-level patch when the governing rule IS the
  ## base rule, so the unconditional path keeps its refusals (ambiguous
  ## selector, missing rule) and its byte-for-byte behaviour.
  let target = css.editTargetAtWidth(selector, property, width)
  if not target.found or not target.isBreakpoint:
    return patchCssDeclaration(css, selector, property, newValue)

  # Locate the one rule matching BOTH the selector and the condition.
  var matches: seq[NestedRule] = @[]
  for rule in css.allRules():
    if rule.condition == target.condition and
        rule.selector.selectorMatches(selector):
      matches.add rule
  if matches.len != 1:
    return CssPatchResult(ok: false, outcome: cpoAmbiguous,
      message: $matches.len & " rules declare `" & selector & "` in " &
        target.condition & ". Which one owns `" & property &
        "` is a decision this patch cannot make; edit the stylesheet directly.")

  let rule = matches[0]
  let body = RuleSpan(selector: rule.selector, bodyStart: rule.bodyStart,
                      bodyEnd: rule.bodyEnd)
  let decl = css.findDeclaration(body, property)
  if decl.valueStart >= 0:
    let existing = css[decl.valueStart ..< decl.valueEnd]
    let comment = existing.trailingComment()
    let current = (if comment.len > 0: existing[0 ..< existing.find("/*")]
                   else: existing).strip()
    if current == newValue:
      return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                            oldValue: current)
    return CssPatchResult(ok: true, outcome: cpoReplaced,
      content: css[0 ..< decl.valueStart] & newValue &
        (if comment.len > 0: " " & comment else: "") &
        css[decl.valueEnd .. ^1],
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
                           newValue: string; width: int): CssPatchResult =
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
  result = patchCssDeclarationAt(body, selector, property, newValue, width)
  if not result.ok or result.outcome == cpoUnchanged:
    if result.outcome == cpoUnchanged:
      result.content = nimSource
    return
  result.content = nimSource[0 ..< bodyStart] & result.content &
    nimSource[bodyEnd .. ^1]

func editTargetInNimConst*(nimSource, constName, selector, property: string;
                           width: int): CssEditTarget =
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
  nimSource[bodyStart ..< bodyEnd].editTargetAtWidth(selector, property, width)
