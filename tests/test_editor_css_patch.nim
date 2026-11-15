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

  test "a rule reached past the previous rule's trailing comment":
    ## grip comments nearly every rule on the line it closes, so a rule's
    ## selector text almost always begins with the PREVIOUS rule's comment.
    ## The fixture above has exactly that shape between `.site-header` and
    ## `.tagline`, and missing it made every real-file patch fail while every
    ## test passed.
    let r = patchCssDeclaration(gripCss, ".tagline", "text-wrap", "pretty")
    check r.ok
    check r.outcome == cpoReplaced
    check "text-wrap:pretty; }" in r.content
    # And the comment that preceded it is still there.
    check "/* STRUCTURAL */" in r.content

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

suite "css_patch: a value edit keeps the declaration's priority":
  ## isonim-pm issue 2026-11-15-a-value-edit-writes-the-declaration-without-
  ## its-important-while-the-preview-keeps-it. Editor spec "Saving" (an edit
  ## changes the one declaration that owns the property) and "Visual box
  ## model" (the preview shows the same values before the write and after
  ## it): the preview keeps a declaration's `!important` and never adds one,
  ## and the inspector field takes a value without one, so the written file
  ## keeps the priority as written and gains none. CSS allows whitespace and
  ## comments between `!` and `important`, in either case
  ## (https://www.w3.org/TR/css-syntax-3/#consume-declaration).

  const issueCss = ".destination-card { padding: 18px !important; }\n" &
    ".long-tail-card { padding: 30px; }\n"

  test "the issue's case: a shorthand keeps its !important; the old value is reported as written":
    let r = patchCssDeclaration(issueCss, ".destination-card", "padding", "20px")
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "18px !important"
    check r.content == ".destination-card { padding: 20px !important; }\n" &
      ".long-tail-card { padding: 30px; }\n"

  test "a longhand keeps its !important, and a neighbour without one gains none":
    let css = ".card { padding: 18px; padding-top: 24px !important; margin:0; }"
    let r = patchCssDeclaration(css, ".card", "padding-top", "30px")
    check r.content == ".card { padding: 18px; padding-top: 30px !important; margin:0; }"
    let s = patchCssDeclaration(css, ".card", "padding", "20px")
    check s.content == ".card { padding: 20px; padding-top: 24px !important; margin:0; }"

  test "no priority is manufactured: a plain declaration and an inserted one stay plain":
    let css = ".card { padding: 18px; }"
    check patchCssDeclaration(css, ".card", "padding", "20px").content ==
      ".card { padding: 20px; }"
    check patchCssDeclaration(css, ".card", "margin", "4px").content ==
      ".card { padding: 18px; margin:4px; }"
    let under = patchCssDeclarationUnder(css, "@media (max-width: 640px)",
      ".card", "padding", "6px")
    check under.ok
    check "important" notin under.content

  test "whitespace, case and comments in the priority are kept as written":
    for (declared, written) in [
        ("18px ! important", "20px ! important"),
        ("18px !IMPORTANT", "20px !IMPORTANT"),
        ("18px!important", "20px!important"),
        ("18px !\timportant", "20px !\timportant"),
        ("18px ! /* keep */ important", "20px ! /* keep */ important"),
        ("18px !important /* why */", "20px !important /* why */"),
        ("18px /* note */ !important", "20px /* note */ !important")]:
      let css = ".card { padding: " & declared & "; }"
      let r = patchCssDeclaration(css, ".card", "padding", "20px")
      check r.ok
      check r.outcome == cpoReplaced
      check r.content == ".card { padding: " & written & "; }"

  test "a word that only ends in important, or a value that names it, is not a priority":
    check cssPrioritySuffix("url(unimportant)") == ""
    check cssPrioritySuffix("'important'") == ""
    check cssPrioritySuffix("x important") == ""
    check cssPrioritySuffix("18px ! IMPORTANT ") == " ! IMPORTANT"
    check patchCssDeclaration(".a { content: 'important'; }", ".a", "content",
      "'x'").content == ".a { content: 'x'; }"

  test "the same value without its priority is no change; a value that states one replaces it":
    let unchanged = patchCssDeclaration(issueCss, ".destination-card", "padding", "18px")
    check unchanged.outcome == cpoUnchanged
    check unchanged.content == issueCss
    # A value that states its own priority is written as given (an undo that
    # puts back the text a write replaced).
    let plain = ".card { padding: 20px; }"
    check patchCssDeclaration(plain, ".card", "padding", "18px !important").content ==
      ".card { padding: 18px !important; }"

  test "an edit and its undo restore the declaration byte for byte":
    let css = ".card { padding: 18px ! IMPORTANT; }"
    let forward = patchCssDeclaration(css, ".card", "padding", "20px")
    check forward.content == ".card { padding: 20px ! IMPORTANT; }"
    # Undo writes the old value back, as the field shows it or as written.
    let undone = patchCssDeclaration(forward.content, ".card", "padding", "18px")
    check undone.content == css
    let undoneWritten = patchCssDeclaration(forward.content, ".card", "padding",
      forward.oldValue)
    check undoneWritten.content == css
    let redone = patchCssDeclaration(undone.content, ".card", "padding", "20px")
    check redone.content == forward.content

  test "the breakpoint-aware and override writers keep it too":
    let media = ".x { padding: 1px; }\n@media (max-width: 1080px) { .x { padding: 2px !important; } }\n"
    let at = patchCssDeclarationAt(media, ".x", "padding", "5px", 850)
    check at.ok
    check at.oldValue == "2px !important"
    check at.content == ".x { padding: 1px; }\n@media (max-width: 1080px) { .x { padding:5px !important; } }\n"
    check patchCssDeclarationAt(media, ".x", "padding", "2px", 850).outcome == cpoUnchanged
    let under = patchCssDeclarationUnder(media, "@media (max-width: 1080px)",
      ".x", "padding", "6px")
    check under.ok
    check under.oldValue == "2px !important"
    check under.content == ".x { padding: 1px; }\n@media (max-width: 1080px) { .x { padding: 6px !important; } }\n"
    # Removing the override removes its priority with it.
    check "important" notin patchCssDeclarationUnder(media,
      "@media (max-width: 1080px)", ".x", "padding", "").content

  test "inside a Nim const, the native writer keeps it":
    let module = "const styles* = \"\"\".panel { padding:8px !important; }\"\"\"\n"
    let r = patchCssInNimConstAt(module, "styles", ".panel", "padding", "10px", 1440)
    check r.ok
    check r.oldValue == "8px !important"
    check r.content == "const styles* = \"\"\".panel { padding:10px !important; }\"\"\"\n"

  # Round-1 review residuals R2-R4 (isonim-pm issue 2026-11-15-a-value-edit-
  # writes-the-declaration-without-its-important-...): comments are read as
  # CSS reads them (https://www.w3.org/TR/css-syntax-3/#consume-comment): one
  # runs from `/*` to the FIRST `*/` and does not nest, and `/*` inside a
  # quoted string is text.
  proc edit(declared, newValue: string): CssPatchResult =
    patchCssDeclaration(".card { padding: " & declared & "; }", ".card",
      "padding", newValue)
  proc written(r: CssPatchResult): string =
    r.content[".card { padding: ".len ..< r.content.len - "; }".len]

  test "R2: a comment holding `/*` after the priority does not hide it":
    check cssPrioritySuffix("18px !important /* a /* b */") ==
      " !important /* a /* b */"
    let r = edit("18px !important /* a /* b */", "20px")
    check r.outcome == cpoReplaced
    check r.oldValue == "18px !important"
    check r.written == "20px !important /* a /* b */"
    # A priority written only inside a comment is not one, whatever the
    # comment holds.
    check cssPrioritySuffix("18px /* x !important /* */") == ""
    check edit("18px /* x !important /* */", "20px").written ==
      "20px /* x !important /* */"
    check cssPrioritySuffix("18px /* !important */") == ""
    check edit("18px /* !important */", "20px").written == "20px /* !important */"

  test "R2: what the reviewer's detection probe reads as a priority, and what not":
    for (value, suffix) in [("\"!important\"", ""), ("\"a\" !important", " !important"),
        ("url(a!important)", ""), ("18px ! /*c*/ important", " ! /*c*/ important"),
        ("a!", ""), ("!", ""), ("a !ie", ""), ("!important", "!important"),
        ("{!important}", ""), ("x/**/!/**/important/**/", "!/**/important/**/"),
        ("'/* x' !important", " !important"), ("\"*/\" /* c */ !important", " !important")]:
      check cssPrioritySuffix(value) == suffix
    check edit("18px !", "20px").written == "20px"
    check edit("18px !ie", "20px").written == "20px"
    let custom = ".x { --v: a!; --w: b !important; }"
    check patchCssDeclaration(custom, ".x", "--v", "c").content ==
      ".x { --v: c; --w: b !important; }"
    check patchCssDeclaration(custom, ".x", "--w", "c").content ==
      ".x { --v: a!; --w: c !important; }"

  test "R3: a new value that states its priority in any form is written as given, never doubled":
    for given in ["20px ! important", "20px !important /* c */",
        "20px ! /*c*/ important", "20px!IMPORTANT"]:
      let r = edit("18px !important", given)
      check r.outcome == cpoReplaced
      check r.written == given

  test "R3: the old value is the declaration as written, and writing it back is exact":
    let original = "20px ! /*c*/ important"
    let forward = edit(original, "18px")
    check forward.oldValue == original
    check forward.written == "18px ! /*c*/ important"
    let back = patchCssDeclaration(forward.content, ".card", "padding",
      forward.oldValue)
    check back.written == original
    for declared in ["18px !important /* a /* b */", "/* lead */ 18px !important",
        "8px /* mid */ 4px !important", "8px /* mid */ 4px",
        "18px /* note */ !important", "18px ! IMPORTANT"]:
      let there = edit(declared, "30px")
      check there.ok
      let again = patchCssDeclaration(there.content, ".card", "padding",
        there.oldValue)
      check again.written == declared

  test "R4: a comment before the value, or between its parts, stays out of the value":
    let lead = edit("/* lead */ 18px !important", "20px")
    check lead.oldValue == "18px !important"
    check lead.written == "/* lead */ 20px !important"
    check edit("/* lead */ 18px", "20px").written == "/* lead */ 20px"
    let mid = edit("8px /* mid */ 4px !important", "20px")
    check mid.oldValue == "8px /* mid */ 4px !important"
    # The comment between the value's parts goes with the value it sat in;
    # the old value holds it, so undo puts it back (the round-trip test).
    check mid.written == "20px !important"
    check edit("8px /* mid */ 4px", "20px").written == "20px"
    check edit("8px /* mid */ 4px /* after */", "20px").written ==
      "20px /* after */"
    # The same value, comments aside, is no change.
    check edit("8px /* mid */ 4px !important", "8px 4px").outcome == cpoUnchanged
    check edit("/* lead */ 18px", "18px").outcome == cpoUnchanged

  # Round-2 review residual R5: the value is read as CSS Syntax tokenizes it
  # (https://www.w3.org/TR/css-syntax-3/#consume-url-token,
  # #consume-escaped-code-point): an unquoted `url(...)` is one token, `/*`
  # included; a backslash escapes the next character outside strings too;
  # and a comment, string or `url(` that never closes is refused, because
  # where the value ends cannot be told.
  test "R5: every probe value, read and edited as CSS Syntax reads it":
    for (declared, written) in [
        ("url(a/*b) !important", "20px !important"),
        ("url(a/*b*/c) !important", "20px !important"),
        ("URL( a/*b ) !important", "20px !important"),
        ("url(\"a/*b\") !important", "20px !important"),
        ("\"a\\\"b /*\" !important", "20px !important"),
        ("a\\\"b !important", "20px !important"),
        ("a\\/*b*/ !important", "20px !important"),
        ("a /\\* x */ !important", "20px !important"),
        ("calc(var(--a, 1px) + 2px) !important", "20px !important"),
        ("calc(1px/*c*/+2px) !important", "20px !important"),
        ("rgb(0 0 0 / 50%) !important", "20px !important"),
        ("\"/*\" !important", "20px !important"),
        ("'x' /* a /* b */ !important /* c */", "20px /* a /* b */ !important /* c */"),
        ("8px /* mid */ 4px", "20px"),
        ("8px /* mid */ 4px ! /*p*/ important /* t */", "20px ! /*p*/ important /* t */"),
        ("/* lead */ 18px ! IMPORTANT", "/* lead */ 20px ! IMPORTANT")]:
      let edited = cssValueEdit(declared, "20px")
      check edited.refusal == ""
      check edited.text == written
      # Writing the reported old value back restores the declaration.
      check cssValueEdit(written, cssDeclarationValue(declared)).text == declared.strip()
    check cssPrioritySuffix("url(a/*b) !important") == " !important"
    check cssValueWithoutPriority("url(a/*b) !important") == "url(a/*b)"
    check cssValueWithoutPriority("a\\/*b*/ !important") == "a\\/*b*/"
    # The example writer's case: an unquoted url holding `/*`, edited.
    check cssValueEdit("url(a/*b)", "url(c)").text == "url(c)"
    check cssValueEdit("url(a/*b) !important", "url(c)").text == "url(c) !important"
    # A function merely named like url is not a url token.
    check cssPrioritySuffix("myurl(a) /* x */ !important") == " !important"

  test "R5: a value with an unterminated comment, string or url( is refused, nothing written":
    for declared in ["18px !important /* unterminated", "\"unterminated !important",
        "'line\nbreak' !important", "url(a !important", "18px /* open"]:
      let edited = cssValueEdit(declared, "20px")
      check edited.refusal.len > 0
      check "unterminated" in edited.refusal
      check edited.text == ""
    check "new value" in cssValueEdit("18px", "20px /* open").refusal
    # Through the stylesheet writers: a string or comment that runs to the
    # end of the sheet swallows the rule's `}`, so CSS (and the writers) have
    # no closed `.card` rule; the refusal says what hides it.
    for css in [".card { padding: \"unterminated !important; }",
        ".card { padding: 18px !important /* open; }"]:
      for r in [patchCssDeclaration(css, ".card", "padding", "20px"),
          patchCssDeclarationAt(css, ".card", "padding", "20px", 1440)]:
        check not r.ok
        check "never closed" in r.message
        check r.content == ""
    let media = ".card { padding: 1px; }\n@media (max-width: 600px) { .card { padding: 'x !important; } }\n"
    let under = patchCssDeclarationUnder(media, "@media (max-width: 600px)",
      ".card", "padding", "6px")
    check not under.ok
    check under.outcome == cpoUnreadable

  test "R5: an escaped quote outside a string does not swallow the declaration's end":
    let css = ".card { background: a\\\"b !important; color: red; }"
    let r = patchCssDeclaration(css, ".card", "background", "red")
    check r.ok
    check r.oldValue == "a\\\"b !important"
    check r.content == ".card { background: red !important; color: red; }"
    check patchCssDeclaration(r.content, ".card", "background", r.oldValue).content == css

  # Round-3 gap: the stylesheet's rule scanners read comments, strings,
  # escapes and unquoted urls by the same rules as the value
  # (`skipCssOpaque`), so a rule holding one is found and edited instead of
  # being refused as "rule not found".
  test "rules holding /*, braces or ; inside a string, escape or url are found and edited":
    for (css, property, written) in [
        (".card { background: url(\"a/*b\") !important; }", "background",
         ".card { background: red !important; }"),
        (".card { background: \"/*\" !important; }", "background",
         ".card { background: red !important; }"),
        (".card { background: \"a\\\"b /*\" !important; }", "background",
         ".card { background: red !important; }"),
        (".card { background: url(a/*b) !important; }", "background",
         ".card { background: red !important; }"),
        (".card { background: url(a;b}c) !important; color: blue; }", "background",
         ".card { background: red !important; color: blue; }"),
        (".card { content: \"{ } ; /*\"; color: blue; }", "color",
         ".card { content: \"{ } ; /*\"; color: red; }"),
        (".card { content: 'a\\'}'; color: blue; }", "color",
         ".card { content: 'a\\'}'; color: red; }"),
        (".card { content: \\7B; color: blue; }", "color",
         ".card { content: \\7B; color: red; }"),
        ("[title=\"/*\"] { color: green; }\n.card { color: blue; }", "color",
         "[title=\"/*\"] { color: green; }\n.card { color: red; }")]:
      let r = patchCssDeclaration(css, ".card", property, "red")
      check r.ok
      check r.outcome == cpoReplaced
      check r.content == written
      # And back, byte for byte, through the reported old value.
      check patchCssDeclaration(r.content, ".card", property, r.oldValue).content == css

  # Round-3 review R7: CSS Syntax closes at the end of the sheet whatever is
  # still open there, and a browser applies what came before as written
  # (checked in Chromium: `.x` keeps its padding in each sheet below except
  # the stray-apostrophe one, whose bad string swallows `.a`'s `}`, so `.x`
  # is not a top-level rule there). Only a write at or after the start of
  # what the end closes is refused; the catalog offers nothing there.
  test "R7: sheets a browser reads past an unclosed end are edited before it, never inside it":
    const rule = ".x { padding: 1px; }"
    for css in [
        rule & "\n.b { color: red;",                         # block closed by EOF
        rule & "\n/* trailing",                              # comment closed by EOF
        rule & "\n.z { content: x\\",                        # escape at EOF
        rule & "\n.z { background: url(a",                   # url( closed by EOF
        rule & "\n.z { content: 'open",                       # string closed by EOF
        "// don't do this\n.a { color: red; }\n" & rule,      # bad string ends at newline
        ".q { content: 'a\n; }\n" & rule,                     # the same inside a rule
        rule & "\n@media (min-width:100px) { #other { width:60px; }"]:
      let r = patchCssDeclaration(css, ".x", "padding", "9px")
      check r.ok
      check r.content == css.replace(rule, ".x { padding: 9px; }")
      check patchCssDeclarationAt(css, ".x", "padding", "9px", 1440).ok
      check removeCssDeclaration(css, ".x", "padding").ok
      check cssUnconditionalLiterals(css, @["padding"]).len == 1
      # A new override goes at the end of the sheet: inside what only the
      # end closes, when anything is open there.
      let under = patchCssDeclarationUnder(css, "@media (max-width: 900px)",
        ".x", "padding", "9px")
      if css.cssOpenTail().at >= 0:
        check not under.ok
        check under.outcome == cpoUnreadable
        check "never closed" in under.message
        check under.content == ""
      else:
        check under.ok

  test "R7: a rule inside what only the end of the sheet closes is neither edited nor offered":
    # The bad string in `it's` swallows `.a`'s `}` (Chromium drops `.x`).
    let stray = ".a { color: red; it's: x; }\n.x { padding: 1px; }"
    let r = patchCssDeclaration(stray, ".x", "padding", "9px")
    check not r.ok
    check r.content == ""
    check cssUnconditionalLiterals(stray, @["padding"]).len == 0
    # An insertion into the rule that the end of the sheet closes.
    let open = ".x { padding: 1px; }\n.b { color: red;"
    let into = patchCssDeclarationUnder(open & " } .c { color: blue;", "@media (max-width: 900px)",
      ".x", "padding", "9px")
    check not into.ok
    check patchCssDeclaration(open, ".b", "padding", "2px").ok == false
    check cssUnconditionalLiterals(open, @["color"]).len == 0
    # Inside a nested block the end closes: a conditional override there is
    # neither found nor added.
    let badString = ".card { padding: 1px; }\n@media (max-width: 600px) { .card { padding: 'x !important; } }\n"
    check patchCssDeclaration(badString, ".card", "padding", "5px").ok
    check not patchCssDeclarationUnder(badString, "@media (max-width: 600px)",
      ".card", "padding", "6px").ok

  test "the breakpoint and override writers find rules past such text too":
    let css = ".card { background: url(\"x/*\"); padding: 1px; }\n" &
      "@media (max-width: 600px) { .card { content: \"}\"; padding: 2px !important; } }\n"
    let at = patchCssDeclarationAt(css, ".card", "padding", "5px", 500)
    check at.ok
    check at.oldValue == "2px !important"
    check at.content == css.replace("padding: 2px !important", "padding:5px !important")
    let under = patchCssDeclarationUnder(css, "@media (max-width: 600px)",
      ".card", "padding", "6px")
    check under.ok
    check under.content == css.replace("padding: 2px !important", "padding: 6px !important")
    let base = patchCssDeclaration(css, ".card", "padding", "3px")
    check base.ok
    check base.content == css.replace("padding: 1px", "padding: 3px")

  test "a value shown without its priority, as the native fields show it":
    check cssValueWithoutPriority("8px !important") == "8px"
    check cssValueWithoutPriority("8px ! /*c*/ IMPORTANT /* why */") == "8px"
    check cssValueWithoutPriority("/* lead */ 8px 4px") == "8px 4px"
    check cssValueWithoutPriority("8px") == "8px"
    check cssValueMatches("8px ! /*c*/ important", "8px")
    check cssValueMatches("/* lead */ 8px /* mid */ 4px", "8px 4px")

  test "a declared value matches the value the inspector shows, priority aside":
    check cssValueMatches("18px !important", "18px")
    check cssValueMatches("18px ! IMPORTANT", "18px")
    check cssValueMatches("18px !important", "18px !important")
    check not cssValueMatches("18px", "18px !important")
    check not cssValueMatches("18px !important", "20px")

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

