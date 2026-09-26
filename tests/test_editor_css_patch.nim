## `css_patch` — editing one declaration without disturbing the rest.
##
## The fixtures are transcribed from the grip pilot's own
## `src/components/styles.nim`, including its comments and its alignment,
## because those are exactly what a patch is most likely to damage and what
## a reviewer would lose first.

import std/[unittest, strutils]
import isonim/editor/css_patch

const gripCss = """
  /* ---------- reset ---------- */
  *,*::before,*::after { box-sizing:border-box; }          /* STRUCTURAL */
  html,body { margin:0; }
  body { background:var(--sys-color-surface-page);
         color:var(--sys-color-text-primary);
         font:var(--sys-type-body);
         font-size:16px;                 /* OPTICAL: the page's reading size
                                            sits between `body` 15 and `prose`
                                            16.5 */
         -webkit-font-smoothing:antialiased; }

  .site-header { position:sticky; top:0; z-index:50;       /* STRUCTURAL */
                 backdrop-filter:blur(8px); }

  @media (prefers-color-scheme: dark) {
    .site-header { background:var(--sys-color-surface-page); }
  }

  .tagline { font:var(--sys-type-display);
             letter-spacing:var(--sys-tracking-display);
             margin:0 0 30px;              /* OPTICAL: between `block` and
                                              `section`, tuned to the 40px line */
             text-wrap:balance; }
  .tagline-clause { display:block; }                       /* STRUCTURAL */
"""

suite "css_patch: replacing an existing declaration":

  test "the value changes and nothing else moves":
    let r = patchCssDeclaration(gripCss, ".tagline", "letter-spacing", "0.02em")
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "var(--sys-tracking-display)"
    check "letter-spacing:0.02em;" in r.content
    # Every neighbour in the rule survives byte-for-byte.
    check "font:var(--sys-type-display);" in r.content
    check "text-wrap:balance; }" in r.content
    # And so does the rest of the file.
    check ".tagline-clause { display:block; }" in r.content
    check r.content.len == gripCss.len -
      "var(--sys-tracking-display)".len + "0.02em".len

  test "a trailing comment stays attached to its declaration":
    ## The comment explains the DECLARATION, not the old number. Dropping it
    ## on edit would strip the stylesheet's reasoning one property at a time.
    let r = patchCssDeclaration(gripCss, ".tagline", "margin", "0 0 40px")
    check r.ok
    check r.oldValue == "0 0 30px"
    check "margin:0 0 40px;" in r.content
    check "OPTICAL: between `block` and" in r.content
    check "tuned to the 40px line */" in r.content

  test "setting the value it already has is a no-op, not a rewrite":
    let r = patchCssDeclaration(gripCss, ".tagline", "text-wrap", "balance")
    check r.ok
    check r.outcome == cpoUnchanged
    check r.content == gripCss

suite "css_patch: choosing the right rule":

  test "a selector inside an at-rule does not shadow the top-level one":
    ## `.site-header` is declared twice — once at the top level and once
    ## inside `@media (prefers-color-scheme: dark)`. A scan that matched on
    ## selector text alone would patch whichever came first.
    let r = patchCssDeclaration(gripCss, ".site-header", "top", "8px")
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "0"
    check "position:sticky; top:8px; z-index:50;" in r.content
    # The dark-mode rule is untouched.
    check ".site-header { background:var(--sys-color-surface-page); }" in
      r.content

  test "a prefix of another selector is not a match":
    ## `.tagline` must not reach `.tagline-clause`, in either direction.
    let r = patchCssDeclaration(gripCss, ".tagline-clause", "display", "flex")
    check r.ok
    check "'.tagline-clause { display:flex; }".replace("'", "") in r.content
    check "font:var(--sys-type-display);" in r.content

  test "a grouped selector is a legitimate home for the declaration":
    const grouped = """
  html,body { margin:0; }
  .page { color:red; }
"""
    let r = patchCssDeclaration(grouped, "body", "margin", "8px")
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "0"
    check "html,body { margin:8px; }" in r.content

  test "a selector that a group ALSO names is ambiguous, and refused":
    ## grip declares `html,body { margin:0 }` and then `body { ... }`. Asking
    ## for `body` is asking about two rules, and choosing one would silently
    ## change which declaration wins. This is the safe answer, not a gap.
    let r = patchCssDeclaration(gripCss, "body", "font-size", "17px")
    check not r.ok
    check r.outcome == cpoAmbiguous
    check "2 top-level rules" in r.message

  test "an unknown selector refuses and says where to look":
    let r = patchCssDeclaration(gripCss, ".nope", "color", "red")
    check not r.ok
    check r.outcome == cpoRuleNotFound
    check "No top-level rule" in r.message
    check ".nope" in r.message

  test "two top-level rules for one selector refuse rather than guess":
    ## Two rules for one selector is a cascade the author built on purpose.
    ## Picking one silently changes which of the two wins.
    const doubled = """
  .card { color:red; }
  .card { color:blue; }
"""
    let r = patchCssDeclaration(doubled, ".card", "color", "green")
    check not r.ok
    check r.outcome == cpoAmbiguous
    check "2 top-level rules" in r.message
    check "cannot make" in r.message

