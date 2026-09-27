## `shadowingDeclaration` — catching a patch that lands and does nothing.
##
## The bug these fixtures are built from: the editor wrote `font-size:50px`
## into grip's top-level `.tagline` rule, the write succeeded, the file
## changed, and the preview kept showing 34px. `.tagline` is redeclared inside
## `@media (max-width:1080px)` with the `font` SHORTHAND, that rule comes
## later at equal specificity, and `font` resets `font-size`. The editor's
## preview iframe is ~850px wide, so the media block always applied.
##
## Nothing was broken in a way anything could see: correct patch, correct
## file, correct save, no visible change. It is indistinguishable from a
## broken save, which is why it has to be reported rather than merely avoided.

import std/[unittest, strutils]
import isonim/editor/css_patch

const gripShape = """
  .tagline { font:var(--sys-type-display);
             letter-spacing:var(--sys-tracking-display);
             margin:0 0 30px;
             text-wrap:balance; }
  .tagline-clause { display:block; }                       /* STRUCTURAL */

  @media (max-width:1080px) {
    .tagline { font:var(--sys-type-displayCompact);
               letter-spacing:var(--sys-tracking-display); }
    .name-initial { font:var(--sys-type-initialCompact); }
  }
"""

suite "css_patch: a later rule that overrides the patch":

  test "a shorthand in a later @media block shadows the longhand":
    ## The exact shape of the real defect.
    let s = gripShape.shadowingDeclaration(".tagline", "font-size")
    check s.found
    check s.byProperty == "font"
    check s.condition == "@media (max-width:1080px)"
    check s.selector == ".tagline"

  test "the report names the condition rather than resolving it":
    ## Whether the media query applies depends on the viewport, which this
    ## function does not have. Naming the prelude lets the caller say "below
    ## 1080px" instead of guessing.
    let s = gripShape.shadowingDeclaration(".tagline", "line-height")
    check s.found
    check "max-width:1080px" in s.condition

  test "a property no later rule touches is not shadowed":
    let s = gripShape.shadowingDeclaration(".tagline", "text-wrap")
    check not s.found

  test "a property the later rule sets directly is shadowed too":
    ## Not only shorthands. `letter-spacing` is redeclared verbatim.
    let s = gripShape.shadowingDeclaration(".tagline", "letter-spacing")
    check s.found
    check s.byProperty == "letter-spacing"

  test "a different selector in the same @media block is not a shadow":
    ## `.name-initial` declares `font` inside the same block, and must not be
    ## mistaken for a rule about `.tagline`.
    let s = gripShape.shadowingDeclaration(".tagline-clause", "font-size")
    check not s.found

  test "an EARLIER rule does not shadow the patch":
    ## At equal specificity, document order decides. A rule before the patched
    ## one loses to it, so reporting it would be a false alarm -- and a false
    ## alarm on every edit is how a warning gets ignored.
    const earlierFirst = """
  @media (max-width:1080px) {
    .tagline { font:var(--sys-type-displayCompact); }
  }
  .tagline { font:var(--sys-type-display);
             text-wrap:balance; }
"""
    let s = earlierFirst.shadowingDeclaration(".tagline", "font-size")
    check not s.found

  test "a top-level later rule shadows without any at-rule":
    const twice = """
  .chip { color:red; }
  .other { color:blue; }
  .chip { font:12px serif; }
"""
    # Two top-level `.chip` rules make the PATCH ambiguous, which
    # `patchCssDeclaration` refuses -- but the shadow query is asked
    # independently and must still answer about document order.
    let s = twice.shadowingDeclaration(".chip", "font-size")
    check s.found
    check s.byProperty == "font"
    check s.condition == ""

  test "an unknown selector reports no shadow rather than failing":
    let s = gripShape.shadowingDeclaration(".nope", "font-size")
    check not s.found

  test "a longhand with no shorthand is still checked for itself":
    const direct = """
  .box { text-wrap:balance; }
  @media print {
    .box { text-wrap:pretty; }
  }
"""
    let s = direct.shadowingDeclaration(".box", "text-wrap")
    check s.found
    check s.byProperty == "text-wrap"
    check s.condition == "@media print"

  test "a nested at-rule still reports a condition":
    const nested = """
  .box { margin:0; }
  @supports (display:grid) {
    @media (max-width:600px) {
      .box { margin:8px; }
    }
  }
"""
    let s = nested.shadowingDeclaration(".box", "margin-top")
    check s.found
    check s.byProperty == "margin"
    check s.condition.len > 0