suite "css_patch: removing the one owning declaration (Reset)":
  # Editor spec "Universal Patterns": Reset removes the one declaration that
  # sets the property; anything but exactly one unconditional declaration is
  # refused with the reason, and every other byte stays where it was.
  test "a declaration sharing its line takes itself and the space after it":
    let r = removeCssDeclaration("#a { width:1px; height:2px; color:red; }\n",
      "#a", "height")
    check r.ok
    check r.outcome == cpoRemoved
    check r.oldValue == "2px"
    check r.content == "#a { width:1px; color:red; }\n"

  test "the last declaration without a semicolon leaves the rule well formed":
    let r = removeCssDeclaration("#a { width:1px; color:red }\n", "#a", "color")
    check r.ok
    check r.content == "#a { width:1px; }\n"

  test "a declaration on its own line takes the line; a later comment stays":
    let css = ".card {\n  padding: 18px;\n  margin:0; /* why */\n}\n"
    let r = removeCssDeclaration(css, ".card", "padding")
    check r.ok
    check r.content == ".card {\n  margin:0; /* why */\n}\n"
    let m = removeCssDeclaration(css, ".card", "margin")
    check m.ok
    check m.content == ".card {\n  padding: 18px;\n  /* why */\n}\n"

  test "a longhand never matches its shorthand or a longer name":
    let css = "#a { padding:8px; margin-top:1em; background-color:#123; }\n"
    let r = removeCssDeclaration(css, "#a", "padding")
    check r.ok
    check r.content == "#a { margin-top:1em; background-color:#123; }\n"
    check not removeCssDeclaration(css, "#a", "color").ok

  test "a property another declaration also sets is refused unchanged":
    # Reset must fall back to the class, token or inherited value: removing a
    # longhand that a shorthand in the same rule also sets, or a shorthand
    # whose longhands follow it, changes nothing or something else.
    for (css, property, other) in [
        ("#a { padding:8px; padding-top:1em; }\n", "padding-top", "padding"),
        ("#a { padding:8px; padding-top:1em; padding-right:2px; padding-bottom:3px; padding-left:4px; }\n", "padding", "padding-top"),
        ("#a { background:#000000; background-color:#334455; }\n", "background-color", "background"),
        ("#a { background-color:#334455; background:#000000; }\n", "background", "background-color"),
        ("#a { border-radius:4px; border-top-left-radius:1em; }\n", "border-top-left-radius", "border-radius"),
        ("#a { border-radius:4px; border-top-left-radius:1em; }\n", "border-radius", "border-top-left-radius"),
        ("#a { font-size:12px; }\n@media (max-width:600px) { #a { font:14px serif; } }\n", "font-size", "font"),
        ("#a { width:1px; all:unset; }\n", "width", "all")]:
      let r = removeCssDeclaration(css, "#a", property)
      check not r.ok
      check r.outcome == cpoAmbiguous
      check r.content.len == 0
      check ("`" & other & "` also sets `" & property & "` for `#a`") in r.message

  test "a grouped rule is the declaration's one owner":
    let r = removeCssDeclaration("html,body { margin:0; color:red; }\n", "body", "margin")
    check r.ok
    check r.content == "html,body { color:red; }\n"

  test "two declarations, a conditional one, or none are refused unchanged":
    let duplicate = removeCssDeclaration("#a { width:1px; width:2px; }\n", "#a", "width")
    check not duplicate.ok
    check duplicate.outcome == cpoAmbiguous
    check "2 declarations set `width` for `#a`" in duplicate.message
    check duplicate.content.len == 0
    let overridden = removeCssDeclaration(
      "#a { width:1px; }\n@media (max-width:600px) { #a { width:2px; } }\n", "#a", "width")
    check not overridden.ok
    check "2 declarations" in overridden.message
    let conditional = removeCssDeclaration(
      "#a { color:red; }\n@media (max-width:600px) { #a { width:2px; } }\n", "#a", "width")
    check not conditional.ok
    check "inside `@media (max-width:600px)`" in conditional.message
    let absent = removeCssDeclaration("#a { color:red; }\n", "#a", "width")
    check not absent.ok
    check "There is no `width` declaration for `#a`" in absent.message
    let noRule = removeCssDeclaration("#b { width:1px; }\n", "#a", "width")
    check not noRule.ok
    check noRule.outcome == cpoRuleNotFound

  test "inside a Nim const only the literal is searched and the module is returned":
    let module = "const s* = \"\"\"\n#a { width:1px; height:2px; }\n\"\"\"\n# #a { height:9px; }\n"
    let r = removeCssInNimConst(module, "s", "#a", "height")
    check r.ok
    check r.content == "const s* = \"\"\"\n#a { width:1px; }\n\"\"\"\n# #a { height:9px; }\n"
    check not removeCssInNimConst(module, "missing", "#a", "height").ok

