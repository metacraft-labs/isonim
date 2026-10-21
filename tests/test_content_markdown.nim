## isonim/content/markdown -- the Markdown parser's Tier 1 suite.
## Dual-target: `nim c -r` and `nim js -r` must both pass (`just test-c`,
## `just test-js`).
##
## These are the parser cases isonim-docs ran against
## `src/core/markdown_vm.nim` before the parser moved here, unchanged
## except for the import: block-level parsing (headings, paragraphs,
## lists, code fences, admonitions, tables, inline code), the heading
## tree, relative-link and asset-reference normalization, the `:::tabs`
## block, and the content directives (`cards`, `hero`, `button`, `faq`,
## `video`, `form`). The cases that render the AST stayed in isonim-docs
## with its renderer. Added here: the path-derived route convention the
## link normalizer falls back on, which used to live in isonim-docs'
## content loader.
##
## Everything goes through the pure, filesystem-free parser, so the
## same assertions hold on both targets. No test doubles.

import std/unittest
import isonim/content/markdown

suite "isonim/content/markdown -- block and inline parsing":
  test "parseMarkdownBlocks translates a heading (with its stable anchor ID) and a paragraph with inline code":
    let blocks = parseMarkdownBlocks("# Getting Started\n\nRun `nimble install` first.")
    check blocks.len == 2
    check blocks[0].kind == bkHeading
    check blocks[0].level == 1
    check blocks[0].headingText == "Getting Started"
    check blocks[0].headingId == "getting-started"
    check blocks[1].kind == bkParagraph
    check blocks[1].spans.len == 3
    check blocks[1].spans[0] == InlineSpan(kind: ikText, text: "Run ")
    check blocks[1].spans[1] == InlineSpan(kind: ikCode, text: "nimble install")
    check blocks[1].spans[2] == InlineSpan(kind: ikText, text: " first.")

  test "parseMarkdownBlocks recognizes heading levels 1 through 6":
    let blocks = parseMarkdownBlocks("# One\n\n## Two\n\n###### Six")
    check blocks.len == 3
    check blocks[0].level == 1
    check blocks[1].level == 2
    check blocks[2].level == 6

  test "parseMarkdownBlocks joins soft-wrapped paragraph lines with a single space":
    let blocks = parseMarkdownBlocks("This is a paragraph\nthat wraps across\nthree lines.")
    check blocks.len == 1
    check blocks[0].kind == bkParagraph
    check spansText(blocks[0].spans) == "This is a paragraph that wraps across three lines."

  test "parseMarkdownBlocks translates an unordered list and stops at the next block":
    let blocks = parseMarkdownBlocks("- First\n- Second\n- Third\n\n# Next")
    check blocks.len == 2
    check blocks[0].kind == bkList
    check blocks[0].listKind == lkUnordered
    check blocks[0].items.len == 3
    check spansText(blocks[0].items[0]) == "First"
    check spansText(blocks[0].items[2]) == "Third"
    check blocks[1].kind == bkHeading

  test "parseMarkdownBlocks translates an ordered list distinctly from an unordered one":
    let blocks = parseMarkdownBlocks("1. Step one\n2. Step two")
    check blocks.len == 1
    check blocks[0].kind == bkList
    check blocks[0].listKind == lkOrdered
    check blocks[0].items.len == 2
    check spansText(blocks[0].items[1]) == "Step two"

  test "parseMarkdownBlocks translates a fenced code block, preserving its language and body verbatim":
    let blocks = parseMarkdownBlocks("```nim\nlet x = 1\necho x\n```")
    check blocks.len == 1
    check blocks[0].kind == bkCodeFence
    check blocks[0].lang == "nim"
    check blocks[0].code == "let x = 1\necho x"

  test "parseMarkdownBlocks translates a fenced code block with no language tag":
    let blocks = parseMarkdownBlocks("```\nplain text\n```")
    check blocks.len == 1
    check blocks[0].lang == ""
    check blocks[0].code == "plain text"

  test "parseMarkdownBlocks translates a ':::kind' admonition fence, defaulting an unrecognized kind to Note":
    let blocks = parseMarkdownBlocks(":::warning\nBack up first.\nThen proceed.\n:::")
    check blocks.len == 1
    check blocks[0].kind == bkAdmonition
    check blocks[0].admonitionKind == akWarning
    check blocks[0].bodyParagraphs.len == 1
    check spansText(blocks[0].bodyParagraphs[0]) == "Back up first. Then proceed."

    let unrecognized = parseMarkdownBlocks(":::mystery\nJust an FYI.\n:::")
    check unrecognized[0].admonitionKind == akNote

  test "parseMarkdownBlocks recognizes every admonition kind":
    check parseMarkdownBlocks(":::note\nx\n:::")[0].admonitionKind == akNote
    check parseMarkdownBlocks(":::tip\nx\n:::")[0].admonitionKind == akTip
    check parseMarkdownBlocks(":::warning\nx\n:::")[0].admonitionKind == akWarning
    check parseMarkdownBlocks(":::danger\nx\n:::")[0].admonitionKind == akDanger

  test "parseMarkdownBlocks translates a pipe table into header cells and body rows":
    let raw = "| Name | Kind |\n| --- | --- |\n| foo | bar |\n| baz | qux |"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkTable
    check blocks[0].headers == @["Name", "Kind"]
    check blocks[0].rows.len == 2
    check blocks[0].rows[0] == @["foo", "bar"]
    check blocks[0].rows[1] == @["baz", "qux"]

  test "parseMarkdownBlocks translates a standalone image line into a single-span paragraph with a normalized asset path":
    let blocks = parseMarkdownBlocks("![Diagram](./diagram.png)", "guide/page.md")
    check blocks.len == 1
    check blocks[0].kind == bkParagraph
    check blocks[0].spans.len == 1
    check blocks[0].spans[0].kind == ikImage
    check blocks[0].spans[0].text == "Diagram"
    check blocks[0].spans[0].href == "/guide/diagram.png"
    check blocks[0].spans[0].isRelative == true

  test "parseMarkdownBlocks parses multiple blocks in document order":
    let raw = "# Title\n\nIntro paragraph.\n\n- one\n- two\n\n```sh\necho hi\n```"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 4
    check blocks[0].kind == bkHeading
    check blocks[1].kind == bkParagraph
    check blocks[2].kind == bkList
    check blocks[3].kind == bkCodeFence

  test "parseMarkdownDoc's heading tree nests headings by level, stopping a section at the next same-or-shallower heading":
    let doc = parseMarkdownDoc(
      "# Guide\n\n## Install\n\nBody.\n\n## Usage\n\n### Basics\n\nBody.\n\n# Reference")
    let tree = doc.headingTree
    check tree.len == 2
    check tree[0].text == "Guide"
    check tree[0].children.len == 2
    check tree[0].children[0].text == "Install"
    check tree[0].children[0].children.len == 0
    check tree[0].children[1].text == "Usage"
    check tree[0].children[1].children.len == 1
    check tree[0].children[1].children[0].text == "Basics"
    check tree[1].text == "Reference"
    check tree[1].children.len == 0

  test "parseMarkdownDoc's heading tree nests a heading that skips a level directly under the shallower one":
    let doc = parseMarkdownDoc("# Guide\n\n### Deep Note")
    let tree = doc.headingTree
    check tree.len == 1
    check tree[0].text == "Guide"
    check tree[0].children.len == 1
    check tree[0].children[0].text == "Deep Note"

  test "parseMarkdownDoc assigns deduped anchor IDs to duplicate headings across the whole document":
    let doc = parseMarkdownDoc("# Guide\n\n## Setup\n\n# Guide\n\n## Setup")
    let tree = doc.headingTree
    check tree.len == 2
    check tree[0].text == "Guide"
    check tree[0].id == "guide"
    check tree[1].text == "Guide"
    check tree[1].id == "guide-2"
    check tree[0].children[0].id == "setup"
    check tree[1].children[0].id == "setup-2"

  test "resolveRelativePath collapses './' and '../' segments against a base directory":
    check resolveRelativePath("guide", "./advanced.md") == "guide/advanced.md"
    check resolveRelativePath("guide", "../index.md") == "index.md"
    check resolveRelativePath("", "getting-started.md") == "getting-started.md"

  test "normalizeRelativeLink resolves a same-directory '.md' link against the current page's own path":
    check normalizeRelativeLink("./advanced.md", "guide/getting-started.md") ==
      ("/guide/advanced", true)

  test "normalizeRelativeLink resolves a parent-directory '.md' link, including back to the root index":
    check normalizeRelativeLink("../index.md", "guide/getting-started.md") == ("/", true)

  test "normalizeRelativeLink resolves a bare (no './') relative '.md' link from a top-level page":
    check normalizeRelativeLink("getting-started.md", "index.md") == ("/getting-started", true)

  test "normalizeRelativeLink resolves a relative non-'.md' reference into a root-relative asset path":
    check normalizeRelativeLink("./diagram.png", "guide/getting-started.md") ==
      ("/guide/diagram.png", true)
    check normalizeRelativeLink("../shared/logo.svg", "guide/getting-started.md") ==
      ("/shared/logo.svg", true)

  test "normalizeRelativeLink passes external/absolute/fragment/mailto targets through unchanged":
    for href in ["https://example.com", "http://example.com/x", "mailto:a@example.com",
                 "//cdn.example.com/x", "/already/rooted", "#section"]:
      check normalizeRelativeLink(href, "guide/getting-started.md") == (href, false)

  test "parseInlineSpans normalizes a relative markdown link's href to a route path in place":
    let spans = parseInlineSpans("See the [advanced guide](./advanced.md) for more.", "guide/page.md")
    check spans.len == 3
    check spans[1] == InlineSpan(kind: ikLink, text: "advanced guide",
      href: "/guide/advanced", isRelative: true)

  test "parseInlineSpans normalizes an inline image reference's src to an asset path":
    let spans = parseInlineSpans("See ![the diagram](./diagram.png) above.", "guide/page.md")
    check spans.len == 3
    check spans[1] == InlineSpan(kind: ikImage, text: "the diagram",
      href: "/guide/diagram.png", isRelative: true)