suite "css_patch: the patch and the shadow are independent questions":

  test "a patch that succeeds can still be shadowed":
    ## This is the pairing that matters: `ok` says the bytes changed, and it
    ## says nothing at all about whether the browser will honour them.
    let patched = patchCssDeclaration(gripShape, ".tagline", "font-size", "50px")
    check patched.ok
    check patched.outcome == cpoInserted
    check "font-size:50px;" in patched.content
    let s = patched.content.shadowingDeclaration(".tagline", "font-size")
    check s.found

# ---------------------------------------------------------------------------
#  Breakpoint-aware editing.
# ---------------------------------------------------------------------------

const responsive = """
  .tagline { font:var(--sys-type-display);
             letter-spacing:var(--sys-tracking-display);
             text-wrap:balance; }

  @media (prefers-color-scheme: dark) {
    .tagline { color:white; }
  }

  @media (max-width:1080px) {
    .tagline { font:var(--sys-type-displayCompact);
               letter-spacing:var(--sys-tracking-display); }
  }
"""

suite "css_patch: which rule an edit belongs in, at a given width":

  test "below the breakpoint, the edit belongs to the media rule":
    ## The media rule is later and its `font` shorthand is what currently
    ## decides `font-size`, so it is the only rule a change can come from.
    let t = responsive.editTargetAtWidth(".tagline", "font-size", 850)
    check t.found
    check t.isBreakpoint
    check t.condition == "@media (max-width:1080px)"
    check "1080px" in t.reason

  test "above the breakpoint, the edit belongs to the base rule":
    ## The media rule does not apply at 1440px, so editing there must not
    ## touch it -- and must not quietly resize the compact tagline too.
    let t = responsive.editTargetAtWidth(".tagline", "font-size", 1440)
    check t.found
    check not t.isBreakpoint
    check t.condition == ""

  test "exactly at the bound is inside it":
    ## `max-width:1080px` matches at 1080 and not at 1081. Off-by-one here
    ## sends an edit to the wrong rule at exactly the width a person is most
    ## likely to be testing.
    check responsive.editTargetAtWidth(".tagline", "font-size", 1080).isBreakpoint
    check not responsive.editTargetAtWidth(".tagline", "font-size", 1081).isBreakpoint

  test "a property nothing declares goes to the base rule at any width":
    ## No rule mentions `word-spacing`, so there is no responsive intent to
    ## respect, and scoping it to whatever breakpoint is on screen would
    ## invent one.
    for width in [400, 850, 1440]:
      let t = responsive.editTargetAtWidth(".tagline", "word-spacing", width)
      check t.found
      check not t.isBreakpoint

  test "a non-width media block is never an edit target":
    ## `@media (prefers-color-scheme: dark)` also redeclares `.tagline`. An
    ## edit made because the preview is 850px wide must never land in the
    ## dark-mode block, whatever the viewport.
    let t = responsive.editTargetAtWidth(".tagline", "color", 850)
    check t.found
    check not t.isBreakpoint
    check "dark" notin t.condition

  test "min-width blocks are evaluated too":
    const desktopFirst = """
  .card { padding:8px; }
  @media (min-width:900px) {
    .card { padding:24px; }
  }
"""
    check desktopFirst.editTargetAtWidth(".card", "padding", 1200).isBreakpoint
    check not desktopFirst.editTargetAtWidth(".card", "padding", 600).isBreakpoint

  test "a band with both bounds only matches inside it":
    const band = """
  .card { padding:8px; }
  @media (min-width:600px) and (max-width:900px) {
    .card { padding:16px; }
  }
"""
    check not band.editTargetAtWidth(".card", "padding", 500).isBreakpoint
    check band.editTargetAtWidth(".card", "padding", 700).isBreakpoint
    check not band.editTargetAtWidth(".card", "padding", 1000).isBreakpoint