suite "the editor's writers ask before writing a selector list or inserting":
  # isonim-pm issues 2026-10-16-selector-list-rules-are-admitted-for-edit-
  # and-removal and 2026-10-16-compiled-bindings-cannot-be-re-set-after-
  # reset-removes-their-last-declaration. Editor spec "Saving": an edit
  # changes exactly the one owning declaration; "Universal Patterns": after
  # Reset the property can be set again in the rule it was removed from. The
  # patcher still accepts a list as a home for its members (the grouped-rule
  # cases above); these are the questions the writers ask first.
  test "a declaration in a selector-list rule, or an insertion into one, is refused":
    let message = cssSelectorListRefusal("html,body { margin:0; }\n", "body", "margin")
    check message == "`body` is styled here by the selector list `html,body`; " &
      "changing `margin` there would change every selector in the list. " &
      "Edit the stylesheet directly."
    # A shorthand in the list rule sets the longhand too.
    check cssSelectorListRefusal(".a, .b { padding:1px; }\n.a { color:red; }\n",
      ".a", "padding-top").len > 0
    # Nothing declares it and the only rule for the selector is a list.
    check cssSelectorListRefusal(".a, .b { color:red; }\n", ".a", "width").len > 0
    # The selector's own rule owns it, or would receive it: allowed.
    check cssSelectorListRefusal("html,body { margin:0; }\nbody { color:red; }\n",
      "body", "color") == ""
    check cssSelectorListRefusal(".a { color:red; }\n.a, .b { margin:0; }\n",
      ".a", "color") == ""
    check cssSelectorListRefusal("#a { width:1px; }\n", "#a", "width") == ""
    # A conditional list rule that sets it is refused as well.
    check cssSelectorListRefusal("#a { width:1px; }\n@media (max-width:600px) { #a, #b { width:2px; } }\n",
      "#a", "width").len > 0

  test "an insertion home is the selector's one unconditional rule, alone and not yet setting it":
    check cssInsertionHome("#a { height:1px; }\n", "#a", "width")
    check cssInsertionHome("#a { }\n", "#a", "width")
    check not cssInsertionHome("#a { width:1px; }\n", "#a", "width")
    check not cssInsertionHome("#a { padding:1px; }\n", "#a", "padding-top")
    check not cssInsertionHome("#a { all:unset; }\n", "#a", "width")
    check not cssInsertionHome("#a, #b { height:1px; }\n", "#a", "width")
    check not cssInsertionHome("#a { }\n#a { }\n", "#a", "width")
    check not cssInsertionHome("#a { }\n@media (max-width:600px) { #a { width:2px; } }\n", "#a", "width")
    check not cssInsertionHome("#b { }\n", "#a", "width")