suite "isonim/content/markdown -- :::tabs":
  test "parseMarkdownBlocks translates ':::tabs' / '@tab Title' into an ordered bkTabs block":
    let raw = ":::tabs\n@tab Nim\nSee `echo 1`.\n@tab Bash\necho 1\n:::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkTabs
    check blocks[0].tabs.len == 2
    check blocks[0].tabs[0].title == "Nim"
    check blocks[0].tabs[1].title == "Bash"

  test "parseMarkdownBlocks re-parses each tab panel's body as a full nested block list":
    let raw = ":::tabs\n@tab Nim\n```nim\nlet x = 1\n```\n@tab JSON\n```json\n{}\n```\n:::"
    let blocks = parseMarkdownBlocks(raw)
    let tabs = blocks[0].tabs
    check tabs[0].blocks.len == 1
    check tabs[0].blocks[0].kind == bkCodeFence
    check tabs[0].blocks[0].lang == "nim"
    check tabs[1].blocks[0].lang == "json"

  test "parseMarkdownBlocks preserves panel order exactly as authored":
    let raw = ":::tabs\n@tab First\nOne.\n@tab Second\nTwo.\n@tab Third\nThree.\n:::"
    let tabs = parseMarkdownBlocks(raw)[0].tabs
    check tabs.len == 3
    check tabs[0].title == "First"
    check tabs[1].title == "Second"
    check tabs[2].title == "Third"
    check spansText(tabs[0].blocks[0].spans) == "One."
    check spansText(tabs[2].blocks[0].spans) == "Three."

  test "parseMarkdownBlocks parses tabs alongside other blocks in document order":
    let raw = "# Title\n\n:::tabs\n@tab A\nBody A.\n:::\n\nAfter."
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 3
    check blocks[0].kind == bkHeading
    check blocks[1].kind == bkTabs
    check blocks[2].kind == bkParagraph