suite "css_patch: writing into the rule a breakpoint selected":

  test "the declaration lands inside the media block, not the base rule":
    let r = patchCssDeclarationAt(responsive, ".tagline", "font-size",
                                  "50px", 850)
    check r.ok
    check r.outcome == cpoInserted
    # The base rule is untouched...
    let baseStart = r.content.find(".tagline { font:var(--sys-type-display)")
    let baseEnd = r.content.find("}", baseStart)
    check "font-size" notin r.content[baseStart ..< baseEnd]
    # ...and the media rule carries it.
    let mediaStart = r.content.find("@media (max-width:1080px)")
    check "font-size:50px;" in r.content[mediaStart .. ^1]

  test "and it actually wins, because it follows the shorthand":
    ## Inserting before the `font` shorthand would be reset by it. This is the
    ## mistake that cost two false test failures before anyone noticed the
    ## cascade was doing the overriding.
    let r = patchCssDeclarationAt(responsive, ".tagline", "font-size",
                                  "50px", 850)
    check r.ok
    let mediaStart = r.content.find("@media (max-width:1080px)")
    let body = r.content[mediaStart .. ^1]
    check body.find("font:var(--sys-type-displayCompact)") <
          body.find("font-size:50px")

  test "the same edit above the breakpoint lands in the base rule":
    let r = patchCssDeclarationAt(responsive, ".tagline", "font-size",
                                  "50px", 1440)
    check r.ok
    let mediaStart = r.content.find("@media (max-width:1080px)")
    check "font-size:50px" notin r.content[mediaStart .. ^1]
    check "font-size:50px;" in r.content[0 ..< mediaStart]

  test "an existing declaration in the media rule is replaced, not duplicated":
    const already = """
  .tagline { font:var(--sys-type-display); }
  @media (max-width:1080px) {
    .tagline { font:var(--sys-type-displayCompact);
               font-size:30px; }
  }
"""
    let r = patchCssDeclarationAt(already, ".tagline", "font-size", "50px", 850)
    check r.ok
    check r.outcome == cpoReplaced
    check r.oldValue == "30px"
    check r.content.count("font-size:") == 1
    check "font-size:50px;" in r.content

  test "writing the value it already has is a no-op":
    const already = """
  .tagline { font:var(--sys-type-display); }
  @media (max-width:1080px) {
    .tagline { font:var(--sys-type-displayCompact);
               font-size:30px; }
  }
"""
    let r = patchCssDeclarationAt(already, ".tagline", "font-size", "30px", 850)
    check r.ok
    check r.outcome == cpoUnchanged
    check r.content == already

  test "an inserted declaration matches its neighbours' indentation":
    let r = patchCssDeclarationAt(responsive, ".tagline", "font-size",
                                  "50px", 850)
    check r.ok
    var found = false
    for line in r.content.splitLines():
      if "font-size:50px;" in line:
        found = true
        check line.startsWith("               font-size:50px;")
    check found

  test "the base-rule path keeps the plain patch's refusals":
    ## `patchCssDeclarationAt` delegates when the target is the base rule, so
    ## an ambiguous selector must still be refused rather than guessed at.
    const doubled = """
  .card { color:red; }
  .card { color:blue; }
"""
    let r = patchCssDeclarationAt(doubled, ".card", "margin-top", "4px", 800)
    check not r.ok
    check r.outcome == cpoAmbiguous

  test "after the breakpoint write, nothing shadows it any more":
    ## The point of the whole exercise: the value the editor wrote is the
    ## value the browser will use.
    let r = patchCssDeclarationAt(responsive, ".tagline", "font-size",
                                  "50px", 850)
    check r.ok
    let target = r.content.editTargetAtWidth(".tagline", "font-size", 850)
    check target.isBreakpoint
    # The winning declaration at 850px is now `font-size` itself, not `font`.
    check "`font-size` is set" in target.reason