suite "css_patch: declarations the author never wrote":

  test "a missing declaration is inserted into the rule":
    ## The inspector offers `font-size` on a rule that only declares the
    ## `font` shorthand. Refusing there would make most of the panel inert.
    let r = patchCssDeclaration(gripCss, ".tagline", "font-size", "42px")
    check r.ok
    check r.outcome == cpoInserted
    check r.oldValue == ""
    check "font-size:42px;" in r.content
    # It lands inside the rule, after the last declaration.
    let ruleStart = r.content.find(".tagline {")
    let ruleEnd = r.content.find("}", ruleStart)
    let inserted = r.content.find("font-size:42px;")
    check inserted > ruleStart
    check inserted < ruleEnd
    # And the existing declarations are all still there.
    check "text-wrap:balance;" in r.content
    check "letter-spacing:var(--sys-tracking-display);" in r.content

  test "an inserted declaration matches its neighbours' indentation":
    let r = patchCssDeclaration(gripCss, ".tagline", "font-size", "42px")
    check r.ok
    var found = false
    for line in r.content.splitLines():
      if "font-size:42px;" in line:
        found = true
        # `.tagline`'s declarations are aligned under the selector at 13
        # spaces; a patch that ignored that would be obvious in the diff.
        check line.startsWith("             font-size:42px;")
    check found

  test "inserting into a single-line rule keeps it on one line":
    const oneLine = "  .chip { color:red; }\n"
    let r = patchCssDeclaration(oneLine, ".chip", "padding", "4px")
    check r.ok
    check r.outcome == cpoInserted
    check r.content == "  .chip { color:red; padding:4px; }\n"

  test "a rule with no trailing semicolon still gains one":
    const noSemi = "  .chip { color:red }\n"
    let r = patchCssDeclaration(noSemi, ".chip", "padding", "4px")
    check r.ok
    check r.content == "  .chip { color:red; padding:4px; }\n"

  test "an empty rule accepts its first declaration":
    const empty = "  .chip { }\n"
    let r = patchCssDeclaration(empty, ".chip", "color", "red")
    check r.ok
    check "color:red;" in r.content

suite "css_patch: not matching the wrong text":

  test "a shorthand is not mistaken for its longhand, or the reverse":
    ## `.tagline` declares `font`; the inspector's Font size row edits
    ## `font-size`. Matching on a substring would have one overwrite the
    ## other, which is a silently wrong stylesheet rather than an error.
    let a = patchCssDeclaration(gripCss, ".tagline", "font", "12px/1.2 serif")
    check a.ok
    check a.outcome == cpoReplaced
    check a.oldValue == "var(--sys-type-display)"
    check "letter-spacing:var(--sys-tracking-display);" in a.content

    let b = patchCssDeclaration(gripCss, ".tagline", "font-size", "42px")
    check b.ok
    check b.outcome == cpoInserted
    check "font:var(--sys-type-display);" in b.content

  test "a property named inside a comment is not a declaration":
    const commented = """
  .chip { /* margin:0 is deliberate, do not add it back */
          color:red; }
"""
    let r = patchCssDeclaration(commented, ".chip", "color", "blue")
    check r.ok
    check r.oldValue == "red"
    check "margin:0 is deliberate" in r.content
    # The comment's `margin` was not treated as a declaration to patch.
    let m = patchCssDeclaration(commented, ".chip", "margin", "8px")
    check m.ok
    check m.outcome == cpoInserted

  test "a selector named inside a comment does not open a rule":
    const commented = """
  /* .ghost { color:red; } was removed in review */
  .real { color:blue; }
"""
    let r = patchCssDeclaration(commented, ".ghost", "color", "green")
    check not r.ok
    check r.outcome == cpoRuleNotFound

suite "css_patch: refusals":

  test "an empty selector or property is refused":
    check not patchCssDeclaration(gripCss, "", "color", "red").ok
    check not patchCssDeclaration(gripCss, ".tagline", "", "red").ok

suite "css_patch: stylesheets that live in a Nim raw-string const":
  ## The IsoNim idiom: a project that renders on both sides keeps its CSS as
  ## a `const` so the same bytes reach SSR and the client.

  const module = """import ../design_system/tokens

const structureCssText* = """ & "\"\"\"" & """
  .tagline { font:var(--sys-type-display);
             margin:0 0 30px; }
  .chip { color:red; }
""" & "\"\"\"" & """

const globalCss* = tokenCss & structureCssText
"""

  test "the declaration is patched inside the literal":
    let r = patchCssInNimConst(module, "structureCssText", ".chip",
                               "color", "blue")
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "red"
    check ".chip { color:blue; }" in r.content
    # The module around the literal survives.
    check "import ../design_system/tokens" in r.content
    check "const globalCss* = tokenCss & structureCssText" in r.content
    check r.content.endsWith("\n")

  test "a selector that appears outside the literal is out of range":
    ## The whole reason the const is located first: a class named in a doc
    ## comment or in ordinary code must not be reachable by a source edit.
    const withDecoy = """## The `.chip { color:red; }` rule is explained here.

const structureCssText* = """ & "\"\"\"" & """
  .other { color:green; }
""" & "\"\"\"" & """
"""
    let r = patchCssInNimConst(withDecoy, "structureCssText", ".chip",
                               "color", "blue")
    check not r.ok
    check r.outcome == cpoRuleNotFound
    # The doc comment is untouched, because nothing was written.
    check r.content.len == 0

  test "a missing const refuses by name":
    let r = patchCssInNimConst(module, "nopeCss", ".chip", "color", "blue")
    check not r.ok
    check "`nopeCss` is not a raw-string const" in r.message

  test "an unchanged value returns the whole module, not just the CSS":
    let r = patchCssInNimConst(module, "structureCssText", ".chip",
                               "color", "red")
    check r.ok
    check r.outcome == cpoUnchanged
    check r.content == module