suite "isonim/content/markdown -- content directives":
  test ":::cards / :::card parses into a bkCardGrid with title/icon/href + description":
    let raw = ":::cards\n" &
      ":::card title=\"Getting Started\" icon=\"/img/start.svg\" href=\"guide/start.md\"\n" &
      "Install and record your first trace.\n" &
      ":::card title=\"Reference\" icon=\"/img/ref.svg\" href=\"reference.md\"\n" &
      "The full API surface.\n" &
      ":::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkCardGrid
    check blocks[0].cards.len == 2
    check blocks[0].cards[0].title == "Getting Started"
    check blocks[0].cards[0].icon == "/img/start.svg"
    check blocks[0].cards[0].href == "guide/start.md"
    check spansText(blocks[0].cards[0].body[0]) == "Install and record your first trace."
    check blocks[0].cards[1].title == "Reference"
    check spansText(blocks[0].cards[1].body[0]) == "The full API surface."
    # M6: a plain `:::cards` grid has NO variant, so it keeps the default
    # (category-card) look byte-for-byte.
    check blocks[0].gridVariant == ""

  test "M6: :::cards variant=\"compact\" parses gridVariant, unknown/absent normalizes to \"\"":
    let compact = parseMarkdownBlocks(
      ":::cards variant=\"compact\"\n:::card title=\"Introduction\" href=\"a.md\"\nGetting Started\n:::")
    check compact.len == 1
    check compact[0].kind == bkCardGrid
    check compact[0].gridVariant == "compact"
    # An unrecognized value falls back to the default (empty) variant, so a
    # typo can never silently change an existing grid's look.
    let bogus = parseMarkdownBlocks(":::cards variant=\"wide\"\n:::card title=\"X\" href=\"x.md\"\nY\n:::")
    check bogus[0].gridVariant == ""

  test ":::hero parses title/subtitle attrs and its :::button action list":
    let raw = ":::hero title=\"Welcome\" subtitle=\"Docs for everyone\"\n" &
      ":::button href=\"start.md\" variant=\"primary\"\n" &
      "Get Started\n" &
      ":::button href=\"support.md\" variant=\"secondary\"\n" &
      "Support\n" &
      ":::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkHero
    check blocks[0].heroTitle == "Welcome"
    check blocks[0].heroSubtitle == "Docs for everyone"
    check blocks[0].heroButtons.len == 2
    check blocks[0].heroButtons[0].label == "Get Started"
    check blocks[0].heroButtons[0].href == "start.md"
    check blocks[0].heroButtons[0].variant == "primary"
    check blocks[0].heroButtons[1].label == "Support"
    check blocks[0].heroButtons[1].variant == "secondary"

  test ":::button parses into a standalone bkButton (variant defaults to primary)":
    let raw = ":::button href=\"start.md\"\nGet Started\n:::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkButton
    check blocks[0].button.label == "Get Started"
    check blocks[0].button.href == "start.md"
    check blocks[0].button.variant == "primary"

  test ":::faq / :::q parses into a bkFaq with question + answer paragraphs":
    let raw = ":::faq\n" &
      ":::q title=\"What is it?\"\n" &
      "A time-traveling debugger.\n" &
      ":::q title=\"Which languages?\"\n" &
      "Noir, Ruby and more.\n" &
      ":::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkFaq
    check blocks[0].faqItems.len == 2
    check blocks[0].faqItems[0].question == "What is it?"
    check spansText(blocks[0].faqItems[0].answer[0]) == "A time-traveling debugger."
    check blocks[0].faqItems[1].question == "Which languages?"
    check spansText(blocks[0].faqItems[1].answer[0]) == "Noir, Ruby and more."

  test "M3: :::video parses a bare YouTube id into a bkVideo":
    let blocks = parseMarkdownBlocks(":::video xZsJ55JVqmU")
    check blocks.len == 1
    check blocks[0].kind == bkVideo
    check blocks[0].videoId == "xZsJ55JVqmU"
    check blocks[0].videoSrc == ""

  test "M3: :::video extracts the id from watch / youtu.be / embed URLs and reads title=":
    check parseMarkdownBlocks(
      ":::video https://www.youtube.com/watch?v=xZsJ55JVqmU&t=1")[0].videoId == "xZsJ55JVqmU"
    check parseMarkdownBlocks(":::video https://youtu.be/xZsJ55JVqmU")[0].videoId == "xZsJ55JVqmU"
    check parseMarkdownBlocks(
      ":::video https://www.youtube.com/embed/xZsJ55JVqmU")[0].videoId == "xZsJ55JVqmU"
    let titled = parseMarkdownBlocks(":::video xZsJ55JVqmU title=\"Noir Demo\"")[0]
    check titled.videoId == "xZsJ55JVqmU"
    check titled.videoTitle == "Noir Demo"

  test "M3: :::video src=\"...\" overrides the id and is used verbatim":
    let blk = parseMarkdownBlocks(":::video src=\"https://example.com/e/abc\" title=\"X\"")[0]
    check blk.kind == bkVideo
    check blk.videoSrc == "https://example.com/e/abc"

  test "M3: an empty / bogus :::video is handled safely (no id, no crash)":
    let empty = parseMarkdownBlocks(":::video")
    check empty.len == 1
    check empty[0].kind == bkVideo
    check empty[0].videoId == ""

  test ":::form parses action/method/submit + a full field set into a bkForm":
    let raw = ":::form action=\"/support\" method=\"get\" submit=\"Send message\"\n" &
      "@field name=\"Email\" label=\"Email address\" type=email placeholder=\"Email\" required\n" &
      "@field name=\"Name\" label=\"Name\" type=text required\n" &
      "@field name=\"Category\" label=\"Category\" type=select options=\"Payments,Account,Software\" required\n" &
      "@field name=\"Message\" label=\"Message\" type=textarea required\n" &
      "@field name=\"remember\" label=\"Remember me\" type=checkbox\n" &
      ":::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkForm
    check blocks[0].formAction == "/support"
    check blocks[0].formMethod == "get"
    check blocks[0].formSubmit == "Send message"
    check blocks[0].formFields.len == 5
    check blocks[0].formFields[0].name == "Email"
    check blocks[0].formFields[0].label == "Email address"
    check blocks[0].formFields[0].kind == ffkEmail
    check blocks[0].formFields[0].placeholder == "Email"
    check blocks[0].formFields[0].required
    check blocks[0].formFields[1].kind == ffkText
    check blocks[0].formFields[2].kind == ffkSelect
    check blocks[0].formFields[2].options == @["Payments", "Account", "Software"]
    check blocks[0].formFields[3].kind == ffkTextarea
    check blocks[0].formFields[4].kind == ffkCheckbox
    check not blocks[0].formFields[4].required

  test ":::form submit defaults + malformed lines are handled safely":
    # No submit= attr -> a sensible default label; a stray non-@field line is
    # ignored; an unknown type falls back to a plain text input; nothing raises.
    let raw = ":::form\n" &
      "Some stray prose that is not a field.\n" &
      "@field name=\"Email\" label=\"Email\" type=wobble\n" &
      "@field name=\"pw\" label=\"Password\" type=password\n" &
      ":::"
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 1
    check blocks[0].kind == bkForm
    check blocks[0].formSubmit == "Submit"       # default
    check blocks[0].formFields.len == 2           # the stray line is ignored
    check blocks[0].formFields[0].kind == ffkText # unknown type -> text
    check blocks[0].formFields[1].kind == ffkPassword

  test "components parse alongside other blocks in document order":
    let raw = "Intro paragraph.\n\n:::button href=\"x.md\"\nGo\n:::\n\nAfter."
    let blocks = parseMarkdownBlocks(raw)
    check blocks.len == 3
    check blocks[0].kind == bkParagraph
    check blocks[1].kind == bkButton
    check blocks[2].kind == bkParagraph

  test "a plain markdown page parses to NONE of the new component block kinds":
    let raw = "## Heading\n\nA paragraph with `code` and a [link](other.md).\n\n" &
      "- one\n- two\n\n:::note\nAn admonition.\n:::\n\n" &
      "```nim\nlet x = 1\n```\n"
    for blk in parseMarkdownBlocks(raw):
      check blk.kind notin {bkCardGrid, bkHero, bkButton, bkFaq, bkVideo}

