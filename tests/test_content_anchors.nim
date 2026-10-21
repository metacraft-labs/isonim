## isonim/content/anchors -- stable heading anchor IDs. Dual-target:
## `nim c -r` and `nim js -r` must both pass.
##
## Moved unchanged from isonim-docs' anchor suite when the module moved:
## slugs are stable across punctuation differences, duplicate headings
## anywhere in a document get deduped numeric suffixes, and dedup is flat
## across heading levels -- an anchor is a URL fragment, not scoped per
## section, so two same-text headings at different levels must still
## dedupe against each other. No test doubles.

import std/unittest
import isonim/content/anchors

suite "isonim/content/anchors -- stable slug and dedupe rules":
  test "slugifyHeadingText lowercases and collapses punctuation/whitespace to single hyphens":
    check slugifyHeadingText("Getting Started") == "getting-started"
    check slugifyHeadingText("Getting Started!") == "getting-started"
    check slugifyHeadingText("Getting, Started") == "getting-started"
    check slugifyHeadingText("  Getting   Started  ") == "getting-started"

  test "slugifyHeadingText trims leading/trailing punctuation rather than leaving stray hyphens":
    check slugifyHeadingText("--Hello--") == "hello"
    check slugifyHeadingText("!!!") == ""

  test "slugifyHeadingText is stable regardless of punctuation style used for the same words":
    check slugifyHeadingText("Signals & Effects") == slugifyHeadingText("Signals&Effects")
    check slugifyHeadingText("Signals & Effects!") == slugifyHeadingText("Signals & Effects")
    check slugifyHeadingText("Signals & Effects") == "signals-effects"

  test "AnchorIdRegistry gives the first occurrence of a slug the bare slug":
    var reg = newAnchorIdRegistry()
    check reg.nextId("Overview") == "overview"

  test "AnchorIdRegistry dedupes repeated headings with numeric suffixes in document order":
    var reg = newAnchorIdRegistry()
    check reg.nextId("Example") == "example"
    check reg.nextId("Example") == "example-2"
    check reg.nextId("Example") == "example-3"

  test "AnchorIdRegistry dedupes punctuation-equivalent duplicate headings against each other":
    var reg = newAnchorIdRegistry()
    check reg.nextId("Getting Started") == "getting-started"
    check reg.nextId("Getting Started!") == "getting-started-2"

  test "AnchorIdRegistry dedupes flatly across heading levels/nested sections":
    var reg = newAnchorIdRegistry()
    check reg.nextId("Overview") == "overview" # e.g. an H2
    check reg.nextId("Details") == "details" # an H3 nested under it
    check reg.nextId("Overview") == "overview-2" # a later H2 in a different section, same text

  test "AnchorIdRegistry falls back to a non-empty base for a heading with no alphanumeric characters":
    var reg = newAnchorIdRegistry()
    check reg.nextId("---") == "section"
    check reg.nextId("!!!") == "section-2"

  test "assignHeadingIds is a convenience batch form equivalent to sequential nextId calls":
    let ids = assignHeadingIds(@["Intro", "Details", "Intro"])
    check ids == @["intro", "details", "intro-2"]

  test "nextRawId dedups a formed base verbatim, sharing the counter with nextId":
    var reg = newAnchorIdRegistry()
    check reg.nextRawId("sym-MyType.myProc") == "sym-MyType.myProc"
    check reg.nextRawId("sym-MyType.myProc") == "sym-MyType.myProc-2"
    check reg.nextId("Setup") == "setup"
    check reg.nextRawId("setup") == "setup-2"
    check reg.nextRawId("") == "sym"
