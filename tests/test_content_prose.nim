## Real parser and HTML renderer on C and JS. No doubles; exact HTML and
## independent AST assertions prevent one layer from hiding another's error.
import std/[unittest, strutils]
import isonim/content/[markdown, prose]

suite "long-form prose":
  test "double-backtick spans retain embedded ticks and trim one surrounding space":
    check parseInlineSpans("Use `` `tick` `` here.") == @[
      InlineSpan(kind: ikText, text: "Use "), InlineSpan(kind: ikCode, text: "`tick`"),
      InlineSpan(kind: ikText, text: " here.")]
    check renderProseHtml(parseMarkdownDoc("Use `` `tick` `` here.")) ==
      "<p>Use <code>`tick`</code> here.</p>"

  test "code-span delimiters match whole runs and unmatched runs remain literal":
    check parseInlineSpans("``a ` b ``` c``") == @[InlineSpan(kind: ikCode, text: "a ` b ``` c")]
    check parseInlineSpans("a `` b ``` c") == @[InlineSpan(kind: ikText, text: "a `` b ``` c")]
    check parseInlineSpans("`foo``bar`") == @[InlineSpan(kind: ikCode, text: "foo``bar")]
    check parseInlineSpans("````") == @[InlineSpan(kind: ikText, text: "````")]

  test "code-span whitespace follows CommonMark without collapsing interior spaces":
    for pair in [("`  a  `", " a "), ("`   `", "   "), ("` a`", " a"),
                 ("`a `", "a "), ("`` a\r\nb\rc\nd ``", "a b c d"), ("`\ta\t`", "\ta\t")]:
      check parseInlineSpans(pair[0]) == @[InlineSpan(kind: ikCode, text: pair[1])]

  test "nested and adjacent quotes preserve block structure":
    let doc = parseMarkdownDoc("> outer\n>\n> > inner `x`\n>\n> final\n\n> separate")
    check doc.blocks.len == 2
    check doc.blocks[0].kind == bkBlockquote
    check doc.blocks[0].quoteBlocks.len == 3
    check doc.blocks[0].quoteBlocks[1].kind == bkBlockquote
    check doc.blocks[0].quoteBlocks[1].quoteBlocks[0].spans[1].text == "x"
    check renderProseHtml(doc) == "<blockquote><p>outer</p><blockquote><p>inner <code>x</code></p></blockquote><p>final</p></blockquote><blockquote><p>separate</p></blockquote>"

  test "footnotes use reference order and unique backlinks for repeated occurrences":
    let doc = parseMarkdownDoc("B[^b], A[^a], B[^b].\n\n[^a]: Alpha & <a>\n[^b]: Beta `code`")
    check doc.blocks.len == 2
    check doc.blocks[0].spans[1].footnoteNumber == 1
    check doc.blocks[0].spans[3].footnoteNumber == 2
    check doc.blocks[0].spans[5].referenceId == "fnref-1-2"
    check doc.blocks[1].footnotes[0].label == "b"
    check doc.blocks[1].footnotes[0].referenceIds == @["fnref-1", "fnref-1-2"]
    check renderProseHtml(doc) == "<p>B<sup id=\"fnref-1\"><a href=\"#fn-1\" role=\"doc-noteref\">1</a></sup>, A<sup id=\"fnref-2\"><a href=\"#fn-2\" role=\"doc-noteref\">2</a></sup>, B<sup id=\"fnref-1-2\"><a href=\"#fn-1\" role=\"doc-noteref\">1</a></sup>.</p><section class=\"footnotes\" role=\"doc-endnotes\"><ol><li id=\"fn-1\"><p>Beta <code>code</code></p><a href=\"#fnref-1\" role=\"doc-backlink\" aria-label=\"Back to reference 1\">↩</a> <a href=\"#fnref-1-2\" role=\"doc-backlink\" aria-label=\"Back to reference 1 (2)\">↩</a></li><li id=\"fn-2\"><p>Alpha &amp; &lt;a&gt;</p><a href=\"#fnref-2\" role=\"doc-backlink\" aria-label=\"Back to reference 2\">↩</a></li></ol></section>"

  test "definitions may precede use and continue in paragraphs with references":
    let doc = parseMarkdownDoc("[^one]: first\n\n    second[^two]\n\n[^two]: end\n\n> Use[^one].\n\nMissing[^none].")
    check doc.blocks[0].quoteBlocks[0].spans[1].footnoteNumber == 1
    check spansText(doc.blocks[1].spans) == "Missing[^none]."
    check doc.blocks[^1].footnotes.len == 2
    check doc.blocks[^1].footnotes[0].blocks.len == 2
    check doc.blocks[^1].footnotes[1].number == 2
    check renderProseHtml(doc).contains("<p>second<sup")

  test "unused and duplicate definitions do not emit duplicate anchors":
    let doc = parseMarkdownDoc("[^unused]: unused\n[^a]: first\n[^a]: second\n\nUse[^a].")
    check doc.blocks[^1].footnotes.len == 1
    check renderProseHtml(doc).contains("<p>first</p>")
    check not renderProseHtml(doc).contains("second")

  test "image and italic caption form an escaped figure":
    let doc = parseMarkdownDoc("![A & B](plot.png \"A title\")\n\n*Caption <one> & `two`.*", "notes/post.md")
    check doc.blocks.len == 1
    check doc.blocks[0].kind == bkFigure
    check doc.blocks[0].figureImage.href == "/notes/plot.png"
    check doc.blocks[0].figureImage.title == "A title"
    check renderProseHtml(doc) == "<figure><img src=\"/notes/plot.png\" alt=\"A &amp; B\" title=\"A title\"><figcaption>Caption &lt;one&gt; &amp; <code>two</code>.</figcaption></figure>"

  test "figure directive and plain standalone image remain distinct":
    let doc = parseMarkdownDoc(":::figure\n![alt](https://example.test/a.png)\nCaption ~~old~~\n:::\n\n![alone](a.png)")
    check doc.blocks.len == 2
    check doc.blocks[0].kind == bkFigure
    check doc.blocks[1].kind == bkParagraph
    check renderProseHtml(doc).contains("<figcaption>Caption <del>old</del></figcaption>")
    check renderProseHtml(doc).endsWith("<p><img src=\"/a.png\" alt=\"alone\"></p>")

  test "tasks distinguish checked unchecked ordinary and malformed items":
    let doc = parseMarkdownDoc("- [ ] pending\n- [x] complete\n- [X] also complete\n- ordinary\n- [xy] literal")
    check doc.blocks[0].tasks == @[tsUnchecked, tsChecked, tsChecked, tsNone, tsNone]
    check spansText(doc.blocks[0].items[0]) == "pending"
    check spansText(doc.blocks[0].items[4]) == "[xy] literal"
    # Each task's own text labels its checkbox; ordinary items get no label.
    check renderProseHtml(doc) == "<ul><li><label><input type=\"checkbox\" disabled> pending</label></li><li><label><input type=\"checkbox\" disabled checked> complete</label></li><li><label><input type=\"checkbox\" disabled checked> also complete</label></li><li>ordinary</li><li>[xy] literal</li></ul>"
    # Inline markup inside a task stays inside its label.
    check renderProseHtml(parseMarkdownDoc("- [x] see [the plan](https://example.test/plan) `now`")) ==
      "<ul><li><label><input type=\"checkbox\" disabled checked> see <a href=\"https://example.test/plan\">the plan</a> <code>now</code></label></li></ul>"

  test "strike parses children but code stays literal":
    let doc = parseMarkdownDoc("~~old `x` & [link](https://example.test)~~ and `~~literal~~`")
    check doc.blocks[0].spans[0].kind == ikStrike
    check doc.blocks[0].spans[0].children[1].kind == ikCode
    check renderProseHtml(doc) == "<p><del>old <code>x</code> &amp; <a href=\"https://example.test\">link</a></del> and <code>~~literal~~</code></p>"

  test "autolinks respect delimiters and balanced URL parentheses":
    let doc = parseMarkdownDoc("<https://example.test/a?x=1&y=2> <a@example.test> (https://example.test/a_(b)). www.example.test/path, a@example.test!")
    check renderProseHtml(doc) == "<p><a href=\"https://example.test/a?x=1&amp;y=2\">https://example.test/a?x=1&amp;y=2</a> <a href=\"mailto:a@example.test\">a@example.test</a> (<a href=\"https://example.test/a_(b)\">https://example.test/a_(b)</a>). <a href=\"http://www.example.test/path\">www.example.test/path</a>, <a href=\"mailto:a@example.test\">a@example.test</a>!</p>"
    check renderProseHtml(parseMarkdownDoc("<not a link> xhttps://example.test `https://example.test`")) == "<p>&lt;not a link&gt; xhttps://example.test <code>https://example.test</code></p>"

  test "link titles stay separate from balanced destinations":
    for src in ["[link](docs.md \"A title\")", "[link](docs.md 'A title')", "[link](docs.md (A title))"]:
      let s = parseInlineSpans(src, "guide/page.md")[0]
      check s.href == "/guide/docs"
      check s.title == "A title"
      check s.isRelative
    check parseInlineSpans("[x](https://example.test/a_(b))")[0].href == "https://example.test/a_(b)"
    check parseInlineSpans("[x](<a b.md> \"say \\\"hi\\\"\")")[0].title == "say \"hi\""

  test "fence attributes preserve code and record line decorations":
    let b = parseMarkdownDoc("```nim {3,1-2,2} title=\"Example & code\" diff\n+added\n-removed\n keep\n```").blocks[0]
    check b.lang == "nim"
    check b.code == "+added\n-removed\n keep"
    check b.fenceAttrs.title == "Example & code"
    check b.fenceAttrs.highlightLines == @[1, 2, 3]
    check b.fenceAttrs.diff
    check b.fenceAttrs.diffLines == @[DiffLine(line: 1, kind: dlAdded), DiffLine(line: 2, kind: dlRemoved)]
    check renderProseHtml(@[b]) == "<pre tabindex=\"0\"><code class=\"language-nim\">+added\n-removed\n keep</code></pre>"

  test "code blocks are keyboard-focusable scroll boxes, with or without a language":
    # A long line scrolls inside the block; tabindex lets a keyboard user
    # reach and scroll it (WCAG 2.2 SC 2.1.1, axe scrollable-region-focusable).
    check renderProseHtml(parseMarkdownDoc("```\nplain <code> & text\n```")) ==
      "<pre tabindex=\"0\"><code>plain &lt;code&gt; &amp; text</code></pre>"
    check renderProseHtml(parseMarkdownDoc("```sh\necho \"" & repeat('x', 200) & "\"\n```")) ==
      "<pre tabindex=\"0\"><code class=\"language-sh\">echo \"" & repeat('x', 200) & "\"</code></pre>"
    # Inline code is not a scroll box and stays a bare <code>.
    check renderProseHtml(parseMarkdownDoc("Use `x`.")) == "<p>Use <code>x</code>.</p>"

  test "tables sit in a focusable, named scroll region":
    let doc = parseMarkdownDoc("| A | B |\n| --- | --- |\n| 1 & 2 | <x> |")
    check tableScrollClass == "table-scroll"
    check tableRegionLabel == "Table"
    check renderProseHtml(doc) ==
      "<div class=\"table-scroll\" role=\"region\" tabindex=\"0\" aria-label=\"Table\">" &
      "<table><thead><tr><th>A</th><th>B</th></tr></thead><tbody>" &
      "<tr><td>1 &amp; 2</td><td>&lt;x&gt;</td></tr>" &
      "</tbody></table></div>"

  test "nested tables and code blocks get the same scroll boxes":
    # Quotes and footnotes render their bodies through the same renderer.
    let html = renderProseHtml(parseMarkdownDoc(
      "> | A |\n> | - |\n> | 1 |\n>\n> ```\n> code\n> ```\n\nNote[^n].\n\n[^n]: See:\n\n    ```\n    in note\n    ```"))
    check html.startsWith("<blockquote><div class=\"table-scroll\" role=\"region\" tabindex=\"0\" aria-label=\"Table\"><table>")
    check html.count("<pre tabindex=\"0\">") == html.count("<pre")
    check html.count("<pre") == 2
    check html.count("<table>") == 1
    check html.count("</table></div>") == 1

  test "long fences protect shorter fences and marker-like code":
    let doc = parseMarkdownDoc("````text\n```\n<!--more-->\n[^a]: code\n> quote\n````\n\nreal")
    check doc.blocks.len == 2
    check doc.blocks[0].code == "```\n<!--more-->\n[^a]: code\n> quote"
    check doc.excerpt.len == 1
    check spansText(doc.excerpt[0].spans) == "real"
    check doc.blocks[^1].kind != bkFootnotes

  test "excerpt uses the marker or first paragraph and ignores inline code":
    let doc = parseMarkdownDoc("## Intro\n\nFirst.\n\n<!--more-->\n\nSecond.")
    check doc.excerpt.len == 2
    check renderProseHtml(doc.excerpt) == "<h2 id=\"intro\">Intro</h2><p>First.</p>"
    check not renderProseHtml(doc).contains("more")
    check renderProseHtml(parseMarkdownDoc("Literal `<!--more-->` stays.").excerpt) == "<p>Literal <code>&lt;!--more--&gt;</code> stays.</p>"

  test "ToC and heading IDs share visible labels and collision-free document scope":
    let doc = parseMarkdownDoc("## A `word`\n\n> ### [A word](https://example.test)\n\n## A word\n\n## A word-2")
    check doc.headingTree[0].id == "a-word"
    check doc.headingTree[0].children[0].id == "a-word-2"
    check doc.headingTree[1].id == "a-word-3"
    check doc.headingTree[2].id == "a-word-2-2"
    check renderTocHtml(doc.headingTree) == "<ul><li><a href=\"#a-word\">A word</a><ul><li><a href=\"#a-word-2\">A word</a></li></ul></li><li><a href=\"#a-word-3\">A word</a></li><li><a href=\"#a-word-2-2\">A word-2</a></li></ul>"

  test "code-span whitespace survives paragraph line collection and quote prefixes":
    check parseMarkdownDoc("`a  \n  b`").blocks[0].spans[0].text == "a     b"
    check parseMarkdownDoc("> ```\n> a  \n> ```").blocks[0].quoteBlocks[0].code == "a  "

  test "escaped markers malformed strikes and angle autolinks stay distinct":
    check renderProseHtml(parseMarkdownDoc("\\~~plain~~ ~~~literal~~~ ~~ spaced ~~")) ==
      "<p>~~plain~~ ~~~literal~~~ ~~ spaced ~~</p>"
    check renderProseHtml(parseMarkdownDoc("<HTTPS://example.test> <a@localhost>")) ==
      "<p><a href=\"HTTPS://example.test\">HTTPS://example.test</a> <a href=\"mailto:a@localhost\">a@localhost</a></p>"

  test "fence metadata ignores braces inside titles and malformed highlight ranges":
    let b = parseMarkdownBlocks("```text title=\"A {2}\" {0,-1,2-1,999999999999999999999,1} diff\n+one\n```")[0]
    check b.fenceAttrs.title == "A {2}"
    check b.fenceAttrs.highlightLines == @[1]
    check b.code == "+one"
    check parseMarkdownBlocks("~~~text\nliteral ```\n~~~")[0].code == "literal ```"

  test "endnote IDs avoid headings and excerpt notes have no dangling backlinks":
    let doc = parseMarkdownDoc("# fn-1\n\n> Earlier[^a].\n\nSummary[^b].\n\nLater[^b].\n\n[^a]: A\n[^b]: B")
    check doc.blocks[^1].footnotes[0].id == "fn-1-2"
    check doc.excerpt[^1].footnotes.len == 1
    check doc.excerpt[^1].footnotes[0].number == 2
    check doc.excerpt[^1].footnotes[0].referenceIds == @["fnref-2"]
    let html = renderProseHtml(doc.excerpt)
    check html.contains("<li id=\"fn-2\" value=\"2\">")
    check not html.contains("fnref-2-2")

  test "code and links suppress footnote and strike syntax":
    let doc = parseMarkdownDoc("`[^a] ~~x~~ <!--more-->` [^unknown]\n\n[^a]: unused")
    check doc.blocks.len == 1
    check doc.blocks[0].spans[0].kind == ikCode
    check renderProseHtml(doc) == "<p><code>[^a] ~~x~~ &lt;!--more--&gt;</code> [^unknown]</p>"
    check parseMarkdownBlocks("before\n<!--more-->\nafter").len == 3

  test "literal heading punctuation preserves old slugs and visible ToC labels":
    let doc = parseMarkdownDoc("## foo_bar\n\n## a*b\n\n## **literal**")
    check doc.blocks[0].headingId == "foo-bar"
    check doc.blocks[1].headingId == "a-b"
    check doc.headingTree[0].text == "foo_bar"
    check doc.headingTree[1].text == "a*b"
    check doc.headingTree[2].text == "**literal**"
    check renderTocHtml(doc.headingTree) == "<ul><li><a href=\"#foo-bar\">foo_bar</a></li><li><a href=\"#a-b\">a*b</a></li><li><a href=\"#literal\">**literal**</a></li></ul>"

  test "heading HTML retains document link symbol and footnote resolution":
    let doc = parseMarkdownDoc("## [Guide](guide.md) [[sym:Thing]][^note]\n\n[^note]: detail", "posts/article.md",
      resolveSymbol = proc(sym: string): string = "/api#" & sym)
    check doc.blocks[0].headingSpans[0].href == "/posts/guide"
    check doc.blocks[0].headingSpans[2].href == "/api#Thing"
    check doc.blocks[0].headingSpans[3].footnoteNumber == 1
    check doc.headingTree[0].text == "Guide Thing"
    check renderProseHtml(doc).startsWith("<h2 id=\"guide-thing\"><a href=\"/posts/guide\">Guide</a> <a href=\"/api#Thing\"><code>Thing</code></a><sup id=\"fnref-1\"><a href=\"#fn-1\" role=\"doc-noteref\">1</a></sup></h2>")

  test "backticks bind more tightly than link brackets":
    check renderProseHtml(parseMarkdownDoc("[not a `link](/foo`)")) ==
      "<p>[not a <code>link](/foo</code>)</p>"
    check parseInlineSpans("`foo\\`bar`") == @[
      InlineSpan(kind: ikCode, text: "foo\\"), InlineSpan(kind: ikText, text: "bar`")]
    check parseMarkdownBlocks("```diff\n+added\n```")[0].lang == "diff"

  test "strike ignores delimiters inside complete links images and opaque spans":
    check renderProseHtml(parseMarkdownDoc("~~one [link](https://example.test/~~) two~~")) ==
      "<p><del>one <a href=\"https://example.test/~~\">link</a> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one [link](https://example.test \"a ~~ title\") two~~")) ==
      "<p><del>one <a href=\"https://example.test\" title=\"a ~~ title\">link</a> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one ![alt](https://example.test/~~.png \"a ~~ title\") two~~")) ==
      "<p><del>one <img src=\"https://example.test/~~.png\" alt=\"alt\" title=\"a ~~ title\"> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one `a~~b` two~~")) ==
      "<p><del>one <code>a~~b</code> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one <https://example.test/~~> two~~")) ==
      "<p><del>one <a href=\"https://example.test/~~\">https://example.test/~~</a> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one [[sym:A~~B]] two~~")) ==
      "<p><del>one <code>A~~B</code> two</del></p>"
    check renderProseHtml(parseMarkdownDoc("~~https://example.test~~")) ==
      "<p><del><a href=\"https://example.test\">https://example.test</a></del></p>"
    check renderProseHtml(parseMarkdownDoc("~~one https://example.test/a~~b two~~")) ==
      "<p><del>one <a href=\"https://example.test/a~~b\">https://example.test/a~~b</a> two</del></p>"

  test "incomplete link or image syntax cannot hide an outer strike closer":
    check renderProseHtml(parseMarkdownDoc("~~one [link](broken~~ after")) ==
      "<p><del>one [link](broken</del> after</p>"
    check renderProseHtml(parseMarkdownDoc("~~one ![alt](broken \"title~~ after")) ==
      "<p><del>one ![alt](broken \"title</del> after</p>"

  test "unresolved heading notes keep literal anchors and defined notes stay annotations":
    let doc = parseMarkdownDoc("## Missing[^none]\n\n## Missing[^none]\n\n## Defined[^known]\n\n[^known]: detail")
    check doc.blocks[0].headingId == "missing-none"
    check doc.blocks[1].headingId == "missing-none-2"
    check doc.headingTree[0].text == "Missing[^none]"
    check doc.blocks[2].headingId == "defined"
    check doc.headingTree[2].text == "Defined"
    check renderProseHtml(doc).contains("<h2 id=\"missing-none\">Missing[^none]</h2>")
    check renderTocHtml(doc.headingTree).contains("href=\"#missing-none\">Missing[^none]</a>")
    let unused = parseMarkdownDoc("[^unused]: ## Topic\n\n## Topic")
    check unused.blocks[0].headingId == "topic"
    check parseMarkdownBlocks("## Missing[^none]", footnotes = false)[0].headingId == "missing-none"

  test "resolved heading note IDs remain unique across nested headings and notes":
    let doc = parseMarkdownDoc("# fn-1\n\n> ## fnref-1\n\n## Missing[^none]\n\n## Defined[^a]\n\n[^a]: ### fn-1\n\n    Again[^a].")
    check doc.blocks[0].headingId == "fn-1"
    check doc.blocks[1].quoteBlocks[0].headingId == "fnref-1"
    check doc.blocks[2].headingId == "missing-none"
    check doc.blocks[3].headingId == "defined"
    let note = doc.blocks[^1].footnotes[0]
    check note.blocks[0].headingId == "fn-1-2"
    check note.id == "fn-1-3"
    check note.referenceIds == @["fnref-1-2", "fnref-1-3"]
    let html = renderProseHtml(doc)
    for id in ["fn-1", "fnref-1", "missing-none", "defined", "fn-1-2", "fn-1-3", "fnref-1-2", "fnref-1-3"]:
      check html.count("id=\"" & id & "\"") == 1

  test "link origins and authored label sources survive the AST boundary":
    let explicit = parseInlineSpans("[mailto:literal \\*stars\\*](https://example.test)")[0]
    check explicit.linkOrigin == loExplicit
    check explicit.labelSource == "mailto:literal \\*stars\\*"
    check explicit.text == "mailto:literal *stars*"
    let angle = parseInlineSpans("<mailto:user@example.test>")[0]
    check angle.linkOrigin == loAngleAutolink
    check angle.text == "mailto:user@example.test"
    check angle.labelSource == ""
    check parseInlineSpans("https://example.test")[0].linkOrigin == loBareAutolink