suite "isonim/content/markdown -- the path-derived route convention":
  test "contentPathSlug strips the directory and a .md extension":
    check contentPathSlug("guide/getting-started.md") == "getting-started"
    check contentPathSlug("index.md") == "index"
    check contentPathSlug("a/b/c.txt") == "c.txt"

  test "contentPathSection is the parent directory, empty at the root":
    check contentPathSection("guide/getting-started.md") == "guide"
    check contentPathSection("a/b/c.md") == "a/b"
    check contentPathSection("index.md") == ""

  test "contentRoutePath binds index pages to their section root and others to /section/slug":
    check contentRoutePath("", "index") == "/"
    check contentRoutePath("guide", "index") == "/guide"
    check contentRoutePath("guide", "intro") == "/guide/intro"
    check contentRoutePath("", "about") == "/about"

  test "normalizeRelativeLink without a resolver uses exactly that convention, fragment kept":
    check normalizeRelativeLink("./sub/index.md#top", "guide/page.md") ==
      ("/guide/sub#top", true)
    check normalizeRelativeLink("../about.md", "guide/page.md") == ("/about", true)

  test "normalizeRelativeLink prefers a caller's resolver for the route part":
    let resolver = proc(p: string): string = "/r/" & p
    check normalizeRelativeLink("./intro.md#x", "guide/page.md", resolver) ==
      ("/r/guide/intro.md#x", true)
