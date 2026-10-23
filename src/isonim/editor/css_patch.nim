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
  nameStart: int   ## first byte of the property name
  valueStart: int  ## first byte after the `:`
  valueEnd: int    ## exclusive; the `;` or the closing `}`

func skipCssQuotedValue(css: string; at, limit: int): int =
  let quote = css[at]
  result = at + 1
  while result < limit:
    if css[result] == '\\': result += 2
    elif css[result] == quote: return result + 1
    else: inc result
  result = min(result,limit)

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
    if css[i] in {'\'', '"'}:
      i = css.skipCssQuotedValue(i,body.bodyEnd)
      continue
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
            if css[valueEnd] in {'\'', '"'}:
              valueEnd = css.skipCssQuotedValue(valueEnd,body.bodyEnd)
              continue
            # A comment inside the value is part of the value's span but must
            # not hide a `;` that follows it.
            if valueEnd + 1 < css.len and css[valueEnd] == '/' and
               css[valueEnd + 1] == '*':
              let close = css.find("*/", valueEnd + 2)
              valueEnd = if close < 0: body.bodyEnd else: close + 2
              continue
            valueEnd += 1
          return DeclSpan(nameStart: i, valueStart: j + 1, valueEnd: valueEnd)
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

# ---------------------------------------------------------------------------
#  Responsive overrides: a declaration written under a named breakpoint.
# ---------------------------------------------------------------------------

func collapsedCondition(condition: string): string =
  ## An at-rule prelude compared without its incidental whitespace, so the
  ## stylesheet's `@media (max-width: 980px)` and a caller's copy of it with a
  ## different line break or indentation name the same block.
  condition.withoutComments().splitWhitespace().join(" ")

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
    if i + 1 < css.len and css[i] == '/' and css[i + 1] == '*':
      let close = css.find("*/", i + 2)
      i = if close < 0: css.len else: close + 2
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

proc patchCssDeclarationUnder*(css, condition, selector, property,
                               newValue: string): CssPatchResult =
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
      let comment = existing.trailingComment()
      let current = (if comment.len > 0: existing[0 ..< existing.find("/*")]
                     else: existing).strip()
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
      if current == value:
        return CssPatchResult(ok: true, outcome: cpoUnchanged, content: css,
                              oldValue: current)
      let lead = if css[decl.valueStart] in {' ', '\t'}: " " else: ""
      return CssPatchResult(ok: true, outcome: cpoReplaced, oldValue: current,
        content: css[0 ..< decl.valueStart] & lead & value &
          (if comment.len > 0: " " & comment else: "") &
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

proc removeCssDeclaration*(css, selector, property: string): CssPatchResult =
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
  let comment = existing.trailingComment()
  let current = (if comment.len > 0: existing[0 ..< existing.find("/*")]
                 else: existing).strip()
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
  for base in rules:
    if base.condition.len > 0: continue
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
        let comment = existing.trailingComment()
        let value = (if comment.len > 0: existing[0 ..< existing.find("/*")] else: existing).strip()
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
